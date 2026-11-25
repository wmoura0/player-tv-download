import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/favorite_item.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/services/cloud_progress_sync_service.dart';
import 'package:projeto_tv/services/favorites_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';
import 'package:projeto_tv/services/series_identity_verifier.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/user_profile_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await UserProfileService.instance.init();
    await SettingsService.instance.loadSettings();
    FavoritesService.resetInstanceForTesting();
    SmartSourceResolver.instance.clearCache();
    PlayerDiagnostics.clearSeriesDiagnostics();
    CloudProgressSyncService.setMockInstance(null);
    tempDir = await Directory.systemTemp.createTemp('jessflix_p0_p8_');
  });

  tearDown(() async {
    CloudProgressSyncService.setMockInstance(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('P0 - Identidade de Séries (Gossip Girl e Homônimos/Ambíguos)', () {
    test('Rejeita mistura de séries diferentes com mesma categoria e mesmo rating', () {
      const gossipGirl = XtreamSeriesItem(
        seriesId: 101,
        name: 'Gossip Girl',
        categoryId: '10',
        rating: '7.5',
      );
      const gilmoreGirls = XtreamSeriesItem(
        seriesId: 102,
        name: 'Gilmore Girls',
        categoryId: '10',
        rating: '7.5',
      );
      const gossipShort = XtreamSeriesItem(
        seriesId: 103,
        name: 'Gossip',
        categoryId: '10',
        rating: '7.5',
      );
      const theGirls = XtreamSeriesItem(
        seriesId: 104,
        name: 'Girls',
        categoryId: '10',
        rating: '7.5',
      );

      expect(SeriesIdentityVerifier.areSameSeriesIdentity('Gossip Girl', 'Gilmore Girls'), isFalse);
      expect(SeriesIdentityVerifier.areSameSeriesIdentity('Gossip Girl', 'Gossip'), isFalse);
      expect(SeriesIdentityVerifier.areSameSeriesIdentity('Gossip Girl', 'Girls'), isFalse);

      expect(
        SeriesIdentityVerifier.findUnambiguousSeriesMatch(
          target: gossipGirl,
          candidates: [gilmoreGirls, gossipShort, theGirls],
        ),
        isNull,
      );

      expect(
        SeriesIdentityVerifier.verifySeriesInfoIdentity(
          requestedTitle: 'Gossip Girl',
          serverReturnedName: 'Gilmore Girls',
        ),
        SeriesIdentityConsistency.mismatch,
      );
    });

    test('Rejeita candidatos ambíguos com mesmo título sem desambiguação e não escolhe o primeiro arbitrariamente', () {
      const target = XtreamSeriesItem(
        seriesId: 50,
        name: 'Gossip Girl',
        categoryId: '0',
        rating: '8.0',
      );
      const cand1 = XtreamSeriesItem(
        seriesId: 201,
        name: 'Gossip Girl',
        categoryId: '12',
        rating: '8.0',
      );
      const cand2 = XtreamSeriesItem(
        seriesId: 202,
        name: 'Gossip Girl (Dublado)',
        categoryId: '15',
        rating: '8.0',
      );

      expect(
        SeriesIdentityVerifier.findUnambiguousSeriesMatch(
          target: target,
          candidates: [cand1, cand2],
        ),
        isNull,
      );

      // Anos explícitos distintos não podem casar entre si (ex.: original 2007 vs reboot 2021)
      expect(
        SeriesIdentityVerifier.areSameSeriesIdentity(
          'Gossip Girl (2007)',
          'Gossip Girl (2021)',
        ),
        isFalse,
      );
    });

    test('tryRecoverReindexedEpisode nunca associa episódio de outra série mesmo com rating/categoria iguais', () async {
      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        if (action == 'get_series') {
          return http.Response(
            jsonEncode([
              {
                'series_id': 999,
                'name': 'Pretty Little Liars',
                'category_id': '10',
                'rating': '7.5',
              },
              {
                'series_id': 998,
                'name': 'Gossip',
                'category_id': '10',
                'rating': '7.5',
              },
            ]),
            200,
          );
        }
        if (action == 'get_series_info') {
          return http.Response(
            jsonEncode({
              'info': {'name': 'Pretty Little Liars'},
              'episodes': {
                '1': [
                  {
                    'id': '99901',
                    'episode_num': 1,
                    'title': 'Pilot',
                    'season': 1,
                    'container_extension': 'mp4',
                  },
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
        username: 'secret_user',
        password: 'secret_password',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      const gossipGirl = XtreamSeriesItem(
        seriesId: 101,
        name: 'Gossip Girl',
        categoryId: '10',
        rating: '7.5',
      );
      final ep = XtreamSeriesEpisode(
        id: 10101,
        episodeNum: 1,
        title: 'S01E01',
        seasonNumber: 1,
        containerExtension: 'mp4',
      );

      final recovered = await SmartSourceResolver.instance.tryRecoverReindexedEpisode(
        catalogService: catalog,
        oldSeriesId: gossipGirl.seriesId,
        episode: ep,
        seriesTitle: gossipGirl.name,
        categoryId: gossipGirl.categoryId,
        probeClient: client,
      );

      expect(recovered, isNull);
    });

    testWidgets('SeriesDetailScreen bloqueia episódios trocados em mismatch e oferece Atualizar dados manualmente', (tester) async {
      final client = MockClient((req) async {
        final action = req.url.queryParameters['action'];
        if (action == 'get_series_info') {
          return http.Response(
            jsonEncode({
              'info': {'name': 'Outlander'},
              'seasons': [
                {'season_number': 1, 'name': 'Temporada 1'},
              ],
              'episodes': {
                '1': [
                  {
                    'id': '5501',
                    'episode_num': 1,
                    'title': 'Sassenach (ERRADO)',
                    'season': 1,
                    'container_extension': 'mp4',
                  },
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
        username: 'secret_user',
        password: 'secret_password',
        client: client,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: const XtreamSeriesItem(
              seriesId: 101,
              name: 'Gossip Girl',
              categoryId: '10',
              rating: '7.5',
            ),
            catalogService: catalog,
            accountKey: 'acc_p0_test',
          ),
        ),
      );

      for (var i = 0; i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Sassenach'), findsNothing);
      expect(find.text('Atualizar dados'), findsOneWidget);
      final cachedAfterReject = await tester.runAsync(
        () => catalog.getCachedSeriesInfo(101, expectedSeriesName: 'Gossip Girl'),
      );
      expect(cachedAfterReject, isNull);
    });
  });

  group('P4 & P8 - Diagnóstico get_series_info e Privacidade de Logs', () {
    XtreamCatalogService makeCatalog(Future<http.Response> Function(http.Request) handler) {
      return XtreamCatalogService(
        serverUrl: 'http://private-host.example:8080',
        username: 'my_private_user',
        password: 'my_super_secret_password',
        client: MockClient(handler),
        cacheDirectoryOverride: tempDir,
      );
    }

    test('Diferencia zero episódios reais, erro HTTP, JSON inválido, erro de rede e mismatch', () async {
      // 1. Servidor retornou zero episódios
      final catZero = makeCatalog((_) async => http.Response(
            jsonEncode({'info': {'name': 'Gossip Girl'}, 'seasons': [], 'episodes': []}),
            200,
          ));
      final resZero = await catZero.fetchSeriesInfoDetailed(101, expectedSeriesName: 'Gossip Girl');
      expect(resZero.category, SeriesInfoErrorCategory.serverReturnedNoEpisodes);
      expect(resZero.classification, DiagnosticClassification.confirmedServerIssue);

      // 2. Servidor retornou HTTP 500
      final catHttp500 = makeCatalog((_) async => http.Response('Internal Error', 500));
      final resHttp500 = await catHttp500.fetchSeriesInfoDetailed(102, expectedSeriesName: 'Dark');
      expect(resHttp500.category, SeriesInfoErrorCategory.httpServerError);
      expect(resHttp500.classification, DiagnosticClassification.confirmedServerIssue);
      expect(resHttp500.httpStatus, 500);

      // 3. JSON inválido
      final catBadJson = makeCatalog((_) async => http.Response('{not_valid_json', 200));
      final resBadJson = await catBadJson.fetchSeriesInfoDetailed(103, expectedSeriesName: 'Dark');
      expect(resBadJson.category, SeriesInfoErrorCategory.invalidJson);
      expect(resBadJson.classification, DiagnosticClassification.confirmedServerIssue);

      // 4. Estrutura map_of_maps válida não deve ser ignorada pelo parser
      final catMapOfMaps = makeCatalog((_) async => http.Response(
            jsonEncode({
              'info': {'name': 'Diários de um Vampiro'},
              'episodes': {
                '1': {
                  '101': {
                    'id': '9001',
                    'episode_num': 1,
                    'title': 'Pilot',
                    'season': 1,
                    'container_extension': 'mp4',
                  },
                },
              },
            }),
            200,
          ));
      final resMapOfMaps = await catMapOfMaps.fetchSeriesInfoDetailed(
        104,
        expectedSeriesName: 'Diários de um Vampiro',
      );
      expect(resMapOfMaps.category, SeriesInfoErrorCategory.none);
      expect(resMapOfMaps.hasUsableEpisodes, isTrue);
      expect(resMapOfMaps.info?.rawEpisodesShape, 'map_of_maps');

      // 5. Falha de rede / SocketException
      final catNet = makeCatalog((_) async => throw const SocketException('Connection refused'));
      final resNet = await catNet.fetchSeriesInfoDetailed(105, expectedSeriesName: 'Dark');
      expect(resNet.category, SeriesInfoErrorCategory.networkError);
      expect(resNet.classification, DiagnosticClassification.networkFailure);

      // 6. Mismatch de identidade
      final catMismatch = makeCatalog((_) async => http.Response(
            jsonEncode({
              'info': {'name': 'Another Series'},
              'episodes': {
                '1': [
                  {'id': '1', 'episode_num': 1, 'title': 'Ep 1', 'season': 1},
                ],
              },
            }),
            200,
          ));
      final resMismatch = await catMismatch.fetchSeriesInfoDetailed(
        106,
        expectedSeriesName: 'Gossip Girl',
      );
      expect(resMismatch.category, SeriesInfoErrorCategory.identityMismatch);
      expect(resMismatch.classification, DiagnosticClassification.confirmedServerIssue);

      // Verifica P8: registros diagnósticos sem vazamento de credenciais ou URL bruta
      final logs = PlayerDiagnostics.recentSeriesDiagnostics;
      expect(logs, isNotEmpty);
      for (final rec in logs) {
        final summary = rec.toLogSummary();
        expect(summary.contains('private-host.example'), isFalse);
        expect(summary.contains('my_private_user'), isFalse);
        expect(summary.contains('my_super_secret_password'), isFalse);
        expect(rec.anonymizedId.length, greaterThanOrEqualTo(8));
      }
    });
  });

  group('P6 - Continuidade de Progresso (Diários de um Vampiro)', () {
    test('Preserva episódio e segundos em Favoritos, não sobrescreve com <10s e migra reindexação sem apagar antigos', () async {
      final progress = PlaybackProgressService();
      const accountKey = 'http___tv_test_usuario';
      const oldSeriesId = 777;
      const newSeriesId = 888;
      const oldEpId = 77705;
      const newEpId = 88805;

      // 1. Favorita e salva progresso no episódio T3:E5 aos 22m30s
      await FavoritesService.instance.addFavorite(
        FavoriteItem(
          id: '$oldSeriesId',
          scopeKey: accountKey,
          type: FavoriteType.series,
          name: 'Diários de um Vampiro',
          categoryId: '1',
          addedAt: DateTime(2026, 11, 1),
        ),
      );
      await progress.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: oldSeriesId,
        episodeId: oldEpId,
        seasonNumber: 3,
        episodeNum: 5,
      );
      await progress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: oldSeriesId,
        episodeId: oldEpId,
        position: const Duration(minutes: 22, seconds: 30),
        duration: const Duration(minutes: 42),
      );

      // 2. Tentativa acidental com posição <10s não sobrescreve 22m30s
      await progress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: oldSeriesId,
        episodeId: oldEpId,
        position: const Duration(seconds: 3),
        duration: const Duration(minutes: 42),
      );
      final afterZero = await progress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: oldSeriesId,
        episodeId: oldEpId,
      );
      expect(afterZero?.position, const Duration(minutes: 22, seconds: 30));

      // 3. Reindexação inequívoca (oldSeriesId -> newSeriesId) migra não-destrutivamente
      final newInfo = XtreamSeriesInfo(
        name: 'Diários de um Vampiro',
        seasons: const [XtreamSeriesSeason(seasonNumber: 3, name: 'Temporada 3')],
        episodesBySeason: {
          3: [
            XtreamSeriesEpisode(
              id: newEpId,
              episodeNum: 5,
              title: 'The Reckoning',
              seasonNumber: 3,
              containerExtension: 'mp4',
            ),
          ],
        },
      );

      await progress.migrateSeriesProgressNonDestructively(
        accountKey: accountKey,
        oldSeriesId: oldSeriesId,
        newSeriesId: newSeriesId,
        seriesName: 'Diários de um Vampiro',
        newSeriesInfo: newInfo,
      );
      await FavoritesService.instance.migrateSeriesFavoriteId(
        accountKey: accountKey,
        oldSeriesId: oldSeriesId,
        newSeries: const XtreamSeriesItem(
          seriesId: newSeriesId,
          name: 'Diários de um Vampiro',
          categoryId: '1',
        ),
      );

      final migratedLast = await progress.getLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: newSeriesId,
      );
      expect(migratedLast?['episodeId'], newEpId);
      expect(migratedLast?['seasonNumber'], 3);
      expect(migratedLast?['episodeNum'], 5);

      final migratedEpProg = await progress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: newSeriesId,
        episodeId: newEpId,
      );
      expect(migratedEpProg?.position, const Duration(minutes: 22, seconds: 30));

      // Dados antigos preservados (migração não-destrutiva)
      final preservedOld = await progress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: oldSeriesId,
        episodeId: oldEpId,
      );
      expect(preservedOld?.position, const Duration(minutes: 22, seconds: 30));

      // Favorito migrado sem duplicar e preservando addedAt original
      final favs = await FavoritesService.instance.getFavorites(
        scopeKey: accountKey,
        type: FavoriteType.series,
      );
      expect(favs.length, 1);
      expect(favs.first.id, '$newSeriesId');
      expect(favs.first.addedAt, DateTime(2026, 11, 1));
    });
  });
}
