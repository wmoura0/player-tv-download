import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/channel.dart';
import '../models/favorite_item.dart';
import '../models/playlist.dart';
import '../services/epg_service.dart';
import '../services/favorites_service.dart';
import '../services/hidden_categories_service.dart';
import '../services/playback_metrics.dart';
import '../services/player_stability_manager.dart';
import '../services/playlist_storage.dart';
import '../services/url_sanitizer.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';
import '../widgets/epg_guide_view.dart';
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

class _PlaylistChannelsScreenState extends State<PlaylistChannelsScreen>
    with WidgetsBindingObserver {
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
  late final PlayerStabilityManager _stabilityManager;
  bool _isConnecting = false;
  bool _isBackDebounced = false;
  bool _isExitingFullscreen = false;
  Timer? _backDebounceTimer;
  final GlobalKey<LivePlayerViewState> _livePlayerKey = GlobalKey<LivePlayerViewState>();
  final ScrollController _channelScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentPlaylist = widget.playlist;
    _stabilityManager = PlayerStabilityManager(
      onReconnectRequest: (count) async {
        if (mounted && _activeChannel != null) {
          await _retryPlayback();
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
    FavoritesService.instance.loadFavorites(_currentPlaylist.id);
    HiddenCategoriesService.instance.addListener(_onHiddenCategoriesChanged);
    EpgService.instance.addListener(_onEpgUpdated);
    DeviceUtils.isPipMode.addListener(_onPipModeChanged);
    if (_currentPlaylist.epgUrl != null && _currentPlaylist.epgUrl!.isNotEmpty) {
      EpgService.instance.loadXmltv(
        playlistId: _currentPlaylist.id,
        url: _currentPlaylist.epgUrl!,
      );
    }
    _loadChannels();
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
    if (DeviceUtils.isPipMode.value) {
      return;
    }

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _stabilityManager.pauseMonitoring();
      _playerController?.pause();
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: false);
    } else if (state == AppLifecycleState.resumed) {
      if (mounted &&
          _activeChannel != null &&
          _playerController != null &&
          _playerController!.value.isInitialized) {
        DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
        _stabilityManager.startStallMonitoring(_playerController!);
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
    EpgService.instance.removeListener(_onEpgUpdated);
    FavoritesService.instance.removeListener(_onFavoritesChanged);
    HiddenCategoriesService.instance.removeListener(_onHiddenCategoriesChanged);
    _searchController.dispose();
    _channelScrollController.dispose();
    _playerController?.removeListener(_onPlayerStateChanged);
    _playerController?.pause();
    _playerController?.dispose();
    _backDebounceTimer?.cancel();
    DeviceUtils.restoreOrientation();
    super.dispose();
  }

  void _onEpgUpdated() {
    if (mounted) setState(() {});
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  void _onHiddenCategoriesChanged() {
    if (!mounted) return;
    final hidden = HiddenCategoriesService.instance.getHiddenCategories(_currentPlaylist.id);
    if (_selectedCategory != 'TODOS' &&
        _selectedCategory != 'Todos' &&
        _selectedCategory != '❤️ Favoritos' &&
        hidden.contains(_selectedCategory.trim())) {
      _selectedCategory = 'TODOS';
    }
    setState(() {});
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
    final hidden = HiddenCategoriesService.instance.getHiddenCategories(_currentPlaylist.id);
    for (final channel in _allChannels) {
      if (channel.groupTitle.isNotEmpty && !hidden.contains(channel.groupTitle.trim())) {
        groups.add(channel.groupTitle);
      }
    }
    list.addAll(groups);
    return list;
  }

  List<M3uChannel> get _filteredChannels {
    final hidden = HiddenCategoriesService.instance.getHiddenCategories(_currentPlaylist.id);
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
        final matchesSearch = _searchQuery.isEmpty ||
            c.name.toLowerCase().contains(_searchQuery.toLowerCase());
        return matchesCategory && matchesSearch;
      }

      // Se a categoria do canal estiver oculta, não exibe na lista geral nem na busca
      if (c.groupTitle.isNotEmpty && hidden.contains(c.groupTitle.trim())) {
        return false;
      }

      if (_selectedCategory == 'TODOS' || _selectedCategory == 'Todos') {
        matchesCategory = true;
      } else {
        matchesCategory = c.groupTitle == _selectedCategory;
      }
      final matchesSearch = _searchQuery.isEmpty ||
          c.name.toLowerCase().contains(_searchQuery.toLowerCase());
      return matchesCategory && matchesSearch;
    }).toList();
  }

  Future<void> _toggleChannelFavorite(M3uChannel channel) async {
    final item = FavoriteItem.fromM3uChannel(
      playlistId: _currentPlaylist.id,
      channel: channel,
    );
    final wasFav = FavoritesService.instance.isFavorite(
      scopeKey: _currentPlaylist.id,
      type: FavoriteType.m3uChannel,
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
      _isPlayerBuffering = val.isBuffering;
      // Não dispara setState() na lista inteira de canais durante micro-buffering,
      // pois o LivePlayerView gerencia o indicador de buffer localmente.
    }
  }

  Future<void> _playM3uChannel(M3uChannel channel, {bool isRetry = false, bool keepFullscreen = false}) async {
    // Requisito: Clicar novamente no canal já selecionado abre tela cheia sem reiniciar a transmissão!
    if (!isRetry &&
        _activeChannel?.streamUrl == channel.streamUrl &&
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
      title: channel.name,
    );
    _stabilityManager.metrics?.markRequestStart();
    DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);

    if (!isRetry) {
      _stabilityManager.resetRetries();
    }

    if (_isConnecting) return;
    _isConnecting = true;

    setState(() {
      _activeChannel = channel;
      if (!keepFullscreen && !_isFullscreen) {
        _isFullscreen = false;
      }
      _isPlayerLoading = true;
      _isPlayerBuffering = false;
      _playerError = null;
    });

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

    final sanitizedDisplay = UrlSanitizer.sanitize(channel.streamUrl);
    debugPrint('[PLAYER] Conectando ao canal M3U: $sanitizedDisplay');

    final isMpegTs = PlayerStabilityManager.isMpegTsUrl(channel.streamUrl);
    _stabilityManager.isMpegTsStream = isMpegTs;

    final uri = Uri.tryParse(channel.streamUrl);
    if (uri == null) {
      _isConnecting = false;
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
        if (!isRetry) {
          _stabilityManager.resetRetries();
        }
        _stabilityManager.startStallMonitoring(controller, isMpegTs: isMpegTs);

        await controller.play();
        DeviceUtils.setPipState(enabled: true);
        DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
        setState(() {
          _isPlayerLoading = false;
          _playerError = null;
        });
      }
    } catch (e) {
      if (mounted && _playerController == controller) {
        DeviceUtils.setPipState(enabled: false);
        _stabilityManager.clearOpenWatchdog();
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

  void _playPreviousChannel() {
    if (_activeChannel == null) return;
    final channels = _filteredChannels;
    if (channels.isEmpty) return;
    final currentIndex = channels.indexWhere((c) => c.streamUrl == _activeChannel!.streamUrl);
    if (currentIndex > 0) {
      _playM3uChannel(channels[currentIndex - 1], keepFullscreen: _isFullscreen);
    } else if (channels.isNotEmpty) {
      _playM3uChannel(channels.last, keepFullscreen: _isFullscreen);
    }
  }

  void _playNextChannel() {
    if (_activeChannel == null) return;
    final channels = _filteredChannels;
    if (channels.isEmpty) return;
    final currentIndex = channels.indexWhere((c) => c.streamUrl == _activeChannel!.streamUrl);
    if (currentIndex >= 0 && currentIndex < channels.length - 1) {
      _playM3uChannel(channels[currentIndex + 1], keepFullscreen: _isFullscreen);
    } else if (channels.isNotEmpty) {
      _playM3uChannel(channels.first, keepFullscreen: _isFullscreen);
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
      if (!mounted || _activeChannel == null) return;
      final items = _filteredChannels;
      final idx = items.indexWhere((it) => it.streamUrl == _activeChannel!.streamUrl);
      if (idx >= 0 && _channelScrollController.hasClients) {
        final targetOffset = (idx * 84.0 - 80.0).clamp(
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
        _activeChannel = null;
        _isFullscreen = false;
        _playerError = null;
        _isPlayerLoading = false;
        _isPlayerBuffering = false;
      });
      DeviceUtils.restoreOrientation();
    }
  }

  Future<void> _retryPlayback() async {
    if (_activeChannel == null || !mounted) return;
    if (_isConnecting) {
      debugPrint('[PLAYER] Reconexão já em andamento, ignorando chamada redundante.');
      return;
    }
    _stabilityManager.clearOpenWatchdog();

    final c = _playerController;
    if (!_stabilityManager.isMpegTsStream &&
        c != null &&
        c.value.isInitialized &&
        !c.value.hasError &&
        _stabilityManager.retryCount == 0) {
      debugPrint('[PLAYER] Tentando recuperação suave (soft recovery)...');
      final ok = await _stabilityManager.attemptSoftRecovery(c);
      if (ok && mounted) {
        setState(() {
          _playerError = null;
          _isPlayerLoading = false;
          _isPlayerBuffering = false;
        });
        _stabilityManager.startStallMonitoring(c, isMpegTs: _stabilityManager.isMpegTsStream);
        return;
      }
    }

    // Reinicialização controlada (hard recovery) sem resetar contagem de retries prematuramente
    await _playM3uChannel(_activeChannel!, isRetry: true, keepFullscreen: _isFullscreen);
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
    // 0. Modo Picture-in-Picture: exibe unicamente a tela cheia do player para preencher a janela flutuante
    if (DeviceUtils.isPipMode.value && _activeChannel != null) {
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
        if (_isFullscreen && _activeChannel != null) {
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

        if (_activeChannel != null) {
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
        body: _isFullscreen && _activeChannel != null
            ? Container(
                color: Colors.black,
                child: _buildLivePlayerWidget(isFullscreen: true),
              )
            : SafeArea(
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
      ),
    );
  }

  Widget _buildLivePlayerWidget({required bool isFullscreen}) {
    final nowNext = EpgService.instance.getNowAndNext(
      channelId: _activeChannel!.tvgId,
      channelName: _activeChannel!.name,
    );

    return LivePlayerView(
      key: _livePlayerKey,
      controller: _playerController,
      channelName: _activeChannel!.name,
      channelLogo: _activeChannel!.logoUrl,
      groupTitle: _activeChannel!.groupTitle,
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
      currentProgram: nowNext.now?.title,
      nextProgram: nowNext.next?.title,
      onOpenGuide: () {
        final schedule = EpgService.instance.getSchedule(
          channelId: _activeChannel!.tvgId,
          channelName: _activeChannel!.name,
        );
        EpgGuideDialog.show(
          context,
          channelName: _activeChannel!.name,
          channelLogo: _activeChannel!.logoUrl,
          schedule: schedule,
        );
      },
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

  Widget _buildMiniPlayerWidget() => _buildLivePlayerWidget(isFullscreen: false);

  Widget _buildFilterBar() {
    return Container(
      color: const Color(0xFF0F1523),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // Campo de busca com suporte TV-safe (navegação D-pad não abre teclado automaticamente)
          _TvSafeM3uSearchBar(
            controller: _searchController,
            query: _searchQuery,
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
            controller: _channelScrollController,
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
              final isCurrent = _activeChannel?.streamUrl == channel.streamUrl;
              return _ChannelTile(
                channel: channel,
                isPlaying: isCurrent,
                autofocus: isCurrent,
                isFavorite: isFav,
                onToggleFavorite: () => _toggleChannelFavorite(channel),
                onTap: () => _onChannelTap(channel),
              );
            },
          );
        }

        // Layout em lista para celulares em modo retrato
        return ListView.builder(
          controller: _channelScrollController,
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
            final isCurrent = _activeChannel?.streamUrl == channel.streamUrl;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: _ChannelTile(
                channel: channel,
                isPlaying: isCurrent,
                autofocus: isCurrent,
                isFavorite: isFav,
                onToggleFavorite: () => _toggleChannelFavorite(channel),
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
                ? AppColors.primary
                : (_isFocused ? AppColors.surfaceSecondary.withValues(alpha: 0.8) : AppColors.surfaceSecondary),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (widget.isSelected ? AppColors.primary : AppColors.borderSubtle),
              width: _isFocused ? AppColors.focusBorderWidth : AppColors.normalBorderWidth,
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
  final bool autofocus;

  const _ChannelTile({
    required this.channel,
    this.isPlaying = false,
    this.isFavorite = false,
    this.onToggleFavorite,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
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
    final isFocusHighlight = _isFocused || _isHovered;
    final isHighlighted = isFocusHighlight || widget.isPlaying;

    return Focus(
      autofocus: widget.autofocus,
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
          scale: DeviceUtils.isTv ? 1.0 : (isHighlighted ? 1.02 : 1.0),
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: widget.isPlaying
                ? AppColors.surfaceSecondary.withValues(alpha: 0.9)
                : AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isFocusHighlight
                  ? AppColors.focusCyan
                  : (widget.isPlaying ? AppColors.primary : AppColors.borderSubtle),
              width: isFocusHighlight
                  ? AppColors.focusBorderWidth
                  : (widget.isPlaying ? 2.0 : AppColors.normalBorderWidth),
            ),
            boxShadow: isFocusHighlight
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: widget.isPlaying ? 0.35 : 0.2),
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
                            else ...[
                              Builder(
                                builder: (context) {
                                  final nowProg = EpgService.instance.getNowAndNext(
                                    channelId: widget.channel.tvgId,
                                    channelName: widget.channel.name,
                                  ).now;

                                  if (nowProg != null && nowProg.title.isNotEmpty) {
                                    return Row(
                                      children: [
                                        const Icon(Icons.schedule_rounded, size: 11, color: Color(0xFF00E5FF)),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            nowProg.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF00E5FF),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  }

                                  return Text(
                                    widget.channel.groupTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF8A99AD),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
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

/// Barra de busca com suporte TV-safe para playlist M3U:
/// - Foco no controle remoto apenas destaca a caixa de busca.
/// - Teclado virtual abre apenas com OK.
/// - Voltar encerra edição sem fechar a tela.
class _TvSafeM3uSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;

  const _TvSafeM3uSearchBar({
    required this.controller,
    required this.query,
    required this.onChanged,
  });

  @override
  State<_TvSafeM3uSearchBar> createState() => _TvSafeM3uSearchBarState();
}

class _TvSafeM3uSearchBarState extends State<_TvSafeM3uSearchBar> {
  final FocusNode _containerFocusNode = FocusNode();
  final FocusNode _textFocusNode = FocusNode();
  bool _isFocused = false;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _textFocusNode.skipTraversal = true;
  }

  @override
  void dispose() {
    _containerFocusNode.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    _textFocusNode.skipTraversal = false;
    setState(() => _isEditing = true);
    _textFocusNode.requestFocus();
  }

  void _stopEditing() {
    _textFocusNode.skipTraversal = true;
    setState(() => _isEditing = false);
    _containerFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _containerFocusNode,
      canRequestFocus: !_isEditing,
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) {
        if (!_isEditing &&
            (event.logicalKey == LogicalKeyboardKey.select ||
             event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.gameButtonA ||
             event.logicalKey == LogicalKeyboardKey.space)) {
          if (event is KeyDownEvent) {
            _startEditing();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: _startEditing,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _isFocused || _isEditing ? const Color(0xFF141D2D) : const Color(0xFF0F1523),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _isFocused || _isEditing ? const Color(0xFF00E5FF) : const Color(0xFF1F2B40),
              width: 2.0,
            ),
            boxShadow: _isFocused || _isEditing
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 20,
                color: _isFocused || _isEditing ? const Color(0xFF00E5FF) : const Color(0xFF8A99AD),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _textFocusNode,
                  readOnly: false,
                  onTap: _startEditing,
                  style: const TextStyle(color: Color(0xFFF0F4F8), fontSize: 14),
                  decoration: InputDecoration(
                    hintText: _isFocused && !_isEditing ? 'Pressione OK para buscar' : 'Buscar canal...',
                    hintStyle: TextStyle(
                      color: _isFocused && !_isEditing ? const Color(0xFF00E5FF) : const Color(0xFF5A6E85),
                      fontSize: 14,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: InputBorder.none,
                  ),
                  onChanged: widget.onChanged,
                  onSubmitted: (_) => _stopEditing(),
                ),
              ),
              if (widget.controller.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    widget.controller.clear();
                    widget.onChanged('');
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.clear_rounded, size: 18, color: Color(0xFF8A99AD)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
