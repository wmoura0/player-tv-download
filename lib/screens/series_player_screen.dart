import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../services/cloud_progress_sync_service.dart';
import '../services/playback_metrics.dart';
import '../services/playback_progress_service.dart';
import '../services/player_diagnostics.dart';
import '../services/series_identity_verifier.dart';
import '../services/settings_service.dart';
import '../services/smart_source_resolver.dart';
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
  final bool seriesInfoIsFresh;

  const SeriesPlayerScreen({
    super.key,
    required this.series,
    required this.seriesInfo,
    required this.initialEpisode,
    required this.catalogService,
    required this.accountKey,
    this.initialPosition,
    this.testController,
    this.seriesInfoIsFresh = false,
  });

  @override
  State<SeriesPlayerScreen> createState() => _SeriesPlayerScreenState();
}

class _SeriesPlayerScreenState extends State<SeriesPlayerScreen>
    with WidgetsBindingObserver {
  late int _activeSeriesId;
  late XtreamSeriesInfo _currentSeriesInfo;
  late XtreamSeriesEpisode _currentEpisode;
  VideoPlayerController? _controller;
  final PlaybackProgressService _progressService = PlaybackProgressService();
  late PlaybackMetrics _metrics;

  bool _isLoading = true;
  bool _isBuffering = false;
  bool _isSeekingToInitial = false;
  bool _isExiting = false;
  String? _errorMessage;
  String? _smartSourceStatusMessage;
  bool _smartSourceAttempted = false;
  List<String> _streamUrls = [];
  int _currentUrlIndex = 0;

  Duration? _resumptionTarget;
  bool _seekAttempted = false;
  Timer? _postPlaySeekTimer;
  bool _postPlaySeekFallbackDone = false;
  bool _wasControllerPlaying = false;
  Future<void>? _hydrationFuture;
  final Set<String> _failedStreamUrls = {};

  int _streamUrlsSourceEpisodeId = 0;
  int? _streamUrlsSourceAltId;
  String? _streamUrlsSourceExt;
  String? _streamUrlsSourceDirect;
  bool _hydratedRetryAttempted = false;
  bool _transient403RetryAttempted = false;
  bool _smartSourceConnectRetryAttempted = false;
  bool _autoSessionReloadAttempted = false;
  String? _smartSourceResolvedUrl;
  bool _isHandlingError = false;
  bool _forceAwaitDispose = false;
  bool _isInitializingController = false;

  Timer? _progressSaveTimer;
  Timer? _initialBufferingWatchdog;
  int _connectionEpoch = 0;
  int _episodeSessionEpoch = 0;
  LiveVideoFitMode _fitMode = SettingsService.instance.defaultAspectRatio;

  // Controle de Próximo Episódio
  XtreamSeriesEpisode? _nextEpisode;
  int? _countdownSeconds;
  Timer? _countdownTimer;
  bool _hasTriggeredCompletion = false;
  bool _hasTriggeredBingeCard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeviceUtils.isPipMode.addListener(_onPipModeChanged);
    _activeSeriesId = widget.series.seriesId;
    _currentSeriesInfo = widget.seriesInfo;
    _currentEpisode = widget.initialEpisode;
    _resumptionTarget = widget.initialPosition;
    _updateNextEpisode();

    DeviceUtils.setVideoOrientation();
    DeviceUtils.setKeepScreenOn(true, force: true);

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
    _postPlaySeekTimer?.cancel();
    _cancelCountdown();
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

  void _updateNextEpisode() {
    _nextEpisode = _currentSeriesInfo.getNextEpisode(_currentEpisode);
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

    final sessionEpoch = _episodeSessionEpoch;
    final activeSeriesId = _activeSeriesId;
    final epSnapshot = _currentEpisode;
    final pos = c.value.position;
    final dur = c.value.duration;

    // Proteção absoluta: NUNCA sobrescrever posição anterior válida nem sobrescrever S4E2 com Ep1 (< 10s).
    final resumptionRef = _resumptionTarget;
    if (resumptionRef != null &&
        resumptionRef.inSeconds >= 10 &&
        pos.inSeconds < 10) {
      debugPrint('[SERIES PLAYER] [PROGRESSO] Preservando posição salva anterior (${PlaybackProgressService.formatDuration(resumptionRef)}) pois reprodução atual não avançou (${PlaybackProgressService.formatDuration(pos)}).');
      return;
    }

    if (dur > Duration.zero && (pos.inSeconds >= 5 || force)) {
      final isNearEnd = dur.inSeconds > 0 &&
          ((dur.inSeconds - pos.inSeconds) <= 45 ||
              (pos.inSeconds / dur.inSeconds) >= 0.96);

      // Se o episódio atingiu os créditos finais (<= 45s ou >= 96%) e o usuário saiu ou o timer disparou,
      // promove automaticamente o próximo episódio (se existir).
      if (isNearEnd) {
        if (!_hasTriggeredCompletion) {
          _hasTriggeredCompletion = true;
          await _handleEpisodeCompleted(sessionEpoch: sessionEpoch);
        }
        return;
      }

      // Nunca gravar lastWatched nem ContinueWatching para reprodução acidental abaixo de 10s.
      if (pos.inSeconds < 10) {
        return;
      }

      if (sessionEpoch != _episodeSessionEpoch) return;
      _resumptionTarget = pos;

      debugPrint('[SERIES PLAYER] [PROGRESSO] Salvando progresso: ep=${epSnapshot.id}, pos=${PlaybackProgressService.formatDuration(pos)}, dur=${PlaybackProgressService.formatDuration(dur)}');
      await _progressService.saveEpisodeProgress(
        accountKey: widget.accountKey,
        seriesId: activeSeriesId,
        episodeId: epSnapshot.id,
        position: pos,
        duration: dur,
      );

      if (sessionEpoch != _episodeSessionEpoch) return;
      await _progressService.saveLastWatchedEpisode(
        accountKey: widget.accountKey,
        seriesId: activeSeriesId,
        episodeId: epSnapshot.id,
        seasonNumber: epSnapshot.seasonNumber,
        episodeNum: epSnapshot.episodeNum,
      );

      if (sessionEpoch != _episodeSessionEpoch) return;
      await _progressService.saveContinueWatchingItem(
        accountKey: widget.accountKey,
        item: ContinueWatchingItem(
          streamId: epSnapshot.id,
          seriesId: activeSeriesId,
          type: ContinueWatchingType.series,
          title: widget.series.name,
          subtitle: 'T${epSnapshot.seasonNumber}:E${epSnapshot.episodeNum} • ${epSnapshot.title}',
          coverUrl: epSnapshot.cover ?? widget.series.cover,
          position: pos,
          duration: dur,
          updatedAt: DateTime.now(),
          containerExtension: epSnapshot.containerExtension,
          categoryId: widget.series.categoryId,
          seasonNumber: epSnapshot.seasonNumber,
          episodeNum: epSnapshot.episodeNum,
        ),
      );
    }
  }

  void _recordStreamUrlsSource(XtreamSeriesEpisode ep) {
    _streamUrlsSourceEpisodeId = ep.id;
    _streamUrlsSourceAltId = ep.streamId;
    _streamUrlsSourceExt = ep.containerExtension;
    _streamUrlsSourceDirect = ep.directSource;
  }

  bool _hasEpisodeMetadataChangedFromStreamUrls() {
    return _currentEpisode.id != _streamUrlsSourceEpisodeId ||
        _currentEpisode.streamId != _streamUrlsSourceAltId ||
        _currentEpisode.containerExtension != _streamUrlsSourceExt ||
        _currentEpisode.directSource != _streamUrlsSourceDirect;
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

  List<String> _buildPriorityUrls(XtreamSeriesEpisode ep) {
    final baseUrls = widget.catalogService.buildSeriesStreamUrls(ep);
    final cached = SmartSourceResolver.instance.getCachedSource(
      _activeSeriesId,
      ep.id,
      catalogService: widget.catalogService,
    );
    final direct = ep.directSource?.trim();

    final merged = <String>[];
    void addUrl(String u) {
      final trimmed = u.trim();
      if (trimmed.isNotEmpty && !merged.contains(trimmed) && merged.length < 4) {
        merged.add(trimmed);
      }
    }

    if (cached != null) {
      addUrl(cached);
    }
    for (final u in baseUrls.take(3)) {
      addUrl(u);
    }
    if (direct != null && direct.isNotEmpty) {
      for (final u in baseUrls) {
        if (u.contains(direct)) {
          addUrl(u);
        }
      }
    }
    for (final u in baseUrls) {
      if (merged.length >= 4) break;
      addUrl(u);
    }
    return merged;
  }

  Future<void> _hydrateSeriesInfoInBackground(
    int seriesId, {
    bool forceRefresh = false,
    required int sessionEpoch,
  }) async {
    try {
      final result = await widget.catalogService
          .fetchSeriesInfoDetailed(
            seriesId,
            forceRefresh: forceRefresh,
            expectedSeriesName: widget.series.name,
            expectedCoverUrl: widget.series.cover,
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted || sessionEpoch != _episodeSessionEpoch || _isExiting) return;
      final hydratedInfo = result.info;
      if (result.identityConsistency == SeriesIdentityConsistency.mismatch ||
          hydratedInfo == null ||
          hydratedInfo.isOrphanedOrStub) {
        return;
      }

      final prevId = _currentEpisode.id;
      final prevExt = _currentEpisode.containerExtension;
      // Prioriza a correspondência por temporada e número do episódio quando disponível,
      // pois em reindexações parciais o ID antigo pode ter sido reaproveitado ou substituído.
      final hydratedEp = hydratedInfo.findEpisodeBySeasonAndNum(
            _currentEpisode.seasonNumber,
            _currentEpisode.episodeNum,
          ) ??
          hydratedInfo.findEpisodeById(prevId);
      setState(() {
        _currentSeriesInfo = hydratedInfo;
        if (hydratedEp != null) {
          _currentEpisode = hydratedEp;
        }
        _updateNextEpisode();
      });
      if (hydratedEp != null &&
          (hydratedEp.id != prevId || hydratedEp.containerExtension != prevExt)) {
        final posToKeep = _resumptionTarget ?? widget.initialPosition ?? Duration.zero;
        if (posToKeep.inSeconds >= 10) {
          unawaited(
            _progressService.saveContinueWatchingItem(
              accountKey: widget.accountKey,
              item: ContinueWatchingItem(
                type: ContinueWatchingType.series,
                streamId: hydratedEp.id,
                seriesId: _activeSeriesId,
                title: widget.series.name,
                coverUrl: hydratedEp.cover ?? widget.series.cover,
                subtitle: 'T${hydratedEp.seasonNumber}:E${hydratedEp.episodeNum} • ${hydratedEp.title}',
                position: posToKeep,
                duration: hydratedEp.durationSecs != null
                    ? Duration(seconds: hydratedEp.durationSecs!)
                    : Duration.zero,
                updatedAt: DateTime.now(),
                seasonNumber: hydratedEp.seasonNumber,
                episodeNum: hydratedEp.episodeNum,
                containerExtension: hydratedEp.containerExtension,
                categoryId: widget.series.categoryId,
              ),
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _initCurrentEpisode({
    Duration? initialPosition,
    bool isAutoSessionReload = false,
  }) async {
    final sessionEpoch = ++_episodeSessionEpoch;
    if (!isAutoSessionReload) {
      _autoSessionReloadAttempted = false;
    }
    _resumptionTarget = initialPosition;
    _seekAttempted = false;
    _smartSourceAttempted = false;
    _smartSourceStatusMessage = null;
    _failedStreamUrls.clear();
    _hydrationFuture = null;
    _hydratedRetryAttempted = false;
    _transient403RetryAttempted = false;
    _smartSourceConnectRetryAttempted = false;
    _smartSourceResolvedUrl = null;
    _isHandlingError = false;

    // Hidratação instantânea do cache local com verificação estrita de identidade;
    // se vindo de SeriesDetailScreen já validado em rede nesta sessão, evita forceRefresh redundante na abertura.
    final knownEpisodesCount = _currentSeriesInfo.episodesBySeason.values
        .fold<int>(0, (sum, list) => sum + list.length);
    if (knownEpisodesCount <= 1 && _activeSeriesId > 0) {
      try {
        final cachedInfo = await widget.catalogService.getCachedSeriesInfo(
          _activeSeriesId,
          expectedSeriesName: widget.series.name,
          expectedCoverUrl: widget.series.cover,
        );
        if (!mounted || sessionEpoch != _episodeSessionEpoch) return;
        if (cachedInfo != null && !cachedInfo.isOrphanedOrStub) {
          _currentSeriesInfo = cachedInfo;
          final hydratedEp = cachedInfo.findEpisodeById(_currentEpisode.id) ??
              cachedInfo.findEpisodeBySeasonAndNum(
                _currentEpisode.seasonNumber,
                _currentEpisode.episodeNum,
              );
          if (hydratedEp != null) {
            _currentEpisode = hydratedEp;
          }
          _updateNextEpisode();
          _hydrationFuture = _hydrateSeriesInfoInBackground(
            _activeSeriesId,
            forceRefresh: true,
            sessionEpoch: sessionEpoch,
          );
        } else {
          _hydrationFuture = _hydrateSeriesInfoInBackground(
            _activeSeriesId,
            forceRefresh: true,
            sessionEpoch: sessionEpoch,
          );
          try {
            await _hydrationFuture!.timeout(
              const Duration(milliseconds: 2000),
              onTimeout: () {},
            );
          } catch (_) {}
          if (!mounted || sessionEpoch != _episodeSessionEpoch) return;
        }
      } catch (_) {}
    } else if (_activeSeriesId > 0 && !widget.seriesInfoIsFresh) {
      _hydrationFuture = _hydrateSeriesInfoInBackground(
        _activeSeriesId,
        forceRefresh: true,
        sessionEpoch: sessionEpoch,
      );
    }

    _streamUrls = _buildPriorityUrls(_currentEpisode);
    _recordStreamUrlsSource(_currentEpisode);
    _currentUrlIndex = 0;
    _hasTriggeredCompletion = false;
    _hasTriggeredBingeCard = false;
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
    PlayerDiagnostics.log('REQUEST', 'Tipo=SERIE, ID=${_currentEpisode.id}, T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum} ("${_currentEpisode.title}"), Série="${widget.series.name}", Extensão="${_currentEpisode.containerExtension}", Rota=${_currentUrlIndex + 1}/${_streamUrls.length}');
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

    // Timeout de inicialização adequado para arquivos grandes de VOD/Séries (25 segundos)
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

      _metrics.markConnectionEstablished();
      _metrics.markPlayerInitialized();

      final detectedDur = controller.value.duration;
      PlayerDiagnostics.log('STATE', 'STATE_READY | Duração: ${PlaybackProgressService.formatDuration(detectedDur)} | Resolução: ${controller.value.size.width.toInt()}x${controller.value.size.height.toInt()}');

      // 1. Inicia o watchdog de buffer inicial
      _startInitialBufferingWatchdog(epoch);

      // 2. Aplica seekTo ANTES de play() para que o ExoPlayer já faça buffer direto na posição salva
      Duration effectiveTarget = Duration.zero;
      if (initialPosition != null && initialPosition > Duration.zero) {
        Duration target = initialPosition;
        if (detectedDur > Duration.zero && target >= detectedDur) {
          final safeTarget = detectedDur - const Duration(seconds: 10);
          target = safeTarget > Duration.zero ? safeTarget : Duration.zero;
        }
        _resumptionTarget = target;
        effectiveTarget = target;

        if (target > Duration.zero) {
          _isSeekingToInitial = true;
          _seekAttempted = true;
          debugPrint('[SERIES PLAYER] [SEEK] Disparando seekTo para ${PlaybackProgressService.formatDuration(target)} (posição salva: ${PlaybackProgressService.formatDuration(initialPosition)})...');
          try {
            await controller.seekTo(target).timeout(const Duration(seconds: 6));
            debugPrint('[SERIES PLAYER] [SEEK] seekTo concluído com sucesso para ${PlaybackProgressService.formatDuration(target)}.');
          } catch (seekError) {
            debugPrint('[SERIES PLAYER] [SEEK] Aviso: falha ao buscar ponto salvo ($seekError). Reproduzindo do início.');
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
      _failedStreamUrls.add(url);
      await _handleConnectionError(e, epoch: epoch, initialPosition: initialPosition);
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
      debugPrint('[SERIES PLAYER] [SEEK FALLBACK] Posição reiniciada em ${PlaybackProgressService.formatDuration(val.position)}; reaplicando seek para ${PlaybackProgressService.formatDuration(target)}...');
      try {
        await controller.seekTo(target).timeout(const Duration(seconds: 4));
      } catch (_) {
      } finally {
        _isSeekingToInitial = false;
      }
    }
  }

  Future<void> _handleConnectionError(
    Object e, {
    required int epoch,
    Duration? initialPosition,
  }) async {
    if (!mounted || epoch != _connectionEpoch || _isExiting) return;

    final quickDetails = PlayerDiagnostics.analyzeError(e);

    final isPluginUnavailable =
        e is UnimplementedError || e.toString().contains('MissingPluginException');
    final isTimeout = e is TimeoutException ||
        quickDetails.causeClass == 'TimeoutException' ||
        quickDetails.shortUiMessage.contains('Timeout');
    final isAuthOrForbidden = quickDetails.isAuthOrForbidden;
    final isHttp403 = quickDetails.exoPlayerHttpStatus == 403 ||
        quickDetails.probeHttpStatus == 403;

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

    // 0a. Se o Smart Source acabou de validar uma URL e a conexão imediata falhou
    // (ex.: servidor Xtream ainda liberando o slot da sonda), tenta 1 reconexão limpa.
    if (_smartSourceResolvedUrl != null &&
        !_smartSourceConnectRetryAttempted &&
        !_isExiting &&
        quickDetails.exoPlayerHttpStatus != 401) {
      _smartSourceConnectRetryAttempted = true;
      PlayerDiagnostics.log(
        'RETRY_ROUTE',
        'Repetindo conexão limpa na URL validada pelo Smart Source após breve pausa.',
      );
      await _disposeCurrentController();
      await Future.delayed(const Duration(milliseconds: 700));
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;
      await _connectToUrl(
        _smartSourceResolvedUrl!,
        initialPosition: initialPosition,
      );
      return;
    }

    // 0b. Em HTTP 403 transitório (sessão/socket anterior ainda fechando no servidor),
    // aguarda brevemente e tenta a mesma URL uma única vez sem alternar extensões.
    if (_smartSourceResolvedUrl == null &&
        isHttp403 &&
        !_transient403RetryAttempted &&
        !_isExiting &&
        _streamUrls.isNotEmpty) {
      _transient403RetryAttempted = true;
      final retryUrl = _streamUrls[_currentUrlIndex.clamp(0, _streamUrls.length - 1)];
      PlayerDiagnostics.log(
        'RETRY_ROUTE',
        'HTTP 403 transitório; aguardando fechamento da conexão anterior para tentar novamente a mesma URL.',
      );
      await _disposeCurrentController();
      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;
      await _connectToUrl(retryUrl, initialPosition: initialPosition);
      return;
    }

    // REGRA DE SEGURANÇA E CONTINGÊNCIA:
    // 1. Nunca tentar rotas alternativas em erros de autenticação ou permissão (HTTP 401/403).
    // 2. Não tentar rotas alternativas para timeouts de rede puros (25s watchdog ou host inalcançável).
    // 3. Para qualquer falha de reprodução (Source error, 404, container/codec incompatível, EOF, conexão resetada):
    //    se existirem URLs alternativas na lista, encerra o player anterior e avança sem sondagem paralela.
    final canTryAlternative = !isAuthOrForbidden &&
        !isTimeout &&
        (_currentUrlIndex + 1 < _streamUrls.length);

    if (canTryAlternative) {
      _currentUrlIndex++;
      PlayerDiagnostics.log(
        'RETRY_ROUTE',
        'Avançando para URL de contingência ${_currentUrlIndex + 1}/${_streamUrls.length} devido a erro: ${quickDetails.technicalSummary}',
      );

      await _disposeCurrentController();
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;

      await _connectToUrl(_streamUrls[_currentUrlIndex], initialPosition: initialPosition);
      return;
    }

    // Se a hidratação em background trouxe metadados reais diferentes do snapshot usado
    // para montar _streamUrls (ou ainda não revalidou porque seriesInfoIsFresh era true),
    // recria as URLs hidratadas e tenta conectar antes de ir ao SmartSourceResolver.
    if (!isAuthOrForbidden &&
        !_hydratedRetryAttempted &&
        !_isExiting) {
      final epEpochAtError = _episodeSessionEpoch;
      final hydration = _hydrationFuture ??
          (_activeSeriesId > 0
              ? _hydrateSeriesInfoInBackground(
                  _activeSeriesId,
                  forceRefresh: true,
                  sessionEpoch: epEpochAtError,
                )
              : null);
      if (hydration != null) {
        try {
          await hydration.timeout(const Duration(seconds: 6), onTimeout: () {});
        } catch (_) {}
      }
      if (!mounted ||
          epoch != _connectionEpoch ||
          epEpochAtError != _episodeSessionEpoch ||
          _isExiting) {
        return;
      }
      if (_hasEpisodeMetadataChangedFromStreamUrls()) {
        _hydratedRetryAttempted = true;
        final refreshedUrls = _buildPriorityUrls(_currentEpisode)
            .where((u) => !_failedStreamUrls.contains(u))
            .toList();
        if (refreshedUrls.isNotEmpty) {
          _streamUrls = refreshedUrls;
          _currentUrlIndex = 0;
          _recordStreamUrlsSource(_currentEpisode);
          await _disposeCurrentController();
          if (!mounted || epoch != _connectionEpoch || _isExiting) return;
          PlayerDiagnostics.log(
            'RETRY_ROUTE',
            'Hidratação retornou episódio atualizado (ID=${_currentEpisode.id}, ext=${_currentEpisode.containerExtension}); tentando rota fresca.',
          );
          await _connectToUrl(_streamUrls[0], initialPosition: initialPosition);
          return;
        }
      }
    }

    // Se esgotou as rotas imediatas sem sucesso, tenta a recuperação profunda SmartSourceResolver
    if (!_smartSourceAttempted &&
        SettingsService.instance.enableSmartSource &&
        !isAuthOrForbidden &&
        !isTimeout) {
      final epEpochAtResolve = _episodeSessionEpoch;
      _smartSourceAttempted = true;
      await _disposeCurrentController();
      if (!mounted ||
          epoch != _connectionEpoch ||
          epEpochAtResolve != _episodeSessionEpoch ||
          _isExiting) {
        return;
      }

      setState(() {
        _isLoading = true;
        _smartSourceStatusMessage = 'Recuperando fonte do episódio (Smart Source)...';
      });

      PlayerDiagnostics.log('SMART_SOURCE', 'Iniciando resolução inteligente de fonte via sondagem multi-container (.mp4/.mkv/.ts).');
      final result = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: widget.catalogService,
        episode: _currentEpisode,
        seriesId: _activeSeriesId,
        seriesName: widget.series.name,
        categoryId: widget.series.categoryId,
        alreadyFailedUrls: Set<String>.from(_failedStreamUrls),
        onProgressMessage: (msg) {
          if (mounted &&
              epoch == _connectionEpoch &&
              epEpochAtResolve == _episodeSessionEpoch) {
            setState(() => _smartSourceStatusMessage = msg);
          }
        },
      );

      if (!mounted ||
          epoch != _connectionEpoch ||
          epEpochAtResolve != _episodeSessionEpoch ||
          _isExiting) {
        return;
      }

      if (result.isSuccess && result.workingUrl != null) {
        final workingUrl = result.workingUrl!;
        _smartSourceResolvedUrl = workingUrl;
        setState(() {
          _smartSourceStatusMessage = null;
        });

        if (result.recoveredSeriesId != null && result.recoveredSeriesId! > 0) {
          _activeSeriesId = result.recoveredSeriesId!;
        }

        if (result.recoveredEpisode != null) {
          _currentEpisode = result.recoveredEpisode!;
          _updateNextEpisode();
          debugPrint('[SERIES PLAYER] Atualizando episódio ativo para recuperado: ID=${_currentEpisode.id}, T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum}');
          if (initialPosition != null && initialPosition.inSeconds >= 10) {
            unawaited(
              _progressService.saveContinueWatchingItem(
                accountKey: widget.accountKey,
                item: ContinueWatchingItem(
                  type: ContinueWatchingType.series,
                  streamId: _currentEpisode.id,
                  seriesId: _activeSeriesId,
                  title: widget.series.name,
                  coverUrl: _currentEpisode.cover ?? widget.series.cover,
                  subtitle: 'T${_currentEpisode.seasonNumber}:E${_currentEpisode.episodeNum} • ${_currentEpisode.title}',
                  position: initialPosition,
                  duration: Duration.zero,
                  updatedAt: DateTime.now(),
                  seasonNumber: _currentEpisode.seasonNumber,
                  episodeNum: _currentEpisode.episodeNum,
                  containerExtension: _currentEpisode.containerExtension,
                  categoryId: widget.series.categoryId,
                ),
              ),
            );
          }
        }

        _streamUrls = [workingUrl];
        _currentUrlIndex = 0;
        _recordStreamUrlsSource(_currentEpisode);

        PlayerDiagnostics.log(
          'SMART_SOURCE',
          'Fonte resolvida com sucesso: ${UrlSanitizer.sanitize(workingUrl)}',
        );
        await Future.delayed(const Duration(milliseconds: 350));
        if (!mounted ||
            epoch != _connectionEpoch ||
            epEpochAtResolve != _episodeSessionEpoch ||
            _isExiting) {
          return;
        }
        await _connectToUrl(workingUrl, initialPosition: initialPosition);
        return;
      }

      // Antes de exibir erro definitivo ao usuário no 1º clique, realiza 1 recarga automática de sessão completa
      // (equivalente ao 2º clique / botão Tentar novamente) após liberar completamente os sockets.
      if (!_autoSessionReloadAttempted &&
          !_isExiting &&
          !isPluginUnavailable &&
          quickDetails.exoPlayerHttpStatus != 401) {
        _autoSessionReloadAttempted = true;
        PlayerDiagnostics.log(
          'RETRY_ROUTE',
          'Acionando recarga automática completa do episódio no 1º clique após falha do Smart Source.',
        );
        await _disposeCurrentController();
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted || epoch != _connectionEpoch || _isExiting) return;
        await _initCurrentEpisode(
          initialPosition: initialPosition,
          isAutoSessionReload: true,
        );
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

    // Antes de exibir erro definitivo ao usuário no 1º clique (ex.: HTTP 403 persistente por socket da tela anterior,
    // ou falha transitória de abertura), realiza 1 recarga automática de sessão completa (exceto HTTP 401 ou timeout de 25s).
    if (!_autoSessionReloadAttempted &&
        !_isExiting &&
        !isPluginUnavailable &&
        !isTimeout &&
        quickDetails.exoPlayerHttpStatus != 401) {
      _autoSessionReloadAttempted = true;
      PlayerDiagnostics.log(
        'RETRY_ROUTE',
        'Acionando recarga automática completa do episódio no 1º clique antes de exibir erro na tela.',
      );
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted || epoch != _connectionEpoch || _isExiting) return;
      await _initCurrentEpisode(
        initialPosition: initialPosition,
        isAutoSessionReload: true,
      );
      return;
    }

    // Diagnóstico final definitivo quando todas as alternativas falharam ou em erro de auth/timeout
    final probe = _streamUrls.isNotEmpty
        ? await PlayerDiagnostics.probeStreamUrl(
            _streamUrls[_currentUrlIndex.clamp(0, _streamUrls.length - 1)],
          )
        : const HttpProbeResult(elapsedMs: 0);
    if (!mounted || epoch != _connectionEpoch || _isExiting) return;
    final details = PlayerDiagnostics.analyzeError(e, probe: probe);

    PlayerDiagnostics.log('ERROR', 'Falha definitiva na reprodução do episódio: ${details.technicalSummary}');
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

    // Erros durante controller.initialize() são tratados pelo try/catch de _connectToUrl
    if (_isInitializingController) return;

    // Se houver erro, cancela qualquer contagem regressiva e interrompe avanço automático
    if (c.value.hasError) {
      if (_isHandlingError || _errorMessage != null) return;
      _isHandlingError = true;
      c.removeListener(_onControllerUpdate);
      _cancelCountdown();
      _initialBufferingWatchdog?.cancel();
      final errorDesc = c.value.errorDescription ?? 'Erro interno de reprodução';
      final details = PlayerDiagnostics.analyzeError(errorDesc);
      PlayerDiagnostics.log('ERROR', 'Controller disparou erro durante reprodução do episódio: ${details.technicalSummary}');
      PlayerDiagnostics.logDiagnosticDetails(details);
      PlayerDiagnostics.log('ERROR_NAME', details.errorCodeName ?? 'N/D');
      PlayerDiagnostics.log('CAUSE', '${details.causeClass ?? 'N/D'}: ${details.causeMessage ?? 'N/D'}');
      PlayerDiagnostics.log('STATE', 'hasError=true, pos=${c.value.position}, isPlaying=${c.value.isPlaying}, isBuffering=${c.value.isBuffering}');
      _metrics.markError(details.shortUiMessage);

      if (_currentUrlIndex >= 0 && _currentUrlIndex < _streamUrls.length) {
        _failedStreamUrls.add(_streamUrls[_currentUrlIndex]);
      }
      final effectiveResumption = _resumptionTarget ?? (c.value.position > Duration.zero ? c.value.position : null);
      if (_currentUrlIndex + 1 < _streamUrls.length) {
        PlayerDiagnostics.log('RETRY_ROUTE', 'Erro assíncrono no controller; tentando URL de contingência ${_currentUrlIndex + 1}.');
      }
      if (!_isExiting) {
        _handleConnectionError(errorDesc, epoch: _connectionEpoch, initialPosition: effectiveResumption);
        return;
      }

      setState(() {
        _errorMessage = details.shortUiMessage;
        _isLoading = false;
        _isBuffering = false;
      });
      return;
    }

    if (!c.value.isInitialized) return;

    // Validação segura de avanço real de reprodução / primeiro quadro
    bool hasAdvanced = false;
    if (_seekAttempted && _resumptionTarget != null && _resumptionTarget! > Duration.zero) {
      // Quando houve seek para posição salva, usa tolerância de 12s para acomodar alinhamento de keyframe (I-frame)
      final minExpectedPos = _resumptionTarget! > const Duration(seconds: 12)
          ? _resumptionTarget! - const Duration(seconds: 12)
          : Duration.zero;
      hasAdvanced = c.value.isPlaying &&
                    !c.value.isBuffering &&
                    !_isSeekingToInitial &&
                    c.value.position >= minExpectedPos &&
                    c.value.position > Duration.zero;
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

    if (c.value.isPlaying != _wasControllerPlaying) {
      _wasControllerPlaying = c.value.isPlaying;
      if (c.value.isPlaying) {
        _syncPipState(true);
        DeviceUtils.setKeepScreenOn(true, force: true);
      }
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

    // Regra 3: O avanço automático só pode ocorrer após a conclusão NORMAL do episódio
    // ou no modo Binge-Watching antecipado durante os créditos.
    if (c.value.isInitialized &&
        _errorMessage == null &&
        !_isLoading &&
        !_isBuffering &&
        c.value.duration > Duration.zero) {
      final pos = c.value.position;
      final dur = c.value.duration;
      final remaining = dur.inSeconds - pos.inSeconds;

      // Binge-Watching antecipado nos créditos (quando faltarem 25s ou menos de vídeo):
      if (!_hasTriggeredBingeCard &&
          _nextEpisode != null &&
          SettingsService.instance.enableAutoPlayNextEpisode &&
          pos.inSeconds > 20 &&
          remaining <= 25 &&
          remaining > 2) {
        _hasTriggeredBingeCard = true;
        _startNextEpisodeCountdown(initialSeconds: 15);
      }

      // Conclusão normal ao fim do vídeo
      if (!_hasTriggeredCompletion &&
          !c.value.isPlaying &&
          remaining <= 2 &&
          pos.inSeconds > 10) {
        _hasTriggeredCompletion = true;
        final sessionEpoch = _episodeSessionEpoch;
        unawaited(_completeEpisodeAndMaybeAutoAdvance(sessionEpoch));
      }
    }
  }

  Future<void> _completeEpisodeAndMaybeAutoAdvance(int sessionEpoch) async {
    await _handleEpisodeCompleted(sessionEpoch: sessionEpoch);
    if (!mounted || sessionEpoch != _episodeSessionEpoch || _isExiting) return;
    if (_nextEpisode != null &&
        SettingsService.instance.enableAutoPlayNextEpisode &&
        _countdownSeconds == null) {
      _startNextEpisodeCountdown(initialSeconds: 5);
    }
  }

  Future<void> _handleEpisodeCompleted({required int sessionEpoch}) async {
    if (sessionEpoch != _episodeSessionEpoch) return;
    final activeSeriesId = _activeSeriesId;
    final completedEp = _currentEpisode;
    // 1. Limpa o progresso salvo do episódio concluído
    await _progressService.clearEpisodeProgress(
      accountKey: widget.accountKey,
      seriesId: activeSeriesId,
      episodeId: completedEp.id,
    );

    if (sessionEpoch != _episodeSessionEpoch) return;

    // Se iniciou a partir de stub da Home (<= 1 episódio conhecido), aguarda/busca a grade completa
    // com verificação estrita de identidade antes de concluir que não existe próximo episódio.
    var knownEpisodesCount = _currentSeriesInfo.episodesBySeason.values
        .fold<int>(0, (sum, list) => sum + list.length);
    var seriesConfirmedFromNetwork = false;
    if (_nextEpisode == null && knownEpisodesCount <= 1 && activeSeriesId > 0) {
      if (_hydrationFuture != null) {
        try {
          await _hydrationFuture!.timeout(const Duration(seconds: 6), onTimeout: () {});
          seriesConfirmedFromNetwork = _currentSeriesInfo.totalEpisodeCount >= 1 &&
              !_currentSeriesInfo.isOrphanedOrStub;
        } catch (_) {}
      } else {
        try {
          final res = await widget.catalogService
              .fetchSeriesInfoDetailed(
                activeSeriesId,
                expectedSeriesName: widget.series.name,
                expectedCoverUrl: widget.series.cover,
              )
              .timeout(const Duration(seconds: 6));
          final fetched = res.info;
          if (res.identityConsistency != SeriesIdentityConsistency.mismatch &&
              fetched != null &&
              !fetched.isOrphanedOrStub) {
            seriesConfirmedFromNetwork = fetched.totalEpisodeCount >= 1;
            if (sessionEpoch == _episodeSessionEpoch) {
              _currentSeriesInfo = fetched;
              _updateNextEpisode();
            }
          }
        } catch (_) {}
      }
      knownEpisodesCount = _currentSeriesInfo.episodesBySeason.values
          .fold<int>(0, (sum, list) => sum + list.length);
    }

    if (sessionEpoch != _episodeSessionEpoch) return;

    // 2. Se houver próximo episódio na série, promove-o com posição inicial zero
    if (_nextEpisode != null) {
      await _progressService.saveLastWatchedEpisode(
        accountKey: widget.accountKey,
        seriesId: activeSeriesId,
        episodeId: _nextEpisode!.id,
        seasonNumber: _nextEpisode!.seasonNumber,
        episodeNum: _nextEpisode!.episodeNum,
        isPromotedNext: true,
      );

      await _progressService.saveContinueWatchingItem(
        accountKey: widget.accountKey,
        item: ContinueWatchingItem(
          streamId: _nextEpisode!.id,
          seriesId: activeSeriesId,
          type: ContinueWatchingType.series,
          title: widget.series.name,
          subtitle: 'T${_nextEpisode!.seasonNumber}:E${_nextEpisode!.episodeNum} • ${_nextEpisode!.title}',
          coverUrl: _nextEpisode!.cover ?? widget.series.cover,
          position: Duration.zero,
          duration: _nextEpisode!.durationSecs != null
              ? Duration(seconds: _nextEpisode!.durationSecs!)
              : Duration.zero,
          updatedAt: DateTime.now(),
          containerExtension: _nextEpisode!.containerExtension,
          categoryId: widget.series.categoryId,
          seasonNumber: _nextEpisode!.seasonNumber,
          episodeNum: _nextEpisode!.episodeNum,
        ),
      );
    } else if (knownEpisodesCount > 1 || seriesConfirmedFromNetwork) {
      // Último episódio da série confirmada como hidratada (inclusive minissérie de 1 ep): marca como concluída
      await _progressService.markContinueWatchingCompleted(
        accountKey: widget.accountKey,
        type: ContinueWatchingType.series,
        id: activeSeriesId,
      );
    }
  }

  void _startNextEpisodeCountdown({int initialSeconds = 15}) {
    _cancelCountdown();
    setState(() {
      _countdownSeconds = initialSeconds;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_countdownSeconds != null && _countdownSeconds! > 1) {
        setState(() {
          _countdownSeconds = _countdownSeconds! - 1;
        });
      } else {
        _cancelCountdown();
        _playNextEpisode();
      }
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
    final next = _nextEpisode;
    if (next == null) return;
    final previousEp = _currentEpisode;
    final prevController = _controller;
    _cancelCountdown();
    unawaited(_transitionToNextEpisode(previousEp, next, prevController));
  }

  Future<void> _transitionToNextEpisode(
    XtreamSeriesEpisode previousEp,
    XtreamSeriesEpisode next,
    VideoPlayerController? prevController,
  ) async {
    final activeSeriesId = _activeSeriesId;
    if (prevController != null && prevController.value.isInitialized) {
      final pos = prevController.value.position;
      final dur = prevController.value.duration;
      final isNearEnd = dur.inSeconds > 0 &&
          ((dur.inSeconds - pos.inSeconds) <= 45 ||
              (pos.inSeconds / dur.inSeconds) >= 0.96);
      if (isNearEnd) {
        await _progressService.clearEpisodeProgress(
          accountKey: widget.accountKey,
          seriesId: activeSeriesId,
          episodeId: previousEp.id,
        );
      } else if (pos.inSeconds >= 10 && dur > Duration.zero) {
        await _progressService.saveEpisodeProgress(
          accountKey: widget.accountKey,
          seriesId: activeSeriesId,
          episodeId: previousEp.id,
          position: pos,
          duration: dur,
        );
      }
    }

    await _progressService.saveLastWatchedEpisode(
      accountKey: widget.accountKey,
      seriesId: activeSeriesId,
      episodeId: next.id,
      seasonNumber: next.seasonNumber,
      episodeNum: next.episodeNum,
      isPromotedNext: true,
    );

    await _progressService.saveContinueWatchingItem(
      accountKey: widget.accountKey,
      item: ContinueWatchingItem(
        streamId: next.id,
        seriesId: activeSeriesId,
        type: ContinueWatchingType.series,
        title: widget.series.name,
        subtitle: 'T${next.seasonNumber}:E${next.episodeNum} • ${next.title}',
        coverUrl: next.cover ?? widget.series.cover,
        position: Duration.zero,
        duration: next.durationSecs != null
            ? Duration(seconds: next.durationSecs!)
            : Duration.zero,
        updatedAt: DateTime.now(),
        containerExtension: next.containerExtension,
        categoryId: widget.series.categoryId,
        seasonNumber: next.seasonNumber,
        episodeNum: next.episodeNum,
      ),
    );

    if (!mounted || _isExiting) return;
    setState(() {
      _currentEpisode = next;
      _updateNextEpisode();
    });

    await _initCurrentEpisode();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (c.value.isPlaying) {
      c.pause();
      _syncPipState(false);
      _saveCurrentProgress();
    } else {
      // Se estava em contagem regressiva, cancela ao despausar
      _cancelCountdown();
      c.play();
      _syncPipState(true);
      DeviceUtils.setKeepScreenOn(true, force: true);
    }
    setState(() {});
  }

  Future<void> _seekToTarget(Duration target) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final sessionEpoch = _episodeSessionEpoch;
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(0, c.value.duration.inMilliseconds),
    );
    _resumptionTarget = clamped;
    try {
      await c.seekTo(clamped);
    } catch (_) {}
    if (!mounted || sessionEpoch != _episodeSessionEpoch || _isExiting) return;
    await _saveCurrentProgress(force: clamped.inSeconds >= 10);
  }

  void _seekRelative(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    _cancelCountdown();
    unawaited(_seekToTarget(c.value.position + Duration(seconds: seconds)));
  }

  void _seekFraction(double fraction) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    _cancelCountdown();
    final targetMs = (fraction * c.value.duration.inMilliseconds).round();
    unawaited(_seekToTarget(Duration(milliseconds: targetMs)));
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
    return Scaffold(
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
          isSeriesEpisode: true,
          loadingMessage: _smartSourceStatusMessage ?? 'Carregando episódio...',
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
          isLoading: _isLoading || _smartSourceStatusMessage != null,
          isBuffering: _isBuffering,
          errorMessage: _errorMessage,
          onRetry: () => _initCurrentEpisode(
            initialPosition: _resumptionTarget ?? widget.initialPosition,
          ),
        ),
      ),
    );
  }
}
