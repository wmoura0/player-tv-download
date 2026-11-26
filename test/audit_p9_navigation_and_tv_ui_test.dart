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
}
