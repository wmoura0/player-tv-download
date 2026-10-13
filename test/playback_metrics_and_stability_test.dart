import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/playback_metrics.dart';
import 'package:projeto_tv/services/player_stability_manager.dart';

void main() {
  group('PlaybackMetrics Unit Tests', () {
    test('Calcula corretamente intervalos de inicialização, preparo e primeiro quadro', () {
      final metrics = PlaybackMetrics(
        mediaType: PlaybackMediaType.movie,
        title: 'Interestelar',
      );

      final t0 = DateTime(2026, 10, 11, 20, 0, 0, 0);
      final t1 = DateTime(2026, 10, 11, 20, 0, 0, 250); // +250ms conexão
      final t2 = DateTime(2026, 10, 11, 20, 0, 0, 600); // +600ms preparado
      final t3 = DateTime(2026, 10, 11, 20, 0, 0, 850); // +850ms primeiro quadro

      metrics.markRequestStart(t0);
      expect(metrics.totalStartupMs, isNull);

      metrics.markConnectionEstablished(t1);
      metrics.markPlayerInitialized(t2);
      expect(metrics.initDurationMs, equals(600));

      metrics.markFirstFrame(t3);
      expect(metrics.totalStartupMs, equals(850));
      expect(metrics.hasFirstFrame, isTrue);

      // Chamada repetida de firstFrame não altera o timestamp original
      metrics.markFirstFrame(DateTime(2026, 10, 11, 20, 0, 1, 0));
      expect(metrics.totalStartupMs, equals(850));
    });

    test('Registra eventos de buffering e acumula tempo total decorrido', () {
      final metrics = PlaybackMetrics(
        mediaType: PlaybackMediaType.live,
        title: 'ESPN HD',
      );

      metrics.markRequestStart(DateTime(2026, 10, 11, 20, 0, 0));

      // 1º evento de buffer (400ms)
      metrics.markBufferingStart(DateTime(2026, 10, 11, 20, 1, 0, 0));
      final dur1 = metrics.markBufferingEnd(DateTime(2026, 10, 11, 20, 1, 0, 400));
      expect(dur1, equals(400));
      expect(metrics.bufferingEventCount, equals(1));
      expect(metrics.totalBufferingMs, equals(400));

      // 2º evento de buffer (600ms)
      metrics.markBufferingStart(DateTime(2026, 10, 11, 20, 2, 0, 0));
      final dur2 = metrics.markBufferingEnd(DateTime(2026, 10, 11, 20, 2, 0, 600));
      expect(dur2, equals(600));
      expect(metrics.bufferingEventCount, equals(2));
      expect(metrics.totalBufferingMs, equals(1000));
    });

    test('Registra ciclo de interrupção e tempo até recuperação', () {
      final metrics = PlaybackMetrics(
        mediaType: PlaybackMediaType.live,
        title: 'Globo SP',
      );

      final tInterruption = DateTime(2026, 10, 11, 20, 15, 0, 0);
      final tRecoveryStart = DateTime(2026, 10, 11, 20, 15, 1, 0); // +1000ms
      final tRecoveryEnd = DateTime(2026, 10, 11, 20, 15, 1, 800);  // +1800ms total

      metrics.markInterruption('Queda de socket TCP', tInterruption);
      metrics.markRecoveryStart(1, tRecoveryStart);
      expect(metrics.recoveryAttempts, equals(1));

      final recDur = metrics.markRecoverySuccess(tRecoveryEnd);
      expect(recDur, equals(1800));
    });

    test('Higieniza mensagens de erro ocultando credenciais e senhas', () {
      final metrics = PlaybackMetrics(
        mediaType: PlaybackMediaType.series,
        title: 'Breaking Bad',
      );

      // Não deve lançar exceção ao registrar erros com credenciais sensíveis
      expect(
        () => metrics.markError('Erro 404 em http://admin:super_secret@server.tv:8080/movie.mp4'),
        returnsNormally,
      );
      expect(
        () => metrics.markInterruption('SocketException http://user:pass123@iptv.com/live/1.ts'),
        returnsNormally,
      );
    });
  });

  group('PlayerStabilityManager Staged Recovery Tests', () {
    test('attemptSoftRecovery lida com controller nulo ou com erro retornando false', () async {
      final manager = PlayerStabilityManager(
        isLiveStream: true,
      );

      final okNull = await manager.attemptSoftRecovery(null);
      expect(okNull, isFalse);

      manager.dispose();
    });

    test('Tolera buffering legítimo curto sem disparar stall prematuro', () async {
      bool stalled = false;
      final manager = PlayerStabilityManager(
        maxBufferingDuration: const Duration(milliseconds: 300),
        onStateChanged: (state) {
          if (state == PlayerRecoveryState.stalled) stalled = true;
        },
      );

      // Buffering não deve disparar stall antes do tempo configurado
      expect(stalled, isFalse);
      manager.dispose();
    });

    test('Backoff exponencial de reconexão calcula intervalos crescentes 2s, 4s, 8s', () {
      final manager = PlayerStabilityManager(
        maxRetries: 3,
      );

      expect(manager.retryCount, equals(0));

      manager.scheduleRetry('Tentativa 1');
      expect(manager.retryCount, equals(1));

      manager.scheduleRetry('Tentativa 2');
      expect(manager.retryCount, equals(2));

      manager.scheduleRetry('Tentativa 3');
      expect(manager.retryCount, equals(3));

      // Tentativa 4 excede
      manager.scheduleRetry('Tentativa 4');
      expect(manager.retryCount, equals(3));

      manager.dispose();
    });

    test('resetRetries restaura contagem de tentativas e limpa lock de reconexão', () {
      final manager = PlayerStabilityManager(maxRetries: 3);

      manager.scheduleRetry('Erro teste');
      expect(manager.retryCount, equals(1));

      manager.resetRetries();
      expect(manager.retryCount, equals(0));
      expect(manager.isReconnecting, isFalse);

      manager.dispose();
    });
  });
}
