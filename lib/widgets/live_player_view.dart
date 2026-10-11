import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/url_sanitizer.dart';

/// Modos de enquadramento do vídeo na tela (Original ou Preencher).
enum LiveVideoFitMode { contain, cover }

/// Widget modular de reprodução de TV ao vivo com suporte unificado
/// para modo mini player e modo tela cheia compartilhando a mesma instância
/// de [VideoPlayerController].
class LivePlayerView extends StatefulWidget {
  final VideoPlayerController? controller;
  final String channelName;
  final String? channelLogo;
  final String? groupTitle;
  final bool isFullscreen;
  final bool isLoading;
  final bool isBuffering;
  final String? errorMessage;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onToggleFullscreen;
  final VoidCallback? onClose;
  final VoidCallback? onRetry;
  final LiveVideoFitMode fitMode;
  final ValueChanged<LiveVideoFitMode>? onFitModeChanged;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final String? currentProgram;
  final String? nextProgram;

  const LivePlayerView({
    super.key,
    required this.controller,
    required this.channelName,
    this.channelLogo,
    this.groupTitle,
    required this.isFullscreen,
    required this.isLoading,
    this.isBuffering = false,
    this.errorMessage,
    required this.onTogglePlayPause,
    required this.onToggleFullscreen,
    this.onClose,
    this.onRetry,
    this.fitMode = LiveVideoFitMode.contain,
    this.onFitModeChanged,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.currentProgram,
    this.nextProgram,
  });

  @override
  State<LivePlayerView> createState() => _LivePlayerViewState();
}

class _LivePlayerViewState extends State<LivePlayerView> {
  bool _showControls = true;
  Timer? _controlsTimer;
  final FocusNode _focusNode = FocusNode();
  late LiveVideoFitMode _currentFitMode;

  @override
  void initState() {
    super.initState();
    _currentFitMode = widget.fitMode;
    _startControlsTimer();
  }

  @override
  void didUpdateWidget(covariant LivePlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitMode != oldWidget.fitMode) {
      _currentFitMode = widget.fitMode;
    }
    if (widget.isFullscreen != oldWidget.isFullscreen) {
      if (widget.isFullscreen) {
        _showControls = true;
        _startControlsTimer();
        _focusNode.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    if (!widget.isFullscreen) {
      // No modo mini player, mantemos os controles acessíveis com auto-ocultação mais longa
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && (widget.controller?.value.isPlaying ?? false)) {
          setState(() => _showControls = false);
        }
      });
      return;
    }

    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (widget.controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startControlsTimer();
    } else {
      _controlsTimer?.cancel();
    }
  }

  String get _fitModeLabel {
    switch (_currentFitMode) {
      case LiveVideoFitMode.contain:
        return 'Original';
      case LiveVideoFitMode.cover:
        return 'Preencher';
    }
  }

  void _cycleFitMode() {
    final newMode = _currentFitMode == LiveVideoFitMode.contain
        ? LiveVideoFitMode.cover
        : LiveVideoFitMode.contain;
    setState(() {
      _currentFitMode = newMode;
    });
    widget.onFitModeChanged?.call(newMode);
    _startControlsTimer();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      widget.onTogglePlayPause();
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
        event.logicalKey == LogicalKeyboardKey.mediaPlay ||
        event.logicalKey == LogicalKeyboardKey.mediaPause) {
      widget.onTogglePlayPause();
      return KeyEventResult.handled;
    }

    if (widget.isFullscreen &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack)) {
      widget.onToggleFullscreen();
      return KeyEventResult.handled;
    }

    // Qualquer seta acorda os controles
    setState(() => _showControls = true);
    _startControlsTimer();
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final isInitialized = controller != null && controller.value.isInitialized;
    final isPlaying = controller?.value.isPlaying ?? false;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        onTap: _toggleControls,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Superfície de vídeo
              if (isInitialized && widget.errorMessage == null)
                _buildVideoSurface(controller)
              else
                _buildPlaceholderBackground(),

              // 2. Indicador de Carregamento ou Buffering
              if (widget.isLoading || widget.isBuffering)
                _buildLoadingOverlay(),

              // 3. Indicador de Erro
              if (widget.errorMessage != null && !widget.isLoading)
                _buildErrorOverlay(),

              // 4. Controles Sobrepostos (OSD)
              if (_showControls && widget.errorMessage == null)
                _buildControlsOverlay(isPlaying),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoSurface(VideoPlayerController controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerWidth = constraints.maxWidth;
        final containerHeight = constraints.maxHeight;

        if (containerWidth <= 0 || containerHeight <= 0) {
          return const SizedBox.shrink();
        }

        final rawVideoWidth = controller.value.size.width;
        final rawVideoHeight = controller.value.size.height;
        final double videoAspect = (rawVideoWidth > 0 && rawVideoHeight > 0)
            ? rawVideoWidth / rawVideoHeight
            : (controller.value.aspectRatio > 0 ? controller.value.aspectRatio : 16 / 9);

        if (_currentFitMode == LiveVideoFitMode.contain) {
          // Modo Original: Enquadramento perfeito preservando a proporção original do vídeo,
          // sem distorção, centralizado na área disponível com letterbox/pillarbox.
          return Center(
            child: AspectRatio(
              aspectRatio: videoAspect,
              child: VideoPlayer(controller),
            ),
          );
        } else {
          // Modo Preencher: Ocupa 100% da área disponível sem distorcer o vídeo,
          // calculando as dimensões exatas de cobertura e recortando o excedente via ClipRect.
          final containerAspect = containerWidth / containerHeight;
          double renderWidth;
          double renderHeight;

          if (containerAspect > videoAspect) {
            // Container proporcionalmente mais largo: largura preenche, corta topo e base
            renderWidth = containerWidth;
            renderHeight = containerWidth / videoAspect;
          } else {
            // Container proporcionalmente mais alto: altura preenche, corta laterais
            renderHeight = containerHeight;
            renderWidth = containerHeight * videoAspect;
          }

          return ClipRect(
            child: Center(
              child: OverflowBox(
                minWidth: renderWidth,
                maxWidth: renderWidth,
                minHeight: renderHeight,
                maxHeight: renderHeight,
                child: SizedBox(
                  width: renderWidth,
                  height: renderHeight,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          );
        }
      },
    );
  }

  Widget _buildPlaceholderBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.9,
          colors: [Color(0xFF141C2A), Color(0xFF090D14)],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildLogo(size: widget.isFullscreen ? 72 : 48),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  widget.channelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xFFF0F4F8),
                    fontSize: widget.isFullscreen ? 18 : 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black45,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.isLoading ? 'Conectando ao canal...' : 'Carregando transmissão...',
              style: const TextStyle(
                color: Color(0xFFF0F4F8),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                shadows: [
                  Shadow(blurRadius: 4, color: Colors.black, offset: Offset(0, 1)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    final sanitizedError = UrlSanitizer.sanitizeErrorMessage(
      widget.errorMessage ?? 'Transmissão indisponível.',
    );

    return Container(
      color: const Color(0xE60D121C),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: widget.isFullscreen ? 40 : 28,
                  color: const Color(0xFFEF5350),
                ),
                const SizedBox(height: 6),
                Text(
                  'Falha na transmissão',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: widget.isFullscreen ? 16 : 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sanitizedError,
                  textAlign: TextAlign.center,
                  maxLines: widget.isFullscreen ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB0BEC5),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.onRetry != null)
                      ElevatedButton.icon(
                        onPressed: widget.onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 14),
                        label: const Text('Reconectar', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        ),
                      ),
                    if (widget.onClose != null) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: widget.onClose,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          side: const BorderSide(color: Color(0xFF37474F)),
                        ),
                        child: const Text('Fechar', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(bool isPlaying) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showCenterPlay = widget.isFullscreen && constraints.maxHeight >= 220;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.75),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.85),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
          child: SafeArea(
            top: widget.isFullscreen,
            bottom: widget.isFullscreen,
            left: widget.isFullscreen,
            right: widget.isFullscreen,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Barra Superior
                _buildTopBar(),

                // Centro: Botão Play/Pause grande (apenas em tela cheia com altura suficiente)
                if (showCenterPlay)
                  _buildCenterPlayButton(isPlaying)
                else
                  const SizedBox.shrink(),

                // Barra Inferior
                _buildBottomBar(isPlaying),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    final isCompact = !widget.isFullscreen;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 12,
        vertical: isCompact ? 4 : 8,
      ),
      child: Row(
        children: [
          if (widget.isFullscreen)
            IconButton(
              tooltip: 'Voltar à lista de canais',
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
              onPressed: () {
                widget.onToggleFullscreen();
              },
            ),
          _buildLogo(size: isCompact ? 24 : 32),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.channelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCompact ? 13 : 15,
                    fontWeight: FontWeight.bold,
                    shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
                  ),
                ),
                if (widget.currentProgram != null && widget.currentProgram!.isNotEmpty)
                  Text(
                    'Agora: ${widget.currentProgram!}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFFF1F5F9),
                      fontSize: isCompact ? 10 : 12,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else if (widget.groupTitle != null && widget.groupTitle!.isNotEmpty)
                  Text(
                    widget.groupTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFF00E5FF),
                      fontSize: isCompact ? 10 : 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                if (widget.isFullscreen && widget.nextProgram != null && widget.nextProgram!.isNotEmpty)
                  Text(
                    'A seguir: ${widget.nextProgram!}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // Badge "AO VIVO"
          Container(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 6 : 8, vertical: isCompact ? 2 : 3),
            decoration: BoxDecoration(
              color: const Color(0xFFD32F2F),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fiber_manual_record, color: Colors.white, size: isCompact ? 8 : 10),
                const SizedBox(width: 4),
                Text(
                  'AO VIVO',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCompact ? 9 : 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onToggleFavorite != null) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: widget.isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
              icon: Icon(
                widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                color: widget.isFavorite ? const Color(0xFFEF5350) : Colors.white70,
                size: isCompact ? 20 : 22,
              ),
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(minWidth: isCompact ? 30 : 36, minHeight: isCompact ? 30 : 36),
              onPressed: widget.onToggleFavorite,
            ),
          ],
          if (!widget.isFullscreen && widget.onClose != null) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Fechar player',
              icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: widget.onClose,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCenterPlayButton(bool isPlaying) {
    return Center(
      child: IconButton(
        iconSize: widget.isFullscreen ? 64 : 44,
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
          ),
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: const Color(0xFF00E5FF),
          ),
        ),
        onPressed: () {
          widget.onTogglePlayPause();
          _startControlsTimer();
        },
      ),
    );
  }

  Widget _buildBottomBar(bool isPlaying) {
    final isCompact = !widget.isFullscreen;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 12,
        vertical: isCompact ? 4 : 8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Controle Play/Pause pequeno
          IconButton(
            tooltip: isPlaying ? 'Pausar' : 'Reproduzir',
            icon: Icon(
              isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
              color: const Color(0xFF00E5FF),
              size: isCompact ? 24 : 26,
            ),
            padding: isCompact ? EdgeInsets.zero : const EdgeInsets.all(8),
            constraints: isCompact
                ? const BoxConstraints(minWidth: 36, minHeight: 36)
                : const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: () {
              widget.onTogglePlayPause();
              _startControlsTimer();
            },
          ),

          Row(
            children: [
              // Alternador de Enquadramento (Fit Mode) tanto em tela cheia quanto em mini player
              if (widget.onFitModeChanged != null)
                widget.isFullscreen
                    ? TextButton.icon(
                        onPressed: _cycleFitMode,
                        icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white70, size: 18),
                        label: Text(
                          _fitModeLabel,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Proporção: $_fitModeLabel',
                        icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white70, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        onPressed: _cycleFitMode,
                      ),

              // Botão Alternar Tela Cheia / Mini Player
              IconButton(
                tooltip: widget.isFullscreen ? 'Sair da tela cheia' : 'Tela cheia',
                icon: Icon(
                  widget.isFullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: Colors.white,
                  size: isCompact ? 22 : 24,
                ),
                padding: isCompact ? EdgeInsets.zero : const EdgeInsets.all(8),
                constraints: isCompact
                    ? const BoxConstraints(minWidth: 36, minHeight: 36)
                    : const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: widget.onToggleFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLogo({required double size}) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1E283D),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.live_tv_rounded, color: const Color(0xFF00E5FF), size: size * 0.55),
    );

    if (widget.channelLogo == null || widget.channelLogo!.trim().isEmpty) {
      return fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          widget.channelLogo!,
          cacheWidth: 120,
          cacheHeight: 120,
          fit: BoxFit.contain,
          errorBuilder: (ctx, err, stack) => fallback,
        ),
      ),
    );
  }
}
