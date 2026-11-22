import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'playback_progress_service.dart';
import 'user_profile_service.dart';

/// Serviço de sincronização em nuvem (Cloud Firestore REST + Anonymous Auth)
/// para manter o progresso de Filmes e Séries sincronizado entre Celular e Fire TV.
///
/// Implementado com HTTPS puro (`package:http`), garantindo funcionamento leve em
/// dispositivos sem Google Play Services (ex.: Amazon Fire TV Stick Lite / Fire OS 7)
/// e aplicando sempre a regra "mais avançado sempre vence" via
/// [PlaybackProgressService.pickMoreAdvanced].
class CloudProgressSyncService {
  static const String defaultProjectId = 'jessflix-sync-60d42';
  static const String defaultApiKey = 'AIzaSyClu_cKtwrcPsnlKN7klrEpbe_lUKgXU9k';
  static const String defaultDatabaseId = '(default)';

  static const String _authStorageKey = 'cloud_sync_auth_v1';
  static const int _maxLedgerItems = 30;
  static const int _maxItemsJsonBytes = 60000;
  static const Duration _pushThrottleInterval = Duration(seconds: 25);
  static const Duration _syncCooldown = Duration(seconds: 4);

  static CloudProgressSyncService _instance = CloudProgressSyncService();
  static CloudProgressSyncService get instance => _instance;

  @visibleForTesting
  static void setMockInstance(CloudProgressSyncService? service) {
    _instance = service ?? CloudProgressSyncService();
  }

  final String projectId;
  final String apiKey;
  final String databaseId;
  final http.Client? _customClient;
  final SharedPreferences? _customPrefs;
  final bool enableInTests;

  final Map<String, Future<bool>> _inFlightSyncs = {};
  final Map<String, DateTime> _lastSyncAt = {};
  final Map<String, DateTime> _lastPushAt = {};

  String? _cachedIdToken;
  String? _cachedRefreshToken;
  String? _cachedUid;
  DateTime? _cachedExpiresAt;
  Future<bool>? _authFuture;

  CloudProgressSyncService({
    this.projectId = defaultProjectId,
    this.apiKey = defaultApiKey,
    this.databaseId = defaultDatabaseId,
    http.Client? client,
    SharedPreferences? prefs,
    this.enableInTests = false,
  }) : _customClient = client,
       _customPrefs = prefs;

  bool get _isDisabledForTests =>
      !enableInTests &&
      _customClient == null &&
      Platform.environment.containsKey('FLUTTER_TEST');

  Future<SharedPreferences> _getPrefs() async {
    return _customPrefs ?? await SharedPreferences.getInstance();
  }

  String _effectiveAccountKey(String accountKey) {
    return UserProfileService.instance.getScopedKey(accountKey);
  }

  /// Gera identificador SHA-256 hex de 64 caracteres sem expor credenciais/URL do servidor.
  static String buildSyncId(String effectiveAccountKey) {
    final normalized = effectiveAccountKey.trim().toLowerCase();
    final bytes = utf8.encode('jessflix_sync_v1:$normalized');
    return sha256.convert(bytes).toString();
  }

  /// Chave estável por item no mapa sincronizado (`movie_<id>` ou `series_<seriesId>`).
  static String buildItemKey(ContinueWatchingItem item) {
    if (item.type == ContinueWatchingType.series) {
      final sid = item.seriesId ?? item.streamId;
      return 'series_$sid';
    }
    return 'movie_${item.streamId}';
  }

  String _ledgerKey(String effectiveAccountKey) =>
      'cloud_sync_ledger_$effectiveAccountKey';

  Uri _documentUri(String syncId, {bool withUpdateMask = false}) {
    final dbSegment =
        databaseId == '(default)' ? '(default)' : Uri.encodeComponent(databaseId);
    final base =
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/$dbSegment/documents/sync_profiles/$syncId';
    if (!withUpdateMask) {
      return Uri.parse(base);
    }
    return Uri.parse(
      '$base?updateMask.fieldPaths=syncId&updateMask.fieldPaths=updatedAtMs&updateMask.fieldPaths=lastUid&updateMask.fieldPaths=itemsJson',
    );
  }

  Future<T> _withClient<T>(Future<T> Function(http.Client client) action) async {
    if (_customClient != null) {
      return action(_customClient);
    }
    final client = http.Client();
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  Future<bool> _ensureAuth({bool forceRefresh = false}) async {
    if (_inFlightAuthValid(forceRefresh)) {
      return true;
    }
    if (_authFuture != null) {
      return _authFuture!;
    }
    final future = _performAuth(forceRefresh: forceRefresh);
    _authFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_authFuture, future)) {
        _authFuture = null;
      }
    }
  }

  bool _inFlightAuthValid(bool forceRefresh) {
    if (forceRefresh) return false;
    if (_cachedIdToken == null ||
        _cachedIdToken!.isEmpty ||
        _cachedUid == null ||
        _cachedUid!.isEmpty ||
        _cachedExpiresAt == null) {
      return false;
    }
    return DateTime.now()
        .isBefore(_cachedExpiresAt!.subtract(const Duration(minutes: 2)));
  }

  Future<bool> _performAuth({required bool forceRefresh}) async {
    try {
      final prefs = await _getPrefs();
      if (!forceRefresh && _cachedIdToken == null) {
        final raw = prefs.getString(_authStorageKey);
        if (raw != null && raw.trim().isNotEmpty) {
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            _cachedIdToken = map['idToken'] as String?;
            _cachedRefreshToken = map['refreshToken'] as String?;
            _cachedUid = map['uid'] as String?;
            final expMs = map['expiresAtMs'] as int? ?? 0;
            if (expMs > 0) {
              _cachedExpiresAt = DateTime.fromMillisecondsSinceEpoch(expMs);
            }
          } catch (_) {}
        }
      }

      if (!forceRefresh &&
          _cachedIdToken != null &&
          _cachedUid != null &&
          _cachedExpiresAt != null &&
          DateTime.now().isBefore(
            _cachedExpiresAt!.subtract(const Duration(minutes: 2)),
          )) {
        return true;
      }

      if (_cachedRefreshToken != null && _cachedRefreshToken!.isNotEmpty) {
        final refreshed = await _tryRefreshToken(prefs, _cachedRefreshToken!);
        if (refreshed) return true;
      }

      return await _signUpAnonymous(prefs);
    } catch (e) {
      debugPrint('[CLOUD_SYNC] Falha na autenticação anônima: $e');
      return false;
    }
  }

  Future<bool> _tryRefreshToken(
    SharedPreferences prefs,
    String refreshToken,
  ) async {
    try {
      final uri = Uri.parse(
        'https://securetoken.googleapis.com/v1/token?key=$apiKey',
      );
      final resp = await _withClient(
        (client) => client
            .post(
              uri,
              headers: const {'Content-Type': 'application/json; charset=utf-8'},
              body: utf8.encode(
                jsonEncode({
                  'grant_type': 'refresh_token',
                  'refresh_token': refreshToken,
                }),
              ),
            )
            .timeout(const Duration(seconds: 6)),
      );
      if (resp.statusCode != 200) {
        return false;
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final token = (data['id_token'] ?? data['idToken']) as String?;
      final uid = (data['user_id'] ?? data['localId'] ?? _cachedUid) as String?;
      final nextRefresh =
          (data['refresh_token'] ?? data['refreshToken'] ?? refreshToken)
              as String?;
      final expiresSec =
          int.tryParse('${data['expires_in'] ?? data['expiresIn'] ?? '3600'}') ??
          3600;
      if (token == null || token.isEmpty || uid == null || uid.isEmpty) {
        return false;
      }
      await _persistAuth(
        prefs: prefs,
        idToken: token,
        refreshToken: nextRefresh,
        uid: uid,
        expiresInSec: expiresSec,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _signUpAnonymous(SharedPreferences prefs) async {
    final uri = Uri.parse(
      'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$apiKey',
    );
    final resp = await _withClient(
      (client) => client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode({'returnSecureToken': true})),
          )
          .timeout(const Duration(seconds: 6)),
    );
    if (resp.statusCode != 200) {
      debugPrint(
        '[CLOUD_SYNC] signUp anônimo retornou HTTP ${resp.statusCode}',
      );
      return false;
    }
    final data =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final token = (data['idToken'] ?? data['id_token']) as String?;
    final refreshToken =
        (data['refreshToken'] ?? data['refresh_token']) as String?;
    final uid = (data['localId'] ?? data['user_id']) as String?;
    final expiresSec =
        int.tryParse('${data['expiresIn'] ?? data['expires_in'] ?? '3600'}') ??
        3600;
    if (token == null || token.isEmpty || uid == null || uid.isEmpty) {
      return false;
    }
    await _persistAuth(
      prefs: prefs,
      idToken: token,
      refreshToken: refreshToken,
      uid: uid,
      expiresInSec: expiresSec,
    );
    return true;
  }

  Future<void> _persistAuth({
    required SharedPreferences prefs,
    required String idToken,
    required String? refreshToken,
    required String uid,
    required int expiresInSec,
  }) async {
    final expiresAt = DateTime.now().add(Duration(seconds: expiresInSec));
    _cachedIdToken = idToken;
    _cachedRefreshToken = refreshToken;
    _cachedUid = uid;
    _cachedExpiresAt = expiresAt;
    await prefs.setString(
      _authStorageKey,
      jsonEncode({
        'idToken': idToken,
        'refreshToken': refreshToken,
        'uid': uid,
        'expiresAtMs': expiresAt.millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> _invalidateTokenCache() async {
    _cachedIdToken = null;
    _cachedExpiresAt = null;
  }

  Future<Map<String, ContinueWatchingItem>> _loadLedger(
    String effectiveAccountKey,
  ) async {
    final prefs = await _getPrefs();
    final raw = prefs.getString(_ledgerKey(effectiveAccountKey));
    if (raw == null || raw.trim().isEmpty) {
      return {};
    }
    return _decodeItemsMap(raw);
  }

  Future<void> _saveLedger(
    String effectiveAccountKey,
    Map<String, ContinueWatchingItem> map,
  ) async {
    final prefs = await _getPrefs();
    final bounded = _capItemsMap(map);
    final encoded = _encodeBoundedItemsJson(bounded);
    await prefs.setString(_ledgerKey(effectiveAccountKey), encoded);
  }

  Map<String, ContinueWatchingItem> _decodeItemsMap(String rawJson) {
    final result = <String, ContinueWatchingItem>{};
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          try {
            if (entry.value is Map<String, dynamic>) {
              final item = ContinueWatchingItem.fromJson(
                entry.value as Map<String, dynamic>,
              );
              if (item.streamId > 0) {
                result[entry.key] = item;
              }
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return result;
  }

  Map<String, ContinueWatchingItem> _capItemsMap(
    Map<String, ContinueWatchingItem> input,
  ) {
    final entries = input.entries.toList()
      ..sort((a, b) {
        final aTime = _effectiveSortTime(a.value);
        final bTime = _effectiveSortTime(b.value);
        return bTime.compareTo(aTime);
      });
    final out = <String, ContinueWatchingItem>{};
    for (final entry in entries.take(_maxLedgerItems)) {
      out[entry.key] = entry.value;
    }
    return out;
  }

  DateTime _effectiveSortTime(ContinueWatchingItem item) {
    final reset = item.manualResetAt;
    if (reset != null && reset.isAfter(item.updatedAt)) {
      return reset;
    }
    return item.updatedAt;
  }

  String _encodeBoundedItemsJson(Map<String, ContinueWatchingItem> map) {
    final ordered = _capItemsMap(map);
    while (ordered.isNotEmpty) {
      final jsonStr = jsonEncode(
        ordered.map((k, v) => MapEntry(k, v.toJson())),
      );
      if (utf8.encode(jsonStr).length <= _maxItemsJsonBytes) {
        return jsonStr;
      }
      final lastKey = ordered.keys.last;
      ordered.remove(lastKey);
    }
    return '{}';
  }

  /// Persiste imediatamente no ledger local (sem rede) e indica se já pode enviar à nuvem.
  Future<bool> persistLocalLedgerChange({
    required String accountKey,
    required ContinueWatchingItem item,
    bool immediatePush = false,
  }) async {
    if (accountKey.trim().isEmpty || _isDisabledForTests) return false;

    final effectiveKey = _effectiveAccountKey(accountKey);
    final ledger = await _loadLedger(effectiveKey);
    final itemKey = buildItemKey(item);
    final existing = ledger[itemKey];

    var normalizedItem = item;
    if (existing != null &&
        existing.manualResetAt != null &&
        normalizedItem.manualResetAt == null &&
        !normalizedItem.isCompleted) {
      normalizedItem = normalizedItem.copyWith(
        manualResetAt: existing.manualResetAt,
      );
    }

    ledger[itemKey] = existing != null
        ? PlaybackProgressService.pickMoreAdvanced(normalizedItem, existing)
        : normalizedItem;
    await _saveLedger(effectiveKey, ledger);

    final lastPush = _lastPushAt[effectiveKey];
    return immediatePush ||
        lastPush == null ||
        DateTime.now().difference(lastPush) >= _pushThrottleInterval;
  }

  /// Dispara sincronização em segundo plano para [accountKey].
  void triggerBackgroundSync(
    String accountKey, {
    PlaybackProgressService? progressService,
    bool force = false,
  }) {
    if (accountKey.trim().isEmpty || _isDisabledForTests) return;
    unawaited(
      syncAccount(
        accountKey,
        progressService: progressService,
        force: force,
      ).catchError((_) => false),
    );
  }

  /// Registra uma alteração local de progresso/conclusão/reinício no ledger local
  /// e dispara sincronização em nuvem respeitando o intervalo de throttle.
  Future<void> recordLocalChange({
    required String accountKey,
    required ContinueWatchingItem item,
    bool immediatePush = false,
  }) async {
    final canPushNow = await persistLocalLedgerChange(
      accountKey: accountKey,
      item: item,
      immediatePush: immediatePush,
    );
    if (canPushNow) {
      await syncAccount(accountKey, force: immediatePush);
    }
  }

  /// Sincroniza bidirecionalmente o histórico local e remoto para a [accountKey],
  /// aplicando sempre o progresso mais avançado entre Celular e Fire TV.
  /// Retorna `true` caso o armazenamento local tenha sido atualizado pela nuvem.
  Future<bool> syncAccount(
    String accountKey, {
    PlaybackProgressService? progressService,
    bool force = false,
  }) async {
    if (accountKey.trim().isEmpty || _isDisabledForTests) return false;

    final effectiveKey = _effectiveAccountKey(accountKey);
    final existingFuture = _inFlightSyncs[effectiveKey];
    if (existingFuture != null) {
      return existingFuture;
    }

    final lastSync = _lastSyncAt[effectiveKey];
    if (!force &&
        lastSync != null &&
        DateTime.now().difference(lastSync) < _syncCooldown) {
      return false;
    }

    final future = _runSyncAccount(
      accountKey: accountKey,
      effectiveKey: effectiveKey,
      progressService:
          progressService ?? PlaybackProgressService(prefs: _customPrefs),
    );
    _inFlightSyncs[effectiveKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightSyncs[effectiveKey], future)) {
        _inFlightSyncs.remove(effectiveKey);
      }
    }
  }

  Future<bool> _runSyncAccount({
    required String accountKey,
    required String effectiveKey,
    required PlaybackProgressService progressService,
  }) async {
    try {
      final syncId = buildSyncId(effectiveKey);

      // 1. Consolidar estado local ativo + ledger persistido
      final localMap = await _loadLedger(effectiveKey);
      final activeItems =
          await progressService.getContinueWatchingList(accountKey: accountKey);
      for (final active in activeItems) {
        final k = buildItemKey(active);
        final prev = localMap[k];
        if (prev == null) {
          localMap[k] = active;
        } else {
          final carried = (prev.manualResetAt != null &&
                  active.manualResetAt == null &&
                  !active.isCompleted)
              ? active.copyWith(manualResetAt: prev.manualResetAt)
              : active;
          localMap[k] =
              PlaybackProgressService.pickMoreAdvanced(carried, prev);
        }
      }

      // 2. Autenticar silenciosamente e baixar estado remoto do Firestore
      if (!await _ensureAuth()) {
        return false;
      }

      final fetchResult = await _fetchRemoteDoc(syncId);
      if (!fetchResult.success) {
        return false;
      }

      // Recarrega o ledger local para não perder alterações ocorridas durante a requisição HTTP
      final latestLedger = await _loadLedger(effectiveKey);
      for (final entry in latestLedger.entries) {
        final existing = localMap[entry.key];
        localMap[entry.key] = existing != null
            ? PlaybackProgressService.pickMoreAdvanced(entry.value, existing)
            : entry.value;
      }

      final remoteMap = fetchResult.items;
      final mergedMap = <String, ContinueWatchingItem>{};
      final allKeys = <String>{...localMap.keys, ...remoteMap.keys};

      bool localChanged = false;
      bool remoteNeedsPush = !fetchResult.docExists && localMap.isNotEmpty;

      for (final key in allKeys) {
        final localItem = localMap[key];
        final remoteItem = remoteMap[key];

        if (localItem != null && remoteItem != null) {
          final winner =
              PlaybackProgressService.pickMoreAdvanced(localItem, remoteItem);
          mergedMap[key] = winner;

          final remoteWon = _didRemoteWin(localItem, remoteItem, winner);

          if (remoteWon) {
            await progressService.applySyncedItem(
              accountKey: accountKey,
              item: winner,
            );
            localChanged = true;
          }

          if (_itemsDifferSignificantly(remoteItem, winner)) {
            remoteNeedsPush = true;
          }
        } else if (remoteItem != null) {
          mergedMap[key] = remoteItem;
          await progressService.applySyncedItem(
            accountKey: accountKey,
            item: remoteItem,
          );
          localChanged = true;
        } else if (localItem != null) {
          mergedMap[key] = localItem;
          remoteNeedsPush = true;
        }
      }

      final boundedMerged = _capItemsMap(mergedMap);
      await _saveLedger(effectiveKey, boundedMerged);

      if (remoteNeedsPush && boundedMerged.isNotEmpty) {
        final pushed = await _patchRemoteDoc(syncId, boundedMerged);
        if (pushed) {
          _lastPushAt[effectiveKey] = DateTime.now();
        }
      }

      _lastSyncAt[effectiveKey] = DateTime.now();
      return localChanged;
    } catch (e) {
      debugPrint('[CLOUD_SYNC] Falha ao sincronizar conta: $e');
      return false;
    }
  }

  bool _didRemoteWin(
    ContinueWatchingItem local,
    ContinueWatchingItem remote,
    ContinueWatchingItem winner,
  ) {
    final localReset = local.manualResetAt;
    final remoteReset = remote.manualResetAt;
    if (localReset != null &&
        localReset.isAfter(remote.updatedAt) &&
        (remoteReset == null || localReset.isAfter(remoteReset))) {
      return false;
    }
    if (remoteReset != null &&
        remoteReset.isAfter(local.updatedAt) &&
        (localReset == null || remoteReset.isAfter(localReset))) {
      return _itemsDifferSignificantly(local, winner);
    }
    if (PlaybackProgressService.compareAdvancement(local, remote) >= 0) {
      return false;
    }
    return _itemsDifferSignificantly(local, winner);
  }

  bool _itemsDifferSignificantly(
    ContinueWatchingItem baseline,
    ContinueWatchingItem candidate,
  ) {
    if (baseline.streamId != candidate.streamId ||
        (baseline.seasonNumber ?? 1) != (candidate.seasonNumber ?? 1) ||
        (baseline.episodeNum ?? 1) != (candidate.episodeNum ?? 1) ||
        baseline.isCompleted != candidate.isCompleted ||
        baseline.manualResetAt != candidate.manualResetAt) {
      return true;
    }
    return (baseline.position.inMilliseconds - candidate.position.inMilliseconds)
            .abs() >=
        1000;
  }

  Future<_RemoteFetchResult> _fetchRemoteDoc(String syncId) async {
    var retried = false;
    while (true) {
      final token = _cachedIdToken;
      if (token == null || token.isEmpty) {
        return const _RemoteFetchResult.failure();
      }
      final resp = await _withClient(
        (client) => client.get(
          _documentUri(syncId),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 5)),
      );
      if (resp.statusCode == 401 && !retried) {
        retried = true;
        await _invalidateTokenCache();
        if (!await _ensureAuth(forceRefresh: true)) {
          return const _RemoteFetchResult.failure();
        }
        continue;
      }
      if (resp.statusCode == 404) {
        return const _RemoteFetchResult(
          success: true,
          docExists: false,
          items: {},
        );
      }
      if (resp.statusCode != 200) {
        debugPrint('[CLOUD_SYNC] GET remoto HTTP ${resp.statusCode}');
        return const _RemoteFetchResult.failure();
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final fields = data['fields'] as Map<String, dynamic>? ?? {};
      final itemsField = fields['itemsJson'] as Map<String, dynamic>?;
      final itemsRaw = itemsField?['stringValue'] as String? ?? '{}';
      return _RemoteFetchResult(
        success: true,
        docExists: true,
        items: _decodeItemsMap(itemsRaw),
      );
    }
  }

  Future<bool> _patchRemoteDoc(
    String syncId,
    Map<String, ContinueWatchingItem> items,
  ) async {
    var retried = false;
    while (true) {
      final token = _cachedIdToken;
      final uid = _cachedUid;
      if (token == null || token.isEmpty || uid == null || uid.isEmpty) {
        return false;
      }
      final itemsJson = _encodeBoundedItemsJson(items);
      final body = jsonEncode({
        'fields': {
          'syncId': {'stringValue': syncId},
          'updatedAtMs': {
            'integerValue': '${DateTime.now().millisecondsSinceEpoch}',
          },
          'lastUid': {'stringValue': uid},
          'itemsJson': {'stringValue': itemsJson},
        },
      });
      final resp = await _withClient(
        (client) => client
            .patch(
              _documentUri(syncId, withUpdateMask: true),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: utf8.encode(body),
            )
            .timeout(const Duration(seconds: 6)),
      );
      if (resp.statusCode == 401 && !retried) {
        retried = true;
        await _invalidateTokenCache();
        if (!await _ensureAuth(forceRefresh: true)) {
          return false;
        }
        continue;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[CLOUD_SYNC] PATCH remoto HTTP ${resp.statusCode}');
        return false;
      }
      return true;
    }
  }
}

class _RemoteFetchResult {
  final bool success;
  final bool docExists;
  final Map<String, ContinueWatchingItem> items;

  const _RemoteFetchResult({
    required this.success,
    required this.docExists,
    required this.items,
  });

  const _RemoteFetchResult.failure()
    : success = false,
      docExists = false,
      items = const {};
}
