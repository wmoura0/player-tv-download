import 'package:flutter/foundation.dart';
import 'url_sanitizer.dart';

/// Tipo de mídia monitorada pelas métricas de reprodução
enum PlaybackMediaType {
  live,
  movie,
  series,
}

/// Coletor e diagnosticador de métricas de desempenho e estabilidade de reprodução.
/// Registra timestamps em microsegundos e calcula intervalos críticos de inicialização,
/// buffering e recuperação, com sanitização estrita de URLs e credenciais.
class PlaybackMetrics {
  final PlaybackMediaType mediaType;
  final String title;

  DateTime? _requestStartTime;
  DateTime? _connectionEstablishedTime;
  DateTime? _playerInitializedTime;
  DateTime? _firstFrameTime;
  DateTime? _bufferingStartTime;
  DateTime? _interruptionTime;
  DateTime? _recoveryStartTime;

  int _bufferingEventCount = 0;
  int _totalBufferingMs = 0;
  int _recoveryAttempts = 0;
  bool _firstFrameLogged = false;

  final String sessionId;

  PlaybackMetrics({
    required this.mediaType,
    required this.title,
    String? sessionId,
  }) : sessionId = sessionId ?? DateTime.now().millisecondsSinceEpoch.toRadixString(16).padLeft(8, '0');

  /// Registra o início da solicitação de reprodução (clique do usuário ou troca de canal)
  void markRequestStart([DateTime? time]) {
    _requestStartTime = time ?? DateTime.now();
    _firstFrameLogged = false;
    _bufferingEventCount = 0;
    _totalBufferingMs = 0;
    _recoveryAttempts = 0;

    final typeTag = _typeTag;
    final safeTitle = UrlSanitizer.sanitizeErrorMessage(title);
    debugPrint('[LIVE_DIAG] [sess:$sessionId] [$typeTag] Início de solicitação: "$safeTitle" às ${_formatTime(_requestStartTime!)}');
  }

  /// Registra o estabelecimento da conexão HTTP/stream
  void markConnectionEstablished([DateTime? time]) {
    _connectionEstablishedTime = time ?? DateTime.now();
    if (_requestStartTime != null) {
      final elapsed = _connectionEstablishedTime!.difference(_requestStartTime!).inMilliseconds;
      debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] Conexão estabelecida em ${elapsed}ms');
    }
  }

  /// Registra o momento em que o player nativo (ExoPlayer) concluiu a inicialização (STATE_READY / prepared)
  void markPlayerInitialized([DateTime? time]) {
    _playerInitializedTime = time ?? DateTime.now();
    if (_requestStartTime != null) {
      final elapsed = _playerInitializedTime!.difference(_requestStartTime!).inMilliseconds;
      debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] Player preparado em ${elapsed}ms (desde a solicitação)');
    }
  }

  /// Registra a renderização do primeiro quadro ou início efetivo do áudio/vídeo
  void markFirstFrame([DateTime? time]) {
    if (_firstFrameLogged) return;
    _firstFrameLogged = true;
    _firstFrameTime = time ?? DateTime.now();

    final totalElapsed = _requestStartTime != null
        ? _firstFrameTime!.difference(_requestStartTime!).inMilliseconds
        : 0;
    final initElapsed = (_playerInitializedTime != null && _requestStartTime != null)
        ? _playerInitializedTime!.difference(_requestStartTime!).inMilliseconds
        : 0;
    final renderElapsed = (_firstFrameTime != null && _playerInitializedTime != null)
        ? _firstFrameTime!.difference(_playerInitializedTime!).inMilliseconds
        : 0;

    debugPrint(
      '[LIVE_DIAG] [sess:$sessionId] [$_typeTag] PRIMEIRO QUADRO EXIBIDO: total=${totalElapsed}ms '
      '(preparo=${initElapsed}ms | render=${renderElapsed}ms)',
    );
  }

  /// Registra o início de um evento de buffering
  void markBufferingStart([DateTime? time]) {
    // Se já houver um intervalo de buffering ativo aberto, ignora chamada redundante
    // para não duplicar eventos nem sobrescrever o início real do intervalo
    if (_bufferingStartTime != null) return;

    _bufferingStartTime = time ?? DateTime.now();
    _bufferingEventCount++;
    debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] Buffering #$_bufferingEventCount iniciado às ${_formatTime(_bufferingStartTime!)}');
  }

  /// Registra o término de um evento de buffering e acumula a duração
  int markBufferingEnd([DateTime? time]) {
    if (_bufferingStartTime == null) return 0;
    final end = time ?? DateTime.now();
    final durMs = end.difference(_bufferingStartTime!).inMilliseconds;
    _totalBufferingMs += durMs;
    _bufferingStartTime = null;

    debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] Buffering finalizado em ${durMs}ms (total acumulado: ${_totalBufferingMs}ms)');
    return durMs;
  }

  /// Indica se há um intervalo de buffering atualmente em aberto
  bool get isBufferingActive => _bufferingStartTime != null;

  /// Registra uma interrupção detectada no stream (queda de socket, travamento ou erro)
  void markInterruption(String reason, [DateTime? time]) {
    _interruptionTime = time ?? DateTime.now();
    final safeReason = UrlSanitizer.sanitizeErrorMessage(reason);
    debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] INTERRUPÇÃO DETECTADA: "$safeReason" às ${_formatTime(_interruptionTime!)}');
  }

  /// Registra o início de uma tentativa de recuperação
  void markRecoveryStart(int attempt, [DateTime? time]) {
    _recoveryAttempts = attempt;
    _recoveryStartTime = time ?? DateTime.now();
    debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] Recuperação tentativa #$attempt iniciada às ${_formatTime(_recoveryStartTime!)}');
  }

  /// Registra a conclusão com sucesso da recuperação
  int markRecoverySuccess([DateTime? time]) {
    final now = time ?? DateTime.now();
    final totalRecoveryMs = _interruptionTime != null
        ? now.difference(_interruptionTime!).inMilliseconds
        : (_recoveryStartTime != null ? now.difference(_recoveryStartTime!).inMilliseconds : 0);

    debugPrint(
      '[LIVE_DIAG] [sess:$sessionId] [$_typeTag] RECUPERAÇÃO CONCLUÍDA com sucesso em ${totalRecoveryMs}ms '
      'após $_recoveryAttempts tentativa(s)',
    );
    _interruptionTime = null;
    _recoveryStartTime = null;
    return totalRecoveryMs;
  }

  /// Registra erro de reprodução de forma segura
  void markError(dynamic error) {
    final safeErr = UrlSanitizer.sanitizeErrorMessage(error.toString());
    debugPrint('[LIVE_DIAG] [sess:$sessionId] [$_typeTag] ERRO: $safeErr');
  }

  // Getters para consulta diagnóstica
  int? get totalStartupMs => (_firstFrameTime != null && _requestStartTime != null)
      ? _firstFrameTime!.difference(_requestStartTime!).inMilliseconds
      : null;

  int? get initDurationMs => (_playerInitializedTime != null && _requestStartTime != null)
      ? _playerInitializedTime!.difference(_requestStartTime!).inMilliseconds
      : null;

  int get bufferingEventCount => _bufferingEventCount;
  int get totalBufferingMs => _totalBufferingMs;
  int get recoveryAttempts => _recoveryAttempts;
  bool get hasFirstFrame => _firstFrameLogged;

  String get _typeTag {
    switch (mediaType) {
      case PlaybackMediaType.live:
        return 'TV AO VIVO';
      case PlaybackMediaType.movie:
        return 'FILME';
      case PlaybackMediaType.series:
        return 'SÉRIE';
    }
  }

  static String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
