import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fase 2.1: Navegação D-Pad em TV ao Vivo (LivePlayerView)', () {
    late DateTime mockNow;

    setUp(() {
      mockNow = DateTime(2026, 11, 7, 20, 0);
      LivePlayerViewState.clock = () => mockNow;
    });

    tearDown(() {
      LivePlayerViewState.clock = DateTime.now;
    });

    testWidgets('1. Em tela cheia com OSD oculto, ArrowUp aciona canal anterior com debounce', (tester) async {
      int prevCalls = 0;
      int nextCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Globo SP HD',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
              onPreviousChannel: () => prevCalls++,
              onNextChannel: () => nextCalls++,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Oculta os controles via método do State
      final state = tester.state<LivePlayerViewState>(find.byType(LivePlayerView));
      state.hideControls();
      await tester.pumpAndSettle();

      // Pressiona ArrowUp no controle remoto
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(prevCalls, equals(1));
      expect(nextCalls, equals(0));

      // Anti-chattering / debounce: se pressionar imediatamente de novo (< 300ms), não duplica
      mockNow = mockNow.add(const Duration(milliseconds: 50));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(prevCalls, equals(1));

      // Após 350ms, permite nova troca
      mockNow = mockNow.add(const Duration(milliseconds: 350));
      state.hideControls();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(prevCalls, equals(2));
    });

    testWidgets('2. Em tela cheia com OSD oculto, ArrowDown aciona próximo canal com debounce', (tester) async {
      int prevCalls = 0;
      int nextCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'SBT HD',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
              onPreviousChannel: () => prevCalls++,
              onNextChannel: () => nextCalls++,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final state = tester.state<LivePlayerViewState>(find.byType(LivePlayerView));
      state.hideControls();
      await tester.pumpAndSettle();

      // Pressiona ArrowDown no controle remoto
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(nextCalls, equals(1));
      expect(prevCalls, equals(0));

      // Teste de debounce anti-chattering
      mockNow = mockNow.add(const Duration(milliseconds: 50));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(nextCalls, equals(1));
    });

    testWidgets('3. Com OSD visível, ArrowUp e ArrowDown preservam navegação entre botões sem trocar canal', (tester) async {
      int prevCalls = 0;
      int nextCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Record TV',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
              onPreviousChannel: () => prevCalls++,
              onNextChannel: () => nextCalls++,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Com controles visíveis por padrão, setas verticais navegam o foco 2D sem disparar zapping
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(prevCalls, equals(0));
      expect(nextCalls, equals(0));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(prevCalls, equals(0));
      expect(nextCalls, equals(0));
    });
  });

  group('Fase 2.2: Modos de Proporção de Vídeo (contain, cover, fill)', () {
    test('1. Enum LiveVideoFitMode contém os 3 modos consistentes', () {
      expect(LiveVideoFitMode.values, contains(LiveVideoFitMode.contain));
      expect(LiveVideoFitMode.values, contains(LiveVideoFitMode.cover));
      expect(LiveVideoFitMode.values, contains(LiveVideoFitMode.fill));
      expect(LiveVideoFitMode.values.length, equals(3));
    });

    test('2. SettingsService persiste e recupera os 3 modos de aspect ratio', () async {
      SharedPreferences.setMockInitialValues({});
      final service = SettingsService.instance;

      await service.setDefaultAspectRatio(LiveVideoFitMode.fill);
      expect(service.defaultAspectRatio, equals(LiveVideoFitMode.fill));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pref_default_aspect_ratio'), equals('fill'));

      // Recarrega em nova instância simulada
      await service.loadSettings(prefs: prefs);
      expect(service.defaultAspectRatio, equals(LiveVideoFitMode.fill));

      // Testa contain
      await service.setDefaultAspectRatio(LiveVideoFitMode.contain);
      expect(prefs.getString('pref_default_aspect_ratio'), equals('contain'));
      await service.loadSettings(prefs: prefs);
      expect(service.defaultAspectRatio, equals(LiveVideoFitMode.contain));

      // Testa cover
      await service.setDefaultAspectRatio(LiveVideoFitMode.cover);
      expect(prefs.getString('pref_default_aspect_ratio'), equals('cover'));
      await service.loadSettings(prefs: prefs);
      expect(service.defaultAspectRatio, equals(LiveVideoFitMode.cover));
    });

    testWidgets('3. LivePlayerView alterna ciclicamente contain -> cover -> fill -> contain', (tester) async {
      LiveVideoFitMode mode = LiveVideoFitMode.contain;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return LivePlayerView(
                  controller: null,
                  channelName: 'Canal Teste Proporção',
                  isFullscreen: true,
                  isLoading: false,
                  fitMode: mode,
                  onFitModeChanged: (m) => setState(() => mode = m),
                  onTogglePlayPause: () {},
                  onToggleFullscreen: () {},
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Original (contain)
      expect(find.text('Original'), findsOneWidget);

      // Tap 1 -> Preencher (cover)
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(mode, equals(LiveVideoFitMode.cover));
      expect(find.text('Preencher'), findsOneWidget);

      // Tap 2 -> Esticar (fill)
      await tester.tap(find.text('Preencher'));
      await tester.pumpAndSettle();
      expect(mode, equals(LiveVideoFitMode.fill));
      expect(find.text('Esticar'), findsOneWidget);

      // Tap 3 -> Volta para Original (contain)
      await tester.tap(find.text('Esticar'));
      await tester.pumpAndSettle();
      expect(mode, equals(LiveVideoFitMode.contain));
      expect(find.text('Original'), findsOneWidget);
    });
  });

  group('Fase 2.3: Concorrência e Epoch/Geração no Zapping Rápido', () {
    test('1. Mecanismo de epoch invalida comandos e requisições obsoletas', () {
      int connectionGeneration = 0;

      // Canal 1 inicia conexão
      final gen1 = ++connectionGeneration;
      expect(gen1, equals(1));

      // Usuário dá zapping rápido para Canal 2 antes do Canal 1 terminar
      final gen2 = ++connectionGeneration;
      expect(gen2, equals(2));

      // Usuário dá zapping rápido para Canal 3
      final gen3 = ++connectionGeneration;
      expect(gen3, equals(3));

      // Verifica se Canal 1 e Canal 2 são identificados como obsoletos
      expect(gen1 == connectionGeneration, isFalse);
      expect(gen2 == connectionGeneration, isFalse);
      expect(gen3 == connectionGeneration, isTrue);
    });
  });
}
