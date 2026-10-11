import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
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

/// Gerenciador de estabilidade, detecção de travamento (stall), timeout e reconexão progressiva do player.
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

  PlayerStabilityManager({
    this.maxRetries = 3,
    this.openTimeout = const Duration(seconds: 15),
    this.stallDetectionInterval = const Duration(seconds: 2),
    this.maxStallDuration = const Duration(seconds: 15),
    this.maxBufferingDuration = const Duration(seconds: 25),
    this.isLiveStream = true,
    this.onReconnectRequest,
    this.onError,
    this.onStateChanged,
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
  /// Para transmissões ao vivo (`isLive: true`), tolera variações e não utiliza
  /// a posição estática da timeline para forçar reinícios indevidos.
  void startStallMonitoring(VideoPlayerController controller, {bool? isLive}) {
    _stallCheckTimer?.cancel();
    _lastPosition = controller.value.position;
    _lastPositionAdvanceTime = DateTime.now();
    _bufferingStartTime = DateTime.now();
    _isBuffering = controller.value.isBuffering;

    final live = isLive ?? isLiveStream;

    _stallCheckTimer = Timer.periodic(stallDetectionInterval, (_) {
      if (_isDisposed || !controller.value.isInitialized) return;

      final val = controller.value;
      final now = DateTime.now();

      // Monitoramento de buffering prolongado com alta tolerância (25s) para variações de rede
      if (val.isBuffering) {
        if (!_isBuffering) {
          _isBuffering = true;
          _bufferingStartTime = now;
        } else if (now.difference(_bufferingStartTime) > maxBufferingDuration) {
          debugPrint('[PLAYER STABILITY] Buffering estagnado por mais de ${maxBufferingDuration.inSeconds} segundos.');
          _handleStall('Buffering contínuo estagnado');
          return;
        }
      } else {
        _isBuffering = false;
      }

      // Em canais ao vivo (live streams), o relógio de posição pode ser constante (0:00) ou
      // atrelado a chunks temporários da playlist HLS/TS. Não usamos a posição para disparar
      // reconexões se o player estiver tocando normalmente sem buffering.
      if (!live && val.isPlaying && !val.isBuffering) {
        if (val.position != _lastPosition) {
          _lastPosition = val.position;
          _lastPositionAdvanceTime = now;
        } else if (now.difference(_lastPositionAdvanceTime) > maxStallDuration) {
          debugPrint('[PLAYER STABILITY] Reprodução congelada por mais de ${maxStallDuration.inSeconds} segundos.');
          _handleStall('Reprodução congelada');
        }
      }
    });
  }

  String? _lastRetryReason;
  DateTime _lastRetryTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pausa temporariamente os temporizadores de monitoramento (ex: app em background)
  void pauseMonitoring() {
    _openTimeoutTimer?.cancel();
    _stallCheckTimer?.cancel();
    _openTimeoutTimer = null;
    _stallCheckTimer = null;
  }

  /// Tenta recuperação suave sem desmontar o controlador.
  /// Se o controlador for um stream HLS ao vivo com janela de timeline,
  /// posiciona na borda mais recente (live edge) para evitar reprisar trechos antigos.
  Future<bool> attemptSoftRecovery(VideoPlayerController? controller) async {
    if (controller == null || _isDisposed || !controller.value.isInitialized || controller.value.hasError) {
      return false;
    }
    try {
      if (isLiveStream && controller.value.duration > const Duration(seconds: 2)) {
        await controller.seekTo(controller.value.duration);
      }
      await controller.play();
      return true;
    } catch (e) {
      debugPrint('[PLAYER STABILITY] Falha na recuperação suave: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}');
      return false;
    }
  }

  void _handleStall([String? reason]) {
    _stallCheckTimer?.cancel();
    onStateChanged?.call(PlayerRecoveryState.stalled);
    scheduleRetry(reason ?? 'A transmissão parou de responder. Tentando reconectar...');
  }

  /// Agenda uma tentativa de reconexão com intervalos progressivos (backoff)
  /// e proteção contra múltiplas chamadas concorrentes.
  void scheduleRetry(String reason) {
    if (_isDisposed) return;

    if (_isReconnecting) {
      debugPrint('[PLAYER STABILITY] Reconexão já em andamento. Aguardando conclusão.');
      return;
    }

    final safeReason = UrlSanitizer.sanitizeErrorMessage(reason);
    final now = DateTime.now();

    // Bloqueia eventos duplicados imediatos gerados pela mesma falha
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
    // Intervalo progressivo: 2s, 4s, 8s (backoff exponencial controlado)
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
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Cancela e descarta todos os timers e operações pendentes
  void dispose() {
    _isDisposed = true;
    _isReconnecting = false;
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
