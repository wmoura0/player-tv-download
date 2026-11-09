import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late XtreamCatalogService catalogService;
  late XtreamSeriesEpisode sampleEpisode;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.loadSettings();
    SmartSourceResolver.instance.clearCache();

    catalogService = XtreamCatalogService(
      serverUrl: 'http://testserver.tv:8080',
      username: 'testuser',
      password: 'testpassword',
    );

    sampleEpisode = const XtreamSeriesEpisode(
      id: 501,
      episodeNum: 1,
      title: 'Pilot',
      containerExtension: 'mp4',
      seasonNumber: 1,
      streamId: 900501,
    );
  });

  group('SmartSourceResolver - Candidate URLs Generation', () {
    test('generates candidate URLs with multi-container formats and streamId permutations', () {
      final candidates = SmartSourceResolver.instance.generateCandidateUrls(
        catalogService: catalogService,
        episode: sampleEpisode,
      );

      expect(candidates, isNotEmpty);
      // Deve conter rota primária com id 501 e extensão mp4
      expect(candidates, contains('http://testserver.tv:8080/series/testuser/testpassword/501.mp4'));
      // Deve conter contingência com id alternativo 900501
      expect(candidates, contains('http://testserver.tv:8080/series/testuser/testpassword/900501.mp4'));
      // Deve conter contingência multi-formato mkv e ts
      expect(candidates, contains('http://testserver.tv:8080/series/testuser/testpassword/501.mkv'));
      expect(candidates, contains('http://testserver.tv:8080/series/testuser/testpassword/501.ts'));
      // Deve conter rota legada
      expect(candidates, contains('http://testserver.tv:8080/testuser/testpassword/501.mp4'));
    });

    test('prioritizes preferredContainerExtension when override is provided', () {
      final candidates = SmartSourceResolver.instance.generateCandidateUrls(
        catalogService: catalogService,
        episode: sampleEpisode,
        preferredExtensionOverride: 'mkv',
      );

      final firstCandidate = candidates.first;
      expect(firstCandidate, endsWith('.mkv'));
    });

    test('includes directSource if present in episode data', () {
      const epWithDirect = XtreamSeriesEpisode(
        id: 777,
        episodeNum: 2,
        title: 'Episode 2',
        containerExtension: 'mp4',
        seasonNumber: 1,
        directSource: '/direct/stream777.mkv',
      );

      final candidates = SmartSourceResolver.instance.generateCandidateUrls(
        catalogService: catalogService,
        episode: epWithDirect,
      );

      expect(candidates, contains('http://testserver.tv:8080/direct/stream777.mkv'));
    });
  });

  group('SmartSourceResolver - Source Probing and Fallback', () {
    test('returns first working candidate (HTTP 206 Partial Content)', () async {
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains('501.mkv')) {
          return http.Response('video content bytes', 206);
        }
        return http.Response('Not Found', 404);
      });

      final result = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalogService,
        episode: sampleEpisode,
        seriesId: 10,
        probeClient: mockClient,
      );

      expect(result.status, equals(SmartSourceStatus.resolved));
      expect(result.isSuccess, isTrue);
      expect(result.workingUrl, contains('501.mkv'));
      expect(SmartSourceResolver.instance.hasCachedSource(10, 501), isTrue);
    });

    test('uses cached source instantly without probing client', () async {
      // Pré-popula cache via primeira resolução
      final mockClient = MockClient((request) async {
        return http.Response('video content', 200);
      });

      final firstResult = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalogService,
        episode: sampleEpisode,
        seriesId: 10,
        probeClient: mockClient,
      );
      expect(firstResult.isSuccess, isTrue);

      // Segunda resolução com mock que falharia: deve retornar do cache sem chamar o cliente
      final failingClient = MockClient((request) async {
        return http.Response('Should not be called', 500);
      });

      final cachedResult = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalogService,
        episode: sampleEpisode,
        seriesId: 10,
        probeClient: failingClient,
      );

      expect(cachedResult.status, equals(SmartSourceStatus.resolved));
      expect(cachedResult.workingUrl, equals(firstResult.workingUrl));
      expect(cachedResult.attemptsCount, equals(0));
    });

    test('returns allFailed when all candidate URLs return HTTP 404', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final result = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalogService,
        episode: sampleEpisode,
        seriesId: 10,
        probeClient: mockClient,
      );

      expect(result.status, equals(SmartSourceStatus.allFailed));
      expect(result.isSuccess, isFalse);
      expect(result.workingUrl, isNull);
      expect(result.diagnosticMessage, contains('404'));
    });

    test('returns skippedDisabled when enableSmartSource is set to false', () async {
      await SettingsService.instance.setEnableSmartSource(false);

      final result = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalogService,
        episode: sampleEpisode,
        seriesId: 10,
      );

      expect(result.status, equals(SmartSourceStatus.skippedDisabled));
      expect(result.isSuccess, isFalse);
    });
  });
}
