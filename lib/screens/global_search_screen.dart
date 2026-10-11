import 'dart:async';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/playlist.dart';
import '../models/xtream_catalog.dart';
import '../services/settings_service.dart';
import '../services/xtream_catalog_service.dart';
import 'series_detail_screen.dart';
import 'vod_detail_screen.dart';
import 'xtream_catalog_screen.dart';

enum SearchFilterTab { all, live, movies, series }

/// Tela de Pesquisa Global Unificada do Player TV.
/// Busca simultaneamente em canais de TV ao vivo, filmes e séries
/// com debounce, seções agrupadas, capas, metadados e navegação nativa.
class GlobalSearchScreen extends StatefulWidget {
  final XtreamCatalogService? catalogService;
  final String accountKey;
  final M3uPlaylist? activeM3uPlaylist;

  const GlobalSearchScreen({
    super.key,
    this.catalogService,
    required this.accountKey,
    this.activeM3uPlaylist,
  });

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final SettingsService _settings = SettingsService.instance;

  Timer? _debounceTimer;
  String _currentQuery = '';
  SearchFilterTab _selectedTab = SearchFilterTab.all;

  bool _isLoadingAll = false;
  String? _loadingError;

  List<XtreamLiveStream> _allLiveStreams = [];
  List<XtreamVodStream> _allVodStreams = [];
  List<XtreamSeriesItem> _allSeries = [];
  List<M3uChannel> _m3uChannels = [];

  List<XtreamLiveStream> _filteredLive = [];
  List<XtreamVodStream> _filteredVod = [];
  List<XtreamSeriesItem> _filteredSeries = [];
  List<M3uChannel> _filteredM3u = [];

  @override
  void initState() {
    super.initState();
    _loadCatalogsForSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadCatalogsForSearch() async {
    if (widget.catalogService == null && widget.activeM3uPlaylist == null) {
      return;
    }

    setState(() {
      _isLoadingAll = true;
      _loadingError = null;
    });

    try {
      if (widget.catalogService != null) {
        // Carrega streams de TV, VOD e Séries (instantâneo do cache de memória/disco)
        final results = await Future.wait([
          widget.catalogService!.fetchLiveStreams(categoryId: 'all'),
          widget.catalogService!.fetchVodStreams(categoryId: 'all'),
          widget.catalogService!.fetchSeries(categoryId: 'all'),
        ]);

        if (mounted) {
          setState(() {
            _allLiveStreams = results[0] as List<XtreamLiveStream>;
            _allVodStreams = results[1] as List<XtreamVodStream>;
            _allSeries = results[2] as List<XtreamSeriesItem>;
            _isLoadingAll = false;
            if (_currentQuery.isNotEmpty) {
              _applyFilter();
            }
          });
        }
      } else if (widget.activeM3uPlaylist != null) {
        setState(() {
          _m3uChannels = widget.activeM3uPlaylist!.channels ?? [];
          _isLoadingAll = false;
          if (_currentQuery.isNotEmpty) {
            _applyFilter();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAll = false;
          _loadingError = 'Não foi possível carregar o catálogo para busca: $e';
        });
      }
    }
  }

  void _onSearchChanged(String text) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _currentQuery = text.trim();
        _applyFilter();
      });
    });
  }

  void _applyFilter() {
    if (_currentQuery.isEmpty) {
      _filteredLive = [];
      _filteredVod = [];
      _filteredSeries = [];
      _filteredM3u = [];
      return;
    }

    final query = _currentQuery.toLowerCase();

    _filteredLive = _allLiveStreams
        .where((s) => s.name.toLowerCase().contains(query))
        .toList();

    _filteredVod = _allVodStreams
        .where((m) => m.name.toLowerCase().contains(query))
        .toList();

    _filteredSeries = _allSeries
        .where((s) =>
            s.name.toLowerCase().contains(query) ||
            (s.genre != null && s.genre!.toLowerCase().contains(query)))
        .toList();

    _filteredM3u = _m3uChannels
        .where((c) =>
            c.name.toLowerCase().contains(query) ||
            c.groupTitle.toLowerCase().contains(query))
        .toList();
  }

  int get _totalResultsCount =>
      _filteredLive.length +
      _filteredVod.length +
      _filteredSeries.length +
      _filteredM3u.length;

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _currentQuery = '';
      _applyFilter();
    });
  }

  void _openLiveStream(XtreamLiveStream stream) {
    if (widget.catalogService == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XtreamCatalogScreen(
          type: XtreamCatalogType.live,
          catalogService: widget.catalogService,
          initialLiveStream: stream,
        ),
      ),
    );
  }

  void _openVodDetail(XtreamVodStream movie) {
    if (widget.catalogService == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VodDetailScreen(
          movie: movie,
          catalogService: widget.catalogService!,
          accountKey: widget.accountKey,
        ),
      ),
    );
  }

  void _openSeriesDetail(XtreamSeriesItem series) {
    if (widget.catalogService == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(
          series: series,
          catalogService: widget.catalogService!,
          accountKey: widget.accountKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = _settings.accentColor.color;

    return Scaffold(
      backgroundColor: const Color(0xFF070A12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1424),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFFF5F8FC)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: _buildSearchBar(accent),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_currentQuery.isNotEmpty) _buildFilterTabs(accent),
            Expanded(child: _buildBody(accent)),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(Color accent) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF141C33),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF263352), width: 1),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: _onSearchChanged,
        style: const TextStyle(color: Color(0xFFF5F8FC), fontSize: 15),
        decoration: InputDecoration(
          hintText: 'Buscar canais, filmes ou séries...',
          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
          prefixIcon: Icon(Icons.search_rounded, color: accent, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 18),
                  onPressed: _clearSearch,
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  Widget _buildFilterTabs(Color accent) {
    final liveTotal = _filteredLive.length + _filteredM3u.length;
    final vodTotal = _filteredVod.length;
    final seriesTotal = _filteredSeries.length;
    final total = _totalResultsCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F1D),
        border: Border(bottom: BorderSide(color: Color(0xFF1D263B), width: 1)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildTabChip('Todos ($total)', SearchFilterTab.all, accent),
            const SizedBox(width: 8),
            _buildTabChip('TV ao vivo ($liveTotal)', SearchFilterTab.live, accent),
            const SizedBox(width: 8),
            _buildTabChip('Filmes ($vodTotal)', SearchFilterTab.movies, accent),
            const SizedBox(width: 8),
            _buildTabChip('Séries ($seriesTotal)', SearchFilterTab.series, accent),
          ],
        ),
      ),
    );
  }

  Widget _buildTabChip(String label, SearchFilterTab tab, Color accent) {
    final isSelected = _selectedTab == tab;
    return InkWell(
      onTap: () => setState(() => _selectedTab = tab),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? accent.withValues(alpha: 0.18) : const Color(0xFF141C33),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? accent : const Color(0xFF263352),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? accent : const Color(0xFF94A3B8),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(Color accent) {
    if (_isLoadingAll) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: accent),
            const SizedBox(height: 16),
            const Text(
              'Preparando catálogo para pesquisa...',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_loadingError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Color(0xFFEF5350), size: 48),
              const SizedBox(height: 12),
              Text(
                _loadingError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFF5F8FC), fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black),
                onPressed: _loadCatalogsForSearch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Tentar Novamente'),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentQuery.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.search_rounded, color: accent, size: 48),
              ),
              const SizedBox(height: 16),
              const Text(
                'Pesquisa Global no Player TV',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5F8FC),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Digite o que deseja assistir para pesquisar simultaneamente em canais de TV ao vivo, filmes e séries.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }

    if (_totalResultsCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_rounded, color: Color(0xFF64748B), size: 56),
              const SizedBox(height: 16),
              Text(
                'Nenhum resultado para "$_currentQuery"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5F8FC),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Verifique a ortografia ou tente palavras-chave diferentes.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      children: [
        if ((_selectedTab == SearchFilterTab.all || _selectedTab == SearchFilterTab.live) &&
            (_filteredLive.isNotEmpty || _filteredM3u.isNotEmpty)) ...[
          _buildSectionHeader(
            'TV ao vivo (${_filteredLive.length + _filteredM3u.length})',
            Icons.live_tv_rounded,
            accent,
          ),
          const SizedBox(height: 12),
          ..._filteredLive.map((ch) => _buildLiveItemTile(ch, accent)),
          ..._filteredM3u.map((ch) => _buildM3uItemTile(ch, accent)),
          const SizedBox(height: 20),
        ],

        if ((_selectedTab == SearchFilterTab.all || _selectedTab == SearchFilterTab.movies) &&
            _filteredVod.isNotEmpty) ...[
          _buildSectionHeader(
            'Filmes (${_filteredVod.length})',
            Icons.movie_outlined,
            const Color(0xFF29B6F6),
          ),
          const SizedBox(height: 12),
          ..._filteredVod.map((m) => _buildVodItemTile(m, const Color(0xFF29B6F6))),
          const SizedBox(height: 20),
        ],

        if ((_selectedTab == SearchFilterTab.all || _selectedTab == SearchFilterTab.series) &&
            _filteredSeries.isNotEmpty) ...[
          _buildSectionHeader(
            'Séries (${_filteredSeries.length})',
            Icons.video_library_outlined,
            const Color(0xFF1E88E5),
          ),
          const SizedBox(height: 12),
          ..._filteredSeries.map((s) => _buildSeriesItemTile(s, const Color(0xFF1E88E5))),
          const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildLiveItemTile(XtreamLiveStream stream, Color accent) {
    return _buildResultTile(
      title: stream.name,
      subtitle: 'Canal de TV ao vivo',
      badgeText: 'CANAL',
      badgeColor: accent,
      imageUrl: stream.streamIcon,
      fallbackIcon: Icons.live_tv_rounded,
      onTap: () => _openLiveStream(stream),
    );
  }

  Widget _buildM3uItemTile(M3uChannel channel, Color accent) {
    return _buildResultTile(
      title: channel.name,
      subtitle: channel.groupTitle.isNotEmpty ? channel.groupTitle : 'Lista M3U',
      badgeText: 'CANAL',
      badgeColor: accent,
      imageUrl: channel.logoUrl,
      fallbackIcon: Icons.live_tv_rounded,
      onTap: () {},
    );
  }

  Widget _buildVodItemTile(XtreamVodStream movie, Color color) {
    final rating = movie.rating != null && movie.rating!.isNotEmpty ? '★ ${movie.rating}' : null;
    return _buildResultTile(
      title: movie.name,
      subtitle: rating ?? 'Filme (VOD)',
      badgeText: 'FILME',
      badgeColor: color,
      imageUrl: movie.streamIcon,
      fallbackIcon: Icons.movie_outlined,
      onTap: () => _openVodDetail(movie),
    );
  }

  Widget _buildSeriesItemTile(XtreamSeriesItem series, Color color) {
    final info = series.genre != null && series.genre!.isNotEmpty ? series.genre! : 'Série';
    return _buildResultTile(
      title: series.name,
      subtitle: info,
      badgeText: 'SÉRIE',
      badgeColor: color,
      imageUrl: series.cover,
      fallbackIcon: Icons.video_library_outlined,
      onTap: () => _openSeriesDetail(series),
    );
  }

  Widget _buildResultTile({
    required String title,
    required String subtitle,
    required String badgeText,
    required Color badgeColor,
    required String? imageUrl,
    required IconData fallbackIcon,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0E1424),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF1D263B), width: 1),
          ),
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Capa / Thumbnail com fallback gracioso
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 54,
                  height: 70,
                  color: const Color(0xFF141C33),
                  child: imageUrl != null && imageUrl.isNotEmpty
                      ? Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Icon(fallbackIcon, color: const Color(0xFF64748B), size: 24),
                        )
                      : Icon(fallbackIcon, color: const Color(0xFF64748B), size: 24),
                ),
              ),
              const SizedBox(width: 14),
              // Informações do item
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: badgeColor, width: 0.8),
                          ),
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: badgeColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F8FC),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B), size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
