import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/playback_metrics.dart';
import 'package:projeto_tv/services/player_stability_manager.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PLAYER TV v16 - LivePlayerView Debounce & Buffering Overlay Tests', () {
    testWidgets('Micro-jitter de buffer (< 700ms) não exibe overlay de carregamento na tela', (tester) async {
      bool buffering = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return LivePlayerView(
                  controller: null,
                  channelName: 'Canal Teste Micro-Jitter',
                  isFullscreen: true,
                  isLoading: false,
                  isBuffering: buffering,
                  onTogglePlayPause: () {},
                  onToggleFullscreen: () {},
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Carregando transmissão...'), findsNothing);
      expect(find.text('Conectando ao canal...'), findsNothing);

      // Simula início de micro-jitter (ex: 300ms de oscilação de pacote)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste Micro-Jitter',
              isFullscreen: true,
              isLoading: false,
              isBuffering: true,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      // Avança 350ms (abaixo do grace period de 700ms)
      await tester.pump(const Duration(milliseconds: 350));

      // Não deve exibir overlay nem bloquear a tela para hesitação de 350ms
      expect(
        find.text('Carregando transmissão...'),
        findsNothing,
        reason: 'Micro-oscilações transitórias de buffer não devem piscar tela escura nem spinner',
      );

      // Buffer normaliza antes de estourar o grace period
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste Micro-Jitter',
              isFullscreen: true,
              isLoading: false,
              isBuffering: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Carregando transmissão...'), findsNothing);
    });

    testWidgets('Buffering sustentado (> 700ms) exibe indicador de carregamento e oculta ao normalizar', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste Real Buffering',
              isFullscreen: true,
              isLoading: false,
              isBuffering: true,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      // Avança 750ms (acima do grace period de 700ms)
      await tester.pump(const Duration(milliseconds: 750));

      // Agora que a estagnação é real, deve exibir o indicador claramente
      expect(
        find.text('Carregando transmissão...'),
        findsOneWidget,
        reason: 'Buffering real sustentado deve exibir indicador visual de carregamento',
      );

      // Quando a transmissão normaliza (isBuffering = false), o indicador deve sumir imediatamente
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste Real Buffering',
              isFullscreen: true,
              isLoading: false,
              isBuffering: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('Carregando transmissão...'), findsNothing);
    });

    testWidgets('isLoading inicial exibe Conectando ao canal imediatamente sem esperar grace period', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste Abertura',
              isFullscreen: true,
              isLoading: true,
              isBuffering: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      // Imediatamente no primeiro frame
      await tester.pump();
      expect(find.text('Conectando ao canal...'), findsOneWidget);
    });
  });

  group('PLAYER TV v16 - PlayerStabilityManager & LIVE_DIAG Tests', () {
    test('PlaybackMetrics gera sessionId e tags LIVE_DIAG estruturadas', () {
      final metrics = PlaybackMetrics(
        mediaType: PlaybackMediaType.live,
        title: 'Canal Teste Diagnóstico',
      );

      expect(metrics.sessionId, isNotEmpty);
      expect(metrics.sessionId.length, greaterThanOrEqualTo(8));

      metrics.markRequestStart();
      metrics.markConnectionEstablished();
      metrics.markPlayerInitialized();
      metrics.markFirstFrame();
      metrics.markBufferingStart();
      metrics.markBufferingEnd();
      metrics.markRecoverySuccess();

      expect(metrics.totalStartupMs, isNotNull);
    });

    test('PlayerStabilityManager não dispara reconexões desnecessárias durante oscilação transitória', () {
      int reconnectAttempts = 0;
      final manager = PlayerStabilityManager(
        isLiveStream: true,
        maxRetries: 3,
        onReconnectRequest: (count) async {
          reconnectAttempts = count;
        },
      );

      expect(manager.isReconnecting, isFalse);
      expect(manager.retryCount, equals(0));

      manager.scheduleRetry('Oscilação de teste');
      expect(manager.retryCount, equals(1));

      manager.resetRetries();
      expect(manager.retryCount, equals(0));
      expect(reconnectAttempts, equals(0));
      manager.dispose();
    });

    test('Transmissão estabilizada com avanço contínuo zera contador de retries sem reconectar', () {
      final manager = PlayerStabilityManager(
        isLiveStream: true,
        maxRetries: 3,
      );

      manager.scheduleRetry('Oscilação passageira');
      expect(manager.retryCount, equals(1));

      // Após normalização, resetRetries zera as tentativas mantendo a conexão ativa
      manager.resetRetries();
      expect(manager.retryCount, equals(0));
      expect(manager.isReconnecting, isFalse);

      manager.dispose();
    });

    test('Protege contra reconexões simultâneas e mantém tolerância a microbuffering', () {
      int reconnectInvocationCount = 0;
      final manager = PlayerStabilityManager(
        isLiveStream: true,
        isMpegTsStream: true,
        maxRetries: 3,
        onReconnectRequest: (count) async {
          reconnectInvocationCount++;
        },
      );

      expect(manager.isMpegTsStream, isTrue);
      expect(manager.maxStallDuration.inSeconds, equals(6));
      expect(reconnectInvocationCount, equals(0));

      // Dispara primeiro agendamento
      manager.scheduleRetry('Congelamento comprovado');
      expect(manager.retryCount, equals(1));

      // Tentativa simultânea imediata é rejeitada por debounce e lock
      manager.scheduleRetry('Congelamento comprovado');
      expect(manager.retryCount, equals(1), reason: 'Reconexão simultânea duplicada deve ser bloqueada');

      manager.dispose();
    });

    testWidgets('LivePlayerView em tela cheia preserva controles, foco e proporção sem piscar tela', (tester) async {
      LiveVideoFitMode currentFit = LiveVideoFitMode.contain;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return LivePlayerView(
                  controller: null,
                  channelName: 'CNN Brasil',
                  groupTitle: 'Notícias',
                  isFullscreen: true,
                  isLoading: false,
                  isBuffering: false,
                  fitMode: currentFit,
                  onFitModeChanged: (mode) {
                    setState(() => currentFit = mode);
                  },
                  onTogglePlayPause: () {},
                  onToggleFullscreen: () {},
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('CNN Brasil'), findsWidgets);
      expect(find.text('Original'), findsOneWidget);

      // Alterna modo de proporção
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(currentFit, equals(LiveVideoFitMode.cover));
      expect(find.text('Preencher'), findsOneWidget);
    });
  });
}
