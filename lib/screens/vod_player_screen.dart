import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../services/playback_metrics.dart';
import '../services/playback_progress_service.dart';
import '../services/player_diagnostics.dart';
import '../services/settings_service.dart';
import '../services/url_sanitizer.dart';
import '../utils/device_utils.dart';
import '../widgets/live_player_view.dart'; // Para reutilizar LiveVideoFitMode
import '../widgets/vod_player_view.dart';

/// Tela dedicada para reprodução de Filmes (VOD).
/// Gerencia o ciclo de vida do player, rotas de contingência e salvamento
/// periódico de progresso a cada 5 segundos e ao sair.
class VodPlayerScreen extends StatefulWidget {
  final XtreamVodStream movie;
  final List<String> streamUrls;
  final String accountKey;
  final Duration? initialPosition;
  final VideoPlayerController? testController;

  const VodPlayerScreen({
    super.key,
    required this.movie,
    required this.streamUrls,
    required this.accountKey,
    this.initialPosition,
    this.testController,
  });

  @override
  State<VodPlayerScreen> createState() => _VodPlayerScreenState();
}

class _VodPlayerScreenState extends State<VodPlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  final PlaybackProgressService _progressService = PlaybackProgressService();
  late final PlaybackMetrics _metrics;

  bool _isLoading = true;
  bool _isBuffering = false;
  bool _isSeekingToInitial = false;
  bool _isExiting = false;
  String? _errorMessage;
  int _currentUrlIndex = 0;
  Timer? _initialBufferingWatchdog;
  int _connectionEpoch = 0;

  Duration? _resumptionTarget;
  bool _seekAttempted = false;

  Timer? _progressSaveTimer;
  LiveVideoFitMode _fitMode = SettingsService.instance.defaultAspectRatio;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeviceUtils.setVideoOrientation();
    DeviceUtils.setKeepScreenOn(true);

    _resumptionTarget = widget.initialPosition;
    _seekAttempted = false;

    _metrics = PlaybackMetrics(
      mediaType: PlaybackMediaType.movie,
      title: widget.movie.name,
    );
    _metrics.markRequestStart();

    if (widget.testController != null) {
      _controller = widget.testController;
      _isLoading = false;
      _metrics.markPlayerInitialized();
      _metrics.markFirstFrame();
    } else {
      _initPlayer();
    }

    _startPeriodicProgressSave();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _saveCurrentProgress(force: true);
      final c = _controller;
      if (c != null && c.value.isInitialized && c.value.isPlaying) {
        c.pause();
      }
    } else if (state == AppLifecycleState.detached) {
      _saveCurrentProgress(force: true);
      _disposeCurrentController();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeviceUtils.setKeepScreenOn(false);
    _initialBufferingWatchdog?.cancel();
    _progressSaveTimer?.cancel();
    if (!_isExiting) {
      _saveCurrentProgress(force: true);
    }

    if (widget.testController == null) {
      final c = _controller;
      _controller = null;
      c?.removeListener(_onControllerUpdate);
      if (c != null && c.value.isInitialized && c.value.isPlaying) {
        c.pause();
      }
      c?.dispose();
    }

    DeviceUtils.restoreOrientation();
    super.dispose();
  }

  Future<void> _handleExit() async {
    if (_isExiting) return;
    _isExiting = true;
    _initialBufferingWatchdog?.cancel();
    _progressSaveTimer?.cancel();
    await _saveCurrentProgress(force: true);
    DeviceUtils.restoreOrientation();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _startPeriodicProgressSave() {
    _progressSaveTimer?.cancel();
    // Salva a posição do filme periodicamente a cada 15 segundos em vez de 5,
    // evitando contenção de I/O e micro-travamentos no armazenamento flash.
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        _saveCurrentProgress();
      }
    });
  }

  Future<void> _saveCurrentProgress({bool force = false}) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_isLoading && !force) return;
    if (_isSeekingToInitial) return;

    final pos = c.value.position;
    final dur = c.value.duration;

    // Proteção absoluta: NUNCA sobrescrever posição anterior válida se a reprodução atual não avançou (menos de 5s).
    // Preserva o progresso salvo mesmo quando force == true (saída rápida ou falha de inicialização).
    if (widget.initialPosition != null &&
        widget.initialPosition!.inSeconds >= 10 &&
        pos.inSeconds < 5) {
      debugPrint('[VOD PLAYER] [PROGRESSO] Preservando posição salva anterior (${PlaybackProgressService.formatDuration(widget.initialPosition!)}) pois reprodução atual não avançou (${PlaybackProgressService.formatDuration(pos)}).');
      return;
    }

    if (dur > Duration.zero && (pos.inSeconds >= 5 || force)) {
      debugPrint('[VOD PLAYER] [PROGRESSO] Salvando progresso: streamId=${widget.movie.streamId}, pos=${PlaybackProgressService.formatDuration(pos)}, dur=${PlaybackProgressService.formatDuration(dur)}');
      await _progressService.saveProgress(
        accountKey: widget.accountKey,
        streamId: widget.movie.streamId,
        position: pos,
        duration: dur,
      );

      await _progressService.saveContinueWatchingItem(
        accountKey: widget.accountKey,
        item: ContinueWatchingItem(
          streamId: widget.movie.streamId,
          type: ContinueWatchingType.movie,
          title: widget.movie.name,
          coverUrl: widget.movie.streamIcon,
          position: pos,
          duration: dur,
          updatedAt: DateTime.now(),
          containerExtension: widget.movie.containerExtension,
          categoryId: widget.movie.categoryId,
        ),
      );
    }
  }

  Future<void> _disposeCurrentController() async {
    _initialBufferingWatchdog?.cancel();
    final oldController = _controller;
    _controller = null;
    if (oldController != null) {
      oldController.removeListener(_onControllerUpdate);
      try {
        if (oldController.value.isInitialized && oldController.value.isPlaying) {
          await oldController.pause();
        }
      } catch (_) {}
      try {
        unawaited(oldController.dispose());
      } catch (_) {}
    }
  }

  Future<void> _initPlayer() async {
    _resumptionTarget = widget.initialPosition;
    _seekAttempted = false;

    debugPrint('[VOD PLAYER] Início de fluxo: streamId=${widget.movie.streamId}, título="${widget.movie.name}"');
    debugPrint('[VOD PLAYER] Posição de retomada solicitada: ${widget.initialPosition != null ? PlaybackProgressService.formatDuration(widget.initialPosition!) : 'Início (00:00)'}');

    if (widget.streamUrls.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Nenhum endereço de transmissão disponível para este filme.';
      });
      return;
    }

    await _connectToUrl(widget.streamUrls[_currentUrlIndex]);
  }

  Future<void> _connectToUrl(String url) async {
    final epoch = ++_connectionEpoch;
    await _disposeCurrentController();
    if (!mounted || epoch != _connectionEpoch) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isBuffering = false;
    });

    final sanitizedUrl = UrlSanitizer.sanitize(url);
    PlayerDiagnostics.log('REQUEST', 'Tipo=FILME, ID=${widget.movie.streamId}, Nome="${widget.movie.name}", Extensão="${widget.movie.containerExtension}", Rota=${_currentUrlIndex + 1}/${widget.streamUrls.length}');
    PlayerDiagnostics.log('MEDIA_ITEM', 'URL: $sanitizedUrl');
    PlayerDiagnostics.log('PREPARE', 'Iniciando controller.initialize() [timeout=25s]');

    final uri = Uri.parse(url);
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
      },
    );

    _controller = controller;
    controller.addListener(_onControllerUpdate);

    // Timeout de inicialização adequado para arquivos grandes de VOD (25 segundos)
    const timeoutDuration = Duration(seconds: 25);

    try {
      await controller.initialize().timeout(timeoutDuration);

      if (!mounted || epoch != _connectionEpoch || _controller != controller) return;

      _metrics.markConnectionEstablished();
      _metrics.markPlayerInitialized();

      final detectedDur = controller.value.duration;
      PlayerDiagnostics.log('STATE', 'STATE_READY | Duração: ${PlaybackProgressService.formatDuration(detectedDur)} | Resolução: ${controller.value.size.width.toInt()}x${controller.value.size.height.toInt()}');

      // 1. Inicia watchdog de buffer inicial
      _startInitialBufferingWatchdog(epoch);

      // 2. Aciona play() para estabelecer o pipeline de decodificação ativo
      await controller.play();
      PlayerDiagnostics.log('PLAY', 'controller.play() acionado (playWhenReady=true)');

      // 3. Aplica seekTo se houver posição inicial para continuar de onde parou
      if (widget.initialPosition != null && widget.initialPosition! > Duration.zero) {
        Duration target = widget.initialPosition!;
        if (detectedDur > Duration.zero && target >= detectedDur) {
          final safeTarget = detectedDur - const Duration(seconds: 10);
          target = safeTarget > Duration.zero ? safeTarget : Duration.zero;
        }

        if (target > Duration.zero) {
          _isSeekingToInitial = true;
          _seekAttempted = true;
          debugPrint('[VOD PLAYER] [SEEK] Disparando seekTo para ${PlaybackProgressService.formatDuration(target)} (posição salva: ${PlaybackProgressService.formatDuration(widget.initialPosition!)})...');
          try {
            await controller.seekTo(target);
            debugPrint('[VOD PLAYER] [SEEK] seekTo concluído com sucesso para ${PlaybackProgressService.formatDuration(target)}.');
          } catch (seekError) {
            debugPrint('[VOD PLAYER] [SEEK] Aviso: erro no seek inicial ($seekError). Reproduzindo do início.');
          } finally {
            _isSeekingToInitial = false;
          }
        }
      }

      if (mounted && epoch == _connectionEpoch && _controller == controller) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (!mounted || epoch != _connectionEpoch || _controller != controller) return;
      await _handleConnectionError(e, epoch: epoch);
    }
  }

  Future<void> _handleConnectionError(Object e, {required int epoch}) async {
    final quickDetails = PlayerDiagnostics.analyzeError(e);

    final isTimeout = e is TimeoutException ||
        quickDetails.causeClass == 'TimeoutException' ||
        quickDetails.shortUiMessage.contains('Timeout');
    final isAuthOrForbidden = quickDetails.isAuthOrForbidden;

    final canTryAlternative = !isAuthOrForbidden &&
        !isTimeout &&
        (_currentUrlIndex + 1 < widget.streamUrls.length);

    if (canTryAlternative) {
      _currentUrlIndex++;
      PlayerDiagnostics.log(
        'RETRY_ROUTE',
        'Tentando rota de contingência index $_currentUrlIndex devido a erro: ${quickDetails.technicalSummary}',
      );

      // Sondagem assíncrona em background para telemetria
      PlayerDiagnostics.probeStreamUrl(widget.streamUrls[_currentUrlIndex - 1], timeout: const Duration(seconds: 2))
          .then((p) => PlayerDiagnostics.logDiagnosticDetails(PlayerDiagnostics.analyzeError(e, probe: p)))
          .catchError((_) => null);

      await _connectToUrl(widget.streamUrls[_currentUrlIndex]);
      return;
    }

    final probe = await PlayerDiagnostics.probeStreamUrl(widget.streamUrls[_currentUrlIndex]);
    final details = PlayerDiagnostics.analyzeError(e, probe: probe);

    PlayerDiagnostics.log('ERROR', 'Falha na reprodução do filme: ${details.technicalSummary}');
    PlayerDiagnostics.logDiagnosticDetails(details);
    PlayerDiagnostics.log('ERROR_CODE', '${details.errorCode ?? 'N/D'}');
    PlayerDiagnostics.log('ERROR_NAME', details.errorCodeName ?? 'N/D');
    PlayerDiagnostics.log('CAUSE', '${details.causeClass ?? 'N/D'}: ${details.causeMessage ?? 'N/D'}');
    if (probe.statusCode != null) {
      PlayerDiagnostics.log('HTTP_STATUS', '${probe.statusCode} | Content-Type: ${probe.contentType ?? 'N/D'}');
    }

    final userMessage = details.shortUiMessage;
    _metrics.markError(userMessage);

    setState(() {
      _isLoading = false;
      _isBuffering = false;
      _errorMessage = userMessage;
    });
  }

  void _startInitialBufferingWatchdog(int epoch) {
    _initialBufferingWatchdog?.cancel();
    _initialBufferingWatchdog = Timer(const Duration(seconds: 25), () {
      if (!mounted || epoch != _connectionEpoch) return;
      final c = _controller;
      if (c != null &&
          !_metrics.hasFirstFrame &&
          (_isLoading || _isBuffering || (c.value.position <= Duration.zero && !c.value.isPlaying) || (_seekAttempted && c.value.isBuffering))) {
        debugPrint('[VOD PLAYER WATCHDOG] Tempo limite de buffer inicial excedido (25s sem reprodução). Pos: ${c.value.position}, isPlaying: ${c.value.isPlaying}, isBuffering: ${c.value.isBuffering}');
        _initialBufferingWatchdog?.cancel();
        _disposeCurrentController();
        if (mounted && epoch == _connectionEpoch) {
          setState(() {
            _isLoading = false;
            _isBuffering = false;
            _errorMessage = 'O fluxo de vídeo não iniciou a reprodução a tempo (tempo limite de buffer excedido). Tente novamente.';
          });
        }
      }
    });
  }

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;
    final val = c.value;

    // Erros durante a inicialização são tratados pelo try/catch de _connectToUrl
    if (!val.isInitialized) return;

    if (val.hasError && _errorMessage == null) {
      _initialBufferingWatchdog?.cancel();
      final errorDesc = val.errorDescription ?? 'Erro interno de reprodução';
      final details = PlayerDiagnostics.analyzeError(errorDesc);
      PlayerDiagnostics.log('ERROR', 'Controller disparou erro durante reprodução: ${details.technicalSummary}');
      PlayerDiagnostics.logDiagnosticDetails(details);
      PlayerDiagnostics.log('ERROR_NAME', details.errorCodeName ?? 'N/D');
      PlayerDiagnostics.log('CAUSE', '${details.causeClass ?? 'N/D'}: ${details.causeMessage ?? 'N/D'}');
      PlayerDiagnostics.log('STATE', 'hasError=true, pos=${val.position}, isPlaying=${val.isPlaying}, isBuffering=${val.isBuffering}');
      _metrics.markError(details.shortUiMessage);

      final isTimeout = details.causeClass == 'TimeoutException' || details.shortUiMessage.contains('Timeout');
      final isAuthOrForbidden = details.isAuthOrForbidden;

      if (!isAuthOrForbidden && !isTimeout && (_currentUrlIndex + 1 < widget.streamUrls.length)) {
        PlayerDiagnostics.log('RETRY_ROUTE', 'Erro assíncrono no controller do filme; tentando URL de contingência ${_currentUrlIndex + 1}.');
        _handleConnectionError(errorDesc, epoch: _connectionEpoch);
        return;
      }

      setState(() {
        _errorMessage = details.shortUiMessage;
        _isLoading = false;
        _isBuffering = false;
      });
    } else {
      // Confirmação segura de primeiro quadro / avanço real de reprodução
      bool hasAdvanced = false;
      if (_seekAttempted && _resumptionTarget != null && _resumptionTarget! > Duration.zero) {
        hasAdvanced = val.isPlaying &&
                      !val.isBuffering &&
                      !_isSeekingToInitial &&
                      val.position >= _resumptionTarget!;
      } else {
        hasAdvanced = val.isPlaying &&
                      !val.isBuffering &&
                      val.position > Duration.zero;
      }

      if (hasAdvanced && !_metrics.hasFirstFrame) {
        _metrics.markFirstFrame();
        _initialBufferingWatchdog?.cancel();
        debugPrint('[VOD PLAYER] [FRAME] Primeiro quadro / avanço efetivo de reprodução confirmado em ${PlaybackProgressService.formatDuration(val.position)}.');
      }

      if (val.isBuffering != _isBuffering) {
        debugPrint('[VOD PLAYER] [BUFFER] Estado de buffering alterado: ${val.isBuffering} (pos: ${PlaybackProgressService.formatDuration(val.position)})');
        if (val.isBuffering) {
          _metrics.markBufferingStart();
        } else {
          _metrics.markBufferingEnd();
        }
        setState(() => _isBuffering = val.isBuffering);
      }
    }
  }

  Future<void> _togglePlayPause() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (c.value.isPlaying) {
      await c.pause();
      await _saveCurrentProgress(); // Salva imediatamente ao pausar
    } else {
      await c.play();
    }
    setState(() {});
  }

  Future<void> _seekRelative(int seconds) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    final current = c.value.position;
    final total = c.value.duration;
    final target = current + Duration(seconds: seconds);

    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > total ? total : target);

    await c.seekTo(clamped);
    await _saveCurrentProgress();
    setState(() {});
  }

  Future<void> _seekToFraction(double fraction) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    final total = c.value.duration;
    final targetMs = (total.inMilliseconds * fraction).round();
    final target = Duration(milliseconds: targetMs);

    await c.seekTo(target);
    await _saveCurrentProgress();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: VodPlayerView(
          controller: _controller,
          title: widget.movie.name,
          coverUrl: widget.movie.streamIcon,
          isSeriesEpisode: false,
          fitMode: _fitMode,
          onFitModeChanged: (mode) => setState(() => _fitMode = mode),
          onTogglePlayPause: _togglePlayPause,
          onSeekRelative: _seekRelative,
          onSeekFraction: _seekToFraction,
          onBack: _handleExit,
          isLoading: _isLoading,
          isBuffering: _isBuffering,
          errorMessage: _errorMessage,
          onRetry: () {
            _currentUrlIndex = 0;
            _initPlayer();
          },
        ),
      ),
    );
  }
}
