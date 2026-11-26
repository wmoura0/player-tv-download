import 'dart:async';
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
import 'package:projeto_tv/screens/hidden_categories_screen.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/screens/series_player_screen.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/cloud_progress_sync_service.dart';
import 'package:projeto_tv/services/favorites_service.dart';
import 'package:projeto_tv/services/hidden_categories_service.dart';
import 'package:projeto_tv/services/pin_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/user_profile_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _StubHomeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _controllers = {};
  int _nextId = 1;

  void disposeAll() {
    for (final c in _controllers.values) {
      if (!c.isClosed) unawaited(c.close());
    }
    _controllers.clear();
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int textureId) async {
    final c = _controllers.remove(textureId);
    if (c != null && !c.isClosed) unawaited(c.close());
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _nextId++;
    final controller = StreamController<VideoEvent>();
    _controllers[id] = controller;
    controller.onListen = () {
      scheduleMicrotask(() {
        if (!controller.isClosed) {
          controller.add(
            VideoEvent(
              eventType: VideoEventType.initialized,
              duration: const Duration(minutes: 45),
              size: const Size(1920, 1080),
            ),
          );
        }
      });
    };
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) =>
      _controllers[textureId]?.stream ?? const Stream.empty();

  @override
  Future<void> setLooping(int textureId, bool looping) async {}

  @override
  Future<void> play(int textureId) async {}

  @override
  Future<void> pause(int textureId) async {}

  @override
  Future<void> setVolume(int textureId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int textureId, Duration position) async {}

  @override
  Future<Duration> getPosition(int textureId) async => Duration.zero;

  @override
  Widget buildView(int textureId) => const SizedBox(width: 1920, height: 1080);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'mock_password'});
    await UserProfileService.instance.init();
    await PinService.instance.init();
    await HiddenCategoriesService.instance.init();
    HiddenCategoriesService.instance.clearForTesting();
    FavoritesService.resetInstanceForTesting();
    CloudProgressSyncService.setMockInstance(null);
    tempDir = await Directory.systemTemp.createTemp('jessflix_p1_p7_');
  });

  tearDown(() async {
    CloudProgressSyncService.setMockInstance(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('P1 - Continuar Assistindo: Operações Distintas, Persistência e Anti-Ressurreição', () {
    test('hideContinueWatchingItem oculta da Home preservando progresso, persiste no reinício e só volta com reprodução real', () async {
      final progress = PlaybackProgressService();
      const accountKey = 'http___tv_test_usuario';
      const seriesId = 900;
      const episodeId = 90001;

      await progress.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        seasonNumber: 2,
        episodeNum: 4,
      );
      await progress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 45),
      );
      await progress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: episodeId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: 'The Boys',
          subtitle: 'T2:E4',
          position: const Duration(minutes: 15),
          duration: const Duration(minutes: 45),
          updatedAt: DateTime(2026, 11, 20, 20, 0),
          seasonNumber: 2,
          episodeNum: 4,
        ),
      );

      // Oculta da Home
      await progress.hideContinueWatchingItem(
        accountKey: accountKey,
        type: ContinueWatchingType.series,
        id: seriesId,
      );

      // 1. Card removido imediatamente
      expect(await progress.getContinueWatchingList(accountKey: accountKey), isEmpty);
      expect(
        await progress.isHiddenFromHome(
          accountKey: accountKey,
          type: ContinueWatchingType.series,
          id: seriesId,
        ),
        isTrue,
      );

      // 2. Posição assistida do episódio foi preservada!
      final epProg = await progress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
      );
      expect(epProg?.position, const Duration(minutes: 15));

      // 3. Simula reinício do app com nova instância
      final restartedProgress = PlaybackProgressService();
      expect(await restartedProgress.getContinueWatchingList(accountKey: accountKey), isEmpty);

      // 4. Abrir detalhes / reconciliação não-real (isRealPlayback: false) NÃO restaura card
      await restartedProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        isRealPlayback: false,
        item: ContinueWatchingItem(
          streamId: episodeId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: 'The Boys',
          subtitle: 'T2:E4',
          position: const Duration(minutes: 15),
          duration: const Duration(minutes: 45),
          updatedAt: DateTime.now(),
          seasonNumber: 2,
          episodeNum: 4,
        ),
      );
      expect(await restartedProgress.getContinueWatchingList(accountKey: accountKey), isEmpty);

      // 5. Nova reprodução real (>=10s, isRealPlayback: true) volta a exibir na Home
      await restartedProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        isRealPlayback: true,
        item: ContinueWatchingItem(
          streamId: episodeId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: 'The Boys',
          subtitle: 'T2:E4',
          position: const Duration(minutes: 18),
          duration: const Duration(minutes: 45),
          updatedAt: DateTime.now().add(const Duration(seconds: 5)),
          seasonNumber: 2,
          episodeNum: 4,
        ),
      );
      final restored = await restartedProgress.getContinueWatchingList(accountKey: accountKey);
      expect(restored.length, 1);
      expect(restored.first.title, 'The Boys');
    });

    test('CloudProgressSyncService não ressuscita item ocultado na Home com timestamp posterior', () async {
      final tOldPlay = DateTime(2026, 11, 20, 18, 0);
      final docs = <String, Map<String, dynamic>>{};
      const accountKey = 'http___tv_test_usuario';
      final syncId = CloudProgressSyncService.buildSyncId(accountKey);

      docs[syncId] = {
        'fields': {
          'syncId': {'stringValue': syncId},
          'updatedAtMs': {'integerValue': '${tOldPlay.millisecondsSinceEpoch}'},
          'lastUid': {'stringValue': 'other_device'},
          'itemsJson': {
            'stringValue': jsonEncode({
              'series_700': ContinueWatchingItem(
                streamId: 70001,
                seriesId: 700,
                type: ContinueWatchingType.series,
                title: 'Lost',
                subtitle: 'T1:E1',
                position: const Duration(minutes: 25),
                duration: const Duration(minutes: 45),
                updatedAt: tOldPlay,
                seasonNumber: 1,
                episodeNum: 1,
              ).toJson(),
            }),
          },
        },
      };

      final client = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('signUp')) {
          return http.Response(
            jsonEncode({'idToken': 'tok', 'refreshToken': 'ref', 'localId': 'uid1', 'expiresIn': '3600'}),
            200,
          );
        }
        if (u.contains('/documents/sync_profiles/')) {
          final id = req.url.pathSegments.last;
          if (req.method == 'GET') {
            return docs[id] == null ? http.Response('{}', 404) : http.Response(jsonEncode(docs[id]), 200);
          }
          if (req.method == 'PATCH') {
            docs[id] = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            return http.Response(jsonEncode(docs[id]), 200);
          }
        }
        return http.Response('{}', 404);
      });

      final sync = CloudProgressSyncService(client: client, enableInTests: true);
      CloudProgressSyncService.setMockInstance(sync);
      final progress = PlaybackProgressService();

      await progress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 70001,
          seriesId: 700,
          type: ContinueWatchingType.series,
          title: 'Lost',
          position: const Duration(minutes: 25),
          duration: const Duration(minutes: 45),
          updatedAt: tOldPlay,
          seasonNumber: 1,
          episodeNum: 1,
        ),
      );
      await progress.hideContinueWatchingItem(
        accountKey: accountKey,
        type: ContinueWatchingType.series,
        id: 700,
      );

      await sync.syncAccount(accountKey, progressService: progress, force: true);
      expect(await progress.getContinueWatchingList(accountKey: accountKey), isEmpty);
    });

    testWidgets('HomeScreen abre opções ao pressionar Menu no card de Continuar Assistindo e oculta da Home', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const account = XtreamAccount(
        serverUrl: 'http://tv.test.local',
        username: 'user_home',
        isAuthorized: true,
        status: 'Active',
      );
      final ak = PlaybackProgressService.buildAccountKey(account.serverUrl, account.username);
      final progress = PlaybackProgressService();
      await progress.saveContinueWatchingItem(
        accountKey: ak,
        item: ContinueWatchingItem(
          streamId: 5001,
          seriesId: 50,
          type: ContinueWatchingType.series,
          title: 'Ruptura',
          subtitle: 'T1:E2',
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 45),
          updatedAt: DateTime.now(),
          seasonNumber: 1,
          episodeNum: 2,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: HomeScreen(xtreamAccount: account)));
      await tester.pumpAndSettle();

      expect(find.text('Ruptura'), findsOneWidget);
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

      await tester.tap(find.text('Ocultar da Home'));
      await tester.pumpAndSettle();

      expect(find.text('Ocultar'), findsOneWidget);
      await tester.tap(find.text('Ocultar'));
      await tester.pumpAndSettle();

      expect(find.text('Ruptura'), findsNothing);
    });

    testWidgets('HomeScreen permite descer o foco de Categorias até Opções e Card de Continuar Assistindo e clicar com OK', (tester) async {
      final originalVideoPlatform = VideoPlayerPlatform.instance;
      final stubVideo = _StubHomeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = stubVideo;
      addTearDown(() {
        stubVideo.disposeAll();
        VideoPlayerPlatform.instance = originalVideoPlatform;
      });

      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const account = XtreamAccount(
        serverUrl: 'http://tv.test.local',
        username: 'user_home_dpad',
        isAuthorized: true,
        status: 'Active',
      );
      final ak = PlaybackProgressService.buildAccountKey(account.serverUrl, account.username);
      final progress = PlaybackProgressService();
      await progress.saveContinueWatchingItem(
        accountKey: ak,
        item: ContinueWatchingItem(
          streamId: 6001,
          seriesId: 60,
          type: ContinueWatchingType.series,
          title: 'Diários de um Vampiro',
          subtitle: 'T2:E5',
          position: const Duration(minutes: 12),
          duration: const Duration(minutes: 42),
          updatedAt: DateTime.now(),
          seasonNumber: 2,
          episodeNum: 5,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: HomeScreen(xtreamAccount: account)));
      await tester.pumpAndSettle();

      // Garante que o foco inicial sai da seção de categorias ao navegar para baixo com D-pad
      var reachedOptions = false;
      var reachedCwCard = false;
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final focusedLabel = FocusManager.instance.primaryFocus?.debugLabel ?? '';
        if (focusedLabel == 'ContinueWatchingCard_0') {
          reachedCwCard = true;
          break;
        }
        final optionsFinder = find.text('Opções');
        if (optionsFinder.evaluate().isNotEmpty) {
          final optionsElement = optionsFinder.evaluate().first;
          final focusWidget = FocusManager.instance.primaryFocus?.context?.widget;
          var insideOptions = false;
          optionsElement.visitAncestorElements((el) {
            if (identical(el.widget, focusWidget)) {
              insideOptions = true;
              return false;
            }
            return true;
          });
          if (insideOptions) {
            reachedOptions = true;
          }
        }
      }

      // Pelo menos Opções ou ContinueWatchingCard_0 deve ter sido alcançado diretamente via ArrowDown
      expect(reachedOptions || reachedCwCard, isTrue);

      // Se parou em Opções, abre diálogo com OK e depois navega mais 1x para baixo até o card
      if (reachedOptions && !reachedCwCard) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(find.text('Ocultar da Home'), findsOneWidget);

        await tester.tap(find.text('Fechar'));
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'ContinueWatchingCard_0',
        );
      }

      // Pressiona OK no card de Continuar Assistindo e confirma navegação para o player
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(SeriesPlayerScreen), findsOneWidget);
    });
  });

  group('P2 & P3 - Catálogo de Séries: Preserva Lançamentos na Navegação e Pesquisa Global', () {
    testWidgets('Séries abre em Lançamentos, setas Esquerda/Direita não retornam para Todas e busca encontra séries fora da categoria', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        if (action == 'get_series_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '10', 'category_name': 'Lançamentos 2026'},
              {'category_id': '20', 'category_name': 'Netflix'},
              {'category_id': '30', 'category_name': 'Drama'},
            ]),
            200,
          );
        }
        if (action == 'get_series') {
          final cat = req.url.queryParameters['category_id'];
          final allSeries = [
            {'series_id': 1, 'name': 'Serie Lancamento Alpha', 'category_id': '10'},
            {'series_id': 2, 'name': 'Stranger Things', 'category_id': '20'},
            {'series_id': 3, 'name': 'Breaking Bad', 'category_id': '30'},
          ];
          if (cat == null || cat == 'all' || cat.isEmpty) {
            return http.Response(jsonEncode(allSeries), 200);
          }
          return http.Response(
            jsonEncode(allSeries.where((s) => s['category_id'] == cat).toList()),
            200,
          );
        }
        if (action == 'get_series_info') {
          return http.Response(
            jsonEncode({
              'info': {'name': 'Serie Lancamento Alpha'},
              'episodes': {
                '1': [
                  {'id': '100', 'episode_num': 1, 'title': 'Ep 1', 'season': 1},
                ],
              },
            }),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://test.iptv.local:8080',
        username: 'user_cat',
        password: 'p',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.series,
            catalogService: catalog,
          ),
        ),
      );

      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();

      // P2: Inicia automaticamente em Lançamentos 2026
      expect(find.text('Serie Lancamento Alpha'), findsOneWidget);
      expect(find.text('Breaking Bad'), findsNothing);

      // Move foco para o card e pressiona ArrowLeft -> retorna para Lançamentos 2026 (NÃO Todas!)
      Focus.of(tester.element(find.text('Serie Lancamento Alpha'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      // Conteúdo continua filtrado em Lançamentos 2026 (Breaking Bad NÃO apareceu!)
      expect(find.text('Serie Lancamento Alpha'), findsOneWidget);
      expect(find.text('Breaking Bad'), findsNothing);

      // Pressiona ArrowRight volta para o card preservando Lançamentos
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('Serie Lancamento Alpha'), findsOneWidget);
      expect(find.text('Breaking Bad'), findsNothing);

      // P2: Entra nos detalhes da série e volta mantendo Lançamentos
      await tester.tap(find.text('Serie Lancamento Alpha'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.byType(SeriesDetailScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(SeriesDetailScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Serie Lancamento Alpha'), findsOneWidget);
      expect(find.text('Breaking Bad'), findsNothing);

      // P3: Pesquisa global encontra série de outra categoria ('Breaking Bad' em Drama)
      await tester.enterText(find.byType(TextField), 'Breaking Bad');
      await tester.pump(const Duration(milliseconds: 400));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(GridView),
          matching: find.text('Breaking Bad'),
        ),
        findsOneWidget,
      );
      expect(find.text('Serie Lancamento Alpha'), findsNothing);

      // Limpar pesquisa restaura exatamente a categoria anterior (Lançamentos 2026)
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Serie Lancamento Alpha'), findsOneWidget);
      expect(find.text('Breaking Bad'), findsNothing);
    });
  });

  group('P5 & P7 - Favoritos (Controle Remoto + Perfis), PIN e Categorias Ocultas', () {
    testWidgets('FavoritesScreen remove via tecla Delete, persiste, permite Desfazer e isola por perfil', (tester) async {
      const acc = XtreamAccount(
        serverUrl: 'http://fav.test.local:80',
        username: 'user_fav',
        isAuthorized: true,
        status: 'Active',
      );
      final ak = PlaybackProgressService.buildAccountKey(acc.serverUrl, acc.username);

      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '10',
          scopeKey: ak,
          type: FavoriteType.live,
          name: 'SporTV',
          addedAt: DateTime(2026, 11, 20),
        ),
      );
      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '11',
          scopeKey: ak,
          type: FavoriteType.live,
          name: 'Telecine',
          addedAt: DateTime(2026, 11, 19),
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FavoritesScreen(xtreamAccount: acc)));
      await tester.pumpAndSettle();

      expect(find.text('SporTV'), findsOneWidget);
      expect(find.text('Telecine'), findsOneWidget);

      // Foca SporTV e remove via tecla Delete no controle/teclado
      final favNode = FocusManager.instance.rootScope.traversalDescendants
          .firstWhere((n) => n.debugLabel == 'FavLive_0');
      favNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(find.text('SporTV'), findsNothing);
      expect(find.text('Telecine'), findsOneWidget);
      expect(FavoritesService.instance.isFavorite(scopeKey: ak, type: FavoriteType.live, id: '10'), isFalse);

      // Desfaz remoção via botão inline acessível ao D-pad
      await tester.tap(find.text('Desfazer remoção'));
      await tester.pumpAndSettle();
      expect(find.text('SporTV'), findsOneWidget);
      expect(FavoritesService.instance.isFavorite(scopeKey: ak, type: FavoriteType.live, id: '10'), isTrue);

      // Troca de perfil isola favoritos sem vazar perfil anterior
      final p2 = await UserProfileService.instance.createProfile(name: 'Perfil 2');
      await UserProfileService.instance.switchProfile(p2.id);
      await tester.pumpAndSettle();
      expect(find.text('SporTV'), findsNothing);
    });

    testWidgets('P7 - Troca de perfil bloqueia sessão PIN, removePin limpa PIN real e HiddenCategories conta sem duplicar', (tester) async {
      await PinService.instance.setPin('1234');
      await PinService.instance.setHideAdultContent(true);
      await PinService.instance.setCategoryLocked('99', true);
      PinService.instance.unlockCategoryForSession('99');
      expect(PinService.instance.isCategoryLocked('99'), isFalse);

      final p2 = await UserProfileService.instance.createProfile(name: 'Convidado');
      await UserProfileService.instance.switchProfile(p2.id);
      expect(PinService.instance.isCategoryLocked('99'), isTrue);

      expect(await PinService.instance.removePin('1234'), isTrue);
      expect(PinService.instance.isPinSet, isFalse);

      // HiddenCategoriesScreen conta por categoria única (não ID+nome em dobro)
      await tester.pumpWidget(
        const MaterialApp(
          home: HiddenCategoriesScreen(
            scopeKey: 'acc_hidden_test',
            sourceTitle: 'Conta Teste',
            categories: [
              HiddenCategoryItem(id: '1', name: 'Esportes'),
              HiddenCategoryItem(id: '2', name: 'Filmes'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Esportes'));
      await tester.pumpAndSettle();

      expect(find.text('1 de 2 categorias ocultas'), findsOneWidget);
    });
  });
}
