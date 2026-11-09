import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/playback_progress_service.dart';
import '../services/url_sanitizer.dart';
import 'audio_subtitle_selector_dialog.dart';
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
  // FocusNodes explícitos para controles e navegação D-Pad em Android TV / Fire TV
  final FocusNode _focusNode = FocusNode(debugLabel: 'VodPlayerRoot');
  final FocusNode _backFocusNode = FocusNode(debugLabel: 'VodPlayerBack');
  final FocusNode _seekBackFocusNode = FocusNode(debugLabel: 'VodPlayerSeekBack');
  final FocusNode _playPauseFocusNode = FocusNode(debugLabel: 'VodPlayerPlayPause');
  final FocusNode _seekForwardFocusNode = FocusNode(debugLabel: 'VodPlayerSeekForward');
  final FocusNode _nextEpFocusNode = FocusNode(debugLabel: 'VodPlayerNextEp');
  final FocusNode _skipIntroFocusNode = FocusNode(debugLabel: 'VodPlayerSkipIntro');
  final FocusNode _audioTrackFocusNode = FocusNode(debugLabel: 'VodPlayerAudioTrack');
  final FocusNode _fitFocusNode = FocusNode(debugLabel: 'VodPlayerFit');

  // FocusNodes para overlays
  final FocusNode _retryFocusNode = FocusNode(debugLabel: 'VodPlayerRetry');
  final FocusNode _errorNextEpFocusNode = FocusNode(debugLabel: 'VodPlayerErrorNextEp');
  final FocusNode _errorBackFocusNode = FocusNode(debugLabel: 'VodPlayerErrorBack');
  final FocusNode _cancelCountdownFocusNode = FocusNode(debugLabel: 'VodPlayerCancelCountdown');
  final FocusNode _playNowCountdownFocusNode = FocusNode(debugLabel: 'VodPlayerPlayNowCountdown');

  bool _showControls = true;
  Timer? _controlsTimer;

  bool _isDraggingSlider = false;
  double _dragSliderValue = 0.0;

  // Variáveis para controle de avanço e retrocesso contínuo fluido (active ticker)
  bool _isContinuousSeeking = false;
  int _continuousSeekTargetMs = 0;
  int _continuousSeekDeltaSeconds = 0;
  int _seekDirection = 0; // +1 = avanço, -1 = retrocesso
  Timer? _initialHoldTimer;
  Timer? _continuousSeekTicker;
  Timer? _inactivityWatchdogTimer;
  DateTime? _seekStartTime;
  bool _isBackDebounced = false;
  Timer? _backDebounceTimer;

  // Estado explícito de intenção de reprodução vs. busca de posição
  bool _isUserPaused = false;
  bool _isRelativeSeeking = false;
  Timer? _relativeSeekResetTimer;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _isUserPaused = c != null && c.value.isInitialized && !c.value.isPlaying;
    _attachController(widget.controller);
    _startControlsTimer();
    _checkInitialOverlayFocus();
  }

  void _checkInitialOverlayFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.errorMessage != null && !widget.isLoading) {
        if (widget.onRetry != null) {
          _retryFocusNode.requestFocus();
        } else {
          _errorBackFocusNode.requestFocus();
        }
      } else if (widget.nextEpisodeCountdown != null && widget.nextEpisodeCountdown! > 0) {
        if (widget.onPlayNextEpisodeNow != null) {
          _playNowCountdownFocusNode.requestFocus();
        } else {
          _cancelCountdownFocusNode.requestFocus();
        }
      } else if (_showControls) {
        _playPauseFocusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant VodPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _detachController(oldWidget.controller);
      _attachController(widget.controller);
      if (widget.controller?.value.isPlaying ?? false) {
        _isUserPaused = false;
      }
    }

    if (widget.errorMessage != oldWidget.errorMessage && widget.errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (widget.onRetry != null) {
            _retryFocusNode.requestFocus();
          } else {
            _errorBackFocusNode.requestFocus();
          }
        }
      });
    }

    if (widget.nextEpisodeCountdown != oldWidget.nextEpisodeCountdown &&
        widget.nextEpisodeCountdown != null &&
        widget.nextEpisodeCountdown! > 0 &&
        oldWidget.nextEpisodeCountdown == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (widget.onPlayNextEpisodeNow != null) {
            _playNowCountdownFocusNode.requestFocus();
          } else {
            _cancelCountdownFocusNode.requestFocus();
          }
        }
      });
    }
  }

  void _attachController(VideoPlayerController? c) {
    c?.addListener(_onControllerStateChanged);
  }

  void _detachController(VideoPlayerController? c) {
    c?.removeListener(_onControllerStateChanged);
  }

  void _onControllerStateChanged() {
    if (!mounted) return;
    final val = widget.controller?.value;
    if (val != null) {
      if (val.isPlaying) {
        if (_isUserPaused || _isRelativeSeeking) {
          setState(() {
            _isUserPaused = false;
            _isRelativeSeeking = false;
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _detachController(widget.controller);
    _relativeSeekResetTimer?.cancel();
    _controlsTimer?.cancel();
    _initialHoldTimer?.cancel();
    _continuousSeekTicker?.cancel();
    _inactivityWatchdogTimer?.cancel();
    _backDebounceTimer?.cancel();

    _focusNode.dispose();
    _backFocusNode.dispose();
    _seekBackFocusNode.dispose();
    _playPauseFocusNode.dispose();
    _seekForwardFocusNode.dispose();
    _nextEpFocusNode.dispose();
    _skipIntroFocusNode.dispose();
    _audioTrackFocusNode.dispose();
    _fitFocusNode.dispose();
    _retryFocusNode.dispose();
    _errorNextEpFocusNode.dispose();
    _errorBackFocusNode.dispose();
    _cancelCountdownFocusNode.dispose();
    _playNowCountdownFocusNode.dispose();
    super.dispose();
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

  void _triggerSeekRelative(int seconds) {
    _isRelativeSeeking = true;
    _relativeSeekResetTimer?.cancel();
    _relativeSeekResetTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _isRelativeSeeking = false);
      }
    });
    widget.onSeekRelative?.call(seconds);
    _startControlsTimer();
    setState(() {});
  }

  void _handleTogglePlayPause() {
    final c = widget.controller;
    if (c != null && c.value.isInitialized) {
      _isUserPaused = c.value.isPlaying;
    } else {
      _isUserPaused = !_isUserPaused;
    }
    widget.onTogglePlayPause();
    setState(() => _showControls = true);
    _startControlsTimer();
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    // Exibição de progresso com vídeo pausado: não auto-oculta enquanto estiver pausado ou em seek contínuo
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          (widget.controller?.value.isPlaying ?? false) &&
          !_isDraggingSlider &&
          !_isContinuousSeeking) {
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
    switch (widget.fitMode) {
      case LiveVideoFitMode.contain:
        return 'Original';
      case LiveVideoFitMode.cover:
        return 'Preencher';
      case LiveVideoFitMode.fill:
        return 'Esticar';
    }
  }

  void _cycleFitMode() {
    if (widget.onFitModeChanged == null) return;
    final LiveVideoFitMode newMode;
    switch (widget.fitMode) {
      case LiveVideoFitMode.contain:
        newMode = LiveVideoFitMode.cover;
        break;
      case LiveVideoFitMode.cover:
        newMode = LiveVideoFitMode.fill;
        break;
      case LiveVideoFitMode.fill:
        newMode = LiveVideoFitMode.contain;
        break;
    }
    widget.onFitModeChanged!(newMode);
    _startControlsTimer();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;

    // A. OVERLAY DE ERRO ATIVO: Foco dedicado nas ações de erro
    if (widget.errorMessage != null && !widget.isLoading) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;

      if (key == LogicalKeyboardKey.arrowLeft) {
        if (_errorBackFocusNode.hasFocus) {
          if (widget.onNextEpisode != null) {
            _errorNextEpFocusNode.requestFocus();
          } else if (widget.onRetry != null) {
            _retryFocusNode.requestFocus();
          }
        } else if (_errorNextEpFocusNode.hasFocus) {
          if (widget.onRetry != null) _retryFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.arrowRight) {
        if (_retryFocusNode.hasFocus) {
          if (widget.onNextEpisode != null) {
            _errorNextEpFocusNode.requestFocus();
          } else if (widget.onBack != null) {
            _errorBackFocusNode.requestFocus();
          }
        } else if (_errorNextEpFocusNode.hasFocus) {
          if (widget.onBack != null) _errorBackFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space) {
        if (_errorBackFocusNode.hasFocus) {
          widget.onBack?.call();
        } else if (_errorNextEpFocusNode.hasFocus) {
          widget.onNextEpisode?.call();
        } else if (_retryFocusNode.hasFocus || widget.onRetry != null) {
          widget.onRetry?.call();
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.backspace) {
        widget.onBack?.call();
        return KeyEventResult.handled;
      }

      return KeyEventResult.ignored;
    }

    // B. OVERLAY DE CONTAGEM REGRESSIVA DO PRÓXIMO EPISÓDIO
    if (widget.nextEpisodeCountdown != null &&
        widget.nextEpisodeCountdown! > 0 &&
        widget.errorMessage == null) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;

      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        if (_playNowCountdownFocusNode.hasFocus) {
          if (widget.onCancelNextEpisode != null) _cancelCountdownFocusNode.requestFocus();
        } else {
          if (widget.onPlayNextEpisodeNow != null) _playNowCountdownFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space) {
        if (_cancelCountdownFocusNode.hasFocus) {
          widget.onCancelNextEpisode?.call();
        } else {
          widget.onPlayNextEpisodeNow?.call();
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.backspace) {
        widget.onCancelNextEpisode?.call();
        return KeyEventResult.handled;
      }

      return KeyEventResult.ignored;
    }

    // C. PROCESSAMENTO DE TECLAS NO PLAYER (COM OU SEM CONTROLES VISÍVEIS)

    // 1. Processa KeyUpEvent unificado: soltar seek contínuo ou salto curto de 10s
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        if (_isContinuousSeeking) {
          _commitContinuousSeek();
          return KeyEventResult.handled;
        } else if (_initialHoldTimer != null) {
          _cancelHoldTimer();
          final isForward = key == LogicalKeyboardKey.arrowRight;
          _triggerSeekRelative(isForward ? 10 : -10);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // 2. Play/Pause físico dedicado no controle remoto
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (event is KeyDownEvent) {
        _handleTogglePlayPause();
      }
      return KeyEventResult.handled;
    }

    // 3. Voltar físico (Escape / goBack / backspace)
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.backspace) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (event is KeyDownEvent) {
        if (_isBackDebounced) return KeyEventResult.handled;
        _isBackDebounced = true;
        _backDebounceTimer?.cancel();
        _backDebounceTimer = Timer(const Duration(milliseconds: 350), () {
          if (mounted) _isBackDebounced = false;
        });

        if (_showControls) {
          // Primeiro toque com controles visíveis: apenas oculta controles mantendo o vídeo rodando
          _controlsTimer?.cancel();
          setState(() => _showControls = false);
          _focusNode.requestFocus();
        } else {
          // Com controles ocultos: sair da tela e retornar ao catálogo
          widget.onBack?.call();
        }
      }
      return KeyEventResult.handled;
    }

    // 4. QUANDO CONTROLES ESTIVEREM OCULTOS:
    if (!_showControls) {
      // Setas Left / Right com controles ocultos iniciam seek
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        final isForward = key == LogicalKeyboardKey.arrowRight;
        final newDir = isForward ? 1 : -1;
        setState(() => _showControls = true);
        _controlsTimer?.cancel();
        _resetInactivityWatchdog();

        if (_isContinuousSeeking) {
          if (_seekDirection != newDir) {
            _seekDirection = newDir;
          }
          return KeyEventResult.handled;
        }

        if (event is KeyRepeatEvent) {
          _cancelHoldTimer();
          _startContinuousSeeking(newDir);
          return KeyEventResult.handled;
        }

        if (event is KeyDownEvent) {
          _seekDirection = newDir;
          _cancelHoldTimer();
          _initialHoldTimer = Timer(const Duration(milliseconds: 250), () {
            if (mounted) {
              _startContinuousSeeking(newDir);
            }
          });
          return KeyEventResult.handled;
        }

        return KeyEventResult.handled;
      }

      // Qualquer outra tecla (Select, Enter, Space, Up, Down): APENAS revela os controles e foca o botão central
      // Requisito estrito: OK com controles ocultos NÃO pausa nem altera a reprodução involuntariamente!
      if (event is KeyDownEvent) {
        _revealControls();
      }
      return KeyEventResult.handled;
    }

    // 5. QUANDO CONTROLES ESTIVEREM VISÍVEIS:
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    _startControlsTimer();

    // 5a. Navegação D-Pad 2D: ArrowUp
    if (key == LogicalKeyboardKey.arrowUp) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_fitFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (_playPauseFocusNode.hasFocus ||
          _seekBackFocusNode.hasFocus ||
          _seekForwardFocusNode.hasFocus ||
          _nextEpFocusNode.hasFocus) {
        if (widget.onBack != null) {
          _backFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.handled;
    }

    // 5b. Navegação D-Pad 2D: ArrowDown
    if (key == LogicalKeyboardKey.arrowDown) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_backFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (_playPauseFocusNode.hasFocus ||
          _seekBackFocusNode.hasFocus ||
          _seekForwardFocusNode.hasFocus ||
          _nextEpFocusNode.hasFocus) {
        if (widget.onFitModeChanged != null) {
          _fitFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.handled;
    }

    // 5c. Navegação D-Pad 2D e Seek: ArrowLeft
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_fitFocusNode.hasFocus) {
        _backFocusNode.requestFocus();
        return KeyEventResult.handled;
      }

      // Se estiver no botão Voltar superior, mantém foco lá
      if (_backFocusNode.hasFocus) {
        return KeyEventResult.handled;
      }

      // Move foco visual entre botões
      if (_skipIntroFocusNode.hasFocus) {
        if (widget.onNextEpisode != null) {
          _nextEpFocusNode.requestFocus();
        } else {
          _seekForwardFocusNode.requestFocus();
        }
      } else if (_nextEpFocusNode.hasFocus) {
        _seekForwardFocusNode.requestFocus();
      } else if (_seekForwardFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
      } else if (_playPauseFocusNode.hasFocus) {
        _seekBackFocusNode.requestFocus();
      }

      // Dispara lógica de seek acelerado / salto de 10s
      final newDir = -1;
      _controlsTimer?.cancel();
      _resetInactivityWatchdog();

      if (_isContinuousSeeking) {
        if (_seekDirection != newDir) _seekDirection = newDir;
        return KeyEventResult.handled;
      }

      if (event is KeyRepeatEvent) {
        _cancelHoldTimer();
        _startContinuousSeeking(newDir);
        return KeyEventResult.handled;
      }

      if (event is KeyDownEvent) {
        _seekDirection = newDir;
        _cancelHoldTimer();
        _initialHoldTimer = Timer(const Duration(milliseconds: 250), () {
          if (mounted) _startContinuousSeeking(newDir);
        });
        return KeyEventResult.handled;
      }

      return KeyEventResult.handled;
    }

    // 5d. Navegação D-Pad 2D e Seek: ArrowRight
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_backFocusNode.hasFocus) {
        if (widget.onFitModeChanged != null) {
          _fitFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }

      // Se estiver no botão Proporção superior, mantém foco lá
      if (_fitFocusNode.hasFocus) {
        return KeyEventResult.handled;
      }

      // Move foco visual entre botões
      if (_seekBackFocusNode.hasFocus) {
        _playPauseFocusNode.requestFocus();
      } else if (_playPauseFocusNode.hasFocus) {
        _seekForwardFocusNode.requestFocus();
      } else if (_seekForwardFocusNode.hasFocus) {
        if (widget.onNextEpisode != null) {
          _nextEpFocusNode.requestFocus();
        } else if (_skipIntroFocusNode.canRequestFocus) {
          _skipIntroFocusNode.requestFocus();
        }
      } else if (_nextEpFocusNode.hasFocus && _skipIntroFocusNode.canRequestFocus) {
        _skipIntroFocusNode.requestFocus();
      }

      // Dispara lógica de seek acelerado / salto de 10s
      final newDir = 1;
      _controlsTimer?.cancel();
      _resetInactivityWatchdog();

      if (_isContinuousSeeking) {
        if (_seekDirection != newDir) _seekDirection = newDir;
        return KeyEventResult.handled;
      }

      if (event is KeyRepeatEvent) {
        _cancelHoldTimer();
        _startContinuousSeeking(newDir);
        return KeyEventResult.handled;
      }

      if (event is KeyDownEvent) {
        _seekDirection = newDir;
        _cancelHoldTimer();
        _initialHoldTimer = Timer(const Duration(milliseconds: 250), () {
          if (mounted) _startContinuousSeeking(newDir);
        });
        return KeyEventResult.handled;
      }

      return KeyEventResult.handled;
    }

    // 5e. Ação Central OK / Select / Enter / Space
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      if (_backFocusNode.hasFocus) {
        widget.onBack?.call();
      } else if (_seekBackFocusNode.hasFocus) {
        _triggerSeekRelative(-10);
      } else if (_seekForwardFocusNode.hasFocus) {
        _triggerSeekRelative(10);
      } else if (_nextEpFocusNode.hasFocus) {
        widget.onNextEpisode?.call();
        _startControlsTimer();
      } else if (_skipIntroFocusNode.hasFocus) {
        _triggerSeekRelative(85);
        _startControlsTimer();
      } else if (_audioTrackFocusNode.hasFocus) {
        AudioSubtitleSelectorDialog.show(context, controller: widget.controller);
        _startControlsTimer();
      } else if (_fitFocusNode.hasFocus) {
        _cycleFitMode();
      } else {
        // Se Play/Pause ou qualquer outro tiver foco
        _handleTogglePlayPause();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _startContinuousSeeking(int direction) {
    _cancelHoldTimer();
    _seekDirection = direction;
    final pos = widget.controller?.value.position.inMilliseconds ?? 0;
    _continuousSeekTargetMs = pos;
    _continuousSeekDeltaSeconds = 0;
    _isContinuousSeeking = true;
    _seekStartTime = DateTime.now();

    _continuousSeekTicker?.cancel();
    _continuousSeekTicker = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!mounted) return;
      _tickContinuousSeek();
    });

    _tickContinuousSeek();
  }

  void _tickContinuousSeek() {
    if (!_isContinuousSeeking) return;

    final elapsedMs = _seekStartTime != null
        ? DateTime.now().difference(_seekStartTime!).inMilliseconds
        : 0;

    // Curva de aceleração progressiva rápida e perceptível
    int stepSec;
    if (elapsedMs > 5000) {
      stepSec = 60;
    } else if (elapsedMs > 2500) {
      stepSec = 30;
    } else if (elapsedMs > 1000) {
      stepSec = 15;
    } else {
      stepSec = 5;
    }

    final delta = _seekDirection * stepSec;
    _continuousSeekDeltaSeconds += delta;

    final totalMs = widget.controller?.value.duration.inMilliseconds ?? 0;
    final maxMs = totalMs > 0 ? totalMs : 0;
    _continuousSeekTargetMs = (_continuousSeekTargetMs + delta * 1000).clamp(0, maxMs);

    setState(() {});
  }

  void _resetInactivityWatchdog() {
    _inactivityWatchdogTimer?.cancel();
    _inactivityWatchdogTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted && _isContinuousSeeking) {
        _commitContinuousSeek();
      }
    });
  }

  void _cancelHoldTimer() {
    _initialHoldTimer?.cancel();
    _initialHoldTimer = null;
  }

  void _commitContinuousSeek() {
    _inactivityWatchdogTimer?.cancel();
    _inactivityWatchdogTimer = null;
    _continuousSeekTicker?.cancel();
    _continuousSeekTicker = null;
    _cancelHoldTimer();

    if (!_isContinuousSeeking) return;

    final target = Duration(milliseconds: _continuousSeekTargetMs);
    final deltaSecs = _continuousSeekDeltaSeconds;
    setState(() {
      _isContinuousSeeking = false;
      _continuousSeekDeltaSeconds = 0;
      _seekStartTime = null;
    });

    final c = widget.controller;
    if (c != null && c.value.isInitialized) {
      c.seekTo(target);
      c.play();
    } else {
      widget.onSeekRelative?.call(deltaSecs);
    }
    _startControlsTimer();
  }

  String _formatSeekDelta(int seconds) {
    final sign = seconds >= 0 ? '+' : '-';
    final abs = seconds.abs();
    if (abs < 60) return '$sign${abs}s';
    final m = abs ~/ 60;
    final s = abs % 60;
    return s > 0 ? '$sign${m}m ${s}s' : '$sign${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final isInitialized = controller != null && controller.value.isInitialized;
    final isPlaying = controller?.value.isPlaying ?? false;

    return PopScope(
      canPop: !_showControls,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showControls) {
          if (_isBackDebounced) return;
          _isBackDebounced = true;
          _backDebounceTimer?.cancel();
          _backDebounceTimer = Timer(const Duration(milliseconds: 350), () {
            if (mounted) _isBackDebounced = false;
          });
          _controlsTimer?.cancel();
          setState(() => _showControls = false);
        }
      },
      child: Focus(
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
        } else if (widget.fitMode == LiveVideoFitMode.fill) {
          return SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: rawVideoWidth > 0 ? rawVideoWidth : 16,
                height: rawVideoHeight > 0 ? rawVideoHeight : 9,
                child: VideoPlayer(controller),
              ),
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

  Widget _buildFocusableIconButton({
    required FocusNode focusNode,
    required String tooltip,
    required double iconSize,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    return AnimatedBuilder(
      animation: focusNode,
      builder: (context, _) {
        final isFocused = focusNode.hasFocus;
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isFocused ? const Color(0xFF00E5FF) : Colors.transparent,
              width: 2.2,
            ),
            boxShadow: isFocused
                ? [
                    const BoxShadow(
                      color: Color(0x9900E5FF),
                      blurRadius: 12,
                      spreadRadius: 2,
                    )
                  ]
                : null,
          ),
          child: IconButton(
            focusNode: focusNode,
            tooltip: tooltip,
            iconSize: iconSize,
            icon: icon,
            onPressed: onPressed,
          ),
        );
      },
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
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0x33EF5350),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x66EF5350)),
                  ),
                  child: Text(
                    sanitizedError,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFFCDD2),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.onRetry != null) ...[
                      AnimatedBuilder(
                        animation: _retryFocusNode,
                        builder: (context, _) {
                          final isFocused = _retryFocusNode.hasFocus;
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: isFocused
                                  ? [
                                      const BoxShadow(
                                        color: Color(0x9900E5FF),
                                        blurRadius: 12,
                                        spreadRadius: 2,
                                      )
                                    ]
                                  : null,
                            ),
                            child: ElevatedButton.icon(
                              focusNode: _retryFocusNode,
                              onPressed: widget.onRetry,
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('Tentar novamente'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isFocused ? const Color(0xFF00E5FF) : const Color(0xFFE50914),
                                foregroundColor: isFocused ? Colors.black : Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (widget.onNextEpisode != null) ...[
                      AnimatedBuilder(
                        animation: _errorNextEpFocusNode,
                        builder: (context, _) {
                          final isFocused = _errorNextEpFocusNode.hasFocus;
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: isFocused
                                  ? [
                                      const BoxShadow(
                                        color: Color(0x9900E5FF),
                                        blurRadius: 12,
                                        spreadRadius: 2,
                                      )
                                    ]
                                  : null,
                            ),
                            child: ElevatedButton.icon(
                              focusNode: _errorNextEpFocusNode,
                              onPressed: widget.onNextEpisode,
                              icon: const Icon(Icons.skip_next_rounded, size: 16),
                              label: const Text('Próximo episódio'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isFocused ? const Color(0xFF00E5FF) : const Color(0xFF1E293B),
                                foregroundColor: isFocused ? Colors.black : Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (widget.onBack != null)
                      AnimatedBuilder(
                        animation: _errorBackFocusNode,
                        builder: (context, _) {
                          final isFocused = _errorBackFocusNode.hasFocus;
                          return OutlinedButton(
                            focusNode: _errorBackFocusNode,
                            onPressed: widget.onBack,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isFocused ? const Color(0xFF00E5FF) : Colors.white70,
                              side: BorderSide(
                                color: isFocused ? const Color(0xFF00E5FF) : const Color(0xFF37474F),
                                width: isFocused ? 2 : 1,
                              ),
                            ),
                            child: const Text('Voltar'),
                          );
                        },
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

            // Centro: Botões de Controle Rápido (-10s, Play/Pause, +10s, [Próximo Ep], [Pular Abertura])
            _buildCenterControls(isPlaying, position: position, duration: duration),

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
            _buildFocusableIconButton(
              focusNode: _backFocusNode,
              tooltip: 'Voltar',
              iconSize: 24,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              onPressed: () => widget.onBack?.call(),
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

  Widget _buildCenterControls(bool isPlaying, {Duration position = Duration.zero, Duration duration = Duration.zero}) {
    final isSeekingActive = _isRelativeSeeking || _isContinuousSeeking || _isDraggingSlider;
    final showPausedPill = _isUserPaused && !isPlaying && !isSeekingActive && !widget.isLoading && !widget.isBuffering;
    final showPauseIcon = (isPlaying || isSeekingActive) && !_isUserPaused;

    final canSkipIntro = position < const Duration(minutes: 5) && duration >= const Duration(minutes: 6);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showPausedPill)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFFA726), width: 1.2),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_circle_filled_rounded, color: Color(0xFFFFA726), size: 16),
                SizedBox(width: 6),
                Text(
                  'PAUSADO',
                  style: TextStyle(
                    color: Color(0xFFFFA726),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
        if (_isContinuousSeeking)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xDD000000),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x6600E5FF),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _continuousSeekDeltaSeconds >= 0
                      ? Icons.fast_forward_rounded
                      : Icons.fast_rewind_rounded,
                  color: const Color(0xFF00E5FF),
                  size: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  '${_formatSeekDelta(_continuousSeekDeltaSeconds)}  ➜  ${PlaybackProgressService.formatDuration(Duration(milliseconds: _continuousSeekTargetMs))}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildFocusableIconButton(
              focusNode: _seekBackFocusNode,
              tooltip: 'Retroceder 10s',
              iconSize: 42,
              icon: const Icon(Icons.replay_10_rounded, color: Colors.white70),
              onPressed: () => _triggerSeekRelative(-10),
            ),
            const SizedBox(width: 20),
            _buildFocusableIconButton(
              focusNode: _playPauseFocusNode,
              tooltip: showPauseIcon ? 'Pausar' : 'Reproduzir',
              iconSize: 64,
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE50914), width: 1.5),
                ),
                child: Icon(
                  showPauseIcon ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: const Color(0xFFE50914),
                ),
              ),
              onPressed: _handleTogglePlayPause,
            ),
            const SizedBox(width: 20),
            _buildFocusableIconButton(
              focusNode: _seekForwardFocusNode,
              tooltip: 'Avançar 10s',
              iconSize: 42,
              icon: const Icon(Icons.forward_10_rounded, color: Colors.white70),
              onPressed: () => _triggerSeekRelative(10),
            ),
            if (widget.onNextEpisode != null) ...[
              const SizedBox(width: 20),
              _buildFocusableIconButton(
                focusNode: _nextEpFocusNode,
                tooltip: 'Próximo episódio',
                iconSize: 42,
                icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                onPressed: () {
                  widget.onNextEpisode?.call();
                  _startControlsTimer();
                },
              ),
            ],
            if (canSkipIntro) ...[
              const SizedBox(width: 20),
              _buildSkipIntroPillButton(),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSkipIntroPillButton() {
    return AnimatedBuilder(
      animation: _skipIntroFocusNode,
      builder: (context, _) {
        final isFocused = _skipIntroFocusNode.hasFocus;
        return Tooltip(
          message: 'Pular Abertura (+85s)',
          child: InkWell(
            focusNode: _skipIntroFocusNode,
            onTap: () {
              _triggerSeekRelative(85);
              _startControlsTimer();
            },
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isFocused ? const Color(0xFFE50914) : const Color(0xCC182234),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isFocused ? Colors.white : const Color(0xFFE50914),
                  width: isFocused ? 2.0 : 1.2,
                ),
                boxShadow: isFocused
                    ? const [
                        BoxShadow(
                          color: Color(0x99E50914),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fast_forward_rounded,
                    size: 18,
                    color: isFocused ? Colors.white : const Color(0xFFE50914),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Pular Abertura (+85s)',
                    style: TextStyle(
                      color: isFocused ? Colors.white : const Color(0xFFF1F5F9),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(Duration position, Duration duration, bool isPlaying) {
    final effectivePosition = _isContinuousSeeking
        ? Duration(milliseconds: _continuousSeekTargetMs)
        : position;
    final totalMs = duration.inMilliseconds.toDouble();
    final currentMs = effectivePosition.inMilliseconds.toDouble().clamp(0.0, totalMs > 0 ? totalMs : 0.0);

    final sliderValue = _isDraggingSlider
        ? _dragSliderValue
        : (totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0);

    final currentDisplayDuration = _isDraggingSlider && totalMs > 0
        ? Duration(milliseconds: (_dragSliderValue * totalMs).round())
        : effectivePosition;

    final remaining = duration > currentDisplayDuration ? duration - currentDisplayDuration : Duration.zero;
    final elapsedStr = PlaybackProgressService.formatDuration(currentDisplayDuration);
    final totalStr = PlaybackProgressService.formatDuration(duration);
    final remainingStr = '-${PlaybackProgressService.formatDuration(remaining)}';

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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$elapsedStr / $totalStr',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (duration > Duration.zero) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Restante: $remainingStr',
                        style: const TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildAudioTracksButton(),
                  if (widget.onFitModeChanged != null) ...[
                    const SizedBox(width: 8),
                    AnimatedBuilder(
                      animation: _fitFocusNode,
                      builder: (context, _) {
                        final isFocused = _fitFocusNode.hasFocus;
                        return Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isFocused ? const Color(0xFF00E5FF) : Colors.transparent,
                              width: 2.0,
                            ),
                            boxShadow: isFocused
                                ? [
                                    const BoxShadow(
                                      color: Color(0x9900E5FF),
                                      blurRadius: 10,
                                      spreadRadius: 1,
                                    )
                                  ]
                                : null,
                          ),
                          child: TextButton.icon(
                            focusNode: _fitFocusNode,
                            onPressed: _cycleFitMode,
                            icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white70, size: 18),
                            label: Text(
                              _fitModeLabel,
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAudioTracksButton() {
    return AnimatedBuilder(
      animation: _audioTrackFocusNode,
      builder: (context, _) {
        final isFocused = _audioTrackFocusNode.hasFocus;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isFocused ? const Color(0xFF00E5FF) : Colors.transparent,
              width: 2.0,
            ),
            boxShadow: isFocused
                ? const [
                    BoxShadow(
                      color: Color(0x9900E5FF),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: TextButton.icon(
            focusNode: _audioTrackFocusNode,
            onPressed: () {
              AudioSubtitleSelectorDialog.show(context, controller: widget.controller);
              _startControlsTimer();
            },
            icon: const Icon(Icons.audiotrack_rounded, color: Colors.white70, size: 18),
            label: const Text(
              'Áudio & Legendas',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNextEpisodeCountdownOverlay() {
    return Positioned(
      bottom: 24,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xEE0D121D),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE50914), width: 1.8),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.skip_next_rounded, color: Color(0xFFE50914), size: 26),
                  const SizedBox(width: 8),
                  const Text(
                    'Próximo Episódio',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (widget.nextEpisodeTitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  widget.nextEpisodeTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB0BEC5),
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'Iniciando em ${widget.nextEpisodeCountdown}s...',
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (widget.onCancelNextEpisode != null)
                    AnimatedBuilder(
                      animation: _cancelCountdownFocusNode,
                      builder: (context, _) {
                        final isFocused = _cancelCountdownFocusNode.hasFocus;
                        return OutlinedButton(
                          focusNode: _cancelCountdownFocusNode,
                          onPressed: widget.onCancelNextEpisode,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: isFocused ? const Color(0xFF00E5FF) : Colors.white70,
                            side: BorderSide(
                              color: isFocused ? const Color(0xFF00E5FF) : const Color(0xFF37474F),
                              width: isFocused ? 2 : 1,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                          child: const Text('Cancelar', style: TextStyle(fontSize: 12)),
                        );
                      },
                    ),
                  if (widget.onPlayNextEpisodeNow != null)
                    AnimatedBuilder(
                      animation: _playNowCountdownFocusNode,
                      builder: (context, _) {
                        final isFocused = _playNowCountdownFocusNode.hasFocus;
                        return ElevatedButton.icon(
                          focusNode: _playNowCountdownFocusNode,
                          autofocus: true,
                          onPressed: widget.onPlayNextEpisodeNow,
                          icon: const Icon(Icons.play_arrow_rounded, size: 16),
                          label: const Text('Assistir agora', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE50914),
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: isFocused ? Colors.white : Colors.transparent,
                              width: isFocused ? 2 : 0,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
