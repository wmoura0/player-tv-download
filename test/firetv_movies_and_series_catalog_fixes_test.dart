import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('firetv_catalog_fixes_test_');
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.loadSettings();
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Ponto 1: determineInitialSeriesCategory — Seleção Determinística da Categoria Inicial de Séries', () {
    test('Prioriza categorias com palavras-chave de novidade/lançamento/atualizadas', () {
      final categories = [
        const XtreamCategory(id: '1', name: 'Documentários'),
        const XtreamCategory(id: '2', name: 'Séries Atualizadas'),
        const XtreamCategory(id: '3', name: 'Animes'),
      ];

      final selected = XtreamCatalogScreen.determineInitialSeriesCategory(categories);
      expect(selected, equals('2'));
    });

    test('Prioriza Lançamentos quando presente', () {
      final categories = [
        const XtreamCategory(id: '10', name: 'Ação'),
        const XtreamCategory(id: '20', name: 'Lançamentos 2026'),
        const XtreamCategory(id: '30', name: 'Drama'),
      ];

      final selected = XtreamCatalogScreen.determineInitialSeriesCategory(categories);
      expect(selected, equals('20'));
    });

    test('Nunca seleciona categoria adulta mesmo que contenha termo prioritário', () {
      final categories = [
        const XtreamCategory(id: '99', name: 'Adulto +18 Lançamentos'),
        const XtreamCategory(id: '5', name: 'Séries HBO'),
        const XtreamCategory(id: '6', name: 'Séries Netflix'),
      ];

      final selected = XtreamCatalogScreen.determineInitialSeriesCategory(categories);
      expect(selected, equals('5'));
      expect(selected, isNot(equals('99')));
    });

    test('Recai deterministamente sobre a primeira categoria segura se nenhuma palavra-chave coincidir', () {
      final categories = [
        const XtreamCategory(id: '50', name: 'Comédia'),
        const XtreamCategory(id: '60', name: 'Ficção Científica'),
      ];

      final selected = XtreamCatalogScreen.determineInitialSeriesCategory(categories);
      expect(selected, equals('50'));
    });

    test('Retorna fallback seguro se lista de categorias for vazia', () {
      final selected = XtreamCatalogScreen.determineInitialSeriesCategory([]);
      expect(selected, isNotEmpty);
      expect(selected, isNot(equals('all')));
    });
  });

  group('Ponto 2: Normalização de category_id e Preservação de Itens em Filmes e Séries', () {
    test('fetchVodStreams normaliza items com category_id ausente ou "0" para o categoryId requisitado', () async {
      // Simula servidor Xtream real que omite category_id quando requisitado com category_id=123
      final vodJson = [
        {
          'stream_id': 1001,
          'name': 'Filme Com Category 0',
          'category_id': '0', // Xtream real frequentemente retorna "0" ou omite
        },
        {
          'stream_id': 1002,
          'name': 'Filme Com Category Vazio',
          'category_id': '',
        },
        {
          'stream_id': 1003,
          'name': 'Filme Com Category Correto',
          'category_id': '123',
        },
      ];

      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_vod_streams'));
        expect(request.url.queryParameters['category_id'], equals('123'));
        return http.Response(jsonEncode(vodJson), 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://xtream-test.live',
        username: 'user',
        password: 'pass',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      final result = await service.fetchVodStreams(categoryId: '123');

      // Nenhum item deve ser descartado pelo filtro destrutivo
      expect(result.length, equals(3));
      expect(result[0].categoryId, equals('123'));
      expect(result[1].categoryId, equals('123'));
      expect(result[2].categoryId, equals('123'));
    });

    test('fetchSeries normaliza items com category_id ausente ou "0" para o categoryId requisitado', () async {
      final seriesJson = [
        {
          'series_id': 501,
          'name': 'Série A (Sem Cat)',
          // category_id totalmente ausente
        },
        {
          'series_id': 502,
          'name': 'Série B (Cat 0)',
          'category_id': '0',
        },
        {
          'series_id': 503,
          'name': 'Série C (Cat 45)',
          'category_id': '45',
        },
      ];

      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_series'));
        expect(request.url.queryParameters['category_id'], equals('45'));
        return http.Response(jsonEncode(seriesJson), 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://xtream-test.live',
        username: 'user',
        password: 'pass',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      final result = await service.fetchSeries(categoryId: '45');

      expect(result.length, equals(3));
      expect(result[0].categoryId, equals('45'));
      expect(result[1].categoryId, equals('45'));
      expect(result[2].categoryId, equals('45'));
    });
  });

  group('Ponto 3: Cache Granular por Categoria e Controle de Memória/Disco', () {
    test('Grava arquivo individual por categoria no disco e carrega via getLocalItems', () async {
      final vodJson = [
        {'stream_id': 88, 'name': 'Filme Individual', 'category_id': '77'},
      ];

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(vodJson), 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://xtream-test.live',
        username: 'user',
        password: 'pass',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await service.fetchVodStreams(categoryId: '77');

      // Verifica se o arquivo de cache da categoria foi gravado
      final files = tempDir.listSync().whereType<File>().toList();
      final catFile = files.where((f) => f.path.contains('vod_cat_77')).toList();
      expect(catFile, isNotEmpty);

      // getLocalItems deve recuperar os dados do disco sem chamada de rede
      final local = await service.getLocalItems(type: 'movies', categoryId: '77');
      expect(local, isNotNull);
      expect(local!.length, equals(1));
      expect((local.first as XtreamVodStream).name, equals('Filme Individual'));
    });

    test('getCachedVodStreamsSync e getCachedSeriesSync retornam cache de memória síncrono', () async {
      final mockClient = MockClient((request) async {
        if (request.url.queryParameters['action'] == 'get_vod_streams') {
          return http.Response(jsonEncode([{'stream_id': 1, 'name': 'F1', 'category_id': '10'}]), 200);
        }
        if (request.url.queryParameters['action'] == 'get_series') {
          return http.Response(jsonEncode([{'series_id': 2, 'name': 'S1', 'category_id': '20'}]), 200);
        }
        return http.Response('[]', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://xtream-test.live',
        username: 'user',
        password: 'pass',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      // Antes do fetch, cache síncrono é nulo
      expect(service.getCachedVodStreamsSync('10'), isNull);
      expect(service.getCachedSeriesSync('20'), isNull);

      await service.fetchVodStreams(categoryId: '10');
      await service.fetchSeries(categoryId: '20');

      // Após o fetch, cache síncrono retorna imediatamente
      expect(service.getCachedVodStreamsSync('10'), isNotNull);
      expect(service.getCachedVodStreamsSync('10')!.first.name, equals('F1'));
      expect(service.getCachedSeriesSync('20'), isNotNull);
      expect(service.getCachedSeriesSync('20')!.first.name, equals('S1'));
    });
  });

  group('Ponto 4: Abertura da Tela de Séries no Fire TV', () {
    testWidgets('Séries abre diretamente na categoria inicial segura e NÃO em Todas', (tester) async {
      final requestedCategories = <String?>[];
      final requestedActions = <String?>[];

      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        requestedActions.add(action);

        if (action == 'get_series_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '101', 'category_name': 'Séries Atualizadas'},
              {'category_id': '102', 'category_name': 'Documentários'},
            ]),
            200,
          );
        }
        if (action == 'get_series') {
          final catId = request.url.queryParameters['category_id'];
          requestedCategories.add(catId);
          return http.Response(
            jsonEncode([
              {'series_id': 1, 'name': 'Stranger Things', 'category_id': '101'},
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://xtream-test.live',
        username: 'user',
        password: 'pass',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.series,
            catalogService: service,
          ),
        ),
      );

      // Aguarda carregamento
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      // 1. Deve ter consultado get_series COM a categoria inicial selecionada ('101')
      expect(requestedCategories, contains('101'));

      // 2. NUNCA deve ter chamado get_series global (sem category_id ou com null/all) na inicialização
      expect(requestedCategories.where((c) => c == null || c.isEmpty || c == 'all'), isEmpty);

      // 3. Renderiza o item da categoria na tela
      expect(find.text('Stranger Things'), findsOneWidget);
    });
  });
}
