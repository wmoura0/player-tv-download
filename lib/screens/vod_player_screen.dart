import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../services/cloud_progress_sync_service.dart';
import '../services/playback_metrics.dart';
import '../services/playback_progress_service.dart';
import '../services/player_diagnostics.dart';
import '../services/settings_service.dart';
import '../services/smart_source_resolver.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
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
  final XtreamCatalogService? catalogService;

  const VodPlayerScreen({
    super.key,
    required this.movie,
    required this.streamUrls,
    required this.accountKey,
    this.initialPosition,
    this.testController,
    this.catalogService,
  });

  @override
  State<VodPlayerScreen> createState() => _VodPlayerScreenState();
}

class _VodPlayerScreenState extends State<VodPlayerScreen>
    with WidgetsBindingObserver {
  late XtreamVodStream _currentMovie;
  late List<String> _streamUrls;
  VideoPlayerController? _controller;
  final PlaybackProgressService _progressService = PlaybackProgressService();
  late final PlaybackMetrics _metrics;

  bool _isLoading = true;
  bool _isBuffering = false;
  bool _isSeekingToInitial = false;
  bool _isExiting = false;
  String? _errorMessage;
  String? _smartSourceStatusMessage;
  bool _smartSourceAttempted = false;
  int _currentUrlIndex = 0;
  Timer? _initialBufferingWatchdog;
  int _connectionEpoch = 0;

  Duration? _resumptionTarget;
  bool _seekAttempted = false;
  Timer? _postPlaySeekTimer;
  bool _postPlaySeekFallbackDone = false;
  bool _wasControllerPlaying = false;
  bool _isHandlingError = false;
  bool _forceAwaitDispose = false;
  bool _isInitializingController = false;

  Timer? _progressSaveTimer;
  LiveVideoFitMode _fitMode = SettingsService.instance.defaultAspectRatio;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeviceUtils.isPipMode.addListener(_onPipModeChanged);
    _currentMovie = widget.movie;
    _streamUrls = List<String>.from(widget.streamUrls);
    DeviceUtils.setVideoOrientation();
    DeviceUtils.setKeepScreenOn(true, force: true);

    _resumptionTarget = widget.initialPosition;
    _seekAttempted = false;

    _metrics = PlaybackMetrics(
      mediaType: PlaybackMediaType.movie,
      title: _currentMovie.name,
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

  void _onPipModeChanged() {
    if (!mounted) return;
    final inPip = DeviceUtils.isPipMode.value;
    if (!inPip) {
      DeviceUtils.setVideoOrientation();
      if (_isLoading || (_controller?.value.isPlaying ?? false)) {
        DeviceUtils.setKeepScreenOn(true, force: true);
      }
    }
    setState(() {});
  }

  void _syncPipState(bool enabled) {
    if (DeviceUtils.isTv) return;
    if (!enabled) {
      DeviceUtils.setPipState(enabled: false);
      return;
    }
    final sz = _controller?.value.size ?? Size.zero;
    final w = sz.width.round();
    final h = sz.height.round();
    final aspectNum = (w > 0 && h > 0) ? w : 16;
    final aspectDen = (w > 0 && h > 0) ? h : 9;
    DeviceUtils.setPipState(
      enabled: true,
      aspectNumerator: aspectNum,
      aspectDenominator: aspectDen,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _saveCurrentProgress(force: true);
      return;
    }

    if (state == AppLifecycleState.paused) {
      unawaited(_handleBackgroundLifecycle());
    } else if (state == AppLifecycleState.resumed) {
      if (mounted && (_isLoading || (_controller?.value.isPlaying ?? false))) {
        DeviceUtils.setKeepScreenOn(true, force: true);
      }
    } else if (state == AppLifecycleState.detached) {
      _saveCurrentProgress(force: true);
      _disposeCurrentController();
    }
  }

  Future<void> _handleBackgroundLifecycle() async {
    await _saveCurrentProgress(force: true);
    if (widget.accountKey.trim().isNotEmpty) {
      unawaited(
        CloudProgressSyncService.instance.syncAccount(
          widget.accountKey,
          progressService: _progressService,
          force: true,
        ),
      );
    }
    if (DeviceUtils.isPipMode.value || DeviceUtils.isMultiWindowMode.value) {
      return;
    }
    if (await DeviceUtils.isInMultiWindowOrPip()) {
      return;
    }
    if (!mounted || _isExiting) return;
    final currentLifecycle = WidgetsBinding.instance.lifecycleState;
    if (currentLifecycle != null && currentLifecycle != AppLifecycleState.paused) {
      return;
    }
    final c = _controller;
    if (c != null && c.value.isInitialized && c.value.isPlaying) {
      await c.pause();
      _syncPipState(false);
      DeviceUtils.setKeepScreenOn(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeviceUtils.isPipMode.removeListener(_onPipModeChanged);
    _syncPipState(false);
    DeviceUtils.setKeepScreenOn(false);
    _postPlaySeekTimer?.cancel();
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
    _postPlaySeekTimer?.cancel();
    _initialBufferingWatchdog?.cancel();
    _progressSaveTimer?.cancel();
    _syncPipState(false);
    DeviceUtils.setKeepScreenOn(false);
    await _saveCurrentProgress(force: true);
    if (widget.accountKey.trim().isNotEmpty) {
      unawaited(
        CloudProgressSyncService.instance.syncAccount(
          widget.accountKey,
          progressService: _progressService,
          force: true,
        ),
      );
    }
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
    final resumptionRef = _resumptionTarget ?? widget.initialPosition;
    if (resumptionRef != null &&
        resumptionRef.inSeconds >= 10 &&
        pos.inSeconds < 5) {
      debugPrint('[VOD PLAYER] [PROGRESSO] Preservando posição salva anterior (${PlaybackProgressService.formatDuration(resumptionRef)}) pois reprodução atual não avançou (${PlaybackProgressService.formatDuration(pos)}).');
      return;
    }

    if (dur > Duration.zero && (pos.inSeconds >= 5 || force)) {
      debugPrint('[VOD PLAYER] [PROGRESSO] Salvando progresso: streamId=${_currentMovie.streamId}, pos=${PlaybackProgressService.formatDuration(pos)}, dur=${PlaybackProgressService.formatDuration(dur)}');
      await _progressService.saveProgress(
        accountKey: widget.accountKey,
        streamId: _currentMovie.streamId,
        position: pos,
        duration: dur,
      );

      await _progressService.saveContinueWatchingItem(
        accountKey: widget.accountKey,
        item: ContinueWatchingItem(
          streamId: _currentMovie.streamId,
          type: ContinueWatchingType.movie,
          title: _currentMovie.name,
          coverUrl: _currentMovie.streamIcon,
          position: pos,
          duration: dur,
          updatedAt: DateTime.now(),
          containerExtension: _currentMovie.containerExtension,
          categoryId: _currentMovie.categoryId,
        ),
      );
    }
  }

  Future<void> _disposeCurrentController() async {
    _postPlaySeekTimer?.cancel();
    _postPlaySeekTimer = null;
    _initialBufferingWatchdog?.cancel();
    _syncPipState(false);
    _isInitializingController = false;
    final shouldAwaitDispose = _forceAwaitDispose;
    _forceAwaitDispose = false;
    final oldController = _controller;
    _controller = null;
    if (oldController != null) {
      oldController.removeListener(_onControllerUpdate);
      try {
        if (oldController.value.isInitialized && oldController.value.isPlaying) {
          await oldController.pause().timeout(
            const Duration(milliseconds: 250),
            onTimeout: () {},
          );
        }
      } catch (_) {}
      final nativePlayerCreated = oldController.value.isInitialized ||
          oldController.value.hasError ||
          shouldAwaitDispose;
      if (nativePlayerCreated) {
        try {
          await oldController.dispose().timeout(
            const Duration(milliseconds: 600),
            onTimeout: () {},
          );
        } catch (_) {}
      } else {
        try {
          unawaited(oldController.dispose().catchError((_) {}));
        } catch (_) {}
      }
    }
  }

  Future<void> _initPlayer() async {
    _resumptionTarget ??= widget.initialPosition;
    _seekAttempted = false;
    _smartSourceAttempted = false;
    _smartSourceStatusMessage = null;

    if (_streamUrls.isEmpty && widget.catalogService != null) {
      _streamUrls = widget.catalogService!.buildVodStreamUrls(_currentMovie);
    }

    debugPrint('[VOD PLAYER] Início de fluxo: streamId=${_currentMovie.streamId}, título="${_currentMovie.name}"');
    debugPrint('[VOD PLAYER] Posição de retomada solicitada: ${_resumptionTarget != null ? PlaybackProgressService.formatDuration(_resumptionTarget!) : 'Início (00:00)'}');

    if (_streamUrls.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Nenhum endereço de transmissão disponível para este filme.';
      });
      return;
    }

    await _connectToUrl(_streamUrls[_currentUrlIndex]);
  }

  Future<void> _connectToUrl(String url) async {
    final epoch = ++_connectionEpoch;
    _isHandlingError = false;
    _postPlaySeekTimer?.cancel();
    _postPlaySeekTimer = null;
    _postPlaySeekFallbackDone = false;
    _wasControllerPlaying = false;
    await _disposeCurrentController();
    if (!mounted || epoch != _connectionEpoch) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isBuffering = false;
    });

    final sanitizedUrl = UrlSanitizer.sanitize(url);
    PlayerDiagnostics.log('REQUEST', 'Tipo=FILME, ID=${_currentMovie.streamId}, Nome="${_currentMovie.name}", Extensão="${_currentMovie.containerExtension}", Rota=${_currentUrlIndex + 1}/${_streamUrls.length}');
    PlayerDiagnostics.log('MEDIA_ITEM', 'URL: $sanitizedUrl');
    PlayerDiagnostics.log('PREPARE', 'Iniciando controller.initialize() [timeout=25s]');

    final uri = Uri.parse(url);
    final controller = VideoPlayerController.networkUrl(
      uri,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
      httpHeaders: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
      },
    );

    _controller = controller;
    controller.addListener(_onControllerUpdate);

    // Timeout de inicialização adequado para arquivos grandes de VOD (25 segundos)
    const timeoutDuration = Duration(seconds: 25);

    try {
      _isInitializingController = true;
      try {
        await controller.initialize().timeout(timeoutDuration);
      } finally {
        if (_controller == controller) {
          _isInitializingController = false;
        }
      }

      if (!mounted || epoch != _connectionEpoch || _controller != controller) return;

      // Atualiza extensão real conectada para futuras retomadas na Home
      final pathPart = Uri.tryParse(url)?.path ?? url;
      final extMatch = RegExp(r'\.(mp4|mkv|ts|avi|m3u8)$', caseSensitive: false).firstMatch(pathPart);
      if (extMatch != null) {
        final activeExt = extMatch.group(1)!.toLowerCase();
        if (_currentMovie.containerExtension != activeExt) {
          _currentMovie = _currentMovie.copyWith(containerExtension: activeExt);
        }
      }

      _metrics.markConnectionEstablished();
      _metrics.markPlayerInitialized();

      final detectedDur = controller.value.duration;
      PlayerDiagnostics.log('STATE', 'STATE_READY | Duração: ${PlaybackProgressService.formatDuration(detectedDur)} | Resolução: ${controller.value.size.width.toInt()}x${controller.value.size.height.toInt()}');

      // 1. Inicia watchdog de buffer inicial
      _startInitialBufferingWatchdog(epoch);

      // 2. Aplica seekTo ANTES de play() quando há retomada para evitar duplo buffering no ExoPlayer
      Duration effectiveTarget = Duration.zero;
      final effectiveInitialPos = _resumptionTarget ?? widget.initialPosition;
      if (effectiveInitialPos != null && effectiveInitialPos > Duration.zero) {
        Duration target = effectiveInitialPos;
        if (detectedDur > Duration.zero && target >= detectedDur) {
          final safeTarget = detectedDur - const Duration(seconds: 10);
          target = safeTarget > Duration.zero ? safeTarget : Duration.zero;
        }
        _resumptionTarget = target;
        effectiveTarget = target;

        if (target > Duration.zero) {
          _isSeekingToInitial = true;
          _seekAttempted = true;
          debugPrint('[VOD PLAYER] [SEEK] Disparando seekTo para ${PlaybackProgressService.formatDuration(target)} (posição salva: ${PlaybackProgressService.formatDuration(effectiveInitialPos)})...');
          try {
            await controller.seekTo(target).timeout(const Duration(seconds: 6));
            debugPrint('[VOD PLAYER] [SEEK] seekTo concluído com sucesso para ${PlaybackProgressService.formatDuration(target)}.');
          } catch (seekError) {
            debugPrint('[VOD PLAYER] [SEEK] Aviso: erro no seek inicial ($seekError). Reproduzindo do início.');
          } finally {
            _isSeekingToInitial = false;
          }
        }
      }

      // 3. Aciona play() após posicionar o cursor inicial
      await controller.play();
      if (!mounted || epoch != _connectionEpoch || _controller != controller) return;
      PlayerDiagnostics.log('PLAY', 'controller.play() acionado (playWhenReady=true)');

      _syncPipState(true);
      DeviceUtils.setKeepScreenOn(true, force: true);

      if (effectiveTarget.inSeconds >= 10) {
        _postPlaySeekTimer?.cancel();
        _postPlaySeekTimer = Timer(const Duration(milliseconds: 800), () {
          if (!mounted || epoch != _connectionEpoch || _controller != controller) return;
          unawaited(_applyPostPlaySeekFallbackIfNeeded(controller, effectiveTarget, epoch));
        });
      }

      if (mounted && epoch == _connectionEpoch && _controller == controller) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (!mounted ||
          epoch != _connectionEpoch ||
          _controller != controller ||
          _isHandlingError) {
        return;
      }
      _isHandlingError = true;
      _forceAwaitDispose = e is TimeoutException;
      await _handleConnectionError(e, epoch: epoch);
    }
  }

  Future<void> _applyPostPlaySeekFallbackIfNeeded(
    VideoPlayerController controller,
    Duration target,
    int epoch,
  ) async {
    if (_postPlaySeekFallbackDone ||
        !mounted ||
        epoch != _connectionEpoch ||
        _controller != controller) {
      return;
    }
    final val = controller.value;
    if (val.isInitialized && val.isPlaying && val.position.inSeconds < 3 && !_isSeekingToInitial) {
      _postPlaySeekFallbackDone = true;
      _isSeekingToInitial = true;
      debugPrint('[VOD PLAYER] [SEEK FALLBACK] Posição reiniciada em ${PlaybackProgressService.formatDuration(val.position)}; reaplicando seek para ${PlaybackProgressService.formatDuration(target)}...');
      try {
        await controller.seekTo(target).timeout(const Duration(seconds: 4));
      } catch (_) {
      } finally {
        _isSeekingToInitial = false;
      }
    }
  }

  Future<void> _handleConnectionError(Object e, {required int epoch}) async {
    if (!mounted || epoch != _connectionEpoch || _isExiting) return;

    final quickDetails = PlayerDiagnostics.analyzeError(e);

    final isPluginUnavailable =
        e is UnimplementedError || e.toString().contains('MissingPluginException');
    final isTimeout = e is TimeoutException ||
        quickDetails.causeClass == 'TimeoutException' ||
        quickDetails.shortUiMessage.contains('Timeout');
    final isAuthOrForbidden = quickDetails.isAuthOrForbidden;

    PlayerDiagnostics.logDiagnosticDetails(quickDetails);

    if (isPluginUnavailable) {
      await _disposeCurrentController();
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;
      _metrics.markError(quickDetails.shortUiMessage);
      setState(() {
        _isLoading = false;
        _isBuffering = false;
        _smartSourceStatusMessage = null;
        _errorMessage = quickDetails.shortUiMessage;
      });
      return;
    }

    final canTryAlternative = !isAuthOrForbidden &&
        !isTimeout &&
        (_currentUrlIndex + 1 < _streamUrls.length);

    if (canTryAlternative) {
      _currentUrlIndex++;
      PlayerDiagnostics.log(
        'RETRY_ROUTE',
        'Tentando rota de contingência index $_currentUrlIndex devido a erro: ${quickDetails.technicalSummary}',
      );

      await _disposeCurrentController();
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;

      await _connectToUrl(_streamUrls[_currentUrlIndex]);
      return;
    }

    // Recuperação inteligente de filme via SmartSourceResolver (descobre extensão via get_vod_info ou filme reindexado)
    if (!_smartSourceAttempted &&
        widget.catalogService != null &&
        SettingsService.instance.enableSmartSource &&
        !isAuthOrForbidden &&
        !isTimeout) {
      _smartSourceAttempted = true;
      await _disposeCurrentController();
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;

      setState(() {
        _isLoading = true;
        _smartSourceStatusMessage = 'Recuperando fonte do filme (Smart Source)...';
      });

      PlayerDiagnostics.log('SMART_SOURCE', 'Iniciando resolução inteligente VOD para "${_currentMovie.name}" (streamId=${_currentMovie.streamId}).');
      final result = await SmartSourceResolver.instance.resolveBestVodSource(
        catalogService: widget.catalogService!,
        movie: _currentMovie,
        onProgressMessage: (msg) {
          if (mounted && epoch == _connectionEpoch) {
            setState(() => _smartSourceStatusMessage = msg);
          }
        },
      );

      if (!mounted || epoch != _connectionEpoch || _isExiting) return;

      if (result.isSuccess && result.workingUrl != null) {
        setState(() {
          _smartSourceStatusMessage = null;
        });

        final recoveredId = (result.recoveredSeriesId != null && result.recoveredSeriesId! > 0)
            ? result.recoveredSeriesId!
            : _currentMovie.streamId;
        final recoveredExt = result.containerExtension ?? _currentMovie.containerExtension;

        if (recoveredId != _currentMovie.streamId || recoveredExt != _currentMovie.containerExtension) {
          _currentMovie = _currentMovie.copyWith(
            streamId: recoveredId,
            containerExtension: recoveredExt,
          );
          final posToKeep = _resumptionTarget ?? widget.initialPosition ?? Duration.zero;
          if (posToKeep.inSeconds >= 10) {
            unawaited(
              _progressService.saveContinueWatchingItem(
                accountKey: widget.accountKey,
                item: ContinueWatchingItem(
                  streamId: _currentMovie.streamId,
                  type: ContinueWatchingType.movie,
                  title: _currentMovie.name,
                  coverUrl: _currentMovie.streamIcon,
                  position: posToKeep,
                  duration: const Duration(hours: 2),
                  updatedAt: DateTime.now(),
                  containerExtension: _currentMovie.containerExtension,
                  categoryId: _currentMovie.categoryId,
                ),
              ),
            );
          }
        }

        PlayerDiagnostics.log('SMART_SOURCE', 'Fonte VOD resolvida com sucesso: ${UrlSanitizer.sanitize(result.workingUrl!)}');
        await Future.delayed(const Duration(milliseconds: 350));
        if (!mounted || epoch != _connectionEpoch || _isExiting) return;
        await _connectToUrl(result.workingUrl!);
        return;
      }

      final failureMsg = result.diagnosticMessage ?? quickDetails.shortUiMessage;
      _metrics.markError(failureMsg);
      setState(() {
        _isLoading = false;
        _isBuffering = false;
        _smartSourceStatusMessage = null;
        _errorMessage = failureMsg;
      });
      return;
    }

    await _disposeCurrentController();
    if (!mounted || epoch != _connectionEpoch || _isExiting) return;

    final probe = _streamUrls.isNotEmpty
        ? await PlayerDiagnostics.probeStreamUrl(_streamUrls[_currentUrlIndex.clamp(0, _streamUrls.length - 1)])
        : const HttpProbeResult(elapsedMs: 0);
    if (!mounted || epoch != _connectionEpoch || _isExiting) return;
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
      _smartSourceStatusMessage = null;
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

    // Erros durante controller.initialize() são tratados pelo try/catch de _connectToUrl
    if (_isInitializingController) return;

    if (val.hasError) {
      if (_isHandlingError || _errorMessage != null) return;
      _isHandlingError = true;
      c.removeListener(_onControllerUpdate);
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

      if (!_isExiting && !isAuthOrForbidden && !isTimeout) {
        if (_currentUrlIndex + 1 < _streamUrls.length) {
          PlayerDiagnostics.log('RETRY_ROUTE', 'Erro assíncrono no controller do filme; tentando URL de contingência ${_currentUrlIndex + 1}.');
        }
        _handleConnectionError(errorDesc, epoch: _connectionEpoch);
        return;
      }

      setState(() {
        _errorMessage = details.shortUiMessage;
        _isLoading = false;
        _isBuffering = false;
      });
    } else if (!val.isInitialized) {
      return;
    } else {
      // Confirmação segura de primeiro quadro / avanço real de reprodução
      bool hasAdvanced = false;
      if (_seekAttempted && _resumptionTarget != null && _resumptionTarget! > Duration.zero) {
        final minExpectedPos = _resumptionTarget! > const Duration(seconds: 12)
            ? _resumptionTarget! - const Duration(seconds: 12)
            : Duration.zero;
        hasAdvanced = val.isPlaying &&
                      !val.isBuffering &&
                      !_isSeekingToInitial &&
                      val.position >= minExpectedPos &&
                      val.position > Duration.zero;
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

      if (val.isPlaying != _wasControllerPlaying) {
        _wasControllerPlaying = val.isPlaying;
        if (val.isPlaying) {
          _syncPipState(true);
          DeviceUtils.setKeepScreenOn(true, force: true);
        }
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
      _syncPipState(false);
      await _saveCurrentProgress(); // Salva imediatamente ao pausar
    } else {
      await c.play();
      _syncPipState(true);
      DeviceUtils.setKeepScreenOn(true, force: true);
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: VodPlayerView(
        controller: _controller,
        title: _currentMovie.name,
        coverUrl: _currentMovie.streamIcon,
        isSeriesEpisode: false,
        loadingMessage: _smartSourceStatusMessage ?? 'Carregando filme...',
        fitMode: _fitMode,
        onFitModeChanged: (mode) => setState(() => _fitMode = mode),
        onTogglePlayPause: _togglePlayPause,
        onSeekRelative: _seekRelative,
        onSeekFraction: _seekToFraction,
        onBack: _handleExit,
        isLoading: _isLoading || _smartSourceStatusMessage != null,
        isBuffering: _isBuffering,
        errorMessage: _errorMessage,
        onRetry: () {
          _currentUrlIndex = 0;
          _smartSourceAttempted = false;
          _smartSourceStatusMessage = null;
          _resumptionTarget ??= widget.initialPosition;
          _initPlayer();
        },
      ),
    );
  }
}
