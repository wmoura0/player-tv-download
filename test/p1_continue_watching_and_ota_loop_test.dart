import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/ota_update_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('p1_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.player.m3u/device'), null);
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('P1 - OTA Update Downgrade Trap & Stale APK Prevention', () {
    test('syncWithNativeStatus purges APK and marks upToDate when native versionCode <= currentVersionCode', () async {
      bool cleanOldApksCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('com.player.m3u/device'), (call) async {
        if (call.method == 'getOtaDownloadStatus') {
          return {
            'status': 'READY_TO_INSTALL',
            'apkPath': '/fake/update_v10.apk',
            'versionCode': 10, // Menor que o atual (12)
            'versionName': '1.2.8',
          };
        } else if (call.method == 'cleanOldApks') {
          cleanOldApksCalled = true;
          return true;
        }
        return null;
      });

      final service = OtaUpdateService();
      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.upToDate));
      expect(service.downloadedApkFile, isNull);
      expect(cleanOldApksCalled, isTrue);
    });

    test('syncWithNativeStatus discards APK and sets updateAvailable when file size mismatches manifest', () async {
      final fakeApk = File('${tempDir.path}/update_newer.apk');
      fakeApk.writeAsBytesSync(utf8.encode('CORRUPT_BYTES_SMALL'));

      final newVersionCode = OtaUpdateService.currentVersionCode + 1;
      bool cleanCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('com.player.m3u/device'), (call) async {
        if (call.method == 'getOtaDownloadStatus') {
          return {
            'status': 'READY_TO_INSTALL',
            'apkPath': fakeApk.path,
            'versionCode': newVersionCode,
            'versionName': '1.3.0',
          };
        } else if (call.method == 'cleanOldApks') {
          cleanCalled = true;
          return true;
        }
        return null;
      });

      final mockClient = MockClient((request) async {
        final manifest = {
          'version': '1.3.0',
          'versionCode': newVersionCode,
          'apkUrl': 'https://example.com/app.apk',
          'fileSize': 999999, // Esperado 999KB, arquivo real tem < 100 bytes
          'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          'releaseNotes': 'Notas de versão 1.3.0',
        };
        return http.Response(jsonEncode(manifest), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      await service.checkForUpdates(customUrl: 'https://example.com/manifest.json');
      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.updateAvailable));
      expect(service.downloadedApkFile, isNull);
      expect(cleanCalled, isTrue);
    });

    test('syncWithNativeStatus marks readyToInstall when file size and SHA-256 match manifest', () async {
      final validContent = 'VALID_APK_PAYLOAD_FOR_TESTING';
      final fakeApk = File('${tempDir.path}/update_valid.apk');
      fakeApk.writeAsBytesSync(utf8.encode(validContent));

      final newVersionCode = OtaUpdateService.currentVersionCode + 1;
      final digest = sha256.convert(fakeApk.readAsBytesSync()).toString();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('com.player.m3u/device'), (call) async {
        if (call.method == 'getOtaDownloadStatus') {
          return {
            'status': 'READY_TO_INSTALL',
            'apkPath': fakeApk.path,
            'versionCode': newVersionCode,
            'versionName': '1.3.0',
          };
        }
        return null;
      });

      final mockClient = MockClient((request) async {
        final manifest = {
          'version': '1.3.0',
          'versionCode': newVersionCode,
          'apkUrl': 'https://example.com/app.apk',
          'fileSize': fakeApk.lengthSync(),
          'sha256': digest,
          'releaseNotes': 'Notas de versão 1.3.0',
        };
        return http.Response(jsonEncode(manifest), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      await service.checkForUpdates(customUrl: 'https://example.com/manifest.json');
      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.readyToInstall));
      expect(service.downloadedApkFile?.path, equals(fakeApk.path));
    });
  });

  group('P1 - Continuar Assistindo Regex and Metadata Extraction', () {
    (int, int) parseSeasonEpisode(String? subtitle) {
      int? season;
      int? epNum;
      if (subtitle != null) {
        final sub = subtitle.trim();
        final regExp1 = RegExp(r'(?:[sStT]|temp|temporada)[\s.:xX\-]*(\d+)[\s.,:xXeE\-_|•]+(?:[eE]|ep|episodio|episódio)?[\s.:xX\-]*(\d+)', caseSensitive: false);
        final regExp2 = RegExp(r'(\d+)[\s]*[xX][\s]*(\d+)');
        final regExp3 = RegExp(r'(?:[eE]|ep|episodio|episódio)[\s.:xX\-]*(\d+)', caseSensitive: false);

        final match1 = regExp1.firstMatch(sub);
        if (match1 != null) {
          season = int.tryParse(match1.group(1)!);
          epNum = int.tryParse(match1.group(2)!);
        } else {
          final match2 = regExp2.firstMatch(sub);
          if (match2 != null) {
            season = int.tryParse(match2.group(1)!);
            epNum = int.tryParse(match2.group(2)!);
          } else {
            final match3 = regExp3.firstMatch(sub);
            if (match3 != null) {
              epNum = int.tryParse(match3.group(1)!);
            }
          }
        }
      }
      return (season ?? 1, epNum ?? 1);
    }

    test('Extrai temporada e episódio de múltiplos formatos comuns de subtitle', () {
      expect(parseSeasonEpisode('T4:E2 • Memorial'), equals((4, 2)));
      expect(parseSeasonEpisode('Temporada 4, Episódio 2'), equals((4, 2)));
      expect(parseSeasonEpisode('Temp 4 - Ep 2'), equals((4, 2)));
      expect(parseSeasonEpisode('4x02 - Memorial'), equals((4, 2)));
      expect(parseSeasonEpisode('S04E02'), equals((4, 2)));
      expect(parseSeasonEpisode('Episódio 2'), equals((1, 2)));
      expect(parseSeasonEpisode('ep 7'), equals((1, 7)));
      expect(parseSeasonEpisode(null), equals((1, 1)));
    });
  });

  group('P1 - SmartSourceResolver Reindexed Episode Recovery', () {
    test('tryRecoverReindexedEpisode recovers episode when episode ID changed inside SAME series', () async {
      final mockClient = MockClient((request) async {
        final uri = request.url;
        final action = uri.queryParameters['action'];

        if (action == 'get_series_info') {
          final seriesId = uri.queryParameters['series_id'];
          if (seriesId == '113752') {
            // Retorna a série atualizada onde o episódio 2 da temporada 4 agora tem id 9999999 (antigo era 3479097)
            final jsonResp = {
              'seasons': [
                {'season_number': 4, 'name': 'Temporada 4'}
              ],
              'info': {'name': 'Diários de um Vampiro'},
              'episodes': {
                '4': [
                  {
                    'id': '3479096',
                    'episode_num': 1,
                    'title': 'Episódio 1',
                    'container_extension': 'mp4',
                  },
                  {
                    'id': '9999999', // NOVO ID APÓS REINDEXAÇÃO DO PROVEDOR
                    'episode_num': 2,
                    'title': 'Memorial',
                    'container_extension': 'mp4',
                  },
                ]
              }
            };
            return http.Response(jsonEncode(jsonResp), 200, headers: {'content-type': 'application/json'});
          }
        }
        if (uri.path.contains('9999999')) {
          return http.Response('VIDEO_BYTES', 200, headers: {'content-length': '11'});
        }
        return http.Response('Not Found', 404);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      final deadEp = XtreamSeriesEpisode(
        id: 3479097,
        episodeNum: 2,
        seasonNumber: 4,
        title: 'Memorial',
        containerExtension: 'mp4',
      );

      final result = await SmartSourceResolver.instance.tryRecoverReindexedEpisode(
        catalogService: catalog,
        oldSeriesId: 113752,
        episode: deadEp,
        seriesTitle: 'Diários de um Vampiro',
        probeClient: mockClient,
      );

      expect(result, isNotNull);
      expect(result!.isSuccess, isTrue);
      expect(result.recoveredEpisode?.id, equals(9999999));
      expect(result.recoveredSeriesId, equals(113752));
      expect(result.workingUrl, contains('9999999.mp4'));
    });

    test('probeUrl detects Content-Length: 0 as invalid even if HTTP 200 is returned', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 200, headers: {'content-length': '0'});
      });

      final isValid = await SmartSourceResolver.instance.probeUrl(
        'http://testserver.tv:8080/series/user/pass/3479097.mp4',
        client: mockClient,
      );

      expect(isValid, isFalse);
    });

    test('probeUrl accepts HTTP 200/206 with real content length', () async {
      final mockClient = MockClient((request) async {
        return http.Response('MEDIA_SAMPLE_DATA', 200, headers: {'content-length': '17'});
      });

      final isValid = await SmartSourceResolver.instance.probeUrl(
        'http://testserver.tv:8080/series/user/pass/9999999.mp4',
        client: mockClient,
      );

      expect(isValid, isTrue);
    });
  });

  group('Home Continue Watching Fixes - VOD SmartSource & SeriesInfo Disk Cache', () {
    test('resolveBestVodSource descobre extensão real via get_vod_info quando containerExtension é nulo', () async {
      SmartSourceResolver.instance.clearCache();
      final mockClient = MockClient((request) async {
        final uri = request.url;
        if (uri.queryParameters['action'] == 'get_vod_info' &&
            uri.queryParameters['vod_id'] == '8888') {
          return http.Response(
            jsonEncode({
              'movie_data': {
                'stream_id': 8888,
                'name': 'Duna Parte 2',
                'container_extension': 'mkv',
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (uri.path.endsWith('/movie/user/pass/8888.mkv')) {
          return http.Response('VIDEO_OK', 200, headers: {'content-length': '8'});
        }
        return http.Response('Not Found', 404);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      const movie = XtreamVodStream(
        streamId: 8888,
        name: 'Duna Parte 2',
        categoryId: '5',
        containerExtension: null,
      );

      final result = await SmartSourceResolver.instance.resolveBestVodSource(
        catalogService: catalog,
        movie: movie,
        probeClient: mockClient,
      );

      expect(result.isSuccess, isTrue);
      expect(result.containerExtension, equals('mkv'));
      expect(result.workingUrl, contains('/movie/user/pass/8888.mkv'));
      expect(result.recoveredSeriesId, equals(8888));
    });

    test('resolveBestVodSource recupera filme reindexado pelo título normalizado quando streamId antigo retorna 404', () async {
      SmartSourceResolver.instance.clearCache();
      final mockClient = MockClient((request) async {
        final uri = request.url;
        final action = uri.queryParameters['action'];
        if (action == 'get_vod_info') {
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }
        if (action == 'get_vod_streams') {
          return http.Response(
            jsonEncode([
              {
                'stream_id': 2000,
                'name': 'O Poderoso Chefao (1972)',
                'category_id': '5',
                'container_extension': 'mp4',
              }
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (uri.path.endsWith('/movie/user/pass/2000.mp4')) {
          return http.Response('VIDEO_OK', 200, headers: {'content-length': '8'});
        }
        return http.Response('Not Found', 404);
      });

      final catalog = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      const oldMovie = XtreamVodStream(
        streamId: 1000,
        name: 'O Poderoso Chefao',
        categoryId: '5',
        containerExtension: 'mp4',
      );

      final result = await SmartSourceResolver.instance.resolveBestVodSource(
        catalogService: catalog,
        movie: oldMovie,
        probeClient: mockClient,
      );

      expect(result.isSuccess, isTrue);
      expect(result.recoveredSeriesId, equals(2000));
      expect(result.workingUrl, contains('/movie/user/pass/2000.mp4'));
    });

    test('fetchSeriesInfo persiste metadados em disco e recarrega instantaneamente em nova sessão', () async {
      final onlineClient = MockClient((request) async {
        if (request.url.queryParameters['action'] == 'get_series_info' &&
            request.url.queryParameters['series_id'] == '555') {
          return http.Response(
            jsonEncode({
              'seasons': [
                {'season_number': 1, 'name': 'Temporada 1'}
              ],
              'info': {'name': 'Série Cacheada'},
              'episodes': {
                '1': [
                  {
                    'id': '7001',
                    'episode_num': 1,
                    'title': 'Piloto',
                    'container_extension': 'mkv',
                  }
                ]
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final catalogOnline = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'user',
        password: 'pass',
        client: onlineClient,
        cacheDirectoryOverride: tempDir,
      );

      final fetched = await catalogOnline.fetchSeriesInfo(555);
      expect(fetched, isNotNull);
      expect(fetched!.findEpisodeById(7001)?.containerExtension, equals('mkv'));

      // Aguarda gravação assíncrona em disco completar
      await Future.delayed(const Duration(milliseconds: 100));

      final offlineClient = MockClient((request) async {
        return http.Response('Network Error', 503);
      });

      final catalogOffline = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'user',
        password: 'pass',
        client: offlineClient,
        cacheDirectoryOverride: tempDir,
      );

      final restoredFromDisk = await catalogOffline.fetchSeriesInfo(555);
      expect(restoredFromDisk, isNotNull);
      expect(restoredFromDisk!.name, equals('Série Cacheada'));
      expect(restoredFromDisk.findEpisodeById(7001)?.containerExtension, equals('mkv'));
    });

    test('buildVodStreamUrls inclui extensões extras e directSource sem alterar as 3 rotas principais', () {
      final catalog = XtreamCatalogService(
        serverUrl: 'http://testserver.tv:8080',
        username: 'user',
        password: 'pass',
      );

      const movie = XtreamVodStream(
        streamId: 42,
        name: 'Teste VOD',
        categoryId: '1',
        containerExtension: 'avi',
        directSource: 'https://cdn.example.com/custom/42.mp4',
      );

      final urls = catalog.buildVodStreamUrls(movie);
      expect(urls[0], equals('http://testserver.tv:8080/movie/user/pass/42.avi'));
      expect(urls[1], equals('http://testserver.tv:8080/movie/user/pass/42.mp4'));
      expect(urls[2], equals('http://testserver.tv:8080/user/pass/42.avi'));
      expect(urls, contains('http://testserver.tv:8080/movie/user/pass/42.mkv'));
      expect(urls, contains('http://testserver.tv:8080/movie/user/pass/42.ts'));
      expect(urls.last, equals('https://cdn.example.com/custom/42.mp4'));
    });
  });
}
