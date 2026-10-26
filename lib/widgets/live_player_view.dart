import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/url_sanitizer.dart';
import '../utils/device_utils.dart';

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
  final VoidCallback? onOpenGuide;
  final VoidCallback? onPreviousChannel;
  final VoidCallback? onNextChannel;

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
    this.onOpenGuide,
    this.onPreviousChannel,
    this.onNextChannel,
  });

  @override
  State<LivePlayerView> createState() => LivePlayerViewState();
}

class LivePlayerViewState extends State<LivePlayerView> {
  bool _showControls = true;
  bool get isControlsVisible => _showControls;

  void hideControls() {
    if (_showControls) {
      _controlsTimer?.cancel();
      setState(() => _showControls = false);
      if (mounted) {
        _focusNode.requestFocus();
      }
    }
  }

  void revealControls() => _revealControls();

  Timer? _controlsTimer;
  final FocusNode _focusNode = FocusNode();
  final FocusNode _playPauseFocusNode = FocusNode();
  final FocusNode _prevChannelFocusNode = FocusNode();
  final FocusNode _nextChannelFocusNode = FocusNode();
  final FocusNode _guideFocusNode = FocusNode();
  final FocusNode _favFocusNode = FocusNode();
  final FocusNode _backFocusNode = FocusNode();
  final FocusNode _fitFocusNode = FocusNode();
  final FocusNode _fsFocusNode = FocusNode();

  bool _showBufferingIndicator = false;
  Timer? _bufferingDebounceTimer;

  void _startBufferingDebounce() {
    _bufferingDebounceTimer?.cancel();
    // Grace period de 700ms para micro-hesitações transitórias de buffer na Fire TV.
    // Se a bufferização for legítima e persistir além de 700ms, exibe o indicador.
    _bufferingDebounceTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted && widget.isBuffering) {
        setState(() => _showBufferingIndicator = true);
      }
    });
  }

  void _cancelBufferingDebounce() {
    _bufferingDebounceTimer?.cancel();
    _bufferingDebounceTimer = null;
    if (_showBufferingIndicator) {
      setState(() => _showBufferingIndicator = false);
    }
  }

  late LiveVideoFitMode _currentFitMode;

  @override
  void initState() {
    super.initState();
    _currentFitMode = widget.fitMode;
    _startControlsTimer();
    if (widget.isBuffering) {
      _startBufferingDebounce();
    }
    _attachControllerListener(widget.controller);
    if (widget.controller?.value.isPlaying ?? false) {
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
    }
  }

  void _attachControllerListener(VideoPlayerController? controller) {
    controller?.addListener(_onControllerStateChanged);
  }

  void _detachControllerListener(VideoPlayerController? controller) {
    controller?.removeListener(_onControllerStateChanged);
  }

  void _onControllerStateChanged() {
    if (!mounted) return;
    final val = widget.controller?.value;
    if (val == null) return;

    if (val.isPlaying) {
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
    }

    final isBuff = val.isBuffering || widget.isBuffering;
    if (isBuff) {
      if (!_showBufferingIndicator && _bufferingDebounceTimer == null) {
        _startBufferingDebounce();
      }
    } else {
      _cancelBufferingDebounce();
    }
  }

  @override
  void didUpdateWidget(covariant LivePlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _detachControllerListener(oldWidget.controller);
      _attachControllerListener(widget.controller);
      if (widget.controller?.value.isPlaying ?? false) {
        DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
      }
    } else if (widget.controller?.value.isPlaying ?? false) {
      DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
    }

    if (widget.isBuffering != oldWidget.isBuffering) {
      if (widget.isBuffering) {
        _startBufferingDebounce();
      } else {
        _cancelBufferingDebounce();
      }
    }

    if (widget.fitMode != oldWidget.fitMode) {
      _currentFitMode = widget.fitMode;
    }
    if (widget.isFullscreen != oldWidget.isFullscreen) {
      if (widget.isFullscreen) {
        _revealControls();
      }
    }
  }

  @override
  void dispose() {
    _detachControllerListener(widget.controller);
    _bufferingDebounceTimer?.cancel();
    _controlsTimer?.cancel();
    _focusNode.dispose();
    _playPauseFocusNode.dispose();
    _prevChannelFocusNode.dispose();
    _nextChannelFocusNode.dispose();
    _guideFocusNode.dispose();
    _favFocusNode.dispose();
    _backFocusNode.dispose();
    _fitFocusNode.dispose();
    _fsFocusNode.dispose();
    super.dispose();
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    // Em TV com controles abertos, concede 4 segundos de inatividade para auto-ocultação
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (widget.controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _revealControls() {
    setState(() => _showControls = true);
    _startControlsTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showControls) {
        _playPauseFocusNode.requestFocus();
      }
    });
  }

  void _toggleControls() {
    if (_showControls) {
      _controlsTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _revealControls();
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

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  DateTime _lastBackPressTime = DateTime.fromMillisecondsSinceEpoch(0);

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // 1. Se os controles estiverem ocultos:
    if (!_showControls) {
      // Tecla Voltar (Escape / goBack)
      if (event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.goBack) {
        final now = clock();
        if (now.difference(_lastBackPressTime) < const Duration(milliseconds: 300)) {
          return KeyEventResult.handled;
        }
        _lastBackPressTime = now;

        if (widget.isFullscreen) {
          widget.onToggleFullscreen();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      // Teclas físicas de reprodução Play/Pause
      if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
          event.logicalKey == LogicalKeyboardKey.mediaPlay ||
          event.logicalKey == LogicalKeyboardKey.mediaPause) {
        widget.onTogglePlayPause();
        _revealControls();
        return KeyEventResult.handled;
      }

      // Tecla Menu no controle Fire TV: favorita/desfavorita diretamente
      if (event.logicalKey == LogicalKeyboardKey.contextMenu && widget.onToggleFavorite != null) {
        widget.onToggleFavorite!();
        _revealControls();
        return KeyEventResult.handled;
      }

      // Tecla Guia
      if (event.logicalKey == LogicalKeyboardKey.guide && widget.onOpenGuide != null) {
        widget.onOpenGuide!();
        return KeyEventResult.handled;
      }

      // Troca física de canal (Channel Up/Down)
      if (widget.isFullscreen) {
        if (event.logicalKey == LogicalKeyboardKey.channelUp ||
            event.logicalKey == LogicalKeyboardKey.pageUp ||
            event.logicalKey == LogicalKeyboardKey.mediaTrackNext) {
          widget.onNextChannel?.call();
          _revealControls();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.channelDown ||
            event.logicalKey == LogicalKeyboardKey.pageDown ||
            event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious) {
          widget.onPreviousChannel?.call();
          _revealControls();
          return KeyEventResult.handled;
        }
      }

      // Qualquer outra tecla (Enter, Select, Espaço, Setas D-Pad): APENAS revela os controles e foca o botão central
      // Requisito estrito: OK com controles ocultos NÃO pausa nem executa ações inesperadas!
      _revealControls();
      return KeyEventResult.handled;
    }

    // 2. Se os controles estiverem VISÍVEIS:
    // Tecla Voltar (Escape / goBack)
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      final now = clock();
      if (now.difference(_lastBackPressTime) < const Duration(milliseconds: 300)) {
        return KeyEventResult.handled;
      }
      _lastBackPressTime = now;

      // Primeiro toque em Voltar: apenas oculta os controles de reprodução mantendo o vídeo em tela cheia
      _controlsTimer?.cancel();
      setState(() => _showControls = false);
      _focusNode.requestFocus();
      return KeyEventResult.handled;
    }

    // Atalhos diretos de controle remoto com controles abertos
    if (event.logicalKey == LogicalKeyboardKey.contextMenu && widget.onToggleFavorite != null) {
      widget.onToggleFavorite!();
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.guide && widget.onOpenGuide != null) {
      widget.onOpenGuide!();
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
        event.logicalKey == LogicalKeyboardKey.mediaPlay ||
        event.logicalKey == LogicalKeyboardKey.mediaPause) {
      widget.onTogglePlayPause();
      _startControlsTimer();
      return KeyEventResult.handled;
    }

    if (widget.isFullscreen) {
      if (event.logicalKey == LogicalKeyboardKey.channelUp ||
          event.logicalKey == LogicalKeyboardKey.pageUp ||
          event.logicalKey == LogicalKeyboardKey.mediaTrackNext) {
        widget.onNextChannel?.call();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.channelDown ||
          event.logicalKey == LogicalKeyboardKey.pageDown ||
          event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious) {
        widget.onPreviousChannel?.call();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
    }

    // Navegação Direcional D-Pad 2D Completa sem armadilhas de foco (no focus traps)
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _startControlsTimer();
      // Linha Central
      if (_playPauseFocusNode.hasFocus) {
        if (widget.isFullscreen && widget.onPreviousChannel != null && _prevChannelFocusNode.canRequestFocus) {
          _prevChannelFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
      } else if (_nextChannelFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Linha Inferior
      else if (_fsFocusNode.hasFocus && _fitFocusNode.canRequestFocus) {
        _fitFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Linha Superior
      else if (_favFocusNode.hasFocus) {
        if (widget.onOpenGuide != null && _guideFocusNode.canRequestFocus) {
          _guideFocusNode.requestFocus();
        } else if (widget.isFullscreen && _backFocusNode.canRequestFocus) {
          _backFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      } else if (_guideFocusNode.hasFocus && widget.isFullscreen && _backFocusNode.canRequestFocus) {
        _backFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _startControlsTimer();
      // Linha Central
      if (_playPauseFocusNode.hasFocus) {
        if (widget.isFullscreen && widget.onNextChannel != null && _nextChannelFocusNode.canRequestFocus) {
          _nextChannelFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
      } else if (_prevChannelFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Linha Inferior
      else if (_fitFocusNode.hasFocus && _fsFocusNode.canRequestFocus) {
        _fsFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Linha Superior
      else if (_backFocusNode.hasFocus) {
        if (widget.onOpenGuide != null && _guideFocusNode.canRequestFocus) {
          _guideFocusNode.requestFocus();
        } else if (widget.onToggleFavorite != null && _favFocusNode.canRequestFocus) {
          _favFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      } else if (_guideFocusNode.hasFocus && widget.onToggleFavorite != null && _favFocusNode.canRequestFocus) {
        _favFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _startControlsTimer();
      // Da Linha Inferior -> sobe para o Play/Pause Central
      if (_fitFocusNode.hasFocus || _fsFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Da Linha Central -> sobe para a Barra Superior
      if (_playPauseFocusNode.hasFocus || _prevChannelFocusNode.hasFocus || _nextChannelFocusNode.hasFocus) {
        if (_prevChannelFocusNode.hasFocus && widget.isFullscreen && _backFocusNode.canRequestFocus) {
          _backFocusNode.requestFocus();
        } else if (_nextChannelFocusNode.hasFocus && widget.onToggleFavorite != null && _favFocusNode.canRequestFocus) {
          _favFocusNode.requestFocus();
        } else if (widget.isFullscreen && _backFocusNode.canRequestFocus) {
          _backFocusNode.requestFocus();
        } else if (widget.onOpenGuide != null && _guideFocusNode.canRequestFocus) {
          _guideFocusNode.requestFocus();
        } else if (widget.onToggleFavorite != null && _favFocusNode.canRequestFocus) {
          _favFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _startControlsTimer();
      // Da Barra Superior -> desce para a Linha Central
      if (_backFocusNode.hasFocus || _guideFocusNode.hasFocus || _favFocusNode.hasFocus) {
        if (_backFocusNode.hasFocus && widget.isFullscreen && widget.onPreviousChannel != null && _prevChannelFocusNode.canRequestFocus) {
          _prevChannelFocusNode.requestFocus();
        } else if (_favFocusNode.hasFocus && widget.isFullscreen && widget.onNextChannel != null && _nextChannelFocusNode.canRequestFocus) {
          _nextChannelFocusNode.requestFocus();
        } else {
          _playPauseFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      // Da Linha Central -> desce para a Barra Inferior
      if (_playPauseFocusNode.hasFocus || _prevChannelFocusNode.hasFocus || _nextChannelFocusNode.hasFocus) {
        if (_prevChannelFocusNode.hasFocus && _fitFocusNode.canRequestFocus) {
          _fitFocusNode.requestFocus();
        } else if (_nextChannelFocusNode.hasFocus && _fsFocusNode.canRequestFocus) {
          _fsFocusNode.requestFocus();
        } else if (_fsFocusNode.canRequestFocus) {
          _fsFocusNode.requestFocus();
        } else if (_fitFocusNode.canRequestFocus) {
          _fitFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
    }

    // Execução direta de ação ao pressionar OK/Select/Enter nos botões com foco
    final isSelectKey = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;

    if (isSelectKey) {
      if (_prevChannelFocusNode.hasFocus && widget.onPreviousChannel != null) {
        widget.onPreviousChannel!();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_nextChannelFocusNode.hasFocus && widget.onNextChannel != null) {
        widget.onNextChannel!();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_playPauseFocusNode.hasFocus) {
        widget.onTogglePlayPause();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_backFocusNode.hasFocus) {
        widget.onToggleFullscreen();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_favFocusNode.hasFocus && widget.onToggleFavorite != null) {
        widget.onToggleFavorite!();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_guideFocusNode.hasFocus && widget.onOpenGuide != null) {
        widget.onOpenGuide!();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_fitFocusNode.hasFocus) {
        _cycleFitMode();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
      if (_fsFocusNode.hasFocus) {
        widget.onToggleFullscreen();
        _startControlsTimer();
        return KeyEventResult.handled;
      }
    }

    // Reinicia o timer de auto-hide em qualquer tecla de navegação D-pad
    _startControlsTimer();

    // Permite que teclas de navegação passem
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DeviceUtils.isPipMode,
      builder: (context, inPip, _) {
        final controller = widget.controller;
        final isInitialized = controller != null && controller.value.isInitialized;
        final isPlaying = controller?.value.isPlaying ?? false;

        // Quando estiver no modo Picture-in-Picture (PiP), exibe unicamente a superfície
        // de vídeo limpa, preenchendo a janela flutuante sem botões, overlays ou foco
        if (inPip) {
          return Container(
            color: Colors.black,
            child: isInitialized
                ? _buildVideoSurface(controller)
                : _buildPlaceholderBackground(),
          );
        }

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
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

                  // 2. Indicador de Carregamento Inicial ou Buffering Persistente
                  if (widget.isLoading || _showBufferingIndicator)
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
      },
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

                // Centro: Botões de Play/Pause e troca de canal (tela cheia)
                if (showCenterPlay)
                  _buildCenterControls(isPlaying)
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
            _PlayerTvIconButton(
              buttonKey: const Key('btn_fullscreen_back'),
              tooltip: 'Voltar à lista de canais',
              focusNode: _backFocusNode,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
              onPressed: widget.onToggleFullscreen,
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
          if (widget.onOpenGuide != null) ...[
            const SizedBox(width: 4),
            _PlayerTvIconButton(
              buttonKey: const Key('btn_open_guide'),
              tooltip: 'Guia de Programação (EPG)',
              focusNode: _guideFocusNode,
              constraints: BoxConstraints(minWidth: isCompact ? 30 : 36, minHeight: isCompact ? 30 : 36),
              icon: Icon(
                Icons.schedule_rounded,
                color: const Color(0xFF00E5FF),
                size: isCompact ? 20 : 22,
              ),
              onPressed: () {
                widget.onOpenGuide?.call();
                _startControlsTimer();
              },
            ),
          ],
          if (widget.onToggleFavorite != null) ...[
            const SizedBox(width: 4),
            _PlayerTvIconButton(
              buttonKey: const Key('btn_toggle_favorite'),
              tooltip: widget.isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
              focusNode: _favFocusNode,
              constraints: BoxConstraints(minWidth: isCompact ? 30 : 36, minHeight: isCompact ? 30 : 36),
              icon: Icon(
                widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                color: widget.isFavorite ? const Color(0xFFEF5350) : Colors.white70,
                size: isCompact ? 20 : 22,
              ),
              onPressed: () {
                widget.onToggleFavorite?.call();
                _startControlsTimer();
              },
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

  Widget _buildCenterControls(bool isPlaying) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Botão Canal Anterior (visível em tela cheia)
          if (widget.isFullscreen && widget.onPreviousChannel != null)
            Padding(
              padding: const EdgeInsets.only(right: 28),
              child: _PlayerTvIconButton(
                buttonKey: const Key('btn_prev_channel'),
                tooltip: 'Canal anterior',
                focusNode: _prevChannelFocusNode,
                padding: const EdgeInsets.all(8),
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 1.2),
                  ),
                  child: const Icon(
                    Icons.skip_previous_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                onPressed: () {
                  widget.onPreviousChannel?.call();
                  _startControlsTimer();
                },
              ),
            ),

          // Botão Play/Pause Central
          _PlayerTvIconButton(
            buttonKey: const Key('btn_center_play_pause'),
            tooltip: isPlaying ? 'Pausar' : 'Reproduzir',
            focusNode: _playPauseFocusNode,
            padding: const EdgeInsets.all(8),
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF00E5FF), width: 1.8),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: const Color(0xFF00E5FF),
                size: widget.isFullscreen ? 48 : 36,
              ),
            ),
            onPressed: () {
              widget.onTogglePlayPause();
              _startControlsTimer();
            },
          ),

          // Botão Próximo Canal (visível em tela cheia)
          if (widget.isFullscreen && widget.onNextChannel != null)
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: _PlayerTvIconButton(
                buttonKey: const Key('btn_next_channel'),
                tooltip: 'Próximo canal',
                focusNode: _nextChannelFocusNode,
                padding: const EdgeInsets.all(8),
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 1.2),
                  ),
                  child: const Icon(
                    Icons.skip_next_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                onPressed: () {
                  widget.onNextChannel?.call();
                  _startControlsTimer();
                },
              ),
            ),
        ],
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
          // Controles de canal e Play/Pause no rodapé (mini player)
          if (!widget.isFullscreen)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: isPlaying ? 'Pausar' : 'Reproduzir',
                  icon: Icon(
                    isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                    color: const Color(0xFF00E5FF),
                    size: 24,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    widget.onTogglePlayPause();
                    _startControlsTimer();
                  },
                ),
              ],
            )
          else
            const SizedBox.shrink(),

          Row(
            children: [
              // Alternador de Enquadramento (Fit Mode) tanto em tela cheia quanto em mini player
              if (widget.onFitModeChanged != null)
                _PlayerTvIconButton(
                  buttonKey: const Key('btn_fit_mode'),
                  tooltip: 'Proporção: $_fitModeLabel',
                  focusNode: _fitFocusNode,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  icon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.aspect_ratio_rounded, color: Colors.white70, size: 18),
                      if (widget.isFullscreen) ...[
                        const SizedBox(width: 4),
                        Text(
                          _fitModeLabel,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                  onPressed: _cycleFitMode,
                ),

              // Botão Picture-in-Picture (se suportado e não for TV)
              if (!DeviceUtils.isTv)
                IconButton(
                  key: const Key('btn_pip'),
                  tooltip: 'Janela flutuante (PiP)',
                  icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white70, size: 20),
                  padding: isCompact ? EdgeInsets.zero : const EdgeInsets.all(8),
                  constraints: isCompact
                      ? const BoxConstraints(minWidth: 36, minHeight: 36)
                      : const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: () {
                    DeviceUtils.enterPip();
                  },
                ),

              // Botão Alternar Tela Cheia / Mini Player
              _PlayerTvIconButton(
                buttonKey: const Key('btn_toggle_fullscreen'),
                tooltip: widget.isFullscreen ? 'Sair da tela cheia' : 'Tela cheia',
                focusNode: _fsFocusNode,
                padding: isCompact ? EdgeInsets.zero : const EdgeInsets.all(8),
                constraints: isCompact
                    ? const BoxConstraints(minWidth: 36, minHeight: 36)
                    : const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: Icon(
                  widget.isFullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: Colors.white,
                  size: isCompact ? 22 : 24,
                ),
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

/// Botão de controle sobreposto adaptado para Smart TV e controle remoto D-pad.
/// Exibe anel neon com brilho ao receber foco e processa ativação no OK/Select/Espaço.
class _PlayerTvIconButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback onPressed;
  final String tooltip;
  final Key? buttonKey;
  final FocusNode? focusNode;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry padding;

  const _PlayerTvIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.buttonKey,
    this.focusNode,
    this.constraints,
    this.padding = const EdgeInsets.all(6),
  });

  @override
  State<_PlayerTvIconButton> createState() => _PlayerTvIconButtonState();
}

class _PlayerTvIconButtonState extends State<_PlayerTvIconButton> {
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocusChanged);
    _isFocused = widget.focusNode?.hasFocus ?? false;
  }

  @override
  void didUpdateWidget(covariant _PlayerTvIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChanged);
      widget.focusNode?.addListener(_onFocusChanged);
      _isFocused = widget.focusNode?.hasFocus ?? false;
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) {
      final focused = widget.focusNode?.hasFocus ?? false;
      if (_isFocused != focused) {
        setState(() => _isFocused = focused);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveFocused = _isFocused || (widget.focusNode?.hasFocus ?? false);

    return FocusableActionDetector(
      key: widget.buttonKey,
      focusNode: widget.focusNode,
      actions: DeviceUtils.activateAction(widget.onPressed),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) {
        if (mounted && _isFocused != v) {
          setState(() => _isFocused = v);
        }
      },
      child: Tooltip(
        message: widget.tooltip,
        child: InkWell(
          canRequestFocus: false,
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(24),
          splashColor: const Color(0x3300E5FF),
          child: Container(
            constraints: widget.constraints,
            padding: widget.padding,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: effectiveFocused ? const Color(0x3300E5FF) : Colors.transparent,
              border: Border.all(
                color: effectiveFocused ? const Color(0xFF00E5FF) : Colors.transparent,
                width: 2.0,
              ),
              boxShadow: effectiveFocused
                  ? const [
                      BoxShadow(
                        color: Color(0x6600E5FF),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: widget.icon,
          ),
        ),
      ),
    );
  }
}
