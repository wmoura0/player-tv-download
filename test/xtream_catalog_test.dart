import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  group('XtreamCatalogService Tests', () {
    test('Consulta e faz cache de categorias de TV ao vivo', () async {
      int requestCount = 0;
      final mockClient = MockClient((request) async {
        requestCount++;
        expect(request.url.queryParameters['action'], equals('get_live_categories'));

        final body = jsonEncode([
          {'category_id': '10', 'category_name': 'Esportes', 'parent_id': 0},
          {'category_id': '20', 'category_name': 'Notícias', 'parent_id': 0},
        ]);
        return http.Response(body, 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final categories = await service.fetchLiveCategories();
      expect(categories.length, equals(2));
      expect(categories[0].id, equals('10'));
      expect(categories[0].name, equals('Esportes'));
      expect(categories[1].name, equals('Notícias'));
      expect(requestCount, equals(1));

      // Segunda chamada deve usar o cache sem nova requisição HTTP
      final cached = await service.fetchLiveCategories();
      expect(cached.length, equals(2));
      expect(requestCount, equals(1));
    });

    test('Consulta canais de TV ao vivo e filtra por category_id', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_live_streams'));

        final body = jsonEncode([
          {
            'stream_id': 101,
            'name': 'ESPN HD',
            'stream_icon': 'http://logo.com/espn.png',
            'category_id': '10',
          },
          {
            'stream_id': 102,
            'name': 'CNN Brasil',
            'stream_icon': 'http://logo.com/cnn.png',
            'category_id': '20',
          },
        ]);
        return http.Response(body, 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final channels = await service.fetchLiveStreams(categoryId: '10');
      expect(channels.length, equals(1));
      expect(channels.first.name, equals('ESPN HD'));
      expect(channels.first.streamId, equals(101));
    });

    test('Consulta filmes (VOD) com posters e avaliações', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_vod_streams'));

        final body = jsonEncode([
          {
            'stream_id': 501,
            'name': 'Interestelar',
            'stream_icon': 'http://poster.com/interstellar.jpg',
            'rating': '8.7',
            'category_id': '5',
            'container_extension': 'mp4',
          },
        ]);
        return http.Response(body, 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final movies = await service.fetchVodStreams(categoryId: '5');
      expect(movies.length, equals(1));
      expect(movies.first.name, equals('Interestelar'));
      expect(movies.first.rating, equals('8.7'));
      expect(movies.first.containerExtension, equals('mp4'));
    });

    test('Consulta séries com capas e sinopses', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_series'));

        final body = jsonEncode([
          {
            'series_id': 901,
            'name': 'Breaking Bad',
            'cover': 'http://cover.com/bb.jpg',
            'genre': 'Drama / Crime',
            'rating': '9.5',
            'category_id': '8',
          },
        ]);
        return http.Response(body, 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final series = await service.fetchSeries(categoryId: '8');
      expect(series.length, equals(1));
      expect(series.first.name, equals('Breaking Bad'));
      expect(series.first.genre, equals('Drama / Crime'));
      expect(series.first.rating, equals('9.5'));
    });

    test('Trata erros 401/403 de sessão expirada lançando XtreamCatalogException', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Unauthorized', 401);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'secret_password_here',
        client: mockClient,
      );

      expect(
        () => service.fetchLiveCategories(),
        throwsA(isA<XtreamCatalogException>()),
      );
    });

    test('Retorna lista vazia quando o corpo da resposta estiver vazio', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final result = await service.fetchVodCategories();
      expect(result.isEmpty, isTrue);
    });

    test('clearCache limpa todos os caches de categorias e streams', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([
            {'category_id': '1', 'category_name': 'Teste', 'parent_id': 0},
          ]),
          200,
        );
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      await service.fetchLiveCategories();
      expect(service.hasLiveCategoriesCache, isTrue);

      service.clearCache();
      expect(service.hasLiveCategoriesCache, isFalse);
      expect(service.hasVodCategoriesCache, isFalse);
      expect(service.hasSeriesCategoriesCache, isFalse);
      expect(service.liveStreamsCacheCount, equals(0));
      expect(service.vodStreamsCacheCount, equals(0));
      expect(service.seriesStreamsCacheCount, equals(0));
    });
  });
}
