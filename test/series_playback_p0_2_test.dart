import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/screens/vod_player_screen.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _MockVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, String> dataSources = {};
  final Map<int, StreamController<VideoEvent>> eventControllers = {};
  final List<String> initializedUrls = [];
  String? failOnUrl;
  int _nextTextureId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int textureId) async {
    eventControllers[textureId]?.close();
    eventControllers.remove(textureId);
    dataSources.remove(textureId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final textureId = _nextTextureId++;
    final uri = dataSource.uri ?? '';
    dataSources[textureId] = uri;
    initializedUrls.add(uri);

    final controller = StreamController<VideoEvent>.broadcast();
    eventControllers[textureId] = controller;

    controller.onListen = () {
      scheduleMicrotask(() {
        if (failOnUrl != null && uri.contains(failOnUrl!)) {
          controller.addError(
            PlatformException(
              code: 'VideoError',
              message: 'Video player had error com.google.android.exoplayer2.ExoPlaybackException: Source error',
            ),
          );
        } else {
          controller.add(
            VideoEvent(
              eventType: VideoEventType.initialized,
              duration: const Duration(minutes: 45),
              size: const Size(1920, 1080),
            ),
          );
        }
      });
    };
    return textureId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    return eventControllers[textureId]?.stream ?? const Stream.empty();
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {}

  @override
  Future<void> play(int textureId) async {
    eventControllers[textureId]?.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: true,
      ),
    );
  }

  @override
  Future<void> pause(int textureId) async {
    eventControllers[textureId]?.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: false,
      ),
    );
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {}

  @override
  Future<void> seekTo(int textureId, Duration position) async {}

  @override
  Future<Duration> getPosition(int textureId) async => Duration.zero;

  @override
  Widget buildView(int textureId) => const SizedBox(width: 1920, height: 1080);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockVideoPlayerPlatform mockPlatform;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.loadSettings();
    mockPlatform = _MockVideoPlayerPlatform();
    VideoPlayerPlatform.instance = mockPlatform;
  });

  group('P0.2 - XtreamSeriesEpisode Robust Parsing', () {
    test('Prioritizes info.id when json.id is ordinal episode number', () {
      final json = {
        'id': 1,
        'episode_num': 1,
        'season': 1,
        'title': 'Episódio Piloto',
        'container_extension': 'mkv',
        'info': {
          'id': 88990,
          'duration': '45 min',
        },
      };

      final episode = XtreamSeriesEpisode.fromJson(json, fallbackSeasonNumber: 1);
      expect(episode.id, equals(88990));
      expect(episode.streamId, equals(1));
      expect(episode.containerExtension, equals('mkv'));
    });

    test('Captures custom_sid as alternative ID when present', () {
      final json = {
        'id': 500,
        'episode_num': 2,
        'season': 1,
        'title': 'Episódio 2',
        'custom_sid': 99123,
      };

      final episode = XtreamSeriesEpisode.fromJson(json, fallbackSeasonNumber: 1);
      expect(episode.id, equals(500));
      expect(episode.streamId, equals(99123));
    });
  });

  group('P0.2 - SmartSourceResolver Resiliency', () {
    test('Considers HTTP 416 (Range Not Satisfiable) as valid source on server', () async {
      final client = MockClient((request) async {
        return http.Response('Range Not Satisfiable', 416);
      });

      final isValid = await SmartSourceResolver.instance.probeUrl(
        'http://example.com/series/user/pass/101.mp4',
        client: client,
      );

      expect(isValid, isTrue);
    });

    test('Falls back to HEAD request when GET with Range returns 400 or 405', () async {
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response('Bad Request for Range', 400);
        } else if (request.method == 'HEAD') {
          return http.Response('', 200);
        }
        return http.Response('Not Found', 404);
      });

      final isValid = await SmartSourceResolver.instance.probeUrl(
        'http://example.com/series/user/pass/101.mkv',
        client: client,
      );

      expect(isValid, isTrue);
    });

    test('Generates candidate URLs including /movie/ fallback for VOD-routed series', () {
      final catalog = XtreamCatalogService(
        serverUrl: 'http://myprovider.com',
        username: 'testuser',
        password: 'testpass',
      );

      final episode = XtreamSeriesEpisode(
        id: 777,
        episodeNum: 1,
        seasonNumber: 1,
        title: 'Pilot',
        containerExtension: 'mp4',
      );

      final candidates = SmartSourceResolver.instance.generateCandidateUrls(
        catalogService: catalog,
        episode: episode,
      );

      expect(candidates.any((u) => u.contains('/series/testuser/testpass/777.mp4')), isTrue);
      expect(candidates.any((u) => u.contains('/series/testuser/testpass/777.mkv')), isTrue);
      expect(candidates.any((u) => u.contains('/movie/testuser/testpass/777.mp4')), isTrue);
    });
  });

  group('P0.2 - PlayerDiagnostics Source Error Analysis', () {
    test('Identifies ExoPlaybackException: Source error and marks format/container contingency eligible', () {
      const err = 'PlatformException(VideoError, Video player had error com.google.android.exoplayer2.ExoPlaybackException: Source error, null, null)';
      final details = PlayerDiagnostics.analyzeError(err);

      expect(details.causeClass, equals('ExoPlaybackException\$SourceError'));
      expect(details.isFormatOrContainerError, isTrue);
      expect(details.isAuthOrForbidden, isFalse);
    });

    test('Identifies HTTP 401/403 as auth/forbidden', () {
      const err = 'PlatformException(VideoError, HttpDataSource\$InvalidResponseCodeException: Response code: 403, null, null)';
      final details = PlayerDiagnostics.analyzeError(err);

      expect(details.isAuthOrForbidden, isTrue);
    });
  });

  group('P0.2 - SeriesPlayerScreen Automatic Fallback Execution', () {
    testWidgets('Automatically falls back from failing .mp4 to .mkv candidate URL without stopping on Source error', (tester) async {
      final catalog = XtreamCatalogService(
        serverUrl: 'http://testserver.com',
        username: 'user1',
        password: 'pass1',
      );

      final series = XtreamSeriesItem(
        seriesId: 99,
        num: 1,
        name: 'Série Teste',
        categoryId: '1',
      );

      final episode = XtreamSeriesEpisode(
        id: 101,
        episodeNum: 1,
        seasonNumber: 1,
        title: 'Episódio 1',
        containerExtension: 'mp4',
      );

      final seriesInfo = XtreamSeriesInfo(
        name: 'Série Teste',
        seasons: [XtreamSeriesSeason(seasonNumber: 1, name: 'T1')],
        episodesBySeason: {
          1: [episode],
        },
      );

      // Force failure on .mp4, but allow .mkv to succeed
      mockPlatform.failOnUrl = '.mp4';

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesPlayerScreen(
            series: series,
            seriesInfo: seriesInfo,
            initialEpisode: episode,
            catalogService: catalog,
            accountKey: 'test-acc',
          ),
        ),
      );

      // First attempt on .mp4 fails, then it should automatically attempt .mkv
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(mockPlatform.initializedUrls.length, greaterThanOrEqualTo(2));
      expect(mockPlatform.initializedUrls.first.contains('.mp4'), isTrue);
      expect(mockPlatform.initializedUrls.any((u) => u.contains('.mkv')), isTrue);

      // Player should NOT be displaying failure message because fallback to .mkv succeeded
      expect(find.text('Falha no carregamento da fonte (Source error)'), findsNothing);
      expect(find.text('Falha na reprodução'), findsNothing);
    });
  });

  group('P0.2 - VodPlayerScreen Automatic Fallback Execution', () {
    testWidgets('Automatically advances to alternative streamUrl on playback failure', (tester) async {
      final urls = [
        'http://testserver.com/movie/user1/pass1/200.mp4',
        'http://testserver.com/movie/user1/pass1/200.mkv',
      ];

      final movie = XtreamVodStream(
        streamId: 200,
        num: 1,
        name: 'Filme Teste',
        containerExtension: 'mp4',
        categoryId: '1',
      );

      mockPlatform.failOnUrl = '.mp4';

      await tester.pumpWidget(
        MaterialApp(
          home: VodPlayerScreen(
            movie: movie,
            streamUrls: urls,
            accountKey: 'test-acc',
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(mockPlatform.initializedUrls.length, greaterThanOrEqualTo(2));
      expect(mockPlatform.initializedUrls.first.contains('.mp4'), isTrue);
      expect(mockPlatform.initializedUrls.any((u) => u.contains('.mkv')), isTrue);
    });
  });
}
