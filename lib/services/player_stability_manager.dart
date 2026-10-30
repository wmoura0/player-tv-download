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
  final Duration softRecoveryObservationDuration;
  final Duration stabilityThreshold;
  final bool isLiveStream;
  bool isMpegTsStream;
  final Future<void> Function(int retryCount)? onReconnectRequest;
  final VoidCallback? onStabilityConfirmed;
  final void Function(String userMessage)? onError;
  final void Function(PlayerRecoveryState state)? onStateChanged;
  PlaybackMetrics? metrics;

  PlayerStabilityManager({
    this.maxRetries = 3,
    this.openTimeout = const Duration(seconds: 15),
    this.stallDetectionInterval = const Duration(seconds: 2),
    this.maxStallDuration = const Duration(seconds: 6),
    this.maxBufferingDuration = const Duration(seconds: 15),
    this.softRecoveryObservationDuration = const Duration(milliseconds: 1000),
    this.stabilityThreshold = const Duration(seconds: 15),
    this.isLiveStream = true,
    this.isMpegTsStream = false,
    this.onReconnectRequest,
    this.onStabilityConfirmed,
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

  bool _hasAttemptedJitterSoftPlay = false;

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
  void startStallMonitoring(VideoPlayerController controller, {bool? isLive, bool? isMpegTs}) {
    if (isMpegTs != null) {
      isMpegTsStream = isMpegTs;
    }
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

      // 2. Monitoramento de buffering legítimo com janela de tolerância a microbuffering
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

      // 3. Monitoramento de interrupção de reprodução (STATE_ENDED / estagnação sem buffer)
      // Em transmissões ao vivo (MPEG-TS/HLS), micro-pausas transitórias de buffer (jitter de 500ms a 3s)
      // ocorrem com frequência no Fire TV. Não desconectar prematuramente nem reiniciar o socket!
      if (live && !val.isPlaying && !val.isBuffering && !_isUserPaused) {
        _notPlayingStartTime ??= now;
        final uninterruptedNonPlaying = now.difference(_notPlayingStartTime!);

        // Para fluxos que não sejam MPEG-TS, tenta manter pipeline nativo ativo via soft play
        // somente uma vez após tolerância inicial de micro-jitter (1.5s).
        // Disparar controller.play() repetitivamente a cada ciclo forçava o ExoPlayer a sair
        // prematuramente do estado de re-buffering antes de recompor a SampleQueue, gerando
        // micro-travamentos recorrentes de alguns segundos.
        if (!isMpegTsStream && !_hasAttemptedJitterSoftPlay && uninterruptedNonPlaying >= const Duration(milliseconds: 1500)) {
          _hasAttemptedJitterSoftPlay = true;
          controller.play().catchError((_) {});
        }

        // Janela de stall configurada (padrão 6s, 5 a 8 segundos recomendados)
        if (uninterruptedNonPlaying >= maxStallDuration) {
          debugPrint(
            '[PLAYER STABILITY] Transmissão estagnada há ${uninterruptedNonPlaying.inSeconds}s (sem dados e sem buffer). Iniciando recuperação...',
          );
          metrics?.markInterruption('Conexão estagnada por mais de ${maxStallDuration.inSeconds}s');
          _notPlayingStartTime = null;
          _hasAttemptedJitterSoftPlay = false;
          _handleStall('Conexão com a transmissão ao vivo encerrada', controller);
          return;
        }
      } else {
        _notPlayingStartTime = null;
        _hasAttemptedJitterSoftPlay = false;
      }

      // 4. Detecção de congelamento de frames / estagnação de posição
      // Diferenciação estrita entre VOD e Live TV:
      if (val.isPlaying && !val.isBuffering && !_isUserPaused) {
        if (val.position > _lastPosition) {
          _lastPosition = val.position;
          _lastPositionAdvanceTime = now;
        }

        // VOD (Filmes e Séries): onde val.position é um indicador temporal contínuo e mensurável.
        // Se a posição de VOD parar de avançar durante reprodução ativa além de maxStallDuration,
        // aciona a recuperação específica de congelamento.
        if (!live) {
          final stallDuration = now.difference(_lastPositionAdvanceTime);
          if (stallDuration > maxStallDuration) {
            debugPrint('[PLAYER STABILITY] Reprodução de VOD congelada por mais de ${stallDuration.inSeconds} segundos.');
            metrics?.markInterruption('VOD congelado (${stallDuration.inSeconds}s)');
            _handleStall('Reprodução congelada', controller);
            return;
          }
        }

        // LIVE TV: Em transmissões ao vivo progressivas/dinâmicas no Flutter, a propriedade
        // val.position é estática ou limitada pela duração do buffer inicial (clamped), não refletindo
        // o avanço real de quadros do decodificador nativo. Para não provocar falsos congelamentos a cada
        // poucos segundos, a posição estática NUNCA é utilizada isoladamente para destruir o player ao vivo.
        // Em live TV, a perda real de transmissão é detectada com confiabilidade por:
        // - Buffering persistente estagnado (> maxBufferingDuration no Bloco 2)
        // - Queda de conexão / encerramento do stream pelo servidor (> maxStallDuration no Bloco 3)
        // - Falha interna ou erro de decodificação reportado pelo player (Bloco 1)
      }

      // 5. Confirmação real e documentada de estabilidade da transmissão
      if (val.isPlaying && !val.isBuffering && !val.hasError && !_isUserPaused) {
        _playbackStabilizedStartTime ??= now;
        final stableDuration = now.difference(_playbackStabilizedStartTime!);
        if (stableDuration >= stabilityThreshold) {
          if (_retryCount > 0) {
            debugPrint(
              '[PLAYER STABILITY] Transmissão estabilizada após ${stableDuration.inSeconds}s '
              'de reprodução ininterrupta. Resetando contadores de reconexão.',
            );
            metrics?.markRecoverySuccess();
            _retryCount = 0;
            _lastRetryReason = null;
            onStabilityConfirmed?.call();
          }
        }
      } else {
        _playbackStabilizedStartTime = null;
      }
    });
  }

  DateTime? _notPlayingStartTime;
  DateTime? _playbackStabilizedStartTime;
  String? _lastRetryReason;
  DateTime _lastRetryTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pausa temporariamente os temporizadores de monitoramento (ex: app em background)
  void pauseMonitoring() {
    _openTimeoutTimer?.cancel();
    _stallCheckTimer?.cancel();
    _openTimeoutTimer = null;
    _stallCheckTimer = null;
    _notPlayingStartTime = null;
    _playbackStabilizedStartTime = null;
  }

  /// Etapa 3: Tenta recuperação leve (soft recovery) sem destruir o controlador.
  /// Requisito estrito: NÃO considerar isPlaying == true ou isBuffering == true
  /// isoladamente como sucesso. A posição deve avançar comprovadamente durante
  /// a janela de observação para certificar que o pipeline de decodificação voltou a renderizar.
  /// Para fluxos MPEG-TS confirmados, a recuperação suave é ignorada para evitar saltos retroativos
  /// de PTS causados pelo replay de buffers obsoletos da SampleQueue do ExoPlayer.
  Future<bool> attemptSoftRecovery(VideoPlayerController? controller) async {
    if (controller == null || _isDisposed || !controller.value.isInitialized || controller.value.hasError) {
      return false;
    }

    if (isMpegTsStream) {
      debugPrint(
        '[PLAYER STABILITY] Fluxo MPEG-TS detectado: soft recovery ignorada para evitar saltos retroativos de PTS. Priorizando reconexão real.',
      );
      return false;
    }

    try {
      debugPrint('[PLAYER STABILITY] Tentando recuperação leve (soft play)...');
      final posBefore = controller.value.position;

      await controller.play();

      // Janela de observação para confirmar avanço real da reprodução
      await Future<void>.delayed(softRecoveryObservationDuration);

      if (_isDisposed || !controller.value.isInitialized || controller.value.hasError) {
        return false;
      }

      final posAfter = controller.value.position;
      final isPlaying = controller.value.isPlaying;
      final isBuffering = controller.value.isBuffering;

      // Confirmação de avanço real:
      // 1. A posição deve ter avançado em relação à posição inicial (posAfter > posBefore)
      // 2. O player deve estar efetivamente reproduzindo (isPlaying == true)
      // 3. O player NÃO deve estar estagnado em buffering no final da janela
      final hasAdvanced = posAfter > posBefore;

      if (hasAdvanced && isPlaying && !isBuffering) {
        debugPrint(
          '[PLAYER STABILITY] Recuperação leve bem-sucedida! Avanço confirmado: '
          '${posBefore.inMilliseconds}ms -> ${posAfter.inMilliseconds}ms',
        );
        metrics?.markRecoverySuccess();
        resetRetries();
        return true;
      }

      debugPrint(
        '[PLAYER STABILITY] Recuperação leve ineficaz (sem avanço comprovado: '
        'posBefore=${posBefore.inMilliseconds}ms, posAfter=${posAfter.inMilliseconds}ms, '
        'isPlaying=$isPlaying, isBuffering=$isBuffering). Prosseguindo para reconexão real...',
      );
      return false;
    } catch (e) {
      debugPrint('[PLAYER STABILITY] Falha na recuperação leve: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}');
      return false;
    }
  }

  /// Trata stall aplicando recuperação em etapas:
  /// Primeiro tenta recuperação leve se o controlador for fornecido, se o fluxo NÃO for MPEG-TS,
  /// e se ainda não houver retries acumulados (_retryCount == 0);
  /// se falhar, se for MPEG-TS ou já estivermos em ciclo de retries, agenda reinicialização controlada via backoff.
  Future<void> _handleStall(String reason, [VideoPlayerController? controller]) async {
    _stallCheckTimer?.cancel();

    // Etapa 3: Tenta recuperação leve se o controlador ainda estiver ativo,
    // o fluxo NÃO for MPEG-TS e ainda não estivermos no meio de um ciclo de retries (_retryCount == 0).
    // Para MPEG-TS comprovado, prioriza reconexão real direta para restabelecer na borda ao vivo.
    if (!isMpegTsStream && _retryCount == 0 && controller != null && controller.value.isInitialized && !controller.value.hasError) {
      final softOk = await attemptSoftRecovery(controller);
      if (softOk) {
        // Reinicia monitoramento contínuo se realmente estabilizou e avançou
        startStallMonitoring(controller);
        return;
      }
    }

    // Etapa 4: Reconexão completa controlada (hard recovery)
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
    _hasAttemptedJitterSoftPlay = false;
    _playbackStabilizedStartTime = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Cancela e descarta todos os timers e operações pendentes
  void dispose() {
    _isDisposed = true;
    _isReconnecting = false;
    _notPlayingStartTime = null;
    _hasAttemptedJitterSoftPlay = false;
    _playbackStabilizedStartTime = null;
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

  /// Identifica com precisão se uma URL de stream corresponde ao formato MPEG-TS (.ts ou endpoint progressivo)
  static bool isMpegTsUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    final clean = url.trim().toLowerCase();
    final uri = Uri.tryParse(clean);
    final path = uri?.path ?? clean;

    if (path.endsWith('.ts')) return true;
    if (path.contains('.ts?') || path.contains('.ts&')) return true;

    // Se for formato explicitamente HLS ou contêiner de arquivo, não é TS direto
    if (path.contains('.m3u8') || path.contains('.mp4') || path.contains('.mkv') || path.contains('.webm')) {
      return false;
    }

    // Endpoints IPTV numéricos sem extensão (ex: /live/user/pass/123 ou /user/pass/123)
    // são entregues nativamente pelos servidores Xtream como MPEG-TS progressivo.
    final segments = uri?.pathSegments ?? [];
    if (segments.isNotEmpty) {
      final last = segments.last;
      if (int.tryParse(last) != null && !path.contains('.')) {
        return true;
      }
    }
    return false;
  }
}
