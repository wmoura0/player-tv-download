import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import 'series_identity_verifier.dart';
import 'user_profile_service.dart';

/// Serviço responsável por persistir e gerenciar favoritos localmente,
/// garantindo isolamento estrito por conta/servidor Xtream, por lista M3U e por perfil.
///
/// Todas as gravações são serializadas em fila e o cache em memória é isolado
/// pelo escopo efetivo (conta + perfil ativo), evitando mistura ou duplicação.
class FavoritesService extends ChangeNotifier {
  static FavoritesService? _instance;

  /// Acesso singleton padrão para uso global pelo app
  static FavoritesService get instance => _instance ??= FavoritesService();

  /// Reinicializa a instância (útil para testes isolados)
  static void resetInstanceForTesting() {
    _instance = null;
  }

  final SharedPreferences? _prefsOverride;

  // Chaves compostas indexadas por escopo efetivo (conta + perfil):
  // '$effectiveCacheKey#${type.name}#$id'
  final Set<String> _cachedCompositeKeys = <String>{};

  // Cache em memória dos itens por effectiveCacheKey (conta + perfil)
  final Map<String, List<FavoriteItem>> _cachedItems = <String, List<FavoriteItem>>{};

  // Controle de carregamento por effectiveCacheKey
  final Set<String> _loadedScopes = <String>{};

  // Fila sequencial para evitar condições de corrida entre alterações simultâneas
  Future<void>? _writeQueue;

  FavoritesService({SharedPreferences? prefs}) : _prefsOverride = prefs;

  Future<SharedPreferences> _getPrefs() async {
    return _prefsOverride ?? await SharedPreferences.getInstance();
  }

  Future<T> _enqueueWrite<T>(Future<T> Function() action) {
    final prev = _writeQueue;
    if (prev == null) {
      final current = action();
      late final Future<void> tail;
      tail = current.then<void>(
        (_) {
          if (identical(_writeQueue, tail)) {
            _writeQueue = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_writeQueue, tail)) {
            _writeQueue = null;
          }
        },
      );
      _writeQueue = tail;
      return current;
    }

    final completer = Completer<T>();
    final tail = prev.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    late final Future<void> trackedTail;
    trackedTail = tail.whenComplete(() {
      if (identical(_writeQueue, trackedTail)) {
        _writeQueue = null;
      }
    });
    _writeQueue = trackedTail;
    return completer.future;
  }

  /// Limpa caches em memória ao alternar perfis, contas ou fontes
  void clearCache() {
    _cachedCompositeKeys.clear();
    _cachedItems.clear();
    _loadedScopes.clear();
    notifyListeners();
  }

  /// Alias explícito para limpeza de cache em memória no logout ou troca de perfil/conta.
  void clearMemoryCache() => clearCache();

  /// Gera a chave de armazenamento isolada por escopo e perfil
  static String buildStorageKey(String scopeKey) {
    final effective = UserProfileService.instance.getScopedKey(scopeKey);
    final cleanScope = effective.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return 'player_fav_${cleanScope}_v1';
  }

  String _effectiveCacheKey(String scopeKey) => buildStorageKey(scopeKey);

  String _compositeKeyFor(String effectiveKey, FavoriteType type, String id) =>
      '$effectiveKey#${type.name}#$id';

  Future<List<FavoriteItem>> _loadFavoritesUnlocked(String scopeKey) async {
    final effectiveKey = _effectiveCacheKey(scopeKey);
    if (_loadedScopes.contains(effectiveKey) &&
        _cachedItems.containsKey(effectiveKey)) {
      return List.unmodifiable(_cachedItems[effectiveKey]!);
    }

    final prefs = await _getPrefs();
    final jsonList = prefs.getStringList(effectiveKey) ?? [];

    final items = <FavoriteItem>[];
    for (final jsonStr in jsonList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final item = FavoriteItem.fromJson(map);
        items.add(item);
        _cachedCompositeKeys.add(
          _compositeKeyFor(effectiveKey, item.type, item.id),
        );
      } catch (_) {
        // Ignorar itens corrompidos para não quebrar a carga
      }
    }

    // Ordenar pelos mais recentemente adicionados
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));

    _cachedItems[effectiveKey] = items;
    _loadedScopes.add(effectiveKey);
    return List.unmodifiable(items);
  }

  /// Carrega os favoritos do escopo (isolado pelo perfil ativo) para o cache em memória
  Future<List<FavoriteItem>> loadFavorites(String scopeKey) =>
      _loadFavoritesUnlocked(scopeKey);

  /// Retorna de forma síncrona se um item é favorito no perfil ativo (cache em memória)
  bool isFavorite({
    required String scopeKey,
    required FavoriteType type,
    required String id,
  }) {
    final effectiveKey = _effectiveCacheKey(scopeKey);
    return _cachedCompositeKeys.contains(
      _compositeKeyFor(effectiveKey, type, id),
    );
  }

  /// Retorna todos os IDs favoritos de um determinado tipo para o escopo e perfil ativo
  Set<String> getFavoriteIdsSync({
    required String scopeKey,
    required FavoriteType type,
  }) {
    final effectiveKey = _effectiveCacheKey(scopeKey);
    final items = _cachedItems[effectiveKey] ?? [];
    return items.where((i) => i.type == type).map((i) => i.id).toSet();
  }

  /// Alterna o estado de favorito de um item.
  /// Retorna `true` se o item foi adicionado e `false` se foi removido.
  Future<bool> toggleFavorite(FavoriteItem item) {
    return _enqueueWrite(() async {
      await _loadFavoritesUnlocked(item.scopeKey);

      final currentlyFavorite = isFavorite(
        scopeKey: item.scopeKey,
        type: item.type,
        id: item.id,
      );

      if (currentlyFavorite) {
        await _removeFavoriteUnlocked(
          scopeKey: item.scopeKey,
          type: item.type,
          id: item.id,
        );
        return false;
      } else {
        await _addFavoriteUnlocked(item);
        return true;
      }
    });
  }

  /// Adiciona um item aos favoritos mantendo ordenação por [addedAt] (suporta Desfazer na posição original)
  Future<void> addFavorite(FavoriteItem item) {
    return _enqueueWrite(() => _addFavoriteUnlocked(item));
  }

  Future<void> _addFavoriteUnlocked(FavoriteItem item) async {
    final effectiveKey = _effectiveCacheKey(item.scopeKey);
    await _loadFavoritesUnlocked(item.scopeKey);

    final currentList = _cachedItems[effectiveKey] ?? <FavoriteItem>[];
    currentList.removeWhere((i) => i.type == item.type && i.id == item.id);
    currentList.add(item);
    currentList.sort((a, b) => b.addedAt.compareTo(a.addedAt));

    _cachedItems[effectiveKey] = currentList;
    _cachedCompositeKeys.add(
      _compositeKeyFor(effectiveKey, item.type, item.id),
    );

    await _persistScope(item.scopeKey, currentList);
    notifyListeners();
  }

  /// Remove um item dos favoritos
  Future<void> removeFavorite({
    required String scopeKey,
    required FavoriteType type,
    required String id,
  }) {
    return _enqueueWrite(
      () => _removeFavoriteUnlocked(scopeKey: scopeKey, type: type, id: id),
    );
  }

  Future<void> _removeFavoriteUnlocked({
    required String scopeKey,
    required FavoriteType type,
    required String id,
  }) async {
    final effectiveKey = _effectiveCacheKey(scopeKey);
    await _loadFavoritesUnlocked(scopeKey);

    final currentList = _cachedItems[effectiveKey] ?? <FavoriteItem>[];
    currentList.removeWhere((i) => i.type == type && i.id == id);
    _cachedItems[effectiveKey] = currentList;
    _cachedCompositeKeys.remove(_compositeKeyFor(effectiveKey, type, id));

    await _persistScope(scopeKey, currentList);
    notifyListeners();
  }

  /// Migra o ID de uma série já favoritada após reindexação confirmada no servidor,
  /// removendo o ID antigo (sem duplicar) e preservando o timestamp [addedAt] original.
  /// Nunca adiciona favorito se [oldSeriesId] não estiver favoritado.
  Future<void> migrateSeriesFavoriteId({
    required String accountKey,
    required int oldSeriesId,
    required XtreamSeriesItem newSeries,
  }) {
    return _enqueueWrite(() async {
      if (accountKey.trim().isEmpty ||
          oldSeriesId <= 0 ||
          newSeries.seriesId <= 0 ||
          oldSeriesId == newSeries.seriesId) {
        return;
      }

      final effectiveKey = _effectiveCacheKey(accountKey);
      await _loadFavoritesUnlocked(accountKey);

      final currentList = _cachedItems[effectiveKey] ?? <FavoriteItem>[];
      final oldIdStr = oldSeriesId.toString();
      final newIdStr = newSeries.seriesId.toString();

      final oldIdx = currentList.indexWhere(
        (i) => i.type == FavoriteType.series && i.id == oldIdStr,
      );
      if (oldIdx < 0) return;

      final existingOld = currentList[oldIdx];
      final existingNewIdx = currentList.indexWhere(
        (i) => i.type == FavoriteType.series && i.id == newIdStr,
      );
      final preservedAddedAt = existingNewIdx >= 0 &&
              currentList[existingNewIdx].addedAt.isAfter(existingOld.addedAt)
          ? currentList[existingNewIdx].addedAt
          : existingOld.addedAt;

      currentList.removeWhere(
        (i) =>
            i.type == FavoriteType.series &&
            (i.id == oldIdStr || i.id == newIdStr),
      );
      _cachedCompositeKeys.remove(
        _compositeKeyFor(effectiveKey, FavoriteType.series, oldIdStr),
      );

      final updated = FavoriteItem(
        id: newIdStr,
        scopeKey: accountKey,
        type: FavoriteType.series,
        name: newSeries.name.isNotEmpty ? newSeries.name : existingOld.name,
        iconUrl: newSeries.cover ?? existingOld.iconUrl,
        categoryId: newSeries.categoryId.isNotEmpty
            ? newSeries.categoryId
            : existingOld.categoryId,
        rating: newSeries.rating ?? existingOld.rating,
        addedAt: preservedAddedAt,
      );
      currentList.add(updated);
      currentList.sort((a, b) => b.addedAt.compareTo(a.addedAt));

      _cachedItems[effectiveKey] = currentList;
      _cachedCompositeKeys.add(
        _compositeKeyFor(effectiveKey, FavoriteType.series, newIdStr),
      );

      await _persistScope(accountKey, currentList);
      notifyListeners();
    });
  }

  /// Localiza um favorito de série por correspondência estrita e inequívoca de identidade.
  Future<FavoriteItem?> findSeriesFavoriteByIdentity({
    required String scopeKey,
    required String seriesName,
  }) async {
    final seriesFavs = await getFavorites(
      scopeKey: scopeKey,
      type: FavoriteType.series,
    );
    final matches = seriesFavs
        .where((f) => SeriesIdentityVerifier.areSameSeriesIdentity(seriesName, f.name))
        .toList();
    if (matches.length == 1) return matches.first;
    return null;
  }

  /// Retorna a lista de itens favoritos filtrada por tipo (ou todos se type == null)
  Future<List<FavoriteItem>> getFavorites({
    required String scopeKey,
    FavoriteType? type,
  }) async {
    final all = await _loadFavoritesUnlocked(scopeKey);
    if (type == null) return all;
    return all.where((item) => item.type == type).toList();
  }

  /// Retorna o conjunto de IDs favoritos assincronamente
  Future<Set<String>> getFavoriteIds({
    required String scopeKey,
    required FavoriteType type,
  }) async {
    final items = await getFavorites(scopeKey: scopeKey, type: type);
    return items.map((i) => i.id).toSet();
  }

  /// Limpa todos os favoritos de um escopo e perfil (ou apenas de um tipo específico)
  Future<void> clearFavorites({
    required String scopeKey,
    FavoriteType? type,
  }) {
    return _enqueueWrite(() async {
      final effectiveKey = _effectiveCacheKey(scopeKey);
      await _loadFavoritesUnlocked(scopeKey);

      final currentList = _cachedItems[effectiveKey] ?? <FavoriteItem>[];
      if (type == null) {
        for (final item in currentList) {
          _cachedCompositeKeys.remove(
            _compositeKeyFor(effectiveKey, item.type, item.id),
          );
        }
        currentList.clear();
      } else {
        currentList.removeWhere((item) {
          if (item.type == type) {
            _cachedCompositeKeys.remove(
              _compositeKeyFor(effectiveKey, item.type, item.id),
            );
            return true;
          }
          return false;
        });
      }

      _cachedItems[effectiveKey] = currentList;
      await _persistScope(scopeKey, currentList);
      notifyListeners();
    });
  }

  Future<void> _persistScope(String scopeKey, List<FavoriteItem> items) async {
    final prefs = await _getPrefs();
    final storageKey = _effectiveCacheKey(scopeKey);
    final stringList = items.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(storageKey, stringList);
  }
}
