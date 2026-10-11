import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/playback_progress_service.dart';
import '../services/url_sanitizer.dart';
import 'live_player_view.dart'; // Para reutilizar LiveVideoFitMode

/// Widget modular de interface de reprodução de Filmes (VOD).
/// Contém scrubber de progresso, botões -10s e +10s, alternador Original/Preencher,
/// e suporte nativo a controle remoto D-Pad e rotação horizontal.
class VodPlayerView extends StatefulWidget {
  final VideoPlayerController? controller;
  final String title;
  final String? coverUrl;
  final String badgeText;
  final String? loadingMessage;
  final LiveVideoFitMode fitMode;
  final ValueChanged<LiveVideoFitMode>? onFitModeChanged;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<int>? onSeekRelative;
  final ValueChanged<double>? onSeekFraction;
  final VoidCallback? onBack;
  final VoidCallback? onNextEpisode;
  final String? nextEpisodeTitle;
  final int? nextEpisodeCountdown;
  final VoidCallback? onCancelNextEpisode;
  final VoidCallback? onPlayNextEpisodeNow;
  final bool isLoading;
  final bool isBuffering;
  final String? errorMessage;
  final VoidCallback? onRetry;

  const VodPlayerView({
    super.key,
    required this.controller,
    required this.title,
    this.coverUrl,
    this.badgeText = 'FILME',
    this.loadingMessage,
    this.fitMode = LiveVideoFitMode.contain,
    this.onFitModeChanged,
    required this.onTogglePlayPause,
    this.onSeekRelative,
    this.onSeekFraction,
    this.onBack,
    this.onNextEpisode,
    this.nextEpisodeTitle,
    this.nextEpisodeCountdown,
    this.onCancelNextEpisode,
    this.onPlayNextEpisodeNow,
    this.isLoading = false,
    this.isBuffering = false,
    this.errorMessage,
    this.onRetry,
  });

  @override
  State<VodPlayerView> createState() => _VodPlayerViewState();
}

class _VodPlayerViewState extends State<VodPlayerView> {
  final FocusNode _focusNode = FocusNode();
  bool _showControls = true;
  Timer? _controlsTimer;

  bool _isDraggingSlider = false;
  double _dragSliderValue = 0.0;

  @override
  void initState() {
    super.initState();
    _startControlsTimer();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (widget.controller?.value.isPlaying ?? false) && !_isDraggingSlider) {
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

  void _cycleFitMode() {
    if (widget.onFitModeChanged == null) return;
    final newMode = widget.fitMode == LiveVideoFitMode.contain
        ? LiveVideoFitMode.cover
        : LiveVideoFitMode.contain;
    widget.onFitModeChanged!(newMode);
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

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onSeekRelative?.call(-10);
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onSeekRelative?.call(10);
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      widget.onTogglePlayPause();
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      widget.onBack?.call();
      return KeyEventResult.handled;
    }

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
              // 1. Superfície Física do Vídeo
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
                _buildControlsOverlay(controller, isPlaying),

              // 5. Overlay de Contagem Regressiva para Próximo Episódio (Cancelável)
              if (widget.nextEpisodeCountdown != null && widget.nextEpisodeCountdown! > 0 && widget.errorMessage == null)
                _buildNextEpisodeCountdownOverlay(),
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

        if (widget.fitMode == LiveVideoFitMode.contain) {
          return Center(
            child: AspectRatio(
              aspectRatio: videoAspect,
              child: VideoPlayer(controller),
            ),
          );
        } else {
          final containerAspect = containerWidth / containerHeight;
          double renderWidth;
          double renderHeight;

          if (containerAspect > videoAspect) {
            renderWidth = containerWidth;
            renderHeight = containerWidth / videoAspect;
          } else {
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
              _buildPosterImage(size: 80),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF0F4F8),
                    fontSize: 18,
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

  Widget _buildPosterImage({required double size}) {
    if (widget.coverUrl != null && widget.coverUrl!.trim().isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: size,
          height: size * 1.4,
          child: Image.network(
            widget.coverUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildFallbackIcon(size),
          ),
        ),
      );
    }
    return _buildFallbackIcon(size);
  }

  Widget _buildFallbackIcon(double size) {
    return Container(
      width: size,
      height: size * 1.4,
      decoration: BoxDecoration(
        color: const Color(0xFF1E283D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.movie_rounded, color: Color(0xFFE50914), size: 36),
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
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE50914)),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              widget.isLoading
                  ? (widget.loadingMessage ?? (widget.badgeText == 'SÉRIE' ? 'Carregando episódio...' : 'Carregando filme...'))
                  : 'Ajustando buffer...',
              style: const TextStyle(
                color: Color(0xFFF0F4F8),
                fontSize: 14,
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
      widget.errorMessage ?? 'Transmissão do filme indisponível.',
    );

    return Container(
      color: const Color(0xE60D121C),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 44,
                  color: Color(0xFFEF5350),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Falha na reprodução',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  sanitizedError,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB0BEC5),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.onRetry != null) ...[
                      ElevatedButton.icon(
                        onPressed: widget.onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Tentar novamente'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE50914),
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (widget.onBack != null)
                      OutlinedButton(
                        onPressed: widget.onBack,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Color(0xFF37474F)),
                        ),
                        child: const Text('Voltar'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(VideoPlayerController? c, bool isPlaying) {
    final position = c?.value.position ?? Duration.zero;
    final duration = c?.value.duration ?? Duration.zero;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.8),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.9),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Barra Superior
            _buildTopBar(),

            // Centro: Botões de Controle Rápido (-10s, Play/Pause, +10s, [Próximo Ep])
            _buildCenterControls(isPlaying),

            // Barra Inferior: Scrubber de Progresso, Tempos e Fit Mode
            _buildBottomBar(position, duration, isPlaying),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              tooltip: 'Voltar',
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
              onPressed: widget.onBack,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFE50914),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.badgeText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterControls(bool isPlaying) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Retroceder 10s',
          iconSize: 42,
          icon: const Icon(Icons.replay_10_rounded, color: Colors.white70),
          onPressed: () {
            widget.onSeekRelative?.call(-10);
            _startControlsTimer();
          },
        ),
        const SizedBox(width: 20),
        IconButton(
          tooltip: isPlaying ? 'Pausar' : 'Reproduzir',
          iconSize: 64,
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black45,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE50914), width: 1.5),
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: const Color(0xFFE50914),
            ),
          ),
          onPressed: () {
            widget.onTogglePlayPause();
            _startControlsTimer();
          },
        ),
        const SizedBox(width: 20),
        IconButton(
          tooltip: 'Avançar 10s',
          iconSize: 42,
          icon: const Icon(Icons.forward_10_rounded, color: Colors.white70),
          onPressed: () {
            widget.onSeekRelative?.call(10);
            _startControlsTimer();
          },
        ),
        if (widget.onNextEpisode != null) ...[
          const SizedBox(width: 20),
          IconButton(
            tooltip: 'Próximo episódio',
            iconSize: 42,
            icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
            onPressed: () {
              widget.onNextEpisode?.call();
              _startControlsTimer();
            },
          ),
        ],
      ],
    );
  }

  Widget _buildBottomBar(Duration position, Duration duration, bool isPlaying) {
    final totalMs = duration.inMilliseconds.toDouble();
    final currentMs = position.inMilliseconds.toDouble().clamp(0.0, totalMs > 0 ? totalMs : 0.0);

    final sliderValue = _isDraggingSlider
        ? _dragSliderValue
        : (totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0);

    final currentDisplayDuration = _isDraggingSlider && totalMs > 0
        ? Duration(milliseconds: (_dragSliderValue * totalMs).round())
        : position;

    final fitLabel = widget.fitMode == LiveVideoFitMode.contain ? 'Original' : 'Preencher';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3.5,
              activeTrackColor: const Color(0xFFE50914),
              inactiveTrackColor: Colors.white24,
              thumbColor: const Color(0xFFE50914),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayColor: const Color(0xFFE50914).withValues(alpha: 0.2),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: sliderValue,
              onChanged: totalMs > 0
                  ? (val) {
                      setState(() {
                        _isDraggingSlider = true;
                        _dragSliderValue = val;
                      });
                      _startControlsTimer();
                    }
                  : null,
              onChangeEnd: totalMs > 0
                  ? (val) {
                      setState(() => _isDraggingSlider = false);
                      widget.onSeekFraction?.call(val);
                      _startControlsTimer();
                    }
                  : null,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${PlaybackProgressService.formatDuration(currentDisplayDuration)} / ${PlaybackProgressService.formatDuration(duration)}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (widget.onFitModeChanged != null)
                TextButton.icon(
                  onPressed: _cycleFitMode,
                  icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white70, size: 18),
                  label: Text(
                    fitLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNextEpisodeCountdownOverlay() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Center(
        child: SingleChildScrollView(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(24),
            constraints: const BoxConstraints(maxWidth: 420),
            decoration: BoxDecoration(
              color: const Color(0xFF141C2A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE50914), width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.skip_next_rounded, color: Color(0xFFE50914), size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Próximo Episódio',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (widget.nextEpisodeTitle != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.nextEpisodeTitle!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFB0BEC5),
                      fontSize: 14,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Iniciando em ${widget.nextEpisodeCountdown}s...',
                  style: const TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    if (widget.onCancelNextEpisode != null)
                      OutlinedButton(
                        onPressed: widget.onCancelNextEpisode,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Color(0xFF37474F)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        child: const Text('Cancelar'),
                      ),
                    if (widget.onPlayNextEpisodeNow != null)
                      ElevatedButton.icon(
                        onPressed: widget.onPlayNextEpisodeNow,
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Assistir agora'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE50914),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
