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
  final Future<void> Function(int retryCount)? onReconnectRequest;
  final void Function(String userMessage)? onError;
  final void Function(PlayerRecoveryState state)? onStateChanged;

  PlayerStabilityManager({
    this.maxRetries = 3,
    this.openTimeout = const Duration(seconds: 15),
    this.stallDetectionInterval = const Duration(seconds: 2),
    this.maxStallDuration = const Duration(seconds: 7),
    this.onReconnectRequest,
    this.onError,
    this.onStateChanged,
  });

  Timer? _openTimeoutTimer;
  Timer? _stallCheckTimer;
  Timer? _retryTimer;

  int _retryCount = 0;
  int get retryCount => _retryCount;

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

  /// Inicia monitoramento ativo de travamento/congelamento durante reprodução
  void startStallMonitoring(VideoPlayerController controller) {
    _stallCheckTimer?.cancel();
    _lastPosition = controller.value.position;
    _lastPositionAdvanceTime = DateTime.now();
    _bufferingStartTime = DateTime.now();
    _isBuffering = controller.value.isBuffering;

    _stallCheckTimer = Timer.periodic(stallDetectionInterval, (_) {
      if (_isDisposed || !controller.value.isInitialized) return;

      final val = controller.value;
      final now = DateTime.now();

      // Monitoramento de buffering prolongado
      if (val.isBuffering) {
        if (!_isBuffering) {
          _isBuffering = true;
          _bufferingStartTime = now;
        } else if (now.difference(_bufferingStartTime) > const Duration(seconds: 12)) {
          debugPrint('[PLAYER STABILITY] Buffering estagnado por mais de 12 segundos.');
          _handleStall();
          return;
        }
      } else {
        _isBuffering = false;
      }

      // Monitoramento de reprodução parada (isPlaying mas posição congelada)
      if (val.isPlaying && !val.isBuffering) {
        if (val.position != _lastPosition) {
          _lastPosition = val.position;
          _lastPositionAdvanceTime = now;
        } else if (now.difference(_lastPositionAdvanceTime) > maxStallDuration) {
          debugPrint('[PLAYER STABILITY] Reprodução congelada por mais de ${maxStallDuration.inSeconds} segundos.');
          _handleStall();
        }
      }
    });
  }

  void _handleStall() {
    _stallCheckTimer?.cancel();
    onStateChanged?.call(PlayerRecoveryState.stalled);
    scheduleRetry('A transmissão parou de responder. Tentando reconectar...');
  }

  /// Agenda uma tentativa de reconexão com intervalos progressivos (backoff)
  void scheduleRetry(String reason) {
    if (_isDisposed) return;

    if (_retryCount >= maxRetries) {
      debugPrint('[PLAYER STABILITY] Limite de tentativas ($maxRetries) excedido.');
      onStateChanged?.call(PlayerRecoveryState.failed);
      onError?.call('Transmissão indisponível no momento após $maxRetries tentativas. Tente novamente mais tarde.');
      return;
    }

    _retryCount++;
    // Intervalo progressivo: 1.5s, 3.0s, 5.0s
    final delaySeconds = (_retryCount * 1.5).round();
    final delay = Duration(seconds: delaySeconds);

    debugPrint('[PLAYER STABILITY] Agendando reconexão $_retryCount/$maxRetries em ${delay.inSeconds}s. Motivo: $reason');
    onStateChanged?.call(PlayerRecoveryState.retrying);

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () async {
      if (_isDisposed) return;
      if (onReconnectRequest != null) {
        await onReconnectRequest!(_retryCount);
      }
    });
  }

  /// Reseta a contagem de tentativas quando o stream se estabiliza
  void resetRetries() {
    _retryCount = 0;
  }

  /// Cancela e descarta todos os timers e operações pendentes
  void dispose() {
    _isDisposed = true;
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
