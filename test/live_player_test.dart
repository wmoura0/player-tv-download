import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/services/url_sanitizer.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';

void main() {
  group('XtreamCatalogService Stream URL Generation Tests', () {
    test('Gera lista ordenada de URLs com codificação adequada de credenciais', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user@teste',
        password: 'pass#123',
      );

      const stream = XtreamLiveStream(
        streamId: 4567,
        name: 'Globo SP HD',
        categoryId: '1',
      );

      final urls = service.buildLiveStreamUrls(stream);

      // Deve ter pelo menos 3 candidatos
      expect(urls.length, greaterThanOrEqualTo(3));

      // 1ª URL: Padrão Xtream Codes MPEG-TS
      expect(urls[0], equals('http://ls-prime.site/live/user%40teste/pass%23123/4567.ts'));

      // 2ª URL: Alternativa HLS
      expect(urls[1], equals('http://ls-prime.site/live/user%40teste/pass%23123/4567.m3u8'));

      // 3ª URL: Alternativa sem prefixo /live/
      expect(urls[2], equals('http://ls-prime.site/user%40teste/pass%23123/4567.ts'));
    });

    test('Prioriza directSource quando fornecido com protocolo HTTP/HTTPS', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'testuser',
        password: 'testpass',
      );

      const stream = XtreamLiveStream(
        streamId: 101,
        name: 'Canal Direto',
        categoryId: '1',
        directSource: 'http://cdn.exemplo.com/hls/direto.m3u8',
      );

      final urls = service.buildLiveStreamUrls(stream);

      expect(urls.first, equals('http://cdn.exemplo.com/hls/direto.m3u8'));
      expect(urls.length, equals(4));
    });

    test('UrlSanitizer mascara credenciais ao exibir URLs de streaming', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'usuarioSecreto',
        password: 'senhaSuperSecreta',
      );

      final urls = service.buildLiveStreamUrlsById(999);
      final rawUrl = urls.first;
      final safeUrl = UrlSanitizer.sanitize(rawUrl);

      expect(safeUrl, isNot(contains('usuarioSecreto')));
      expect(safeUrl, isNot(contains('senhaSuperSecreta')));
      expect(safeUrl, contains('/live/***/***/999.ts'));
    });
  });

  group('LivePlayerView Widget Tests', () {
    testWidgets('Exibe estado de carregamento com nome do canal', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'SporTV HD',
              channelLogo: null,
              groupTitle: 'Esportes',
              isFullscreen: false,
              isLoading: true,
              errorMessage: null,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      expect(find.text('SporTV HD'), findsWidgets);
      expect(find.text('Conectando ao canal...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('Exibe overlay de erro com mensagem higienizada e botão de reconectar', (tester) async {
      bool retried = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Com Erro',
              groupTitle: 'Variedades',
              isFullscreen: false,
              isLoading: false,
              errorMessage: 'Falha ao acessar http://ls-prime.site/live/user123/passSecret/88.ts',
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
              onRetry: () => retried = true,
            ),
          ),
        ),
      );

      // Deve exibir título de erro
      expect(find.text('Falha na transmissão'), findsOneWidget);

      // Credenciais NUNCA devem estar visíveis no texto de erro
      expect(find.textContaining('user123'), findsNothing);
      expect(find.textContaining('passSecret'), findsNothing);

      // Botão de reconectar funcional
      final retryButton = find.text('Reconectar');
      expect(retryButton, findsOneWidget);
      await tester.tap(retryButton);
      expect(retried, isTrue);
    });

    testWidgets('Alterna controles e aciona callback de tela cheia', (tester) async {
      bool fullscreenToggled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'CNN Brasil',
              groupTitle: 'Notícias',
              isFullscreen: false,
              isLoading: false,
              errorMessage: null,
              onTogglePlayPause: () {},
              onToggleFullscreen: () => fullscreenToggled = true,
            ),
          ),
        ),
      );

      expect(find.text('AO VIVO'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      expect(fullscreenToggled, isTrue);
    });

    testWidgets('Modos de proporção alternam estritamente entre Original e Preencher', (tester) async {
      LiveVideoFitMode currentMode = LiveVideoFitMode.contain;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return LivePlayerView(
                  controller: null,
                  channelName: 'Discovery Channel',
                  isFullscreen: true,
                  isLoading: false,
                  fitMode: currentMode,
                  onFitModeChanged: (mode) {
                    setState(() => currentMode = mode);
                  },
                  onTogglePlayPause: () {},
                  onToggleFullscreen: () {},
                );
              },
            ),
          ),
        ),
      );

      // No modo contain inicial, deve exibir "Original"
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('Esticar'), findsNothing);

      // Clica para alternar
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();

      // Agora deve estar em "Preencher"
      expect(currentMode, equals(LiveVideoFitMode.cover));
      expect(find.text('Preencher'), findsOneWidget);
      expect(find.text('Esticar'), findsNothing);

      // Clica novamente para voltar a "Original"
      await tester.tap(find.text('Preencher'));
      await tester.pumpAndSettle();

      expect(currentMode, equals(LiveVideoFitMode.contain));
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('Esticar'), findsNothing);
    });

    testWidgets('Mini player em altura reduzida (paisagem) não gera overflow nem botão central', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 296,
                height: 166.5, // Dimensão exata do mini player 16:9 em paisagem
                child: LivePlayerView(
                  controller: null,
                  channelName: 'Canal Teste Compacto',
                  isFullscreen: false,
                  isLoading: false,
                  onTogglePlayPause: () {},
                  onToggleFullscreen: () {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Não deve ter ocorrido overflow
      expect(tester.takeException(), isNull);
      expect(find.text('Canal Teste Compacto'), findsWidgets);
      expect(find.text('AO VIVO'), findsOneWidget);
      // Controles essenciais presentes
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
    });

    testWidgets('Modos de proporção funcionam também no mini player', (tester) async {
      LiveVideoFitMode currentMode = LiveVideoFitMode.contain;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return LivePlayerView(
                  controller: null,
                  channelName: 'Canal Mini Player',
                  isFullscreen: false,
                  isLoading: false,
                  fitMode: currentMode,
                  onFitModeChanged: (mode) {
                    setState(() => currentMode = mode);
                  },
                  onTogglePlayPause: () {},
                  onToggleFullscreen: () {},
                );
              },
            ),
          ),
        ),
      );

      // Botão de aspect ratio deve existir no mini player
      final fitButton = find.byIcon(Icons.aspect_ratio_rounded);
      expect(fitButton, findsOneWidget);

      // Clica para alternar
      await tester.tap(fitButton);
      await tester.pumpAndSettle();

      expect(currentMode, equals(LiveVideoFitMode.cover));

      // Clica novamente para voltar a Original
      await tester.tap(fitButton);
      await tester.pumpAndSettle();

      expect(currentMode, equals(LiveVideoFitMode.contain));
    });

    testWidgets('Exibe botões de canal anterior e próximo em tela cheia e aciona callbacks', (tester) async {
      bool prevCalled = false;
      bool nextCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Globo SP HD',
              groupTitle: 'Abertos',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
              onPreviousChannel: () => prevCalled = true,
              onNextChannel: () => nextCalled = true,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final prevButton = find.byKey(const Key('btn_prev_channel'));
      final nextButton = find.byKey(const Key('btn_next_channel'));

      expect(prevButton, findsOneWidget);
      expect(nextButton, findsOneWidget);

      await tester.tap(prevButton);
      expect(prevCalled, isTrue);

      await tester.tap(nextButton);
      expect(nextCalled, isTrue);
    });

    test('DeviceUtils.setKeepScreenOn executa sem lançar exceção', () async {
      // Invocação em ambiente de teste não deve crashar
      await DeviceUtils.setKeepScreenOn(true);
      await DeviceUtils.setKeepScreenOn(false);
    });

    testWidgets('Exibe botão de PiP na barra de controles em dispositivos móveis e oculta em TV', (tester) async {
      DeviceUtils.setMockIsTv(false);

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
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final pipButton = find.byKey(const Key('btn_pip'));
      expect(pipButton, findsOneWidget);

      // Em TV, o botão de PiP de celular não deve existir
      DeviceUtils.setMockIsTv(true);
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
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_pip')), findsNothing);
      DeviceUtils.setMockIsTv(null);
    });

    testWidgets('Em modo PiP (isPipMode == true), LivePlayerView oculta controles e exibe superfície limpa', (tester) async {
      DeviceUtils.isPipMode.value = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Canal Teste PiP',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btn_center_play_pause')), findsOneWidget);

      // Ativa PiP
      DeviceUtils.isPipMode.value = true;
      await tester.pumpAndSettle();

      // Controles normais devem desaparecer da tela flutuante
      expect(find.byKey(const Key('btn_center_play_pause')), findsNothing);
      expect(find.byKey(const Key('btn_pip')), findsNothing);

      // Restaura para teste subsequente
      DeviceUtils.isPipMode.value = false;
      await tester.pumpAndSettle();
    });

    test('DeviceUtils PiP helpers funcionam e protegem ambiente de TV', () async {
      DeviceUtils.setMockIsTv(true);
      expect(await DeviceUtils.isPipSupported(), isFalse);
      expect(await DeviceUtils.enterPip(), isFalse);

      DeviceUtils.setMockIsTv(false);
      DeviceUtils.setMockIsPipSupported(true);
      expect(await DeviceUtils.isPipSupported(), isTrue);

      await DeviceUtils.setPipState(enabled: true, aspectNumerator: 16, aspectDenominator: 9);
      await DeviceUtils.setPipState(enabled: false);

      DeviceUtils.setMockIsTv(null);
      DeviceUtils.setMockIsPipSupported(null);
    });
  });
}
