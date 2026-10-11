import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/channel.dart';
import '../models/favorite_item.dart';
import '../models/playlist.dart';
import '../services/favorites_service.dart';
import '../services/playlist_storage.dart';
import '../services/url_sanitizer.dart';
import '../utils/device_utils.dart';
import '../widgets/live_player_view.dart';

/// Tela para exibir os canais de uma lista M3U agrupados por categoria.
class PlaylistChannelsScreen extends StatefulWidget {
  final M3uPlaylist playlist;
  final PlaylistStorageService storageService;

  const PlaylistChannelsScreen({
    super.key,
    required this.playlist,
    required this.storageService,
  });

  @override
  State<PlaylistChannelsScreen> createState() => _PlaylistChannelsScreenState();
}

class _PlaylistChannelsScreenState extends State<PlaylistChannelsScreen> {
  late M3uPlaylist _currentPlaylist;
  List<M3uChannel> _allChannels = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;

  String _selectedCategory = 'TODOS';
  String _searchQuery = '';
  final _searchController = TextEditingController();

  // Estado de reprodução
  M3uChannel? _activeChannel;
  VideoPlayerController? _playerController;
  bool _isFullscreen = false;
  bool _isPlayerLoading = false;
  bool _isPlayerBuffering = false;
  String? _playerError;
  LiveVideoFitMode _fitMode = LiveVideoFitMode.contain;

  @override
  void initState() {
    super.initState();
    _currentPlaylist = widget.playlist;
    FavoritesService.instance.addListener(_onFavoritesChanged);
    FavoritesService.instance.loadFavorites(_currentPlaylist.id);
    _loadChannels();
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
    if (mounted) setState(() {});
  }

  Future<void> _loadChannels() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_currentPlaylist.channels != null && _currentPlaylist.channels!.isNotEmpty) {
        if (mounted) {
          setState(() {
            _allChannels = _currentPlaylist.channels!;
            _isLoading = false;
          });
        }
        return;
      }

      final channels = await widget.storageService.loadChannels(_currentPlaylist.id);
      if (mounted) {
        setState(() {
          _allChannels = channels;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = UrlSanitizer.sanitizeErrorMessage(
            'Erro ao carregar canais do armazenamento: ${e.toString()}',
          );
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refreshPlaylist() async {
    setState(() => _isRefreshing = true);

    try {
      final updated = await widget.storageService.refreshPlaylist(_currentPlaylist);
      final channels = await widget.storageService.loadChannels(updated.id);

      if (mounted) {
        setState(() {
          _currentPlaylist = updated;
          _allChannels = channels;
          _isRefreshing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lista "${_currentPlaylist.name}" atualizada com sucesso!'),
            backgroundColor: const Color(0xFF1E88E5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRefreshing = false);
        final safeMsg = UrlSanitizer.sanitizeErrorMessage(e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao atualizar: $safeMsg'),
            backgroundColor: const Color(0xFFC62828),
          ),
        );
      }
    }
  }

  List<String> get _categories {
    final list = <String>['TODOS', '❤️ Favoritos'];
    final groups = <String>{};
    for (final channel in _allChannels) {
      if (channel.groupTitle.isNotEmpty) {
        groups.add(channel.groupTitle);
      }
    }
    list.addAll(groups);
    return list;
  }

  List<M3uChannel> get _filteredChannels {
    return _allChannels.where((c) {
      final bool matchesCategory;
      if (_selectedCategory == '❤️ Favoritos') {
        final channelId = FavoriteItem.buildM3uChannelId(
          name: c.name,
          streamUrl: c.streamUrl,
          tvgId: c.tvgId,
        );
        matchesCategory = FavoritesService.instance.isFavorite(
          scopeKey: _currentPlaylist.id,
          type: FavoriteType.m3uChannel,
          id: channelId,
        );
      } else {
        matchesCategory = _selectedCategory == 'TODOS' ||
            _selectedCategory == 'Todos' ||
            c.groupTitle == _selectedCategory;
      }
      final matchesSearch = _searchQuery.isEmpty ||
          c.name.toLowerCase().contains(_searchQuery.toLowerCase());
      return matchesCategory && matchesSearch;
    }).toList();
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

  Future<void> _playM3uChannel(M3uChannel channel) async {
    // Requisito: Clicar novamente no canal já selecionado abre tela cheia sem reiniciar a transmissão!
    if (_activeChannel?.streamUrl == channel.streamUrl) {
      _toggleFullscreen();
      return;
    }

    setState(() {
      _activeChannel = channel;
      _isPlayerLoading = true;
      _isPlayerBuffering = false;
      _playerError = null;
    });

    final oldController = _playerController;
    _playerController = null;
    oldController?.removeListener(_onPlayerStateChanged);
    await oldController?.pause();
    await oldController?.dispose();

    if (!mounted) return;

    final sanitizedDisplay = UrlSanitizer.sanitize(channel.streamUrl);
    debugPrint('[PLAYER] Conectando ao canal M3U: $sanitizedDisplay');

    final uri = Uri.tryParse(channel.streamUrl);
    if (uri == null) {
      setState(() {
        _isPlayerLoading = false;
        _playerError = 'Endereço de canal inválido.';
      });
      return;
    }

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
        });
      }
    } catch (e) {
      if (mounted && _playerController == controller) {
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
        _activeChannel = null;
        _isFullscreen = false;
        _playerError = null;
        _isPlayerLoading = false;
        _isPlayerBuffering = false;
      });
      DeviceUtils.restoreOrientation();
    }
  }

  void _retryPlayback() {
    if (_activeChannel == null) return;
    _playM3uChannel(_activeChannel!);
  }

  void _onChannelTap(M3uChannel channel) {
    if (_activeChannel?.streamUrl == channel.streamUrl) {
      _toggleFullscreen();
      return;
    }
    _playM3uChannel(channel);
  }

  @override
  Widget build(BuildContext context) {
    if (_isFullscreen && _activeChannel != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toggleFullscreen();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LivePlayerView(
            controller: _playerController,
            channelName: _activeChannel!.name,
            channelLogo: _activeChannel!.logoUrl,
            groupTitle: _activeChannel!.groupTitle,
            isFullscreen: true,
            isLoading: _isPlayerLoading,
            isBuffering: _isPlayerBuffering,
            errorMessage: _playerError,
            fitMode: _fitMode,
            onFitModeChanged: (mode) => setState(() => _fitMode = mode),
            onTogglePlayPause: _togglePlayPause,
            onToggleFullscreen: _toggleFullscreen,
            onRetry: _retryPlayback,
            isFavorite: _activeChannel != null &&
                FavoritesService.instance.isFavorite(
                  scopeKey: _currentPlaylist.id,
                  type: FavoriteType.m3uChannel,
                  id: FavoriteItem.buildM3uChannelId(
                    name: _activeChannel!.name,
                    streamUrl: _activeChannel!.streamUrl,
                    tvgId: _activeChannel!.tvgId,
                  ),
                ),
            onToggleFavorite: _activeChannel == null
                ? null
                : () async {
                    await FavoritesService.instance.toggleFavorite(
                      FavoriteItem.fromM3uChannel(
                        playlistId: _currentPlaylist.id,
                        channel: _activeChannel!,
                      ),
                    );
                  },
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF090D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1523),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _currentPlaylist.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF0F4F8),
              ),
            ),
            Text(
              '${_allChannels.length} canais encontrados',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF8A99AD),
              ),
            ),
          ],
        ),
        actions: [
          if (_isRefreshing)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00E5FF)),
              tooltip: 'Atualizar lista',
              onPressed: _refreshPlaylist,
            ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                ),
              )
            : _errorMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Color(0xFFEF5350)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final isLandscape = constraints.maxWidth > constraints.maxHeight;
                      final showMini = _activeChannel != null;

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
                                  _buildFilterBar(),
                                  Expanded(
                                    child: _filteredChannels.isEmpty
                                        ? _buildEmptyState()
                                        : _buildChannelsList(),
                                  ),
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
                          _buildFilterBar(),
                          Expanded(
                            child: _filteredChannels.isEmpty
                                ? _buildEmptyState()
                                : _buildChannelsList(),
                          ),
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
      channelName: _activeChannel!.name,
      channelLogo: _activeChannel!.logoUrl,
      groupTitle: _activeChannel!.groupTitle,
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
      isFavorite: _activeChannel != null &&
          FavoritesService.instance.isFavorite(
            scopeKey: _currentPlaylist.id,
            type: FavoriteType.m3uChannel,
            id: FavoriteItem.buildM3uChannelId(
              name: _activeChannel!.name,
              streamUrl: _activeChannel!.streamUrl,
              tvgId: _activeChannel!.tvgId,
            ),
          ),
      onToggleFavorite: _activeChannel == null
          ? null
          : () async {
              await FavoritesService.instance.toggleFavorite(
                FavoriteItem.fromM3uChannel(
                  playlistId: _currentPlaylist.id,
                  channel: _activeChannel!,
                ),
              );
            },
    );
  }

  Widget _buildFilterBar() {
    return Container(
      color: const Color(0xFF0F1523),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // Campo de busca
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Color(0xFFF0F4F8), fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Buscar canal...',
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

          // Categorias em Chips horizontais com foco para controle remoto
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = _categories[index];
                final isSelected = category == _selectedCategory;

                return _CategoryFilterChip(
                  label: category,
                  isSelected: isSelected,
                  onTap: () => setState(() => _selectedCategory = category),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 48, color: Color(0xFF5A6E85)),
            const SizedBox(height: 12),
            const Text(
              'Nenhum canal encontrado nesta categoria.',
              style: TextStyle(color: Color(0xFF8A99AD), fontSize: 16),
            ),
            if (_searchQuery.isNotEmpty || _selectedCategory != 'Todos') ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _searchQuery = '';
                    _selectedCategory = 'Todos';
                  });
                },
                child: const Text('Limpar filtros', style: TextStyle(color: Color(0xFF00E5FF))),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChannelsList() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;

        if (isLandscape) {
          // Layout em grade para TVs e telas largas em paisagem
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 320,
              mainAxisExtent: 80,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _filteredChannels.length,
            itemBuilder: (context, index) {
              final channel = _filteredChannels[index];
              return _ChannelTile(
                channel: channel,
                isPlaying: _activeChannel?.streamUrl == channel.streamUrl,
                onTap: () => _onChannelTap(channel),
              );
            },
          );
        }

        // Layout em lista para celulares em modo retrato
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: _filteredChannels.length,
          itemBuilder: (context, index) {
            final channel = _filteredChannels[index];
            final channelId = FavoriteItem.buildM3uChannelId(
              name: channel.name,
              streamUrl: channel.streamUrl,
              tvgId: channel.tvgId,
            );
            final isFav = FavoritesService.instance.isFavorite(
              scopeKey: _currentPlaylist.id,
              type: FavoriteType.m3uChannel,
              id: channelId,
            );
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: _ChannelTile(
                channel: channel,
                isPlaying: _activeChannel?.streamUrl == channel.streamUrl,
                isFavorite: isFav,
                onToggleFavorite: () async {
                  await FavoritesService.instance.toggleFavorite(
                    FavoriteItem.fromM3uChannel(
                      playlistId: _currentPlaylist.id,
                      channel: channel,
                    ),
                  );
                },
                onTap: () => _onChannelTap(channel),
              ),
            );
          },
        );
      },
    );
  }
}

class _CategoryFilterChip extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _CategoryFilterChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_CategoryFilterChip> createState() => _CategoryFilterChipState();
}

class _CategoryFilterChipState extends State<_CategoryFilterChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? const Color(0xFF1E88E5)
                : (_isFocused ? const Color(0xFF1A2638) : const Color(0xFF141D2D)),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _isFocused
                  ? const Color(0xFF00E5FF)
                  : (widget.isSelected ? const Color(0xFF1E88E5) : const Color(0xFF1E283D)),
              width: _isFocused ? 1.5 : 1.0,
            ),
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
                color: widget.isSelected || _isFocused
                    ? Colors.white
                    : const Color(0xFF8A99AD),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatefulWidget {
  final M3uChannel channel;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    this.isPlaying = false,
    this.isFavorite = false,
    this.onToggleFavorite,
    required this.onTap,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered || widget.isPlaying;

    return FocusableActionDetector(
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
              color: isHighlighted ? const Color(0xFF00E5FF) : const Color(0xFF1A2436),
              width: widget.isPlaying ? 2.0 : 1.5,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: widget.isPlaying ? 0.35 : 0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(10),
              splashColor: const Color(0xFF00E5FF).withValues(alpha: 0.15),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    // Logo do Canal ou Ícone de TV
                    _buildLogo(widget.channel.logoUrl),
                    const SizedBox(width: 12),

                    // Nome e Categoria
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFF0F4F8),
                            ),
                          ),
                          const SizedBox(height: 3),
                          if (widget.isPlaying)
                            const Row(
                              children: [
                                Icon(Icons.graphic_eq_rounded, size: 12, color: Color(0xFF00E5FF)),
                                SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'EM REPRODUÇÃO • Toque p/ tela cheia',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF00E5FF),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else
                            Text(
                              widget.channel.groupTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF8A99AD),
                              ),
                            ),
                        ],
                      ),
                    ),

                    if (widget.onToggleFavorite != null)
                      IconButton(
                        tooltip: widget.isFavorite ? 'Remover dos favoritos' : 'Favoritar canal',
                        icon: Icon(
                          widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                          size: 20,
                          color: widget.isFavorite ? const Color(0xFFEF5350) : const Color(0xFF8A99AD),
                        ),
                        onPressed: widget.onToggleFavorite,
                      ),

                    Icon(
                      widget.isPlaying
                          ? Icons.play_circle_filled_rounded
                          : Icons.play_circle_outline_rounded,
                      size: 22,
                      color: isHighlighted ? const Color(0xFF00E5FF) : const Color(0xFF3E506B),
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
    const double size = 44;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1A2436),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.live_tv_rounded,
        color: Color(0xFF00E5FF),
        size: 22,
      ),
    );

    if (logoUrl == null || logoUrl.trim().isEmpty) {
      return fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          logoUrl,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => fallback,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              color: const Color(0xFF1A2436),
              child: const Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
