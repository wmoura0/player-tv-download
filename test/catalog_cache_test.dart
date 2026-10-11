import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('catalog_cache_test_');
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('XtreamCatalogService Disk Cache & Smart Refresh Tests', () {
    test('Persiste categorias e streams em disco e recarrega instantaneamente na sessão seguinte', () async {
      int requestCount = 0;
      final mockClient = MockClient((request) async {
        requestCount++;
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '10', 'category_name': 'Esportes'},
            ]),
            200,
          );
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {'stream_id': 101, 'name': 'ESPN HD', 'category_id': '10'},
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      // Sessão 1: Baixa e salva em disco
      final session1 = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      final cats = await session1.fetchLiveCategories();
      expect(cats.length, equals(1));
      expect(cats.first.name, equals('Esportes'));

      final streams = await session1.fetchLiveStreams(categoryId: 'all');
      expect(streams.length, equals(1));
      expect(streams.first.name, equals('ESPN HD'));

      final lastUpdated = await session1.getLastUpdated();
      expect(lastUpdated, isNotNull);
      final formatted = XtreamCatalogService.formatLastUpdated(lastUpdated);
      expect(formatted, contains('às'));

      expect(requestCount, equals(2));

      // Sessão 2: Nova instância limpa sem cache em memória, deve ler diretamente do disco
      final session2 = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      // Não deve fazer requisições HTTP adicionais!
      final diskCats = await session2.fetchLiveCategories();
      expect(diskCats.length, equals(1));
      expect(diskCats.first.name, equals('Esportes'));

      final diskStreams = await session2.fetchLiveStreams(categoryId: 'all');
      expect(diskStreams.length, equals(1));
      expect(diskStreams.first.name, equals('ESPN HD'));

      // Filtro local por categoria usando o cache de disco de todos
      final filteredStreams = await session2.fetchLiveStreams(categoryId: '10');
      expect(filteredStreams.length, equals(1));
      expect(filteredStreams.first.streamId, equals(101));

      // Contador de requisições permaneceu o mesmo (zero requisições na sessão 2)
      expect(requestCount, equals(2));
    });

    test('Falha de rede na atualização mantém o cache existente intacto', () async {
      int requestCount = 0;
      bool failNetwork = false;

      final mockClient = MockClient((request) async {
        requestCount++;
        if (failNetwork) {
          throw const SocketException('Sem conexão à internet');
        }
        return http.Response(
          jsonEncode([
            {'category_id': '1', 'category_name': 'Filmes de Ação'},
          ]),
          200,
        );
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      // 1. Carrega dados válidos com sucesso
      final cats = await service.fetchVodCategories();
      expect(cats.length, equals(1));
      expect(requestCount, equals(1));

      // 2. Simula falha de conexão durante refresh forçado
      failNetwork = true;
      await expectLater(
        service.fetchVodCategories(forceRefresh: true),
        throwsA(isA<XtreamCatalogException>()),
      );

      // 3. O cache anterior permanece seguro e disponível
      failNetwork = false;
      final cachedCats = await service.fetchVodCategories();
      expect(cachedCats.length, equals(1));
      expect(cachedCats.first.name, equals('Filmes de Ação'));
    });

    test('clearDiskCache remove arquivos persistidos e limpa memória', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([
            {'category_id': '5', 'category_name': 'Séries Dramáticas'},
          ]),
          200,
        );
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await service.fetchSeriesCategories();
      expect(service.hasSeriesCategoriesCache, isTrue);

      await service.clearDiskCache();
      expect(service.hasSeriesCategoriesCache, isFalse);

      final files = tempDir.listSync();
      expect(files.isEmpty, isTrue);
    });
  });
}
