import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço responsável por persistir e gerenciar quais categorias da TV ao vivo
/// estão ocultas pelo usuário, com escopo isolado por fonte (Playlist M3U ou Conta Xtream).
class HiddenCategoriesService extends ChangeNotifier {
  static final HiddenCategoriesService instance = HiddenCategoriesService._internal();

  HiddenCategoriesService._internal();

  @visibleForTesting
  HiddenCategoriesService.forTesting({SharedPreferences? prefs}) {
    _prefs = prefs;
  }

  SharedPreferences? _prefs;
  final Map<String, Set<String>> _hiddenMap = {};

  /// Inicializa o serviço com SharedPreferences.
  Future<void> init([SharedPreferences? prefs]) async {
    _prefs = prefs ?? await SharedPreferences.getInstance();
  }

  /// Retorna o conjunto de IDs ou nomes de categorias ocultas para a fonte especificada.
  Set<String> getHiddenCategories(String scopeKey) {
    if (_hiddenMap.containsKey(scopeKey)) {
      return _hiddenMap[scopeKey]!;
    }
    final raw = _prefs?.getStringList('hidden_cats_$scopeKey') ?? [];
    final set = raw.toSet();
    _hiddenMap[scopeKey] = set;
    return set;
  }

  /// Verifica se uma categoria específica está oculta.
  bool isHidden(String scopeKey, String categoryIdOrName) {
    final set = getHiddenCategories(scopeKey);
    return set.contains(categoryIdOrName.trim());
  }

  /// Define o estado de ocultação de uma categoria e persiste localmente.
  Future<void> setHidden(String scopeKey, String categoryIdOrName, bool hidden) async {
    final clean = categoryIdOrName.trim();
    if (clean.isEmpty) return;
    final set = getHiddenCategories(scopeKey);
    if (hidden) {
      set.add(clean);
    } else {
      set.remove(clean);
    }
    await _save(scopeKey);
    notifyListeners();
  }

  /// Alterna o estado de ocultação de uma categoria e persiste localmente.
  Future<void> toggleHidden(String scopeKey, String categoryIdOrName) async {
    final clean = categoryIdOrName.trim();
    if (clean.isEmpty) return;
    final set = getHiddenCategories(scopeKey);
    if (set.contains(clean)) {
      set.remove(clean);
    } else {
      set.add(clean);
    }
    await _save(scopeKey);
    notifyListeners();
  }

  /// Restaura todas as categorias da fonte para a condição visível.
  Future<void> restoreAll(String scopeKey) async {
    final set = getHiddenCategories(scopeKey);
    set.clear();
    await _save(scopeKey);
    notifyListeners();
  }

  Future<void> _save(String scopeKey) async {
    _prefs ??= await SharedPreferences.getInstance();
    final list = _hiddenMap[scopeKey]?.toList() ?? [];
    await _prefs?.setStringList('hidden_cats_$scopeKey', list);
  }

  @visibleForTesting
  void clearForTesting() {
    _hiddenMap.clear();
  }
}
