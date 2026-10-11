import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/screens/global_search_screen.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('search_test_');
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

  group('GlobalSearchScreen Widget Tests', () {
    testWidgets('Exibe estado inicial com campo de busca e mensagem explicativa', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: GlobalSearchScreen(
            accountKey: 'test_account',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Buscar canais, filmes ou séries...'), findsOneWidget);
      expect(find.text('Pesquisa Global no Player TV'), findsOneWidget);
      expect(
        find.text(
          'Digite o que deseja assistir para pesquisar simultaneamente em canais de TV ao vivo, filmes e séries.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Busca simultaneamente em TV ao vivo, Filmes e Séries e agrupa por seções', (tester) async {
      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {'stream_id': 10, 'name': 'HBO Max Live', 'category_id': '1'},
              {'stream_id': 11, 'name': 'Globo RJ', 'category_id': '1'},
            ]),
            200,
          );
        }
        if (action == 'get_vod_streams') {
          return http.Response(
            jsonEncode([
              {'stream_id': 20, 'name': 'The Batman', 'category_id': '2'},
              {'stream_id': 21, 'name': 'Vingadores', 'category_id': '2'},
            ]),
            200,
          );
        }
        if (action == 'get_series') {
          return http.Response(
            jsonEncode([
              {'series_id': 30, 'name': 'Batman: A Série Animada', 'genre': 'Ação', 'category_id': '3'},
              {'series_id': 31, 'name': 'Breaking Bad', 'genre': 'Drama', 'category_id': '3'},
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
          home: GlobalSearchScreen(
            catalogService: service,
            accountKey: 'test_account',
          ),
        ),
      );

      // Aguarda até o carregamento assíncrono do catálogo finalizar
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      // Digita 'batman' no campo de busca
      await tester.enterText(find.byType(TextField), 'batman');
      // Aguarda o debounce de 350ms
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // Deve encontrar 'The Batman' em Filmes e 'Batman: A Série Animada' em Séries
      expect(find.text('The Batman'), findsOneWidget);
      expect(find.text('Batman: A Série Animada'), findsOneWidget);
      // 'HBO Max Live' e 'Globo RJ' não devem aparecer
      expect(find.text('HBO Max Live'), findsNothing);
      expect(find.text('Globo RJ'), findsNothing);

      // Abas de filtro e cabeçalhos de seção
      expect(find.text('Todos (2)'), findsOneWidget);
      expect(find.text('Filmes (1)'), findsNWidgets(2)); // Chip da aba + cabeçalho da seção
      expect(find.text('Séries (1)'), findsNWidgets(2)); // Chip da aba + cabeçalho da seção
      expect(find.text('TV ao vivo (0)'), findsOneWidget);

      // Botão Limpar busca (X)
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump(const Duration(milliseconds: 100));

      // Campo foi limpo e voltou ao estado inicial
      expect(find.text('Pesquisa Global no Player TV'), findsOneWidget);
    });

    testWidgets('Exibe mensagem amigável quando nenhum item coincide com a busca', (tester) async {
      final mockClient = MockClient((request) async {
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
          home: GlobalSearchScreen(
            catalogService: service,
            accountKey: 'test_account',
          ),
        ),
      );

      // Aguarda até o carregamento assíncrono do catálogo finalizar
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      await tester.enterText(find.byType(TextField), 'InexistenteXYZ');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.text('Nenhum resultado para "InexistenteXYZ"'), findsOneWidget);
      expect(find.text('Verifique a ortografia ou tente palavras-chave diferentes.'), findsOneWidget);
    });
  });
}
