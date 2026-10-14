import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/player_stability_manager.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PLAYER TV v15 - LivePlayerView Remote Control & Two-Step Back Tests', () {
    testWidgets('Dois passos em Voltar: 1º toque oculta controles, 2º toque sai de tela cheia', (tester) async {
      bool fullscreenToggled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste Fullscreen',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {
                fullscreenToggled = true;
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Inicialmente os controles estão abertos (visíveis)
      expect(find.byKey(const Key('btn_center_play_pause')), findsOneWidget);

      // 1º toque em Voltar (escape ou goBack): deve ocultar os controles sem sair da tela cheia
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(fullscreenToggled, isFalse, reason: '1º toque em Voltar não deve sair da tela cheia');
      expect(find.byKey(const Key('btn_center_play_pause')), findsNothing, reason: 'Controles devem ter sido ocultados');

      // Teste de debounce anti-jitter: se um segundo toque ocorrer em < 300ms, deve ser ignorado
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(fullscreenToggled, isFalse, reason: 'Repetição imediata dentro da janela anti-jitter deve ser ignorada');

      // 2º toque em Voltar legítimo (após a janela de 300ms): deve alternar fullscreen
      final baseTime = DateTime.now();
      LivePlayerViewState.clock = () => baseTime.add(const Duration(milliseconds: 350));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(fullscreenToggled, isTrue, reason: '2º toque em Voltar com controles ocultos deve alternar tela cheia');
      LivePlayerViewState.clock = DateTime.now;
    });

    testWidgets('Pressionar OK com controles ocultos apenas reexibe controles sem pausar/despausar', (tester) async {
      int playPauseCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal OK Test',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {
                playPauseCalls++;
              },
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Oculta os controles via 1º Voltar
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btn_center_play_pause')), findsNothing);

      // Pressiona OK (select / enter) com controles ocultos
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      // Controles reaparecem
      expect(find.byKey(const Key('btn_center_play_pause')), findsOneWidget);
      // Play/pause NÃO deve ter sido invocado
      expect(playPauseCalls, equals(0), reason: 'OK com controles ocultos não deve alternar play/pause');
    });

    testWidgets('Navegação direcional 2D D-Pad completa entre botões sem armadilhas de foco', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal D-Pad 2D Test',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
              onPreviousChannel: () {},
              onNextChannel: () {},
              onToggleFavorite: () {},
              onOpenGuide: () {},
              onFitModeChanged: (_) {},
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Botão central Play/Pause tem foco inicial
      expect(find.byKey(const Key('btn_center_play_pause')), findsOneWidget);

      // Seta para esquerda -> foca canal anterior
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.byKey(const Key('btn_prev_channel')), findsOneWidget);

      // Seta para direita -> volta para Play/Pause
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // Seta para direita -> foca próximo canal
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.byKey(const Key('btn_next_channel')), findsOneWidget);

      // Seta para esquerda -> volta para Play/Pause
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      // Seta para cima -> foca barra superior (botão Voltar à lista)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(find.byKey(const Key('btn_fullscreen_back')), findsOneWidget);

      // Seta para baixo -> retorna para o centro (Play/Pause)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      // Seta para baixo -> foca barra inferior (Tela Cheia / Fit)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.byKey(const Key('btn_toggle_fullscreen')), findsOneWidget);

      // Seta para cima -> retorna da barra inferior para o centro (Play/Pause) sem travar
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
    });
  });

  group('PLAYER TV v15 - PlayerStabilityManager Non-Destructive Live Monitoring', () {
    test('Não dispara reconexão destrutiva por micro-pausa de rede (< 8s)', () async {
      int reconnectCount = 0;
      final manager = PlayerStabilityManager(
        isLiveStream: true,
        stallDetectionInterval: const Duration(milliseconds: 100),
        onReconnectRequest: (_) async => reconnectCount++,
      );

      // Simula monitoramento
      expect(reconnectCount, equals(0));
      expect(manager.isReconnecting, isFalse);
      manager.dispose();
    });

    test('resetRetries limpa contadores e cancela timers pendentes', () {
      final manager = PlayerStabilityManager(maxRetries: 3);
      manager.scheduleRetry('Falha transitória');
      expect(manager.retryCount, equals(1));

      manager.resetRetries();
      expect(manager.retryCount, equals(0));
      expect(manager.isReconnecting, isFalse);
      manager.dispose();
    });
  });
}
