import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/main.dart';
import 'package:projeto_tv/models/favorite_item.dart';
import 'package:projeto_tv/models/xtream_account.dart';
import 'package:projeto_tv/screens/favorites_screen.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/screens/settings_screen.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/app_toast_service.dart';
import 'package:projeto_tv/services/cloud_progress_sync_service.dart';
import 'package:projeto_tv/services/favorites_service.dart';
import 'package:projeto_tv/services/hidden_categories_service.dart';
import 'package:projeto_tv/services/pin_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/user_profile_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:projeto_tv/widgets/catalog_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'pass'});
    FavoritesService.resetInstanceForTesting();
    CloudProgressSyncService.setMockInstance(null);
    AppToastService.instance.dismiss();
    await SettingsService.instance.loadSettings();
    await UserProfileService.instance.init();
    await PinService.instance.init();
    await HiddenCategoriesService.instance.init();
    tempDir = await Directory.systemTemp.createTemp('jessflix_p9_test_');
  });

  tearDown(() async {
    AppToastService.instance.dismiss();
    CloudProgressSyncService.setMockInstance(null);
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('P9-A - Notificações temporárias confiáveis (Fire TV / accessibleNavigation)', () {
    const account = XtreamAccount(
      serverUrl: 'http://tv.p9.local',
      username: 'user_p9a',
      isAuthorized: true,
      status: 'Active',
    );
    final accountKey = PlaybackProgressService.buildAccountKey(
      account.serverUrl,
      account.username,
    );

    testWidgets('Remover favorito exibe aviso temporário com Desfazer e desaparece mesmo com accessibleNavigation ativo', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '101',
          scopeKey: accountKey,
          type: FavoriteType.series,
          name: 'Gossip Girl',
          addedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(accessibleNavigation: true),
            child: FavoritesScreen(
              xtreamAccount: account,
              catalogService: XtreamCatalogService(
                serverUrl: account.serverUrl,
                username: account.username,
                password: 'pass',
                cacheDirectoryOverride: tempDir,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Séries'));
      await tester.pumpAndSettle();
      expect(find.text('Gossip Girl'), findsOneWidget);

      await tester.tap(find.byTooltip('Remover dos favoritos').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('app_toast_banner')), findsOneWidget);
      expect(find.text('"Gossip Girl" removido dos favoritos.'), findsOneWidget);
      expect(find.text('Desfazer'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      // Após janela de 3.5s, overlay desaparece automaticamente e sem travar foco
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_toast_banner')), findsNothing);
      expect(find.byKey(const Key('favorites_undo_banner')), findsNothing);
      expect(AppToastService.instance.isVisible, isFalse);
    });

    testWidgets('Remover 3 favoritos consecutivos não acumula notificações e limpar tela remove overlay', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final now = DateTime.now();
      for (var i = 1; i <= 3; i++) {
        await FavoritesService.instance.addFavorite(
          FavoriteItem(
            id: '$i',
            scopeKey: accountKey,
            type: FavoriteType.live,
            name: 'Canal P9 $i',
            addedAt: now.add(Duration(seconds: i)),
          ),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => FavoritesScreen(
              xtreamAccount: account,
              catalogService: XtreamCatalogService(
                serverUrl: account.serverUrl,
                username: account.username,
                password: 'pass',
                cacheDirectoryOverride: tempDir,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Remove 3 canais em sequência via Delete
      for (var i = 0; i < 3; i++) {
        final removeBtns = find.byTooltip('Remover dos favoritos');
        expect(removeBtns, findsWidgets);
        await tester.tap(removeBtns.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('app_toast_banner')), findsOneWidget);
      }

      expect(
        find.descendant(
          of: find.byKey(const Key('favorites_cat_live')),
          matching: find.text('0'),
        ),
        findsOneWidget,
      );

      // Troca/desmonta a tela imediatamente: overlay é removido sem vazar
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(AppToastService.instance.isVisible, isFalse);
    });
  });

  group('P9-B & P9-F - Sidebar sem quadradinhos + Navegação pós-pesquisa + 10 categorias', () {
    test('Sanitização remove símbolos decorativos e quadradinhos preservando nomes reais', () {
      expect(
        CatalogSidebar.sanitizeDisplayCategoryName('▪ Netflix'),
        'Netflix',
      );
      expect(
        CatalogSidebar.sanitizeDisplayCategoryName('■ Amazon Prime Video'),
        'Amazon Prime Video',
      );
      expect(
        CatalogSidebar.sanitizeDisplayCategoryName('▶ HBO MAX • UHD'),
        'HBO MAX • UHD',
      );
      expect(
        CatalogSidebar.sanitizeDisplayCategoryName('🔥 Lançamentos 2026'),
        'Lançamentos 2026',
      );
    });

    testWidgets('Buscar série, limpar busca, alternar 10 categorias sem mudar por foco e voltar à grade com seta Direita', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final serverCategories = [
        {'category_id': '10', 'category_name': '▪ Lançamentos'},
        {'category_id': '11', 'category_name': '■ Netflix'},
        {'category_id': '12', 'category_name': '▫ Amazon Prime Video'},
        {'category_id': '13', 'category_name': '▶ HBO MAX'},
        {'category_id': '14', 'category_name': 'Disney+'},
        {'category_id': '15', 'category_name': 'Apple TV+'},
        {'category_id': '16', 'category_name': 'Globoplay'},
        {'category_id': '17', 'category_name': 'Paramount+'},
        {'category_id': '18', 'category_name': 'Ação'},
        {'category_id': '19', 'category_name': 'Drama'},
      ];

      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        final cat = req.url.queryParameters['category_id'];
        if (action == 'get_series_categories') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(serverCategories)),
            200,
          );
        }
        if (action == 'get_series') {
          if (cat == '10') {
            return http.Response.bytes(
              utf8.encode(jsonEncode([
                {'series_id': 1001, 'name': 'Série Lançamento', 'category_id': '10'},
              ])),
              200,
            );
          }
          if (cat == '11') {
            return http.Response.bytes(
              utf8.encode(jsonEncode([
                {'series_id': 1101, 'name': 'Stranger Things', 'category_id': '11'},
              ])),
              200,
            );
          }
          if (cat == '19') {
            return http.Response.bytes(
              utf8.encode(jsonEncode([
                {'series_id': 1901, 'name': 'Diários de um Vampiro', 'category_id': '19'},
              ])),
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode(jsonEncode([
              {'series_id': 1001, 'name': 'Série Lançamento', 'category_id': '10'},
              {'series_id': 1101, 'name': 'Stranger Things', 'category_id': '11'},
              {'series_id': 1901, 'name': 'Diários de um Vampiro', 'category_id': '19'},
            ])),
            200,
          );
        }
        if (action == 'get_series_info') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'info': {'name': 'Diários de um Vampiro'},
              'seasons': [
                {'season_number': 1, 'name': 'Temporada 1'},
              ],
              'episodes': {
                '1': [
                  {
                    'id': '9001',
                    'episode_num': 1,
                    'title': 'Pilot',
                    'season': 1,
                    'container_extension': 'mp4',
                  },
                ],
              },
            })),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://p9.local:8080',
        username: 'u',
        password: 'p',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        PlayerTvApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.series,
            catalogService: catalog,
          ),
        ),
      );
      for (var i = 0;
          i < 40 &&
              (find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
                  find.byKey(const Key('sidebar_cat_11')).evaluate().isEmpty);
          i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 100));

      // Sidebar não usa Icons.folder_outlined nem exibe quadradinhos ▪ / ■ / ▶
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('▪ Lançamentos'), findsNothing);
      expect(find.text('Série Lançamento'), findsOneWidget);

      // Pesquisa global e limpa
      await tester.enterText(find.byType(TextField), 'Vampiro');
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Diários de um Vampiro'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // Mover foco para baixo 3 categorias não troca de Lançamentos até confirmar OK
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.text('Série Lançamento'), findsOneWidget);

      // Alternar entre 10 categorias consecutivas e entrar na grade via Direita
      for (final id in ['11', '12', '13', '14', '15', '16', '17', '18', '10', '19']) {
        final catFinder = find.byKey(Key('sidebar_cat_$id'));
        await tester.ensureVisible(catFinder);
        await tester.pump();
        await tester.tap(catFinder);
        await tester.pump();
        for (var i = 0; i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
          await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 25)));
          await tester.pump();
        }
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Diários de um Vampiro'), findsOneWidget);

      // Pressiona seta Direita na categoria selecionada para entrar na grade
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'CatalogFirstItemFocus');

      // Abre detalhes e retorna mantendo categoria Drama selecionada
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SeriesDetailScreen), findsOneWidget);

      await tester.tap(find.text('Voltar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      expect(find.byType(SeriesDetailScreen), findsNothing);
      expect(find.text('Diários de um Vampiro'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('P9-C, P9-D, P9-E, P9-G & P9-H - Home, Favoritos Sidebar, Settings, 720p & 1080p', () {
    const account = XtreamAccount(
      serverUrl: 'http://tv.p9full.local',
      username: 'user_p9',
      isAuthorized: true,
      status: 'Active',
    );
    final accountKey = PlaybackProgressService.buildAccountKey(
      account.serverUrl,
      account.username,
    );

    testWidgets('SettingsScreen removeu Reprodução e Fontes mantendo as demais categorias navegáveis', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const PlayerTvApp(home: SettingsScreen(xtreamAccount: account)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reprodução e Fontes'), findsNothing);
      expect(find.text('Conta e Acesso'), findsOneWidget);
      expect(find.text('Atualizações'), findsOneWidget);
      expect(find.text('Preferências de Conteúdo'), findsOneWidget);
      expect(find.text('Armazenamento e Catálogo'), findsOneWidget);
      expect(find.text('Controle Parental'), findsOneWidget);
      expect(find.text('Contas e Perfis'), findsOneWidget);
      expect(find.text('Sair da conta'), findsOneWidget);

      // Navega pelas categorias sem overflow
      await tester.tap(find.text('Controle Parental'));
      await tester.pumpAndSettle();
      expect(find.text('Bloqueio por PIN e Conteúdo Adulto'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Home 720p e 1080p sem overflow nem recorte, e Continuar Assistindo oferece só Ocultar/Concluir + persistência', (tester) async {
      final progress = PlaybackProgressService();
      await progress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: 77,
        episodeId: 7702,
        position: const Duration(minutes: 18),
        duration: const Duration(minutes: 44),
      );
      await progress.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: 77,
        episodeId: 7702,
        seasonNumber: 2,
        episodeNum: 5,
      );
      await progress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 7702,
          seriesId: 77,
          type: ContinueWatchingType.series,
          title: 'Diários de um Vampiro',
          subtitle: 'T2:E5 • Kill or Be Killed',
          position: const Duration(minutes: 18),
          duration: const Duration(minutes: 44),
          updatedAt: DateTime.now(),
          seasonNumber: 2,
          episodeNum: 5,
        ),
      );

      for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(const PlayerTvApp(home: HomeScreen(xtreamAccount: account)));
        await tester.pumpAndSettle();

        expect(find.text('TV ao vivo'), findsOneWidget);
        expect(find.text('Continuar assistindo'), findsOneWidget);
        expect(find.text('Diários de um Vampiro'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Todos os botões do cabeçalho permanecem dentro da viewport
        for (final k in const [
          Key('header_search_btn'),
          Key('header_profile_btn'),
          Key('header_settings_btn'),
          Key('header_logout_btn'),
        ]) {
          final rect = tester.getRect(find.byKey(k));
          expect(rect.right <= size.width, isTrue);
          expect(rect.left >= 0, isTrue);
        }
      }
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Abre opções via Menu no card e valida P9-E
      final cwNode = FocusManager.instance.rootScope.traversalDescendants
          .firstWhere((n) => n.debugLabel == 'ContinueWatchingCard_0');
      cwNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Ocultar da Home'), findsOneWidget);
      expect(find.text('Marcar como concluído'), findsOneWidget);
      expect(find.text('Fechar'), findsOneWidget);
      expect(find.text('Reiniciar reprodução'), findsNothing);
      expect(find.text('Apagar histórico'), findsNothing);

      // Oculta preservando progresso
      await tester.tap(find.text('Ocultar da Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ocultar'));
      await tester.pumpAndSettle();

      expect(find.text('Diários de um Vampiro'), findsNothing);
      final savedEp = await progress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: 77,
        episodeId: 7702,
      );
      expect(savedEp, isNotNull);
      expect(savedEp!.position.inMinutes, 18);

      // Sincronização Firebase com item na nuvem posterior NÃO ressuscita item oculto
      final syncId = CloudProgressSyncService.buildSyncId(accountKey);
      final futureTs = DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch;
      final syncMockClient = MockClient((req) async {
        if (req.url.path.endsWith('/$syncId')) {
          return http.Response(
            jsonEncode({
              'fields': {
                'syncId': {'stringValue': syncId},
                'updatedAtMs': {'integerValue': '$futureTs'},
                'itemsJson': {
                  'stringValue': jsonEncode({
                    'series_77': {
                      'type': 'series',
                      'streamId': 7702,
                      'seriesId': 77,
                      'title': 'Diários de um Vampiro',
                      'subtitle': 'T2:E5',
                      'pos': 1080000,
                      'dur': 2640000,
                      'time': futureTs,
                      'seasonNumber': 2,
                      'episodeNum': 5,
                    },
                  }),
                },
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final syncService = CloudProgressSyncService(
        client: syncMockClient,
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(syncService);
      await syncService.syncAccount(
        accountKey,
        progressService: progress,
        force: true,
      );
      expect(await progress.getContinueWatchingList(accountKey: accountKey), isEmpty);
    });

    testWidgets('FavoritesScreen com sidebar funcional, D-pad Esquerda/Direita, badge de progresso e 720p/1080p sem overflow', (tester) async {
      final progress = PlaybackProgressService();
      await progress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: 88,
        episodeId: 8805,
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 45),
      );
      await progress.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: 88,
        episodeId: 8805,
        seasonNumber: 2,
        episodeNum: 5,
      );
      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '10',
          scopeKey: accountKey,
          type: FavoriteType.live,
          name: 'Globo Nordeste HD Full Max Extra',
          addedAt: DateTime.now(),
        ),
      );
      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '88',
          scopeKey: accountKey,
          type: FavoriteType.series,
          name: 'Diários de um Vampiro',
          rating: '8.7',
          addedAt: DateTime.now(),
        ),
      );

      for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          PlayerTvApp(
            home: FavoritesScreen(
              xtreamAccount: account,
              catalogService: XtreamCatalogService(
                serverUrl: account.serverUrl,
                username: account.username,
                password: 'pass',
                cacheDirectoryOverride: tempDir,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('favorites_sidebar_home')), findsOneWidget);
        expect(find.byKey(const Key('favorites_cat_live')), findsOneWidget);
        expect(find.byKey(const Key('favorites_cat_movies')), findsOneWidget);
        expect(find.byKey(const Key('favorites_cat_series')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Navegação pura por D-pad: Baixo -> Baixo -> OK (seleciona Séries) -> Direita (vai para grade)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.text('Séries Favoritas'), findsOneWidget);
      expect(find.text('Diários de um Vampiro'), findsOneWidget);
      expect(find.text('T2:E5'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'FavSeries_0');

      // Esquerda retorna à categoria na sidebar
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'FavoritesCat_series');

      // Volta para grade e remove via Menu preservando histórico de reprodução
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Diários de um Vampiro'), findsNothing);
      final epProg = await progress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: 88,
        episodeId: 8805,
      );
      expect(epProg, isNotNull);
      expect(epProg!.position.inMinutes, 15);
    });
  });

  group('Fire TV 960x540 (dpr 2.0) - Escala Virtual 1280x720, Overscan e Grade 5 Colunas', () {
    const account = XtreamAccount(
      serverUrl: 'http://tv.p10.local',
      username: 'usuarioTvP10',
      isAuthorized: true,
      status: 'Active',
    );
    final accountKey = PlaybackProgressService.buildAccountKey(
      account.serverUrl,
      account.username,
    );

    testWidgets('PlayerTvApp normaliza 960x540 dpr 2.0 para 1280x720 com overscan e mantém celular inalterado', (tester) async {
      DeviceUtils.setMockIsTv(true);
      addTearDown(() => DeviceUtils.setMockIsTv(null));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late MediaQueryData capturedTvMq;
      await tester.pumpWidget(
        PlayerTvApp(
          home: Builder(
            builder: (ctx) {
              capturedTvMq = MediaQuery.of(ctx);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );
      expect(capturedTvMq.size.width, closeTo(1280.0, 0.5));
      expect(capturedTvMq.size.height, closeTo(720.0, 0.5));
      expect(capturedTvMq.devicePixelRatio, closeTo(1.5, 0.05));
      expect(capturedTvMq.padding.left, greaterThanOrEqualTo(48.0));
      expect(capturedTvMq.padding.right, greaterThanOrEqualTo(48.0));
      expect(capturedTvMq.padding.top, greaterThanOrEqualTo(30.0));
      expect(capturedTvMq.padding.bottom, greaterThanOrEqualTo(30.0));

      // Celular (não-TV) não recebe escala nem overscan de TV
      DeviceUtils.setMockIsTv(false);
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      late MediaQueryData capturedPhoneMq;
      await tester.pumpWidget(
        PlayerTvApp(
          home: Builder(
            builder: (ctx) {
              capturedPhoneMq = MediaQuery.of(ctx);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );
      expect(capturedPhoneMq.size.width, closeTo(390.0, 0.5));
      expect(capturedPhoneMq.size.height, closeTo(844.0, 0.5));
      expect(capturedPhoneMq.padding.left, 0.0);
    });

    testWidgets('Home, Séries (5 colunas) e Favoritos respeitam zona segura de overscan em Fire TV real', (tester) async {
      DeviceUtils.setMockIsTv(true);
      addTearDown(() => DeviceUtils.setMockIsTv(null));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '10',
          scopeKey: accountKey,
          type: FavoriteType.live,
          name: 'HBO HD',
          addedAt: DateTime.now(),
        ),
      );

      // 1. Home em Fire TV 960x540 @ dpr=2.0
      await tester.pumpWidget(
        const PlayerTvApp(home: HomeScreen(xtreamAccount: account)),
      );
      await tester.pumpAndSettle();
      final logoRect = tester.getRect(find.text('JessFlix'));
      final searchBtnRect = tester.getRect(find.byKey(const Key('header_search_btn')));
      expect(logoRect.top, greaterThanOrEqualTo(22.0));
      expect(logoRect.left, greaterThanOrEqualTo(36.0));
      expect(searchBtnRect.top, greaterThanOrEqualTo(22.0));
      expect(tester.takeException(), isNull);

      // 2. Séries em Fire TV: 5 colunas em 1280px virtuais e sidebar dentro da área de overscan
      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        if (action == 'get_series_categories') {
          return http.Response.bytes(
            utf8.encode(jsonEncode([
              {'category_id': '10', 'category_name': 'Series | Lancamento'},
              {'category_id': '11', 'category_name': 'Drama'},
            ])),
            200,
          );
        }
        if (action == 'get_series') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(List.generate(6, (i) => {
              'series_id': 3000 + i,
              'name': 'Série Grid ${i + 1}',
              'category_id': '10',
              'rating': '8',
            }))),
            200,
          );
        }
        return http.Response('[]', 200);
      });
      final catalog = XtreamCatalogService(
        serverUrl: account.serverUrl,
        username: account.username,
        password: 'p',
        client: client,
        cacheDirectoryOverride: tempDir,
      );
      await tester.pumpWidget(
        PlayerTvApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.series,
            catalogService: catalog,
          ),
        ),
      );
      for (var i = 0; i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      final catRect = tester.getRect(find.byKey(const Key('sidebar_cat_10')));
      expect(catRect.left, greaterThanOrEqualTo(36.0));
      // Série 1 e Série 5 devem estar na primeira linha (top iguais -> 5 colunas)
      final s1Rect = tester.getRect(find.text('Série Grid 1'));
      final s5Rect = tester.getRect(find.text('Série Grid 5'));
      expect((s1Rect.top - s5Rect.top).abs(), lessThan(2.0));
      expect(tester.takeException(), isNull);

      // 3. Favoritos em Fire TV respeita overscan
      await tester.pumpWidget(
        PlayerTvApp(
          home: FavoritesScreen(
            xtreamAccount: account,
            catalogService: catalog,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final favCatRect = tester.getRect(find.byKey(const Key('favorites_cat_live')));
      expect(favCatRect.left, greaterThanOrEqualTo(36.0));
      expect(tester.takeException(), isNull);
    });
  });

  group('Catalog Re-entry D-Pad - TV ao vivo, Filmes e Séries (Ida e Volta Sidebar <-> Direita)', () {
    void expectFocusInContentItems(WidgetTester tester, {required String stepLabel}) {
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull, reason: '$stepLabel: primaryFocus é nulo');
      expect(focused!.context, isNotNull, reason: '$stepLabel: context do foco é nulo');
      var inSidebar = false;
      var inAppBar = false;
      var inScrollable = false;
      focused.context!.visitAncestorElements((ancestor) {
        if (ancestor.widget is CatalogSidebar) inSidebar = true;
        if (ancestor.widget is AppBar) inAppBar = true;
        if (ancestor.widget is GridView || ancestor.widget is ListView) {
          inScrollable = true;
        }
        return true;
      });
      expect(inSidebar, isFalse, reason: '$stepLabel: foco permaneceu preso na sidebar');
      expect(inAppBar, isFalse, reason: '$stepLabel: foco escapou para a AppBar');
      expect(inScrollable, isTrue, reason: '$stepLabel: foco deve estar em um item à direita');
    }

    Future<void> pumpUntilItemsLoaded(WidgetTester tester) async {
      await tester.pump();
      for (var i = 0; i < 60 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pump(const Duration(milliseconds: 120));
    }

    testWidgets('Filmes: entrar em Lançamentos, rolar, voltar à sidebar e reentrar na grade + trocar categorias', (tester) async {
      DeviceUtils.setMockIsTv(true);
      addTearDown(() => DeviceUtils.setMockIsTv(null));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        final cat = req.url.queryParameters['category_id'];
        if (action == 'get_vod_categories') {
          return http.Response.bytes(
            utf8.encode(jsonEncode([
              {'category_id': '10', 'category_name': 'Filmes | Lançamentos'},
              {'category_id': '11', 'category_name': 'Ação'},
              {'category_id': '12', 'category_name': 'Comédia'},
            ])),
            200,
          );
        }
        if (action == 'get_vod_streams') {
          if (cat == '10') {
            return http.Response.bytes(
              utf8.encode(jsonEncode(List.generate(30, (i) => {
                'stream_id': 1000 + i,
                'name': 'Filme Lançamento $i',
                'category_id': '10',
                'container_extension': 'mp4',
              }))),
              200,
            );
          }
          if (cat == '11') {
            return http.Response.bytes(
              utf8.encode(jsonEncode(List.generate(10, (i) => {
                'stream_id': 2000 + i,
                'name': 'Filme Ação $i',
                'category_id': '11',
                'container_extension': 'mp4',
              }))),
              200,
            );
          }
          if (cat == '12') {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            return http.Response.bytes(
              utf8.encode(jsonEncode(List.generate(8, (i) => {
                'stream_id': 3000 + i,
                'name': 'Filme Comédia $i',
                'category_id': '12',
                'container_extension': 'mp4',
              }))),
              200,
            );
          }
        }
        return http.Response('[]', 200);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://reentry.local:8080',
        username: 'u',
        password: 'p',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        PlayerTvApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.movies,
            catalogService: catalog,
          ),
        ),
      );
      await pumpUntilItemsLoaded(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_10');

      // 1. Entra em Filmes | Lançamentos (Direita)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Filmes entrada 1');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'CatalogFirstItemFocus');

      // 2. Desce na grade para desmontar o item 0 da lista virtualizada e volta à esquerda
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expectFocusInContentItems(tester, stepLabel: 'Filmes após descer');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_10');

      // 3. Reentra na grade à direita na MESMA categoria mesmo após rolagem
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Filmes reentrada após rolagem');

      // 4. Volta à sidebar e troca para Ação -> confirma OK -> entra na direita
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_11');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await pumpUntilItemsLoaded(tester);
      expect(find.text('Filme Ação 0'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Filmes entrada em Ação');

      // 5. Volta à sidebar e pressiona OK novamente na categoria Ação já selecionada -> entra nos itens
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_11');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Filmes OK na categoria já selecionada');

      // 6. Volta à sidebar, seleciona Comédia (com carregamento assíncrono) e aperta Direita durante o loading
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await pumpUntilItemsLoaded(tester);
      expect(find.text('Filme Comédia 0'), findsOneWidget);
      expectFocusInContentItems(tester, stepLabel: 'Filmes pendência durante loading');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Séries: entrar, voltar à sidebar, trocar categoria e reentrar na grade repetidamente', (tester) async {
      DeviceUtils.setMockIsTv(true);
      addTearDown(() => DeviceUtils.setMockIsTv(null));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        final cat = req.url.queryParameters['category_id'];
        if (action == 'get_series_categories') {
          return http.Response.bytes(
            utf8.encode(jsonEncode([
              {'category_id': '10', 'category_name': 'Lançamentos'},
              {'category_id': '11', 'category_name': 'Drama'},
            ])),
            200,
          );
        }
        if (action == 'get_series') {
          final prefix = cat == '11' ? 'Série Drama' : 'Série Lançamento';
          return http.Response.bytes(
            utf8.encode(jsonEncode(List.generate(25, (i) => {
              'series_id': (cat == '11' ? 5000 : 4000) + i,
              'name': '$prefix $i',
              'category_id': cat ?? '10',
            }))),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://reentry-series.local:8080',
        username: 'u',
        password: 'p',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        PlayerTvApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.series,
            catalogService: catalog,
          ),
        ),
      );
      await pumpUntilItemsLoaded(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_10');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Séries Lançamentos');

      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_10');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Séries reentrada em Lançamentos');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await pumpUntilItemsLoaded(tester);
      expect(find.text('Série Drama 0'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'Séries Drama');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TV ao vivo: entrar nos canais, rolar lista, voltar à sidebar, trocar categoria e reentrar nos canais', (tester) async {
      DeviceUtils.setMockIsTv(true);
      addTearDown(() => DeviceUtils.setMockIsTv(null));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        final cat = req.url.queryParameters['category_id'];
        if (action == 'get_live_categories') {
          return http.Response.bytes(
            utf8.encode(jsonEncode([
              {'category_id': '20', 'category_name': 'Esportes'},
              {'category_id': '21', 'category_name': 'Variedades'},
            ])),
            200,
          );
        }
        if (action == 'get_live_streams') {
          final sports = List.generate(15, (i) => {
            'stream_id': 7000 + i,
            'name': 'Canal Esporte $i',
            'category_id': '20',
          });
          if (cat == '20') {
            return http.Response.bytes(
              utf8.encode(jsonEncode(sports)),
              200,
            );
          }
          final general = List.generate(25, (i) => {
            'stream_id': 6000 + i,
            'name': 'Canal Geral $i',
            'category_id': '21',
          });
          return http.Response.bytes(
            utf8.encode(jsonEncode([...general, ...sports])),
            200,
          );
        }
        if (action == 'get_short_epg' || action == 'get_simple_data_table') {
          return http.Response('{"epg_listings":[]}', 200);
        }
        return http.Response('[]', 200);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://reentry-live.local:8080',
        username: 'u',
        password: 'p',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        PlayerTvApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: catalog,
          ),
        ),
      );
      await pumpUntilItemsLoaded(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_all');

      // 1. Direita entra no primeiro canal
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'TV ao vivo entrada inicial');

      // 2. Desce 14 canais (fazendo scroll real na _channelScrollController) e volta com Esquerda
      for (var i = 0; i < 14; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 30));
      }
      expectFocusInContentItems(tester, stepLabel: 'TV ao vivo após descer 14 canais');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_all');

      // 3. Pressiona Direita para voltar à lista de canais à direita
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'TV ao vivo reentrada após rolagem');

      // 4. Volta à sidebar, muda para Esportes (OK) e entra nos canais (Direita)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // favorites
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // Esportes ('20')
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar_cat_20');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await pumpUntilItemsLoaded(tester);
      expect(find.text('Canal Esporte 0'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'TV ao vivo entrada em Esportes');

      // 5. Volta à sidebar e aperta OK novamente na categoria Esportes -> entra nos canais
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expectFocusInContentItems(tester, stepLabel: 'TV ao vivo OK na categoria já selecionada');
      expect(tester.takeException(), isNull);
    });
  });
}
