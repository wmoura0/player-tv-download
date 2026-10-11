import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
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

  bool _isLoading = true;
  bool _isBuffering = false;
  String? _errorMessage;
  List<String> _streamUrls = [];
  int _currentUrlIndex = 0;

  Timer? _progressSaveTimer;
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

    if (widget.testController != null) {
      _controller = widget.testController;
      _isLoading = false;
    } else {
      _initCurrentEpisode(initialPosition: widget.initialPosition);
    }

    _startPeriodicProgressSave();
  }

  @override
  void dispose() {
    _cancelCountdown();
    _progressSaveTimer?.cancel();
    _saveCurrentProgress();

    if (widget.testController == null) {
      final c = _controller;
      _controller = null;
      c?.removeListener(_onControllerUpdate);
      c?.pause();
      c?.dispose();
    }

    DeviceUtils.restoreOrientation();
    super.dispose();
  }

  void _updateNextEpisode() {
    _nextEpisode = widget.seriesInfo.getNextEpisode(_currentEpisode);
  }

  void _startPeriodicProgressSave() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        _saveCurrentProgress();
      }
    });
  }

  Future<void> _saveCurrentProgress() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    final pos = c.value.position;
    final dur = c.value.duration;

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
    final oldController = _controller;
    _controller = null;
    oldController?.removeListener(_onControllerUpdate);
    await oldController?.pause();
    await oldController?.dispose();

    if (!mounted) return;

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

    try {
      await controller.initialize().timeout(const Duration(seconds: 20));

      if (!mounted || _controller != controller) return;

      if (initialPosition != null && initialPosition > Duration.zero) {
        if (initialPosition < controller.value.duration) {
          await controller.seekTo(initialPosition);
          debugPrint('[SERIES PLAYER] Retomando reprodução em ${PlaybackProgressService.formatDuration(initialPosition)}');
        }
      }

      await controller.play();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (!mounted || _controller != controller) return;

      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      debugPrint('[SERIES PLAYER] Falha na URL ($_currentUrlIndex): $safeErr');

      // Tentativa de contingência para próxima URL da lista
      if (_currentUrlIndex + 1 < _streamUrls.length) {
        _currentUrlIndex++;
        debugPrint('[SERIES PLAYER] Tentando URL de contingência: $_currentUrlIndex');
        await _connectToUrl(_streamUrls[_currentUrlIndex], initialPosition: initialPosition);
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Não foi possível reproduzir o episódio. Verifique sua conexão ou tente novamente mais tarde.';
        });
      }
    }
  }

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;

    // Se houver erro, cancela qualquer contagem regressiva e interrompe avanço automático
    if (c.value.hasError) {
      _cancelCountdown();
      final err = UrlSanitizer.sanitizeErrorMessage(c.value.errorDescription ?? 'Erro de mídia');
      if (_errorMessage == null) {
        setState(() {
          _errorMessage = err;
          _isLoading = false;
          _isBuffering = false;
        });
      }
      return;
    }

    final isBuff = c.value.isBuffering;
    if (isBuff != _isBuffering) {
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
  }

  void _seekFraction(double fraction) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    _cancelCountdown();
    final targetMs = (fraction * c.value.duration.inMilliseconds).round();
    c.seekTo(Duration(milliseconds: targetMs));
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
      onPopInvokedWithResult: (didPop, _) {
        _saveCurrentProgress();
        DeviceUtils.restoreOrientation();
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
            onBack: () {
              DeviceUtils.restoreOrientation();
              Navigator.of(context).pop();
            },
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
