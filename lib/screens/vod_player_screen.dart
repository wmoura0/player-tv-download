import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/xtream_catalog.dart';
import '../services/playback_progress_service.dart';
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

class _VodPlayerScreenState extends State<VodPlayerScreen> {
  VideoPlayerController? _controller;
  final PlaybackProgressService _progressService = PlaybackProgressService();

  bool _isLoading = true;
  bool _isBuffering = false;
  String? _errorMessage;
  int _currentUrlIndex = 0;

  Timer? _progressSaveTimer;
  LiveVideoFitMode _fitMode = SettingsService.instance.defaultAspectRatio;

  @override
  void initState() {
    super.initState();
    DeviceUtils.setVideoOrientation();
    DeviceUtils.setKeepScreenOn(true);

    if (widget.testController != null) {
      _controller = widget.testController;
      _isLoading = false;
    } else {
      _initPlayer();
    }

    _startPeriodicProgressSave();
  }

  @override
  void dispose() {
    DeviceUtils.setKeepScreenOn(false);
    _progressSaveTimer?.cancel();
    _saveCurrentProgress(); // Salva posição ao fechar

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

  void _startPeriodicProgressSave() {
    _progressSaveTimer?.cancel();
    // Requisito: Salva a posição do filme periodicamente a cada 5 segundos
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

  Future<void> _initPlayer() async {
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
    debugPrint('[VOD PLAYER] Conectando ao filme: $sanitizedUrl');

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

      // Se houver posição inicial para continuar de onde parou
      if (widget.initialPosition != null && widget.initialPosition! > Duration.zero) {
        final target = widget.initialPosition!;
        if (target < controller.value.duration) {
          await controller.seekTo(target);
          debugPrint('[VOD PLAYER] Retomando reprodução em ${PlaybackProgressService.formatDuration(target)}');
        }
      }

      await controller.play();

      if (mounted && _controller == controller) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (!mounted || _controller != controller) return;

      // Se houver rota de contingência alternativa, tenta automaticamente
      if (_currentUrlIndex + 1 < widget.streamUrls.length) {
        _currentUrlIndex++;
        debugPrint('[VOD PLAYER] Tentando rota de contingência índice $_currentUrlIndex...');
        await _connectToUrl(widget.streamUrls[_currentUrlIndex]);
        return;
      }

      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      setState(() {
        _isLoading = false;
        _errorMessage = 'Não foi possível carregar o filme. $safeErr';
      });
    }
  }

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;
    final val = c.value;

    if (val.hasError && _errorMessage == null) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(
        val.errorDescription ?? 'Erro durante a reprodução do filme.',
      );
      setState(() {
        _errorMessage = safeErr;
        _isLoading = false;
        _isBuffering = false;
      });
    } else {
      if (val.isBuffering != _isBuffering) {
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
      onPopInvokedWithResult: (didPop, _) {
        _saveCurrentProgress();
        DeviceUtils.restoreOrientation();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: VodPlayerView(
          controller: _controller,
          title: widget.movie.name,
          coverUrl: widget.movie.streamIcon,
          fitMode: _fitMode,
          onFitModeChanged: (mode) => setState(() => _fitMode = mode),
          onTogglePlayPause: _togglePlayPause,
          onSeekRelative: _seekRelative,
          onSeekFraction: _seekToFraction,
          onBack: () {
            DeviceUtils.restoreOrientation();
            Navigator.of(context).pop();
          },
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
