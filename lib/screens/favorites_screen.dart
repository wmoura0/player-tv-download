import 'package:flutter/material.dart';
import '../models/favorite_item.dart';
import '../models/xtream_account.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/secure_storage_service.dart';
import '../services/xtream_catalog_service.dart';
import '../theme/app_colors.dart';
import 'series_detail_screen.dart';
import 'vod_detail_screen.dart';
import 'xtream_catalog_screen.dart';

/// Tela central de Favoritos dividida em abas (TV ao vivo, Filmes e Séries),
/// com suporte a celular (retrato/paisagem) e controle remoto (D-Pad).
class FavoritesScreen extends StatefulWidget {
  final XtreamAccount? xtreamAccount;
  final XtreamCatalogService? catalogService;

  const FavoritesScreen({
    super.key,
    this.xtreamAccount,
    this.catalogService,
  });

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  XtreamCatalogService? _service;
  String _accountKey = '';
  bool _isLoading = true;

  List<FavoriteItem> _liveFavorites = [];
  List<FavoriteItem> _movieFavorites = [];
  List<FavoriteItem> _seriesFavorites = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    FavoritesService.instance.addListener(_onFavoritesChanged);
    _initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    FavoritesService.instance.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) {
      _loadFavorites();
    }
  }

  Future<void> _initialize() async {
    setState(() => _isLoading = true);

    if (widget.catalogService != null) {
      _service = widget.catalogService;
      _accountKey = PlaybackProgressService.buildAccountKey(
        _service!.serverUrl,
        _service!.username,
      );
    } else if (widget.xtreamAccount != null) {
      _accountKey = PlaybackProgressService.buildAccountKey(
        widget.xtreamAccount!.serverUrl,
        widget.xtreamAccount!.username,
      );
      final storage = SecureStorageService();
      final pass = await storage.getPassword();
      if (pass != null) {
        _service = XtreamCatalogService(
          serverUrl: widget.xtreamAccount!.serverUrl,
          username: widget.xtreamAccount!.username,
          password: pass,
        );
      }
    } else {
      final storage = SecureStorageService();
      final server = await storage.getServerUrl();
      final user = await storage.getUsername();
      final pass = await storage.getPassword();
      if (server != null && user != null && pass != null) {
        _service = XtreamCatalogService(
          serverUrl: server,
          username: user,
          password: pass,
        );
        _accountKey = PlaybackProgressService.buildAccountKey(server, user);
      }
    }

    await _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    if (_accountKey.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final all = await FavoritesService.instance.getFavorites(scopeKey: _accountKey);

    if (mounted) {
      setState(() {
        _liveFavorites = all.where((i) => i.type == FavoriteType.live || i.type == FavoriteType.m3uChannel).toList();
        _movieFavorites = all.where((i) => i.type == FavoriteType.movie).toList();
        _seriesFavorites = all.where((i) => i.type == FavoriteType.series).toList();
        _isLoading = false;
      });
    }
  }

  Future<void> _removeFavorite(FavoriteItem item) async {
    await FavoritesService.instance.removeFavorite(
      scopeKey: item.scopeKey,
      type: item.type,
      id: item.id,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${item.name}" removido dos favoritos.'),
        backgroundColor: const Color(0xFF162032),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Desfazer',
          textColor: const Color(0xFF00E5FF),
          onPressed: () async {
            await FavoritesService.instance.addFavorite(item);
          },
        ),
      ),
    );
  }

  void _onLiveItemTap(FavoriteItem item) {
    if (_service == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XtreamCatalogScreen(
          type: XtreamCatalogType.live,
          catalogService: _service!,
          initialLiveStream: item.toLiveStream(),
        ),
      ),
    );
  }

  void _onMovieItemTap(FavoriteItem item) {
    if (_service == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VodDetailScreen(
          movie: item.toVodStream(),
          catalogService: _service!,
          accountKey: _accountKey,
        ),
      ),
    );
  }

  void _onSeriesItemTap(FavoriteItem item) {
    if (_service == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(
          series: item.toSeriesItem(),
          catalogService: _service!,
          accountKey: _accountKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _liveFavorites.length + _movieFavorites.length + _seriesFavorites.length;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Row(
          children: [
            const Icon(Icons.favorite_rounded, color: AppColors.error, size: 24),
            const SizedBox(width: 10),
            const Text(
              'Meus Favoritos',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Text(
                '$totalCount',
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          tabs: [
            Tab(
              icon: const Icon(Icons.live_tv_rounded, size: 20),
              text: 'Canais (${_liveFavorites.length})',
            ),
            Tab(
              icon: const Icon(Icons.movie_outlined, size: 20),
              text: 'Filmes (${_movieFavorites.length})',
            ),
            Tab(
              icon: const Icon(Icons.video_library_outlined, size: 20),
              text: 'Séries (${_seriesFavorites.length})',
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              )
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildLiveTab(),
                  _buildMoviesTab(),
                  _buildSeriesTab(),
                ],
              ),
      ),
    );
  }

  Widget _buildLiveTab() {
    if (_liveFavorites.isEmpty) {
      return _buildEmptyState(
        'canais de TV ao vivo',
        Icons.live_tv_rounded,
        'Navegue pelo catálogo de TV ao vivo e toque no ícone de coração para favoritar seus canais preferidos.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        final crossAxisCount = isLandscape ? (constraints.maxWidth ~/ 280).clamp(1, 5) : 1;

        if (crossAxisCount > 1) {
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisExtent: 76,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _liveFavorites.length,
            itemBuilder: (context, index) {
              final item = _liveFavorites[index];
              return _FavoriteChannelTile(
                item: item,
                onTap: () => _onLiveItemTap(item),
                onRemove: () => _removeFavorite(item),
              );
            },
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: _liveFavorites.length,
          itemBuilder: (context, index) {
            final item = _liveFavorites[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: _FavoriteChannelTile(
                item: item,
                onTap: () => _onLiveItemTap(item),
                onRemove: () => _removeFavorite(item),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMoviesTab() {
    if (_movieFavorites.isEmpty) {
      return _buildEmptyState(
        'filmes',
        Icons.movie_outlined,
        'Navegue pelo catálogo de Filmes e toque no ícone de coração para adicionar seus favoritos aqui.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
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
          itemCount: _movieFavorites.length,
          itemBuilder: (context, index) {
            final item = _movieFavorites[index];
            return _FavoritePosterCard(
              title: item.name,
              imageUrl: item.iconUrl,
              rating: item.rating,
              fallbackIcon: Icons.movie_outlined,
              accentColor: const Color(0xFF29B6F6),
              onTap: () => _onMovieItemTap(item),
              onRemove: () => _removeFavorite(item),
            );
          },
        );
      },
    );
  }

  Widget _buildSeriesTab() {
    if (_seriesFavorites.isEmpty) {
      return _buildEmptyState(
        'séries',
        Icons.video_library_outlined,
        'Navegue pelo catálogo de Séries e toque no ícone de coração para acompanhar suas séries preferidas.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
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
          itemCount: _seriesFavorites.length,
          itemBuilder: (context, index) {
            final item = _seriesFavorites[index];
            return _FavoritePosterCard(
              title: item.name,
              imageUrl: item.iconUrl,
              rating: item.rating,
              fallbackIcon: Icons.video_library_outlined,
              accentColor: const Color(0xFF1E88E5),
              onTap: () => _onSeriesItemTap(item),
              onRemove: () => _removeFavorite(item),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(String contentType, IconData icon, String hint) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF141D2D),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF1E283D)),
                ),
                child: Icon(icon, size: 52, color: const Color(0xFF5A6E85)),
              ),
              const SizedBox(height: 18),
              Text(
                'Nenhum item em $contentType',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF0F4F8),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8A99AD),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteChannelTile extends StatefulWidget {
  final FavoriteItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoriteChannelTile({
    required this.item,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_FavoriteChannelTile> createState() => _FavoriteChannelTileState();
}

class _FavoriteChannelTileState extends State<_FavoriteChannelTile> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedScale(
        scale: isHighlighted ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isHighlighted ? AppColors.focusCyan : AppColors.borderSubtle,
              width: isHighlighted ? AppColors.focusBorderWidth : 1.0,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(10),
              splashColor: AppColors.primary.withValues(alpha: 0.15),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _buildLogo(widget.item.iconUrl),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            widget.item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Row(
                            children: [
                              Icon(Icons.play_circle_outline_rounded, size: 12, color: AppColors.primary),
                              SizedBox(width: 4),
                              Text(
                                'Toque para assistir',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remover dos favoritos',
                      icon: const Icon(Icons.favorite_rounded, color: AppColors.error, size: 20),
                      onPressed: widget.onRemove,
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
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: const Icon(Icons.live_tv_rounded, color: AppColors.primary, size: 20),
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

class _FavoritePosterCard extends StatefulWidget {
  final String title;
  final String? imageUrl;
  final String? rating;
  final IconData fallbackIcon;
  final Color accentColor;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoritePosterCard({
    required this.title,
    required this.imageUrl,
    this.rating,
    required this.fallbackIcon,
    required this.accentColor,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_FavoritePosterCard> createState() => _FavoritePosterCardState();
}

class _FavoritePosterCardState extends State<_FavoritePosterCard> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedScale(
        scale: isHighlighted ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHighlighted ? AppColors.focusCyan : AppColors.borderSubtle,
              width: isHighlighted ? AppColors.focusBorderWidth : 1.0,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.45),
                      blurRadius: 12,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                        // Botão de desfavoritar no topo esquerdo
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: widget.onRemove,
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: const Color(0xDD090D14),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFFEF5350), width: 0.8),
                                ),
                                child: const Icon(Icons.favorite_rounded, size: 14, color: Color(0xFFEF5350)),
                              ),
                            ),
                          ),
                        ),
                        // Badge de Nota no topo direito
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
