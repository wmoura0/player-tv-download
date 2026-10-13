import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../models/xtream_vod_info.dart';
import 'url_sanitizer.dart';
import 'xtream_auth_service.dart';

class XtreamCatalogException implements Exception {
  final String message;
  final int? statusCode;

  const XtreamCatalogException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Serviço responsável por consultar os catálogos reais da API Xtream Codes
/// (Categorias e listagens de TV ao vivo, Filmes e Séries) com cache em memória
/// e decodificação em segundo plano (Isolate.run).
class XtreamCatalogService extends ChangeNotifier {
  final String serverUrl;
  final String username;
  final String password;
  final http.Client _client;

  // Cache em memória durante a sessão
  List<XtreamCategory>? _liveCategoriesCache;
  List<XtreamCategory>? _vodCategoriesCache;
  List<XtreamCategory>? _seriesCategoriesCache;

  final Map<String, List<XtreamLiveStream>> _liveStreamsCache = {};
  final Map<String, List<XtreamVodStream>> _vodStreamsCache = {};
  final Map<String, List<XtreamSeriesItem>> _seriesCache = {};
  final Map<int, XtreamVodInfo> _vodInfoCache = {};
  final Map<int, XtreamSeriesInfo> _seriesInfoCache = {};

  bool _isPreloading = false;
  bool get isPreloading => _isPreloading;

  // Getters para validação e testes do estado do cache
  bool get hasLiveCategoriesCache => _liveCategoriesCache != null;
  bool get hasVodCategoriesCache => _vodCategoriesCache != null;
  bool get hasSeriesCategoriesCache => _seriesCategoriesCache != null;
  bool get hasVodInfoCache => _vodInfoCache.isNotEmpty;
  bool get hasSeriesInfoCache => _seriesInfoCache.isNotEmpty;
  int get liveStreamsCacheCount => _liveStreamsCache.length;
  int get vodStreamsCacheCount => _vodStreamsCache.length;
  int get seriesStreamsCacheCount => _seriesCache.length;
  int get vodInfoCacheCount => _vodInfoCache.length;
  int get seriesInfoCacheCount => _seriesInfoCache.length;

  int? get totalLiveCount => _liveStreamsCache['all']?.length;
  int? get totalVodCount => _vodStreamsCache['all']?.length;
  int? get totalSeriesCount => _seriesCache['all']?.length;

  int? getCategoryLiveCount(String catId) {
    if (catId == 'all') return totalLiveCount;
    return _liveStreamsCache['all']?.where((s) => s.categoryId == catId).length;
  }

  int? getCategoryVodCount(String catId) {
    if (catId == 'all') return totalVodCount;
    return _vodStreamsCache['all']?.where((s) => s.categoryId == catId).length;
  }

  int? getCategorySeriesCount(String catId) {
    if (catId == 'all') return totalSeriesCount;
    return _seriesCache['all']?.where((s) => s.categoryId == catId).length;
  }

  final Directory? cacheDirectoryOverride;


  XtreamCatalogService({
    required this.serverUrl,
    required this.username,
    required this.password,
    http.Client? client,
    this.cacheDirectoryOverride,
  }) : _client = client ?? http.Client();

  /// Prefixo seguro de cache derivado do servidor e usuário (sem expor senhas em plain text)
  String get _accountCachePrefix {
    final cleanServer = XtreamAuthService.normalizeServerUrl(serverUrl).toLowerCase();
    final cleanUser = username.trim().toLowerCase();
    final combined = '$cleanServer::$cleanUser';
    final hash = combined.codeUnits.fold<int>(0, (prev, elem) => ((prev << 5) - prev + elem) & 0x7FFFFFFF);
    return 'catalog_${hash.toRadixString(16)}';
  }

  Future<Directory?> _getCacheDirectory() async {
    if (cacheDirectoryOverride != null) return cacheDirectoryOverride;
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  Future<File?> _getCacheFile(String suffix) async {
    final dir = await _getCacheDirectory();
    if (dir == null) return null;
    return File('${dir.path}/${_accountCachePrefix}_$suffix.json');
  }

  Future<void> _writeDiskCache(String suffix, List<dynamic> jsonList) async {
    try {
      final file = await _getCacheFile(suffix);
      if (file == null) return;
      await file.writeAsString(jsonEncode(jsonList));
      await _updateMetadataLastUpdated();
    } catch (e) {
      debugPrint('[CACHE] Falha ao gravar cache em disco ($suffix): $e');
    }
  }

  Future<List<dynamic>?> _readDiskCache(String suffix) async {
    try {
      final file = await _getCacheFile(suffix);
      if (file == null || !await file.exists()) return null;
      final content = await file.readAsString();
      if (content.isEmpty) return null;
      final decoded = jsonDecode(content);
      if (decoded is List) return decoded;
      return null;
    } catch (e) {
      debugPrint('[CACHE] Falha ao ler cache em disco ($suffix): $e');
      return null;
    }
  }

  Future<void> _updateMetadataLastUpdated() async {
    try {
      final file = await _getCacheFile('meta');
      if (file == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      await file.writeAsString(jsonEncode({'last_updated': now}));
    } catch (_) {}
  }

  /// Retorna a data/hora da última sincronização bem-sucedida do catálogo com o servidor
  Future<DateTime?> getLastUpdated() async {
    try {
      final file = await _getCacheFile('meta');
      if (file == null || !await file.exists()) return null;
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map && decoded.containsKey('last_updated')) {
        final ms = decoded['last_updated'] as int?;
        if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Formata a data/hora da última atualização para exibição amigável
  static String formatLastUpdated(DateTime? dateTime) {
    if (dateTime == null) return 'Nunca atualizado';
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$day/$month/$year às $hour:$minute';
  }

  /// Limpa o cache da sessão em memória.
  void clearCache() {
    _liveCategoriesCache = null;
    _vodCategoriesCache = null;
    _seriesCategoriesCache = null;
    _liveStreamsCache.clear();
    _vodStreamsCache.clear();
    _seriesCache.clear();
    _vodInfoCache.clear();
    _seriesInfoCache.clear();
    debugPrint('[PERF] Cache do XtreamCatalogService completamente limpo.');
    notifyListeners();
  }

  /// Limpa também os arquivos de cache persistidos em disco para esta conta.
  Future<void> clearDiskCache() async {
    clearCache();
    final suffixes = [
      'live_cats',
      'live_streams_all',
      'vod_cats',
      'vod_streams_all',
      'series_cats',
      'series_all',
      'meta',
    ];
    for (final s in suffixes) {
      try {
        final file = await _getCacheFile(s);
        if (file != null && await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  /// Executa atualização completa e inteligente de todos os catálogos (TV, Filmes, Séries).
  /// Se a conexão falhar, mantém o cache existente intacto sem deixar telas vazias.
  Future<void> refreshAllCatalogs() async {
    debugPrint('[CACHE] Iniciando atualização completa inteligente do catálogo...');
    await fetchLiveCategories(forceRefresh: true);
    await fetchLiveStreams(categoryId: 'all', forceRefresh: true);
    await fetchVodCategories(forceRefresh: true);
    await fetchVodStreams(categoryId: 'all', forceRefresh: true);
    await fetchSeriesCategories(forceRefresh: true);
    await fetchSeries(categoryId: 'all', forceRefresh: true);
    await _updateMetadataLastUpdated();
    debugPrint('[CACHE] Atualização completa concluída com sucesso.');
    notifyListeners();
  }

  /// Verifica se já existem dados em cache (memória) para um determinado tipo de catálogo
  bool hasLoadedCacheFor(String typeKey) {
    if (typeKey == 'live') return _liveStreamsCache.containsKey('all') && _liveStreamsCache['all']!.isNotEmpty;
    if (typeKey == 'movies') return _vodStreamsCache.containsKey('all') && _vodStreamsCache['all']!.isNotEmpty;
    if (typeKey == 'series') return _seriesCache.containsKey('all') && _seriesCache['all']!.isNotEmpty;
    return false;
  }

  /// Pré-carrega catálogos em segundo plano de forma inteligente:
  /// 1. Se já houver dados em disco, carrega-os transparentemente para a memória sem rede.
  /// 2. Se não houver dados locais, busca de forma controlada sequencial no servidor.
  /// 3. Em caso de falha de conexão, preserva os dados existentes sem apagar nada.
  Future<void> preloadCatalogsInBackground() async {
    if (_isPreloading) return;
    _isPreloading = true;
    try {
      // 1. Tenta alimentar memória a partir do disco primeiro (sem rede)
      if (_liveCategoriesCache == null) {
        final diskCats = await _readDiskCache('live_cats');
        if (diskCats != null && diskCats.isNotEmpty) {
          _liveCategoriesCache = diskCats
              .map((i) => XtreamCategory.fromJson(i as Map<String, dynamic>))
              .toList();
        }
      }
      if (!_liveStreamsCache.containsKey('all')) {
        final diskLive = await _readDiskCache('live_streams_all');
        if (diskLive != null && diskLive.isNotEmpty) {
          _liveStreamsCache['all'] = diskLive
              .map((i) => XtreamLiveStream.fromJson(i as Map<String, dynamic>))
              .toList();
        }
      }
      if (_vodCategoriesCache == null) {
        final diskVodCats = await _readDiskCache('vod_cats');
        if (diskVodCats != null && diskVodCats.isNotEmpty) {
          _vodCategoriesCache = diskVodCats
              .map((i) => XtreamCategory.fromJson(i as Map<String, dynamic>))
              .toList();
        }
      }
      if (!_vodStreamsCache.containsKey('all')) {
        final diskVod = await _readDiskCache('vod_streams_all');
        if (diskVod != null && diskVod.isNotEmpty) {
          _vodStreamsCache['all'] = diskVod
              .map((i) => XtreamVodStream.fromJson(i as Map<String, dynamic>))
              .toList();
        }
      }
      if (_seriesCategoriesCache == null) {
        final diskSeriesCats = await _readDiskCache('series_cats');
        if (diskSeriesCats != null && diskSeriesCats.isNotEmpty) {
          _seriesCategoriesCache = diskSeriesCats
              .map((i) => XtreamCategory.fromJson(i as Map<String, dynamic>))
              .toList();
        }
      }
      if (!_seriesCache.containsKey('all')) {
        final diskSeries = await _readDiskCache('series_all');
        if (diskSeries != null && diskSeries.isNotEmpty) {
          _seriesCache['all'] = diskSeries
              .map((i) => XtreamSeriesItem.fromJson(i as Map<String, dynamic>))
              .toList();
        }
      }

      notifyListeners();

      // 2. Se ainda faltam dados básicos, busca na API de forma sequencial controlada
      if (_liveCategoriesCache == null) {
        await fetchLiveCategories();
      }
      if (!_liveStreamsCache.containsKey('all')) {
        await fetchLiveStreams(categoryId: 'all');
      }
      if (_vodCategoriesCache == null) {
        await fetchVodCategories();
      }
      if (!_vodStreamsCache.containsKey('all')) {
        await fetchVodStreams(categoryId: 'all');
      }
      if (_seriesCategoriesCache == null) {
        await fetchSeriesCategories();
      }
      if (!_seriesCache.containsKey('all')) {
        await fetchSeries(categoryId: 'all');
      }

      await _updateMetadataLastUpdated();
      notifyListeners();
    } catch (e) {
      debugPrint('[CATALOG] Pré-carregamento em segundo plano finalizado/interrompido: $e');
    } finally {
      _isPreloading = false;
    }
  }

  /// Retorna até [limit] filmes recentes já presentes no cache com data confiável.
  /// Não realiza nenhuma requisição de rede adicional.
  List<XtreamVodStream> getRecentCachedMovies({int limit = 5}) {
    final all = _vodStreamsCache.values.expand((list) => list).toList();
    final withDate = all.where((m) => m.addedDate != null).toList();
    if (withDate.isEmpty) return [];
    withDate.sort((a, b) => b.addedDate!.compareTo(a.addedDate!));
    final unique = <int, XtreamVodStream>{};
    for (final m in withDate) {
      unique.putIfAbsent(m.streamId, () => m);
    }
    return unique.values.take(limit).toList();
  }

  /// Retorna até [limit] filmes recentes presentes no cache em memória ou disco com data confiável.
  /// Não realiza requisições de rede. Se a memória estiver vazia, carrega do disco de forma transparente.
  Future<List<XtreamVodStream>> getRecentMovies({int limit = 5}) async {
    final cached = getRecentCachedMovies(limit: limit);
    if (cached.isNotEmpty) return cached;

    final diskAll = await _readDiskCache('vod_streams_all');
    if (diskAll != null && diskAll.isNotEmpty) {
      final allMovies = diskAll
          .map((item) => XtreamVodStream.fromJson(item as Map<String, dynamic>))
          .toList();
      _vodStreamsCache['all'] = allMovies;
      return getRecentCachedMovies(limit: limit);
    }
    return [];
  }

  /// Retorna até [limit] séries recentes já presentes no cache com data confiável.
  /// Não realiza nenhuma requisição de rede adicional.
  List<XtreamSeriesItem> getRecentCachedSeries({int limit = 5}) {
    final all = _seriesCache.values.expand((list) => list).toList();
    final withDate = all.where((s) => s.addedDate != null).toList();
    if (withDate.isEmpty) return [];
    withDate.sort((a, b) => b.addedDate!.compareTo(a.addedDate!));
    final unique = <int, XtreamSeriesItem>{};
    for (final s in withDate) {
      unique.putIfAbsent(s.seriesId, () => s);
    }
    return unique.values.take(limit).toList();
  }

  /// Retorna até [limit] séries recentes presentes no cache em memória ou disco com data confiável.
  /// Não realiza requisições de rede. Se a memória estiver vazia, carrega do disco de forma transparente.
  Future<List<XtreamSeriesItem>> getRecentSeries({int limit = 5}) async {
    final cached = getRecentCachedSeries(limit: limit);
    if (cached.isNotEmpty) return cached;

    final diskAll = await _readDiskCache('series_all');
    if (diskAll != null && diskAll.isNotEmpty) {
      final allSeries = diskAll
          .map((item) => XtreamSeriesItem.fromJson(item as Map<String, dynamic>))
          .toList();
      _seriesCache['all'] = allSeries;
      return getRecentCachedSeries(limit: limit);
    }
    return [];
  }

  // =========================================================================
  // TV AO VIVO
  // =========================================================================

  /// Consulta as categorias de TV ao vivo (`action=get_live_categories`).
  Future<List<XtreamCategory>> fetchLiveCategories({bool forceRefresh = false}) async {
    if (!forceRefresh && _liveCategoriesCache != null) {
      debugPrint('[PERF] [CACHE HIT MEMORY] get_live_categories (${_liveCategoriesCache!.length} categorias)');
      return _liveCategoriesCache!;
    }

    if (!forceRefresh) {
      final diskData = await _readDiskCache('live_cats');
      if (diskData != null && diskData.isNotEmpty) {
        final categories = diskData
            .map((item) => XtreamCategory.fromJson(item as Map<String, dynamic>))
            .toList();
        _liveCategoriesCache = categories;
        debugPrint('[PERF] [CACHE HIT DISK] get_live_categories (${categories.length} categorias)');
        return categories;
      }
    }

    final data = await _fetchApiList('get_live_categories');
    final categories = data
        .map((item) => XtreamCategory.fromJson(item as Map<String, dynamic>))
        .toList();

    _liveCategoriesCache = categories;
    await _writeDiskCache('live_cats', categories.map((c) => c.toJson()).toList());
    return categories;
  }

  /// Consulta os canais de TV ao vivo (`action=get_live_streams`).
  /// Se [categoryId] for informado, filtra por categoria no servidor ou localmente.
  Future<List<XtreamLiveStream>> fetchLiveStreams({
    String? categoryId,
    bool forceRefresh = false,
  }) async {
    final cacheKey = categoryId ?? 'all';
    if (!forceRefresh && _liveStreamsCache.containsKey(cacheKey)) {
      final cached = _liveStreamsCache[cacheKey]!;
      debugPrint('[PERF] [CACHE HIT MEMORY] get_live_streams (cat: $cacheKey) -> ${cached.length} canais');
      return cached;
    }

    // Se buscamos todos ou se uma categoria específica pode ser satisfeita pelo cache de todos
    if (!forceRefresh) {
      if (_liveStreamsCache.containsKey('all')) {
        final all = _liveStreamsCache['all']!;
        if (categoryId != null && categoryId != 'all') {
          final filtered = all.where((s) => s.categoryId == categoryId).toList();
          _liveStreamsCache[cacheKey] = filtered;
          return filtered;
        }
      } else {
        final diskAll = await _readDiskCache('live_streams_all');
        if (diskAll != null && diskAll.isNotEmpty) {
          final allStreams = diskAll
              .map((item) => XtreamLiveStream.fromJson(item as Map<String, dynamic>))
              .toList();
          _liveStreamsCache['all'] = allStreams;
          debugPrint('[PERF] [CACHE HIT DISK] get_live_streams -> ${allStreams.length} canais');
          if (categoryId != null && categoryId != 'all') {
            final filtered = allStreams.where((s) => s.categoryId == categoryId).toList();
            _liveStreamsCache[cacheKey] = filtered;
            return filtered;
          }
          return allStreams;
        }
      }
    }

    final extraParams = <String, String>{};
    if (categoryId != null && categoryId != 'all' && categoryId.isNotEmpty) {
      extraParams['category_id'] = categoryId;
    }

    final data = await _fetchApiList('get_live_streams', extraParams: extraParams);
    
    // Mapeamento em Isolate para grandes volumes de canais
    final swMap = Stopwatch()..start();
    List<XtreamLiveStream> streams;
    if (data.length > 500) {
      streams = await Isolate.run(() => data
          .map((item) => XtreamLiveStream.fromJson(item as Map<String, dynamic>))
          .toList());
    } else {
      streams = data
          .map((item) => XtreamLiveStream.fromJson(item as Map<String, dynamic>))
          .toList();
    }
    swMap.stop();
    debugPrint('[PERF] MAP get_live_streams: ${streams.length} canais mapeados em ${swMap.elapsedMilliseconds}ms');

    if (cacheKey == 'all') {
      await _writeDiskCache('live_streams_all', streams.map((s) => s.toJson()).toList());
    }

    if (categoryId != null && categoryId != 'all') {
      final filtered = streams.where((s) => s.categoryId == categoryId).toList();
      _liveStreamsCache[cacheKey] = filtered;
      return filtered;
    }

    _liveStreamsCache[cacheKey] = streams;
    return streams;
  }

  // =========================================================================
  // FILMES (VOD)
  // =========================================================================

  /// Consulta as categorias de Filmes (`action=get_vod_categories`).
  Future<List<XtreamCategory>> fetchVodCategories({bool forceRefresh = false}) async {
    if (!forceRefresh && _vodCategoriesCache != null) {
      debugPrint('[PERF] [CACHE HIT MEMORY] get_vod_categories (${_vodCategoriesCache!.length} categorias)');
      return _vodCategoriesCache!;
    }

    if (!forceRefresh) {
      final diskData = await _readDiskCache('vod_cats');
      if (diskData != null && diskData.isNotEmpty) {
        final categories = diskData
            .map((item) => XtreamCategory.fromJson(item as Map<String, dynamic>))
            .toList();
        _vodCategoriesCache = categories;
        debugPrint('[PERF] [CACHE HIT DISK] get_vod_categories (${categories.length} categorias)');
        return categories;
      }
    }

    final data = await _fetchApiList('get_vod_categories');
    final categories = data
        .map((item) => XtreamCategory.fromJson(item as Map<String, dynamic>))
        .toList();

    _vodCategoriesCache = categories;
    await _writeDiskCache('vod_cats', categories.map((c) => c.toJson()).toList());
    return categories;
  }

  /// Consulta os filmes (`action=get_vod_streams`).
  Future<List<XtreamVodStream>> fetchVodStreams({
    String? categoryId,
    bool forceRefresh = false,
  }) async {
    final cacheKey = categoryId ?? 'all';
    if (!forceRefresh && _vodStreamsCache.containsKey(cacheKey)) {
      final cached = _vodStreamsCache[cacheKey]!;
      debugPrint('[PERF] [CACHE HIT MEMORY] get_vod_streams (cat: $cacheKey) -> ${cached.length} filmes');
      return cached;
    }

    if (!forceRefresh) {
      if (_vodStreamsCache.containsKey('all')) {
        final all = _vodStreamsCache['all']!;
        if (categoryId != null && categoryId != 'all') {
          final filtered = all.where((s) => s.categoryId == categoryId).toList();
          _vodStreamsCache[cacheKey] = filtered;
          return filtered;
        }
      } else {
        final diskAll = await _readDiskCache('vod_streams_all');
        if (diskAll != null && diskAll.isNotEmpty) {
          final allMovies = diskAll
              .map((item) => XtreamVodStream.fromJson(item as Map<String, dynamic>))
              .toList();
          _vodStreamsCache['all'] = allMovies;
          debugPrint('[PERF] [CACHE HIT DISK] get_vod_streams -> ${allMovies.length} filmes');
          if (categoryId != null && categoryId != 'all') {
            final filtered = allMovies.where((s) => s.categoryId == categoryId).toList();
            _vodStreamsCache[cacheKey] = filtered;
            return filtered;
          }
          return allMovies;
        }
      }
    }

    final extraParams = <String, String>{};
    if (categoryId != null && categoryId != 'all' && categoryId.isNotEmpty) {
      extraParams['category_id'] = categoryId;
    }

    final data = await _fetchApiList('get_vod_streams', extraParams: extraParams);

    final swMap = Stopwatch()..start();
    List<XtreamVodStream> streams;
    if (data.length > 500) {
      streams = await Isolate.run(() => data
          .map((item) => XtreamVodStream.fromJson(item as Map<String, dynamic>))
          .toList());
    } else {
      streams = data
          .map((item) => XtreamVodStream.fromJson(item as Map<String, dynamic>))
          .toList();
    }
    swMap.stop();
    debugPrint('[PERF] MAP get_vod_streams: ${streams.length} filmes mapeados em ${swMap.elapsedMilliseconds}ms');

    if (cacheKey == 'all') {
      await _writeDiskCache('vod_streams_all', streams.map((s) => s.toJson()).toList());
    }

    if (categoryId != null && categoryId != 'all') {
      final filtered = streams.where((s) => s.categoryId == categoryId).toList();
      _vodStreamsCache[cacheKey] = filtered;
      return filtered;
    }

    _vodStreamsCache[cacheKey] = streams;
    return streams;
  }

  /// Consulta os detalhes adicionais de um filme (`action=get_vod_info&vod_id=...`).
  /// Retorna nulo se o servidor não fornecer ou se a requisição falhar.
  Future<XtreamVodInfo?> fetchVodInfo(int vodId, {bool forceRefresh = false}) async {
    if (!forceRefresh && _vodInfoCache.containsKey(vodId)) {
      debugPrint('[PERF] [CACHE HIT] get_vod_info (vod_id: $vodId)');
      return _vodInfoCache[vodId];
    }

    try {
      final data = await _fetchApiMap(
        'get_vod_info',
        extraParams: {'vod_id': vodId.toString()},
      );

      if (data.isEmpty) return null;

      final info = XtreamVodInfo.fromJson(data, fallbackStreamId: vodId);
      _vodInfoCache[vodId] = info;
      return info;
    } catch (e) {
      debugPrint('[VOD INFO] Detalhes adicionais não disponíveis para vod_id=$vodId');
      return null;
    }
  }

  // =========================================================================
  // SÉRIES
  // =========================================================================

  /// Consulta as categorias de Séries (`action=get_series_categories`).
  Future<List<XtreamCategory>> fetchSeriesCategories({bool forceRefresh = false}) async {
    if (!forceRefresh && _seriesCategoriesCache != null) {
      debugPrint('[PERF] [CACHE HIT MEMORY] get_series_categories (${_seriesCategoriesCache!.length} categorias)');
      return _seriesCategoriesCache!;
    }

    if (!forceRefresh) {
      final diskData = await _readDiskCache('series_cats');
      if (diskData != null && diskData.isNotEmpty) {
        final categories = diskData
            .map((item) => XtreamCategory.fromJson(item as Map<String, dynamic>))
            .toList();
        _seriesCategoriesCache = categories;
        debugPrint('[PERF] [CACHE HIT DISK] get_series_categories (${categories.length} categorias)');
        return categories;
      }
    }

    final data = await _fetchApiList('get_series_categories');
    final categories = data
        .map((item) => XtreamCategory.fromJson(item as Map<String, dynamic>))
        .toList();

    _seriesCategoriesCache = categories;
    await _writeDiskCache('series_cats', categories.map((c) => c.toJson()).toList());
    return categories;
  }

  /// Consulta as séries (`action=get_series`).
  Future<List<XtreamSeriesItem>> fetchSeries({
    String? categoryId,
    bool forceRefresh = false,
  }) async {
    final cacheKey = categoryId ?? 'all';
    if (!forceRefresh && _seriesCache.containsKey(cacheKey)) {
      final cached = _seriesCache[cacheKey]!;
      debugPrint('[PERF] [CACHE HIT MEMORY] get_series (cat: $cacheKey) -> ${cached.length} séries');
      return cached;
    }

    if (!forceRefresh) {
      if (_seriesCache.containsKey('all')) {
        final all = _seriesCache['all']!;
        if (categoryId != null && categoryId != 'all') {
          final filtered = all.where((s) => s.categoryId == categoryId).toList();
          _seriesCache[cacheKey] = filtered;
          return filtered;
        }
      } else {
        final diskAll = await _readDiskCache('series_all');
        if (diskAll != null && diskAll.isNotEmpty) {
          final allSeries = diskAll
              .map((item) => XtreamSeriesItem.fromJson(item as Map<String, dynamic>))
              .toList();
          _seriesCache['all'] = allSeries;
          debugPrint('[PERF] [CACHE HIT DISK] get_series -> ${allSeries.length} séries');
          if (categoryId != null && categoryId != 'all') {
            final filtered = allSeries.where((s) => s.categoryId == categoryId).toList();
            _seriesCache[cacheKey] = filtered;
            return filtered;
          }
          return allSeries;
        }
      }
    }

    final extraParams = <String, String>{};
    if (categoryId != null && categoryId != 'all' && categoryId.isNotEmpty) {
      extraParams['category_id'] = categoryId;
    }

    final data = await _fetchApiList('get_series', extraParams: extraParams);

    final swMap = Stopwatch()..start();
    List<XtreamSeriesItem> series;
    if (data.length > 500) {
      series = await Isolate.run(() => data
          .map((item) => XtreamSeriesItem.fromJson(item as Map<String, dynamic>))
          .toList());
    } else {
      series = data
          .map((item) => XtreamSeriesItem.fromJson(item as Map<String, dynamic>))
          .toList();
    }
    swMap.stop();
    debugPrint('[PERF] MAP get_series: ${series.length} séries mapeadas em ${swMap.elapsedMilliseconds}ms');

    if (cacheKey == 'all') {
      await _writeDiskCache('series_all', series.map((s) => s.toJson()).toList());
    }

    if (categoryId != null && categoryId != 'all') {
      final filtered = series.where((s) => s.categoryId == categoryId).toList();
      _seriesCache[cacheKey] = filtered;
      return filtered;
    }

    _seriesCache[cacheKey] = series;
    return series;
  }

  /// Consulta os detalhes e episódios de uma série (`action=get_series_info&series_id=...`).
  Future<XtreamSeriesInfo?> fetchSeriesInfo(int seriesId, {bool forceRefresh = false}) async {
    if (!forceRefresh && _seriesInfoCache.containsKey(seriesId)) {
      debugPrint('[PERF] [CACHE HIT] get_series_info (series_id: $seriesId)');
      return _seriesInfoCache[seriesId];
    }

    try {
      final data = await _fetchApiMap(
        'get_series_info',
        extraParams: {'series_id': seriesId.toString()},
      );

      if (data.isEmpty) return null;

      final info = XtreamSeriesInfo.fromJson(data);
      _seriesInfoCache[seriesId] = info;
      return info;
    } catch (e) {
      debugPrint('[SERIES INFO] Detalhes não disponíveis para series_id=$seriesId: $e');
      return null;
    }
  }

  /// Consulta o Guia Eletrônico de Programação (EPG) para um canal ao vivo (`action=get_short_epg&stream_id=...`).
  /// Se a API retornar dados válidos, retorna os programas encontrados.
  /// Se não houver dados, o servidor retornar vazio ou falhar, retorna lista vazia de forma segura (sem dados fictícios).
  Future<List<XtreamEpgProgram>> fetchShortEpg(int streamId, {int limit = 4}) async {
    try {
      final data = await _fetchApiMap(
        'get_short_epg',
        extraParams: {
          'stream_id': streamId.toString(),
          'limit': limit.toString(),
        },
      );

      if (data.isEmpty || data['epg_listings'] == null) {
        return const [];
      }

      final listings = data['epg_listings'];
      if (listings is List) {
        return listings
            .whereType<Map<String, dynamic>>()
            .map((item) => XtreamEpgProgram.fromJson(item))
            .toList();
      }
      return const [];
    } catch (e) {
      debugPrint('[EPG] Dados de programação não disponíveis para stream_id=$streamId: $e');
      return const [];
    }
  }

  // =========================================================================
  // MÉTODO AUXILIAR PRIVADO DE REQUISIÇÃO E PARSING SEGURO
  // =========================================================================

  Future<List<dynamic>> _fetchApiList(
    String action, {
    Map<String, String>? extraParams,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final cleanServer = XtreamAuthService.normalizeServerUrl(serverUrl);
    final sanitizedBase = UrlSanitizer.sanitize(cleanServer);

    final uri = Uri.tryParse('$cleanServer/player_api.php');
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw const XtreamCatalogException('Endereço de servidor inválido.');
    }

    final query = <String, String>{
      'username': username.trim(),
      'password': password.trim(),
      'action': action,
    };

    if (extraParams != null) {
      query.addAll(extraParams);
    }

    final requestUri = uri.replace(queryParameters: query);

    final swHttp = Stopwatch()..start();
    try {
      final response = await _client
          .get(
            requestUri,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
              'Accept': 'application/json, */*',
            },
          )
          .timeout(timeout);

      swHttp.stop();
      final bodySizeBytes = response.bodyBytes.length;
      final sizeDesc = bodySizeBytes > 1024 * 1024
          ? '${(bodySizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB'
          : '${(bodySizeBytes / 1024).toStringAsFixed(1)} KB';

      debugPrint(
        '[PERF] [HTTP] action=$action '
        '${extraParams != null && extraParams.containsKey('category_id') ? '(cat: ${extraParams['category_id']}) ' : ''}'
        'em ${swHttp.elapsedMilliseconds}ms | Payload: $sizeDesc ($bodySizeBytes bytes)',
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw XtreamCatalogException(
          'Sessão expirada ou acesso negado pelo servidor.',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode == 404) {
        throw XtreamCatalogException(
          'Endpoint "player_api.php?action=$action" não foi encontrado no servidor.',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        throw XtreamCatalogException(
          'O servidor retornou erro HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }

      if (response.bodyBytes.isEmpty) {
        return [];
      }

      // Decodificação JSON: se o payload for maior que 30KB, processa em segundo plano via Isolate.run
      final swParse = Stopwatch()..start();
      List<dynamic> decodedList;

      if (bodySizeBytes > 30 * 1024) {
        decodedList = await Isolate.run(() => _decodeBytesToJsonList(response.bodyBytes));
      } else {
        decodedList = _decodeBytesToJsonList(response.bodyBytes);
      }

      swParse.stop();
      debugPrint(
        '[PERF] [PARSE] action=$action: decodificado em ${swParse.elapsedMilliseconds}ms | '
        '${decodedList.length} registros',
      );

      return decodedList;
    } on XtreamCatalogException {
      rethrow;
    } on TimeoutException {
      throw XtreamCatalogException('Tempo limite esgotado ao consultar $action em $sanitizedBase.');
    } on SocketException catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.message);
      throw XtreamCatalogException('Erro de conexão ao acessar $sanitizedBase: $safeErr');
    } catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      throw XtreamCatalogException('Erro ao processar dados de $action: $safeErr');
    }
  }

  /// Função auxiliar estática pura para decodificação em Isolate
  static List<dynamic> _decodeBytesToJsonList(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      text = latin1.decode(bytes);
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) return [];

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) return decoded;
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Constrói a lista ordenada de URLs candidatas para reprodução de um canal ao vivo.
  List<String> buildLiveStreamUrls(XtreamLiveStream stream) {
    return buildLiveStreamUrlsById(
      stream.streamId,
      directSource: stream.directSource,
    );
  }

  /// Constrói URLs de stream por ID, garantindo a codificação correta de credenciais.
  List<String> buildLiveStreamUrlsById(int streamId, {String? directSource}) {
    final cleanServer = XtreamAuthService.normalizeServerUrl(serverUrl);
    final user = Uri.encodeComponent(username.trim());
    final pass = Uri.encodeComponent(password.trim());

    final urls = <String>[];

    final direct = directSource?.trim();
    if (direct != null && (direct.startsWith('http://') || direct.startsWith('https://'))) {
      urls.add(direct);
    }

    urls.add('$cleanServer/live/$user/$pass/$streamId.ts');
    urls.add('$cleanServer/live/$user/$pass/$streamId.m3u8');
    urls.add('$cleanServer/$user/$pass/$streamId.ts');

    return urls;
  }

  /// Constrói a lista ordenada de URLs candidatas para reprodução de um filme (VOD).
  List<String> buildVodStreamUrls(XtreamVodStream stream) {
    return buildVodStreamUrlsById(
      stream.streamId,
      extension: stream.containerExtension,
    );
  }

  /// Constrói URLs de filme por ID, respeitando a extensão fornecida pelo catálogo
  /// com rotas de contingência e codificação segura de credenciais.
  List<String> buildVodStreamUrlsById(int streamId, {String? extension}) {
    final cleanServer = XtreamAuthService.normalizeServerUrl(serverUrl);
    final user = Uri.encodeComponent(username.trim());
    final pass = Uri.encodeComponent(password.trim());

    final cleanExt = (extension != null && extension.trim().isNotEmpty)
        ? extension.trim().toLowerCase().replaceAll('.', '')
        : 'mp4';

    final urls = <String>[];

    // 1. Rota padrão Xtream Codes para VOD: /movie/$user/$pass/$id.$ext
    urls.add('$cleanServer/movie/$user/$pass/$streamId.$cleanExt');

    // 2. Contingência com extensão alternativa apenas quando fizer sentido
    if (cleanExt != 'mp4') {
      urls.add('$cleanServer/movie/$user/$pass/$streamId.mp4');
    } else {
      urls.add('$cleanServer/movie/$user/$pass/$streamId.mkv');
    }

    // 3. Rota legada direta sem /movie/
    urls.add('$cleanServer/$user/$pass/$streamId.$cleanExt');

    return urls;
  }

  /// Constrói a lista ordenada de URLs candidatas para reprodução de um episódio de série.
  List<String> buildSeriesStreamUrls(XtreamSeriesEpisode episode) {
    return buildSeriesStreamUrlsById(
      episode.id,
      extension: episode.containerExtension,
      directSource: episode.directSource,
    );
  }

  /// Constrói URLs de episódio de série por ID, respeitando a extensão fornecida pelo catálogo
  /// com rotas de contingência e codificação segura de credenciais.
  List<String> buildSeriesStreamUrlsById(
    int episodeId, {
    String? extension,
    String? directSource,
  }) {
    final cleanServer = XtreamAuthService.normalizeServerUrl(serverUrl);
    final user = Uri.encodeComponent(username.trim());
    final pass = Uri.encodeComponent(password.trim());

    final cleanExt = (extension != null && extension.trim().isNotEmpty)
        ? extension.trim().toLowerCase().replaceAll('.', '')
        : 'mp4';

    final urls = <String>[];

    // 1. Rota padrão Xtream Codes para Séries: /series/$user/$pass/$id.$ext
    urls.add('$cleanServer/series/$user/$pass/$episodeId.$cleanExt');

    // 2. Contingência com extensão alternativa apenas quando fizer sentido
    if (cleanExt != 'mp4') {
      urls.add('$cleanServer/series/$user/$pass/$episodeId.mp4');
    } else {
      urls.add('$cleanServer/series/$user/$pass/$episodeId.mkv');
    }

    // 3. Rota legada direta sem /series/
    urls.add('$cleanServer/$user/$pass/$episodeId.$cleanExt');

    // 4. Contingência de directSource apenas como última opção
    final direct = directSource?.trim();
    if (direct != null && (direct.startsWith('http://') || direct.startsWith('https://'))) {
      urls.add(direct);
    }

    return urls;
  }

  Future<Map<String, dynamic>> _fetchApiMap(
    String action, {
    Map<String, String>? extraParams,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final cleanServer = XtreamAuthService.normalizeServerUrl(serverUrl);
    final sanitizedBase = UrlSanitizer.sanitize(cleanServer);

    final uri = Uri.tryParse('$cleanServer/player_api.php');
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw const XtreamCatalogException('Endereço de servidor inválido.');
    }

    final query = <String, String>{
      'username': username.trim(),
      'password': password.trim(),
      'action': action,
    };

    if (extraParams != null) {
      query.addAll(extraParams);
    }

    final requestUri = uri.replace(queryParameters: query);

    try {
      final response = await _client
          .get(
            requestUri,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
              'Accept': 'application/json, */*',
            },
          )
          .timeout(timeout);

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw XtreamCatalogException(
          'Sessão expirada ou acesso negado pelo servidor.',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        throw XtreamCatalogException(
          'O servidor retornou erro HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }

      if (response.bodyBytes.isEmpty) {
        return {};
      }

      String text;
      try {
        text = utf8.decode(response.bodyBytes);
      } catch (_) {
        text = latin1.decode(response.bodyBytes);
      }

      final trimmed = text.trim();
      if (trimmed.isEmpty) return {};

      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      } else if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return {};
    } on XtreamCatalogException {
      rethrow;
    } on TimeoutException {
      throw XtreamCatalogException('Tempo limite esgotado ao consultar $action em $sanitizedBase.');
    } on SocketException catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.message);
      throw XtreamCatalogException('Erro de conexão ao acessar $sanitizedBase: $safeErr');
    } catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      throw XtreamCatalogException('Erro ao processar dados de $action: $safeErr');
    }
  }
}
