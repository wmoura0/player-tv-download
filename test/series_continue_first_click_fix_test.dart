import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _ConfigurableMockVideoPlatform extends VideoPlayerPlatform {
  final List<String> lifecycleEvents = [];
  final List<String> createdUrls = [];
  final Map<int, StreamController<VideoEvent>> eventControllers = {};
  final Map<int, String> urlByTexture = {};
  int _nextId = 1;

  /// Callback opcional que determina o resultado de inicialização de uma URL:
  /// - `'ok'` (padrão): inicializa e inicia reprodução;
  /// - `'403'`: dispara HTTP 403;
  /// - `'401'`: dispara HTTP 401;
  /// - `'source_error'`: dispara ExoPlaybackException Source error;
  /// - `'hang'`: não emite evento (causa timeout de initialize após 25s).
  String Function(String url, int attemptForUrl)? outcomeForUrl;
  final Map<String, int> _urlAttempts = {};
  Duration disposeDelay = Duration.zero;

  void reset() {
    _nextId = 1;
    lifecycleEvents.clear();
    createdUrls.clear();
    urlByTexture.clear();
    _urlAttempts.clear();
    outcomeForUrl = null;
    disposeDelay = Duration.zero;
    for (final c in eventControllers.values) {
      if (!c.isClosed) c.close();
    }
    eventControllers.clear();
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int textureId) async {
    if (disposeDelay > Duration.zero) {
      await Future.delayed(disposeDelay);
    }
    lifecycleEvents.add('dispose:$textureId');
    final c = eventControllers.remove(textureId);
    urlByTexture.remove(textureId);
    if (c != null && !c.isClosed) {
      unawaited(c.close());
    }
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _nextId++;
    final uri = dataSource.uri ?? '';
    urlByTexture[id] = uri;
    createdUrls.add(uri);
    lifecycleEvents.add('create:$id:$uri');

    final count = (_urlAttempts[uri] ?? 0) + 1;
    _urlAttempts[uri] = count;

    final controller = StreamController<VideoEvent>();
    eventControllers[id] = controller;

    final outcome = outcomeForUrl?.call(uri, count) ?? 'ok';

    controller.onListen = () {
      scheduleMicrotask(() {
        if (controller.isClosed) return;
        if (outcome == 'hang') {
          // Propositalmente não emite evento para simular timeout de 25s.
          return;
        }
        if (outcome == '403') {
          controller.addError(
            PlatformException(
              code: 'VideoError',
              message:
                  'HttpDataSource\$InvalidResponseCodeException: Response code: 403',
            ),
          );
          return;
        }
        if (outcome == '401') {
          controller.addError(
            PlatformException(
              code: 'VideoError',
              message:
                  'HttpDataSource\$InvalidResponseCodeException: Response code: 401',
            ),
          );
          return;
        }
        if (outcome == 'source_error') {
          controller.addError(
            PlatformException(
              code: 'VideoError',
              message:
                  'Video player had error com.google.android.exoplayer2.ExoPlaybackException: Source error',
            ),
          );
          return;
        }
        controller.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(minutes: 45),
            size: const Size(1920, 1080),
          ),
        );
      });
    };

    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    final c = eventControllers[textureId];
    if (c == null) return const Stream.empty();
    c.onCancel = () async {};
    return c.stream;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {}

  @override
  Future<void> play(int textureId) async {
    final c = eventControllers[textureId];
    if (c != null && !c.isClosed) {
      c.add(
        VideoEvent(
          eventType: VideoEventType.isPlayingStateUpdate,
          isPlaying: true,
        ),
      );
    }
  }

  @override
  Future<void> pause(int textureId) async {
    final c = eventControllers[textureId];
    if (c != null && !c.isClosed) {
      c.add(
        VideoEvent(
          eventType: VideoEventType.isPlayingStateUpdate,
          isPlaying: false,
        ),
      );
    }
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int textureId, Duration position) async {}

  @override
  Future<Duration> getPosition(int textureId) async =>
      const Duration(minutes: 5);

  @override
  Widget buildView(int textureId) => const SizedBox(width: 1920, height: 1080);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mockPlatform = _ConfigurableMockVideoPlatform();
  VideoPlayerPlatform.instance = mockPlatform;

  const deviceChannel = MethodChannel('com.player.m3u/device');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.loadSettings();
    SmartSourceResolver.instance.clearCache();
    DeviceUtils.resetScreenKeepAliveForTesting();
    DeviceUtils.setMockIsTv(false);
    DeviceUtils.setMockIsPipSupported(false);
    mockPlatform.reset();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, (call) async {
      if (call.method == 'isTvDevice') return false;
      if (call.method == 'isPipSupported') return false;
      if (call.method == 'isInMultiWindowOrPip') return false;
      return true;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() {
    DeviceUtils.resetScreenKeepAliveForTesting();
    DeviceUtils.setMockIsTv(null);
    DeviceUtils.setMockIsPipSupported(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  XtreamSeriesInfo buildStubSeriesInfo(XtreamSeriesEpisode ep) {
    return XtreamSeriesInfo(
      name: 'Série Teste',
      seasons: [XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1')],
      episodesBySeason: {
        1: [ep],
      },
    );
  }

  Map<String, dynamic> hydratedSeriesJson({
    required int episodeId,
    required String ext,
  }) {
    return {
      'info': {'name': 'Série Teste'},
      'seasons': [
        {'season_number': 1, 'name': 'Temporada 1'},
      ],
      'episodes': {
        '1': [
          {
            'id': episodeId,
            'episode_num': 1,
            'season': 1,
            'title': 'Piloto Real',
            'container_extension': ext,
          },
          {
            'id': episodeId + 1,
            'episode_num': 2,
            'season': 1,
            'title': 'Episódio 2',
            'container_extension': ext,
          },
        ],
      },
    };
  }

  Future<void> cleanUnmountPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 3));
  }

  group('Correção 1º clique em Continuar Série (v1.2.14)', () {
    testWidgets(
      '1. Hidratação pré-conexão (100ms) evita abrir stub antigo na 1ª conexão do ExoPlayer',
      (tester) async {
        final httpClient = MockClient((req) async {
          if (req.url.queryParameters['action'] == 'get_series_info') {
            await Future.delayed(const Duration(milliseconds: 100));
            return http.Response(
              jsonEncode(hydratedSeriesJson(episodeId: 999, ext: 'mkv')),
              200,
            );
          }
          return http.Response('{}', 200);
        });

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
          client: httpClient,
        );

        const stubEp = XtreamSeriesEpisode(
          id: 100,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Episódio 1',
          containerExtension: null,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: const XtreamSeriesItem(
                seriesId: 50,
                name: 'Série Teste',
                categoryId: '1',
              ),
              seriesInfo: buildStubSeriesInfo(stubEp),
              initialEpisode: stubEp,
              catalogService: catalog,
              accountKey: 'acc_1',
            ),
          ),
        );

        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 250));

        expect(mockPlatform.createdUrls, isNotEmpty);
        expect(
          mockPlatform.createdUrls.first,
          equals('http://testserver.com/series/u/p/999.mkv'),
          reason:
              'A janela pré-conexão deve hidratar antes de abrir a 1ª conexão do ExoPlayer',
        );
        expect(
          mockPlatform.createdUrls.any((u) => u.contains('/100.')),
          isFalse,
        );

        await cleanUnmountPlayer(tester);
      },
    );

    testWidgets(
      '2. Corrida quando get_series_info (>2s) termina ANTES das falhas do stub ainda aciona URL hidratada',
      (tester) async {
        // get_series_info demora 2400ms (estoura a janela pré-conexão de 2000ms),
        // terminando enquanto as 4 URLs do stub 100 ainda estão falhando (~150ms*3).
        final httpClient = MockClient((req) async {
          if (req.url.queryParameters['action'] == 'get_series_info') {
            await Future.delayed(const Duration(milliseconds: 2400));
            return http.Response(
              jsonEncode(hydratedSeriesJson(episodeId: 999, ext: 'mkv')),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
          client: httpClient,
        );

        mockPlatform.outcomeForUrl = (url, _) {
          if (url.contains('/100.')) return 'source_error';
          if (url.contains('/999.mkv')) return 'ok';
          return 'source_error';
        };

        const stubEp = XtreamSeriesEpisode(
          id: 100,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Episódio 1',
          containerExtension: null,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: const XtreamSeriesItem(
                seriesId: 51,
                name: 'Série Teste',
                categoryId: '1',
              ),
              seriesInfo: buildStubSeriesInfo(stubEp),
              initialEpisode: stubEp,
              catalogService: catalog,
              accountKey: 'acc_2',
            ),
          ),
        );

        // Avança além dos 2000ms de pré-conexão + falha dos stubs + hidratação em 2400ms
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }

        expect(
          mockPlatform.createdUrls.any((u) => u.contains('/999.mkv')),
          isTrue,
          reason:
              'Mesmo com _currentEpisode já atualizado em background antes do fallback, o snapshot deve detectar mudança e abrir /999.mkv no 1º clique',
        );
        expect(find.byIcon(Icons.error_outline_rounded), findsNothing);

        await cleanUnmountPlayer(tester);
      },
    );

    testWidgets(
      '3. Timeout na URL stub não bloqueia troca para episódio hidratado disponível em background',
      (tester) async {
        final httpClient = MockClient((req) async {
          if (req.url.queryParameters['action'] == 'get_series_info') {
            await Future.delayed(const Duration(milliseconds: 2300));
            return http.Response(
              jsonEncode(hydratedSeriesJson(episodeId: 999, ext: 'mkv')),
              200,
            );
          }
          return http.Response('{}', 200);
        });

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
          client: httpClient,
        );

        mockPlatform.outcomeForUrl = (url, _) {
          if (url.contains('/100.')) return 'hang';
          if (url.contains('/999.mkv')) return 'ok';
          return 'source_error';
        };

        const stubEp = XtreamSeriesEpisode(
          id: 100,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Episódio 1',
          containerExtension: null,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: const XtreamSeriesItem(
                seriesId: 52,
                name: 'Série Teste',
                categoryId: '1',
              ),
              seriesInfo: buildStubSeriesInfo(stubEp),
              initialEpisode: stubEp,
              catalogService: catalog,
              accountKey: 'acc_3',
            ),
          ),
        );

        // Avança janela pré-conexão (2s) + timeout do initialize (25s) + conexão hidratada
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 26));
        await tester.pump(const Duration(seconds: 2));

        expect(
          mockPlatform.createdUrls.any((u) => u.contains('/999.mkv')),
          isTrue,
          reason:
              'Timeout em stub deve recuperar via episódio hidratado diferente do snapshot',
        );
        expect(find.byIcon(Icons.error_outline_rounded), findsNothing);

        await cleanUnmountPlayer(tester);
      },
    );

    testWidgets(
      '4a. Dispose do controller anterior conclui ANTES de criar o próximo e HTTP 403 transitório tenta a mesma URL 1 vez',
      (tester) async {
        mockPlatform.disposeDelay = const Duration(milliseconds: 100);
        mockPlatform.outcomeForUrl = (url, attempt) {
          if (url.contains('/700.mp4') && attempt == 1) return '403';
          if (url.contains('/700.mp4') && attempt == 2) return 'ok';
          return 'source_error';
        };

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
        );

        const ep = XtreamSeriesEpisode(
          id: 700,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Ep 1',
          containerExtension: 'mp4',
        );
        final fullInfo = XtreamSeriesInfo(
          name: 'Série Teste',
          seasons: const [XtreamSeriesSeason(seasonNumber: 1, name: 'T1')],
          episodesBySeason: {
            1: [
              ep,
              const XtreamSeriesEpisode(
                id: 701,
                episodeNum: 2,
                seasonNumber: 1,
                title: 'Ep 2',
                containerExtension: 'mp4',
              ),
            ],
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: const XtreamSeriesItem(
                seriesId: 53,
                name: 'Série Teste',
                categoryId: '1',
              ),
              seriesInfo: fullInfo,
              initialEpisode: ep,
              catalogService: catalog,
              accountKey: 'acc_4',
            ),
          ),
        );

        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }

        // Deve ter tentado apenas /700.mp4 duas vezes (nenhuma alternância de extensão em 403)
        expect(
          mockPlatform.createdUrls,
          equals([
            'http://testserver.com/series/u/p/700.mp4',
            'http://testserver.com/series/u/p/700.mp4',
          ]),
        );

        // O dispose da tentativa 1 precisa ocorrer ANTES do create da tentativa 2
        final dispose1Idx = mockPlatform.lifecycleEvents.indexOf('dispose:1');
        final create2Idx = mockPlatform.lifecycleEvents.indexWhere(
          (e) => e.startsWith('create:2:'),
        );
        expect(
          dispose1Idx,
          greaterThanOrEqualTo(0),
          reason: 'lifecycleEvents=${mockPlatform.lifecycleEvents}',
        );
        expect(create2Idx, greaterThan(dispose1Idx));

        await cleanUnmountPlayer(tester);
      },
    );

    testWidgets(
      '4b. HTTP 401 nunca faz retry e interrompe imediatamente com erro de autorização',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        mockPlatform.outcomeForUrl = (_, _) => '401';

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
        );

        const ep = XtreamSeriesEpisode(
          id: 710,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Ep 1',
          containerExtension: 'mp4',
        );
        final fullInfo = XtreamSeriesInfo(
          name: 'Série Teste',
          seasons: const [XtreamSeriesSeason(seasonNumber: 1, name: 'T1')],
          episodesBySeason: {
            1: [
              ep,
              const XtreamSeriesEpisode(
                id: 711,
                episodeNum: 2,
                seasonNumber: 1,
                title: 'Ep 2',
                containerExtension: 'mp4',
              ),
            ],
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: const XtreamSeriesItem(
                seriesId: 54,
                name: 'Série Teste',
                categoryId: '1',
              ),
              seriesInfo: fullInfo,
              initialEpisode: ep,
              catalogService: catalog,
              accountKey: 'acc_4b',
            ),
          ),
        );

        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }

        expect(mockPlatform.createdUrls.length, equals(1));
        expect(find.textContaining('HTTP 401'), findsOneWidget);

        await cleanUnmountPlayer(tester);
      },
    );

    test(
      '5. SmartSourceResolver invalida URL em cache se estiver em alreadyFailedUrls',
      () async {
        final mockClient = MockClient((req) async {
          final url = req.url.toString();
          if (url.endsWith('/801.mp4')) {
            return http.Response('ok', 206);
          }
          if (url.endsWith('/801.mkv')) {
            return http.Response('ok', 206);
          }
          return http.Response('Not Found', 404);
        });

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
        );
        const ep = XtreamSeriesEpisode(
          id: 801,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Ep Cache',
          containerExtension: 'mp4',
        );

        // 1ª chamada popula o cache com .mp4
        final first = await SmartSourceResolver.instance.resolveBestSource(
          catalogService: catalog,
          episode: ep,
          seriesId: 60,
          probeClient: mockClient,
        );
        expect(first.workingUrl, equals('http://testserver.com/series/u/p/801.mp4'));
        expect(SmartSourceResolver.instance.hasCachedSource(60, 801), isTrue);

        // 2ª chamada informa que .mp4 falhou no ExoPlayer -> deve invalidar e resolver .mkv
        final second = await SmartSourceResolver.instance.resolveBestSource(
          catalogService: catalog,
          episode: ep,
          seriesId: 60,
          probeClient: mockClient,
          alreadyFailedUrls: {'http://testserver.com/series/u/p/801.mp4'},
        );
        expect(second.isSuccess, isTrue);
        expect(
          second.workingUrl,
          equals('http://testserver.com/series/u/p/801.mkv'),
        );
      },
    );

    testWidgets(
      '6. Reentrância em _onControllerUpdate ignora múltiplas notificações hasError no mesmo controller',
      (tester) async {
        mockPlatform.outcomeForUrl = (_, _) => 'ok';

        final catalog = XtreamCatalogService(
          serverUrl: 'http://testserver.com',
          username: 'u',
          password: 'p',
        );

        const ep = XtreamSeriesEpisode(
          id: 901,
          episodeNum: 1,
          seasonNumber: 1,
          title: 'Ep Reentrância',
          containerExtension: 'mp4',
        );
        final fullInfo = XtreamSeriesInfo(
          name: 'Série Teste',
          seasons: const [XtreamSeriesSeason(seasonNumber: 1, name: 'T1')],
          episodesBySeason: {
            1: [
              ep,
              const XtreamSeriesEpisode(
                id: 902,
                episodeNum: 2,
                seasonNumber: 1,
                title: 'Ep 2',
                containerExtension: 'mp4',
              ),
            ],
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SeriesPlayerScreen(
              series: const XtreamSeriesItem(
                seriesId: 61,
                name: 'Série Teste',
                categoryId: '1',
              ),
              seriesInfo: fullInfo,
              initialEpisode: ep,
              catalogService: catalog,
              accountKey: 'acc_6',
            ),
          ),
        );

        await tester.pump(const Duration(milliseconds: 200));
        expect(mockPlatform.createdUrls.length, equals(1));

        // Dispara dois erros assíncronos seguidos no mesmo controller inicializado
        final firstControllerStream = mockPlatform.eventControllers.values.first;
        firstControllerStream.addError(
          PlatformException(
            code: 'VideoError',
            message:
                'Video player had error com.google.android.exoplayer2.ExoPlaybackException: Source error',
          ),
        );
        firstControllerStream.addError(
          PlatformException(
            code: 'VideoError',
            message:
                'Video player had error com.google.android.exoplayer2.ExoPlaybackException: Source error',
          ),
        );

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        // Deve avançar apenas UMA vez para a URL de contingência (.mkv)
        expect(
          mockPlatform.createdUrls,
          equals([
            'http://testserver.com/series/u/p/901.mp4',
            'http://testserver.com/series/u/p/901.mkv',
          ]),
        );

        await cleanUnmountPlayer(tester);
      },
    );
  });

  group('Sanidade PlayerDiagnostics', () {
    test('Mantém isAuthOrForbidden=true para 401/403', () {
      expect(
        PlayerDiagnostics.analyzeError('Response code: 403').isAuthOrForbidden,
        isTrue,
      );
      expect(
        PlayerDiagnostics.analyzeError('Response code: 401').isAuthOrForbidden,
        isTrue,
      );
    });
  });
}
