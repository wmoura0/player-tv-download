import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/channel.dart';
import 'package:projeto_tv/models/playlist.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/playlist_channels_screen.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/screens/vod_player_screen.dart';
import 'package:projeto_tv/services/playlist_storage.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
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

class FakePlaylistStorage extends Fake implements PlaylistStorageService {
  @override
  Future<List<M3uChannel>> loadChannels(String playlistId) async {
    return [
      const M3uChannel(
        name: 'Canal Teste 1',
        streamUrl: 'http://example.com/live1.m3u8',
        groupTitle: 'Geral',
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();

  final List<MethodCall> systemChromeCalls = [];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceUtils.setMockIsTv(null);
    systemChromeCalls.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      systemChromeCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    DeviceUtils.setMockIsTv(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('DeviceUtils Phone vs TV Detection & Fallback Tests', () {
    testWidgets('Celular Android com tela 20:9 em paisagem NÃO é classificado como TV', (tester) async {
      // Simula POCO X6 Pro / celular moderno em modo paisagem (largura lógica 986, altura 406)
      tester.view.physicalSize = const Size(986, 406);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late bool detectedAsTv;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              detectedAsTv = DeviceUtils.isTvMode(context);
              return const SizedBox();
            },
          ),
        ),
      );

      // Shortest side do POCO X6 Pro é 406 dp (< 600 dp). Nunca deve ser considerado TV.
      expect(detectedAsTv, isFalse);
    });

    testWidgets('Tela de TV (1920x1080) é classificada como TV via shortestSide >= 600', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late bool detectedAsTv;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              detectedAsTv = DeviceUtils.isTvMode(context);
              return const SizedBox();
            },
          ),
        ),
      );

      // Shortest side é 1080 dp (>= 600 dp)
      expect(detectedAsTv, isTrue);
    });

    test('Injeção mock de isTv respeita com precisão o dispositivo configurado', () {
      DeviceUtils.setMockIsTv(true);
      expect(DeviceUtils.isTv, isTrue);

      DeviceUtils.setMockIsTv(false);
      expect(DeviceUtils.isTv, isFalse);
    });
  });

  group('Orientation Transitions Engine Tests', () {
    test('No Celular: setNormalOrientation bloqueia vertical e restoreOrientation retorna a vertical', () async {
      DeviceUtils.setMockIsTv(false);

      // 1. Navegação normal -> vertical
      await DeviceUtils.setNormalOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown']),
      );

      // 2. Tela cheia de vídeo -> horizontal
      await DeviceUtils.setVideoOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']),
      );

      // 3. Restauração ao sair do vídeo -> vertical imediato
      await DeviceUtils.restoreOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown']),
      );
    });

    test('Na TV / Fire TV: preserva horizontal tanto na navegação quanto no player', () async {
      DeviceUtils.setMockIsTv(true);

      // 1. Navegação normal -> horizontal preservado
      await DeviceUtils.setNormalOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']),
      );

      // 2. Player de vídeo -> horizontal
      await DeviceUtils.setVideoOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']),
      );

      // 3. Restauração ao sair do player -> permanece horizontal
      await DeviceUtils.restoreOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']),
      );
    });
  });

  group('Player Screens Orientation Lifecycle Tests', () {
    testWidgets('VodPlayerScreen no celular: abre em horizontal e restaura vertical ao fechar via botão Voltar', (tester) async {
      DeviceUtils.setMockIsTv(false);

      const movie = XtreamVodStream(
        streamId: 101,
        name: 'Filme Teste',
        categoryId: '1',
        streamIcon: '',
        rating: '8.5',
      );

      final testController = VideoPlayerController.networkUrl(
        Uri.parse('http://example.com/movie.mp4'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => VodPlayerScreen(
                      movie: movie,
                      streamUrls: const ['http://example.com/movie.mp4'],
                      accountKey: 'test_acc',
                      testController: testController,
                    ),
                  ),
                );
              },
              child: const Text('Abrir Filme'),
            ),
          ),
        ),
      );

      // Abre o player
      await tester.tap(find.text('Abrir Filme'));
      await tester.pump();

      // Ao abrir o player, deve ter solicitado horizontal
      expect(
        systemChromeCalls.any((call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            call.arguments.contains('DeviceOrientation.landscapeLeft')),
        isTrue,
      );

      systemChromeCalls.clear();

      // Aguarda transição da rota para o widget estar renderizado
      await tester.pump(const Duration(milliseconds: 500));

      // Clica no botão de Voltar na barra superior do player ou via Navigator pop
      final backButton = find.byTooltip('Voltar');
      if (backButton.evaluate().isNotEmpty) {
        await tester.tap(backButton);
        await tester.pumpAndSettle();
      } else {
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }

      // Deve ter chamado a restauração para vertical
      expect(
        systemChromeCalls.any((call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            call.arguments.contains('DeviceOrientation.portraitUp')),
        isTrue,
      );
    });

    testWidgets('SeriesPlayerScreen no celular: abre em horizontal e restaura vertical ao fechar via pop', (tester) async {
      DeviceUtils.setMockIsTv(false);

      const series = XtreamSeriesItem(
        seriesId: 201,
        name: 'Série Teste',
        categoryId: '1',
        cover: '',
      );

      const episode = XtreamSeriesEpisode(
        id: 1,
        episodeNum: 1,
        title: 'Piloto',
        seasonNumber: 1,
      );

      const seriesInfo = XtreamSeriesInfo(
        name: 'Série Teste',
        seasons: [],
        episodesBySeason: {
          1: [episode],
        },
      );

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://test.com',
        username: 'u',
        password: 'p',
      );

      final testController = VideoPlayerController.networkUrl(
        Uri.parse('http://example.com/ep.mp4'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SeriesPlayerScreen(
                      series: series,
                      seriesInfo: seriesInfo,
                      initialEpisode: episode,
                      catalogService: catalogService,
                      accountKey: 'test_acc',
                      testController: testController,
                    ),
                  ),
                );
              },
              child: const Text('Abrir Série'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Série'));
      await tester.pump();

      // Aberto em landscape
      expect(
        systemChromeCalls.any((call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            call.arguments.contains('DeviceOrientation.landscapeLeft')),
        isTrue,
      );

      systemChromeCalls.clear();

      // Aguarda transição da rota para o widget estar renderizado
      await tester.pump(const Duration(milliseconds: 500));

      // Clica no botão de Voltar na barra superior do player ou via Navigator pop
      final backButton = find.byTooltip('Voltar');
      if (backButton.evaluate().isNotEmpty) {
        await tester.tap(backButton);
        await tester.pumpAndSettle();
      } else {
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }

      // Deve ter restaurado vertical
      expect(
        systemChromeCalls.any((call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            call.arguments.contains('DeviceOrientation.portraitUp')),
        isTrue,
      );
    });

    testWidgets('PlaylistChannelsScreen no celular: alternar tela cheia e sair restaura orientação vertical', (tester) async {
      DeviceUtils.setMockIsTv(false);

      final playlist = M3uPlaylist(
        id: 'p1',
        name: 'Lista Teste',
        url: 'http://example.com/playlist.m3u',
        channelCount: 1,
        lastUpdated: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PlaylistChannelsScreen(
            playlist: playlist,
            storageService: FakePlaylistStorage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Clica em tela cheia via método estático
      await DeviceUtils.setVideoOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']),
      );

      // Sai de tela cheia
      await DeviceUtils.restoreOrientation();
      expect(
        systemChromeCalls.last.arguments,
        equals(['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown']),
      );
    });
  });
}
