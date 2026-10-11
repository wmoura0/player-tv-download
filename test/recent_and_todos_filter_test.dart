import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/channel.dart';
import 'package:projeto_tv/models/playlist.dart';
import 'package:projeto_tv/screens/playlist_channels_screen.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/playlist_storage.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('recent_todos_test_');
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

  group('Recentes no Catálogo Xtream (Filmes e Séries)', () {
    test('getRecentMovies ordena do mais recente para o mais antigo e limita a 5', () async {
      final now = DateTime.now();
      final moviesJson = [
        {'stream_id': 1, 'name': 'Filme Antigo', 'added': (now.subtract(const Duration(days: 10)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '1'},
        {'stream_id': 2, 'name': 'Filme Recente 1', 'added': (now.subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '1'},
        {'stream_id': 3, 'name': 'Filme Recente 2', 'added': (now.subtract(const Duration(days: 2)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '1'},
        {'stream_id': 4, 'name': 'Filme Recente 3', 'added': (now.subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '1'},
        {'stream_id': 5, 'name': 'Filme Recente 4', 'added': (now.subtract(const Duration(days: 4)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '1'},
        {'stream_id': 6, 'name': 'Filme Recente 5', 'added': (now.subtract(const Duration(days: 5)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '1'},
        {'stream_id': 7, 'name': 'Filme Sem Data', 'category_id': '1'},
      ];

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(moviesJson), 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      // Carrega filmes
      await service.fetchVodStreams(categoryId: 'all');

      final recent = await service.getRecentMovies(limit: 5);
      expect(recent.length, equals(5));
      expect(recent[0].name, equals('Filme Recente 1'));
      expect(recent[1].name, equals('Filme Recente 2'));
      expect(recent[2].name, equals('Filme Recente 3'));
      expect(recent[3].name, equals('Filme Recente 4'));
      expect(recent[4].name, equals('Filme Recente 5'));
      // O filme sem data e o mais antigo não devem estar nos 5
      expect(recent.any((m) => m.name == 'Filme Antigo'), isFalse);
      expect(recent.any((m) => m.name == 'Filme Sem Data'), isFalse);
    });

    test('getRecentMovies retorna lista vazia quando nenhum item possui data confiável', () async {
      final moviesJson = [
        {'stream_id': 1, 'name': 'Filme Sem Data 1', 'category_id': '1'},
        {'stream_id': 2, 'name': 'Filme Sem Data 2', 'category_id': '1'},
      ];

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(moviesJson), 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await service.fetchVodStreams(categoryId: 'all');
      final recent = await service.getRecentMovies(limit: 5);
      expect(recent, isEmpty);
    });

    test('getRecentSeries ordena pelo campo last_modified ou added e limita a 5', () async {
      final now = DateTime.now();
      final seriesJson = [
        {'series_id': 10, 'name': 'Série 1 (Ontem)', 'last_modified': (now.subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '2'},
        {'series_id': 11, 'name': 'Série 2 (Hoje)', 'last_modified': (now.millisecondsSinceEpoch ~/ 1000).toString(), 'category_id': '2'},
      ];

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(seriesJson), 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await service.fetchSeries(categoryId: 'all');
      final recent = await service.getRecentSeries(limit: 5);
      expect(recent.length, equals(2));
      expect(recent[0].name, equals('Série 2 (Hoje)'));
      expect(recent[1].name, equals('Série 1 (Ontem)'));
    });
  });

  group('Filtro TODOS no XtreamCatalogScreen', () {
    testWidgets('Filmes exibe TODOS como primeiro chip e seleção padrão', (tester) async {
      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_vod_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '10', 'category_name': 'Ação'},
              {'category_id': '20', 'category_name': 'Comédia'},
            ]),
            200,
          );
        }
        if (action == 'get_vod_streams') {
          return http.Response(
            jsonEncode([
              {'stream_id': 1, 'name': 'Duro de Matar', 'category_id': '10'},
              {'stream_id': 2, 'name': 'Se Beber Não Case', 'category_id': '20'},
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.movies,
            catalogService: service,
          ),
        ),
      );

      // Aguarda carregamento inicial
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      // Deve exibir o item Todas na barra lateral
      expect(find.text('Todas'), findsOneWidget);
      expect(find.text('Ação'), findsOneWidget);
      expect(find.text('Comédia'), findsOneWidget);

      // No modo Todas, ambos os filmes devem estar visíveis
      expect(find.text('Duro de Matar'), findsOneWidget);
      expect(find.text('Se Beber Não Case'), findsOneWidget);

      // Ao filtrar por 'Ação', apenas 'Duro de Matar' deve permanecer
      await tester.tap(find.text('Ação'));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();

      expect(find.text('Duro de Matar'), findsOneWidget);
      expect(find.text('Se Beber Não Case'), findsNothing);

      // Ao voltar para 'Todas', ambos os filmes retornam
      await tester.tap(find.text('Todas'));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();

      expect(find.text('Duro de Matar'), findsOneWidget);
      expect(find.text('Se Beber Não Case'), findsOneWidget);
    });

    testWidgets('TV ao vivo busca em TODOS os canais e restringe ao selecionar categoria específica', (tester) async {
      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '1', 'category_name': 'Esportes'},
              {'category_id': '2', 'category_name': 'Notícias'},
            ]),
            200,
          );
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {'stream_id': 101, 'name': 'SporTV HD', 'category_id': '1'},
              {'stream_id': 102, 'name': 'GloboNews', 'category_id': '2'},
              {'stream_id': 103, 'name': 'ESPN Brasil', 'category_id': '1'},
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: service,
          ),
        ),
      );

      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      // Todas é a opção padrão
      expect(find.text('Todas'), findsOneWidget);
      expect(find.text('SporTV HD'), findsOneWidget);
      expect(find.text('GloboNews'), findsOneWidget);
      expect(find.text('ESPN Brasil'), findsOneWidget);

      // Pesquisa por texto 'globo' no modo TODOS encontra 'GloboNews'
      await tester.enterText(find.byType(TextField), 'globo');
      await tester.pump();

      expect(find.text('GloboNews'), findsOneWidget);
      expect(find.text('SporTV HD'), findsNothing);
      expect(find.text('ESPN Brasil'), findsNothing);

      // Limpa a busca
      await tester.tap(find.byIcon(Icons.clear_rounded));
      await tester.pump();

      expect(find.text('SporTV HD'), findsOneWidget);
      expect(find.text('GloboNews'), findsOneWidget);

      // Ao selecionar 'Esportes', mostra apenas os canais dessa categoria
      await tester.tap(find.text('Esportes'));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();

      expect(find.text('SporTV HD'), findsOneWidget);
      expect(find.text('ESPN Brasil'), findsOneWidget);
      expect(find.text('GloboNews'), findsNothing);
    });
  });

  group('PlaylistChannelsScreen M3U - Opção TODOS', () {
    testWidgets('Exibe TODOS como primeira opção e pesquisa em todas as categorias', (tester) async {
      final channels = [
        const M3uChannel(name: 'Band HD', streamUrl: 'http://stream/band', groupTitle: 'Abertos'),
        const M3uChannel(name: 'Telecine Pipoca', streamUrl: 'http://stream/tc', groupTitle: 'Filmes'),
      ];

      final playlist = M3uPlaylist(
        id: 'test_m3u',
        name: 'Lista Teste',
        url: 'http://test.com/list.m3u',
        channelCount: channels.length,
        lastUpdated: DateTime.now(),
        channels: channels,
      );
      final storage = PlaylistStorageService(storageDir: tempDir);

      await tester.pumpWidget(
        MaterialApp(
          home: PlaylistChannelsScreen(
            playlist: playlist,
            storageService: storage,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Opção TODOS presente e selecionada
      expect(find.text('TODOS'), findsOneWidget);
      expect(find.text('Band HD'), findsOneWidget);
      expect(find.text('Telecine Pipoca'), findsOneWidget);

      // Pesquisa por 'pipoca' encontra canal independente da categoria
      await tester.enterText(find.byType(TextField), 'pipoca');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Telecine Pipoca'), findsOneWidget);
      expect(find.text('Band HD'), findsNothing);
    });
  });
}
