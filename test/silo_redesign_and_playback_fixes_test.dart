import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/screens/vod_detail_screen.dart';
import 'package:projeto_tv/screens/vod_player_screen.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';

class _TestVideoPlatform extends VideoPlayerPlatform {
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

class _FakePlayerController extends VideoPlayerController {
  _FakePlayerController({
    required Duration position,
    required Duration duration,
    bool isPlaying = true,
  }) : super.networkUrl(Uri.parse('https://example.com/video.mp4')) {
    value = VideoPlayerValue(
      isInitialized: true,
      duration: duration,
      position: position,
      isPlaying: isPlaying,
    );
  }

  void setPlayingState({required bool isPlaying, Duration? position}) {
    value = value.copyWith(
      isPlaying: isPlaying,
      position: position ?? value.position,
    );
    notifyListeners();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Two-Step Back Navigation & OK Key in VodPlayerView Tests', () {
    testWidgets('Primeiro toque em Voltar oculta controles; segundo toque chama onBack', (tester) async {
      bool onBackCalled = false;
      bool playPauseCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Silo S1E1',
              onTogglePlayPause: () => playPauseCalled = true,
              onBack: () => onBackCalled = true,
            ),
          ),
        ),
      );

      // Controles começam visíveis (botão voltar da barra superior está presente)
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(onBackCalled, isFalse);

      // 1º toque em Voltar (Escape) com controles visíveis
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Controles foram ocultados, onBack NÃO foi chamado
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(onBackCalled, isFalse);

      // 2º toque em Voltar com controles já ocultos
      // Espera debounce de 350ms para simular segundo clique físico real
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Agora onBack deve ter sido acionado para fechar o player
      expect(onBackCalled, isTrue);
      expect(playPauseCalled, isFalse);
    });

    testWidgets('Anti-jitter: Não conta dois toques por repetição de tecla (KeyRepeatEvent) ou cliques rápidos', (tester) async {
      int onBackCallCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Filme Teste',
              onTogglePlayPause: () {},
              onBack: () => onBackCallCount++,
            ),
          ),
        ),
      );

      // 1º toque em Voltar
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // Evento de repetição imediata (sem intervalo de debounce)
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // onBack não deve ter sido disparado
      expect(onBackCallCount, equals(0));
    });

    testWidgets('Pressionar OK com controles ocultos apenas reexibe controles sem pausar/despausar', (tester) async {
      bool playPauseCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Silo S3E7',
              onTogglePlayPause: () => playPauseCalled = true,
              onBack: () {},
            ),
          ),
        ),
      );

      // Oculta controles via 1º Voltar
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

      // Pressiona OK (Select) quando controles estão ocultos
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      // Controles reexibidos, MAS onTogglePlayPause NÃO foi chamado
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(playPauseCalled, isFalse);

      // Pressiona OK novamente agora que controles ESTÃO visíveis
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      // Agora sim playPause foi acionado
      expect(playPauseCalled, isTrue);
    });
  });

  group('SeriesDetailScreen Silo Redesign & Episode Continuation Tests', () {
    late XtreamCatalogService catalogService;

    setUp(() {
      final mockClient = MockClient((request) async {
        final body = jsonEncode({
          'info': {
            'name': 'Silo',
            'plot': 'Em um futuro tóxico, uma comunidade vive em um silo subterrâneo.',
            'rating': '8.2',
            'releaseDate': '2023-05-05',
            'genre': 'Sci-Fi & Fantasy, Drama',
          },
          'seasons': [
            {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 2},
            {'season_number': 2, 'name': 'Temporada 2', 'episode_count': 1},
          ],
          'episodes': {
            '1': [
              {
                'id': 101,
                'episode_num': 1,
                'title': 'Dia da Liberdade',
                'info': {'duration': '55 min'},
              },
              {
                'id': 102,
                'episode_num': 2,
                'title': 'O Segredo de Holston',
                'info': {'duration': '50 min'},
              },
            ],
            '2': [
              {
                'id': 201,
                'episode_num': 1,
                'title': 'A Ordem',
                'info': {'duration': '52 min'},
              },
            ],
          },
        });
        return http.Response(body, 200);
      });

      catalogService = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );
    });

    testWidgets('Sem histórico prévio: Exibe ASSISTIR S1E1 no botão Hero com foco automático', (tester) async {
      const series = XtreamSeriesItem(
        seriesId: 44,
        name: 'Silo',
        categoryId: '5',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: series,
            catalogService: catalogService,
            accountKey: 'test_acc',
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Metadados Silo
      expect(find.text('Silo'), findsNWidgets(2)); // TopBar e Hero Header
      expect(find.text('SÉRIE'), findsOneWidget);
      expect(find.text('2023'), findsOneWidget);
      expect(find.text('8.2'), findsOneWidget);
      expect(find.text('Sci-Fi & Fantasy, Drama'), findsOneWidget);

      // Botão Hero Primário Silo
      expect(find.text('ASSISTIR S1E1'), findsOneWidget);
      expect(find.text('ADICIONAR AOS FAVORITOS'), findsOneWidget);
      expect(find.text('Temporadas'), findsOneWidget);
      expect(find.text('Temporada 1'), findsOneWidget);
      expect(find.text('Temporada 2'), findsOneWidget);
    });

    testWidgets('Episódio interrompido: Exibe CONTINUAR S1E1 no botão Hero com posição salva', (tester) async {
      final progressService = PlaybackProgressService();
      const accountKey = 'test_acc';
      const seriesId = 44;

      // Episódio 101 foi assistido até 18 minutos (interrompido)
      await progressService.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: 101,
        position: const Duration(minutes: 18, seconds: 20),
        duration: const Duration(minutes: 55),
      );

      await progressService.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: 101,
        seasonNumber: 1,
        episodeNum: 1,
      );

      const series = XtreamSeriesItem(
        seriesId: seriesId,
        name: 'Silo',
        categoryId: '5',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: series,
            catalogService: catalogService,
            accountKey: accountKey,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Botão Hero Primário deve ser CONTINUAR S1E1
      expect(find.text('CONTINUAR S1E1'), findsOneWidget);
    });

    testWidgets('Episódio concluído: Exibe PRÓXIMO S1E2 no botão Hero', (tester) async {
      final progressService = PlaybackProgressService();
      const accountKey = 'test_acc';
      const seriesId = 44;

      // Episódio 101 foi concluído (> 96%)
      await progressService.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: 101,
        seasonNumber: 1,
        episodeNum: 1,
      );

      const series = XtreamSeriesItem(
        seriesId: seriesId,
        name: 'Silo',
        categoryId: '5',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: series,
            catalogService: catalogService,
            accountKey: accountKey,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Botão Hero Primário deve avançar para o próximo episódio: PRÓXIMO S1E2
      expect(find.text('PRÓXIMO S1E2'), findsOneWidget);
    });

    testWidgets('Último episódio da temporada concluído: Exibe PRÓXIMO S2E1 na temporada seguinte', (tester) async {
      final progressService = PlaybackProgressService();
      const accountKey = 'test_acc';
      const seriesId = 44;

      // Episódio 102 (último da Temporada 1) foi concluído
      await progressService.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: 102,
        seasonNumber: 1,
        episodeNum: 2,
      );

      const series = XtreamSeriesItem(
        seriesId: seriesId,
        name: 'Silo',
        categoryId: '5',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: series,
            catalogService: catalogService,
            accountKey: accountKey,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Botão Hero Primário deve transitar para a Temporada 2: PRÓXIMO S2E1
      expect(find.text('PRÓXIMO S2E1'), findsOneWidget);
    });
  });

  group('VodDetailScreen Silo Redesign Tests', () {
    testWidgets('VodDetailScreen exibe metadados, botão com foco e botão de favoritos em pill', (tester) async {
      final catalogService = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
      );

      const movie = XtreamVodStream(
        streamId: 88,
        name: 'Oppenheimer',
        categoryId: '1',
        rating: '8.9',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: VodDetailScreen(
            movie: movie,
            catalogService: catalogService,
            accountKey: 'test_acc',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Oppenheimer'), findsNWidgets(2)); // TopBar e Title
      expect(find.text('FILME'), findsOneWidget);
      expect(find.text('8.9'), findsOneWidget);
      expect(find.text('Assistir filme'), findsOneWidget);
      expect(find.text('ADICIONAR AOS FAVORITOS'), findsOneWidget);
    });
  });

  group('Fire TV Auto-Hide, Skip Intro Timer & Two-Step Hardware Back Tests', () {
    setUp(() {
      VideoPlayerPlatform.instance = _TestVideoPlatform();
    });

    testWidgets('Controles auto-ocultam em 2.5s mesmo após carregamento inicial demorado (> 5s)', (tester) async {
      final controller = _FakePlayerController(
        position: Duration.zero,
        duration: const Duration(minutes: 40),
        isPlaying: false,
      );
      bool isLoading = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() => isLoading = false);
                        controller.setPlayingState(isPlaying: true);
                      },
                      child: const Text('StartPlaying'),
                    ),
                    Expanded(
                      child: VodPlayerView(
                        controller: controller,
                        title: 'Filme Lento',
                        isLoading: isLoading,
                        onTogglePlayPause: () {},
                        onBack: () {},
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      // Simula 5 segundos de carregamento inicial antes de iniciar playback
      await tester.pump(const Duration(seconds: 5));
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      // Agora o vídeo começou a tocar
      await tester.tap(find.text('StartPlaying'));
      await tester.pump();
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      // Após 2.6 segundos de reprodução ativa, os controles devem auto-ocultar
      await tester.pump(const Duration(milliseconds: 2600));
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    });

    testWidgets('Pular Abertura (+85s) flutuante auto-oculta após 10s, mas permanece acessível ao abrir o OSD antes de 180s', (tester) async {
      final controller = _FakePlayerController(
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 45),
        isPlaying: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Série Teste T1E1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // OSD oculta em 2.5s; pílula flutuante segue visível antes dos 10s
      await tester.pump(const Duration(seconds: 3));
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.text('Pular Abertura (+85s)'), findsOneWidget);

      // Após completar 10s de exibição, a pílula flutuante some da tela
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('Pular Abertura (+85s)'), findsNothing);

      // Se o usuário abrir os controles OSD manualmente (< 180s), a opção segue acessível lá dentro
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.text('Pular Abertura (+85s)'), findsOneWidget);
    });

    testWidgets('Voltar do sistema (maybePop) exige 2 cliques em VodPlayerScreen: 1º oculta controles, 2º sai', (tester) async {
      final controller = _FakePlayerController(
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 100),
        isPlaying: true,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VodPlayerScreen(
                        movie: const XtreamVodStream(
                          streamId: 500,
                          name: 'Filme Two-Back',
                          categoryId: '1',
                          containerExtension: 'mp4',
                        ),
                        streamUrls: const ['https://example.com/500.mp4'],
                        accountKey: 'acc',
                        testController: controller,
                      ),
                    ),
                  );
                },
                child: const Text('AbrirVod'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('AbrirVod'));
      await tester.pumpAndSettle();
      expect(find.byType(VodPlayerScreen), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      // 1º maybePop (Voltar físico entregue via rota Android): apenas oculta controles
      await Navigator.of(tester.element(find.byType(VodPlayerView))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(VodPlayerScreen), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

      // Aguarda debounce e envia 2º maybePop: retorna à tela anterior
      await tester.pump(const Duration(milliseconds: 400));
      await Navigator.of(tester.element(find.byType(VodPlayerView))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(VodPlayerScreen), findsNothing);
      expect(find.text('AbrirVod'), findsOneWidget);
    });

    testWidgets('Voltar do sistema (maybePop) exige 2 cliques em SeriesPlayerScreen: 1º oculta controles/Pular Abertura, 2º sai', (tester) async {
      final controller = _FakePlayerController(
        position: Duration.zero,
        duration: const Duration(minutes: 45),
        isPlaying: true,
      );
      addTearDown(controller.dispose);

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
      );
      const ep = XtreamSeriesEpisode(
        id: 700,
        episodeNum: 1,
        title: 'Piloto',
        seasonNumber: 1,
      );
      const info = XtreamSeriesInfo(
        name: 'Série Two-Back',
        seasons: [XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1')],
        episodesBySeason: {
          1: [ep],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SeriesPlayerScreen(
                        series: const XtreamSeriesItem(
                          seriesId: 10,
                          name: 'Série Two-Back',
                          categoryId: '2',
                        ),
                        seriesInfo: info,
                        initialEpisode: ep,
                        catalogService: catalogService,
                        accountKey: 'acc',
                        testController: controller,
                      ),
                    ),
                  );
                },
                child: const Text('AbrirSerie'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('AbrirSerie'));
      await tester.pumpAndSettle();
      expect(find.byType(SeriesPlayerScreen), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      // 1º maybePop oculta controles e botão Pular Abertura sem sair
      await Navigator.of(tester.element(find.byType(VodPlayerView))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(SeriesPlayerScreen), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.text('Pular Abertura (+85s)'), findsNothing);

      // Aguarda debounce e envia 2º maybePop: retorna à tela anterior
      await tester.pump(const Duration(milliseconds: 400));
      await Navigator.of(tester.element(find.byType(VodPlayerView))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(SeriesPlayerScreen), findsNothing);
      expect(find.text('AbrirSerie'), findsOneWidget);
    });
  });
}
