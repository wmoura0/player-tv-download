import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/services/cloud_progress_sync_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/user_profile_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _InMemoryCloudBackend {
  final Map<String, Map<String, dynamic>> docs = {};
  int authCalls = 0;
  int getCalls = 0;
  int patchCalls = 0;
  String? lastPatchedSyncId;

  http.Response _jsonResponse(Object payload, int statusCode) {
    return http.Response.bytes(
      utf8.encode(jsonEncode(payload)),
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }

  MockClient createClient({int? forceStatusCode, bool throwNetworkError = false}) {
    return MockClient((request) async {
      if (throwNetworkError) {
        throw http.ClientException('Offline simulated', request.url);
      }
      if (forceStatusCode != null) {
        return _jsonResponse({'error': {'code': forceStatusCode}}, forceStatusCode);
      }

      final urlStr = request.url.toString();
      if (urlStr.contains('identitytoolkit.googleapis.com/v1/accounts:signUp')) {
        authCalls++;
        return _jsonResponse({
          'idToken': 'fake_id_token_$authCalls',
          'refreshToken': 'fake_refresh_token_$authCalls',
          'localId': 'anon_uid_$authCalls',
          'expiresIn': '3600',
        }, 200);
      }

      if (urlStr.contains('securetoken.googleapis.com/v1/token')) {
        authCalls++;
        return _jsonResponse({
          'id_token': 'refreshed_id_token_$authCalls',
          'refresh_token': 'fake_refresh_token_$authCalls',
          'user_id': 'anon_uid_$authCalls',
          'expires_in': '3600',
        }, 200);
      }

      if (urlStr.contains('/documents/sync_profiles/')) {
        final docId = request.url.pathSegments.last;
        if (request.method == 'GET') {
          getCalls++;
          final doc = docs[docId];
          if (doc == null) {
            return _jsonResponse({'error': {'code': 404, 'status': 'NOT_FOUND'}}, 404);
          }
          return _jsonResponse(doc, 200);
        }
        if (request.method == 'PATCH') {
          patchCalls++;
          lastPatchedSyncId = docId;
          final bodyText = utf8.decode(request.bodyBytes);
          final body = jsonDecode(bodyText) as Map<String, dynamic>;
          docs[docId] = body;
          return _jsonResponse(body, 200);
        }
      }

      return _jsonResponse({'error': 'not_found'}, 404);
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await UserProfileService.instance.init();
  });

  tearDown(() {
    CloudProgressSyncService.setMockInstance(null);
  });

  group('CloudProgressSyncService - Sincronização Celular <-> Fire TV', () {
    test('buildSyncId gera hash SHA-256 hex de 64 chars sem vazar URL ou usuário', () {
      const accountKey = 'http___meuservidor_privado_tv_8080_usuario_wendell';
      final syncId = CloudProgressSyncService.buildSyncId(accountKey);

      expect(syncId.length, equals(64));
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(syncId), isTrue);
      expect(syncId.contains('meuservidor'), isFalse);
      expect(syncId.contains('wendell'), isFalse);
      expect(syncId.contains('8080'), isFalse);

      // Determinístico e case-insensitive para mesma conta
      expect(
        CloudProgressSyncService.buildSyncId('  $accountKey  '.toUpperCase()),
        equals(syncId),
      );
    });

    test('Celular -> Fire TV (Série): Celular em T1:E3 (18m) vence Fire TV em T1:E1 (40m) e limpa ep antigo', () async {
      final cloud = _InMemoryCloudBackend();
      const accountKey = 'http___tv_test_usuario';
      final baseTime = DateTime(2026, 11, 21, 20, 0);

      // 1. Dispositivo A (Celular) assistiu T1:E3 até 18min e enviou para a nuvem
      SharedPreferences.setMockInitialValues({});
      final mobileSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(mobileSync);
      final mobileProgress = PlaybackProgressService();

      await mobileProgress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: 500,
        episodeId: 1003,
        position: const Duration(minutes: 18),
        duration: const Duration(minutes: 45),
      );
      await mobileProgress.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: 500,
        episodeId: 1003,
        seasonNumber: 1,
        episodeNum: 3,
      );
      await mobileProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 1003,
          seriesId: 500,
          type: ContinueWatchingType.series,
          title: 'Silo',
          subtitle: 'T1:E3 • Episódio 3',
          coverUrl: 'http://img/silo.jpg',
          position: const Duration(minutes: 18),
          duration: const Duration(minutes: 45),
          updatedAt: baseTime,
          seasonNumber: 1,
          episodeNum: 3,
        ),
      );
      await mobileSync.syncAccount(accountKey, force: true);
      expect(cloud.patchCalls, greaterThanOrEqualTo(1));

      // 2. Dispositivo B (Fire TV) estava atrasado offline em T1:E1 aos 40min (mesmo com relógio posterior)
      SharedPreferences.setMockInitialValues({});
      CloudProgressSyncService.setMockInstance(null);
      final fireTvProgress = PlaybackProgressService();

      await fireTvProgress.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: 500,
        episodeId: 1001,
        position: const Duration(minutes: 40),
        duration: const Duration(minutes: 45),
      );
      await fireTvProgress.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: 500,
        episodeId: 1001,
        seasonNumber: 1,
        episodeNum: 1,
      );
      await fireTvProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 1001,
          seriesId: 500,
          type: ContinueWatchingType.series,
          title: 'Silo',
          subtitle: 'T1:E1 • Pilot',
          position: const Duration(minutes: 40),
          duration: const Duration(minutes: 45),
          updatedAt: baseTime.add(const Duration(hours: 2)),
          seasonNumber: 1,
          episodeNum: 1,
        ),
      );

      final fireTvSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(fireTvSync);

      final changed = await fireTvSync.syncAccount(
        accountKey,
        progressService: fireTvProgress,
        force: true,
      );
      expect(changed, isTrue);

      // Verifica que Fire TV avançou para T1:E3 aos 18min e limpou progresso antigo de T1:E1
      final last = await fireTvProgress.getLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: 500,
      );
      expect(last?['episodeId'], equals(1003));
      expect(last?['seasonNumber'], equals(1));
      expect(last?['episodeNum'], equals(3));

      final ep3Prog = await fireTvProgress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: 500,
        episodeId: 1003,
      );
      expect(ep3Prog?.position, equals(const Duration(minutes: 18)));

      final oldEp1Prog = await fireTvProgress.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: 500,
        episodeId: 1001,
      );
      expect(oldEp1Prog, isNull);

      final cw = await fireTvProgress.getContinueWatchingList(accountKey: accountKey);
      expect(cw.length, equals(1));
      expect(cw.first.streamId, equals(1003));
      expect(cw.first.position, equals(const Duration(minutes: 18)));
    });

    test('Fire TV -> Celular (Filme): Fire TV aos 55min vence Celular aos 12min mesmo com relógio mais novo no Celular', () async {
      final cloud = _InMemoryCloudBackend();
      const accountKey = 'http___tv_test_usuario';
      final t0 = DateTime(2026, 11, 21, 18, 0);

      // 1. Fire TV enviou Matrix aos 55min (relógio t0)
      SharedPreferences.setMockInitialValues({});
      final fireTvSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(fireTvSync);
      final fireTvProgress = PlaybackProgressService();

      await fireTvProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 88,
          type: ContinueWatchingType.movie,
          title: 'Matrix',
          coverUrl: 'http://img/matrix.jpg',
          position: const Duration(minutes: 55),
          duration: const Duration(minutes: 120),
          updatedAt: t0,
        ),
      );
      await fireTvSync.syncAccount(accountKey, force: true);

      // 2. Celular tem Matrix offline apenas aos 12min (com relógio 3h mais novo)
      SharedPreferences.setMockInitialValues({});
      CloudProgressSyncService.setMockInstance(null);
      final mobileProgress = PlaybackProgressService();

      await mobileProgress.saveProgress(
        accountKey: accountKey,
        streamId: 88,
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 120),
      );
      await mobileProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 88,
          type: ContinueWatchingType.movie,
          title: 'Matrix',
          position: const Duration(minutes: 12),
          duration: const Duration(minutes: 120),
          updatedAt: t0.add(const Duration(hours: 3)),
        ),
      );

      final mobileSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(mobileSync);

      final changed = await mobileSync.syncAccount(
        accountKey,
        progressService: mobileProgress,
        force: true,
      );
      expect(changed, isTrue);

      final vodProg = await mobileProgress.getProgress(
        accountKey: accountKey,
        streamId: 88,
      );
      expect(vodProg?.position, equals(const Duration(minutes: 55)));
    });

    test('Conclusão de filme no Celular remove item do Continuar Assistindo no Fire TV', () async {
      final cloud = _InMemoryCloudBackend();
      const accountKey = 'http___tv_test_usuario';
      final t0 = DateTime(2026, 11, 21, 19, 0);

      // 1. Celular concluiu o filme (119min de 120min)
      SharedPreferences.setMockInitialValues({});
      final mobileSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(mobileSync);
      final mobileProgress = PlaybackProgressService();

      await mobileProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 91,
          type: ContinueWatchingType.movie,
          title: 'Interestelar',
          position: const Duration(minutes: 119),
          duration: const Duration(minutes: 120),
          updatedAt: t0,
        ),
      );
      await mobileSync.syncAccount(accountKey, force: true);

      // 2. Fire TV ainda tinha o filme em andamento offline aos 30min
      SharedPreferences.setMockInitialValues({});
      CloudProgressSyncService.setMockInstance(null);
      final fireTvProgress = PlaybackProgressService();

      await fireTvProgress.saveProgress(
        accountKey: accountKey,
        streamId: 91,
        position: const Duration(minutes: 30),
        duration: const Duration(minutes: 120),
      );
      await fireTvProgress.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 91,
          type: ContinueWatchingType.movie,
          title: 'Interestelar',
          position: const Duration(minutes: 30),
          duration: const Duration(minutes: 120),
          updatedAt: t0.subtract(const Duration(hours: 1)),
        ),
      );

      final fireTvSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(fireTvSync);

      final changed = await fireTvSync.syncAccount(
        accountKey,
        progressService: fireTvProgress,
        force: true,
      );
      expect(changed, isTrue);

      final vodProg = await fireTvProgress.getProgress(
        accountKey: accountKey,
        streamId: 91,
      );
      expect(vodProg, isNull);

      final cw = await fireTvProgress.getContinueWatchingList(accountKey: accountKey);
      expect(cw, isEmpty);
    });

    test('Reinício manual posterior (manualResetAt) limpa progresso antigo na nuvem', () async {
      final cloud = _InMemoryCloudBackend();
      const accountKey = 'http___tv_test_usuario';
      final tOld = DateTime(2026, 11, 21, 15, 0);

      // 1. Nuvem possui Matrix aos 70min
      SharedPreferences.setMockInitialValues({});
      final tvSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(tvSync);
      await PlaybackProgressService().saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 44,
          type: ContinueWatchingType.movie,
          title: 'Matrix',
          position: const Duration(minutes: 70),
          duration: const Duration(minutes: 120),
          updatedAt: tOld,
        ),
      );
      await tvSync.syncAccount(accountKey, force: true);

      // 2. Celular clica em "Assistir do início" (clearProgress com timestamp atual > tOld)
      SharedPreferences.setMockInitialValues({});
      final mobileSync = CloudProgressSyncService(
        client: cloud.createClient(),
        enableInTests: true,
      );
      CloudProgressSyncService.setMockInstance(mobileSync);
      final mobileProgress = PlaybackProgressService();

      await mobileProgress.saveProgress(
        accountKey: accountKey,
        streamId: 44,
        position: const Duration(minutes: 70),
        duration: const Duration(minutes: 120),
      );
      await mobileProgress.clearProgress(accountKey: accountKey, streamId: 44);
      await mobileSync.syncAccount(accountKey, progressService: mobileProgress, force: true);

      // Celular continua zerado (manualResetAt venceu os 70min da nuvem)
      final prog = await mobileProgress.getProgress(accountKey: accountKey, streamId: 44);
      expect(prog, isNull);

      // E a nuvem recebeu o tombstone de reinício manual
      final syncId = CloudProgressSyncService.buildSyncId(accountKey);
      final itemsJsonStr = cloud.docs[syncId]?['fields']?['itemsJson']?['stringValue'] as String?;
      expect(itemsJsonStr, isNotNull);
      expect(itemsJsonStr!.contains('manualResetAt'), isTrue);
    });

    test('Resiliência offline: HTTP 503 e exceção de rede retornam false sem perder dados locais', () async {
      final cloud = _InMemoryCloudBackend();
      const accountKey = 'http___tv_test_usuario';

      SharedPreferences.setMockInitialValues({});
      final progressService = PlaybackProgressService();
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: 303,
        position: const Duration(minutes: 22),
        duration: const Duration(minutes: 95),
      );

      final offline503 = CloudProgressSyncService(
        client: cloud.createClient(forceStatusCode: 503),
        enableInTests: true,
      );
      expect(
        await offline503.syncAccount(accountKey, progressService: progressService, force: true),
        isFalse,
      );

      final offlineException = CloudProgressSyncService(
        client: cloud.createClient(throwNetworkError: true),
        enableInTests: true,
      );
      expect(
        await offlineException.syncAccount(accountKey, progressService: progressService, force: true),
        isFalse,
      );

      final local = await progressService.getProgress(accountKey: accountKey, streamId: 303);
      expect(local?.position, equals(const Duration(minutes: 22)));
    });
  });
}
