import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../services/playback_metrics.dart';
import '../services/playback_progress_service.dart';
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
    if (_isSeekingToInitial && !force) return;

    final pos = c.value.position;
    final dur = c.value.duration;

    // Proteção: não sobrescrever posição anterior válida se o vídeo ainda não avançou
    if (pos.inSeconds < 5 && widget.initialPosition != null && widget.initialPosition!.inSeconds >= 10 && !force) {
      return;
    }

    if (dur > Duration.zero) {
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
    _streamUrls = widget.catalogService.buildSeriesStreamUrls(_currentEpisode);
    _currentUrlIndex = 0;
    _hasTriggeredCompletion = false;
    _cancelCountdown();

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
    debugPrint('[SERIES PLAYER] Conectando ao episódio: $sanitizedUrl');

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

      if (initialPosition != null && initialPosition > Duration.zero) {
        if (initialPosition < controller.value.duration) {
          _isSeekingToInitial = true;
          await controller.seekTo(initialPosition);
          _isSeekingToInitial = false;
          debugPrint('[SERIES PLAYER] Retomando reprodução em ${PlaybackProgressService.formatDuration(initialPosition)}');
        }
      }

      _startInitialBufferingWatchdog(epoch);
      await controller.play();

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
    final errLower = e.toString().toLowerCase();
    final isTimeout = e is TimeoutException || errLower.contains('timeoutexception');

    String userMessage;
    bool isResourceNotFound = false;

    if (isTimeout) {
      userMessage = 'O servidor demorou muito para responder (tempo limite de 25s excedido). Verifique sua conexão ou tente novamente.';
    } else if (errLower.contains('response code: 404') ||
               errLower.contains('code: 404') ||
               errLower.contains('404 not found')) {
      userMessage = 'Episódio não encontrado no servidor remoto (HTTP 404).';
      isResourceNotFound = true;
    } else if (errLower.contains('response code: 401') ||
               errLower.contains('response code: 403') ||
               errLower.contains('code: 401') ||
               errLower.contains('code: 403')) {
      userMessage = 'Acesso não autorizado pelo servidor ou limite de conexões simultâneas atingido (HTTP 401/403).';
    } else if (errLower.contains('response code: 5') ||
               errLower.contains('code: 500') ||
               errLower.contains('code: 502') ||
               errLower.contains('code: 503')) {
      userMessage = 'O servidor de transmissão apresentou instabilidade interna (HTTP 5xx). Tente novamente mais tarde.';
    } else if (errLower.contains('decoderinitializationexception') ||
               errLower.contains('mediacodec') ||
               errLower.contains('unrecognizedinputformat') ||
               errLower.contains('parserexception')) {
      userMessage = 'Formato de vídeo ou áudio do episódio não suportado pelo decodificador deste aparelho.';
      isResourceNotFound = true;
    } else if (errLower.contains('unknownhostexception') ||
               errLower.contains('connectexception') ||
               errLower.contains('socketexception') ||
               errLower.contains('network is unreachable') ||
               errLower.contains('httpdatasourceexception')) {
      userMessage = 'Falha de conexão com o servidor de streaming. Verifique sua conexão com a internet.';
    } else {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      userMessage = 'Não foi possível reproduzir o episódio. $safeErr';
    }

    _metrics.markError(userMessage);

    // REGRA 3: Não tentar outra extensão ou rota apenas porque houve timeout.
    // Tenta alternativa somente quando for falha comprovada de rota/recurso (ex: 404 ou formato não reconhecido)
    // e houver URL alternativa válida na lista.
    final canTryAlternative = isResourceNotFound && (_currentUrlIndex + 1 < _streamUrls.length);

    if (canTryAlternative) {
      _currentUrlIndex++;
      debugPrint('[SERIES PLAYER] Tentando URL de contingência $_currentUrlIndex devido a erro de recurso.');
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
          (_isLoading || _isBuffering || (c.value.position <= Duration.zero && !c.value.isPlaying))) {
        debugPrint('[SERIES PLAYER WATCHDOG] Tempo limite de buffer inicial excedido (25s sem reprodução).');
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
      final err = UrlSanitizer.sanitizeErrorMessage(c.value.errorDescription ?? 'Erro de mídia');
      _metrics.markError(err);
      if (_errorMessage == null) {
        setState(() {
          _errorMessage = err;
          _isLoading = false;
          _isBuffering = false;
        });
      }
      return;
    }

    if (c.value.isPlaying && c.value.position > Duration.zero) {
      _metrics.markFirstFrame();
      _initialBufferingWatchdog?.cancel();
    }

    final isBuff = c.value.isBuffering;
    if (isBuff != _isBuffering) {
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
