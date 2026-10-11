import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/screens/vod_player_screen.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();

  final List<MethodCall> platformCalls = [];

  setUp(() {
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('Video Playback Orientation Tests', () {
    testWidgets('VodPlayerScreen define landscape ao abrir e restaura portrait ao sair', (tester) async {
      const movie = XtreamVodStream(
        streamId: 101,
        name: 'Matrix',
        categoryId: '1',
      );

      final dummyController = VideoPlayerController.networkUrl(
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
                      testController: dummyController,
                    ),
                  ),
                );
              },
              child: const Text('Abrir Filme'),
            ),
          ),
        ),
      );

      // 1. Toca no botão para abrir o player de filme em tela cheia
      await tester.tap(find.text('Abrir Filme'));
      await tester.pump();

      // Verifica chamada para modo paisagem (landscapeLeft e landscapeRight)
      final orientationCalls = platformCalls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .toList();
      expect(orientationCalls, isNotEmpty);
      expect(
        orientationCalls.last.arguments,
        contains('DeviceOrientation.landscapeLeft'),
      );

      // 2. Simula voltar do player (pop)
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      // Verifica se restaurou a orientação para retrato (portraitUp)
      final afterPopCalls = platformCalls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .toList();
      expect(
        afterPopCalls.last.arguments,
        contains('DeviceOrientation.portraitUp'),
      );
    });

    testWidgets('SeriesPlayerScreen define landscape ao abrir e restaura portrait ao sair', (tester) async {
      const series = XtreamSeriesItem(
        seriesId: 201,
        name: 'Dark',
        categoryId: '2',
      );

      const ep1 = XtreamSeriesEpisode(
        id: 2001,
        episodeNum: 1,
        title: 'Segredos',
        seasonNumber: 1,
      );

      const seriesInfo = XtreamSeriesInfo(
        name: 'Dark',
        seasons: [XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1')],
        episodesBySeason: {
          1: [ep1],
        },
      );

      final service = XtreamCatalogService(
        serverUrl: 'http://test.com',
        username: 'user',
        password: 'pass',
      );

      final dummyController = VideoPlayerController.networkUrl(
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
                      initialEpisode: ep1,
                      catalogService: service,
                      accountKey: 'test_acc',
                      testController: dummyController,
                    ),
                  ),
                );
              },
              child: const Text('Abrir Série'),
            ),
          ),
        ),
      );

      // 1. Toca no botão para abrir o episódio
      await tester.tap(find.text('Abrir Série'));
      await tester.pump();

      final orientationCalls = platformCalls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .toList();
      expect(orientationCalls, isNotEmpty);
      expect(
        orientationCalls.last.arguments,
        contains('DeviceOrientation.landscapeLeft'),
      );

      // 2. Simula voltar do player (pop)
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      final afterPopCalls = platformCalls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .toList();
      expect(
        afterPopCalls.last.arguments,
        contains('DeviceOrientation.portraitUp'),
      );
    });
  });
}
