import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'playback_metrics.dart';
import 'url_sanitizer.dart';

/// Notificação de estado do motor de estabilidade e recuperação de reprodução
enum PlayerRecoveryState {
  connecting,
  playing,
  stalled,
  retrying,
  failed,
  cancelled,
}

/// Gerenciador de estabilidade, detecção de travamento (stall), timeout e recuperação em etapas
/// para canais de TV ao vivo e streams VOD em Android TV e Amazon Fire TV.
class PlayerStabilityManager {
  final int maxRetries;
  final Duration openTimeout;
  final Duration stallDetectionInterval;
  final Duration maxStallDuration;
  final Duration maxBufferingDuration;
  final bool isLiveStream;
  final Future<void> Function(int retryCount)? onReconnectRequest;
  final void Function(String userMessage)? onError;
  final void Function(PlayerRecoveryState state)? onStateChanged;
  PlaybackMetrics? metrics;

  PlayerStabilityManager({
    this.maxRetries = 3,
    this.openTimeout = const Duration(seconds: 15),
    this.stallDetectionInterval = const Duration(seconds: 2),
    this.maxStallDuration = const Duration(seconds: 15),
    this.maxBufferingDuration = const Duration(seconds: 15),
    this.isLiveStream = true,
    this.onReconnectRequest,
    this.onError,
    this.onStateChanged,
    this.metrics,
  });

  Timer? _openTimeoutTimer;
  Timer? _stallCheckTimer;
  Timer? _retryTimer;

  int _retryCount = 0;
  int get retryCount => _retryCount;

  bool _isReconnecting = false;
  bool get isReconnecting => _isReconnecting;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  Duration _lastPosition = Duration.zero;
  DateTime _lastPositionAdvanceTime = DateTime.now();
  DateTime _bufferingStartTime = DateTime.now();
  bool _isBuffering = false;

  bool _isUserPaused = false;
  bool get isUserPaused => _isUserPaused;
  void setUserPaused(bool paused) {
    _isUserPaused = paused;
  }

  /// Inicia monitoramento de timeout na abertura do stream
  void startOpenWatchdog(VoidCallback onTimeoutAction) {
    _openTimeoutTimer?.cancel();
    _openTimeoutTimer = Timer(openTimeout, () {
      if (_isDisposed) return;
      debugPrint('[PLAYER STABILITY] Timeout de abertura (${openTimeout.inSeconds}s) atingido.');
      onTimeoutAction();
    });
  }

  /// Cancela o temporizador de timeout de abertura quando o stream inicia com sucesso
  void clearOpenWatchdog() {
    _openTimeoutTimer?.cancel();
    _openTimeoutTimer = null;
  }

  /// Inicia monitoramento ativo de travamento/congelamento durante reprodução.
  /// Implementa recuperação em etapas com diferenciação precisa entre buffering legítimo
  /// e estagnação real, sem invocar seekTo indiscriminado em streams ao vivo.
  void startStallMonitoring(VideoPlayerController controller, {bool? isLive}) {
    _stallCheckTimer?.cancel();
    _lastPosition = controller.value.position;
    _lastPositionAdvanceTime = DateTime.now();
    _bufferingStartTime = DateTime.now();
    _isBuffering = controller.value.isBuffering;

    final live = isLive ?? isLiveStream;

    _stallCheckTimer = Timer.periodic(stallDetectionInterval, (_) {
      if (_isDisposed || !controller.value.isInitialized) return;
      if (_isUserPaused) return;

      final val = controller.value;
      final now = DateTime.now();

      // 1. Falha reportada pelo controller
      if (val.hasError) {
        final safeErr = UrlSanitizer.sanitizeErrorMessage(
          val.errorDescription ?? 'Erro interno de reprodução',
        );
        debugPrint('[PLAYER STABILITY] Erro reportado pelo reprodutor: $safeErr');
        metrics?.markError(safeErr);
        _handleStall('Erro na transmissão: $safeErr', controller);
        return;
      }

      // 2. Monitoramento de buffering legítimo com janela de tolerância
      if (val.isBuffering) {
        if (!_isBuffering) {
          _isBuffering = true;
          _bufferingStartTime = now;
          metrics?.markBufferingStart(now);
          debugPrint('[PLAYER STABILITY] Início de buffering detectado.');
        } else if (now.difference(_bufferingStartTime) > maxBufferingDuration) {
          debugPrint('[PLAYER STABILITY] Buffering estagnado por mais de ${maxBufferingDuration.inSeconds} segundos.');
          metrics?.markBufferingEnd(now);
          metrics?.markInterruption('Buffering estagnado (${maxBufferingDuration.inSeconds}s)');
          _handleStall('Buffering contínuo estagnado', controller);
          return;
        }
      } else {
        if (_isBuffering) {
          final dur = now.difference(_bufferingStartTime).inMilliseconds;
          metrics?.markBufferingEnd(now);
          debugPrint('[PLAYER STABILITY] Buffering finalizado com sucesso (${dur}ms).');
          _isBuffering = false;
        }
      }

      // 3. Monitoramento de interrupção de reprodução (STATE_ENDED / queda de conexão)
      // Em transmissões ao vivo (MPEG-TS/HLS), micro-pausas transitórias de buffer (jitter de 500ms a 3s)
      // ocorrem com frequência no Fire TV. Não desconectar prematuramente nem reiniciar o socket!
      if (live && !val.isPlaying && !val.isBuffering && !_isUserPaused) {
        _notPlayingStartTime ??= now;
        final uninterruptedNonPlaying = now.difference(_notPlayingStartTime!);

        // Tenta manter o pipeline nativo ativo via soft play sem destruir a conexão
        controller.play().catchError((_) {});

        // Apenas considera queda real da conexão se permanecer estagnado por mais de 8 segundos contínuos
        if (uninterruptedNonPlaying >= const Duration(seconds: 8)) {
          debugPrint(
            '[PLAYER STABILITY] Transmissão estagnada há ${uninterruptedNonPlaying.inSeconds}s (sem dados e sem buffer). Iniciando recuperação...',
          );
          metrics?.markInterruption('Conexão encerrada pelo servidor (estagnação > 8s)');
          _notPlayingStartTime = null;
          _handleStall('Conexão com a transmissão ao vivo encerrada', controller);
          return;
        }
      } else {
        _notPlayingStartTime = null;
      }

      // 4. Detecção de congelamento de frames / estagnação de posição
      // Para canais ao vivo (MPEG-TS): se position for zero mas isPlaying for true, não assume congelamento falso!
      if (val.isPlaying && !val.isBuffering && !_isUserPaused) {
        if (val.position != _lastPosition) {
          _lastPosition = val.position;
          _lastPositionAdvanceTime = now;
          // Reseta retries se a reprodução avançar estavelmente por mais de 10s
          if (_retryCount > 0 && now.difference(_lastRetryTime) > const Duration(seconds: 10)) {
            debugPrint('[PLAYER STABILITY] Transmissão estabilizada. Resetando contagem de tentativas.');
            metrics?.markRecoverySuccess();
            _retryCount = 0;
            _lastRetryReason = null;
          }
        } else {
          // Apenas considera congelamento de posição se a posição for mensurável (> 0)
          // ou se ultrapassar um timeout longo com evidência de congelamento
          if (!live || val.position > Duration.zero) {
            final stallDuration = now.difference(_lastPositionAdvanceTime);
            if (stallDuration > maxStallDuration) {
              debugPrint('[PLAYER STABILITY] Reprodução congelada por mais de ${stallDuration.inSeconds} segundos.');
              metrics?.markInterruption('Reprodução congelada (${stallDuration.inSeconds}s)');
              _handleStall('Reprodução congelada', controller);
              return;
            }
          }
        }
      }
    });
  }

  DateTime? _notPlayingStartTime;
  String? _lastRetryReason;
  DateTime _lastRetryTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pausa temporariamente os temporizadores de monitoramento (ex: app em background)
  void pauseMonitoring() {
    _openTimeoutTimer?.cancel();
    _stallCheckTimer?.cancel();
    _openTimeoutTimer = null;
    _stallCheckTimer = null;
    _notPlayingStartTime = null;
  }

  /// Etapa 3: Tenta recuperação leve (soft recovery) sem destruir o controlador.
  /// Requisito estrito: NÃO fazer seekTo(duration) em transmissões ao vivo.
  /// Tenta restaurar play() diretamente e aguarda confirmação de retomada.
  Future<bool> attemptSoftRecovery(VideoPlayerController? controller) async {
    if (controller == null || _isDisposed || !controller.value.isInitialized || controller.value.hasError) {
      return false;
    }

    try {
      debugPrint('[PLAYER STABILITY] Tentando recuperação leve (soft play)...');
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      if (controller.value.isPlaying) {
        debugPrint('[PLAYER STABILITY] Recuperação leve bem-sucedida!');
        metrics?.markRecoverySuccess();
        resetRetries();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[PLAYER STABILITY] Falha na recuperação leve: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}');
      return false;
    }
  }

  /// Trata stall aplicando recuperação em etapas:
  /// Primeiro tenta recuperação leve se o controller for fornecido; se falhar ou não aplicável,
  /// agenda reinicialização controlada via backoff.
  Future<void> _handleStall(String reason, [VideoPlayerController? controller]) async {
    _stallCheckTimer?.cancel();

    // Etapa 3: Tenta recuperação leve se o controlador ainda estiver ativo
    if (controller != null && controller.value.isInitialized && !controller.value.hasError) {
      final softOk = await attemptSoftRecovery(controller);
      if (softOk) {
        // Reinicia monitoramento contínuo
        startStallMonitoring(controller);
        return;
      }
    }

    // Etapa 4: Reconexão completa controlada
    onStateChanged?.call(PlayerRecoveryState.stalled);
    scheduleRetry(reason);
  }

  /// Agenda uma tentativa de reconexão com intervalos progressivos (backoff)
  /// e proteção unificada contra múltiplas chamadas concorrentes.
  void scheduleRetry(String reason) {
    if (_isDisposed) return;

    if (_isReconnecting) {
      debugPrint('[PLAYER STABILITY] Reconexão já em andamento. Aguardando conclusão.');
      return;
    }

    final safeReason = UrlSanitizer.sanitizeErrorMessage(reason);
    final now = DateTime.now();

    // Bloqueia eventos duplicados imediatos gerados pela mesma falha (< 600ms)
    if (safeReason == _lastRetryReason &&
        now.difference(_lastRetryTime) < const Duration(milliseconds: 600)) {
      debugPrint('[PLAYER STABILITY] Evento duplicado de falha ignorado ($safeReason).');
      return;
    }

    _lastRetryReason = safeReason;
    _lastRetryTime = now;

    if (_retryCount >= maxRetries) {
      debugPrint('[PLAYER STABILITY] Limite de tentativas ($maxRetries) excedido.');
      onStateChanged?.call(PlayerRecoveryState.failed);
      onError?.call('Transmissão indisponível no momento após $maxRetries tentativas. Tente novamente mais tarde.');
      return;
    }

    _retryCount++;
    metrics?.markRecoveryStart(_retryCount, now);

    // Intervalo progressivo controlado: 2s, 4s, 8s (backoff exponencial seguro)
    final delaySeconds = 1 << _retryCount;
    final delay = Duration(seconds: delaySeconds);

    debugPrint('[PLAYER STABILITY] Agendando reconexão $_retryCount/$maxRetries em ${delay.inSeconds}s. Motivo: $safeReason');
    onStateChanged?.call(PlayerRecoveryState.retrying);

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () async {
      if (_isDisposed || _isReconnecting) return;
      _isReconnecting = true;
      try {
        if (onReconnectRequest != null) {
          await onReconnectRequest!(_retryCount);
        }
      } catch (e) {
        debugPrint('[PLAYER STABILITY] Erro durante reconexão: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}');
      } finally {
        _isReconnecting = false;
      }
    });
  }

  /// Reseta a contagem de tentativas e o lock de retry quando o stream se estabiliza
  void resetRetries() {
    _retryCount = 0;
    _isReconnecting = false;
    _lastRetryReason = null;
    _notPlayingStartTime = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Cancela e descarta todos os timers e operações pendentes
  void dispose() {
    _isDisposed = true;
    _isReconnecting = false;
    _notPlayingStartTime = null;
    _openTimeoutTimer?.cancel();
    _stallCheckTimer?.cancel();
    _retryTimer?.cancel();
    _openTimeoutTimer = null;
    _stallCheckTimer = null;
    _retryTimer = null;
    onStateChanged?.call(PlayerRecoveryState.cancelled);
  }

  /// Categoriza e sanitiza mensagens de erro para o usuário
  static String categorizeError(dynamic error) {
    final errStr = error.toString().toLowerCase();

    if (errStr.contains('formatexception') || errStr.contains('invalid uri') || errStr.contains('scheme')) {
      return 'Endereço de transmissão inválido ou não suportado.';
    }
    if (errStr.contains('socketexception') || errStr.contains('network') || errStr.contains('connection refused')) {
      return 'Falha de conexão com a rede ou o servidor de transmissão.';
    }
    if (errStr.contains('timeoutexception') || errStr.contains('timed out')) {
      return 'O servidor demorou muito para responder. Verifique sua conexão.';
    }
    if (errStr.contains('401') || errStr.contains('403') || errStr.contains('unauthorized')) {
      return 'Sessão expirada ou acesso não autorizado à transmissão.';
    }
    if (errStr.contains('404') || errStr.contains('not found')) {
      return 'Transmissão não encontrada ou temporariamente fora do ar.';
    }

    return UrlSanitizer.sanitizeErrorMessage(error.toString());
  }
}
