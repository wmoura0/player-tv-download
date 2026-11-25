import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/xtream_series_info.dart';
import 'cloud_progress_sync_service.dart';
import 'series_identity_verifier.dart';
import 'user_profile_service.dart';
import 'xtream_auth_service.dart';

/// Representação do progresso de reprodução salvo para um filme.
class PlaybackProgress {
  final int streamId;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const PlaybackProgress({
    required this.streamId,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  /// Considera o filme concluído quando faltam menos de 45 segundos ou atingiu mais de 96%
  bool get isCompleted {
    if (duration.inSeconds <= 0) return false;
    final remainingSecs = duration.inSeconds - position.inSeconds;
    return remainingSecs <= 45 || (position.inSeconds / duration.inSeconds) >= 0.96;
  }

  /// Oferece retomar somente se assistiu pelo menos 10 segundos e ainda não concluiu
  bool get canResume {
    return position.inSeconds >= 10 && !isCompleted;
  }
}

/// Tipo de conteúdo no índice de continuar assistindo
enum ContinueWatchingType { movie, series }

/// Item do índice consolidado "Continuar Assistindo" para a tela inicial
class ContinueWatchingItem {
  final int streamId; // streamId do filme ou episodeId da série
  final int? seriesId; // seriesId quando for série
  final ContinueWatchingType type;
  final String title;
  final String? subtitle; // Ex: 'T1:E2'
  final String? coverUrl;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final String? containerExtension;
  final String? categoryId;
  final int? seasonNumber;
  final int? episodeNum;
  final DateTime? manualResetAt;
  final DateTime? hiddenFromHomeAt;
  final DateTime? completedAt;
  final DateTime? historyClearedAt;

  const ContinueWatchingItem({
    required this.streamId,
    this.seriesId,
    required this.type,
    required this.title,
    this.subtitle,
    this.coverUrl,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.containerExtension,
    this.categoryId,
    this.seasonNumber,
    this.episodeNum,
    this.manualResetAt,
    this.hiddenFromHomeAt,
    this.completedAt,
    this.historyClearedAt,
  });

  ContinueWatchingItem copyWith({
    int? streamId,
    int? seriesId,
    ContinueWatchingType? type,
    String? title,
    String? subtitle,
    String? coverUrl,
    Duration? position,
    Duration? duration,
    DateTime? updatedAt,
    String? containerExtension,
    String? categoryId,
    int? seasonNumber,
    int? episodeNum,
    DateTime? manualResetAt,
    bool clearManualResetAt = false,
    DateTime? hiddenFromHomeAt,
    bool clearHiddenFromHomeAt = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? historyClearedAt,
    bool clearHistoryClearedAt = false,
  }) {
    return ContinueWatchingItem(
      streamId: streamId ?? this.streamId,
      seriesId: seriesId ?? this.seriesId,
      type: type ?? this.type,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      coverUrl: coverUrl ?? this.coverUrl,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      updatedAt: updatedAt ?? this.updatedAt,
      containerExtension: containerExtension ?? this.containerExtension,
      categoryId: categoryId ?? this.categoryId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNum: episodeNum ?? this.episodeNum,
      manualResetAt:
          clearManualResetAt ? null : (manualResetAt ?? this.manualResetAt),
      hiddenFromHomeAt: clearHiddenFromHomeAt
          ? null
          : (hiddenFromHomeAt ?? this.hiddenFromHomeAt),
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      historyClearedAt: clearHistoryClearedAt
          ? null
          : (historyClearedAt ?? this.historyClearedAt),
    );
  }

  double get progressRatio {
    if (duration.inMilliseconds <= 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool get isHiddenFromHome => hiddenFromHomeAt != null;
  bool get isHistoryCleared => historyClearedAt != null;

  bool get isCompleted {
    if (completedAt != null) return true;
    if (duration.inSeconds <= 0) return false;
    final remainingSecs = duration.inSeconds - position.inSeconds;
    return remainingSecs <= 45 || (position.inSeconds / duration.inSeconds) >= 0.96;
  }

  bool get canResume {
    if (isCompleted || isHiddenFromHome || isHistoryCleared) return false;
    if (position.inSeconds >= 10) return true;
    // Séries com próximo episódio promovido com posição inicial zero podem ser retomadas
    if (type == ContinueWatchingType.series &&
        position == Duration.zero &&
        (episodeNum ?? 0) >= 1) {
      return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'streamId': streamId,
        'seriesId': seriesId,
        'type': type.name,
        'title': title,
        'subtitle': subtitle,
        'coverUrl': coverUrl,
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': updatedAt.millisecondsSinceEpoch,
        'containerExtension': containerExtension,
        'categoryId': categoryId,
        'seasonNumber': seasonNumber,
        'episodeNum': episodeNum,
        if (manualResetAt != null)
          'manualResetAt': manualResetAt!.millisecondsSinceEpoch,
        if (hiddenFromHomeAt != null)
          'hiddenFromHomeAt': hiddenFromHomeAt!.millisecondsSinceEpoch,
        if (completedAt != null)
          'completedAt': completedAt!.millisecondsSinceEpoch,
        if (historyClearedAt != null)
          'historyClearedAt': historyClearedAt!.millisecondsSinceEpoch,
      };

  factory ContinueWatchingItem.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'movie';
    final type =
        typeStr == 'series' ? ContinueWatchingType.series : ContinueWatchingType.movie;
    final posMs = json['pos'] as int? ?? 0;
    final durMs = json['dur'] as int? ?? 0;
    final timeMs = json['time'] as int? ?? 0;
    final resetMs = json['manualResetAt'] as int?;
    final hiddenMs = json['hiddenFromHomeAt'] as int?;
    final completedMs = json['completedAt'] as int?;
    final clearedMs = json['historyClearedAt'] as int?;

    return ContinueWatchingItem(
      streamId: json['streamId'] as int? ?? 0,
      seriesId: json['seriesId'] as int?,
      type: type,
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      coverUrl: json['coverUrl'] as String?,
      position: Duration(milliseconds: posMs),
      duration: Duration(milliseconds: durMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      containerExtension: json['containerExtension'] as String?,
      categoryId: json['categoryId']?.toString(),
      seasonNumber: json['seasonNumber'] as int?,
      episodeNum: json['episodeNum'] as int?,
      manualResetAt: (resetMs != null && resetMs > 0)
          ? DateTime.fromMillisecondsSinceEpoch(resetMs)
          : null,
      hiddenFromHomeAt: (hiddenMs != null && hiddenMs > 0)
          ? DateTime.fromMillisecondsSinceEpoch(hiddenMs)
          : null,
      completedAt: (completedMs != null && completedMs > 0)
          ? DateTime.fromMillisecondsSinceEpoch(completedMs)
          : null,
      historyClearedAt: (clearedMs != null && clearedMs > 0)
          ? DateTime.fromMillisecondsSinceEpoch(clearedMs)
          : null,
    );
  }
}

/// Serviço responsável por persistir e recuperar o progresso de filmes (VOD) e séries
/// de forma associada à conta/servidor/perfil ativo, evitando conflito entre servidores.
class PlaybackProgressService {
  final SharedPreferences? prefs;

  PlaybackProgressService({this.prefs});

  Future<SharedPreferences> _getPrefs() async {
    return prefs ?? await SharedPreferences.getInstance();
  }

  /// Gera a chave de escopo da conta/servidor normalizando barra final e esquema.
  static String buildAccountKey(String serverUrl, String username) {
    final rawServer = serverUrl.trim();
    final normalizedServer = rawServer.isNotEmpty
        ? XtreamAuthService.normalizeServerUrl(rawServer)
        : '';
    final cleanServer =
        normalizedServer.toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final cleanUser =
        username.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return '${cleanServer}_$cleanUser';
  }

  /// Extrai temporada e episódio a partir de um subtítulo amigável quando os campos numéricos falharem.
  static (int? season, int? episode) parseSeasonEpisodeFromSubtitle(
    String? subtitle,
  ) {
    if (subtitle == null || subtitle.trim().isEmpty) return (null, null);
    final sub = subtitle.trim();
    final regExp1 = RegExp(
      r'(?:[sStT]|temp|temporada)[\s.:xX\-]*(\d+)[\s.,:xXeE\-_|•]+(?:[eE]|ep|episodio|episódio)?[\s.:xX\-]*(\d+)',
      caseSensitive: false,
    );
    final regExp2 = RegExp(r'(\d+)[\s]*[xX][\s]*(\d+)');
    final regExp3 = RegExp(
      r'(?:[eE]|ep|episodio|episódio)[\s.:xX\-]*(\d+)',
      caseSensitive: false,
    );

    final match1 = regExp1.firstMatch(sub);
    if (match1 != null) {
      return (int.tryParse(match1.group(1)!), int.tryParse(match1.group(2)!));
    }
    final match2 = regExp2.firstMatch(sub);
    if (match2 != null) {
      return (int.tryParse(match2.group(1)!), int.tryParse(match2.group(2)!));
    }
    final match3 = regExp3.firstMatch(sub);
    if (match3 != null) {
      return (null, int.tryParse(match3.group(1)!));
    }
    return (null, null);
  }

  String _effectiveAccountKey(String accountKey) {
    return UserProfileService.instance.getScopedKey(accountKey);
  }

  String _buildStorageKeyForEffective(String effective, int streamId) {
    return 'vod_prog_${effective}_$streamId';
  }

  String _buildStorageKey(String accountKey, int streamId) {
    return _buildStorageKeyForEffective(_effectiveAccountKey(accountKey), streamId);
  }

  /// Salva a posição assistida de um filme.
  /// Se o filme estiver próximo do final, remove a chave para não retomar nos créditos finais.
  Future<void> saveProgress({
    required String accountKey,
    required int streamId,
    required Duration position,
    required Duration duration,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);

    final progress = PlaybackProgress(
      streamId: streamId,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );

    // Se estiver praticamente finalizado, limpa a posição salva
    if (progress.isCompleted) {
      await prefs.remove(key);
      return;
    }

    // Proteção contra gravações antigas concorrentes
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        final existing = jsonDecode(raw);
        final existingTime = existing['time'] as int?;
        if (existingTime != null && existingTime > progress.updatedAt.millisecondsSinceEpoch) {
          return;
        }
      } catch (_) {}
    }

    // Só grava se tiver assistido pelo menos 10 segundos
    if (position.inSeconds >= 10) {
      final data = {
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': progress.updatedAt.millisecondsSinceEpoch,
      };
      await prefs.setString(key, jsonEncode(data));
    }
  }

  /// Recupera o progresso de um filme. Retorna nulo se não houver progresso válido para retomar.
  Future<PlaybackProgress?> getProgress({
    required String accountKey,
    required int streamId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final posMs = data['pos'] as int? ?? 0;
      final durMs = data['dur'] as int? ?? 0;
      final timeMs = data['time'] as int? ?? 0;

      final progress = PlaybackProgress(
        streamId: streamId,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      );

      if (progress.canResume) {
        return progress;
      } else {
        // Se já concluiu ou tem menos de 10s, limpa do storage
        await prefs.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Limpa o progresso salvo de um filme (ex.: ao escolher "Assistir do início")
  Future<void> clearProgress({
    required String accountKey,
    required int streamId,
  }) async {
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);
    final key = _buildStorageKeyForEffective(effective, streamId);
    await prefs.remove(key);
    await _clearSuppressionEntry(
      prefs,
      mapKey: _buildHiddenMapKeyForEffective(effective),
      type: ContinueWatchingType.movie,
      id: streamId,
    );
    await _clearSuppressionEntry(
      prefs,
      mapKey: _buildClearedMapKeyForEffective(effective),
      type: ContinueWatchingType.movie,
      id: streamId,
    );

    final listKey = _buildContinueWatchingKeyForEffective(effective);
    final rawList = prefs.getStringList(listKey) ?? [];
    ContinueWatchingItem? existingItem;
    final filtered = <String>[];
    for (final raw in rawList) {
      try {
        final item = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (item.type == ContinueWatchingType.movie && item.streamId == streamId) {
          existingItem = item;
          continue;
        }
        filtered.add(raw);
      } catch (_) {}
    }
    if (existingItem != null) {
      await prefs.setStringList(listKey, filtered);
    }

    final now = _monotonicNowAfter(existingItem?.updatedAt);
    final resetItem = (existingItem ??
            ContinueWatchingItem(
              streamId: streamId,
              type: ContinueWatchingType.movie,
              title: 'VOD #$streamId',
              position: Duration.zero,
              duration: Duration.zero,
              updatedAt: now,
            ))
        .copyWith(
      position: Duration.zero,
      duration: Duration.zero,
      updatedAt: now,
      manualResetAt: now,
      clearHiddenFromHomeAt: true,
      clearCompletedAt: true,
      clearHistoryClearedAt: true,
    );
    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: resetItem,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  // =========================================================================
  // PROGRESSO DE EPISÓDIOS DE SÉRIES (Isolado por conta, série e episódio)
  // =========================================================================

  String _buildEpisodeStorageKeyForEffective(
    String effective,
    int seriesId,
    int episodeId,
  ) {
    return 'series_prog_${effective}_${seriesId}_$episodeId';
  }

  String _buildEpisodeStorageKey(String accountKey, int seriesId, int episodeId) {
    return _buildEpisodeStorageKeyForEffective(
      _effectiveAccountKey(accountKey),
      seriesId,
      episodeId,
    );
  }

  String _buildSeriesLastKeyForEffective(String effective, int seriesId) {
    return 'series_last_${effective}_$seriesId';
  }

  String _buildSeriesLastKey(String accountKey, int seriesId) {
    return _buildSeriesLastKeyForEffective(_effectiveAccountKey(accountKey), seriesId);
  }

  String _buildHiddenMapKeyForEffective(String effective) =>
      'cw_hidden_v1_$effective';

  String _buildClearedMapKeyForEffective(String effective) =>
      'cw_cleared_v1_$effective';

  String _suppressionItemKey(ContinueWatchingType type, int id) =>
      '${type.name}#$id';

  DateTime _monotonicNowAfter(DateTime? previous) {
    final now = DateTime.now();
    if (previous != null && !now.isAfter(previous)) {
      return DateTime.fromMillisecondsSinceEpoch(previous.millisecondsSinceEpoch + 1);
    }
    return now;
  }

  Future<Map<String, int>> _loadSuppressionMap(
    SharedPreferences prefs,
    String mapKey,
  ) async {
    final raw = prefs.getString(mapKey);
    if (raw == null || raw.trim().isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final out = <String, int>{};
        decoded.forEach((k, v) {
          final ts = v is int ? v : int.tryParse(v.toString());
          if (ts != null && ts > 0) {
            out[k.toString()] = ts;
          }
        });
        return out;
      }
    } catch (_) {}
    return <String, int>{};
  }

  Future<void> _setSuppressionTimestamp(
    SharedPreferences prefs, {
    required String mapKey,
    required ContinueWatchingType type,
    required int id,
    required DateTime timestamp,
  }) async {
    final map = await _loadSuppressionMap(prefs, mapKey);
    final k = _suppressionItemKey(type, id);
    final existing = map[k] ?? 0;
    final nextMs = timestamp.millisecondsSinceEpoch;
    if (nextMs >= existing) {
      map[k] = nextMs;
      await prefs.setString(mapKey, jsonEncode(map));
    }
  }

  Future<void> _clearSuppressionEntry(
    SharedPreferences prefs, {
    required String mapKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    final map = await _loadSuppressionMap(prefs, mapKey);
    if (map.remove(_suppressionItemKey(type, id)) != null) {
      await prefs.setString(mapKey, jsonEncode(map));
    }
  }

  /// Retorna quando o item foi explicitamente ocultado da Home (se ativo).
  Future<DateTime?> getHiddenFromHomeAt({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
    String? effectiveAccountKeyOverride,
  }) async {
    if (accountKey.trim().isEmpty) return null;
    final prefs = await _getPrefs();
    final effective = effectiveAccountKeyOverride ?? _effectiveAccountKey(accountKey);
    final map = await _loadSuppressionMap(
      prefs,
      _buildHiddenMapKeyForEffective(effective),
    );
    final ms = map[_suppressionItemKey(type, id)];
    return (ms != null && ms > 0) ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Retorna quando o histórico do item foi explicitamente apagado (se ativo).
  Future<DateTime?> getHistoryClearedAt({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
    String? effectiveAccountKeyOverride,
  }) async {
    if (accountKey.trim().isEmpty) return null;
    final prefs = await _getPrefs();
    final effective = effectiveAccountKeyOverride ?? _effectiveAccountKey(accountKey);
    final map = await _loadSuppressionMap(
      prefs,
      _buildClearedMapKeyForEffective(effective),
    );
    final ms = map[_suppressionItemKey(type, id)];
    return (ms != null && ms > 0) ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Indica se o card foi ocultado manualmente da Home no perfil/conta atual.
  Future<bool> isHiddenFromHome({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    return (await getHiddenFromHomeAt(
          accountKey: accountKey,
          type: type,
          id: id,
        )) !=
        null;
  }

  /// Salva a posição assistida de um episódio de série.
  Future<void> saveEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
    required Duration position,
    required Duration duration,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);

    final progress = PlaybackProgress(
      streamId: episodeId,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );

    // Se estiver praticamente finalizado, limpa a posição salva
    if (progress.isCompleted) {
      await prefs.remove(key);
      return;
    }

    // Proteção contra gravações antigas concorrentes
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        final existing = jsonDecode(raw);
        final existingTime = existing['time'] as int?;
        if (existingTime != null && existingTime > progress.updatedAt.millisecondsSinceEpoch) {
          return;
        }
      } catch (_) {}
    }

    // Só grava se tiver assistido pelo menos 10 segundos
    if (position.inSeconds >= 10) {
      final data = {
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': progress.updatedAt.millisecondsSinceEpoch,
      };
      await prefs.setString(key, jsonEncode(data));
    }
  }

  /// Recupera o progresso de um episódio de série. Retorna nulo se não houver progresso válido para retomar.
  Future<PlaybackProgress?> getEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final posMs = data['pos'] as int? ?? 0;
      final durMs = data['dur'] as int? ?? 0;
      final timeMs = data['time'] as int? ?? 0;

      final progress = PlaybackProgress(
        streamId: episodeId,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      );

      if (progress.canResume) {
        return progress;
      } else {
        await prefs.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Limpa o progresso salvo de um episódio de série.
  Future<void> clearEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);
    await prefs.remove(key);
  }

  /// Salva a referência do último episódio assistido em uma série.
  Future<void> saveLastWatchedEpisode({
    required String accountKey,
    required int seriesId,
    required int episodeId,
    required int seasonNumber,
    required int episodeNum,
    bool isPromotedNext = false,
    bool isCompleted = false,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildSeriesLastKey(accountKey, seriesId);
    final data = {
      'episodeId': episodeId,
      'seasonNumber': seasonNumber,
      'episodeNum': episodeNum,
      'isPromotedNext': isPromotedNext,
      'isCompleted': isCompleted,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(key, jsonEncode(data));
  }

  Future<Map<String, int>?> _getLastWatchedEpisodeByEffective(
    SharedPreferences prefs,
    String effective,
    int seriesId,
  ) async {
    final key = _buildSeriesLastKeyForEffective(effective, seriesId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      return {
        'episodeId': data['episodeId'] as int? ?? 0,
        'seasonNumber': data['seasonNumber'] as int? ?? 1,
        'episodeNum': data['episodeNum'] as int? ?? 1,
        'isPromotedNext': (data['isPromotedNext'] == true ? 1 : 0),
        'isCompleted': (data['isCompleted'] == true ? 1 : 0),
        'time': data['time'] as int? ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  /// Recupera o último episódio assistido em uma série.
  Future<Map<String, int>?> getLastWatchedEpisode({
    required String accountKey,
    required int seriesId,
  }) async {
    final prefs = await _getPrefs();
    return _getLastWatchedEpisodeByEffective(
      prefs,
      _effectiveAccountKey(accountKey),
      seriesId,
    );
  }

  /// Fallback P6: tenta recuperar o episódio/posição assistidos para [seriesId]
  /// a partir do índice Continuar Assistindo, do ledger na nuvem ou de entradas
  /// `series_last_*` com título idêntico (em casos de reindexação ou ID antigo).
  Future<Map<String, int>?> findSeriesProgressFallback({
    required String accountKey,
    required int seriesId,
    required String seriesName,
    XtreamSeriesInfo? seriesInfo,
  }) async {
    if (accountKey.trim().isEmpty) return null;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);

    ContinueWatchingItem? bestCandidate;

    bool matchesSeriesIdentity(ContinueWatchingItem item) {
      if (item.type != ContinueWatchingType.series) return false;
      if ((item.seriesId ?? item.streamId) == seriesId && seriesId > 0) {
        return true;
      }
      if (seriesName.trim().isEmpty || item.title.trim().isEmpty) {
        return false;
      }
      return SeriesIdentityVerifier.areSameSeriesIdentity(seriesName, item.title);
    }

    // 1. Verifica itens locais ativos em continue_watching
    final rawCw = prefs.getStringList(_buildContinueWatchingKeyForEffective(effective)) ?? [];
    for (final raw in rawCw) {
      try {
        final item = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (!matchesSeriesIdentity(item)) continue;
        if (item.isHistoryCleared || item.manualResetAt != null) continue;
        if (bestCandidate == null ||
            compareAdvancement(item, bestCandidate) > 0) {
          bestCandidate = item;
        }
      } catch (_) {}
    }

    // 2. Verifica ledger de sincronização na nuvem (inclui itens ocultados da Home que preservaram progresso)
    final ledger = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);
    for (final item in ledger.values) {
      if (!matchesSeriesIdentity(item)) continue;
      if (item.isHistoryCleared) continue;
      if (item.manualResetAt != null &&
          !item.manualResetAt!.isBefore(item.updatedAt)) {
        continue;
      }
      if (bestCandidate == null ||
          compareAdvancement(item, bestCandidate) > 0) {
        bestCandidate = item;
      }
    }

    if (bestCandidate != null) {
      final parsedSub = (bestCandidate.seasonNumber == null ||
              bestCandidate.episodeNum == null)
          ? parseSeasonEpisodeFromSubtitle(bestCandidate.subtitle)
          : (null, null);
      var season = bestCandidate.seasonNumber ?? parsedSub.$1 ?? 1;
      var epNum = bestCandidate.episodeNum ?? parsedSub.$2 ?? 1;
      var epId = bestCandidate.streamId;

      if (seriesInfo != null) {
        final byId = epId > 0 ? seriesInfo.findEpisodeById(epId) : null;
        final bySN = seriesInfo.findEpisodeBySeasonAndNum(season, epNum);
        final resolved = byId ?? bySN;
        if (resolved != null) {
          epId = resolved.id;
          season = resolved.seasonNumber;
          epNum = resolved.episodeNum;
        }
      }

      final isPromotedNext = bestCandidate.position == Duration.zero &&
          bestCandidate.completedAt == null &&
          epNum >= 1;
      final isCompleted = bestCandidate.completedAt != null ||
          (bestCandidate.duration.inSeconds > 0 && bestCandidate.isCompleted);

      return {
        'episodeId': epId,
        'seasonNumber': season,
        'episodeNum': epNum,
        'isPromotedNext': isPromotedNext ? 1 : 0,
        'isCompleted': isCompleted ? 1 : 0,
        'positionSeconds': bestCandidate.position.inSeconds,
        'durationSeconds': bestCandidate.duration.inSeconds,
        'time': bestCandidate.updatedAt.millisecondsSinceEpoch,
      };
    }

    // 3. Por fim, se houver series_last_* sob mesmo título no ledger/catálogo (ou próprio seriesId)
    final directLast = await _getLastWatchedEpisodeByEffective(prefs, effective, seriesId);
    if (directLast != null) {
      final epId = directLast['episodeId'] ?? 0;
      final prog = epId > 0
          ? await getEpisodeProgress(
              accountKey: accountKey,
              seriesId: seriesId,
              episodeId: epId,
            )
          : null;
      return {
        ...directLast,
        'positionSeconds': prog?.position.inSeconds ?? 0,
        'durationSeconds': prog?.duration.inSeconds ?? 0,
      };
    }

    return null;
  }

  /// Migra de forma não-destrutiva o progresso salvo de [oldSeriesId] para [newSeriesId].
  /// Os registros originais em [oldSeriesId] permanecem intactos para segurança e rollback.
  Future<void> migrateSeriesProgressNonDestructively({
    required String accountKey,
    required int oldSeriesId,
    required int newSeriesId,
    required String seriesName,
    String? coverUrl,
    XtreamSeriesInfo? newSeriesInfo,
  }) async {
    if (accountKey.trim().isEmpty ||
        oldSeriesId <= 0 ||
        newSeriesId <= 0 ||
        oldSeriesId == newSeriesId) {
      return;
    }
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);

    // 1. Copiar series_last mantendo histórico original intacto
    final oldLast = await _getLastWatchedEpisodeByEffective(prefs, effective, oldSeriesId);
    if (oldLast != null) {
      final existingNewLast = await _getLastWatchedEpisodeByEffective(prefs, effective, newSeriesId);
      final oldTime = oldLast['time'] ?? 0;
      final newTime = existingNewLast?['time'] ?? 0;
      if (existingNewLast == null || oldTime > newTime) {
        final oldSeason = oldLast['seasonNumber'] ?? 1;
        final oldEpNum = oldLast['episodeNum'] ?? 1;
        var targetEpId = oldLast['episodeId'] ?? 0;
        if (newSeriesInfo != null) {
          final mapped = newSeriesInfo.findEpisodeBySeasonAndNum(oldSeason, oldEpNum) ??
              (targetEpId > 0 ? newSeriesInfo.findEpisodeById(targetEpId) : null);
          if (mapped != null) {
            targetEpId = mapped.id;
          }
        }
        final newLastKey = _buildSeriesLastKeyForEffective(effective, newSeriesId);
        await prefs.setString(
          newLastKey,
          jsonEncode({
            'episodeId': targetEpId,
            'seasonNumber': oldSeason,
            'episodeNum': oldEpNum,
            'isPromotedNext': oldLast['isPromotedNext'] == 1,
            'isCompleted': oldLast['isCompleted'] == 1,
            'time': oldTime,
          }),
        );
      }
    }

    // 2. Copiar todas as posições salvas de episódios (sem apagar as antigas)
    final oldEpPrefix = 'series_prog_${effective}_${oldSeriesId}_';
    for (final k in prefs.getKeys()) {
      if (!k.startsWith(oldEpPrefix)) continue;
      final epIdStr = k.substring(oldEpPrefix.length);
      final oldEpId = int.tryParse(epIdStr);
      if (oldEpId == null || oldEpId <= 0) continue;
      final raw = prefs.getString(k);
      if (raw == null || raw.trim().isEmpty) continue;

      int targetEpId = oldEpId;
      if (newSeriesInfo != null && newSeriesInfo.findEpisodeById(oldEpId) == null) {
        if (oldLast != null && oldLast['episodeId'] == oldEpId) {
          final mapped = newSeriesInfo.findEpisodeBySeasonAndNum(
            oldLast['seasonNumber'] ?? 1,
            oldLast['episodeNum'] ?? 1,
          );
          if (mapped != null) {
            targetEpId = mapped.id;
          }
        }
      }

      final destKey = _buildEpisodeStorageKeyForEffective(effective, newSeriesId, targetEpId);
      final existingDest = prefs.getString(destKey);
      if (existingDest == null) {
        await prefs.setString(destKey, raw);
      }
    }

    // 3. Copiar card ativo do Continuar Assistindo se houver (respeitando ocultação)
    final cwList = await getContinueWatchingList(
      accountKey: accountKey,
      effectiveAccountKeyOverride: effective,
    );
    ContinueWatchingItem? oldCard;
    for (final item in cwList) {
      if (item.type == ContinueWatchingType.series &&
          (item.seriesId ?? item.streamId) == oldSeriesId) {
        oldCard = item;
        break;
      }
    }
    if (oldCard != null) {
      var targetStreamId = oldCard.streamId;
      if (newSeriesInfo != null) {
        final s = oldCard.seasonNumber ?? 1;
        final e = oldCard.episodeNum ?? 1;
        final mapped = newSeriesInfo.findEpisodeBySeasonAndNum(s, e) ??
            newSeriesInfo.findEpisodeById(oldCard.streamId);
        if (mapped != null) {
          targetStreamId = mapped.id;
        }
      }
      final migratedCard = oldCard.copyWith(
        seriesId: newSeriesId,
        streamId: targetStreamId,
        coverUrl: coverUrl ?? oldCard.coverUrl,
      );
      await saveContinueWatchingItem(
        accountKey: accountKey,
        item: migratedCard,
        isRealPlayback: false,
      );
    }
  }

  // =========================================================================
  // ÍNDICE COMPLEMENTAR: CONTINUAR ASSISTINDO (HOME)
  // =========================================================================

  String _buildContinueWatchingKeyForEffective(String effective) {
    return 'continue_watching_$effective';
  }

  /// Recupera a lista de conteúdos com progresso útil para continuar assistindo.
  /// Conteúdos concluídos, ocultados ou limpos são filtrados automaticamente.
  Future<List<ContinueWatchingItem>> getContinueWatchingList({
    required String accountKey,
    String? effectiveAccountKeyOverride,
  }) async {
    if (accountKey.trim().isEmpty) return [];
    final prefs = await _getPrefs();
    final effective = effectiveAccountKeyOverride ?? _effectiveAccountKey(accountKey);
    final key = _buildContinueWatchingKeyForEffective(effective);
    final rawList = prefs.getStringList(key) ?? [];
    final hiddenMap = await _loadSuppressionMap(
      prefs,
      _buildHiddenMapKeyForEffective(effective),
    );
    final clearedMap = await _loadSuppressionMap(
      prefs,
      _buildClearedMapKeyForEffective(effective),
    );

    final result = <ContinueWatchingItem>[];
    for (final raw in rawList) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final item = ContinueWatchingItem.fromJson(map);
        if (!item.canResume || item.title.isEmpty) continue;
        final itemId = item.type == ContinueWatchingType.movie
            ? item.streamId
            : (item.seriesId ?? item.streamId);
        final supKey = _suppressionItemKey(item.type, itemId);
        final hiddenAt = hiddenMap[supKey];
        final clearedAt = clearedMap[supKey];
        if ((hiddenAt != null && hiddenAt >= item.updatedAt.millisecondsSinceEpoch) ||
            (clearedAt != null && clearedAt >= item.updatedAt.millisecondsSinceEpoch)) {
          continue;
        }
        result.add(item);
      } catch (_) {}
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// Salva ou atualiza um item no índice de continuar assistindo.
  /// Quando [isRealPlayback] for `false`, respeita estritamente itens ocultados ou limpos.
  Future<void> saveContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingItem item,
    bool isRealPlayback = true,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);
    final key = _buildContinueWatchingKeyForEffective(effective);
    final hiddenKey = _buildHiddenMapKeyForEffective(effective);
    final clearedKey = _buildClearedMapKeyForEffective(effective);

    final itemId = item.type == ContinueWatchingType.movie
        ? item.streamId
        : (item.seriesId ?? item.streamId);
    final supKey = _suppressionItemKey(item.type, itemId);
    final hiddenMap = await _loadSuppressionMap(prefs, hiddenKey);
    final clearedMap = await _loadSuppressionMap(prefs, clearedKey);
    final hiddenMs = hiddenMap[supKey];
    final clearedMs = clearedMap[supKey];

    if (!isRealPlayback) {
      if (hiddenMs != null ||
          clearedMs != null ||
          item.isHiddenFromHome ||
          item.isHistoryCleared) {
        return;
      }
      final ledger = await CloudProgressSyncService.instance
          .loadLocalLedgerForReconciliation(accountKey);
      final ledgerKey = '${item.type.name}_$itemId';
      final ledgerItem = ledger[ledgerKey];
      if (ledgerItem != null &&
          (ledgerItem.isHiddenFromHome ||
              ledgerItem.isHistoryCleared ||
              ledgerItem.completedAt != null ||
              (ledgerItem.manualResetAt != null &&
                  !ledgerItem.manualResetAt!.isBefore(item.updatedAt)))) {
        return;
      }
    }

    var effectiveItem = item;
    final maxSupMs = [
      ?hiddenMs,
      ?clearedMs,
    ].fold<int>(0, (prev, elem) => elem > prev ? elem : prev);

    if (isRealPlayback &&
        !effectiveItem.isHiddenFromHome &&
        !effectiveItem.isHistoryCleared &&
        !effectiveItem.isCompleted &&
        effectiveItem.manualResetAt == null) {
      // Se havia ocultação/limpeza anterior e ocorreu reprodução real (>=10s ou próximo promovido),
      // remove a supressão e garante timestamp estritamente posterior para sobrepor na nuvem.
      if (maxSupMs > 0) {
        if (effectiveItem.updatedAt.millisecondsSinceEpoch < maxSupMs &&
            !effectiveItem.canResume) {
          return;
        }
        await _clearSuppressionEntry(prefs, mapKey: hiddenKey, type: item.type, id: itemId);
        await _clearSuppressionEntry(prefs, mapKey: clearedKey, type: item.type, id: itemId);
        if (effectiveItem.updatedAt.millisecondsSinceEpoch <= maxSupMs) {
          effectiveItem = effectiveItem.copyWith(
            updatedAt: DateTime.fromMillisecondsSinceEpoch(maxSupMs + 1),
            clearHiddenFromHomeAt: true,
            clearHistoryClearedAt: true,
            clearCompletedAt: true,
          );
        }
      }
    } else if (maxSupMs > 0 &&
        effectiveItem.updatedAt.millisecondsSinceEpoch <= maxSupMs) {
      return;
    }

    final currentList = await getContinueWatchingList(
      accountKey: accountKey,
      effectiveAccountKeyOverride: effective,
    );
    final existingIndex = currentList.indexWhere((i) {
      if (i.type == effectiveItem.type) {
        if (effectiveItem.type == ContinueWatchingType.movie) {
          return i.streamId == effectiveItem.streamId;
        } else {
          return (i.seriesId ?? i.streamId) ==
              (effectiveItem.seriesId ?? effectiveItem.streamId);
        }
      }
      return false;
    });
    final existingItem = existingIndex >= 0 ? currentList[existingIndex] : null;

    if (existingItem != null &&
        existingItem.manualResetAt != null &&
        effectiveItem.manualResetAt == null &&
        !effectiveItem.isCompleted &&
        !isRealPlayback) {
      effectiveItem = effectiveItem.copyWith(
        manualResetAt: existingItem.manualResetAt,
      );
    }

    // Proteção contra gravações concorrentes desatualizadas
    if (existingItem != null &&
        existingItem.updatedAt.isAfter(effectiveItem.updatedAt)) {
      return;
    }

    currentList.removeWhere((i) {
      if (i.type == effectiveItem.type) {
        if (effectiveItem.type == ContinueWatchingType.movie) {
          return i.streamId == effectiveItem.streamId;
        } else {
          return (i.seriesId ?? i.streamId) ==
              (effectiveItem.seriesId ?? effectiveItem.streamId);
        }
      }
      return false;
    });

    if (effectiveItem.canResume) {
      currentList.insert(0, effectiveItem);
    } else if (effectiveItem.isCompleted ||
        effectiveItem.isHiddenFromHome ||
        effectiveItem.isHistoryCleared) {
      // Concluído, ocultado ou histórico limpo: removido do carrossel ativo
    } else if (existingItem != null && existingItem.canResume) {
      currentList.insert(0, existingItem);
    } else if (effectiveItem.type == ContinueWatchingType.series &&
        (effectiveItem.episodeNum ?? 0) >= 1 &&
        effectiveItem.position.inSeconds < 10) {
      currentList.insert(
        0,
        effectiveItem.copyWith(position: Duration.zero),
      );
    }

    currentList.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final capped = currentList.take(20).toList();
    final jsonList = capped.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(key, jsonList);

    if (effectiveItem.canResume ||
        effectiveItem.isCompleted ||
        effectiveItem.manualResetAt != null ||
        effectiveItem.isHiddenFromHome ||
        effectiveItem.isHistoryCleared) {
      final isImmediate = effectiveItem.isCompleted ||
          effectiveItem.position == Duration.zero ||
          effectiveItem.manualResetAt != null ||
          effectiveItem.isHiddenFromHome ||
          effectiveItem.isHistoryCleared;
      final shouldPush = await CloudProgressSyncService.instance
          .persistLocalLedgerChange(
        accountKey: accountKey,
        item: effectiveItem,
        immediatePush: isImmediate,
      );
      if (shouldPush) {
        CloudProgressSyncService.instance.triggerBackgroundSync(
          accountKey,
          progressService: this,
          force: isImmediate,
        );
      }
    }
  }

  /// Garante que uma série que possui episódio ativo para CONTINUAR ou PRÓXIMO
  /// esteja presente e sincronizada no índice "Continuar assistindo" da Home,
  /// exceto se tiver sido ocultada ou limpa pelo usuário.
  Future<void> ensureContinueWatchingSeriesItem({
    required String accountKey,
    required ContinueWatchingItem item,
  }) async {
    if (accountKey.trim().isEmpty || !item.canResume) return;
    final seriesId = item.seriesId ?? item.streamId;
    if (await isHiddenFromHome(
      accountKey: accountKey,
      type: ContinueWatchingType.series,
      id: seriesId,
    )) {
      return;
    }
    if (await getHistoryClearedAt(
          accountKey: accountKey,
          type: ContinueWatchingType.series,
          id: seriesId,
        ) !=
        null) {
      return;
    }

    final currentList = await getContinueWatchingList(accountKey: accountKey);
    final existingIndex = currentList.indexWhere((i) {
      if (i.type == ContinueWatchingType.series) {
        return (i.seriesId ?? i.streamId) == seriesId;
      }
      return false;
    });

    if (existingIndex >= 0) {
      final existing = currentList[existingIndex];
      if (compareAdvancement(existing, item) >= 0 &&
          existing.streamId == item.streamId &&
          (existing.position.inSeconds - item.position.inSeconds).abs() < 2) {
        return;
      }
    }

    await saveContinueWatchingItem(
      accountKey: accountKey,
      item: item,
      isRealPlayback: false,
    );
  }

  /// Reconcilia automaticamente séries que possuem `series_last` ativo no dispositivo
  /// mas ficaram fora da lista `continue_watching` (respeitando ocultações e históricos limpos).
  Future<bool> reconcileOrphanedSeriesContinueWatching({
    required String accountKey,
    Future<XtreamSeriesInfo?> Function(int seriesId)? getCachedSeriesInfo,
    String? Function(int seriesId)? getSeriesTitleSync,
    String? Function(int seriesId)? getSeriesCoverSync,
    String? Function(int seriesId)? getSeriesCategoryIdSync,
  }) async {
    if (accountKey.trim().isEmpty) return false;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);
    final lastPrefix = 'series_last_${effective}_';

    final hiddenMap = await _loadSuppressionMap(
      prefs,
      _buildHiddenMapKeyForEffective(effective),
    );
    final clearedMap = await _loadSuppressionMap(
      prefs,
      _buildClearedMapKeyForEffective(effective),
    );

    final currentList = await getContinueWatchingList(
      accountKey: accountKey,
      effectiveAccountKeyOverride: effective,
    );
    final activeSeriesIds = <int>{};
    for (final item in currentList) {
      if (item.type == ContinueWatchingType.series) {
        activeSeriesIds.add(item.seriesId ?? item.streamId);
      }
    }

    final ledgerMap = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);

    bool addedAny = false;
    final allKeys = prefs.getKeys();
    for (final k in allKeys) {
      if (!k.startsWith(lastPrefix)) continue;
      final seriesIdStr = k.substring(lastPrefix.length);
      final seriesId = int.tryParse(seriesIdStr);
      if (seriesId == null || seriesId <= 0 || activeSeriesIds.contains(seriesId)) {
        continue;
      }

      final supKey = _suppressionItemKey(ContinueWatchingType.series, seriesId);
      if (hiddenMap.containsKey(supKey) || clearedMap.containsKey(supKey)) {
        continue;
      }

      final lastData = await _getLastWatchedEpisodeByEffective(prefs, effective, seriesId);
      if (lastData == null) continue;
      if (lastData['isCompleted'] == 1) continue;

      final lastEpId = lastData['episodeId'] ?? 0;
      final lastSeason = lastData['seasonNumber'] ?? 1;
      final lastEpNum = lastData['episodeNum'] ?? 1;
      final isPromotedNext = lastData['isPromotedNext'] == 1;
      final lastTimeMs = lastData['time'] ?? 0;

      if (lastEpId <= 0) continue;

      final cachedInfo = await getCachedSeriesInfo?.call(seriesId);
      final ledgerItem = ledgerMap['series_$seriesId'];
      if (ledgerItem != null &&
          (ledgerItem.isHiddenFromHome ||
              ledgerItem.isHistoryCleared ||
              ledgerItem.completedAt != null ||
              (ledgerItem.manualResetAt != null &&
                  ledgerItem.manualResetAt!.millisecondsSinceEpoch >= lastTimeMs))) {
        continue;
      }

      // Compatibilidade com tombstones legados (anteriores a hiddenFromHomeAt)
      if (ledgerItem != null &&
          ledgerItem.isCompleted &&
          lastTimeMs > 0 &&
          ledgerItem.updatedAt.millisecondsSinceEpoch > lastTimeMs + 1000 &&
          !isPromotedNext) {
        final epProgCheck = await getEpisodeProgress(
          accountKey: accountKey,
          seriesId: seriesId,
          episodeId: lastEpId,
        );
        if (epProgCheck == null) {
          if (cachedInfo == null) continue;
          final currentEp = cachedInfo.findEpisodeById(lastEpId) ??
              cachedInfo.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
          final nextEp = currentEp != null ? cachedInfo.getNextEpisode(currentEp) : null;
          if (nextEp == null) continue;
        }
      }

      final epProg = await getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: lastEpId,
      );

      XtreamSeriesEpisode? targetEp;
      Duration targetPos = Duration.zero;
      Duration targetDur = Duration.zero;

      if (epProg != null && epProg.canResume) {
        targetEp = cachedInfo?.findEpisodeById(lastEpId) ??
            cachedInfo?.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
        targetPos = epProg.position;
        targetDur = epProg.duration;
      } else if (isPromotedNext) {
        targetEp = cachedInfo?.findEpisodeById(lastEpId) ??
            cachedInfo?.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
        targetPos = Duration.zero;
        targetDur = (targetEp?.durationSecs != null && targetEp!.durationSecs! > 0)
            ? Duration(seconds: targetEp.durationSecs!)
            : Duration.zero;
      } else if (cachedInfo != null) {
        final lastEp = cachedInfo.findEpisodeById(lastEpId) ??
            cachedInfo.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
        if (lastEp != null) {
          final nextEp = cachedInfo.getNextEpisode(lastEp);
          if (nextEp != null) {
            targetEp = nextEp;
            final nextProg = await getEpisodeProgress(
              accountKey: accountKey,
              seriesId: seriesId,
              episodeId: nextEp.id,
            );
            targetPos = (nextProg != null && nextProg.canResume)
                ? nextProg.position
                : Duration.zero;
            targetDur = (nextProg != null && nextProg.duration > Duration.zero)
                ? nextProg.duration
                : ((nextEp.durationSecs != null && nextEp.durationSecs! > 0)
                    ? Duration(seconds: nextEp.durationSecs!)
                    : Duration.zero);
            await saveLastWatchedEpisode(
              accountKey: accountKey,
              seriesId: seriesId,
              episodeId: nextEp.id,
              seasonNumber: nextEp.seasonNumber,
              episodeNum: nextEp.episodeNum,
              isPromotedNext: targetPos == Duration.zero,
            );
          }
        }
      }

      if (targetEp == null && (epProg == null || !epProg.canResume) && !isPromotedNext) {
        continue;
      }

      final title = getSeriesTitleSync?.call(seriesId) ??
          cachedInfo?.name ??
          ledgerItem?.title ??
          '';
      if (title.trim().isEmpty || title.startsWith('Série #')) continue;

      final effSeason = targetEp?.seasonNumber ?? lastSeason;
      final effEpNum = targetEp?.episodeNum ?? lastEpNum;
      final effEpId = targetEp?.id ?? lastEpId;
      final effEpTitle = targetEp?.title ?? 'Episódio $effEpNum';
      final cover = targetEp?.cover ??
          getSeriesCoverSync?.call(seriesId) ??
          cachedInfo?.cover ??
          ledgerItem?.coverUrl;
      final categoryId = getSeriesCategoryIdSync?.call(seriesId) ??
          ledgerItem?.categoryId;
      final ext = targetEp?.containerExtension ?? ledgerItem?.containerExtension;
      final updatedAt = epProg?.updatedAt ??
          (lastTimeMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(lastTimeMs)
              : DateTime.now());

      await saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: effEpId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: title,
          subtitle: 'T$effSeason:E$effEpNum • $effEpTitle',
          coverUrl: cover,
          position: targetPos,
          duration: targetDur,
          updatedAt: updatedAt,
          containerExtension: ext,
          categoryId: categoryId,
          seasonNumber: effSeason,
          episodeNum: effEpNum,
        ),
        isRealPlayback: false,
      );
      addedAny = true;
    }

    return addedAny;
  }

  /// Remove e persiste a ocultação do card na Home SEM apagar posição/episódio assistidos.
  /// Impede ressurreição automática ao abrir a série ou sincronizar com o Firebase,
  /// voltando apenas quando ocorrer nova reprodução real.
  Future<void> hideContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);
    final key = _buildContinueWatchingKeyForEffective(effective);
    final currentList = await getContinueWatchingList(
      accountKey: accountKey,
      effectiveAccountKeyOverride: effective,
    );

    ContinueWatchingItem? removedItem;
    currentList.removeWhere((i) {
      if (i.type == type) {
        final matches = (type == ContinueWatchingType.movie)
            ? i.streamId == id
            : (i.seriesId ?? i.streamId) == id;
        if (matches) {
          removedItem = i;
        }
        return matches;
      }
      return false;
    });

    await prefs.setStringList(
      key,
      currentList.map((i) => jsonEncode(i.toJson())).toList(),
    );

    final ledger = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);
    final baseItem = removedItem ?? ledger['${type.name}_$id'];
    final hiddenAt = _monotonicNowAfter(baseItem?.updatedAt);

    await _setSuppressionTimestamp(
      prefs,
      mapKey: _buildHiddenMapKeyForEffective(effective),
      type: type,
      id: id,
      timestamp: hiddenAt,
    );

    int streamId = baseItem?.streamId ?? id;
    int? lastSeason = baseItem?.seasonNumber;
    int? lastEpisodeNum = baseItem?.episodeNum;
    var preservedPos = baseItem?.position ?? Duration.zero;
    var preservedDur = baseItem?.duration ?? Duration.zero;

    if (type == ContinueWatchingType.series) {
      final last = await _getLastWatchedEpisodeByEffective(prefs, effective, id);
      if (last != null) {
        streamId = (last['episodeId'] ?? 0) > 0 ? last['episodeId']! : streamId;
        lastSeason ??= last['seasonNumber'];
        lastEpisodeNum ??= last['episodeNum'];
        final epProg = await getEpisodeProgress(
          accountKey: accountKey,
          seriesId: id,
          episodeId: streamId,
        );
        if (epProg != null && epProg.position > preservedPos) {
          preservedPos = epProg.position;
          preservedDur = epProg.duration;
        }
      }
    } else if (preservedPos == Duration.zero) {
      final vodProg = await getProgress(accountKey: accountKey, streamId: id);
      if (vodProg != null) {
        preservedPos = vodProg.position;
        preservedDur = vodProg.duration;
      }
    }

    final hiddenLedgerItem = (baseItem ??
            ContinueWatchingItem(
              streamId: streamId,
              seriesId: type == ContinueWatchingType.series ? id : null,
              type: type,
              title: type == ContinueWatchingType.series ? 'Série #$id' : 'VOD #$id',
              position: preservedPos,
              duration: preservedDur,
              updatedAt: baseItem?.updatedAt ?? hiddenAt,
              seasonNumber: lastSeason,
              episodeNum: lastEpisodeNum,
            ))
        .copyWith(
      streamId: streamId,
      position: preservedPos,
      duration: preservedDur,
      seasonNumber: lastSeason,
      episodeNum: lastEpisodeNum,
      hiddenFromHomeAt: hiddenAt,
      clearCompletedAt: true,
    );

    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: hiddenLedgerItem,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  /// Mantém compatibilidade com chamadores existentes, delegando para [hideContinueWatchingItem]
  /// em vez de gravar tombstone falso de concluído.
  Future<void> removeContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) {
    return hideContinueWatchingItem(accountKey: accountKey, type: type, id: id);
  }

  /// Reinicia a reprodução do filme ou série (zera posições e remove card, sem ocultar nem concluir).
  Future<void> resetPlaybackProgress({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);

    await _clearSuppressionEntry(
      prefs,
      mapKey: _buildHiddenMapKeyForEffective(effective),
      type: type,
      id: id,
    );
    await _clearSuppressionEntry(
      prefs,
      mapKey: _buildClearedMapKeyForEffective(effective),
      type: type,
      id: id,
    );

    if (type == ContinueWatchingType.movie) {
      await clearProgress(accountKey: accountKey, streamId: id);
      return;
    }

    final listKey = _buildContinueWatchingKeyForEffective(effective);
    final rawList = prefs.getStringList(listKey) ?? [];
    ContinueWatchingItem? existingItem;
    final kept = <String>[];
    for (final raw in rawList) {
      try {
        final item = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (item.type == ContinueWatchingType.series &&
            (item.seriesId ?? item.streamId) == id) {
          existingItem = item;
          continue;
        }
        kept.add(raw);
      } catch (_) {}
    }
    await prefs.setStringList(listKey, kept);

    final epPrefix = 'series_prog_${effective}_${id}_';
    for (final k in prefs.getKeys().toList()) {
      if (k.startsWith(epPrefix)) {
        await prefs.remove(k);
      }
    }
    await prefs.remove(_buildSeriesLastKeyForEffective(effective, id));

    final ledger = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);
    final prevLedger = existingItem ?? ledger['series_$id'];
    final now = _monotonicNowAfter(prevLedger?.updatedAt);
    final resetItem = (prevLedger ??
            ContinueWatchingItem(
              streamId: id,
              seriesId: id,
              type: ContinueWatchingType.series,
              title: 'Série #$id',
              position: Duration.zero,
              duration: Duration.zero,
              updatedAt: now,
              seasonNumber: 1,
              episodeNum: 1,
            ))
        .copyWith(
      streamId: id,
      seriesId: id,
      position: Duration.zero,
      duration: Duration.zero,
      seasonNumber: 1,
      episodeNum: 1,
      updatedAt: now,
      manualResetAt: now,
      clearHiddenFromHomeAt: true,
      clearCompletedAt: true,
      clearHistoryClearedAt: true,
    );

    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: resetItem,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  /// Marca o filme ou o episódio atual da série como concluído (diferente de "nunca assistido").
  Future<void> markContinueWatchingCompleted({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);

    await _clearSuppressionEntry(
      prefs,
      mapKey: _buildHiddenMapKeyForEffective(effective),
      type: type,
      id: id,
    );

    final listKey = _buildContinueWatchingKeyForEffective(effective);
    final rawList = prefs.getStringList(listKey) ?? [];
    ContinueWatchingItem? existingItem;
    final kept = <String>[];
    for (final raw in rawList) {
      try {
        final item = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final matches = item.type == type &&
            (type == ContinueWatchingType.movie
                ? item.streamId == id
                : (item.seriesId ?? item.streamId) == id);
        if (matches) {
          existingItem = item;
          continue;
        }
        kept.add(raw);
      } catch (_) {}
    }
    await prefs.setStringList(listKey, kept);

    final ledger = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);
    final prevItem = existingItem ?? ledger['${type.name}_$id'];
    final now = _monotonicNowAfter(prevItem?.updatedAt);

    int targetStreamId = prevItem?.streamId ?? id;
    int? targetSeason = prevItem?.seasonNumber;
    int? targetEpNum = prevItem?.episodeNum;

    if (type == ContinueWatchingType.movie) {
      await prefs.remove(_buildStorageKeyForEffective(effective, id));
    } else {
      final last = await _getLastWatchedEpisodeByEffective(prefs, effective, id);
      if (last != null) {
        if ((last['episodeId'] ?? 0) > 0) targetStreamId = last['episodeId']!;
        targetSeason ??= last['seasonNumber'];
        targetEpNum ??= last['episodeNum'];
      }
      if (targetStreamId > 0) {
        await prefs.remove(
          _buildEpisodeStorageKeyForEffective(effective, id, targetStreamId),
        );
      }
      await prefs.setString(
        _buildSeriesLastKeyForEffective(effective, id),
        jsonEncode({
          'episodeId': targetStreamId,
          'seasonNumber': targetSeason ?? 1,
          'episodeNum': targetEpNum ?? 1,
          'isPromotedNext': false,
          'isCompleted': true,
          'time': now.millisecondsSinceEpoch,
        }),
      );
    }

    final baseDur = (prevItem != null && prevItem.duration > Duration.zero)
        ? prevItem.duration
        : const Duration(seconds: 60);
    final completedItem = (prevItem ??
            ContinueWatchingItem(
              streamId: targetStreamId,
              seriesId: type == ContinueWatchingType.series ? id : null,
              type: type,
              title: type == ContinueWatchingType.series ? 'Série #$id' : 'VOD #$id',
              position: baseDur,
              duration: baseDur,
              updatedAt: now,
              seasonNumber: targetSeason,
              episodeNum: targetEpNum,
            ))
        .copyWith(
      streamId: targetStreamId,
      position: baseDur,
      duration: baseDur,
      seasonNumber: targetSeason,
      episodeNum: targetEpNum,
      updatedAt: now,
      completedAt: now,
      clearHiddenFromHomeAt: true,
      clearHistoryClearedAt: true,
    );

    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: completedItem,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  /// Apaga completamente o histórico local e sincronizado de reprodução do item.
  Future<void> clearItemWatchHistory({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);

    final listKey = _buildContinueWatchingKeyForEffective(effective);
    final rawList = prefs.getStringList(listKey) ?? [];
    ContinueWatchingItem? existingItem;
    final kept = <String>[];
    for (final raw in rawList) {
      try {
        final item = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final matches = item.type == type &&
            (type == ContinueWatchingType.movie
                ? item.streamId == id
                : (item.seriesId ?? item.streamId) == id);
        if (matches) {
          existingItem = item;
          continue;
        }
        kept.add(raw);
      } catch (_) {}
    }
    await prefs.setStringList(listKey, kept);

    if (type == ContinueWatchingType.movie) {
      await prefs.remove(_buildStorageKeyForEffective(effective, id));
    } else {
      final epPrefix = 'series_prog_${effective}_${id}_';
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(epPrefix)) {
          await prefs.remove(k);
        }
      }
      await prefs.remove(_buildSeriesLastKeyForEffective(effective, id));
    }

    final ledger = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);
    final prevItem = existingItem ?? ledger['${type.name}_$id'];
    final now = _monotonicNowAfter(prevItem?.updatedAt);

    await _clearSuppressionEntry(
      prefs,
      mapKey: _buildHiddenMapKeyForEffective(effective),
      type: type,
      id: id,
    );
    await _setSuppressionTimestamp(
      prefs,
      mapKey: _buildClearedMapKeyForEffective(effective),
      type: type,
      id: id,
      timestamp: now,
    );

    final clearedItem = (prevItem ??
            ContinueWatchingItem(
              streamId: id,
              seriesId: type == ContinueWatchingType.series ? id : null,
              type: type,
              title: type == ContinueWatchingType.series ? 'Série #$id' : 'VOD #$id',
              position: Duration.zero,
              duration: Duration.zero,
              updatedAt: now,
              seasonNumber: type == ContinueWatchingType.series ? 1 : null,
              episodeNum: type == ContinueWatchingType.series ? 1 : null,
            ))
        .copyWith(
      streamId: id,
      seriesId: type == ContinueWatchingType.series ? id : null,
      position: Duration.zero,
      duration: Duration.zero,
      seasonNumber: type == ContinueWatchingType.series ? 1 : null,
      episodeNum: type == ContinueWatchingType.series ? 1 : null,
      updatedAt: now,
      manualResetAt: now,
      historyClearedAt: now,
      clearHiddenFromHomeAt: true,
      clearCompletedAt: true,
    );

    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: clearedItem,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  /// Aplica localmente um item vencedor vindo da sincronização em nuvem sem disparar reenvio.
  Future<void> applySyncedItem({
    required String accountKey,
    required ContinueWatchingItem item,
    String? effectiveAccountKeyOverride,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final effective = effectiveAccountKeyOverride ?? _effectiveAccountKey(accountKey);
    final hiddenKey = _buildHiddenMapKeyForEffective(effective);
    final clearedKey = _buildClearedMapKeyForEffective(effective);
    final itemId = item.type == ContinueWatchingType.movie
        ? item.streamId
        : (item.seriesId ?? item.streamId);

    // Se veio ocultação da Home de outro dispositivo: oculta localmente SEM apagar posição assistida!
    if (item.isHiddenFromHome) {
      await _setSuppressionTimestamp(
        prefs,
        mapKey: hiddenKey,
        type: item.type,
        id: itemId,
        timestamp: item.hiddenFromHomeAt!,
      );
      await _upsertOrRemoveContinueWatchingLocal(
        prefs: prefs,
        effective: effective,
        item: item,
        remove: true,
      );
      return;
    }

    if (item.type == ContinueWatchingType.movie) {
      final progKey = _buildStorageKeyForEffective(effective, item.streamId);
      if (item.isHistoryCleared) {
        await _clearSuppressionEntry(
          prefs,
          mapKey: hiddenKey,
          type: ContinueWatchingType.movie,
          id: item.streamId,
        );
        await _setSuppressionTimestamp(
          prefs,
          mapKey: clearedKey,
          type: ContinueWatchingType.movie,
          id: item.streamId,
          timestamp: item.historyClearedAt!,
        );
        await prefs.remove(progKey);
        await _upsertOrRemoveContinueWatchingLocal(
          prefs: prefs,
          effective: effective,
          item: item,
          remove: true,
        );
        return;
      }

      final shouldClear = item.isCompleted ||
          (item.manualResetAt != null && item.position.inSeconds < 10);
      if (shouldClear) {
        await _clearSuppressionEntry(
          prefs,
          mapKey: hiddenKey,
          type: ContinueWatchingType.movie,
          id: item.streamId,
        );
        await prefs.remove(progKey);
        await _upsertOrRemoveContinueWatchingLocal(
          prefs: prefs,
          effective: effective,
          item: item,
          remove: true,
        );
      } else {
        await _clearSuppressionEntry(
          prefs,
          mapKey: hiddenKey,
          type: ContinueWatchingType.movie,
          id: item.streamId,
        );
        await _clearSuppressionEntry(
          prefs,
          mapKey: clearedKey,
          type: ContinueWatchingType.movie,
          id: item.streamId,
        );
        if (item.position.inSeconds >= 10) {
          await prefs.setString(
            progKey,
            jsonEncode({
              'pos': item.position.inMilliseconds,
              'dur': item.duration.inMilliseconds,
              'time': item.updatedAt.millisecondsSinceEpoch,
            }),
          );
        }
        await _upsertOrRemoveContinueWatchingLocal(
          prefs: prefs,
          effective: effective,
          item: item,
          remove: !item.canResume,
        );
      }
      return;
    }

    // Série
    final seriesId = item.seriesId ?? item.streamId;
    final parsedSub = (item.seasonNumber == null || item.episodeNum == null)
        ? parseSeasonEpisodeFromSubtitle(item.subtitle)
        : (null, null);
    final effSeason = item.seasonNumber ?? parsedSub.$1 ?? 1;
    final effEpNum = item.episodeNum ?? parsedSub.$2 ?? 1;
    final lastKey = _buildSeriesLastKeyForEffective(effective, seriesId);

    if (item.isHistoryCleared) {
      await _clearSuppressionEntry(
        prefs,
        mapKey: hiddenKey,
        type: ContinueWatchingType.series,
        id: seriesId,
      );
      await _setSuppressionTimestamp(
        prefs,
        mapKey: clearedKey,
        type: ContinueWatchingType.series,
        id: seriesId,
        timestamp: item.historyClearedAt!,
      );
      final epPrefix = 'series_prog_${effective}_${seriesId}_';
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(epPrefix)) {
          await prefs.remove(k);
        }
      }
      await prefs.remove(lastKey);
      await _upsertOrRemoveContinueWatchingLocal(
        prefs: prefs,
        effective: effective,
        item: item,
        remove: true,
      );
      return;
    }

    final oldLast = await _getLastWatchedEpisodeByEffective(prefs, effective, seriesId);
    final epProgKey = _buildEpisodeStorageKeyForEffective(effective, seriesId, item.streamId);

    if (item.isCompleted) {
      await _clearSuppressionEntry(
        prefs,
        mapKey: hiddenKey,
        type: ContinueWatchingType.series,
        id: seriesId,
      );
      await prefs.remove(epProgKey);
      await prefs.setString(
        lastKey,
        jsonEncode({
          'episodeId': item.streamId,
          'seasonNumber': effSeason,
          'episodeNum': effEpNum,
          'isPromotedNext': false,
          'isCompleted': true,
          'time': item.updatedAt.millisecondsSinceEpoch,
        }),
      );
      await _upsertOrRemoveContinueWatchingLocal(
        prefs: prefs,
        effective: effective,
        item: item,
        remove: true,
      );
      return;
    }

    if (item.manualResetAt != null &&
        item.position.inSeconds < 10 &&
        effSeason <= 1 &&
        effEpNum <= 1) {
      await _clearSuppressionEntry(
        prefs,
        mapKey: hiddenKey,
        type: ContinueWatchingType.series,
        id: seriesId,
      );
      await _clearSuppressionEntry(
        prefs,
        mapKey: clearedKey,
        type: ContinueWatchingType.series,
        id: seriesId,
      );
      final epPrefix = 'series_prog_${effective}_${seriesId}_';
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(epPrefix)) {
          await prefs.remove(k);
        }
      }
      await prefs.remove(lastKey);
      await _upsertOrRemoveContinueWatchingLocal(
        prefs: prefs,
        effective: effective,
        item: item,
        remove: true,
      );
      return;
    }

    // Só remove o progresso do episódio anterior quando avançou estritamente de episódio/temporada,
    // preservando progresso do mesmo episódio caso apenas o ID tenha sido reindexado.
    if (oldLast != null &&
        oldLast['episodeId'] != null &&
        oldLast['episodeId'] != item.streamId) {
      final oldSeason = oldLast['seasonNumber'] ?? 1;
      final oldEp = oldLast['episodeNum'] ?? 1;
      final movedStrictlyForward =
          effSeason > oldSeason || (effSeason == oldSeason && effEpNum > oldEp);
      if (movedStrictlyForward) {
        await prefs.remove(
          _buildEpisodeStorageKeyForEffective(effective, seriesId, oldLast['episodeId']!),
        );
      }
    }

    await _clearSuppressionEntry(
      prefs,
      mapKey: hiddenKey,
      type: ContinueWatchingType.series,
      id: seriesId,
    );
    await _clearSuppressionEntry(
      prefs,
      mapKey: clearedKey,
      type: ContinueWatchingType.series,
      id: seriesId,
    );

    final isPromotedNext = item.position == Duration.zero && item.canResume;
    await prefs.setString(
      lastKey,
      jsonEncode({
        'episodeId': item.streamId,
        'seasonNumber': effSeason,
        'episodeNum': effEpNum,
        'isPromotedNext': isPromotedNext,
        'isCompleted': false,
        'time': item.updatedAt.millisecondsSinceEpoch,
      }),
    );

    if (item.position.inSeconds >= 10) {
      await prefs.setString(
        epProgKey,
        jsonEncode({
          'pos': item.position.inMilliseconds,
          'dur': item.duration.inMilliseconds,
          'time': item.updatedAt.millisecondsSinceEpoch,
        }),
      );
    } else if (item.position == Duration.zero) {
      await prefs.remove(epProgKey);
    }

    await _upsertOrRemoveContinueWatchingLocal(
      prefs: prefs,
      effective: effective,
      item: item,
      remove: !item.canResume,
    );
  }

  Future<void> _upsertOrRemoveContinueWatchingLocal({
    required SharedPreferences prefs,
    required String effective,
    required ContinueWatchingItem item,
    required bool remove,
  }) async {
    final key = _buildContinueWatchingKeyForEffective(effective);
    final rawList = prefs.getStringList(key) ?? [];
    final currentList = <ContinueWatchingItem>[];
    for (final raw in rawList) {
      try {
        final parsed = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (parsed.type == item.type) {
          final matches = (item.type == ContinueWatchingType.movie)
              ? parsed.streamId == item.streamId
              : (parsed.seriesId ?? parsed.streamId) ==
                  (item.seriesId ?? item.streamId);
          if (matches) continue;
        }
        if (parsed.canResume && parsed.title.isNotEmpty) {
          currentList.add(parsed);
        }
      } catch (_) {}
    }
    if (!remove && item.canResume && item.title.isNotEmpty) {
      currentList.add(item);
    }
    currentList.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final capped = currentList.take(20).toList();
    await prefs.setStringList(
      key,
      capped.map((i) => jsonEncode(i.toJson())).toList(),
    );
  }

  static DateTime? _maxNullableDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// Compara dois estados de reprodução para determinar qual está mais avançado.
  /// Retorna > 0 quando [a] está mais avançado que [b], < 0 quando [b] está mais avançado e 0 em empate exato.
  static int compareAdvancement(ContinueWatchingItem a, ContinueWatchingItem b) {
    if (a.type != b.type) {
      return a.updatedAt.compareTo(b.updatedAt);
    }

    if (a.type == ContinueWatchingType.movie) {
      if (a.isCompleted != b.isCompleted) {
        return a.isCompleted ? 1 : -1;
      }
      final posCmp = a.position.inMilliseconds.compareTo(b.position.inMilliseconds);
      if (posCmp != 0) return posCmp;
      return a.updatedAt.compareTo(b.updatedAt);
    }

    // Séries: temporada -> episódio -> conclusão -> posição -> timestamp
    final sCmp = (a.seasonNumber ?? 1).compareTo(b.seasonNumber ?? 1);
    if (sCmp != 0) return sCmp;

    final eCmp = (a.episodeNum ?? 1).compareTo(b.episodeNum ?? 1);
    if (eCmp != 0) return eCmp;

    final cCmp = (a.isCompleted ? 1 : 0).compareTo(b.isCompleted ? 1 : 0);
    if (cCmp != 0) return cCmp;

    final posCmp = a.position.inMilliseconds.compareTo(b.position.inMilliseconds);
    if (posCmp != 0) return posCmp;

    return a.updatedAt.compareTo(b.updatedAt);
  }

  /// Seleciona o item prevalente entre [local] e [remote] respeitando ocultação da Home,
  /// limpeza explícita, reinício manual e progresso mais avançado entre Fire TV e celular.
  static ContinueWatchingItem pickMoreAdvanced(
    ContinueWatchingItem local,
    ContinueWatchingItem remote,
  ) {
    final localReset = _maxNullableDate(local.manualResetAt, local.historyClearedAt);
    final remoteReset = _maxNullableDate(remote.manualResetAt, remote.historyClearedAt);

    ContinueWatchingItem winner;
    ContinueWatchingItem loser;

    if (localReset != null &&
        localReset.isAfter(remote.updatedAt) &&
        (remoteReset == null || !remoteReset.isAfter(localReset))) {
      winner = local;
      loser = remote;
    } else if (remoteReset != null &&
        remoteReset.isAfter(local.updatedAt) &&
        (localReset == null || !localReset.isAfter(remoteReset))) {
      winner = remote;
      loser = local;
    } else if (local.completedAt != null &&
        local.completedAt!.isAfter(remote.updatedAt) &&
        (remote.completedAt == null ||
            !remote.completedAt!.isAfter(local.completedAt!))) {
      winner = local;
      loser = remote;
    } else if (remote.completedAt != null &&
        remote.completedAt!.isAfter(local.updatedAt) &&
        (local.completedAt == null ||
            !local.completedAt!.isAfter(remote.completedAt!))) {
      winner = remote;
      loser = local;
    } else if (compareAdvancement(local, remote) >= 0) {
      winner = local;
      loser = remote;
    } else {
      winner = remote;
      loser = local;
    }

    final mergedCover = (winner.coverUrl != null && winner.coverUrl!.trim().isNotEmpty)
        ? winner.coverUrl
        : loser.coverUrl;
    final mergedExt = (winner.containerExtension != null && winner.containerExtension!.trim().isNotEmpty)
        ? winner.containerExtension
        : loser.containerExtension;
    final mergedCat = (winner.categoryId != null && winner.categoryId!.trim().isNotEmpty)
        ? winner.categoryId
        : loser.categoryId;

    // Reconcilia estado de ocultação na Home sem deixar o Firebase ressuscitar item oculto
    final latestHidden =
        _maxNullableDate(local.hiddenFromHomeAt, remote.hiddenFromHomeAt);
    DateTime? latestRealPlay;
    if (!local.isHiddenFromHome &&
        !local.isHistoryCleared &&
        local.manualResetAt == null &&
        local.completedAt == null) {
      latestRealPlay = local.updatedAt;
    }
    if (!remote.isHiddenFromHome &&
        !remote.isHistoryCleared &&
        remote.manualResetAt == null &&
        remote.completedAt == null) {
      latestRealPlay = _maxNullableDate(latestRealPlay, remote.updatedAt);
    }

    final keepHidden = !winner.isHistoryCleared &&
        !winner.isCompleted &&
        latestHidden != null &&
        (latestRealPlay == null || !latestRealPlay.isAfter(latestHidden));

    return winner.copyWith(
      coverUrl: mergedCover,
      containerExtension: mergedExt,
      categoryId: mergedCat,
      hiddenFromHomeAt: keepHidden ? latestHidden : null,
      clearHiddenFromHomeAt: !keepHidden,
    );
  }

  /// Formata uma duração em string legível (ex: 01:23:45 ou 05:30)
  static String formatDuration(Duration duration) {
    if (duration.isNegative) return '00:00';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    final mStr = minutes.toString().padLeft(2, '0');
    final sStr = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      final hStr = hours.toString().padLeft(2, '0');
      return '$hStr:$mStr:$sStr';
    }
    return '$mStr:$sStr';
  }
}
