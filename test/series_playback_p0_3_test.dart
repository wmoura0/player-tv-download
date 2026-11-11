import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P0.3 - Investigação e Correções Forenses de Séries', () {
    test('1. XtreamSeriesEpisode.fromJson decodifica com segurança payload real com container_extension null e info string vazia', () {
      final rawJson = {
        'id': '3479097',
        'episode_num': '2',
        'title': null,
        'container_extension': null,
        'info': '',
        'subtitles': [],
        'custom_sid': '',
        'added': '',
        'season': 4,
        'direct_source': ''
      };

      final ep = XtreamSeriesEpisode.fromJson(rawJson, fallbackSeasonNumber: 4);
      expect(ep.id, equals(3479097));
      expect(ep.episodeNum, equals(2));
      expect(ep.seasonNumber, equals(4));
      expect(ep.containerExtension, isNull);
      expect(ep.title, equals('Episódio 2'));
    });

    test('2. XtreamSeriesInfo.isOrphanedOrStub identifica série cujos episódios não possuem container_extension', () {
      final ghostJson = {
        'info': {
          'name': 'Diarios de um Vampiro 2009 (2009) (2009)',
          'category_id': '95',
        },
        'episodes': {
          '4': [
            {
              'id': '3479097',
              'episode_num': '2',
              'container_extension': null,
              'info': '',
            }
          ]
        }
      };

      final ghostInfo = XtreamSeriesInfo.fromJson(ghostJson);
      expect(ghostInfo.isOrphanedOrStub, isTrue);

      final activeJson = {
        'info': {
          'name': 'Diarios de um Vampiro 2009',
          'category_id': '95',
        },
        'episodes': {
          '4': [
            {
              'id': '4333608',
              'episode_num': '2',
              'container_extension': 'mp4',
              'info': {'duration_secs': 2520},
            }
          ]
        }
      };

      final activeInfo = XtreamSeriesInfo.fromJson(activeJson);
      expect(activeInfo.isOrphanedOrStub, isFalse);
    });

    test('3. SmartSourceResolver.normalizeTitle remove sufixos de anos duplicados e formatações parênteses/colchetes', () {
      expect(
        SmartSourceResolver.normalizeTitle('Diarios de um Vampiro 2009 (2009) (2009)'),
        equals('diarios de um vampiro 2009'),
      );
      expect(
        SmartSourceResolver.normalizeTitle('Diarios de um Vampiro 2009'),
        equals('diarios de um vampiro 2009'),
      );
      expect(
        SmartSourceResolver.normalizeTitle('Diarios de um Vampiro [L] 2009'),
        equals('diarios de um vampiro 2009'),
      );
    });

    test('4. SmartSourceResolver.probeUrl rejeita HTTP 404 e rejeita HTTP 200 com Content-Length 0 (não faz fallback para HEAD em 404)', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('404')) {
          if (request.method == 'HEAD') {
            // Simula o comportamento falso do Nginx/Xtream que responde 200 para HEAD
            return http.Response('', 200, headers: {'content-length': '0', 'content-type': 'video/mp4'});
          }
          return http.Response('Not Found', 404);
        }
        if (request.url.path.contains('empty_200')) {
          return http.Response('', 200, headers: {'content-length': '0'});
        }
        if (request.url.path.contains('valid_206')) {
          return http.Response('video_bytes', 206, headers: {
            'content-length': '1025',
            'content-type': 'video/mp4',
          });
        }
        return http.Response('', 500);
      });

      // 404 no GET NÃO deve aceitar o 200 do HEAD nem mascarar o erro
      final is404Valid = await SmartSourceResolver.instance.probeUrl('http://test.com/404.mp4', client: mockClient);
      expect(is404Valid, isFalse);

      // 200 com Content-Length 0 NÃO é fluxo de mídia válido
      final isEmptyValid = await SmartSourceResolver.instance.probeUrl('http://test.com/empty_200.mp4', client: mockClient);
      expect(isEmptyValid, isFalse);

      // 206 com dados é válido
      final isValid206 = await SmartSourceResolver.instance.probeUrl('http://test.com/valid_206.mp4', client: mockClient);
      expect(isValid206, isTrue);
    });

    test('5. PlayerDiagnostics.probeStreamUrl preserva HTTP 404 e detecta corretamente resposta com corpo vazio', () async {
      final probeResult = await PlayerDiagnostics.probeStreamUrl(
        'http://ls-prime.site/series/user/pass/3479097.mp4',
        headers: {'X-Test': '1'},
        timeout: const Duration(seconds: 1),
      );
      expect(probeResult.isSuccess, isFalse);

      const p404 = HttpProbeResult(statusCode: 404, contentLength: -1, elapsedMs: 50);
      expect(p404.isNotFound, isTrue);
      expect(p404.isSuccess, isFalse);

      const pEmpty = HttpProbeResult(statusCode: 200, contentLength: 0, elapsedMs: 50);
      expect(pEmpty.isEmptyBody, isTrue);
      expect(pEmpty.isSuccess, isFalse);

      final details404 = PlayerDiagnostics.analyzeError(
        PlatformException(code: 'VideoError', message: 'ExoPlaybackException: Source error'),
        probe: p404,
      );
      expect(details404.isResourceNotFound, isTrue);
      expect(details404.shortUiMessage, contains('404'));
      expect(details404.causeMessage, contains('404'));

      final detailsEmpty = PlayerDiagnostics.analyzeError(
        PlatformException(code: 'VideoError', message: 'ExoPlaybackException: Source error'),
        probe: pEmpty,
      );
      expect(detailsEmpty.causeClass, contains('EmptyBodyResponseException'));
      expect(detailsEmpty.shortUiMessage, contains('Conteúdo vazio'));
    });

    test('6. tryRecoverReindexedEpisode localiza série ativa reindexada no catálogo e recupera episódio com stream funcional', () async {
      final mockHttpClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        final seriesId = request.url.queryParameters['series_id'];

        if (action == 'get_series') {
          return http.Response(
            jsonEncode([
              {
                'series_id': 136850,
                'name': 'Diarios de um Vampiro 2009',
                'category_id': '95',
              }
            ]),
            200,
          );
        }

        if (action == 'get_series_info' && seriesId == '136850') {
          return http.Response(
            jsonEncode({
              'info': {
                'name': 'Diarios de um Vampiro 2009',
                'category_id': '95',
              },
              'episodes': {
                '4': [
                  {
                    'id': '4333608',
                    'episode_num': '2',
                    'title': 'Diarios de um Vampiro S04E02',
                    'container_extension': 'mp4',
                    'info': {'duration_secs': 2520},
                  }
                ]
              }
            }),
            200,
          );
        }

        // Teste de stream
        if (request.url.path.contains('4333608.mp4')) {
          return http.Response('valid_media_bytes', 206, headers: {
            'content-length': '1025',
            'content-type': 'video/mp4',
          });
        }

        return http.Response('Not Found', 404);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockHttpClient,
      );

      final deadEp = XtreamSeriesEpisode(
        id: 3479097,
        episodeNum: 2,
        seasonNumber: 4,
        title: 'Episódio 2',
        containerExtension: null,
      );

      final result = await SmartSourceResolver.instance.tryRecoverReindexedEpisode(
        catalogService: catalog,
        oldSeriesId: 113752,
        episode: deadEp,
        seriesTitle: 'Diarios de um Vampiro 2009 (2009) (2009)',
        categoryId: '95',
        probeClient: mockHttpClient,
      );

      expect(result, isNotNull);
      expect(result!.isSuccess, isTrue);
      expect(result.recoveredEpisode?.id, equals(4333608));
      expect(result.recoveredSeriesId, equals(136850));
      expect(result.workingUrl, contains('4333608.mp4'));
    });

    test('7. resolveBestSource reporta allFailed com mensagem clara quando o episódio realmente não existe e não há reindexação', () async {
      final mockHttpClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_series') {
          return http.Response(jsonEncode([]), 200);
        }
        return http.Response('Not Found', 404);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockHttpClient,
      );

      final deadEp = XtreamSeriesEpisode(
        id: 9999999,
        episodeNum: 1,
        seasonNumber: 1,
        title: 'Episódio Inexistente',
        containerExtension: 'mp4',
      );

      final result = await SmartSourceResolver.instance.resolveBestSource(
        catalogService: catalog,
        episode: deadEp,
        seriesId: 88888,
        seriesName: 'Serie Inexistente',
        probeClient: mockHttpClient,
        timeoutPerProbe: const Duration(milliseconds: 50),
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, equals(SmartSourceStatus.allFailed));
      expect(result.diagnosticMessage, contains('HTTP 404'));
      expect(result.diagnosticMessage, contains('removido'));
    });
  });
}
