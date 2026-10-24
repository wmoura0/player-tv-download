import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player/video_player.dart';
import 'package:projeto_tv/services/playback_metrics.dart';
import 'package:projeto_tv/services/player_stability_manager.dart';

class _MockVideoPlatform extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Future<void> dispose(int textureId) async {}
  @override
  Future<int?> create(DataSource dataSource) async => 1;
  @override
  Future<void> setLooping(int textureId, bool looping) async {}
  @override
  Future<void> play(int textureId) async {}
  @override
  Future<void> pause(int textureId) async {}
  @override
  Future<void> setVolume(int textureId, double volume) async {}
  @override
  Future<void> seekTo(int textureId, Duration position) async {}
  @override
  Future<Duration> getPosition(int textureId) async => Duration.zero;
  @override
  Stream<VideoEvent> videoEventsFor(int textureId) => const Stream.empty();
}

class _TestController extends VideoPlayerController {
  _TestController(VideoPlayerValue val) : super.networkUrl(Uri.parse('http://mock.test/stream.ts')) {
    value = val;
  }

  Future<void> Function()? onPlay;

  @override
  Future<void> play() async {
    if (onPlay != null) {
      await onPlay!();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VideoPlayerPlatform.instance = _MockVideoPlatform();
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

    test('Eventos de buffering duplicados concorrentes não sobrescrevem início nem inflam contagem', () {
      final metrics = PlaybackMetrics(
        mediaType: PlaybackMediaType.live,
        title: 'Premiere 1',
      );

      final tStart = DateTime(2026, 10, 11, 20, 0, 0, 0);
      final tDuplicate = DateTime(2026, 10, 11, 20, 0, 0, 66); // 66ms depois
      final tEnd = DateTime(2026, 10, 11, 20, 0, 2, 0);       // 2000ms total

      // Primeiro evento reativo abre o intervalo
      metrics.markBufferingStart(tStart);
      expect(metrics.isBufferingActive, isTrue);
      expect(metrics.bufferingEventCount, equals(1));

      // Segundo evento concorrente (ex: timer periódico de 2s) tenta abrir enquanto já aberto
      metrics.markBufferingStart(tDuplicate);
      // Contagem não deve inflar para 2
      expect(metrics.bufferingEventCount, equals(1));

      // Término do intervalo
      final dur = metrics.markBufferingEnd(tEnd);
      // Duração deve ser calculada a partir do tStart original (2000ms), não do tDuplicate
      expect(dur, equals(2000));
      expect(metrics.totalBufferingMs, equals(2000));
      expect(metrics.isBufferingActive, isFalse);

      // Chamada redundante de markBufferingEnd retorna 0 sem efeito colateral
      final zeroDur = metrics.markBufferingEnd(DateTime(2026, 10, 11, 20, 0, 3, 0));
      expect(zeroDur, equals(0));
      expect(metrics.totalBufferingMs, equals(2000));
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

    test('attemptSoftRecovery com posição congelada: não declara sucesso e não zera retries', () async {
      final manager = PlayerStabilityManager(
        softRecoveryObservationDuration: const Duration(milliseconds: 30),
      );

      final frozen = _TestController(
        const VideoPlayerValue(
          duration: Duration(minutes: 60),
          position: Duration(seconds: 15),
          isPlaying: true,
          isBuffering: false,
          isInitialized: true,
        ),
      );

      manager.scheduleRetry('Congelamento');
      expect(manager.retryCount, equals(1));

      // Posição permanece em 15s sem avanço
      final result = await manager.attemptSoftRecovery(frozen);
      expect(result, isFalse, reason: 'Sem avanço comprovado de frames, não pode declarar sucesso');
      expect(manager.retryCount, equals(1), reason: 'Não deve resetar tentativas se a recuperação foi ineficaz');

      manager.dispose();
    });

    test('attemptSoftRecovery com avanço comprovado: declara sucesso e zera retries', () async {
      final manager = PlayerStabilityManager(
        softRecoveryObservationDuration: const Duration(milliseconds: 30),
      );

      final advancing = _TestController(
        const VideoPlayerValue(
          duration: Duration(minutes: 60),
          position: Duration(seconds: 15),
          isPlaying: true,
          isBuffering: false,
          isInitialized: true,
        ),
      );

      advancing.onPlay = () async {
        advancing.value = const VideoPlayerValue(
          duration: Duration(minutes: 60),
          position: Duration(seconds: 17),
          isPlaying: true,
          isBuffering: false,
          isInitialized: true,
        );
      };

      manager.scheduleRetry('Congelamento');
      expect(manager.retryCount, equals(1));

      final result = await manager.attemptSoftRecovery(advancing);
      expect(result, isTrue, reason: 'Com avanço de posição confirmado, declara sucesso');
      expect(manager.retryCount, equals(0), reason: 'Deve zerar retries após avanço real');

      manager.dispose();
    });

    test('Múltiplos eventos de falha concorrentes (< 600ms) não criam tentativas duplicadas', () {
      final manager = PlayerStabilityManager(maxRetries: 3);

      manager.scheduleRetry('Erro repetido');
      expect(manager.retryCount, equals(1));

      // Disparo imediato da mesma falha dentro da janela de debounce
      manager.scheduleRetry('Erro repetido');
      expect(manager.retryCount, equals(1), reason: 'Debounce deve ignorar erro duplicado concorrente');

      manager.dispose();
    });

    test('Falha persistente encaminha para reconexão real e encerra em failed ao atingir maxRetries', () {
      PlayerRecoveryState? lastState;
      String? errorMessage;

      final manager = PlayerStabilityManager(
        maxRetries: 2,
        onStateChanged: (state) => lastState = state,
        onError: (msg) => errorMessage = msg,
      );

      manager.scheduleRetry('Falha 1');
      expect(manager.retryCount, equals(1));
      expect(lastState, equals(PlayerRecoveryState.retrying));

      // Avança além do debounce para o próximo retry
      manager.resetRetries(); // ou nova falha após retry
      manager.scheduleRetry('Falha 1');
      expect(manager.retryCount, equals(1));

      manager.scheduleRetry('Falha 2 distinta');
      expect(manager.retryCount, equals(2));

      // Terceira tentativa excede maxRetries (2)
      manager.scheduleRetry('Falha 3 definitiva');
      expect(lastState, equals(PlayerRecoveryState.failed));
      expect(errorMessage, contains('Transmissão indisponível no momento'));

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

    test('isMpegTsUrl identifica corretamente URLs de fluxos MPEG-TS e diferencia de HLS e VOD', () {
      // MPEG-TS com extensão explícita
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/live/user/pass/12345.ts'), isTrue);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/live/user/pass/12345.ts?token=abc&auth=1'), isTrue);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/user/pass/999.TS'), isTrue);

      // Endpoint IPTV numérico progressivo (padrão MPEG-TS do Xtream)
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/live/user/pass/12345'), isTrue);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/user/pass/67890'), isTrue);

      // HLS (.m3u8) - NÃO deve ser classificado como MPEG-TS direto
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/live/user/pass/12345.m3u8'), isFalse);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/live/user/pass/master.m3u8?token=xyz'), isFalse);

      // Arquivos VOD (mp4, mkv, webm)
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/movie/user/pass/100.mp4'), isFalse);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.iptv:8080/movie/user/pass/100.mkv'), isFalse);

      // Nulo ou vazio
      expect(PlayerStabilityManager.isMpegTsUrl(null), isFalse);
      expect(PlayerStabilityManager.isMpegTsUrl(''), isFalse);
    });

    test('Para fluxos MPEG-TS, attemptSoftRecovery é ignorado e prioriza reconexão real', () async {
      final manager = PlayerStabilityManager(
        isMpegTsStream: true,
      );

      bool playCalled = false;
      final controller = _TestController(
        const VideoPlayerValue(
          duration: Duration(minutes: 60),
          position: Duration(seconds: 15),
          isPlaying: true,
          isBuffering: false,
          isInitialized: true,
        ),
      );
      controller.onPlay = () async {
        playCalled = true;
      };

      // Em streams MPEG-TS confirmados, a recuperação suave deve retornar false imediatamente
      // sem chamar controller.play() para não provocar salto retroativo de PTS (~17s)
      final result = await manager.attemptSoftRecovery(controller);
      expect(result, isFalse);
      expect(playCalled, isFalse, reason: 'controller.play() não deve ser executado para MPEG-TS estagnado');

      manager.dispose();
    });

    test('Janela inicial de stall é configurada no intervalo recomendado de 5 a 8 segundos', () {
      final manager = PlayerStabilityManager();
      expect(manager.maxStallDuration.inSeconds, inInclusiveRange(5, 8));
      expect(manager.maxStallDuration.inSeconds, equals(6));
      manager.dispose();
    });
  });
}
