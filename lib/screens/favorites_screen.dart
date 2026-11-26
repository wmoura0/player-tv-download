import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/favorite_item.dart';
import '../models/xtream_account.dart';
import '../services/account_manager_service.dart';
import '../services/app_toast_service.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/secure_storage_service.dart';
import '../services/user_profile_service.dart';
import '../services/xtream_catalog_service.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';
import 'series_detail_screen.dart';
import 'vod_detail_screen.dart';
import 'xtream_catalog_screen.dart';

enum FavoritesCategoryType {
  live,
  movies,
  series,
}

class _SeriesProgressBadgeData {
  final String label;
  final double progressRatio;

  const _SeriesProgressBadgeData({
    required this.label,
    required this.progressRatio,
  });
}

/// Tela de Favoritos no padrão Smart TV / Fire TV com barra lateral à esquerda
/// (`Início`, `Canais`, `Filmes`, `Séries`) e grade responsiva à direita.
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

class _FavoritesScreenState extends State<FavoritesScreen> {
  final PlaybackProgressService _progressService = PlaybackProgressService();
  final ScrollController _gridScrollController = ScrollController();

  XtreamCatalogService? _service;
  String _accountKey = '';
  bool _isLoading = true;
  bool _isSidebarVisible = true;
  FavoritesCategoryType _selectedCategory = FavoritesCategoryType.live;

  List<FavoriteItem> _liveFavorites = [];
  List<FavoriteItem> _movieFavorites = [];
  List<FavoriteItem> _seriesFavorites = [];
  Map<String, _SeriesProgressBadgeData> _seriesProgressMap = {};

  final FocusNode _sidebarHomeFocusNode = FocusNode(debugLabel: 'FavoritesSidebarHome');
  final Map<FavoritesCategoryType, FocusNode> _sidebarCategoryNodes = {
    FavoritesCategoryType.live: FocusNode(debugLabel: 'FavoritesCat_live'),
    FavoritesCategoryType.movies: FocusNode(debugLabel: 'FavoritesCat_movies'),
    FavoritesCategoryType.series: FocusNode(debugLabel: 'FavoritesCat_series'),
  };

  final List<FocusNode> _liveFocusNodes = [];
  final List<FocusNode> _movieFocusNodes = [];
  final List<FocusNode> _seriesFocusNodes = [];
  final FocusNode _undoBannerFocusNode = FocusNode(debugLabel: 'FavoritesUndoBanner');
  final FocusNode _backButtonFocusNode = FocusNode(debugLabel: 'FavoritesBackButton');

  FavoriteItem? _lastRemovedItem;
  Timer? _undoHideTimer;

  @override
  void initState() {
    super.initState();
    FavoritesService.instance.addListener(_onFavoritesChanged);
    UserProfileService.instance.addListener(_onProfileChanged);
    AccountManagerService.instance.addListener(_onAccountChanged);
    _initialize();
  }

  @override
  void dispose() {
    _undoHideTimer?.cancel();
    AppToastService.instance.dismiss();
    FavoritesService.instance.removeListener(_onFavoritesChanged);
    UserProfileService.instance.removeListener(_onProfileChanged);
    AccountManagerService.instance.removeListener(_onAccountChanged);
    _gridScrollController.dispose();
    _sidebarHomeFocusNode.dispose();
    for (final fn in _sidebarCategoryNodes.values) {
      fn.dispose();
    }
    for (final fn in _liveFocusNodes) {
      fn.dispose();
    }
    for (final fn in _movieFocusNodes) {
      fn.dispose();
    }
    for (final fn in _seriesFocusNodes) {
      fn.dispose();
    }
    _undoBannerFocusNode.dispose();
    _backButtonFocusNode.dispose();
    super.dispose();
  }

  void _syncFocusNodes(List<FocusNode> nodes, int count, String prefix) {
    while (nodes.length > count) {
      nodes.removeLast().dispose();
    }
    while (nodes.length < count) {
      nodes.add(FocusNode(debugLabel: '${prefix}_${nodes.length}'));
    }
  }

  void _onProfileChanged() {
    _undoHideTimer?.cancel();
    AppToastService.instance.dismiss();
    if (mounted && _lastRemovedItem != null) {
      setState(() => _lastRemovedItem = null);
    }
    _loadFavorites();
  }

  void _onAccountChanged() {
    if (widget.xtreamAccount == null && widget.catalogService == null) {
      _undoHideTimer?.cancel();
      AppToastService.instance.dismiss();
      if (mounted && _lastRemovedItem != null) {
        setState(() => _lastRemovedItem = null);
      }
      _service = null;
      _accountKey = '';
      _initialize();
    }
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

  Future<Map<String, _SeriesProgressBadgeData>> _loadSeriesProgressSummaries(
    List<FavoriteItem> seriesList,
  ) async {
    if (_accountKey.isEmpty || seriesList.isEmpty) {
      return const {};
    }
    final entries = await Future.wait(
      seriesList.map((fav) async {
        final sid = int.tryParse(fav.id);
        if (sid == null || sid <= 0) return null;
        try {
          final last = await _progressService.getLastWatchedEpisode(
            accountKey: _accountKey,
            seriesId: sid,
          );
          if (last == null) return null;
          final sNum = last['seasonNumber'];
          final eNum = last['episodeNum'];
          final epId = last['episodeId'];
          final isCompleted = last['isCompleted'] == 1;
          var ratio = 0.0;
          if (isCompleted) {
            ratio = 1.0;
          } else if (epId != null && epId > 0) {
            final epProg = await _progressService.getEpisodeProgress(
              accountKey: _accountKey,
              seriesId: sid,
              episodeId: epId,
            );
            if (epProg != null && epProg.duration.inSeconds > 0) {
              ratio = (epProg.position.inMilliseconds /
                      epProg.duration.inMilliseconds)
                  .clamp(0.0, 1.0);
            }
          }
          final label = isCompleted
              ? 'Concluído'
              : (sNum != null && eNum != null ? 'T$sNum:E$eNum' : 'Em andamento');
          return MapEntry(
            fav.id,
            _SeriesProgressBadgeData(label: label, progressRatio: ratio),
          );
        } catch (_) {
          return null;
        }
      }),
    );

    final map = <String, _SeriesProgressBadgeData>{};
    for (final entry in entries) {
      if (entry != null) {
        map[entry.key] = entry.value;
      }
    }
    return map;
  }

  Future<void> _loadFavorites() async {
    if (_accountKey.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final all = await FavoritesService.instance.getFavorites(scopeKey: _accountKey);
    final live = all
        .where((i) => i.type == FavoriteType.live || i.type == FavoriteType.m3uChannel)
        .toList();
    final movies = all.where((i) => i.type == FavoriteType.movie).toList();
    final series = all.where((i) => i.type == FavoriteType.series).toList();
    final progressMap = await _loadSeriesProgressSummaries(series);

    if (mounted) {
      setState(() {
        _liveFavorites = live;
        _movieFavorites = movies;
        _seriesFavorites = series;
        _seriesProgressMap = progressMap;
        _syncFocusNodes(_liveFocusNodes, _liveFavorites.length, 'FavLive');
        _syncFocusNodes(_movieFocusNodes, _movieFavorites.length, 'FavMovie');
        _syncFocusNodes(_seriesFocusNodes, _seriesFavorites.length, 'FavSeries');
        _isLoading = false;
      });
    }
  }

  Future<void> _undoLastRemoval([FavoriteItem? overrideItem]) async {
    final target = overrideItem ?? _lastRemovedItem;
    if (target == null) return;
    _undoHideTimer?.cancel();
    AppToastService.instance.dismiss();
    if (mounted) {
      setState(() => _lastRemovedItem = null);
    }
    await FavoritesService.instance.addFavorite(target);
  }

  List<FocusNode> _focusNodesForCategory(FavoritesCategoryType category) {
    switch (category) {
      case FavoritesCategoryType.live:
        return _liveFocusNodes;
      case FavoritesCategoryType.movies:
        return _movieFocusNodes;
      case FavoritesCategoryType.series:
        return _seriesFocusNodes;
    }
  }

  void _focusSidebarCategory(FavoritesCategoryType category) {
    if (!mounted) return;
    if (!_isSidebarVisible) {
      setState(() => _isSidebarVisible = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final node = _sidebarCategoryNodes[category];
        if (node != null && node.canRequestFocus) {
          node.requestFocus();
        }
      });
      return;
    }
    final node = _sidebarCategoryNodes[category];
    if (node != null && node.canRequestFocus) {
      node.requestFocus();
    }
  }

  void _focusGridFirstItem([FavoritesCategoryType? category]) {
    if (!mounted) return;
    final targetCategory = category ?? _selectedCategory;
    final nodes = _focusNodesForCategory(targetCategory);
    if (nodes.isNotEmpty) {
      if (_gridScrollController.hasClients && _gridScrollController.offset > 0) {
        _gridScrollController.jumpTo(0);
      }
      final first = nodes.first;
      if (first.context != null && first.canRequestFocus) {
        first.requestFocus();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (nodes.isNotEmpty && nodes.first.canRequestFocus) {
            nodes.first.requestFocus();
          }
        });
      }
    }
  }

  Future<void> _confirmAndRemoveFavorite(
    FavoriteItem item, {
    required FavoritesCategoryType category,
    required int itemIndex,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.favorite_border_rounded, color: AppColors.error, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Remover dos favoritos',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Deseja remover "${item.name}" dos seus favoritos?\n\nSeu histórico de reprodução não será apagado.',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _removeFavorite(item, category: category, itemIndex: itemIndex);
    }
  }

  Future<void> _removeFavorite(
    FavoriteItem item, {
    required FavoritesCategoryType category,
    int? itemIndex,
  }) async {
    final effectiveScopeKey =
        item.scopeKey.trim().isNotEmpty ? item.scopeKey : _accountKey;

    await FavoritesService.instance.removeFavorite(
      scopeKey: effectiveScopeKey,
      type: item.type,
      id: item.id,
    );
    if (!mounted) return;

    _undoHideTimer?.cancel();
    setState(() {
      _liveFavorites = _liveFavorites
          .where((f) => !(f.type == item.type && f.id == item.id))
          .toList();
      _movieFavorites = _movieFavorites
          .where((f) => !(f.type == item.type && f.id == item.id))
          .toList();
      _seriesFavorites = _seriesFavorites
          .where((f) => !(f.type == item.type && f.id == item.id))
          .toList();
      _syncFocusNodes(_liveFocusNodes, _liveFavorites.length, 'FavLive');
      _syncFocusNodes(_movieFocusNodes, _movieFavorites.length, 'FavMovie');
      _syncFocusNodes(_seriesFocusNodes, _seriesFavorites.length, 'FavSeries');
      _lastRemovedItem = item;
    });

    _undoHideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && _lastRemovedItem == item) {
        setState(() => _lastRemovedItem = null);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nodes = _focusNodesForCategory(category);
      if (nodes.isNotEmpty) {
        final targetIndex = (itemIndex ?? 0).clamp(0, nodes.length - 1);
        final targetNode = nodes[targetIndex];
        if (targetNode.canRequestFocus) {
          targetNode.requestFocus();
          return;
        }
      }
      final catNode = _sidebarCategoryNodes[category];
      if (catNode != null && catNode.canRequestFocus) {
        catNode.requestFocus();
      } else if (_backButtonFocusNode.canRequestFocus) {
        _backButtonFocusNode.requestFocus();
      }
    });

    AppToastService.instance.show(
      context,
      message: '"${item.name}" removido dos favoritos.',
      duration: const Duration(milliseconds: 3500),
      actionLabel: 'Desfazer',
      onAction: () => unawaited(_undoLastRemoval(item)),
      icon: Icons.favorite_border_rounded,
      accentColor: AppColors.focusCyan,
    );
  }

  Future<XtreamCatalogService?> _ensureCatalogService() async {
    if (_service != null) return _service;
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
      if (_accountKey.isEmpty) {
        _accountKey = PlaybackProgressService.buildAccountKey(server, user);
      }
      return _service;
    }
    return null;
  }

  Future<void> _onLiveItemTap(FavoriteItem item) async {
    AppToastService.instance.dismiss();
    final service = await _ensureCatalogService();
    if (!mounted) return;
    if (service == null) {
      AppToastService.instance.show(
        context,
        message: 'Credenciais Xtream não encontradas. Faça login novamente.',
        accentColor: AppColors.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XtreamCatalogScreen(
          type: XtreamCatalogType.live,
          catalogService: service,
          initialLiveStream: item.toLiveStream(),
        ),
      ),
    );
    if (mounted) _loadFavorites();
  }

  Future<void> _onMovieItemTap(FavoriteItem item) async {
    AppToastService.instance.dismiss();
    final service = await _ensureCatalogService();
    if (!mounted) return;
    if (service == null) {
      AppToastService.instance.show(
        context,
        message: 'Credenciais Xtream não encontradas. Faça login novamente.',
        accentColor: AppColors.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VodDetailScreen(
          movie: item.toVodStream(),
          catalogService: service,
          accountKey: _accountKey,
        ),
      ),
    );
    if (mounted) _loadFavorites();
  }

  Future<void> _onSeriesItemTap(FavoriteItem item) async {
    AppToastService.instance.dismiss();
    final service = await _ensureCatalogService();
    if (!mounted) return;
    if (service == null) {
      AppToastService.instance.show(
        context,
        message: 'Credenciais Xtream não encontradas. Faça login novamente.',
        accentColor: AppColors.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(
          series: item.toSeriesItem(),
          catalogService: service,
          accountKey: _accountKey,
        ),
      ),
    );
    if (mounted) _loadFavorites();
  }

  void _selectCategory(FavoritesCategoryType category) {
    if (_selectedCategory != category) {
      if (_gridScrollController.hasClients) {
        _gridScrollController.jumpTo(0);
      }
      setState(() => _selectedCategory = category);
    }
  }

  String get _selectedSectionTitle {
    switch (_selectedCategory) {
      case FavoritesCategoryType.live:
        return 'Canais Favoritos';
      case FavoritesCategoryType.movies:
        return 'Filmes Favoritos';
      case FavoritesCategoryType.series:
        return 'Séries Favoritas';
    }
  }

  int get _selectedSectionCount {
    switch (_selectedCategory) {
      case FavoritesCategoryType.live:
        return _liveFavorites.length;
      case FavoritesCategoryType.movies:
        return _movieFavorites.length;
      case FavoritesCategoryType.series:
        return _seriesFavorites.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalCount =
        _liveFavorites.length + _movieFavorites.length + _seriesFavorites.length;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _undoHideTimer?.cancel();
          AppToastService.instance.dismiss();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070F18),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0A141D),
          leading: IconButton(
            focusNode: _backButtonFocusNode,
            tooltip: 'Voltar',
            icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
            onPressed: () {
              AppToastService.instance.dismiss();
              Navigator.of(context).pop();
            },
          ),
          title: Row(
            children: [
              const Icon(Icons.favorite_rounded, color: AppColors.error, size: 22),
              const SizedBox(width: 10),
              const Text(
                'Meus Favoritos',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5F8FC),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
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
        ),
        body: SafeArea(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 600;
                    final isLandscape = constraints.maxWidth > constraints.maxHeight;

                    return Stack(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_isSidebarVisible)
                              _buildSidebar(isCompact: isCompact),
                            Expanded(
                              child: FocusTraversalGroup(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    _buildContentHeader(isCompact: isCompact),
                                    if (_lastRemovedItem != null)
                                      _buildUndoBanner(_lastRemovedItem!),
                                    Expanded(
                                      child: _buildSelectedCategoryContent(
                                        isLandscape: isLandscape,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
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
                                key: const Key('favorites_btn_expand_sidebar'),
                                onTap: () => setState(() => _isSidebarVisible = true),
                                borderRadius: const BorderRadius.horizontal(
                                  right: Radius.circular(8),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceSecondary,
                                    borderRadius: const BorderRadius.horizontal(
                                      right: Radius.circular(8),
                                    ),
                                    border: Border.all(color: AppColors.borderSubtle),
                                  ),
                                  child: const Icon(
                                    Icons.chevron_right_rounded,
                                    color: AppColors.primary,
                                    size: 20,
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

  Widget _buildSidebar({required bool isCompact}) {
    final width = isCompact ? 170.0 : 220.0;

    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surfaceSecondary,
        border: Border(
          right: BorderSide(
            color: AppColors.borderSubtle,
            width: 1.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _FavoritesHomeButton(
                  focusNode: _sidebarHomeFocusNode,
                  isCompact: isCompact,
                  onTap: () {
                    AppToastService.instance.dismiss();
                    Navigator.of(context).pop();
                  },
                ),
                const Spacer(),
                if (isCompact)
                  IconButton(
                    key: const Key('favorites_btn_close_sidebar'),
                    tooltip: 'Fechar barra lateral',
                    icon: const Icon(
                      Icons.chevron_left_rounded,
                      color: Color(0xFF94A3B8),
                      size: 22,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => setState(() => _isSidebarVisible = false),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 10 : 12,
              vertical: 4,
            ),
            child: Text(
              'CATEGORIAS',
              style: TextStyle(
                fontSize: isCompact ? 10 : 11,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF64748B),
                letterSpacing: 1.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(color: Color(0xFF192238), height: 1, indent: 8, endIndent: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              children: [
                _FavoritesSidebarItem(
                  key: const Key('favorites_cat_live'),
                  label: 'Canais',
                  count: _liveFavorites.length,
                  icon: Icons.live_tv_rounded,
                  focusNode: _sidebarCategoryNodes[FavoritesCategoryType.live]!,
                  isSelected: _selectedCategory == FavoritesCategoryType.live,
                  isCompact: isCompact,
                  autofocus: true,
                  onMoveRight: () => _focusGridFirstItem(_selectedCategory),
                  onTap: () => _selectCategory(FavoritesCategoryType.live),
                ),
                const SizedBox(height: 4),
                _FavoritesSidebarItem(
                  key: const Key('favorites_cat_movies'),
                  label: 'Filmes',
                  count: _movieFavorites.length,
                  icon: Icons.movie_outlined,
                  focusNode: _sidebarCategoryNodes[FavoritesCategoryType.movies]!,
                  isSelected: _selectedCategory == FavoritesCategoryType.movies,
                  isCompact: isCompact,
                  onMoveRight: () => _focusGridFirstItem(_selectedCategory),
                  onTap: () => _selectCategory(FavoritesCategoryType.movies),
                ),
                const SizedBox(height: 4),
                _FavoritesSidebarItem(
                  key: const Key('favorites_cat_series'),
                  label: 'Séries',
                  count: _seriesFavorites.length,
                  icon: Icons.video_library_outlined,
                  focusNode: _sidebarCategoryNodes[FavoritesCategoryType.series]!,
                  isSelected: _selectedCategory == FavoritesCategoryType.series,
                  isCompact: isCompact,
                  onMoveRight: () => _focusGridFirstItem(_selectedCategory),
                  onTap: () => _selectCategory(FavoritesCategoryType.series),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContentHeader({required bool isCompact}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 14 : 20,
        vertical: 10,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF0A141D),
        border: Border(
          bottom: BorderSide(color: Color(0xFF162A38), width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _selectedSectionTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF5F8FC),
              ),
            ),
          ),
          Text(
            '$_selectedSectionCount ${_selectedSectionCount == 1 ? 'item' : 'itens'}',
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF8DAEC4),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUndoBanner(FavoriteItem removedItem) {
    return Container(
      key: const Key('favorites_undo_banner'),
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF162032),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.focusCyan.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.restore_rounded, color: AppColors.focusCyan, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Removido: ${removedItem.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            focusNode: _undoBannerFocusNode,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.focusCyan,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: const Size(0, 32),
            ),
            onPressed: () => _undoLastRemoval(removedItem),
            icon: const Icon(Icons.undo_rounded, size: 16),
            label: const Text(
              'Desfazer remoção',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Fechar aviso',
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
            onPressed: () {
              _undoHideTimer?.cancel();
              setState(() => _lastRemovedItem = null);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedCategoryContent({required bool isLandscape}) {
    switch (_selectedCategory) {
      case FavoritesCategoryType.live:
        return _buildLiveGrid(isLandscape: isLandscape);
      case FavoritesCategoryType.movies:
        return _buildMoviesGrid(isLandscape: isLandscape);
      case FavoritesCategoryType.series:
        return _buildSeriesGrid(isLandscape: isLandscape);
    }
  }

  Widget _buildLiveGrid({required bool isLandscape}) {
    if (_liveFavorites.isEmpty) {
      return _buildEmptyState(
        'canais de TV ao vivo',
        Icons.live_tv_rounded,
        'Navegue pelo catálogo de TV ao vivo e marque seus canais favoritos para acessá-los aqui.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount =
            isLandscape ? (constraints.maxWidth ~/ 260).clamp(1, 4) : 1;

        if (crossAxisCount > 1) {
          return GridView.builder(
            controller: _gridScrollController,
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisExtent: 74,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _liveFavorites.length,
            itemBuilder: (context, index) {
              final item = _liveFavorites[index];
              return _FavoriteChannelTile(
                item: item,
                focusNode:
                    index < _liveFocusNodes.length ? _liveFocusNodes[index] : null,
                onMoveLeft: (index % crossAxisCount == 0)
                    ? () => _focusSidebarCategory(FavoritesCategoryType.live)
                    : null,
                onTap: () => _onLiveItemTap(item),
                onRemoveDirect: () => _removeFavorite(
                  item,
                  category: FavoritesCategoryType.live,
                  itemIndex: index,
                ),
                onRequestConfirmRemove: () => _confirmAndRemoveFavorite(
                  item,
                  category: FavoritesCategoryType.live,
                  itemIndex: index,
                ),
              );
            },
          );
        }

        return ListView.builder(
          controller: _gridScrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: _liveFavorites.length,
          itemBuilder: (context, index) {
            final item = _liveFavorites[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: _FavoriteChannelTile(
                item: item,
                focusNode:
                    index < _liveFocusNodes.length ? _liveFocusNodes[index] : null,
                onMoveLeft: () => _focusSidebarCategory(FavoritesCategoryType.live),
                onTap: () => _onLiveItemTap(item),
                onRemoveDirect: () => _removeFavorite(
                  item,
                  category: FavoritesCategoryType.live,
                  itemIndex: index,
                ),
                onRequestConfirmRemove: () => _confirmAndRemoveFavorite(
                  item,
                  category: FavoritesCategoryType.live,
                  itemIndex: index,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMoviesGrid({required bool isLandscape}) {
    if (_movieFavorites.isEmpty) {
      return _buildEmptyState(
        'filmes',
        Icons.movie_outlined,
        'Navegue pelo catálogo de Filmes e toque no ícone de coração para adicionar seus favoritos aqui.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = isLandscape ? 165.0 : 128.0;
        final crossAxisCount = (constraints.maxWidth ~/ itemWidth).clamp(2, 6);

        return GridView.builder(
          controller: _gridScrollController,
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.65,
            crossAxisSpacing: 14,
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
              focusNode:
                  index < _movieFocusNodes.length ? _movieFocusNodes[index] : null,
              onMoveLeft: (index % crossAxisCount == 0)
                  ? () => _focusSidebarCategory(FavoritesCategoryType.movies)
                  : null,
              onTap: () => _onMovieItemTap(item),
              onRemoveDirect: () => _removeFavorite(
                item,
                category: FavoritesCategoryType.movies,
                itemIndex: index,
              ),
              onRequestConfirmRemove: () => _confirmAndRemoveFavorite(
                item,
                category: FavoritesCategoryType.movies,
                itemIndex: index,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSeriesGrid({required bool isLandscape}) {
    if (_seriesFavorites.isEmpty) {
      return _buildEmptyState(
        'séries',
        Icons.video_library_outlined,
        'Navegue pelo catálogo de Séries e toque no ícone de coração para acompanhar suas séries preferidas.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = isLandscape ? 165.0 : 128.0;
        final crossAxisCount = (constraints.maxWidth ~/ itemWidth).clamp(2, 6);

        return GridView.builder(
          controller: _gridScrollController,
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.65,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: _seriesFavorites.length,
          itemBuilder: (context, index) {
            final item = _seriesFavorites[index];
            final prog = _seriesProgressMap[item.id];
            return _FavoritePosterCard(
              title: item.name,
              imageUrl: item.iconUrl,
              rating: item.rating,
              progressBadge: prog?.label,
              progressRatio: prog?.progressRatio,
              fallbackIcon: Icons.video_library_outlined,
              accentColor: const Color(0xFF1E88E5),
              focusNode:
                  index < _seriesFocusNodes.length ? _seriesFocusNodes[index] : null,
              onMoveLeft: (index % crossAxisCount == 0)
                  ? () => _focusSidebarCategory(FavoritesCategoryType.series)
                  : null,
              onTap: () => _onSeriesItemTap(item),
              onRemoveDirect: () => _removeFavorite(
                item,
                category: FavoritesCategoryType.series,
                itemIndex: index,
              ),
              onRequestConfirmRemove: () => _confirmAndRemoveFavorite(
                item,
                category: FavoritesCategoryType.series,
                itemIndex: index,
              ),
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
                textAlign: TextAlign.center,
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

class _FavoritesHomeButton extends StatefulWidget {
  final FocusNode focusNode;
  final bool isCompact;
  final VoidCallback onTap;

  const _FavoritesHomeButton({
    required this.focusNode,
    required this.isCompact,
    required this.onTap,
  });

  @override
  State<_FavoritesHomeButton> createState() => _FavoritesHomeButtonState();
}

class _FavoritesHomeButtonState extends State<_FavoritesHomeButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _focused || _hovered;
    return FocusableActionDetector(
      key: const Key('favorites_sidebar_home'),
      focusNode: widget.focusNode,
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
              vertical: 6,
              horizontal: widget.isCompact ? 6 : 8,
            ),
            decoration: BoxDecoration(
              color: highlighted
                  ? AppColors.focusCyan.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: highlighted
                  ? Border.all(color: AppColors.focusCyan, width: AppColors.focusBorderWidth)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.home_rounded,
                  size: 18,
                  color: highlighted ? AppColors.focusCyan : AppColors.textSecondary,
                ),
                if (!widget.isCompact) ...[
                  const SizedBox(width: 6),
                  Text(
                    'Início',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: highlighted ? Colors.white : const Color(0xFFE2E8F0),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoritesSidebarItem extends StatefulWidget {
  final String label;
  final int count;
  final IconData icon;
  final FocusNode focusNode;
  final bool isSelected;
  final bool isCompact;
  final bool autofocus;
  final VoidCallback? onMoveRight;
  final VoidCallback onTap;

  const _FavoritesSidebarItem({
    super.key,
    required this.label,
    required this.count,
    required this.icon,
    required this.focusNode,
    required this.isSelected,
    required this.isCompact,
    this.autofocus = false,
    this.onMoveRight,
    required this.onTap,
  });

  @override
  State<_FavoritesSidebarItem> createState() => _FavoritesSidebarItemState();
}

class _FavoritesSidebarItemState extends State<_FavoritesSidebarItem> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _focused || _hovered;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowRight &&
            widget.onMoveRight != null) {
          widget.onMoveRight!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        actions: DeviceUtils.activateAction(widget.onTap),
        shortcuts: DeviceUtils.dpadSelectShortcuts,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: EdgeInsets.symmetric(
                vertical: widget.isCompact ? 7 : 9,
                horizontal: widget.isCompact ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: highlighted
                    ? AppColors.focusCyan.withValues(alpha: 0.2)
                    : (widget.isSelected
                        ? AppColors.primary.withValues(alpha: 0.22)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: highlighted
                    ? Border.all(
                        color: AppColors.focusCyan,
                        width: AppColors.focusBorderWidth,
                      )
                    : (widget.isSelected
                        ? Border.all(
                            color: AppColors.primary.withValues(alpha: 0.55),
                            width: 1.2,
                          )
                        : Border.all(color: Colors.transparent, width: 1.2)),
                boxShadow: highlighted
                    ? [
                        BoxShadow(
                          color: AppColors.focusCyan.withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  if (widget.isSelected)
                    Container(
                      width: 3,
                      height: 16,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  Icon(
                    widget.icon,
                    size: widget.isCompact ? 16 : 18,
                    color: widget.isSelected
                        ? AppColors.primary
                        : (highlighted ? AppColors.focusCyan : AppColors.textSecondary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: widget.isCompact ? 12 : 13,
                        fontWeight: (widget.isSelected || highlighted)
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: (widget.isSelected || highlighted)
                            ? const Color(0xFFF0F4F8)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: widget.isSelected
                          ? AppColors.primary.withValues(alpha: 0.22)
                          : const Color(0xFF132230),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: widget.isSelected
                            ? AppColors.primary.withValues(alpha: 0.45)
                            : const Color(0xFF1E3547),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      '${widget.count}',
                      style: TextStyle(
                        fontSize: widget.isCompact ? 10 : 11,
                        fontWeight: FontWeight.bold,
                        color: widget.isSelected
                            ? AppColors.primary
                            : const Color(0xFF8DAEC4),
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
}

class _FavoriteChannelTile extends StatefulWidget {
  final FavoriteItem item;
  final FocusNode? focusNode;
  final VoidCallback? onMoveLeft;
  final VoidCallback onTap;
  final VoidCallback onRemoveDirect;
  final VoidCallback onRequestConfirmRemove;

  const _FavoriteChannelTile({
    required this.item,
    this.focusNode,
    this.onMoveLeft,
    required this.onTap,
    required this.onRemoveDirect,
    required this.onRequestConfirmRemove,
  });

  @override
  State<_FavoriteChannelTile> createState() => _FavoriteChannelTileState();
}

class _FavoriteChannelTileState extends State<_FavoriteChannelTile> {
  bool _isFocused = false;
  bool _isHovered = false;
  bool _longPressTriggered = false;

  KeyEventResult _handleExtraKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft && widget.onMoveLeft != null) {
      if (event is KeyDownEvent) {
        widget.onMoveLeft!();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.gameButtonY) {
      if (event is KeyDownEvent) {
        widget.onRemoveDirect();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyRepeatEvent) {
        if (!_longPressTriggered) {
          _longPressTriggered = true;
          widget.onRequestConfirmRemove();
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _longPressTriggered = false;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleExtraKeyEvent,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        actions: DeviceUtils.channelActions(
          onTap: widget.onTap,
          onToggleFavorite: widget.onRemoveDirect,
        ),
        shortcuts: DeviceUtils.dpadChannelShortcuts,
        onShowFocusHighlight: (v) {
          setState(() => _isFocused = v);
          if (v) {
            Scrollable.ensureVisible(
              context,
              alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              duration: const Duration(milliseconds: 180),
            );
          }
        },
        onShowHoverHighlight: (v) => setState(() => _isHovered = v),
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
              canRequestFocus: false,
              onTap: widget.onTap,
              onLongPress: widget.onRequestConfirmRemove,
              borderRadius: BorderRadius.circular(10),
              splashColor: AppColors.primary.withValues(alpha: 0.15),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    _buildLogo(widget.item.iconUrl),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            widget.item.name,
                            maxLines: 1,
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
                              Icon(
                                Icons.play_circle_outline_rounded,
                                size: 12,
                                color: AppColors.primary,
                              ),
                              SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'Ao vivo',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Focus(
                      canRequestFocus: false,
                      descendantsAreFocusable: false,
                      child: IconButton(
                        tooltip: 'Remover dos favoritos',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: const Icon(
                          Icons.favorite_rounded,
                          color: AppColors.error,
                          size: 19,
                        ),
                        onPressed: widget.onRemoveDirect,
                      ),
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
    const double size = 40;
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
  final String? progressBadge;
  final double? progressRatio;
  final IconData fallbackIcon;
  final Color accentColor;
  final FocusNode? focusNode;
  final VoidCallback? onMoveLeft;
  final VoidCallback onTap;
  final VoidCallback onRemoveDirect;
  final VoidCallback onRequestConfirmRemove;

  const _FavoritePosterCard({
    required this.title,
    required this.imageUrl,
    this.rating,
    this.progressBadge,
    this.progressRatio,
    required this.fallbackIcon,
    required this.accentColor,
    this.focusNode,
    this.onMoveLeft,
    required this.onTap,
    required this.onRemoveDirect,
    required this.onRequestConfirmRemove,
  });

  @override
  State<_FavoritePosterCard> createState() => _FavoritePosterCardState();
}

class _FavoritePosterCardState extends State<_FavoritePosterCard> {
  bool _isFocused = false;
  bool _isHovered = false;
  bool _longPressTriggered = false;

  KeyEventResult _handleExtraKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft && widget.onMoveLeft != null) {
      if (event is KeyDownEvent) {
        widget.onMoveLeft!();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.gameButtonY) {
      if (event is KeyDownEvent) {
        widget.onRemoveDirect();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyRepeatEvent) {
        if (!_longPressTriggered) {
          _longPressTriggered = true;
          widget.onRequestConfirmRemove();
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _longPressTriggered = false;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleExtraKeyEvent,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        actions: DeviceUtils.channelActions(
          onTap: widget.onTap,
          onToggleFavorite: widget.onRemoveDirect,
        ),
        shortcuts: DeviceUtils.dpadChannelShortcuts,
        onShowFocusHighlight: (v) {
          setState(() => _isFocused = v);
          if (v) {
            Scrollable.ensureVisible(
              context,
              alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              duration: const Duration(milliseconds: 180),
            );
          }
        },
        onShowHoverHighlight: (v) => setState(() => _isHovered = v),
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
              canRequestFocus: false,
              onTap: widget.onTap,
              onLongPress: widget.onRequestConfirmRemove,
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(11),
                            ),
                            child: widget.imageUrl != null &&
                                    widget.imageUrl!.isNotEmpty
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
                              canRequestFocus: false,
                              onTap: widget.onRemoveDirect,
                              borderRadius: BorderRadius.circular(16),
                              child: Tooltip(
                                message: 'Remover dos favoritos',
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xDD090D14),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFFEF5350),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.favorite_rounded,
                                    size: 14,
                                    color: Color(0xFFEF5350),
                                  ),
                                ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xDD090D14),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: const Color(0xFFFFA726),
                                  width: 0.8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 12,
                                    color: Color(0xFFFFA726),
                                  ),
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
                        // Indicação de progresso salvo (Séries)
                        if (widget.progressBadge != null &&
                            widget.progressBadge!.isNotEmpty)
                          Positioned(
                            left: 6,
                            bottom: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xDD070F18),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: AppColors.focusCyan.withValues(alpha: 0.75),
                                  width: 0.9,
                                ),
                              ),
                              child: Text(
                                widget.progressBadge!,
                                style: const TextStyle(
                                  color: AppColors.focusCyan,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        if (widget.progressRatio != null &&
                            widget.progressRatio! > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: widget.progressRatio,
                              minHeight: 3.5,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                AppColors.focusCyan,
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
        child: Icon(
          widget.fallbackIcon,
          size: 36,
          color: widget.accentColor.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
