import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/epg_program.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../services/epg_service.dart';
import '../services/favorites_service.dart';
import '../services/hidden_categories_service.dart';
import '../services/playback_metrics.dart';
import '../services/playback_progress_service.dart';
import '../services/player_stability_manager.dart';
import '../services/secure_storage_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import '../widgets/catalog_sidebar.dart';
import '../widgets/epg_guide_view.dart';
import '../widgets/live_player_view.dart';
import 'series_detail_screen.dart';
import 'vod_detail_screen.dart';

enum XtreamCatalogType { live, movies, series }

/// Tela genérica e responsiva para exibição do catálogo real de TV ao vivo, Filmes ou Séries.
class XtreamCatalogScreen extends StatefulWidget {
  final XtreamCatalogType type;
  final XtreamCatalogService? catalogService;
  final XtreamLiveStream? initialLiveStream;

  const XtreamCatalogScreen({
    super.key,
    required this.type,
    this.catalogService,
    this.initialLiveStream,
  });

  @override
  State<XtreamCatalogScreen> createState() => _XtreamCatalogScreenState();
}

class _XtreamCatalogScreenState extends State<XtreamCatalogScreen>
    with WidgetsBindingObserver {
  XtreamCatalogService? _service;
  bool _isInitLoading = true;
  String? _initError;

  List<XtreamCategory> _categories = [];
  String _selectedCategoryId = 'all';

  bool _isItemsLoading = false;
  String? _itemsError;
  List<dynamic> _currentItems = [];

  String _searchQuery = '';
  final _searchController = TextEditingController();

  // Estado de reprodução de TV ao vivo (compartilhado entre mini player e tela cheia)
  XtreamLiveStream? _activeLiveStream;
  VideoPlayerController? _playerController;
  bool _isFullscreen = false;
  bool _isPlayerLoading = false;
  bool _isPlayerBuffering = false;
  String? _playerError;
  int _reconnectAttempts = 0;
  List<String> _candidateUrls = [];
  int _currentCandidateIndex = 0;
  LiveVideoFitMode _fitMode = LiveVideoFitMode.contain;
  String? _currentProgram;
  String? _nextProgram;
  EpgChannelSchedule? _activeSchedule;
  late final PlayerStabilityManager _stabilityManager;
  late XtreamCatalogType _currentType;
  bool _isSidebarVisible = true;
  bool _isConnecting = false;

  // Estado do canal e EPG em FOCO (navegação D-pad independente da reprodução)
  XtreamLiveStream? _focusedLiveStream;
  EpgChannelSchedule? _focusedSchedule;
  bool _isEpgLoading = false;
  Timer? _epgDebounceTimer;
  int _epgRequestToken = 0;
  bool _isBackDebounced = false;
  bool _isExitingFullscreen = false;
  Timer? _backDebounceTimer;
  final GlobalKey<LivePlayerViewState> _livePlayerKey = GlobalKey<LivePlayerViewState>();
  final ScrollController _channelScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentType = widget.type;
    _stabilityManager = PlayerStabilityManager(
      onReconnectRequest: (count) async {
        if (mounted && _activeLiveStream != null) {
          _retryPlayback();
        }
      },
      onError: (msg) {
        if (mounted) {
          setState(() {
            _isPlayerLoading = false;
            _playerError = msg;
          });
        }
      },
    );
    FavoritesService.instance.addListener(_onFavoritesChanged);
    HiddenCategoriesService.instance.addListener(_onHiddenCategoriesChanged);
    DeviceUtils.isPipMode.addListener(_onPipModeChanged);
    _initialize();
  }

  void _onPipModeChanged() {
    if (!mounted) return;
    final inPip = DeviceUtils.isPipMode.value;
    if (!inPip) {
      if (_isFullscreen) {
        DeviceUtils.setVideoOrientation();
      } else {
        DeviceUtils.restoreOrientation();
      }
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quando o app estiver em modo Picture-in-Picture (PiP), o Android coloca a Activity em
    // estado Paused/Inactive, mas o vídeo DEVE continuar reproduzindo na janela flutuante.
    if (DeviceUtils.isPipMode.value) {
      return;
    }

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _stabilityManager.pauseMonitoring();
      _playerController?.pause();
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: false);
    } else if (state == AppLifecycleState.resumed) {
      if (mounted &&
          _activeLiveStream != null &&
          _playerController != null &&
          _playerController!.value.isInitialized) {
        DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
        _stabilityManager.startStallMonitoring(_playerController!);
        // Transmissões ao vivo não devem executar seekTo para evitar salto para trás (~5s) ou perda de sincronia
        _playerController!.play().catchError((_) {});
      }
    }
  }



  @override
  void dispose() {
    DeviceUtils.updateScreenKeepAlive(shouldKeepOn: false, immediate: true);
    DeviceUtils.setPipState(enabled: false);
    DeviceUtils.isPipMode.removeListener(_onPipModeChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stabilityManager.dispose();
    FavoritesService.instance.removeListener(_onFavoritesChanged);
    HiddenCategoriesService.instance.removeListener(_onHiddenCategoriesChanged);
    _searchController.dispose();
    _channelScrollController.dispose();
    _playerController?.removeListener(_onPlayerStateChanged);
    _playerController?.pause();
    _playerController?.dispose();
    _epgDebounceTimer?.cancel();
    _backDebounceTimer?.cancel();
    DeviceUtils.restoreOrientation();
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (!mounted) return;
    if (_selectedCategoryId == 'favorites') {
      _loadItemsForCategory('favorites');
    } else {
      setState(() {});
    }
  }

  void _onHiddenCategoriesChanged() {
    if (!mounted) return;
    if (_currentType == XtreamCatalogType.live) {
      final hidden = HiddenCategoriesService.instance.getHiddenCategories(_accountKey);
      if (_selectedCategoryId != 'all' &&
          _selectedCategoryId != 'favorites' &&
          (hidden.contains(_selectedCategoryId) ||
              hidden.contains(_getCategoryName(_selectedCategoryId).trim()))) {
        _selectedCategoryId = 'all';
        _loadItemsForCategory('all');
      }
    }
    setState(() {});
  }

  String get _accountKey {
    if (_service == null) return '';
    return PlaybackProgressService.buildAccountKey(
      _service!.serverUrl,
      _service!.username,
    );
  }

  FavoriteType get _favoriteType {
    switch (_currentType) {
      case XtreamCatalogType.live:
        return FavoriteType.live;
      case XtreamCatalogType.movies:
        return FavoriteType.movie;
      case XtreamCatalogType.series:
        return FavoriteType.series;
    }
  }

  String get _title {
    switch (_currentType) {
      case XtreamCatalogType.live:
        return 'TV ao vivo';
      case XtreamCatalogType.movies:
        return 'Filmes';
      case XtreamCatalogType.series:
        return 'Séries';
    }
  }

  IconData get _icon {
    switch (_currentType) {
      case XtreamCatalogType.live:
        return Icons.live_tv_rounded;
      case XtreamCatalogType.movies:
        return Icons.movie_outlined;
      case XtreamCatalogType.series:
        return Icons.video_library_outlined;
    }
  }

  Color get _accentColor {
    switch (_currentType) {
      case XtreamCatalogType.live:
        return const Color(0xFF00E5FF);
      case XtreamCatalogType.movies:
        return const Color(0xFF29B6F6);
      case XtreamCatalogType.series:
        return const Color(0xFF1E88E5);
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _isInitLoading = true;
      _initError = null;
    });

    try {
      if (widget.catalogService != null) {
        _service = widget.catalogService;
      } else {
        final storage = SecureStorageService();
        final server = await storage.getServerUrl();
        final user = await storage.getUsername();
        final pass = await storage.getPassword();

        if (server == null || user == null || pass == null) {
          throw const XtreamCatalogException(
            'Nenhuma conta Xtream Codes ativa encontrada. Faça login para acessar o catálogo.',
          );
        }

        _service = XtreamCatalogService(
          serverUrl: server,
          username: user,
          password: pass,
        );
      }

      await FavoritesService.instance.loadFavorites(_accountKey);
      await _loadCategories();

      if (widget.initialLiveStream != null && _currentType == XtreamCatalogType.live && mounted) {
        _playLiveChannel(widget.initialLiveStream!);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitLoading = false;
          _initError = e.toString();
        });
      }
    }
  }

  Future<void> _loadCategories() async {
    try {
      List<XtreamCategory> cats;
      switch (_currentType) {
        case XtreamCatalogType.live:
          cats = await _service!.fetchLiveCategories();
          break;
        case XtreamCatalogType.movies:
          cats = await _service!.fetchVodCategories();
          break;
        case XtreamCatalogType.series:
          cats = await _service!.fetchSeriesCategories();
          break;
      }

      // Adiciona categoria de Todas no início, seguida por Favoritos e as categorias do servidor
      final list = <XtreamCategory>[
        const XtreamCategory(id: 'all', name: 'Todas'),
        const XtreamCategory(id: 'favorites', name: 'Favoritos'),
        ...cats,
      ];

      const initialId = 'all';

      if (mounted) {
        setState(() {
          _categories = list;
          _selectedCategoryId = initialId;
          _isInitLoading = false;
        });
        _loadItemsForCategory(initialId);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitLoading = false;
          _initError = e.toString();
        });
      }
    }
  }

  Future<void> _loadItemsForCategory(String categoryId, {bool forceRefresh = false}) async {
    final sw = Stopwatch()..start();
    setState(() {
      _isItemsLoading = true;
      _itemsError = null;
    });

    if (categoryId == 'favorites') {
      try {
        final favs = await FavoritesService.instance.getFavorites(
          scopeKey: _accountKey,
          type: _favoriteType,
        );
        List<dynamic> items;
        switch (_currentType) {
          case XtreamCatalogType.live:
            items = favs.map((f) => f.toLiveStream()).toList();
            break;
          case XtreamCatalogType.movies:
            items = favs.map((f) => f.toVodStream()).toList();
            break;
          case XtreamCatalogType.series:
            items = favs.map((f) => f.toSeriesItem()).toList();
            break;
        }
        if (mounted) {
          setState(() {
            _currentItems = items;
            _isItemsLoading = false;
          });
        }
        return;
      } catch (e) {
        if (mounted) {
          setState(() {
            _isItemsLoading = false;
            _itemsError = 'Erro ao carregar favoritos: $e';
          });
        }
        return;
      }
    }

    final String typeKey = _currentType == XtreamCatalogType.live
        ? 'live'
        : (_currentType == XtreamCatalogType.movies ? 'movies' : 'series');
    final hasCache = _service?.hasLoadedCacheFor(typeKey) ?? false;

    if (categoryId == 'all' && !hasCache && forceRefresh && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Carregando catálogo completo de $_title... Isso pode levar alguns segundos.',
          ),
          backgroundColor: const Color(0xFF1E88E5),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    try {
      List<dynamic> items;
      switch (_currentType) {
        case XtreamCatalogType.live:
          items = await _service!.fetchLiveStreams(
            categoryId: categoryId,
            forceRefresh: forceRefresh,
          );
          break;
        case XtreamCatalogType.movies:
          items = await _service!.fetchVodStreams(
            categoryId: categoryId,
            forceRefresh: forceRefresh,
          );
          break;
        case XtreamCatalogType.series:
          items = await _service!.fetchSeries(
            categoryId: categoryId,
            forceRefresh: forceRefresh,
          );
          break;
      }

      if (mounted) {
        sw.stop();
        debugPrint(
          '[PERF] [UI RENDER] Categoria "$categoryId" exibida com ${items.length} itens em ${sw.elapsedMilliseconds}ms',
        );
        setState(() {
          _currentItems = items;
          _isItemsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isItemsLoading = false;
          _itemsError = e.toString();
        });
      }
    }
  }

  List<XtreamCategory> get _visibleCategories {
    List<XtreamCategory> list = _categories;
    if (_currentType == XtreamCatalogType.live) {
      final hidden = HiddenCategoriesService.instance.getHiddenCategories(_accountKey);
      if (hidden.isNotEmpty) {
        list = _categories.where((cat) {
          if (cat.id == 'all' || cat.id == 'favorites') return true;
          return !hidden.contains(cat.id) && !hidden.contains(cat.name.trim());
        }).toList();
      }
    }

    return list.map((cat) {
      int? count;
      if (cat.id == 'all') {
        count = _currentType == XtreamCatalogType.live
            ? _service?.totalLiveCount
            : (_currentType == XtreamCatalogType.movies
                ? _service?.totalVodCount
                : _service?.totalSeriesCount);
      } else if (cat.id == 'favorites') {
        count = FavoritesService.instance.getFavoriteIdsSync(scopeKey: _accountKey, type: _favoriteType).length;
      } else {
        count = _currentType == XtreamCatalogType.live
            ? _service?.getCategoryLiveCount(cat.id)
            : (_currentType == XtreamCatalogType.movies
                ? _service?.getCategoryVodCount(cat.id)
                : _service?.getCategorySeriesCount(cat.id));
      }
      return cat.copyWith(itemCount: count);
    }).toList();
  }

  List<dynamic> get _filteredItems {
    final hidden = _currentType == XtreamCatalogType.live
        ? HiddenCategoriesService.instance.getHiddenCategories(_accountKey)
        : const <String>{};

    final items = _currentItems.where((item) {
      if (_currentType == XtreamCatalogType.live && item is XtreamLiveStream) {
        // Preserva favoritos existentes mesmo que sua categoria original esteja oculta
        if (_selectedCategoryId != 'favorites' && hidden.isNotEmpty) {
          if (hidden.contains(item.categoryId) ||
              hidden.contains(_getCategoryName(item.categoryId).trim())) {
            return false;
          }
        }
      }
      return true;
    }).toList();

    if (_searchQuery.trim().isEmpty) return items;
    final q = _searchQuery.toLowerCase();
    return items.where((item) {
      if (item is XtreamLiveStream) return item.name.toLowerCase().contains(q);
      if (item is XtreamVodStream) return item.name.toLowerCase().contains(q);
      if (item is XtreamSeriesItem) return item.name.toLowerCase().contains(q);
      return false;
    }).toList();
  }

  Future<void> _toggleLiveFavorite(XtreamLiveStream stream) async {
    final item = FavoriteItem.fromLiveStream(
      accountKey: _accountKey,
      stream: stream,
    );
    final wasFav = FavoritesService.instance.isFavorite(
      scopeKey: _accountKey,
      type: FavoriteType.live,
      id: item.id,
    );
    await FavoritesService.instance.toggleFavorite(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF14243B),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              !wasFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: !wasFav ? const Color(0xFFEF5350) : const Color(0xFF8A99AD),
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              !wasFav ? 'Adicionado aos favoritos' : 'Removido dos favoritos',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  String _getCategoryName(String categoryId) {
    for (final cat in _categories) {
      if (cat.id == categoryId) return cat.name;
    }
    return '';
  }

  void _onPlayerStateChanged() {
    final c = _playerController;
    if (c == null || !mounted) return;
    final val = c.value;

    if (val.isPlaying) {
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
      _stabilityManager.metrics?.markFirstFrame();
    }

    if (val.hasError && _playerError == null) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(
        val.errorDescription ?? 'Falha na transmissão do canal.',
      );
      _stabilityManager.clearOpenWatchdog();
      _stabilityManager.metrics?.markError(safeErr);
      setState(() {
        _playerError = safeErr;
        _isPlayerLoading = false;
        _isPlayerBuffering = false;
      });
      _stabilityManager.scheduleRetry(safeErr);
    } else if (val.isBuffering != _isPlayerBuffering) {
      if (val.isBuffering) {
        _stabilityManager.metrics?.markBufferingStart();
      } else {
        _stabilityManager.metrics?.markBufferingEnd();
      }
      setState(() {
        _isPlayerBuffering = val.isBuffering;
      });
    }
  }

  Future<void> _playLiveChannel(XtreamLiveStream stream, {bool keepFullscreen = false}) async {
    // Requisito: Clicar novamente no canal que já está selecionado abre tela cheia sem reiniciar!
    if (_activeLiveStream?.streamId == stream.streamId &&
        _playerController != null &&
        _playerController!.value.isInitialized) {
      if (!_isFullscreen) {
        _toggleFullscreen();
      }
      return;
    }

    _stabilityManager.setUserPaused(false);
    _stabilityManager.metrics = PlaybackMetrics(
      mediaType: PlaybackMediaType.live,
      title: stream.name,
    );
    _stabilityManager.metrics?.markRequestStart();
    DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);

    _stabilityManager.resetRetries();

    setState(() {
      _activeLiveStream = stream;
      if (!keepFullscreen && !_isFullscreen) {
        _isFullscreen = false;
      }
      _isPlayerLoading = true;
      _isPlayerBuffering = false;
      _playerError = null;
      _reconnectAttempts = 0;
      _candidateUrls = _service?.buildLiveStreamUrls(stream) ?? [];
      _currentCandidateIndex = 0;
      _currentProgram = null;
      _nextProgram = null;
    });

    if (_candidateUrls.isEmpty) {
      setState(() {
        _isPlayerLoading = false;
        _playerError = 'Não foi possível gerar a URL de transmissão para este canal.';
      });
      return;
    }

    await _initControllerWithUrl(_candidateUrls[_currentCandidateIndex]);
    if (mounted && _activeLiveStream?.streamId == stream.streamId) {
      _fetchEpgForChannel(stream.streamId);
    }
  }

  void _playPreviousChannel() {
    if (_activeLiveStream == null) return;
    final items = _filteredItems.whereType<XtreamLiveStream>().toList();
    if (items.isEmpty) return;
    final currentIndex = items.indexWhere((s) => s.streamId == _activeLiveStream!.streamId);
    if (currentIndex > 0) {
      _playLiveChannel(items[currentIndex - 1], keepFullscreen: _isFullscreen);
    } else if (items.isNotEmpty) {
      _playLiveChannel(items.last, keepFullscreen: _isFullscreen);
    }
  }

  void _playNextChannel() {
    if (_activeLiveStream == null) return;
    final items = _filteredItems.whereType<XtreamLiveStream>().toList();
    if (items.isEmpty) return;
    final currentIndex = items.indexWhere((s) => s.streamId == _activeLiveStream!.streamId);
    if (currentIndex >= 0 && currentIndex < items.length - 1) {
      _playLiveChannel(items[currentIndex + 1], keepFullscreen: _isFullscreen);
    } else if (items.isNotEmpty) {
      _playLiveChannel(items.first, keepFullscreen: _isFullscreen);
    }
  }

  Future<void> _fetchEpgForChannel(int streamId) async {
    if (_service == null) return;
    try {
      final schedule = await EpgService.instance.fetchXtreamChannelEpg(
        streamId: streamId,
        catalogService: _service!,
      );
      if (!mounted || _activeLiveStream?.streamId != streamId) return;
      setState(() {
        _activeSchedule = schedule;
        _currentProgram = schedule?.currentProgram?.title;
        _nextProgram = schedule?.nextProgram?.title;
      });
    } catch (_) {}
  }

  Future<void> _initControllerWithUrl(String url) async {
    if (_isConnecting) return;
    _isConnecting = true;

    final oldController = _playerController;
    _playerController = null;
    oldController?.removeListener(_onPlayerStateChanged);
    try {
      await oldController?.pause();
      await oldController?.dispose();
    } catch (_) {}

    if (!mounted) {
      _isConnecting = false;
      return;
    }

    final sanitizedDisplay = UrlSanitizer.sanitize(url);
    debugPrint('[PLAYER] Conectando ao canal: $sanitizedDisplay');

    final uri = Uri.parse(url);
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
      },
    );

    _playerController = controller;
    controller.addListener(_onPlayerStateChanged);

    _stabilityManager.startOpenWatchdog(() {
      if (mounted && _playerController == controller && _isPlayerLoading) {
        setState(() {
          _isPlayerLoading = false;
          _playerError = 'Tempo limite de conexão excedido. Tentando reconectar...';
        });
        _stabilityManager.scheduleRetry('Timeout na conexão inicial');
      }
    });

    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
      if (mounted && _playerController == controller) {
        _stabilityManager.clearOpenWatchdog();
        _stabilityManager.metrics?.markConnectionEstablished();
        _stabilityManager.metrics?.markPlayerInitialized();
        _stabilityManager.startStallMonitoring(controller);

        await controller.play();
        DeviceUtils.setPipState(enabled: true);
        DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
        setState(() {
          _isPlayerLoading = false;
          _playerError = null;
          _reconnectAttempts = 0;
        });
      }
    } catch (e) {
      if (mounted && _playerController == controller) {
        DeviceUtils.setPipState(enabled: false);
        _stabilityManager.clearOpenWatchdog();
        _isConnecting = false;
        // Tentativa de rota/extensão alternativa caso exista
        if (_currentCandidateIndex + 1 < _candidateUrls.length) {
          _currentCandidateIndex++;
          debugPrint('[PLAYER] Tentando formato alternativo de transmissão...');
          await _initControllerWithUrl(_candidateUrls[_currentCandidateIndex]);
          return;
        }

        final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
        setState(() {
          _isPlayerLoading = false;
          _playerError = 'Erro ao conectar à transmissão: $safeErr';
        });
        _stabilityManager.scheduleRetry(safeErr);
      }
    } finally {
      _isConnecting = false;
    }
  }

  void _togglePlayPause() {
    final c = _playerController;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      _stabilityManager.setUserPaused(true);
      c.pause();
      DeviceUtils.setPipState(enabled: false);
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: false);
    } else {
      _stabilityManager.setUserPaused(false);
      c.play();
      DeviceUtils.setPipState(enabled: true);
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
    }
    setState(() {});
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });
    if (_isFullscreen) {
      DeviceUtils.setVideoOrientation();
    } else {
      DeviceUtils.restoreOrientation();
    }
  }

  void _handleBackFromFullscreen() {
    if (_isBackDebounced || _isExitingFullscreen) return;
    _isBackDebounced = true;
    _isExitingFullscreen = true;
    _backDebounceTimer?.cancel();
    _backDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _isBackDebounced = false;
      _isExitingFullscreen = false;
    });
    _toggleFullscreen();
    _restoreActiveChannelVisibility();
  }

  void _restoreActiveChannelVisibility() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeLiveStream == null) return;
      final items = _filteredItems;
      final idx = items.indexWhere((it) => it is XtreamLiveStream && it.streamId == _activeLiveStream!.streamId);
      if (idx >= 0 && _channelScrollController.hasClients) {
        final targetOffset = (idx * 78.0 - 80.0).clamp(
          0.0,
          _channelScrollController.position.maxScrollExtent,
        );
        _channelScrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _onChannelFocusChanged(XtreamLiveStream stream) {
    if (_focusedLiveStream?.streamId == stream.streamId) return;

    _epgDebounceTimer?.cancel();
    final token = ++_epgRequestToken;

    setState(() {
      _focusedLiveStream = stream;
    });

    // 1. Verifica cache síncrono no EpgService
    final cached = EpgService.instance.getXtreamCachedSchedule(stream.streamId);
    if (cached != null) {
      if (mounted && _epgRequestToken == token) {
        setState(() {
          _focusedSchedule = cached;
          _isEpgLoading = false;
        });
      }
      return;
    }

    // 2. Limpa dados antigos do canal anterior
    setState(() {
      _focusedSchedule = null;
      _isEpgLoading = true;
    });

    // 3. Debounce de 250ms para navegação rápida
    _epgDebounceTimer = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted || _service == null || _epgRequestToken != token) return;
      try {
        final schedule = await EpgService.instance.fetchXtreamChannelEpg(
          streamId: stream.streamId,
          catalogService: _service!,
        );
        if (mounted && _epgRequestToken == token && _focusedLiveStream?.streamId == stream.streamId) {
          setState(() {
            _focusedSchedule = schedule;
            _isEpgLoading = false;
          });
        }
      } catch (_) {
        if (mounted && _epgRequestToken == token) {
          setState(() {
            _isEpgLoading = false;
          });
        }
      }
    });
  }

  Future<void> _closeMiniPlayer() async {
    _stabilityManager.setUserPaused(false);
    DeviceUtils.setPipState(enabled: false);
    DeviceUtils.updateScreenKeepAlive(shouldKeepOn: false, immediate: true);
    _stabilityManager.clearOpenWatchdog();
    _stabilityManager.resetRetries();
    final oldController = _playerController;
    _playerController = null;
    oldController?.removeListener(_onPlayerStateChanged);
    await oldController?.pause();
    await oldController?.dispose();

    if (mounted) {
      setState(() {
        _activeLiveStream = null;
        _activeSchedule = null;
        _isFullscreen = false;
        _playerError = null;
        _isPlayerLoading = false;
        _isPlayerBuffering = false;
      });
      DeviceUtils.restoreOrientation();
    }
  }

  Future<void> _retryPlayback() async {
    if (_activeLiveStream == null || !mounted) return;
    if (_isConnecting) {
      debugPrint('[PLAYER] Reconexão já em andamento, ignorando chamada redundante.');
      return;
    }
    _stabilityManager.clearOpenWatchdog();

    // Tenta soft recovery antes de descartar o controlador se ele ainda estiver vivo
    final c = _playerController;
    if (c != null && c.value.isInitialized && !c.value.hasError) {
      debugPrint('[PLAYER] Tentando recuperação suave (soft recovery)...');
      final ok = await _stabilityManager.attemptSoftRecovery(c);
      if (ok && mounted) {
        setState(() {
          _playerError = null;
          _isPlayerLoading = false;
          _isPlayerBuffering = false;
        });
        return;
      }
    }

    // Rotaciona candidatos caso haja mais de um (ex: .ts -> .m3u8) para contornar limitações do proxy
    if (_candidateUrls.length > 1) {
      _currentCandidateIndex = (_currentCandidateIndex + 1) % _candidateUrls.length;
      debugPrint('[PLAYER] Tentando formato alternativo: candidato $_currentCandidateIndex de ${_candidateUrls.length}');
    }

    setState(() {
      _reconnectAttempts++;
      _isPlayerLoading = true;
      _playerError = null;
    });
    debugPrint('[PLAYER] Reconectando (tentativa $_reconnectAttempts)...');
    if (_candidateUrls.isNotEmpty) {
      await _initControllerWithUrl(_candidateUrls[_currentCandidateIndex]);
    }
  }

  void _onItemTap(dynamic item) {
    if (_currentType == XtreamCatalogType.live && item is XtreamLiveStream) {
      _playLiveChannel(item);
      return;
    }

    if (_currentType == XtreamCatalogType.movies && item is XtreamVodStream && _service != null) {
      final accountKey = PlaybackProgressService.buildAccountKey(
        _service!.serverUrl,
        _service!.username,
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VodDetailScreen(
            movie: item,
            catalogService: _service!,
            accountKey: accountKey,
          ),
        ),
      ).then((_) {
        DeviceUtils.restoreOrientation();
        if (mounted) setState(() {});
      });
      return;
    }

    if (_currentType == XtreamCatalogType.series && item is XtreamSeriesItem && _service != null) {
      final accountKey = PlaybackProgressService.buildAccountKey(
        _service!.serverUrl,
        _service!.username,
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SeriesDetailScreen(
            series: item,
            catalogService: _service!,
            accountKey: accountKey,
          ),
        ),
      ).then((_) {
        DeviceUtils.restoreOrientation();
        if (mounted) setState(() {});
      });
      return;
    }

    final String name = (item is XtreamSeriesItem)
        ? item.name
        : item.toString();

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'A reprodução de "$name" será disponibilizada na próxima etapa.',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF162032),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: _accentColor, width: 1),
        ),
      ),
    );
  }

  Future<void> _openGuideForActiveStream() async {
    if (_service == null || _activeLiveStream == null) return;
    final schedule = await EpgService.instance.fetchXtreamChannelEpg(
      streamId: _activeLiveStream!.streamId,
      catalogService: _service!,
    );
    if (!mounted) return;
    EpgGuideDialog.show(
      context,
      channelName: _activeLiveStream!.name,
      channelLogo: _activeLiveStream!.streamIcon,
      schedule: schedule,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 0. Modo Picture-in-Picture: exibe o player ocupando 100% da janela flutuante
    if (DeviceUtils.isPipMode.value && _currentType == XtreamCatalogType.live && _activeLiveStream != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildLivePlayerWidget(isFullscreen: true),
      );
    }

    // 1. Modo Normal ou Tela Cheia Unificado com suporte a controle remoto e dois passos no Voltar
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _isBackDebounced || _isExitingFullscreen) return;

        // Se estiver em tela cheia de TV ao vivo:
        if (_isFullscreen && _currentType == XtreamCatalogType.live && _activeLiveStream != null) {
          // Primeiro toque em Voltar com controles visíveis fecha apenas os controles
          if (_livePlayerKey.currentState?.isControlsVisible ?? false) {
            _livePlayerKey.currentState?.hideControls();
            return;
          }
          // Segundo toque (ou controles já ocultos): sai da tela cheia, restaura foco e posição do canal
          _handleBackFromFullscreen();
          return;
        }

        if (_searchQuery.isNotEmpty || _searchController.text.isNotEmpty) {
          setState(() {
            _searchQuery = '';
            _searchController.clear();
          });
          return;
        }

        if (_currentType == XtreamCatalogType.live && _activeLiveStream != null) {
          _closeMiniPlayer();
          return;
        }

        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070F18),
        appBar: _isFullscreen
            ? null
            : AppBar(
                backgroundColor: const Color(0xFF0A141D),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_icon, color: _accentColor, size: 22),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFF5F8FC),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'Atualizar',
                    icon: Icon(Icons.refresh_rounded, color: _accentColor),
                    onPressed: () {
                      _service?.clearCache();
                      _loadCategories();
                    },
                  ),
                ],
              ),
        body: _isFullscreen && _currentType == XtreamCatalogType.live && _activeLiveStream != null
            ? Container(
                color: Colors.black,
                child: _buildLivePlayerWidget(isFullscreen: true),
              )
            : SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 600;
              final isLandscape = constraints.maxWidth > constraints.maxHeight;
              final showMini = _currentType == XtreamCatalogType.live && _activeLiveStream != null;

              Widget catalogContent;
              if (_isInitLoading) {
                catalogContent = Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
                  ),
                );
              } else if (_initError != null) {
                catalogContent = _buildInitError();
              } else if (isLandscape && _currentType == XtreamCatalogType.live) {
                final channelListWidth = (constraints.maxWidth * 0.35).clamp(320.0, 420.0);
                catalogContent = Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Coluna 2: Cabeçalho da Categoria + Lista de Canais (sem barra horizontal de navegação superior)
                    SizedBox(
                      width: channelListWidth,
                      child: Column(
                        children: [
                          _buildLiveCategoryHeader(),
                          Expanded(child: _buildLiveChannelList()),
                        ],
                      ),
                    ),
                    // Coluna 3: Painel Direito com Mini Player 16:9 + Linha do tempo EPG
                    Expanded(
                      child: _buildLiveEpgAndPlayerPanel(),
                    ),
                  ],
                );
              } else {
                catalogContent = Column(
                  children: [
                    if (showMini)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: _buildMiniPlayerWidget(),
                          ),
                        ),
                      ),
                    Expanded(child: _buildMainContent()),
                  ],
                );
              }

              return Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_isSidebarVisible)
                        CatalogSidebar(
                          categories: _visibleCategories,
                          selectedCategoryId: _selectedCategoryId,
                          searchQuery: _searchQuery,
                          searchController: _searchController,
                          onSearchChanged: (q) => setState(() => _searchQuery = q),
                          onCategorySelected: (catId) {
                            if (_selectedCategoryId != catId) {
                              setState(() {
                                _selectedCategoryId = catId;
                              });
                              _loadItemsForCategory(catId);
                            }
                          },
                          onHomeTap: () => Navigator.of(context).pop(),
                          onCloseTap: isCompact
                              ? () => setState(() => _isSidebarVisible = false)
                              : null,
                          accentColor: _accentColor,
                          isCompact: isCompact,
                          isLoading: _isInitLoading,
                        ),
                      Expanded(
                        child: catalogContent,
                      ),
                    ],
                  ),
                  if (!_isSidebarVisible && isCompact)
                    Positioned(
                      left: 0,
                      top: 12,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const Key('btn_expand_sidebar'),
                          onTap: () => setState(() => _isSidebarVisible = true),
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF141D2D),
                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                              border: Border.all(color: const Color(0xFF1E283D)),
                            ),
                            child: const Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLivePlayerWidget({required bool isFullscreen}) {
    return LivePlayerView(
      key: _livePlayerKey,
      controller: _playerController,
      channelName: _activeLiveStream!.name,
      channelLogo: _activeLiveStream!.streamIcon,
      groupTitle: _getCategoryName(_activeLiveStream!.categoryId),
      isFullscreen: isFullscreen,
      isLoading: _isPlayerLoading,
      isBuffering: _isPlayerBuffering,
      errorMessage: _playerError,
      fitMode: _fitMode,
      onFitModeChanged: (mode) => setState(() => _fitMode = mode),
      onTogglePlayPause: _togglePlayPause,
      onToggleFullscreen: _toggleFullscreen,
      onClose: isFullscreen ? null : _closeMiniPlayer,
      onRetry: _retryPlayback,
      onPreviousChannel: _playPreviousChannel,
      onNextChannel: _playNextChannel,
      currentProgram: _currentProgram,
      nextProgram: _nextProgram,
      onOpenGuide: _openGuideForActiveStream,
      isFavorite: _activeLiveStream != null &&
          FavoritesService.instance.isFavorite(
            scopeKey: _accountKey,
            type: FavoriteType.live,
            id: _activeLiveStream!.streamId.toString(),
          ),
      onToggleFavorite: _activeLiveStream == null
          ? null
          : () async {
              await FavoritesService.instance.toggleFavorite(
                FavoriteItem.fromLiveStream(
                  accountKey: _accountKey,
                  stream: _activeLiveStream!,
                ),
              );
            },
    );
  }

  Widget _buildMiniPlayerWidget() => _buildLivePlayerWidget(isFullscreen: false);

  Widget _buildLiveCategoryHeader() {
    final catName = _selectedCategoryId == 'all'
        ? 'Todos os canais'
        : (_selectedCategoryId == 'favorites'
            ? 'Favoritos'
            : _getCategoryName(_selectedCategoryId));
    final count = _filteredItems.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFF0A141D),
        border: Border(
          bottom: BorderSide(color: Color(0xFF162A38), width: 1.0),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 3.5,
            height: 16,
            decoration: BoxDecoration(
              color: const Color(0xFF00E5FF),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              catName.toUpperCase(),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
                color: Color(0xFFF5F8FC),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF132534),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF1A384C)),
            ),
            child: Text(
              '$count ${count == 1 ? 'canal' : 'canais'}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8FA7BD),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveChannelList() {
    if (_isItemsLoading) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
        ),
      );
    }
    if (_itemsError != null) {
      return _buildItemsError();
    }
    if (_filteredItems.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      controller: _channelScrollController,
      key: const PageStorageKey('xtream_live_channels_list'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index] as XtreamLiveStream;
        final isFav = FavoritesService.instance.isFavorite(
          scopeKey: _accountKey,
          type: FavoriteType.live,
          id: item.streamId.toString(),
        );
        final isCurrent = _activeLiveStream?.streamId == item.streamId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 6.0),
          child: _LiveChannelCard(
            channelNumber: index + 1,
            stream: item,
            accentColor: _accentColor,
            isPlaying: isCurrent,
            autofocus: isCurrent,
            isFavorite: isFav,
            onFocus: () => _onChannelFocusChanged(item),
            onToggleFavorite: () => _toggleLiveFavorite(item),
            onTap: () => _onItemTap(item),
          ),
        );
      },
    );
  }

  Widget _buildLiveEpgAndPlayerPanel() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF070F18),
        border: Border(
          left: BorderSide(color: Color(0xFF162A38), width: 1.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Mini-player 16:9
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _activeLiveStream != null
                    ? _buildMiniPlayerWidget()
                    : _buildLivePlaceholderPlayer(),
              ),
            ),
          ),
          // 2. Grade EPG diretamente abaixo do mini player (sem card intermediário)
          Expanded(
            child: _buildEpgScheduleList(),
          ),
        ],
      ),
    );
  }

  Widget _buildLivePlaceholderPlayer() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A141D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF162A38)),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tv_rounded, size: 36, color: const Color(0xFF00E5FF).withValues(alpha: 0.6)),
              const SizedBox(height: 6),
              const Text(
                'Selecione um canal na lista',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5F8FC),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              const Text(
                'Use o controle remoto e pressione OK para assistir',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF8FA7BD),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }



  Widget _buildEpgScheduleList() {
    final targetStream = _focusedLiveStream ?? _activeLiveStream;
    final schedule = _focusedLiveStream != null
        ? _focusedSchedule
        : _activeSchedule;
    final programs = schedule?.programs ?? [];

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A141D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF162A38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_note_rounded, size: 16, color: Color(0xFF00E5FF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  targetStream != null
                      ? 'PROGRAMAÇÃO: ${targetStream.name}'
                      : 'PROGRAMAÇÃO',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                    color: Color(0xFF8FA7BD),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isEpgLoading) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (programs.isNotEmpty)
                Text(
                  '${programs.length} programas',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6A829A),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(color: Color(0xFF162A38), height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: _isEpgLoading && programs.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                      ),
                    ),
                  )
                : programs.isEmpty
                    ? Center(
                        child: Text(
                          targetStream == null
                              ? 'Selecione ou foque em um canal para ver a programação.'
                              : 'Nenhuma programação disponível para ${targetStream.name}.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6A829A),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: programs.length,
                        itemBuilder: (context, index) {
                          final p = programs[index];
                          final isNow = p.isAiringAt();
                          final progress = p.getProgress();

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: isNow ? const Color(0xFF00E5FF).withValues(alpha: 0.08) : const Color(0xFF0C1622),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isNow ? const Color(0xFF00E5FF).withValues(alpha: 0.5) : const Color(0xFF142436),
                                width: isNow ? 1.5 : 1.0,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      p.formattedTimeRange.isNotEmpty
                                          ? p.formattedTimeRange
                                          : '--:--',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isNow ? const Color(0xFF00E5FF) : const Color(0xFF8FA7BD),
                                      ),
                                    ),
                                    if (isNow) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00E5FF),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'AGORA',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF070F18),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  p.title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isNow ? FontWeight.bold : FontWeight.w500,
                                    color: isNow ? const Color(0xFFF5F8FC) : const Color(0xFFD6E2EE),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (p.description != null && p.description!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    p.description!,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF6A829A),
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                if (isNow && progress != null) ...[
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 3,
                                      backgroundColor: const Color(0xFF132534),
                                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    if (_isItemsLoading) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
        ),
      );
    }
    if (_itemsError != null) {
      return _buildItemsError();
    }
    if (_filteredItems.isEmpty) {
      return _buildEmptyState();
    }
    return _buildCatalogGrid();
  }



  Widget _buildCatalogGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;

        // Se for TV ao vivo: formato de cards horizontais (como canais)
        if (_currentType == XtreamCatalogType.live) {
          final crossAxisCount = isLandscape ? (constraints.maxWidth ~/ 280).clamp(1, 5) : 1;

          if (crossAxisCount > 1) {
            return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisExtent: 74,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _filteredItems.length,
              itemBuilder: (context, index) {
                final item = _filteredItems[index] as XtreamLiveStream;
                final isFav = FavoritesService.instance.isFavorite(
                  scopeKey: _accountKey,
                  type: FavoriteType.live,
                  id: item.streamId.toString(),
                );
                return _LiveChannelCard(
                  stream: item,
                  accentColor: _accentColor,
                  isPlaying: _activeLiveStream?.streamId == item.streamId,
                  isFavorite: isFav,
                  onFocus: () => _onChannelFocusChanged(item),
                  onToggleFavorite: () => _toggleLiveFavorite(item),
                  onTap: () => _onItemTap(item),
                );
              },
            );
          } else {
            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _filteredItems.length,
              itemBuilder: (context, index) {
                final item = _filteredItems[index] as XtreamLiveStream;
                final isFav = FavoritesService.instance.isFavorite(
                  scopeKey: _accountKey,
                  type: FavoriteType.live,
                  id: item.streamId.toString(),
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: _LiveChannelCard(
                    stream: item,
                    accentColor: _accentColor,
                    isPlaying: _activeLiveStream?.streamId == item.streamId,
                    isFavorite: isFav,
                    onFocus: () => _onChannelFocusChanged(item),
                    onToggleFavorite: () => _toggleLiveFavorite(item),
                    onTap: () => _onItemTap(item),
                  ),
                );
              },
            );
          }
        }

        // Se for Filmes ou Séries: formato de pôster vertical (aspect ratio ~2:3)
        final crossAxisCount = isLandscape ? 4 : 2;

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.67,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: _filteredItems.length,
          itemBuilder: (context, index) {
            final dynamic item = _filteredItems[index];
            final String name = item.name;
            final String? image = _currentType == XtreamCatalogType.movies
                ? (item as XtreamVodStream).streamIcon
                : (item as XtreamSeriesItem).cover;
            final String? rating = _currentType == XtreamCatalogType.movies
                ? (item as XtreamVodStream).rating
                : (item as XtreamSeriesItem).rating;
            final String itemId = _currentType == XtreamCatalogType.movies
                ? (item as XtreamVodStream).streamId.toString()
                : (item as XtreamSeriesItem).seriesId.toString();
            final isFav = FavoritesService.instance.isFavorite(
              scopeKey: _accountKey,
              type: _favoriteType,
              id: itemId,
            );

            return _MediaPosterCard(
              title: name,
              imageUrl: image,
              rating: rating,
              accentColor: _accentColor,
              fallbackIcon: _icon,
              isFavorite: isFav,
              onToggleFavorite: () async {
                final favItem = _currentType == XtreamCatalogType.movies
                    ? FavoriteItem.fromVodStream(
                        accountKey: _accountKey,
                        movie: item as XtreamVodStream,
                      )
                    : FavoriteItem.fromSeriesItem(
                        accountKey: _accountKey,
                        series: item as XtreamSeriesItem,
                      );
                await FavoritesService.instance.toggleFavorite(favItem);
              },
              onTap: () => _onItemTap(item),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final hasSearch = _searchQuery.trim().isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasSearch ? Icons.search_off_rounded : Icons.inbox_rounded,
              size: 52,
              color: const Color(0xFF5A6E85),
            ),
            const SizedBox(height: 14),
            Text(
              hasSearch
                  ? 'Nenhum item encontrado para "$_searchQuery"'
                  : 'Nenhum item encontrado em "$_title"',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFFF0F4F8)),
            ),
            const SizedBox(height: 6),
            Text(
              hasSearch
                  ? 'Verifique a ortografia ou selecione a categoria "Todas" na barra lateral para buscar em todo o catálogo.'
                  : 'A categoria selecionada não possui registros no servidor.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF8A99AD)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInitError() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 54, color: Color(0xFFEF5350)),
              const SizedBox(height: 18),
              const Text(
                'Falha ao carregar categorias',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFF0F4F8)),
              ),
              const SizedBox(height: 10),
              Text(
                _initError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFFEF9A9A), height: 1.4),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _initialize,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Tentar novamente'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemsError() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 44, color: Color(0xFFEF5350)),
            const SizedBox(height: 12),
            const Text(
              'Erro ao carregar itens da categoria',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFF0F4F8)),
            ),
            const SizedBox(height: 8),
            Text(
              _itemsError!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFFEF9A9A)),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () => _loadItemsForCategory(_selectedCategoryId, forceRefresh: true),
              style: OutlinedButton.styleFrom(foregroundColor: _accentColor),
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveChannelCard extends StatefulWidget {
  final int? channelNumber;
  final XtreamLiveStream stream;
  final Color accentColor;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback? onFocus;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onTap;
  final bool autofocus;

  const _LiveChannelCard({
    this.channelNumber,
    required this.stream,
    required this.accentColor,
    this.isPlaying = false,
    this.isFavorite = false,
    this.onFocus,
    this.onToggleFavorite,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_LiveChannelCard> createState() => _LiveChannelCardState();
}

class _LiveChannelCardState extends State<_LiveChannelCard> {
  bool _isFocused = false;
  bool _isHovered = false;

  Timer? _longPressTimer;
  bool _longPressTriggered = false;
  bool _isKeyDown = false;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  bool _isSelectKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.numpadEnter;
  }

  bool _isMenuKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.gameButtonX;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_isSelectKey(event.logicalKey)) {
      if (event is KeyDownEvent) {
        if (!_isKeyDown) {
          _isKeyDown = true;
          _longPressTriggered = false;
          _longPressTimer?.cancel();
          _longPressTimer = Timer(const Duration(milliseconds: 700), () {
            if (mounted && _isKeyDown) {
              _longPressTriggered = true;
              HapticFeedback.mediumImpact();
              widget.onToggleFavorite?.call();
            }
          });
        }
        return KeyEventResult.handled;
      } else if (event is KeyRepeatEvent) {
        return KeyEventResult.handled;
      } else if (event is KeyUpEvent) {
        _longPressTimer?.cancel();
        _isKeyDown = false;
        if (!_longPressTriggered) {
          widget.onTap();
        }
        _longPressTriggered = false;
        return KeyEventResult.handled;
      }
    } else if (_isMenuKey(event.logicalKey)) {
      if (event is KeyUpEvent) {
        widget.onToggleFavorite?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered || widget.isPlaying;

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        if (!focused) {
          _longPressTimer?.cancel();
          _isKeyDown = false;
          _longPressTriggered = false;
        } else {
          widget.onFocus?.call();
        }
        setState(() => _isFocused = focused);
      },
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        onEnter: (_) {
          widget.onFocus?.call();
          setState(() => _isHovered = true);
        },
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedScale(
          scale: DeviceUtils.isTv ? 1.0 : (isHighlighted ? 1.02 : 1.0),
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: widget.isPlaying ? const Color(0xFF0F2636) : const Color(0xFF0C1622),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isHighlighted ? widget.accentColor : (widget.isPlaying ? widget.accentColor.withValues(alpha: 0.6) : const Color(0xFF162536)),
                width: widget.isPlaying ? 2.0 : (isHighlighted ? 1.5 : 1.0),
              ),
              boxShadow: isHighlighted
                  ? [
                      BoxShadow(
                        color: widget.accentColor.withValues(alpha: widget.isPlaying ? 0.35 : 0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                canRequestFocus: false,
                onTap: widget.onTap,
                onLongPress: widget.onToggleFavorite,
                borderRadius: BorderRadius.circular(10),
                splashColor: widget.accentColor.withValues(alpha: 0.15),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      // Número do Canal (#01)
                      if (widget.channelNumber != null) ...[
                        Container(
                          width: 32,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '#${widget.channelNumber!.toString().padLeft(2, '0')}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: widget.isPlaying ? widget.accentColor : const Color(0xFF6A829A),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],

                      // Logo do Canal
                      _buildLogo(widget.stream.streamIcon),
                      const SizedBox(width: 12),

                      // Nome do canal e status
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.stream.name,
                              maxLines: widget.isPlaying ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFF0F4F8),
                              ),
                            ),
                            if (widget.isPlaying)
                              Padding(
                                padding: const EdgeInsets.only(top: 2.0),
                                child: Row(
                                  children: [
                                    Icon(Icons.graphic_eq_rounded, size: 12, color: widget.accentColor),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        'EM REPRODUÇÃO • Toque p/ tela cheia',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: widget.accentColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),

                      Icon(
                        widget.isPlaying
                            ? Icons.play_circle_filled_rounded
                            : Icons.play_circle_outline_rounded,
                        size: 22,
                        color: isHighlighted ? widget.accentColor : const Color(0xFF3E506B),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo(String? logoUrl) {
    const double size = 42;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1A2436),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.live_tv_rounded, color: widget.accentColor, size: 20),
    );

    if (logoUrl == null || logoUrl.trim().isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          logoUrl,
          fit: BoxFit.contain,
          cacheWidth: 120,
          cacheHeight: 120,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

class _MediaPosterCard extends StatefulWidget {
  final String title;
  final String? imageUrl;
  final String? rating;
  final Color accentColor;
  final IconData fallbackIcon;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onTap;

  const _MediaPosterCard({
    required this.title,
    required this.imageUrl,
    this.rating,
    required this.accentColor,
    required this.fallbackIcon,
    this.isFavorite = false,
    this.onToggleFavorite,
    required this.onTap,
  });

  @override
  State<_MediaPosterCard> createState() => _MediaPosterCardState();
}

class _MediaPosterCardState extends State<_MediaPosterCard> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedScale(
        scale: DeviceUtils.isTv ? 1.0 : (isHighlighted ? 1.03 : 1.0),
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1E2A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHighlighted ? widget.accentColor : const Color(0xFF162A38),
              width: isHighlighted ? 2.0 : 1.0,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: widget.accentColor.withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Imagem do Poster com Badge de Nota e Coração
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                            child: widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                                ? Image.network(
                                    widget.imageUrl!,
                                    fit: BoxFit.cover,
                                    cacheWidth: 300,
                                    cacheHeight: 450,
                                    errorBuilder: (_, _, _) => _buildFallback(),
                                  )
                                : _buildFallback(),
                          ),
                        ),
                        if (widget.onToggleFavorite != null)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                canRequestFocus: false,
                                onTap: widget.onToggleFavorite,
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xDD090D14),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: widget.isFavorite
                                          ? const Color(0xFFEF5350)
                                          : const Color(0xFF37474F),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Icon(
                                    widget.isFavorite
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_outline_rounded,
                                    size: 14,
                                    color: widget.isFavorite
                                        ? const Color(0xFFEF5350)
                                        : Colors.white70,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (widget.rating != null &&
                            widget.rating!.isNotEmpty &&
                            widget.rating != '0' &&
                            widget.rating != '0.0')
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xDD090D14),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFFFFA726), width: 0.8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFA726)),
                                  const SizedBox(width: 2),
                                  Text(
                                    widget.rating!,
                                    style: const TextStyle(
                                      color: Color(0xFFF0F4F8),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Título na parte inferior
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF0F4F8),
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFallback() {
    return Container(
      color: const Color(0xFF141D2D),
      child: Center(
        child: Icon(widget.fallbackIcon, size: 36, color: widget.accentColor.withValues(alpha: 0.4)),
      ),
    );
  }
}
