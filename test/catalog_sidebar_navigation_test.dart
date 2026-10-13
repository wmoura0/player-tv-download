import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/main.dart';
import 'package:projeto_tv/models/xtream_account.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/widgets/catalog_sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'mock_password'});
  });

  group('CatalogSidebar Widget Tests', () {
    final sampleCategories = [
      const XtreamCategory(id: 'all', name: 'Todas'),
      const XtreamCategory(id: 'favorites', name: 'Favoritos'),
      const XtreamCategory(id: '1', name: 'Esportes'),
      const XtreamCategory(id: '2', name: 'Notícias'),
    ];

    testWidgets('Exibe opções Todas, Favoritos, categorias reais e Início com largura de 220px em modo normal', (tester) async {
      String selectedCategory = 'all';
      bool homeTapped = false;
      bool closeTapped = false;

      // 1. Modo Expandido (TV / Landscape)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSidebar(
              categories: sampleCategories,
              selectedCategoryId: selectedCategory,
              isCompact: false,
              onCategorySelected: (catId) => selectedCategory = catId,
              onHomeTap: () => homeTapped = true,
              onCloseTap: () => closeTapped = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(CatalogSidebar));
      expect(size.width, equals(220.0));

      expect(find.byKey(const Key('sidebar_home')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_all')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_favorites')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_1')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_2')), findsOneWidget);
      expect(find.byKey(const Key('btn_close_sidebar')), findsOneWidget);

      expect(find.text('Todas'), findsOneWidget);
      expect(find.text('Favoritos'), findsOneWidget);
      expect(find.text('Esportes'), findsOneWidget);
      expect(find.text('Notícias'), findsOneWidget);

      // Toca em Início
      await tester.tap(find.byKey(const Key('sidebar_home')));
      expect(homeTapped, isTrue);

      // Toca em uma categoria real (Esportes)
      await tester.tap(find.byKey(const Key('sidebar_cat_1')));
      expect(selectedCategory, equals('1'));

      // Toca em Fechar barra
      await tester.tap(find.byKey(const Key('btn_close_sidebar')));
      expect(closeTapped, isTrue);
    });

    testWidgets('Modo compacto para celular ajusta largura para 170px e exibe categorias com tamanho adaptado', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSidebar(
              categories: sampleCategories,
              selectedCategoryId: '2',
              isCompact: true,
              onCategorySelected: (_) {},
              onHomeTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(CatalogSidebar));
      expect(size.width, equals(170.0));

      expect(find.byKey(const Key('sidebar_cat_all')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_favorites')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_1')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_2')), findsOneWidget);

      // Textos das categorias continuam legíveis no celular
      expect(find.text('Todas'), findsOneWidget);
      expect(find.text('Esportes'), findsOneWidget);
      expect(find.text('Notícias'), findsOneWidget);
    });

    testWidgets('Lista com muitas categorias permite rolagem vertical sem causar overflow', (tester) async {
      final manyCategories = List.generate(
        60,
        (i) => XtreamCategory(id: '$i', name: 'Categoria Canal $i'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSidebar(
              categories: manyCategories,
              selectedCategoryId: '0',
              isCompact: false,
              onCategorySelected: (_) {},
              onHomeTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('sidebar_cat_0')), findsOneWidget);

      // Rola a lista para baixo
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('Catalog & Sidebar Navigation Integration Tests', () {
    late XtreamCatalogService mockService;

    setUp(() {
      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        final catId = request.url.queryParameters['category_id'];

        if (action == 'get_live_categories') {
          return http.Response(
            '[{"category_id":"1","category_name":"Notícias"},{"category_id":"2","category_name":"Esportes"}]',
            200,
          );
        }
        if (action == 'get_vod_categories') {
          return http.Response(
            '[{"category_id":"10","category_name":"Ação"}]',
            200,
          );
        }
        if (action == 'get_series_categories') {
          return http.Response(
            '[{"category_id":"20","category_name":"Drama"}]',
            200,
          );
        }
        if (action == 'get_live_streams') {
          final allStreams = [
            '{"num":1,"name":"Canal Notícias 24h","stream_type":"live","stream_id":100,"stream_icon":"","epg_channel_id":"","added":"","category_id":"1","custom_sid":"","tv_archive":0,"direct_source":"","tv_archive_duration":0}',
            '{"num":2,"name":"Canal Esporte Total","stream_type":"live","stream_id":101,"stream_icon":"","epg_channel_id":"","added":"","category_id":"2","custom_sid":"","tv_archive":0,"direct_source":"","tv_archive_duration":0}',
          ];
          if (catId == '1') {
            return http.Response('[${allStreams[0]}]', 200);
          }
          if (catId == '2') {
            return http.Response('[${allStreams[1]}]', 200);
          }
          return http.Response('[${allStreams.join(",")}]', 200);
        }
        if (action == 'get_vod_streams') {
          return http.Response(
            '[{"num":1,"name":"Filme Ação Explosiva","stream_type":"movie","stream_id":200,"stream_icon":"","rating":"8.5","rating_5based":4.25,"added":"","category_id":"10","container_extension":"mp4","custom_sid":"","direct_source":""}]',
            200,
          );
        }
        if (action == 'get_series') {
          return http.Response(
            '[{"num":1,"name":"Série Drama Intenso","series_id":300,"cover":"","plot":"","cast":"","director":"","genre":"","releaseDate":"","last_modified":"","rating":"9.0","rating_5based":4.5,"backdrop_path":[],"youtube_trailer":"","episode_run_time":"45","category_id":"20"}]',
            200,
          );
        }
        return http.Response('[]', 200);
      });

      mockService = XtreamCatalogService(
        serverUrl: 'http://example.com',
        username: 'test_user',
        password: 'test_password',
        client: mockClient,
      );
    });

    Future<void> waitForLoad(WidgetTester tester) async {
      await tester.pump();
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();
    }

    testWidgets('TV ao vivo exibe categorias reais na barra lateral e filtra os canais ao selecionar', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: mockService,
          ),
        ),
      );
      await waitForLoad(tester);

      // Barra lateral visível exibindo as categorias de TV ao vivo
      expect(find.byType(CatalogSidebar), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_all')), findsOneWidget);
      expect(find.text('Todas'), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_favorites')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_1')), findsOneWidget);
      expect(find.text('Notícias'), findsOneWidget);
      expect(find.byKey(const Key('sidebar_cat_2')), findsOneWidget);
      expect(find.text('Esportes'), findsOneWidget);

      // Inicialmente em "Todas", exibe canais de ambas as categorias
      expect(find.text('Canal Notícias 24h'), findsOneWidget);
      expect(find.text('Canal Esporte Total'), findsOneWidget);

      // Clica na categoria "Notícias" na barra lateral
      await tester.tap(find.byKey(const Key('sidebar_cat_1')));
      await waitForLoad(tester);

      // Agora deve exibir apenas o canal de Notícias
      expect(find.text('Canal Notícias 24h'), findsOneWidget);
      expect(find.text('Canal Esporte Total'), findsNothing);

      // Retorna para "Todas" na barra lateral
      await tester.tap(find.byKey(const Key('sidebar_cat_all')));
      await waitForLoad(tester);

      // Exibe novamente todos os canais
      expect(find.text('Canal Notícias 24h'), findsOneWidget);
      expect(find.text('Canal Esporte Total'), findsOneWidget);
    });

    testWidgets('Barra superior de navegação removida para liberar espaço vertical na TV', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: mockService,
          ),
        ),
      );
      await waitForLoad(tester);

      // Botões redundantes de navegação superior foram removidos conforme solicitado
      expect(find.byKey(const Key('catalog_tab_live')), findsNothing);
      expect(find.byKey(const Key('catalog_tab_movies')), findsNothing);
      expect(find.byKey(const Key('catalog_tab_series')), findsNothing);

      // Canais e categorias da barra lateral carregam diretamente e ocupam o espaço
      expect(find.text('Canal Notícias 24h'), findsOneWidget);
      expect(find.text('Canal Esporte Total'), findsOneWidget);
    });

    testWidgets('Remoção do toggle redundante no AppBar e expansão discreta no mobile sem deixar espaços vazios', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: mockService,
          ),
        ),
      );
      await waitForLoad(tester);

      // Inicialmente visível e confirma que o botão redundante foi removido do AppBar
      expect(find.byType(CatalogSidebar), findsOneWidget);
      expect(find.byKey(const Key('btn_close_sidebar')), findsOneWidget);
      expect(find.byKey(const Key('btn_toggle_sidebar')), findsNothing);
      expect(tester.takeException(), isNull);

      // Fecha barra lateral via botão close interno
      await tester.tap(find.byKey(const Key('btn_close_sidebar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Barra lateral sumiu completamente, 0 espaço reservado
      expect(find.byType(CatalogSidebar), findsNothing);
      expect(tester.takeException(), isNull);

      // Controle discreto de expansão disponível na borda
      expect(find.byKey(const Key('btn_expand_sidebar')), findsOneWidget);

      // Reabre barra lateral via controle discreto
      await tester.tap(find.byKey(const Key('btn_expand_sidebar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(CatalogSidebar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Navegação Home -> Catálogo -> Início retorna limpo sem duplicar telas', (tester) async {
      const account = XtreamAccount(
        serverUrl: 'http://example.com',
        username: 'test_user',
        isAuthorized: true,
        status: 'Active',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: account),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Na Home: NÃO exibe CatalogSidebar
      expect(find.byType(CatalogSidebar), findsNothing);
      expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);

      // Entra em TV ao vivo a partir do card da Home
      await tester.tap(find.byKey(const Key('cat_live_tv')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Agora no Catálogo: exibe a barra lateral de categorias
      expect(find.byType(CatalogSidebar), findsOneWidget);

      // Clica em "Início" na barra lateral
      await tester.tap(find.byKey(const Key('sidebar_home')));
      await tester.pumpAndSettle();

      // De volta à Home: barra lateral não está visível
      expect(find.byType(CatalogSidebar), findsNothing);
      expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);
      expect(find.byKey(const Key('cat_movies')), findsOneWidget);
      expect(find.byKey(const Key('cat_series')), findsOneWidget);
    });
  });
}
