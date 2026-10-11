import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/secure_storage_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import '../widgets/live_player_view.dart';
import 'playlists_screen.dart';
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

class _XtreamCatalogScreenState extends State<XtreamCatalogScreen> {
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

  @override
  void initState() {
    super.initState();
    FavoritesService.instance.addListener(_onFavoritesChanged);
    _initialize();
  }

  @override
  void dispose() {
    FavoritesService.instance.removeListener(_onFavoritesChanged);
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

  String get _accountKey {
    if (_service == null) return '';
    return PlaybackProgressService.buildAccountKey(
      _service!.serverUrl,
      _service!.username,
    );
  }

  FavoriteType get _favoriteType {
    switch (widget.type) {
      case XtreamCatalogType.live:
        return FavoriteType.live;
      case XtreamCatalogType.movies:
        return FavoriteType.movie;
      case XtreamCatalogType.series:
        return FavoriteType.series;
    }
  }

  String get _title {
    switch (widget.type) {
      case XtreamCatalogType.live:
        return 'TV ao vivo';
      case XtreamCatalogType.movies:
        return 'Filmes';
      case XtreamCatalogType.series:
        return 'Séries';
    }
  }

  IconData get _icon {
    switch (widget.type) {
      case XtreamCatalogType.live:
        return Icons.live_tv_rounded;
      case XtreamCatalogType.movies:
        return Icons.movie_outlined;
      case XtreamCatalogType.series:
        return Icons.video_library_outlined;
    }
  }

  Color get _accentColor {
    switch (widget.type) {
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

      if (widget.initialLiveStream != null && widget.type == XtreamCatalogType.live && mounted) {
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
      switch (widget.type) {
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

      // Adiciona categoria de TODOS no início, seguida por Favoritos e as categorias do servidor
      final list = <XtreamCategory>[
        const XtreamCategory(id: 'all', name: 'TODOS'),
        const XtreamCategory(id: 'favorites', name: '❤️ Favoritos'),
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
        switch (widget.type) {
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

    final String typeKey = widget.type == XtreamCatalogType.live
        ? 'live'
        : (widget.type == XtreamCatalogType.movies ? 'movies' : 'series');
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
      switch (widget.type) {
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

  List<dynamic> get _filteredItems {
    if (_searchQuery.trim().isEmpty) return _currentItems;
    final q = _searchQuery.toLowerCase();
    return _currentItems.where((item) {
      if (item is XtreamLiveStream) return item.name.toLowerCase().contains(q);
      if (item is XtreamVodStream) return item.name.toLowerCase().contains(q);
      if (item is XtreamSeriesItem) return item.name.toLowerCase().contains(q);
      return false;
    }).toList();
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
    if (val.hasError && _playerError == null) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(
        val.errorDescription ?? 'Falha na transmissão do canal.',
      );
      setState(() {
        _playerError = safeErr;
        _isPlayerLoading = false;
        _isPlayerBuffering = false;
      });
    } else if (val.isBuffering != _isPlayerBuffering) {
      setState(() {
        _isPlayerBuffering = val.isBuffering;
      });
    }
  }

  Future<void> _playLiveChannel(XtreamLiveStream stream) async {
    // Requisito: Clicar novamente no canal que já está selecionado abre tela cheia sem reiniciar!
    if (_activeLiveStream?.streamId == stream.streamId) {
      _toggleFullscreen();
      return;
    }

    setState(() {
      _activeLiveStream = stream;
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

  Future<void> _fetchEpgForChannel(int streamId) async {
    if (_service == null) return;
    try {
      final epgList = await _service!.fetchShortEpg(streamId);
      if (!mounted || _activeLiveStream?.streamId != streamId) return;
      if (epgList.isNotEmpty) {
        final now = epgList.firstWhere(
          (p) => p.isNowPlaying,
          orElse: () => epgList.first,
        );
        final nextIdx = epgList.indexOf(now) + 1;
        final next = nextIdx < epgList.length ? epgList[nextIdx] : null;

        setState(() {
          _currentProgram = now.title;
          _nextProgram = next?.title;
        });
      }
    } catch (_) {}
  }

  Future<void> _initControllerWithUrl(String url) async {
    final oldController = _playerController;
    _playerController = null;
    oldController?.removeListener(_onPlayerStateChanged);
    await oldController?.pause();
    await oldController?.dispose();

    if (!mounted) return;

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

    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
      if (mounted && _playerController == controller) {
        await controller.play();
        setState(() {
          _isPlayerLoading = false;
          _playerError = null;
          _reconnectAttempts = 0;
        });
      }
    } catch (e) {
      if (mounted && _playerController == controller) {
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
      }
    }
  }

  void _togglePlayPause() {
    final c = _playerController;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
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

  void _retryPlayback() {
    if (_activeLiveStream == null) return;
    setState(() {
      _reconnectAttempts++;
      _isPlayerLoading = true;
      _playerError = null;
      _currentCandidateIndex = 0;
    });
    debugPrint('[PLAYER] Reconectando (tentativa $_reconnectAttempts)...');
    if (_candidateUrls.isNotEmpty) {
      _initControllerWithUrl(_candidateUrls[0]);
    }
  }

  void _onItemTap(dynamic item) {
    if (widget.type == XtreamCatalogType.live && item is XtreamLiveStream) {
      _playLiveChannel(item);
      return;
    }

    if (widget.type == XtreamCatalogType.movies && item is XtreamVodStream && _service != null) {
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

    if (widget.type == XtreamCatalogType.series && item is XtreamSeriesItem && _service != null) {
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

  @override
  Widget build(BuildContext context) {
    // 1. Modo Tela Cheia: exibe o player ocupando 100% da tela, sem reiniciar a instância
    if (_isFullscreen && widget.type == XtreamCatalogType.live && _activeLiveStream != null) {
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
            currentProgram: _currentProgram,
            nextProgram: _nextProgram,
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
    return Scaffold(
      backgroundColor: const Color(0xFF090D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1523),
        title: Row(
          children: [
            Icon(_icon, color: _accentColor, size: 24),
            const SizedBox(width: 10),
            Text(
              _title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF0F4F8),
              ),
            ),
          ],
        ),
        actions: [
          // Acesso rápido a Listas M3U locais
          TextButton.icon(
            icon: const Icon(Icons.playlist_play_rounded, size: 18, color: Color(0xFF8A99AD)),
            label: const Text('Listas M3U', style: TextStyle(color: Color(0xFF8A99AD), fontSize: 13)),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
              );
            },
          ),
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
        child: _isInitLoading
            ? Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
                ),
              )
            : _initError != null
                ? _buildInitError()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final isLandscape = constraints.maxWidth > constraints.maxHeight;
                      final showMini = widget.type == XtreamCatalogType.live && _activeLiveStream != null;

                      if (showMini && isLandscape) {
                        final maxAllowedWidthByHeight = (constraints.maxHeight - 24) * (16 / 9);
                        final desiredWidth = (constraints.maxWidth * 0.42).clamp(260.0, 480.0);
                        final miniWidth = desiredWidth.clamp(200.0, maxAllowedWidthByHeight.clamp(200.0, 520.0));

                        return Row(
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
                      }

                      return Column(
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
                    },
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
      currentProgram: _currentProgram,
      nextProgram: _nextProgram,
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
      child: Column(
        children: [
          // Barra de busca local
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Color(0xFFF0F4F8), fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Buscar em $_title...',
              hintStyle: const TextStyle(color: Color(0xFF5A6E85), fontSize: 14),
              prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF8A99AD), size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, color: Color(0xFF8A99AD), size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF141D2D),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (val) => setState(() => _searchQuery = val),
          ),
          const SizedBox(height: 8),

          // Categorias em Chips horizontais
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final cat = _categories[index];
                final isSelected = cat.id == _selectedCategoryId;

                return _CategoryChip(
                  label: cat.name,
                  isSelected: isSelected,
                  accentColor: _accentColor,
                  onTap: () {
                    if (_selectedCategoryId != cat.id) {
                      setState(() {
                        _selectedCategoryId = cat.id;
                      });
                      _loadItemsForCategory(cat.id);
                    }
                  },
                );
              },
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
        if (widget.type == XtreamCatalogType.live) {
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
                  onToggleFavorite: () async {
                    await FavoritesService.instance.toggleFavorite(
                      FavoriteItem.fromLiveStream(
                        accountKey: _accountKey,
                        stream: item,
                      ),
                    );
                  },
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
                    onToggleFavorite: () async {
                      await FavoritesService.instance.toggleFavorite(
                        FavoriteItem.fromLiveStream(
                          accountKey: _accountKey,
                          stream: item,
                        ),
                      );
                    },
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
            final String? image = widget.type == XtreamCatalogType.movies
                ? (item as XtreamVodStream).streamIcon
                : (item as XtreamSeriesItem).cover;
            final String? rating = widget.type == XtreamCatalogType.movies
                ? (item as XtreamVodStream).rating
                : (item as XtreamSeriesItem).rating;
            final String itemId = widget.type == XtreamCatalogType.movies
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
                final favItem = widget.type == XtreamCatalogType.movies
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
                  ? 'Verifique a ortografia ou selecione o filtro "TODOS" para buscar em todo o catálogo.'
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

class _CategoryChip extends StatefulWidget {
  final String label;
  final bool isSelected;
  final Color accentColor;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.isSelected,
    required this.accentColor,
    required this.onTap,
  });

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      child: InkWell(
        canRequestFocus: false,
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? widget.accentColor
                : (_isFocused ? const Color(0xFF1E2B40) : const Color(0xFF141D2D)),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _isFocused
                  ? Colors.white
                  : (widget.isSelected ? widget.accentColor : const Color(0xFF1E283D)),
              width: _isFocused ? 1.5 : 1.0,
            ),
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
                color: widget.isSelected
                    ? Colors.white
                    : (_isFocused ? Colors.white : const Color(0xFF8A99AD)),
              ),
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

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered || widget.isPlaying;

    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
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

                    if (widget.onToggleFavorite != null)
                      Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        child: IconButton(
                          tooltip: widget.isFavorite ? 'Remover dos favoritos' : 'Favoritar canal',
                          icon: Icon(
                            widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                            size: 20,
                            color: widget.isFavorite ? const Color(0xFFEF5350) : const Color(0xFF8A99AD),
                          ),
                          onPressed: widget.onToggleFavorite,
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
