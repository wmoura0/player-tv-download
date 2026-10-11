import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/favorite_item.dart';

/// Serviço responsável por persistir e gerenciar favoritos localmente,
/// garantindo isolamento estrito por conta/servidor Xtream e por lista M3U.
///
/// Herda de [ChangeNotifier] para notificar a UI de alterações em tempo real
/// sem exigir reinicialização do aplicativo ou recargas completas.
class FavoritesService extends ChangeNotifier {
  static FavoritesService? _instance;

  /// Acesso singleton padrão para uso global pelo app
  static FavoritesService get instance => _instance ??= FavoritesService();

  /// Reinicializa a instância (útil para testes isolados)
  static void resetInstanceForTesting() {
    _instance = null;
  }

  final SharedPreferences? _prefsOverride;

  // Cache em memória de chaves compostas para checagens O(1): '$scopeKey#${type.name}#$id'
  final Set<String> _cachedCompositeKeys = <String>{};

  // Cache em memória dos itens por scopeKey para acesso rápido
  final Map<String, List<FavoriteItem>> _cachedItems = <String, List<FavoriteItem>>{};

  // Controle de carregamento por scopeKey
  final Set<String> _loadedScopes = <String>{};

  FavoritesService({SharedPreferences? prefs}) : _prefsOverride = prefs;

  Future<SharedPreferences> _getPrefs() async {
    return _prefsOverride ?? await SharedPreferences.getInstance();
  }

  /// Gera a chave de armazenamento isolada por escopo
  static String buildStorageKey(String scopeKey) {
    final cleanScope = scopeKey.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return 'player_fav_${cleanScope}_v1';
  }

  /// Carrega os favoritos do escopo para o cache em memória caso ainda não tenham sido lidos
  Future<List<FavoriteItem>> loadFavorites(String scopeKey) async {
    if (_loadedScopes.contains(scopeKey) && _cachedItems.containsKey(scopeKey)) {
      return List.unmodifiable(_cachedItems[scopeKey]!);
    }

    final prefs = await _getPrefs();
    final storageKey = buildStorageKey(scopeKey);
    final jsonList = prefs.getStringList(storageKey) ?? [];

    final items = <FavoriteItem>[];
    for (final jsonStr in jsonList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final item = FavoriteItem.fromJson(map);
        items.add(item);
        _cachedCompositeKeys.add(item.compositeKey);
      } catch (_) {
        // Ignorar itens corrompidos para não quebrar a carga
      }
    }

    // Ordenar pelos mais recentemente adicionados
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));

    _cachedItems[scopeKey] = items;
    _loadedScopes.add(scopeKey);
    return List.unmodifiable(items);
  }

  /// Retorna de forma síncrona se um item é favorito (a partir do cache em memória)
  bool isFavorite({
    required String scopeKey,
    required FavoriteType type,
    required String id,
  }) {
    final key = '$scopeKey#${type.name}#$id';
    return _cachedCompositeKeys.contains(key);
  }

  /// Retorna todos os IDs favoritos de um determinado tipo para o escopo
  Set<String> getFavoriteIdsSync({
    required String scopeKey,
    required FavoriteType type,
  }) {
    final items = _cachedItems[scopeKey] ?? [];
    return items.where((i) => i.type == type).map((i) => i.id).toSet();
  }

  /// Alterna o estado de favorito de um item.
  /// Retorna `true` se o item foi adicionado e `false` se foi removido.
  Future<bool> toggleFavorite(FavoriteItem item) async {
    // Garante que o escopo está carregado
    await loadFavorites(item.scopeKey);

    final currentlyFavorite = isFavorite(
      scopeKey: item.scopeKey,
      type: item.type,
      id: item.id,
    );

    if (currentlyFavorite) {
      await removeFavorite(
        scopeKey: item.scopeKey,
        type: item.type,
        id: item.id,
      );
      return false;
    } else {
      await addFavorite(item);
      return true;
    }
  }

  /// Adiciona um item aos favoritos com persistência local
  Future<void> addFavorite(FavoriteItem item) async {
    await loadFavorites(item.scopeKey);

    final currentList = _cachedItems[item.scopeKey] ?? <FavoriteItem>[];

    // Remove eventual duplicidade pré-existente
    currentList.removeWhere((i) => i.type == item.type && i.id == item.id);

    // Insere no início (mais recente)
    currentList.insert(0, item);
    _cachedItems[item.scopeKey] = currentList;
    _cachedCompositeKeys.add(item.compositeKey);

    await _persistScope(item.scopeKey, currentList);
    notifyListeners();
  }

  /// Remove um item dos favoritos
  Future<void> removeFavorite({
    required String scopeKey,
    required FavoriteType type,
    required String id,
  }) async {
    await loadFavorites(scopeKey);

    final currentList = _cachedItems[scopeKey] ?? <FavoriteItem>[];
    currentList.removeWhere((i) => i.type == type && i.id == id);
    _cachedItems[scopeKey] = currentList;
    _cachedCompositeKeys.remove('$scopeKey#${type.name}#$id');

    await _persistScope(scopeKey, currentList);
    notifyListeners();
  }

  /// Retorna a lista de itens favoritos filtrada por tipo (ou todos se type == null)
  Future<List<FavoriteItem>> getFavorites({
    required String scopeKey,
    FavoriteType? type,
  }) async {
    final all = await loadFavorites(scopeKey);
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

  /// Limpa todos os favoritos de um escopo (ou apenas de um tipo específico)
  Future<void> clearFavorites({
    required String scopeKey,
    FavoriteType? type,
  }) async {
    await loadFavorites(scopeKey);

    final currentList = _cachedItems[scopeKey] ?? <FavoriteItem>[];
    if (type == null) {
      for (final item in currentList) {
        _cachedCompositeKeys.remove(item.compositeKey);
      }
      currentList.clear();
    } else {
      currentList.removeWhere((item) {
        if (item.type == type) {
          _cachedCompositeKeys.remove(item.compositeKey);
          return true;
        }
        return false;
      });
    }

    _cachedItems[scopeKey] = currentList;
    await _persistScope(scopeKey, currentList);
    notifyListeners();
  }

  Future<void> _persistScope(String scopeKey, List<FavoriteItem> items) async {
    final prefs = await _getPrefs();
    final storageKey = buildStorageKey(scopeKey);
    final stringList = items.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(storageKey, stringList);
  }
}
