import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/channel.dart';
import 'package:projeto_tv/models/playlist.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/playlist_channels_screen.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/screens/vod_player_screen.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/playlist_storage.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _TrackingVideoPlayerPlatform extends VideoPlayerPlatform {
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int _nextId = 1;
  final Map<int, StreamController<VideoEvent>> _eventControllers = {};

  void reset() {
    playCalls = 0;
    pauseCalls = 0;
    seekCalls = 0;
    for (final c in _eventControllers.values) {
      if (!c.isClosed) {
        c.close();
      }
    }
    _eventControllers.clear();
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int textureId) async {
    final c = _eventControllers.remove(textureId);
    if (c != null && !c.isClosed) {
      await c.close();
    }
  }

  @override
  Future<int?> create(DataSource dataSource) async => _nextId++;

  @override
  Future<void> setLooping(int textureId, bool looping) async {}

  @override
  Future<void> play(int textureId) async {
    playCalls++;
  }

  @override
  Future<void> pause(int textureId) async {
    pauseCalls++;
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    seekCalls++;
  }

  @override
  Widget buildView(int textureId) => const SizedBox();

  @override
  Future<Duration> getPosition(int textureId) async => const Duration(minutes: 10);

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    final controller = StreamController<VideoEvent>.broadcast();
    _eventControllers[textureId] = controller;
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(minutes: 45),
            size: const Size(1920, 1080),
          ),
        );
        controller.add(
          VideoEvent(
            eventType: VideoEventType.isPlayingStateUpdate,
            isPlaying: true,
          ),
        );
      }
    });
    return controller.stream;
  }
}

class _FakePlaylistStorage extends Fake implements PlaylistStorageService {
  @override
  Future<List<M3uChannel>> loadChannels(String playlistId) async {
    return const [
      M3uChannel(
        name: 'Canal Teste 1',
        streamUrl: 'http://example.com/live1.m3u8',
        groupTitle: 'Geral',
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fakeVideoPlatform = _TrackingVideoPlayerPlatform();
  VideoPlayerPlatform.instance = fakeVideoPlatform;

  const deviceChannel = MethodChannel('com.player.m3u/device');
  final List<MethodCall> deviceCalls = [];

  Future<void> restoreLifecycleToResumed(WidgetTester tester) async {
    final state = tester.binding.lifecycleState;
    if (state == AppLifecycleState.paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    } else if (state == AppLifecycleState.hidden) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    } else if (state == AppLifecycleState.inactive) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'pass'});
    await SettingsService.instance.loadSettings();
    SmartSourceResolver.instance.clearCache();

    fakeVideoPlatform.reset();
    deviceCalls.clear();
    DeviceUtils.resetScreenKeepAliveForTesting();
    DeviceUtils.setMockIsTv(false);
    DeviceUtils.setMockIsMultiWindowOrPip(null);
    DeviceUtils.setMockIsPipSupported(true);
    DeviceUtils.isPipMode.value = false;
    DeviceUtils.isMultiWindowMode.value = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, (call) async {
      deviceCalls.add(call);
      if (call.method == 'isTvDevice') return false;
      if (call.method == 'isPipSupported') return true;
      if (call.method == 'isInMultiWindowOrPip') return false;
      if (call.method == 'setPipState') return true;
      if (call.method == 'enterPip') return true;
      if (call.method == 'keepScreenOn') return true;
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() {
    DeviceUtils.resetScreenKeepAliveForTesting();
    DeviceUtils.setMockIsTv(null);
    DeviceUtils.setMockIsMultiWindowOrPip(null);
    DeviceUtils.setMockIsPipSupported(null);
    DeviceUtils.isPipMode.value = false;
    DeviceUtils.isMultiWindowMode.value = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('KeepScreenOn & Rotas Ocultas', () {
    test('updateScreenKeepAlive com force: true reenvia keepScreenOn mesmo ativo em cache', () async {
      await DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
      expect(
        deviceCalls.where((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true).length,
        equals(1),
      );

      // Sem force: não reenvia porque já está ativo no cache
      await DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true);
      expect(
        deviceCalls.where((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true).length,
        equals(1),
      );

      // Com force: true: reaplica obrigatoriamente na camada nativa Android
      await DeviceUtils.updateScreenKeepAlive(shouldKeepOn: true, force: true);
      expect(
        deviceCalls.where((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true).length,
        equals(2),
      );
    });

    testWidgets('PlaylistChannelsScreen e XtreamCatalogScreen fora do topo não desligam keepScreenOn em inactive/paused', (tester) async {
      final catalogMockClient = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        if (action == 'get_live_categories') {
          return http.Response(jsonEncode([{'category_id': '1', 'category_name': 'TV'}]), 200);
        }
        if (action == 'get_live_streams') {
          return http.Response(jsonEncode([]), 200);
        }
        return http.Response('[]', 200);
      });

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://test.tv',
        username: 'u',
        password: 'p',
        client: catalogMockClient,
      );

      final playlist = M3uPlaylist(
        id: 'p1',
        name: 'Lista',
        url: 'http://example.com/list.m3u',
        channelCount: 1,
        lastUpdated: DateTime.now(),
      );

      final navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: PlaylistChannelsScreen(
            playlist: playlist,
            storageService: _FakePlaylistStorage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      navKey.currentState!.push(
        MaterialPageRoute(
          builder: (_) => XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: catalogService,
          ),
        ),
      );
      await tester.pump();
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pump();

      // Empurra rota de player por cima das duas telas de catálogo
      navKey.currentState!.push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Player em topo'))),
      );
      await tester.pumpAndSettle();

      await DeviceUtils.setKeepScreenOn(true, force: true);
      deviceCalls.clear();

      // Dispara inactive -> hidden -> paused enquanto XtreamCatalogScreen e PlaylistChannelsScreen não são isCurrent
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      final disabledCalls = deviceCalls.where(
        (c) => c.method == 'keepScreenOn' && c.arguments['enable'] == false,
      );
      expect(disabledCalls, isEmpty);
      expect(DeviceUtils.isScreenKeepOnActive, isTrue);

      await restoreLifecycleToResumed(tester);
      navKey.currentState!.popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
    });
  });

  group('Pop-up / Multi-Window / PiP & KeepScreenOn em VodPlayerScreen e SeriesPlayerScreen', () {
    testWidgets('VodPlayerScreen mantém reprodução em inactive e em MultiWindow/PiP, pausa em background real e reativa keepScreenOn em resumed', (tester) async {
      try {
        const movie = XtreamVodStream(streamId: 101, name: 'Interestelar', categoryId: '1');
        final navKey = GlobalKey<NavigatorState>();

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: const VodPlayerScreen(
              movie: movie,
              streamUrls: ['http://example.com/movie.mp4'],
              accountKey: 'acc1',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(fakeVideoPlatform.playCalls, greaterThan(0));
        // Deve ter solicitado keepScreenOn no initState
        expect(
          deviceCalls.any((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true),
          isTrue,
        );

        final pausesBefore = fakeVideoPlatform.pauseCalls;

        // 1. AppLifecycleState.inactive (Pop-up / Barra de notificações / Transição): NÃO pausa
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));

        // 2. AppLifecycleState.paused estando em Multi-Window/Pop-up: NÃO pausa
        DeviceUtils.setMockIsMultiWindowOrPip(true);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));

        // 3. AppLifecycleState.paused estando em PiP (isPipMode = true): NÃO pausa
        DeviceUtils.setMockIsMultiWindowOrPip(null);
        DeviceUtils.isPipMode.value = true;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));

        // 4. Retorno ao primeiro plano (hidden -> inactive -> resumed) NÃO pausa ao passar por hidden
        // e reativa keepScreenOn com force: true em resumed
        DeviceUtils.isPipMode.value = false;
        deviceCalls.clear();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(
          deviceCalls.any((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true),
          isTrue,
        );

        // 5. AppLifecycleState.paused fora de PiP/Multi-Window: pausa normalmente
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, greaterThan(pausesBefore));
      } finally {
        await restoreLifecycleToResumed(tester);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 900));
      }
    });

    testWidgets('SeriesPlayerScreen mantém reprodução em inactive e em MultiWindow/PiP, pausa em background real e reativa keepScreenOn em resumed', (tester) async {
      try {
        const series = XtreamSeriesItem(seriesId: 201, name: 'Silo', categoryId: '2');
        const ep1 = XtreamSeriesEpisode(id: 3001, episodeNum: 1, title: 'Ep 1', seasonNumber: 1, containerExtension: 'mp4');
        const ep2 = XtreamSeriesEpisode(id: 3002, episodeNum: 2, title: 'Ep 2', seasonNumber: 1, containerExtension: 'mp4');
        const seriesInfo = XtreamSeriesInfo(
          name: 'Silo',
          seasons: [XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1')],
          episodesBySeason: {1: [ep1, ep2]},
        );
        final catalogService = XtreamCatalogService(
          serverUrl: 'http://test.tv',
          username: 'u',
          password: 'p',
          client: MockClient((_) async => http.Response('{}', 200)),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: series,
              seriesInfo: seriesInfo,
              initialEpisode: ep1,
              catalogService: catalogService,
              accountKey: 'acc1',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(fakeVideoPlatform.playCalls, greaterThan(0));
        expect(
          deviceCalls.any((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true),
          isTrue,
        );

        final pausesBefore = fakeVideoPlatform.pauseCalls;

        // 1. inactive: NÃO pausa
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));

        // 2. paused em Multi-Window/Pop-up: NÃO pausa
        DeviceUtils.setMockIsMultiWindowOrPip(true);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));

        // 3. Retorno ao primeiro plano (hidden -> inactive -> resumed) NÃO pausa em hidden e reativa keepScreenOn
        DeviceUtils.setMockIsMultiWindowOrPip(false);
        deviceCalls.clear();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, equals(pausesBefore));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(
          deviceCalls.any((c) => c.method == 'keepScreenOn' && c.arguments['enable'] == true),
          isTrue,
        );

        // 4. paused fora de Multi-Window/PiP: pausa normalmente
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(fakeVideoPlatform.pauseCalls, greaterThan(pausesBefore));
      } finally {
        await restoreLifecycleToResumed(tester);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 900));
      }
    });

    testWidgets('VodPlayerScreen ativa setPipState(enabled: true) no celular após play e bloqueia em TV', (tester) async {
      // Caso 1: Celular
      DeviceUtils.setMockIsTv(false);
      deviceCalls.clear();

      await tester.pumpWidget(
        const MaterialApp(
          home: VodPlayerScreen(
            movie: XtreamVodStream(streamId: 50, name: 'Filme PiP', categoryId: '1'),
            streamUrls: ['http://example.com/movie.mp4'],
            accountKey: 'acc_pip',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        deviceCalls.any((c) => c.method == 'setPipState' && c.arguments['enabled'] == true),
        isTrue,
      );

      // Limpa widget e cancela timers antes do segundo caso
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 900));

      // Caso 2: TV (Fire TV) -> nunca chama setPipState(enabled: true)
      DeviceUtils.setMockIsTv(true);
      deviceCalls.clear();

      await tester.pumpWidget(
        const MaterialApp(
          home: VodPlayerScreen(
            movie: XtreamVodStream(streamId: 51, name: 'Filme TV', categoryId: '1'),
            streamUrls: ['http://example.com/movie_tv.mp4'],
            accountKey: 'acc_tv',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        deviceCalls.any((c) => c.method == 'setPipState'),
        isFalse,
      );

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 900));
    });

    testWidgets('VodPlayerView exibe btn_vod_pip no celular, oculta em TV e limpa controles em modo PiP', (tester) async {
      // Celular
      DeviceUtils.setMockIsTv(false);
      DeviceUtils.isPipMode.value = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Episódio 1',
              fitMode: LiveVideoFitMode.contain,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('btn_vod_pip')), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('Episódio 1'), findsWidgets);

      // Aciona modo PiP -> oculta todos os controles/botões de interface
      DeviceUtils.isPipMode.value = true;
      await tester.pump();
      expect(find.byKey(const Key('btn_vod_pip')), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.replay_10_rounded), findsNothing);

      // Restaura PiP e muda para TV -> btn_vod_pip não aparece em TV
      DeviceUtils.isPipMode.value = false;
      DeviceUtils.setMockIsTv(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Episódio TV',
              fitMode: LiveVideoFitMode.contain,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('btn_vod_pip')), findsNothing);
      expect(find.text('Episódio TV'), findsWidgets);
    });
  });

  group('Continuar Séries & SmartSourceResolver', () {
    testWidgets('SeriesDetailScreen preserva PRÓXIMO S1E2 quando isPromotedNext == true e abre na temporada do episódio', (tester) async {
      final mockClient = MockClient((req) async {
        if (req.url.queryParameters['action'] == 'get_series_info') {
          return http.Response(
            jsonEncode({
              'info': {'name': 'Série Teste', 'plot': 'Sinopse'},
              'seasons': [
                {'season_number': 1, 'name': 'Temporada 1'},
                {'season_number': 2, 'name': 'Temporada 2'},
              ],
              'episodes': {
                '1': [
                  {'id': 101, 'episode_num': 1, 'title': 'T1 Ep 1', 'container_extension': 'mp4'},
                  {'id': 102, 'episode_num': 2, 'title': 'T1 Ep 2', 'container_extension': 'mp4'},
                  {'id': 103, 'episode_num': 3, 'title': 'T1 Ep 3', 'container_extension': 'mp4'},
                ],
                '2': [
                  {'id': 201, 'episode_num': 1, 'title': 'T2 Ep 1 Estreia', 'container_extension': 'mp4'},
                ],
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://test.tv',
        username: 'u',
        password: 'p',
        client: mockClient,
      );
      final progressService = PlaybackProgressService();

      // Cenário A: Ep 2 da T1 foi promovido ao concluir o Ep 1 (isPromotedNext: true)
      await progressService.saveLastWatchedEpisode(
        accountKey: 'acc_s',
        seriesId: 77,
        episodeId: 102,
        seasonNumber: 1,
        episodeNum: 2,
        isPromotedNext: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: const XtreamSeriesItem(seriesId: 77, name: 'Série Teste', categoryId: '1'),
            catalogService: catalogService,
            accountKey: 'acc_s',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Deve mostrar PRÓXIMO S1E2 (e NÃO pular para PRÓXIMO S1E3)
      expect(find.text('PRÓXIMO S1E2'), findsOneWidget);
      expect(find.text('PRÓXIMO S1E3'), findsNothing);

      // Cenário B: Episódio em andamento pertence à Temporada 2 -> deve abrir já na Temporada 2
      await progressService.saveEpisodeProgress(
        accountKey: 'acc_s2',
        seriesId: 77,
        episodeId: 201,
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 45),
      );
      await progressService.saveLastWatchedEpisode(
        accountKey: 'acc_s2',
        seriesId: 77,
        episodeId: 201,
        seasonNumber: 2,
        episodeNum: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            key: const ValueKey('series_scenario_b'),
            series: const XtreamSeriesItem(seriesId: 77, name: 'Série Teste', categoryId: '1'),
            catalogService: catalogService,
            accountKey: 'acc_s2',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CONTINUAR S2E1'), findsOneWidget);
      expect(find.textContaining('T2 Ep 1 Estreia'), findsOneWidget);
    });

    test('SmartSourceResolver.resolveBestSource ignora alreadyFailedUrls sem re-sondar', () async {
      final probedUrls = <String>[];
      final mockClient = MockClient((request) async {
        probedUrls.add(request.url.toString());
        if (request.url.toString().endsWith('/501.mkv')) {
          return http.Response('ok', 206);
        }
        return http.Response('Not Found', 404);
      });

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'u',
        password: 'p',
      );
      const episode = XtreamSeriesEpisode(
        id: 501,
        episodeNum: 1,
        title: 'Pilot',
        containerExtension: 'mp4',
        seasonNumber: 1,
      );

      const alreadyFailed = {
        'http://testserver.tv:8080/series/u/p/501.mp4',
      };

      final result = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalogService,
        episode: episode,
        seriesId: 99,
        probeClient: mockClient,
        alreadyFailedUrls: alreadyFailed,
      );

      expect(result.isSuccess, isTrue);
      expect(result.workingUrl, equals('http://testserver.tv:8080/series/u/p/501.mkv'));
      expect(probedUrls, isNot(contains('http://testserver.tv:8080/series/u/p/501.mp4')));
    });
  });

  group('PlaybackProgressService - Regra Mais Avançado Sempre Vence', () {
    test('Filmes: concluído vence incompleto e maior posição vence menor', () {
      final baseTime = DateTime(2026, 11, 20, 20, 0);
      final phoneOlderMoreAdvanced = ContinueWatchingItem(
        streamId: 10,
        type: ContinueWatchingType.movie,
        title: 'Matrix',
        coverUrl: 'http://img/matrix.jpg',
        containerExtension: 'mp4',
        categoryId: '1',
        position: const Duration(minutes: 55),
        duration: const Duration(minutes: 120),
        updatedAt: baseTime,
      );
      final tvNewerClockButLessProgress = ContinueWatchingItem(
        streamId: 10,
        type: ContinueWatchingType.movie,
        title: 'Matrix',
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 120),
        updatedAt: baseTime.add(const Duration(hours: 2)),
      );

      expect(
        PlaybackProgressService.compareAdvancement(
          phoneOlderMoreAdvanced,
          tvNewerClockButLessProgress,
        ),
        greaterThan(0),
      );

      final picked = PlaybackProgressService.pickMoreAdvanced(
        tvNewerClockButLessProgress,
        phoneOlderMoreAdvanced,
      );
      expect(picked.position, equals(const Duration(minutes: 55)));
      expect(picked.coverUrl, equals('http://img/matrix.jpg'));

      final completedMovie = phoneOlderMoreAdvanced.copyWith(
        position: const Duration(minutes: 118),
      );
      expect(completedMovie.isCompleted, isTrue);
      expect(
        PlaybackProgressService.compareAdvancement(completedMovie, phoneOlderMoreAdvanced),
        greaterThan(0),
      );
    });

    test('Séries: temporada/episódio mais avançado vence e respeita manualResetAt posterior', () {
      final t1 = DateTime(2026, 11, 20, 18, 0);
      final tvAtS1E5 = ContinueWatchingItem(
        streamId: 105,
        seriesId: 50,
        type: ContinueWatchingType.series,
        title: 'Silo',
        subtitle: 'T1:E5',
        seasonNumber: 1,
        episodeNum: 5,
        position: const Duration(minutes: 40),
        duration: const Duration(minutes: 50),
        updatedAt: t1,
      );
      final phoneAtS2E2 = ContinueWatchingItem(
        streamId: 202,
        seriesId: 50,
        type: ContinueWatchingType.series,
        title: 'Silo',
        subtitle: 'T2:E2',
        coverUrl: 'http://img/silo.jpg',
        seasonNumber: 2,
        episodeNum: 2,
        position: const Duration(minutes: 4),
        duration: const Duration(minutes: 50),
        updatedAt: t1.subtract(const Duration(hours: 1)),
      );

      // T2:E2 aos 4min deve vencer T1:E5 aos 40min
      final winner = PlaybackProgressService.pickMoreAdvanced(tvAtS1E5, phoneAtS2E2);
      expect(winner.seasonNumber, equals(2));
      expect(winner.episodeNum, equals(2));
      expect(winner.position, equals(const Duration(minutes: 4)));
      expect(winner.coverUrl, equals('http://img/silo.jpg'));

      // Reset manual posterior ao item remoto deve prevalecer
      final localManualReset = ContinueWatchingItem(
        streamId: 101,
        seriesId: 50,
        type: ContinueWatchingType.series,
        title: 'Silo',
        subtitle: 'T1:E1',
        seasonNumber: 1,
        episodeNum: 1,
        position: Duration.zero,
        duration: Duration.zero,
        updatedAt: t1.add(const Duration(hours: 3)),
        manualResetAt: t1.add(const Duration(hours: 3)),
      );
      final afterReset = PlaybackProgressService.pickMoreAdvanced(localManualReset, phoneAtS2E2);
      expect(afterReset.seasonNumber, equals(1));
      expect(afterReset.episodeNum, equals(1));
    });
  });
}
