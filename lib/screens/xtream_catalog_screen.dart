import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../services/epg_service.dart';
import '../services/favorites_service.dart';
import '../services/hidden_categories_service.dart';
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
  late final PlayerStabilityManager _stabilityManager;
  late XtreamCatalogType _currentType;
  bool _isSidebarVisible = true;
  bool _isConnecting = false;
  bool _userPaused = false;

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
        // Pula para a borda ao vivo (live edge) ao retornar do segundo plano
        if (_playerController!.value.duration > Duration.zero) {
          _playerController!
              .seekTo(_playerController!.value.duration)
              .catchError((_) {});
        }
        _playerController!.play().catchError((_) {});
      }
    }
  }

  void _switchCatalogType(XtreamCatalogType newType) {
    if (_currentType == newType) return;
    if (_currentType == XtreamCatalogType.live) {
      _closeMiniPlayer();
    }
    setState(() {
      _currentType = newType;
      _selectedCategoryId = 'all';
      _searchQuery = '';
      _searchController.clear();
      _isInitLoading = true;
      _initError = null;
    });
    _loadCategories();
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
    _playerController?.removeListener(_onPlayerStateChanged);
    _playerController?.pause();
    _playerController?.dispose();
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
    if (_currentType != XtreamCatalogType.live) return _categories;
    final hidden = HiddenCategoriesService.instance.getHiddenCategories(_accountKey);
    if (hidden.isEmpty) return _categories;
    return _categories.where((cat) {
      if (cat.id == 'all' || cat.id == 'favorites') return true;
      return !hidden.contains(cat.id) && !hidden.contains(cat.name.trim());
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
    }

    if (val.hasError && _playerError == null) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(
        val.errorDescription ?? 'Falha na transmissão do canal.',
      );
      _stabilityManager.clearOpenWatchdog();
      setState(() {
        _playerError = safeErr;
        _isPlayerLoading = false;
        _isPlayerBuffering = false;
      });
      _stabilityManager.scheduleRetry(safeErr);
    } else if (val.isBuffering != _isPlayerBuffering) {
      setState(() {
        _isPlayerBuffering = val.isBuffering;
      });
    } else if (!val.isPlaying && !val.isBuffering && !_userPaused && !_isPlayerLoading && _playerError == null) {
      // Queda silenciosa ou término de socket após 15 minutos sem erro formal
      debugPrint('[PLAYER] Transmissão ao vivo interrompida inesperadamente pelo servidor (queda de socket).');
      _stabilityManager.scheduleRetry('Transmissão encerrada pelo servidor');
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

    _userPaused = false;
    _stabilityManager.setUserPaused(false);
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

    _fetchEpgForChannel(stream.streamId);

    if (_candidateUrls.isEmpty) {
      setState(() {
        _isPlayerLoading = false;
        _playerError = 'Não foi possível gerar a URL de transmissão para este canal.';
      });
      return;
    }

    await _initControllerWithUrl(_candidateUrls[_currentCandidateIndex]);
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
      if (schedule != null) {
        final now = schedule.currentProgram;
        final next = schedule.nextProgram;
        setState(() {
          _currentProgram = now?.title;
          _nextProgram = next?.title;
        });
      }
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
        _stabilityManager.startStallMonitoring(controller);

        // Se for HLS ao vivo com duração reportada pelo player, pula para live edge
        if (controller.value.duration > Duration.zero) {
          try {
            await controller.seekTo(controller.value.duration);
          } catch (_) {}
        }

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
      _userPaused = true;
      _stabilityManager.setUserPaused(true);
      c.pause();
      DeviceUtils.setPipState(enabled: false);
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: false);
    } else {
      _userPaused = false;
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

  Future<void> _closeMiniPlayer() async {
    _userPaused = false;
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
    if (c != null && c.value.isInitialized && !c.value.hasError && c.value.isPlaying) {
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
        body: LivePlayerView(
          controller: _playerController,
          channelName: _activeLiveStream!.name,
          channelLogo: _activeLiveStream!.streamIcon,
          groupTitle: _getCategoryName(_activeLiveStream!.categoryId),
          isFullscreen: true,
          isLoading: _isPlayerLoading,
          isBuffering: _isPlayerBuffering,
          errorMessage: _playerError,
          fitMode: _fitMode,
          onFitModeChanged: (mode) => setState(() => _fitMode = mode),
          onTogglePlayPause: _togglePlayPause,
          onToggleFullscreen: _toggleFullscreen,
          onRetry: _retryPlayback,
          onPreviousChannel: _playPreviousChannel,
          onNextChannel: _playNextChannel,
          currentProgram: _currentProgram,
          nextProgram: _nextProgram,
          onOpenGuide: _openGuideForActiveStream,
        ),
      );
    }

    // 1. Modo Tela Cheia: exibe o player ocupando 100% da tela, sem reiniciar a instância
    if (_isFullscreen && _currentType == XtreamCatalogType.live && _activeLiveStream != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toggleFullscreen();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LivePlayerView(
            controller: _playerController,
            channelName: _activeLiveStream!.name,
            channelLogo: _activeLiveStream!.streamIcon,
            groupTitle: _getCategoryName(_activeLiveStream!.categoryId),
            isFullscreen: true,
            isLoading: _isPlayerLoading,
            isBuffering: _isPlayerBuffering,
            errorMessage: _playerError,
            fitMode: _fitMode,
            onFitModeChanged: (mode) => setState(() => _fitMode = mode),
            onTogglePlayPause: _togglePlayPause,
            onToggleFullscreen: _toggleFullscreen,
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
          ),
        ),
      );
    }

    // 2. Modo Normal com ou sem Mini Player
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searchQuery.isNotEmpty || _searchController.text.isNotEmpty) {
          setState(() {
            _searchQuery = '';
            _searchController.clear();
          });
          return;
        }
        if (_selectedCategoryId != 'all') {
          setState(() {
            _selectedCategoryId = 'all';
          });
          _loadItemsForCategory('all');
          return;
        }
        if (_currentType == XtreamCatalogType.live && _activeLiveStream != null) {
          _closeMiniPlayer();
          return;
        }
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF090D14),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F1523),
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
                    color: Color(0xFFF0F4F8),
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
        body: SafeArea(
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
              } else if (showMini && isLandscape) {
                final maxAllowedWidthByHeight = (constraints.maxHeight - 24) * (16 / 9);
                final desiredWidth = (constraints.maxWidth * 0.42).clamp(260.0, 480.0);
                final miniWidth = desiredWidth.clamp(200.0, maxAllowedWidthByHeight.clamp(200.0, 520.0));

                catalogContent = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: miniWidth,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: _buildMiniPlayerWidget(),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _buildTopFilterBar(),
                          Expanded(child: _buildMainContent()),
                        ],
                      ),
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
                    _buildTopFilterBar(),
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

  Widget _buildMiniPlayerWidget() {
    return LivePlayerView(
      controller: _playerController,
      channelName: _activeLiveStream!.name,
      channelLogo: _activeLiveStream!.streamIcon,
      groupTitle: _getCategoryName(_activeLiveStream!.categoryId),
      isFullscreen: false,
      isLoading: _isPlayerLoading,
      isBuffering: _isPlayerBuffering,
      errorMessage: _playerError,
      fitMode: _fitMode,
      onFitModeChanged: (mode) => setState(() => _fitMode = mode),
      onTogglePlayPause: _togglePlayPause,
      onToggleFullscreen: _toggleFullscreen,
      onClose: _closeMiniPlayer,
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

  Widget _buildTopFilterBar() {
    return Container(
      color: const Color(0xFF0F1523),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: _buildCatalogTypeTabs(),
    );
  }

  Widget _buildCatalogTypeTabs() {
    final tabs = [
      (
        key: const Key('catalog_tab_live'),
        type: XtreamCatalogType.live,
        label: 'TV ao vivo',
        icon: Icons.live_tv_rounded,
        accent: const Color(0xFF00E5FF),
      ),
      (
        key: const Key('catalog_tab_movies'),
        type: XtreamCatalogType.movies,
        label: 'Filmes',
        icon: Icons.movie_outlined,
        accent: const Color(0xFF29B6F6),
      ),
      (
        key: const Key('catalog_tab_series'),
        type: XtreamCatalogType.series,
        label: 'Séries',
        icon: Icons.video_library_outlined,
        accent: const Color(0xFF1E88E5),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF141D2D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1F2B40), width: 1.0),
      ),
      child: Row(
        children: [
          for (final tab in tabs)
            Expanded(
              child: _CatalogTabItem(
                tabKey: tab.key,
                label: tab.label,
                icon: tab.icon,
                accentColor: tab.accent,
                isSelected: _currentType == tab.type,
                onTap: () => _switchCatalogType(tab.type),
              ),
            ),
        ],
      ),
    );
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
                    onToggleFavorite: () => _toggleLiveFavorite(item),
                    onTap: () => _onItemTap(item),
                  ),
                );
              },
            );
          }
        }

        // Se for Filmes ou Séries: formato de pôster vertical (aspect ratio ~2:3)
        final itemWidth = isLandscape ? 160.0 : 120.0;
        final crossAxisCount = (constraints.maxWidth ~/ itemWidth).clamp(2, 8);

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
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

class _CatalogTabItem extends StatefulWidget {
  final Key tabKey;
  final String label;
  final IconData icon;
  final Color accentColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _CatalogTabItem({
    required this.tabKey,
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_CatalogTabItem> createState() => _CatalogTabItemState();
}

class _CatalogTabItemState extends State<_CatalogTabItem> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final activeColor = widget.accentColor;
    const inactiveColor = Color(0xFF7E8B9B);

    return FocusableActionDetector(
      key: widget.tabKey,
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? activeColor.withValues(alpha: 0.22)
                  : (isHighlighted ? activeColor.withValues(alpha: 0.10) : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: isHighlighted
                  ? Border.all(color: activeColor, width: 1.5)
                  : (widget.isSelected
                      ? Border.all(color: activeColor.withValues(alpha: 0.6), width: 1.0)
                      : Border.all(color: Colors.transparent, width: 1.0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.isSelected ? activeColor : (isHighlighted ? Colors.white : inactiveColor),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w500,
                      color: widget.isSelected ? const Color(0xFFF0F4F8) : (isHighlighted ? Colors.white : inactiveColor),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveChannelCard extends StatefulWidget {
  final XtreamLiveStream stream;
  final Color accentColor;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onTap;

  const _LiveChannelCard({
    required this.stream,
    required this.accentColor,
    this.isPlaying = false,
    this.isFavorite = false,
    this.onToggleFavorite,
    required this.onTap,
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
      onFocusChange: (focused) {
        if (!focused) {
          _longPressTimer?.cancel();
          _isKeyDown = false;
          _longPressTriggered = false;
        }
        setState(() => _isFocused = focused);
      },
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedScale(
          scale: isHighlighted ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: widget.isPlaying ? const Color(0xFF14243B) : const Color(0xFF121824),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isHighlighted ? widget.accentColor : const Color(0xFF1A2436),
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
        scale: isHighlighted ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: const Color(0xFF121824),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHighlighted ? widget.accentColor : const Color(0xFF1A2436),
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
