import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/xtream_account.dart';
import 'models/xtream_catalog.dart';
import 'screens/favorites_screen.dart';
import 'screens/global_search_screen.dart';
import 'screens/playlists_screen.dart';
import 'screens/series_detail_screen.dart';
import 'screens/series_player_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/vod_detail_screen.dart';
import 'screens/vod_player_screen.dart';
import 'screens/xtream_catalog_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/xtream_login_screen.dart';
import 'services/hidden_categories_service.dart';
import 'services/playback_progress_service.dart';
import 'services/secure_storage_service.dart';
import 'services/settings_service.dart';
import 'services/xtream_catalog_service.dart';
import 'theme/app_colors.dart';
import 'utils/device_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[CRASH_GUARD] Flutter error capturado: ${details.exceptionAsString()}');
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    debugPrint('[CRASH_GUARD] Platform error capturado: $error');
    return true;
  };

  try {
    await SettingsService.instance.loadSettings();
    await HiddenCategoriesService.instance.init();
    await DeviceUtils.init();
    await DeviceUtils.setNormalOrientation();
  } catch (e, st) {
    debugPrint('[INIT_ERROR] Falha na inicialização dos serviços: $e\n$st');
  }

  runApp(const PlayerTvApp());
}

/// Widget principal do aplicativo configurado com tema escuro e identidade visual dinâmica.
class PlayerTvApp extends StatelessWidget {
  final Widget? home;
  const PlayerTvApp({super.key, this.home});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SettingsService.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'JessFlix',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: AppColors.background,
            colorScheme: const ColorScheme.dark(
              primary: AppColors.primary,
              secondary: AppColors.focusCyan,
              surface: AppColors.surfaceSecondary,
              onSurface: AppColors.textPrimary,
            ),
            useMaterial3: true,
          ),
          home: home ?? const SplashScreen(),
        );
      },
    );
  }
}

/// Tela inicial redesenhada no estilo Smart TV, com foco no conteúdo, tema escuro,
/// suporte fluido a controle remoto (D-Pad) e toque, barra inferior com ícones e nomes,
/// e seções dinâmicas de "Continuar assistindo" e conteúdos recentes.
class HomeScreen extends StatefulWidget {
  final XtreamAccount? xtreamAccount;

  const HomeScreen({super.key, this.xtreamAccount});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final PlaybackProgressService _progressService = PlaybackProgressService();
  final ScrollController _scrollController = ScrollController();

  List<ContinueWatchingItem> _continuarAssistindo = [];
  List<XtreamVodStream> _recentMovies = [];
  List<XtreamSeriesItem> _recentSeries = [];

  XtreamCatalogService? _sharedCatalogService;
  String _accountKey = '';

  bool _isInitializingCatalog = false;

  @override
  void initState() {
    super.initState();
    _loadHomeData();
  }

  @override
  void dispose() {
    _sharedCatalogService?.removeListener(_onCatalogServiceUpdated);
    _scrollController.dispose();
    super.dispose();
  }

  void _onCatalogServiceUpdated() {
    if (mounted) {
      _loadRecentCachedMedia();
    }
  }

  Future<void> _initSharedCatalogService() async {
    if (_sharedCatalogService != null || _isInitializingCatalog) return;
    _isInitializingCatalog = true;
    try {
      if (widget.xtreamAccount != null) {
        _accountKey = PlaybackProgressService.buildAccountKey(
          widget.xtreamAccount!.serverUrl,
          widget.xtreamAccount!.username,
        );
        final storage = SecureStorageService();
        final pass = await storage.getPassword().timeout(
          const Duration(seconds: 4),
          onTimeout: () => null,
        );
        if (!mounted) return;
        if (pass != null) {
          _sharedCatalogService = XtreamCatalogService(
            serverUrl: widget.xtreamAccount!.serverUrl,
            username: widget.xtreamAccount!.username,
            password: pass,
          );
          _sharedCatalogService!.addListener(_onCatalogServiceUpdated);
          _sharedCatalogService!.preloadCatalogsInBackground();
        }
      } else {
        _accountKey = '';
        _sharedCatalogService = null;
      }
    } catch (e) {
      debugPrint('[HOME] Falha ao inicializar serviço de catálogo: $e');
    } finally {
      _isInitializingCatalog = false;
    }
  }

  Future<void> _loadHomeData() async {
    await _initSharedCatalogService();

    if (_accountKey.isNotEmpty) {
      final items = await _progressService.getContinueWatchingList(accountKey: _accountKey);
      if (mounted) {
        setState(() {
          _continuarAssistindo = items;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _continuarAssistindo = [];
        });
      }
    }

    await _loadRecentCachedMedia();
  }

  Future<void> _loadRecentCachedMedia() async {
    if (_sharedCatalogService != null) {
      final movies = await _sharedCatalogService!.getRecentMovies(limit: 5);
      final series = await _sharedCatalogService!.getRecentSeries(limit: 5);
      if (mounted) {
        setState(() {
          _recentMovies = movies;
          _recentSeries = series;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _recentMovies = [];
          _recentSeries = [];
        });
      }
    }
  }

  Future<XtreamCatalogService?> _getOrInitCatalogService() async {
    if (widget.xtreamAccount == null) return null;
    if (_sharedCatalogService != null) return _sharedCatalogService;
    final storage = SecureStorageService();
    final pass = await storage.getPassword();
    if (pass != null) {
      _sharedCatalogService = XtreamCatalogService(
        serverUrl: widget.xtreamAccount!.serverUrl,
        username: widget.xtreamAccount!.username,
        password: pass,
      );
    }
    return _sharedCatalogService;
  }

  Future<void> _onCategorySelected(String categoryTitle) async {
    final service = await _getOrInitCatalogService();
    final isXtream = widget.xtreamAccount != null && service != null;

    if (!mounted) return;

    if (categoryTitle == 'TV ao vivo') {
      if (isXtream) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => XtreamCatalogScreen(
              type: XtreamCatalogType.live,
              catalogService: service,
            ),
          ),
        ).then((_) => _loadHomeData());
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const PlaylistsScreen(),
          ),
        ).then((_) => _loadHomeData());
      }
    } else if (categoryTitle == 'Filmes') {
      if (isXtream) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => XtreamCatalogScreen(
              type: XtreamCatalogType.movies,
              catalogService: service,
            ),
          ),
        ).then((_) => _loadHomeData());
      } else {
        _showNotice('Para acessar Filmes, conecte-se com sua conta Xtream Codes.');
      }
    } else if (categoryTitle == 'Séries') {
      if (isXtream) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => XtreamCatalogScreen(
              type: XtreamCatalogType.series,
              catalogService: service,
            ),
          ),
        ).then((_) => _loadHomeData());
      } else {
        _showNotice('Para acessar Séries, conecte-se com sua conta Xtream Codes.');
      }
    } else if (categoryTitle == 'Favoritos') {
      _onOpenFavorites();
    } else if (categoryTitle == 'Playlist') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const PlaylistsScreen(),
        ),
      ).then((_) => _loadHomeData());
    } else {
      _showNotice(categoryTitle);
    }
  }

  Future<void> _onSelectContinueWatching(ContinueWatchingItem item) async {
    final service = await _getOrInitCatalogService();
    if (service == null) {
      _showNotice('Para continuar, conecte-se com sua conta Xtream Codes.');
      return;
    }
    final accKey = _accountKey;

    if (item.type == ContinueWatchingType.movie) {
      final movie = XtreamVodStream(
        streamId: item.streamId,
        name: item.title,
        streamIcon: item.coverUrl,
        categoryId: item.categoryId ?? '0',
        containerExtension: item.containerExtension,
      );
      final streamUrls = service.buildVodStreamUrls(movie);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VodPlayerScreen(
            movie: movie,
            streamUrls: streamUrls,
            accountKey: accKey,
            initialPosition: item.position,
          ),
        ),
      ).then((_) {
        DeviceUtils.restoreOrientation();
        _loadHomeData();
      });
    } else if (item.type == ContinueWatchingType.series && item.seriesId != null) {
      final series = XtreamSeriesItem(
        seriesId: item.seriesId!,
        name: item.title,
        cover: item.coverUrl,
        categoryId: item.categoryId ?? '0',
      );

      final info = await service.fetchSeriesInfo(item.seriesId!);
      if (!mounted) return;

      if (info != null) {
        final ep = info.findEpisodeById(item.streamId);
        if (ep != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SeriesPlayerScreen(
                series: series,
                seriesInfo: info,
                initialEpisode: ep,
                catalogService: service,
                accountKey: accKey,
                initialPosition: item.position,
              ),
            ),
          ).then((_) {
            DeviceUtils.restoreOrientation();
            _loadHomeData();
          });
          return;
        }
      }

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SeriesDetailScreen(
            series: series,
            catalogService: service,
            accountKey: accKey,
          ),
        ),
      ).then((_) => _loadHomeData());
    }
  }

  void _onSelectRecentMovie(XtreamVodStream movie) async {
    final service = await _getOrInitCatalogService();
    if (service == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VodDetailScreen(
          movie: movie,
          catalogService: service,
          accountKey: _accountKey,
        ),
      ),
    ).then((_) => _loadHomeData());
  }

  void _onSelectRecentSeries(XtreamSeriesItem series) async {
    final service = await _getOrInitCatalogService();
    if (service == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(
          series: series,
          catalogService: service,
          accountKey: _accountKey,
        ),
      ),
    ).then((_) => _loadHomeData());
  }

  void _showNotice(String itemTitle) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$itemTitle: funcionalidade em desenvolvimento.',
          style: const TextStyle(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.surfaceSecondary,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.focusCyan, width: 1),
        ),
      ),
    );
  }

  Future<void> _onSearchPressed() async {
    final service = await _getOrInitCatalogService();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlobalSearchScreen(
          catalogService: service,
          accountKey: _accountKey,
        ),
      ),
    ).then((_) => _loadHomeData());
  }

  Future<void> _onSettingsPressed() async {
    final service = await _getOrInitCatalogService();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          xtreamAccount: widget.xtreamAccount,
          catalogService: service,
        ),
      ),
    ).then((_) => _loadHomeData());
  }

  Future<void> _onOpenFavorites() async {
    final service = await _getOrInitCatalogService();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FavoritesScreen(
          xtreamAccount: widget.xtreamAccount,
          catalogService: service,
        ),
      ),
    ).then((_) => _loadHomeData());
  }

  Future<void> _confirmRemoveContinueWatching(ContinueWatchingItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderSubtle, width: 1),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.error,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Remover item',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            'Deseja remover "${item.title}" de Continuar assistindo?\n\nO progresso original não será apagado.',
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                'Cancelar',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remover'),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      final id = (item.type == ContinueWatchingType.movie)
          ? item.streamId
          : (item.seriesId ?? item.streamId);

      // Atualiza a interface e exibe o feedback imediatamente
      setState(() {
        _continuarAssistindo.removeWhere(
          (cw) => cw.streamId == item.streamId && cw.type == item.type,
        );
      });

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '"${item.title}" removido de Continuar assistindo.',
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          backgroundColor: AppColors.surfaceSecondary,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.focusCyan, width: 1),
          ),
        ),
      );

      await _progressService.removeContinueWatchingItem(
        accountKey: _accountKey,
        type: item.type,
        id: id,
      );

      await _loadHomeData();
    }
  }

  void _onLogout() {
    _sharedCatalogService?.removeListener(_onCatalogServiceUpdated);
    _sharedCatalogService?.clearCache();
    _sharedCatalogService = null;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => const XtreamLoginScreen(autoLogin: false),
      ),
    );
  }

  Future<bool> _onConfirmExit() async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
        title: const Text('Sair do JessFlix', style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'Deseja realmente fechar o aplicativo?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sair'),
          ),
        ],
      ),
    );
    return shouldExit ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          final exit = await _onConfirmExit();
          if (exit && mounted) {
            SystemNavigator.pop();
          }
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;
              final isWideScreen = constraints.maxWidth >= 900;
              final horizontalPadding = isLandscape ? (isWideScreen ? 48.0 : 32.0) : 16.0;

              return CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // Cabeçalho superior compacto
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                        vertical: 12.0,
                      ),
                      child: _AppHeader(
                        xtreamAccount: widget.xtreamAccount,
                        onSearchTap: _onSearchPressed,
                        onSettingsTap: _onSettingsPressed,
                        onLogoutTap: _onLogout,
                        onRecentsTap: () {
                          if (_scrollController.hasClients) {
                            _scrollController.animateTo(
                              320,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut,
                            );
                          }
                        },
                      ),
                    ),
                  ),

                  // Cards principais de categorias (TV ao vivo em destaque + Filmes, Séries, Favoritos, Playlist)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                        vertical: 8.0,
                      ),
                      child: _MainCategoriesSection(
                        isLandscape: isLandscape,
                        onCategoryTap: _onCategorySelected,
                        liveCount: _sharedCatalogService?.totalLiveCount,
                      ),
                    ),
                  ),

                  // Seção "Continuar assistindo" (só exibida com itens salvos)
                  if (_continuarAssistindo.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _ContinueWatchingSection(
                        items: _continuarAssistindo,
                        isLandscape: isLandscape,
                        horizontalPadding: horizontalPadding,
                        onItemTap: _onSelectContinueWatching,
                        onItemDelete: _confirmRemoveContinueWatching,
                      ),
                    ),

                  // Seção "Filmes recentes" (só com dados confiáveis em cache)
                  if (_recentMovies.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _RecentMoviesSection(
                        movies: _recentMovies,
                        isLandscape: isLandscape,
                        horizontalPadding: horizontalPadding,
                        onMovieTap: _onSelectRecentMovie,
                      ),
                    ),

                  // Seção "Séries recentes" (só com dados confiáveis em cache)
                  if (_recentSeries.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _RecentSeriesSection(
                        seriesList: _recentSeries,
                        isLandscape: isLandscape,
                        horizontalPadding: horizontalPadding,
                        onSeriesTap: _onSelectRecentSeries,
                      ),
                    ),

                  // Banner discreto de boas-vindas quando não houver itens em andamento ou recentes
                  if (_continuarAssistindo.isEmpty && _recentMovies.isEmpty && _recentSeries.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPadding,
                          vertical: 16.0,
                        ),
                        child: const _ExploreCatalogBanner(),
                      ),
                    ),

                  // Rodapé discreto de status
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                        vertical: 12.0,
                      ),
                      child: _AppFooterStatus(
                        xtreamAccount: widget.xtreamAccount,
                      ),
                    ),
                  ),

                  // Espaço inferior de respiro
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 24),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Cabeçalho moderno Smart TV com logotipo, relógio digital dinâmico e pílulas de ação rápida.
class _AppHeader extends StatelessWidget {
  final XtreamAccount? xtreamAccount;
  final VoidCallback onSearchTap;
  final VoidCallback onSettingsTap;
  final VoidCallback onLogoutTap;
  final VoidCallback? onRecentsTap;

  const _AppHeader({
    this.xtreamAccount,
    required this.onSearchTap,
    required this.onSettingsTap,
    required this.onLogoutTap,
    this.onRecentsTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 720;
        final showClock = constraints.maxWidth >= 1080;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Identidade visual / Logotipo JessFlix
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surfaceSecondary,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.focusCyan.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/images/jessflix_monogram.png',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.play_arrow_rounded,
                      color: AppColors.focusCyan,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'JessFlix',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: Color(0xFFF5F8FC),
                  ),
                ),
              ],
            ),

            if (showClock) ...[
              const Spacer(),
              const _LiveHeaderClock(),
              const Spacer(),
            ] else ...[
              const Spacer(),
            ],

            // Pílulas de Ação Rápida no Topo à Direita
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HeaderActionButton(
                      key: const Key('header_search_btn'),
                      icon: Icons.search_rounded,
                      tooltip: 'Buscar no catálogo',
                      label: isCompact ? null : 'Buscar',
                      iconColor: AppColors.textSecondary,
                      isCompact: isCompact,
                      onTap: onSearchTap,
                    ),
                    if (onRecentsTap != null && showClock) ...[
                      const SizedBox(width: 8),
                      _HeaderActionButton(
                        key: const Key('header_recents_btn'),
                        icon: Icons.history_rounded,
                        tooltip: 'Recentes',
                        label: 'Recentes',
                        iconColor: AppColors.textSecondary,
                        isCompact: false,
                        onTap: onRecentsTap!,
                      ),
                    ],
                    const SizedBox(width: 8),
                    _HeaderActionButton(
                      key: const Key('header_settings_btn'),
                      icon: Icons.settings_outlined,
                      tooltip: 'Configurações',
                      label: isCompact ? null : 'Configurações',
                      iconColor: AppColors.textSecondary,
                      isCompact: isCompact,
                      onTap: onSettingsTap,
                    ),
                    if (xtreamAccount != null) ...[
                      const SizedBox(width: 8),
                      _HeaderActionButton(
                        key: const Key('header_logout_btn'),
                        icon: Icons.account_circle_outlined,
                        tooltip: 'Sair da conta',
                        label: isCompact
                            ? null
                            : (xtreamAccount!.username.length > 12
                                ? '${xtreamAccount!.username.substring(0, 10)}...'
                                : xtreamAccount!.username),
                        iconColor: AppColors.textSecondary,
                        isCompact: isCompact,
                        onTap: onLogoutTap,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Relógio digital com atualização periódica em tempo real para o cabeçalho IPTV.
class _LiveHeaderClock extends StatefulWidget {
  const _LiveHeaderClock();

  @override
  State<_LiveHeaderClock> createState() => _LiveHeaderClockState();
}

class _LiveHeaderClockState extends State<_LiveHeaderClock> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatDate(DateTime dt) {
    const weekdays = [
      'Segunda-feira',
      'Terça-feira',
      'Quarta-feira',
      'Quinta-feira',
      'Sexta-feira',
      'Sábado',
      'Domingo',
    ];
    const months = [
      'Janeiro',
      'Fevereiro',
      'Março',
      'Abril',
      'Maio',
      'Junho',
      'Julho',
      'Agosto',
      'Setembro',
      'Outubro',
      'Novembro',
      'Dezembro',
    ];
    final w = weekdays[dt.weekday - 1];
    final m = months[dt.month - 1];
    return '$w, ${dt.day} De $m';
  }

  @override
  Widget build(BuildContext context) {
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$hh:$mm',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Color(0xFFF5F8FC),
            letterSpacing: 1.0,
          ),
        ),
        Text(
          _formatDate(_now),
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: Color(0xFF8DAEC4),
          ),
        ),
      ],
    );
  }
}

/// Botão de ação do cabeçalho com foco visual e hover para Android TV, suportando formato de pílula.
class _HeaderActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final String? label;
  final Color iconColor;
  final bool isCompact;
  final VoidCallback onTap;

  const _HeaderActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.label,
    required this.iconColor,
    this.isCompact = false,
    required this.onTap,
  });

  @override
  State<_HeaderActionButton> createState() => _HeaderActionButtonState();
}

class _HeaderActionButtonState extends State<_HeaderActionButton> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final isPill = widget.label != null && !widget.isCompact;

    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: Tooltip(
        message: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: isHighlighted
                ? AppColors.focusCyan.withValues(alpha: 0.18)
                : AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(isPill ? 18 : 20),
            border: Border.all(
              color: isHighlighted ? AppColors.focusCyan : AppColors.borderSubtle,
              width: isHighlighted ? AppColors.focusBorderWidth : AppColors.normalBorderWidth,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.35),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(isPill ? 18 : 20),
              onTap: widget.onTap,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isPill ? 10 : 7,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.icon,
                      color: isHighlighted ? AppColors.focusCyan : widget.iconColor,
                      size: 17,
                    ),
                    if (isPill) ...[
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          widget.label!,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isHighlighted ? Colors.white : AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Seção horizontal de "Continuar assistindo", exibida somente quando há conteúdo real.
class _ContinueWatchingSection extends StatelessWidget {
  final List<ContinueWatchingItem> items;
  final bool isLandscape;
  final double horizontalPadding;
  final ValueChanged<ContinueWatchingItem> onItemTap;
  final ValueChanged<ContinueWatchingItem> onItemDelete;

  const _ContinueWatchingSection({
    required this.items,
    required this.isLandscape,
    required this.horizontalPadding,
    required this.onItemTap,
    required this.onItemDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final cardWidth = isLandscape ? (DeviceUtils.isTv ? 240.0 : 220.0) : 185.0;
    final cardHeight = isLandscape ? (DeviceUtils.isTv ? 148.0 : 136.0) : 118.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 12.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.play_circle_outline_rounded,
                size: 19,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                'Continuar assistindo',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                  color: Color(0xFFF5F8FC),
                ),
              ),
              const Spacer(),
              Text(
                '${items.length} ${items.length == 1 ? 'item' : 'itens'}',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return _ContinueWatchingCard(
                  item: item,
                  width: cardWidth,
                  height: cardHeight,
                  onTap: () => onItemTap(item),
                  onDelete: () => onItemDelete(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Card compacto para o carrossel de Continuar Assistindo.
class _ContinueWatchingCard extends StatefulWidget {
  final ContinueWatchingItem item;
  final double width;
  final double height;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ContinueWatchingCard({
    required this.item,
    required this.width,
    required this.height,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<_ContinueWatchingCard> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final isSeries = widget.item.type == ContinueWatchingType.series;

    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedScale(
        scale: DeviceUtils.isTv ? 1.0 : (isHighlighted ? 1.03 : 1.0),
        duration: const Duration(milliseconds: 160),
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHighlighted ? AppColors.focusCyan : AppColors.borderSubtle,
              width: isHighlighted ? AppColors.focusBorderWidth : AppColors.normalBorderWidth,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : const [
                    BoxShadow(
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
              child: Stack(
                children: [
                  // Imagem de fundo ou gradiente fallback
                  if (widget.item.coverUrl != null && widget.item.coverUrl!.isNotEmpty)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          widget.item.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _buildFallbackBackground(isSeries),
                        ),
                      ),
                    )
                  else
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _buildFallbackBackground(isSeries),
                      ),
                    ),

                  // Gradiente escuro para legibilidade do texto
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.15),
                            Colors.black.withValues(alpha: 0.85),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Badge de tipo no topo
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isSeries ? 'SÉRIE' : 'FILME',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),

                  // Botão discreto de excluir no canto superior direito
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _ContinueWatchingDeleteButton(
                      title: widget.item.title,
                      onDelete: widget.onDelete,
                    ),
                  ),

                  // Botão de Play sutil central
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isHighlighted ? const Color(0xFF00E5FF) : Colors.white38,
                          width: 1,
                        ),
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: isHighlighted ? AppColors.focusCyan : Colors.white,
                        size: 20,
                      ),
                    ),
                  ),

                  // Título, Subtítulo e barra de progresso na base
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.item.title,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFF5F8FC),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.item.subtitle != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            widget.item.subtitle!,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94A3B8),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: widget.item.progressRatio,
                            minHeight: 3.5,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                          ),
                        ),
                      ],
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

  Widget _buildFallbackBackground(bool isSeries) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isSeries
              ? [const Color(0xFF16233B), const Color(0xFF0E1626)]
              : [const Color(0xFF102A38), const Color(0xFF0A1C26)],
        ),
      ),
      child: Center(
        child: Icon(
          isSeries ? Icons.video_library_outlined : Icons.movie_outlined,
          color: Colors.white12,
          size: 40,
        ),
      ),
    );
  }
}

/// Botão discreto de exclusão com suporte a foco D-pad e toque.
class _ContinueWatchingDeleteButton extends StatefulWidget {
  final String title;
  final VoidCallback onDelete;

  const _ContinueWatchingDeleteButton({
    required this.title,
    required this.onDelete,
  });

  @override
  State<_ContinueWatchingDeleteButton> createState() => _ContinueWatchingDeleteButtonState();
}

class _ContinueWatchingDeleteButtonState extends State<_ContinueWatchingDeleteButton> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onDelete),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: Tooltip(
        message: 'Remover "${widget.title}" de Continuar assistindo',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            onTap: widget.onDelete,
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: isHighlighted
                    ? const Color(0xFFEF5350).withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isHighlighted ? const Color(0xFFEF5350) : Colors.white24,
                  width: isHighlighted ? 1.5 : 1.0,
                ),
                boxShadow: isHighlighted
                    ? [
                        BoxShadow(
                          color: const Color(0xFFEF5350).withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                Icons.delete_outline_rounded,
                size: 15,
                color: isHighlighted ? const Color(0xFFFF8A80) : const Color(0xFFB0BEC5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Seção horizontal para Filmes Recentes (exibida apenas com dados confiáveis em cache).
class _RecentMoviesSection extends StatelessWidget {
  final List<XtreamVodStream> movies;
  final bool isLandscape;
  final double horizontalPadding;
  final ValueChanged<XtreamVodStream> onMovieTap;

  const _RecentMoviesSection({
    required this.movies,
    required this.isLandscape,
    required this.horizontalPadding,
    required this.onMovieTap,
  });

  @override
  Widget build(BuildContext context) {
    if (movies.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 12.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.new_releases_outlined, size: 18, color: Color(0xFF29B6F6)),
              SizedBox(width: 8),
              Text(
                'Adicionados recentemente — Filmes',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5F8FC),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: DeviceUtils.isTv ? 190 : 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: movies.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final movie = movies[index];
                return _MediaPosterCard(
                  title: movie.name,
                  imageUrl: movie.streamIcon,
                  rating: movie.rating,
                  onTap: () => onMovieTap(movie),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Seção horizontal para Séries Recentes (exibida apenas com dados confiáveis em cache).
class _RecentSeriesSection extends StatelessWidget {
  final List<XtreamSeriesItem> seriesList;
  final bool isLandscape;
  final double horizontalPadding;
  final ValueChanged<XtreamSeriesItem> onSeriesTap;

  const _RecentSeriesSection({
    required this.seriesList,
    required this.isLandscape,
    required this.horizontalPadding,
    required this.onSeriesTap,
  });

  @override
  Widget build(BuildContext context) {
    if (seriesList.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 12.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.new_releases_outlined, size: 18, color: Color(0xFF1E88E5)),
              SizedBox(width: 8),
              Text(
                'Adicionados recentemente — Séries',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5F8FC),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: DeviceUtils.isTv ? 190 : 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: seriesList.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final series = seriesList[index];
                return _MediaPosterCard(
                  title: series.name,
                  imageUrl: series.cover,
                  rating: series.rating,
                  onTap: () => onSeriesTap(series),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Card de pôster vertical para mídias recentes em formato consistente de streaming.
class _MediaPosterCard extends StatefulWidget {
  final String title;
  final String? imageUrl;
  final String? rating;
  final VoidCallback onTap;

  const _MediaPosterCard({
    required this.title,
    this.imageUrl,
    this.rating,
    required this.onTap,
  });

  @override
  State<_MediaPosterCard> createState() => _MediaPosterCardState();
}

class _MediaPosterCardState extends State<_MediaPosterCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      child: AnimatedScale(
        scale: DeviceUtils.isTv ? 1.0 : (_isFocused ? 1.04 : 1.0),
        duration: const Duration(milliseconds: 160),
        child: Container(
          width: DeviceUtils.isTv ? 124 : 110,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _isFocused ? AppColors.focusCyan : AppColors.borderSubtle,
              width: _isFocused ? AppColors.focusBorderWidth : AppColors.normalBorderWidth,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.25),
                      blurRadius: 10,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                      child: widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                          ? Image.network(
                              widget.imageUrl!,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              cacheWidth: 248,
                              cacheHeight: 380,
                              errorBuilder: (_, _, _) => const Center(
                                child: Icon(Icons.movie_outlined, color: Colors.white24, size: 32),
                              ),
                            )
                          : const Center(
                              child: Icon(Icons.movie_outlined, color: Colors.white24, size: 32),
                            ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF5F8FC),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.rating != null && widget.rating!.isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Row(
                            children: [
                              const Icon(Icons.star_rounded, size: 11, color: Color(0xFFFFB300)),
                              const SizedBox(width: 2),
                              Text(
                                widget.rating!,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFFFFB300),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
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
}

/// Banner discreto e acolhedor exibido quando não há conteúdos recentes em cache.
class _ExploreCatalogBanner extends StatelessWidget {
  const _ExploreCatalogBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.35),
              ),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.primary,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pronto para assistir',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF5F8FC),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Selecione uma das categorias acima para explorar canais, filmes ou séries.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryItem {
  final Key key;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final bool autofocus;

  const _CategoryItem({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    this.autofocus = false,
  });
}

/// Seção que organiza o card de destaque de TV ao Vivo e o bloco 2x2 de Filmes, Séries, Favoritos e Playlist.
class _MainCategoriesSection extends StatelessWidget {
  final bool isLandscape;
  final ValueChanged<String> onCategoryTap;
  final int? liveCount;

  const _MainCategoriesSection({
    required this.isLandscape,
    required this.onCategoryTap,
    this.liveCount,
  });

  @override
  Widget build(BuildContext context) {
    final heroItem = _CategoryItem(
      key: const Key('cat_live_tv'),
      title: 'TV ao vivo',
      subtitle: liveCount != null ? '$liveCount canais' : 'Canais em tempo real',
      icon: Icons.live_tv_rounded,
      accentColor: AppColors.primary,
      autofocus: true,
    );

    final subCards = [
      const _CategoryItem(
        key: Key('cat_movies'),
        title: 'Filmes',
        subtitle: 'Catálogo sob demanda',
        icon: Icons.movie_outlined,
        accentColor: AppColors.primary,
      ),
      const _CategoryItem(
        key: Key('cat_series'),
        title: 'Séries',
        subtitle: 'Temporadas e episódios',
        icon: Icons.video_library_outlined,
        accentColor: AppColors.primary,
      ),
      const _CategoryItem(
        key: Key('cat_favorites'),
        title: 'Favoritos',
        subtitle: 'Seus itens marcados',
        icon: Icons.favorite_rounded,
        accentColor: AppColors.primary,
      ),
      const _CategoryItem(
        key: Key('cat_playlists'),
        title: 'Playlist',
        subtitle: 'Adicionar / gerenciar',
        icon: Icons.playlist_play_rounded,
        accentColor: AppColors.primary,
      ),
    ];

    if (isLandscape) {
      return SizedBox(
        height: 200,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cartão de TV ao vivo em destaque (Hero)
            Expanded(
              flex: 40,
              child: _CategoryCard(
                item: heroItem,
                isLandscape: true,
                isHero: true,
                onTap: () => onCategoryTap(heroItem.title),
              ),
            ),
            const SizedBox(width: 12),
            // Bloco 2x2 de Filmes, Séries, Favoritos e Playlist
            Expanded(
              flex: 60,
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _CategoryCard(
                            item: subCards[0],
                            isLandscape: true,
                            onTap: () => onCategoryTap(subCards[0].title),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _CategoryCard(
                            item: subCards[1],
                            isLandscape: true,
                            onTap: () => onCategoryTap(subCards[1].title),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _CategoryCard(
                            item: subCards[2],
                            isLandscape: true,
                            onTap: () => onCategoryTap(subCards[2].title),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _CategoryCard(
                            item: subCards[3],
                            isLandscape: true,
                            onTap: () => onCategoryTap(subCards[3].title),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 135,
          width: double.infinity,
          child: _CategoryCard(
            item: heroItem,
            isLandscape: false,
            isHero: true,
            onTap: () => onCategoryTap(heroItem.title),
          ),
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.2,
          children: subCards
              .map(
                (category) => _CategoryCard(
                  item: category,
                  isLandscape: false,
                  onTap: () => onCategoryTap(category.title),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

/// Card de categoria com suporte a foco (D-Pad para Android/Fire TV), hover e toque.
class _CategoryCard extends StatefulWidget {
  final _CategoryItem item;
  final bool isLandscape;
  final bool isHero;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.item,
    required this.isLandscape,
    this.isHero = false,
    required this.onTap,
  });

  @override
  State<_CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<_CategoryCard> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return FocusableActionDetector(
      key: widget.item.key,
      autofocus: widget.item.autofocus,
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (value) {
        setState(() => _isFocused = value);
      },
      onShowHoverHighlight: (value) {
        setState(() => _isHovered = value);
      },
      child: AnimatedScale(
        scale: DeviceUtils.isTv ? 1.0 : (isHighlighted ? (widget.isLandscape ? 1.03 : 1.02) : 1.0),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isHighlighted
                  ? AppColors.focusCyan
                  : AppColors.borderSubtle,
              width: isHighlighted ? AppColors.focusBorderWidth : AppColors.normalBorderWidth,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: widget.isHero ? 0.35 : 0.25),
                      blurRadius: widget.isHero ? 16 : 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : const [
                    BoxShadow(
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
              borderRadius: BorderRadius.circular(14),
              splashColor: widget.item.accentColor.withValues(alpha: 0.15),
              highlightColor: widget.item.accentColor.withValues(alpha: 0.08),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: widget.isHero ? 10 : 12),
                child: widget.isHero
                    ? _buildHeroContent(isHighlighted)
                    : (widget.isLandscape
                        ? _buildLandscapeContent(isHighlighted)
                        : _buildPortraitContent(isHighlighted)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroContent(bool isHighlighted) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.item.accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.item.accentColor.withValues(alpha: 0.4),
                  width: 1.2,
                ),
              ),
              child: Icon(
                widget.item.icon,
                color: widget.item.accentColor,
                size: 26,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.item.accentColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.item.accentColor.withValues(alpha: 0.35),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFF00E676),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        widget.item.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: widget.item.accentColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const Spacer(),
        Text(
          widget.item.title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: Color(0xFFF5F8FC),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        const Text(
          'Transmissão ao vivo com guia EPG',
          style: TextStyle(
            fontSize: 11,
            color: Color(0xFF8DAEC4),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildLandscapeContent(bool isHighlighted) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: widget.item.accentColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.item.accentColor.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          child: Icon(
            widget.item.icon,
            color: widget.item.accentColor,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                widget.item.subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF8DAEC4),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitContent(bool isHighlighted) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: widget.item.accentColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.item.accentColor.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Icon(
            widget.item.icon,
            color: widget.item.accentColor,
            size: 22,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.item.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                widget.item.subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF8DAEC4),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Rodapé com linha de status discreta informando perfil, usuário e vencimento da lista.
class _AppFooterStatus extends StatelessWidget {
  final XtreamAccount? xtreamAccount;

  const _AppFooterStatus({this.xtreamAccount});

  @override
  Widget build(BuildContext context) {
    String exp = 'Ativo / Indeterminado';
    if (xtreamAccount?.expirationDate != null) {
      final dt = xtreamAccount!.expirationDate!;
      exp = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    }

    final info = xtreamAccount != null
        ? 'Perfil: Padrão   •   Usuário: ${xtreamAccount!.username}   •   Vencimento da lista: $exp'
        : 'Perfil: Padrão   •   Modo: Listas Locais M3U';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          info,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xFF64748B),
            letterSpacing: 0.4,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

