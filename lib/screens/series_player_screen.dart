import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../services/playback_metrics.dart';
import '../services/playback_progress_service.dart';
import '../services/player_diagnostics.dart';
import '../services/settings_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import '../widgets/live_player_view.dart';
import '../widgets/vod_player_view.dart';

/// Tela dedicada para reprodução de Episódios de Séries.
/// Gerencia o ciclo de vida do player, rotas de contingência, salvamento
/// de progresso isolado por conta, série e episódio, e transição para o
/// próximo episódio com contagem regressiva cancelável após conclusão normal.
class SeriesPlayerScreen extends StatefulWidget {
  final XtreamSeriesItem series;
  final XtreamSeriesInfo seriesInfo;
  final XtreamSeriesEpisode initialEpisode;
  final XtreamCatalogService catalogService;
  final String accountKey;
  final Duration? initialPosition;
  final VideoPlayerController? testController;

  const SeriesPlayerScreen({
    super.key,
    required this.series,
    required this.seriesInfo,
    required this.initialEpisode,
    required this.catalogService,
    required this.accountKey,
    this.initialPosition,
    this.testController,
  });

  @override
  State<SeriesPlayerScreen> createState() => _SeriesPlayerScreenState();
}

class _SeriesPlayerScreenState extends State<SeriesPlayerScreen> {
  late XtreamSeriesEpisode _currentEpisode;
  VideoPlayerController? _controller;
  final PlaybackProgressService _progressService = PlaybackProgressService();
  late PlaybackMetrics _metrics;

  bool _isLoading = true;
  bool _isBuffering = false;
  bool _isSeekingToInitial = false;
  bool _isExiting = false;
  String? _errorMessage;
  List<String> _streamUrls = [];
  int _currentUrlIndex = 0;

  Duration? _resumptionTarget;
  bool _seekAttempted = false;

  Timer? _progressSaveTimer;
  Timer? _initialBufferingWatchdog;
  int _connectionEpoch = 0;
  LiveVideoFitMode _fitMode = SettingsService.instance.defaultAspectRatio;

  // Controle de Próximo Episódio
  XtreamSeriesEpisode? _nextEpisode;
  int? _countdownSeconds;
  Timer? _countdownTimer;
  bool _hasTriggeredCompletion = false;

  @override
  void initState() {
    super.initState();
    _currentEpisode = widget.initialEpisode;
    _updateNextEpisode();

    DeviceUtils.setVideoOrientation();
    DeviceUtils.setKeepScreenOn(true);

    _metrics = PlaybackMetrics(
      mediaType: PlaybackMediaType.series,
      title: '${widget.series.name} - T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum}',
    );
    _metrics.markRequestStart();

    if (widget.testController != null) {
      _controller = widget.testController;
      _isLoading = false;
      _metrics.markPlayerInitialized();
      _metrics.markFirstFrame();
    } else {
      _initCurrentEpisode(initialPosition: widget.initialPosition);
    }

    _startPeriodicProgressSave();
  }

  @override
  void dispose() {
    DeviceUtils.setKeepScreenOn(false);
    _cancelCountdown();
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
    _cancelCountdown();
    _initialBufferingWatchdog?.cancel();
    _progressSaveTimer?.cancel();
    await _saveCurrentProgress(force: true);
    DeviceUtils.restoreOrientation();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _updateNextEpisode() {
    _nextEpisode = widget.seriesInfo.getNextEpisode(_currentEpisode);
  }

  void _startPeriodicProgressSave() {
    _progressSaveTimer?.cancel();
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

    // Proteção absoluta: NUNCA sobrescrever posição anterior válida se a reprodução atual ainda não avançou (menos de 5s).
    // Isso evita que um erro de buffer inicial ou encerramento rápido descarte o progresso salvo.
    if (widget.initialPosition != null &&
        widget.initialPosition!.inSeconds >= 10 &&
        pos.inSeconds < 5) {
      debugPrint('[SERIES PLAYER] [PROGRESSO] Preservando posição salva anterior (${PlaybackProgressService.formatDuration(widget.initialPosition!)}) pois reprodução atual não avançou (${PlaybackProgressService.formatDuration(pos)}).');
      return;
    }

    if (dur > Duration.zero && (pos.inSeconds >= 5 || force)) {
      debugPrint('[SERIES PLAYER] [PROGRESSO] Salvando progresso: ep=${_currentEpisode.id}, pos=${PlaybackProgressService.formatDuration(pos)}, dur=${PlaybackProgressService.formatDuration(dur)}');
      await _progressService.saveEpisodeProgress(
        accountKey: widget.accountKey,
        seriesId: widget.series.seriesId,
        episodeId: _currentEpisode.id,
        position: pos,
        duration: dur,
      );

      await _progressService.saveLastWatchedEpisode(
        accountKey: widget.accountKey,
        seriesId: widget.series.seriesId,
        episodeId: _currentEpisode.id,
        seasonNumber: _currentEpisode.seasonNumber,
        episodeNum: _currentEpisode.episodeNum,
      );

      await _progressService.saveContinueWatchingItem(
        accountKey: widget.accountKey,
        item: ContinueWatchingItem(
          streamId: _currentEpisode.id,
          seriesId: widget.series.seriesId,
          type: ContinueWatchingType.series,
          title: widget.series.name,
          subtitle: 'T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum} • ${_currentEpisode.title}',
          coverUrl: _currentEpisode.cover ?? widget.series.cover,
          position: pos,
          duration: dur,
          updatedAt: DateTime.now(),
          containerExtension: _currentEpisode.containerExtension,
          categoryId: widget.series.categoryId,
          seasonNumber: _currentEpisode.seasonNumber,
          episodeNum: _currentEpisode.episodeNum,
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
        await oldController.dispose();
      } catch (_) {}
    }
  }

  Future<void> _initCurrentEpisode({Duration? initialPosition}) async {
    _resumptionTarget = initialPosition;
    _seekAttempted = false;
    _streamUrls = widget.catalogService.buildSeriesStreamUrls(_currentEpisode);
    _currentUrlIndex = 0;
    _hasTriggeredCompletion = false;
    _cancelCountdown();

    debugPrint('[SERIES PLAYER] Início de fluxo: ID=${_currentEpisode.id}, T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum} ("${_currentEpisode.title}"), Série="${widget.series.name}" (seriesId=${widget.series.seriesId})');
    debugPrint('[SERIES PLAYER] Posição de retomada solicitada: ${initialPosition != null ? PlaybackProgressService.formatDuration(initialPosition) : 'Início (00:00)'}');

    if (_streamUrls.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Nenhum endereço de transmissão disponível para este episódio.';
      });
      return;
    }

    await _connectToUrl(_streamUrls[_currentUrlIndex], initialPosition: initialPosition);
  }

  Future<void> _connectToUrl(String url, {Duration? initialPosition}) async {
    final epoch = ++_connectionEpoch;
    await _disposeCurrentController();
    if (!mounted || epoch != _connectionEpoch) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isBuffering = false;
    });

    final sanitizedUrl = UrlSanitizer.sanitize(url);
    PlayerDiagnostics.log('REQUEST', 'Tipo=SERIE, ID=${_currentEpisode.id}, T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum} ("${_currentEpisode.title}"), Série="${widget.series.name}", Extensão="${_currentEpisode.containerExtension}", Rota=${_currentUrlIndex + 1}/${_streamUrls.length}');
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

    // Timeout de inicialização adequado para arquivos grandes de VOD/Séries (25 segundos)
    const timeoutDuration = Duration(seconds: 25);

    try {
      await controller.initialize().timeout(timeoutDuration);

      if (!mounted || epoch != _connectionEpoch || _controller != controller) return;

      _metrics.markConnectionEstablished();
      _metrics.markPlayerInitialized();

      final detectedDur = controller.value.duration;
      PlayerDiagnostics.log('STATE', 'STATE_READY | Duração: ${PlaybackProgressService.formatDuration(detectedDur)} | Resolução: ${controller.value.size.width.toInt()}x${controller.value.size.height.toInt()}');

      // 1. Inicia o watchdog de buffer inicial
      _startInitialBufferingWatchdog(epoch);

      // 2. Aciona play() para estabelecer o pipeline ativo de decodificação no ExoPlayer
      await controller.play();
      PlayerDiagnostics.log('PLAY', 'controller.play() acionado (playWhenReady=true)');

      // 3. Aplica o seekTo se houver posição salva válida para retomar
      if (initialPosition != null && initialPosition > Duration.zero) {
        Duration target = initialPosition;
        if (detectedDur > Duration.zero && target >= detectedDur) {
          final safeTarget = detectedDur - const Duration(seconds: 10);
          target = safeTarget > Duration.zero ? safeTarget : Duration.zero;
        }

        if (target > Duration.zero) {
          _isSeekingToInitial = true;
          _seekAttempted = true;
          debugPrint('[SERIES PLAYER] [SEEK] Disparando seekTo para ${PlaybackProgressService.formatDuration(target)} (posição salva: ${PlaybackProgressService.formatDuration(initialPosition)})...');
          try {
            await controller.seekTo(target);
            debugPrint('[SERIES PLAYER] [SEEK] seekTo concluído com sucesso para ${PlaybackProgressService.formatDuration(target)}.');
          } catch (seekError) {
            debugPrint('[SERIES PLAYER] [SEEK] Aviso: falha ao buscar ponto salvo ($seekError). Reproduzindo do início.');
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
      await _handleConnectionError(e, epoch: epoch, initialPosition: initialPosition);
    }
  }

  Future<void> _handleConnectionError(
    Object e, {
    required int epoch,
    Duration? initialPosition,
  }) async {
    // Sondagem HTTP diagnóstica imediata para identificar com precisão o status do servidor
    final probe = await PlayerDiagnostics.probeStreamUrl(_streamUrls[_currentUrlIndex]);
    final details = PlayerDiagnostics.analyzeError(e, probe: probe);

    PlayerDiagnostics.log('ERROR', 'Falha na reprodução do episódio: ${details.technicalSummary}');
    PlayerDiagnostics.logDiagnosticDetails(details);
    PlayerDiagnostics.log('ERROR_CODE', '${details.errorCode ?? 'N/D'}');
    PlayerDiagnostics.log('ERROR_NAME', details.errorCodeName ?? 'N/D');
    PlayerDiagnostics.log('CAUSE', '${details.causeClass ?? 'N/D'}: ${details.causeMessage ?? 'N/D'}');
    if (probe.statusCode != null) {
      PlayerDiagnostics.log('HTTP_STATUS', '${probe.statusCode} | Content-Type: ${probe.contentType ?? 'N/D'}');
    }

    final userMessage = details.shortUiMessage;
    _metrics.markError(userMessage);

    // REGRA 3: Não tentar outra extensão ou rota apenas porque houve timeout.
    // Tenta alternativa somente quando for falha comprovada de rota/recurso (ex: 404 ou formato não reconhecido)
    // e houver URL alternativa válida na lista.
    final isResourceNotFound = probe.isNotFound ||
        details.exoPlayerHttpStatus == 404 ||
        details.probeHttpStatus == 404 ||
        details.shortUiMessage.contains('404') ||
        details.shortUiMessage.contains('não encontrado') ||
        (details.errorCodeName == 'ERROR_CODE_PARSER_BAD_MEDIA_MANIFEST' ||
         details.causeClass?.contains('Decoder') == true);

    final canTryAlternative = isResourceNotFound && (_currentUrlIndex + 1 < _streamUrls.length);

    if (canTryAlternative) {
      _currentUrlIndex++;
      PlayerDiagnostics.log('RETRY_ROUTE', 'Tentando URL de contingência $_currentUrlIndex devido a erro de recurso.');
      await _connectToUrl(_streamUrls[_currentUrlIndex], initialPosition: initialPosition);
    } else {
      setState(() {
        _isLoading = false;
        _isBuffering = false;
        _errorMessage = userMessage;
      });
    }
  }

  void _startInitialBufferingWatchdog(int epoch) {
    _initialBufferingWatchdog?.cancel();
    _initialBufferingWatchdog = Timer(const Duration(seconds: 25), () {
      if (!mounted || epoch != _connectionEpoch) return;
      final c = _controller;
      if (c != null &&
          !_metrics.hasFirstFrame &&
          (_isLoading || _isBuffering || (c.value.position <= Duration.zero && !c.value.isPlaying) || (_seekAttempted && c.value.isBuffering))) {
        debugPrint('[SERIES PLAYER WATCHDOG] Tempo limite de buffer inicial excedido (25s sem reprodução). Pos: ${c.value.position}, isPlaying: ${c.value.isPlaying}, isBuffering: ${c.value.isBuffering}');
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

    // Se houver erro, cancela qualquer contagem regressiva e interrompe avanço automático
    if (c.value.hasError) {
      _cancelCountdown();
      _initialBufferingWatchdog?.cancel();
      final details = PlayerDiagnostics.analyzeError(c.value.errorDescription ?? 'Erro interno de reprodução');
      PlayerDiagnostics.log('ERROR', 'Controller disparou erro durante reprodução do episódio: ${details.technicalSummary}');
      PlayerDiagnostics.logDiagnosticDetails(details);
      PlayerDiagnostics.log('ERROR_NAME', details.errorCodeName ?? 'N/D');
      PlayerDiagnostics.log('CAUSE', '${details.causeClass ?? 'N/D'}: ${details.causeMessage ?? 'N/D'}');
      PlayerDiagnostics.log('STATE', 'hasError=true, pos=${c.value.position}, isPlaying=${c.value.isPlaying}, isBuffering=${c.value.isBuffering}');
      _metrics.markError(details.shortUiMessage);

      final isResourceNotFound = details.exoPlayerHttpStatus == 404 ||
          details.shortUiMessage.contains('404') ||
          details.shortUiMessage.contains('não encontrado') ||
          details.errorCodeName == 'ERROR_CODE_PARSER_BAD_MEDIA_MANIFEST' ||
          details.causeClass?.contains('Decoder') == true;

      if (!_isExiting && isResourceNotFound && (_currentUrlIndex + 1 < _streamUrls.length)) {
        PlayerDiagnostics.log('RETRY_ROUTE', 'Erro no controller; tentando URL de contingência ${_currentUrlIndex + 1}.');
        _handleConnectionError(c.value.errorDescription ?? 'Erro do player', epoch: _connectionEpoch, initialPosition: c.value.position);
        return;
      }

      if (_errorMessage == null) {
        setState(() {
          _errorMessage = details.shortUiMessage;
          _isLoading = false;
          _isBuffering = false;
        });
      }
      return;
    }

    // Validação segura de avanço real de reprodução / primeiro quadro
    bool hasAdvanced = false;
    if (_seekAttempted && _resumptionTarget != null && _resumptionTarget! > Duration.zero) {
      // Quando houve seek para posição salva, a confirmação exige que a reprodução
      // esteja ativa, sem buffering, e que a posição alcance ou avance em relação ao alvo
      hasAdvanced = c.value.isPlaying &&
                    !c.value.isBuffering &&
                    !_isSeekingToInitial &&
                    c.value.position >= _resumptionTarget!;
    } else {
      hasAdvanced = c.value.isPlaying &&
                    !c.value.isBuffering &&
                    c.value.position > Duration.zero;
    }

    if (hasAdvanced && !_metrics.hasFirstFrame) {
      _metrics.markFirstFrame();
      _initialBufferingWatchdog?.cancel();
      debugPrint('[SERIES PLAYER] [FRAME] Primeiro quadro / avanço efetivo de reprodução confirmado em ${PlaybackProgressService.formatDuration(c.value.position)}.');
    }

    final isBuff = c.value.isBuffering;
    if (isBuff != _isBuffering) {
      debugPrint('[SERIES PLAYER] [BUFFER] Estado de buffering alterado: $isBuff (pos: ${PlaybackProgressService.formatDuration(c.value.position)})');
      if (isBuff) {
        _metrics.markBufferingStart();
      } else {
        _metrics.markBufferingEnd();
      }
      setState(() => _isBuffering = isBuff);
    }

    // Regra 3: O avanço automático só pode ocorrer após a conclusão NORMAL do episódio.
    // Falhas de rede ou reprodução não podem disparar o próximo episódio.
    if (!_hasTriggeredCompletion &&
        c.value.isInitialized &&
        !c.value.isPlaying &&
        _errorMessage == null &&
        !_isLoading &&
        !_isBuffering &&
        c.value.duration > Duration.zero) {
      final pos = c.value.position;
      final dur = c.value.duration;

      // Conclusão normal: posição próxima ao fim (faltam menos de 2s ou atingiu dur)
      final remaining = dur.inSeconds - pos.inSeconds;
      if (remaining <= 2 && pos.inSeconds > 10) {
        _hasTriggeredCompletion = true;
        _saveCurrentProgress();

        if (_nextEpisode != null && SettingsService.instance.enableAutoPlayNextEpisode) {
          _startNextEpisodeCountdown();
        }
      }
    }
  }

  void _startNextEpisodeCountdown() {
    _cancelCountdown();
    setState(() {
      _countdownSeconds = 5;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        if (_countdownSeconds != null && _countdownSeconds! > 1) {
          _countdownSeconds = _countdownSeconds! - 1;
        } else {
          _cancelCountdown();
          _playNextEpisode();
        }
      });
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (mounted && _countdownSeconds != null) {
      setState(() {
        _countdownSeconds = null;
      });
    }
  }

  void _playNextEpisode() {
    if (_nextEpisode == null) return;
    _cancelCountdown();
    _saveCurrentProgress();

    setState(() {
      _currentEpisode = _nextEpisode!;
      _updateNextEpisode();
    });

    _initCurrentEpisode();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (c.value.isPlaying) {
      c.pause();
      _saveCurrentProgress();
    } else {
      // Se estava em contagem regressiva, cancela ao despausar
      _cancelCountdown();
      c.play();
    }
    setState(() {});
  }

  void _seekRelative(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    _cancelCountdown();
    final newPos = c.value.position + Duration(seconds: seconds);
    final clamped = Duration(
      milliseconds: newPos.inMilliseconds.clamp(0, c.value.duration.inMilliseconds),
    );
    c.seekTo(clamped);
    _saveCurrentProgress();
  }

  void _seekFraction(double fraction) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    _cancelCountdown();
    final targetMs = (fraction * c.value.duration.inMilliseconds).round();
    c.seekTo(Duration(milliseconds: targetMs));
    _saveCurrentProgress();
  }

  String get _displayTitle {
    final seasonStr = 'T${_currentEpisode.seasonNumber}';
    final epStr = 'E${_currentEpisode.episodeNum}';
    return '${widget.series.name} • $seasonStr:$epStr - ${_currentEpisode.title}';
  }

  String? get _nextEpisodeDisplayTitle {
    if (_nextEpisode == null) return null;
    final seasonStr = 'T${_nextEpisode!.seasonNumber}';
    final epStr = 'E${_nextEpisode!.episodeNum}';
    return '$seasonStr:$epStr - ${_nextEpisode!.title}';
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
        body: SafeArea(
          top: false,
          bottom: false,
          left: false,
          right: false,
          child: VodPlayerView(
            controller: _controller,
            title: _displayTitle,
            coverUrl: _currentEpisode.cover ?? widget.series.cover,
            badgeText: 'SÉRIE',
            loadingMessage: 'Carregando episódio...',
            fitMode: _fitMode,
            onFitModeChanged: (mode) => setState(() => _fitMode = mode),
            onTogglePlayPause: _togglePlayPause,
            onSeekRelative: _seekRelative,
            onSeekFraction: _seekFraction,
            onBack: _handleExit,
            onNextEpisode: _nextEpisode != null ? _playNextEpisode : null,
            nextEpisodeTitle: _nextEpisodeDisplayTitle,
            nextEpisodeCountdown: _countdownSeconds,
            onCancelNextEpisode: _cancelCountdown,
            onPlayNextEpisodeNow: _playNextEpisode,
            isLoading: _isLoading,
            isBuffering: _isBuffering,
            errorMessage: _errorMessage,
            onRetry: () => _initCurrentEpisode(),
          ),
        ),
      ),
    );
  }
}
