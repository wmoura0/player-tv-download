import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/ota_update_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceUtils.setMockAppVersion(versionCode: 12, versionName: '1.2.9');
  });

  tearDown(() {
    DeviceUtils.setMockAppVersion(versionCode: 12, versionName: '1.2.9');
  });

  group('HOTFIX P0 — BUG 1: Prevenção do Loop de Atualização OTA', () {
    test('1.1 DeviceUtils e OtaUpdateService refletem a versão instalada corrente (1.2.9+12)', () {
      expect(DeviceUtils.installedVersionCode, equals(12));
      expect(DeviceUtils.installedVersionName, equals('1.2.9'));
      expect(OtaUpdateService.currentVersionCode, equals(12));
      expect(OtaUpdateService.currentVersionName, equals('1.2.9'));
    });

    test('1.2 Manifest remoto com versionCode 11 (v1.2.8 de produção) é rejeitado quando instalado é 12 (v1.2.9)', () async {
      final mockClient = MockClient((request) async {
        final manifestData = {
          'version': '1.2.8',
          'versionCode': 11,
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.2.8/JessFlix-v1.2.8.apk',
          'fileSize': 58783821,
          'sha256': 'a' * 64,
          'releaseNotes': 'Versão 1.2.8 de produção',
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isFalse, reason: 'Versão 11 não pode ser oferecida quando app já tem versão 12');
      expect(result.isUpToDate, isTrue);
      expect(service.status, equals(UpdateStatus.upToDate));
    });

    test('1.3 Manifest remoto com mesmo versionCode (12) é considerado atualizado', () async {
      final mockClient = MockClient((request) async {
        final manifestData = {
          'version': '1.2.9',
          'versionCode': 12,
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.2.9/JessFlix-v1.2.9.apk',
          'fileSize': 58783821,
          'sha256': 'b' * 64,
          'releaseNotes': 'Mesma versão instalada',
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isTrue);
    });

    test('1.4 Manifest remoto com versionCode superior (13) é aceito como nova versão', () async {
      final mockClient = MockClient((request) async {
        final manifestData = {
          'version': '1.3.0',
          'versionCode': 13,
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.3.0/JessFlix-v1.3.0.apk',
          'fileSize': 58783821,
          'sha256': 'c' * 64,
          'releaseNotes': 'Futura versão v1.3.0',
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isTrue);
      expect(result.isUpToDate, isFalse);
      expect(result.manifest?.versionCode, equals(13));
    });

    test('1.5 syncWithNativeStatus limpa resíduo de download se versão baixada já foi instalada', () async {
      // Simula que o manifesto checado era da versão 11
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({
          'version': '1.2.8',
          'versionCode': 11,
          'apkUrl': 'https://example.com/app.apk',
          'fileSize': 1000,
          'sha256': 'd' * 64,
          'releaseNotes': 'Notas',
        }), 200);
      });
      final checkedService = OtaUpdateService(client: mockClient);
      await checkedService.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(checkedService.status, equals(UpdateStatus.upToDate));
      expect(checkedService.latestManifest?.versionCode, equals(11));
    });
  });

  group('HOTFIX P0 — BUG 2: Resiliência do Continuar Assistindo para Séries', () {
    test('2.1 Extrai com precisão número de temporada e episódio do subtítulo quando ausentes no item', () {
      final item1 = ContinueWatchingItem(
        streamId: 101,
        type: ContinueWatchingType.series,
        title: 'Stranger Things',
        subtitle: 'T2:E4 • O Devorador de Mentes',
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 50),
        updatedAt: DateTime.now(),
      );

      final regExp = RegExp(r'[sStT](\d+)[\s:xXeE\-]+(?:[eE]|ep|Ep)?(\d+)');
      final match1 = regExp.firstMatch(item1.subtitle!);
      expect(match1, isNotNull);
      expect(int.parse(match1!.group(1)!), equals(2));
      expect(int.parse(match1.group(2)!), equals(4));

      final item2 = ContinueWatchingItem(
        streamId: 202,
        type: ContinueWatchingType.series,
        title: 'Breaking Bad',
        subtitle: 'S05E14 - Ozymandias',
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 45),
        updatedAt: DateTime.now(),
      );
      final match2 = regExp.firstMatch(item2.subtitle!);
      expect(match2, isNotNull);
      expect(int.parse(match2!.group(1)!), equals(5));
      expect(int.parse(match2.group(2)!), equals(14));
    });

    test('2.2 Tolera item de série com seriesId nulo utilizando streamId como identificador efetivo', () {
      final item = ContinueWatchingItem(
        streamId: 442,
        seriesId: null, // Caso legado ou de item migrado
        type: ContinueWatchingType.series,
        title: 'The Boys',
        subtitle: 'T1:E1',
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 60),
        updatedAt: DateTime.now(),
      );

      final int effectiveSeriesId = (item.seriesId != null && item.seriesId! > 0)
          ? item.seriesId!
          : item.streamId;

      expect(effectiveSeriesId, equals(442));
    });

    test('2.3 Sintetiza XtreamSeriesEpisode e XtreamSeriesInfo transparentemente quando fetchSeriesInfo falha', () {
      final item = ContinueWatchingItem(
        streamId: 9901,
        seriesId: 300,
        type: ContinueWatchingType.series,
        title: 'Loki',
        subtitle: 'T1:E3 • Lamentis',
        coverUrl: 'https://example.com/loki.jpg',
        position: const Duration(minutes: 22),
        duration: const Duration(minutes: 48),
        updatedAt: DateTime.now(),
        containerExtension: 'mkv',
        seasonNumber: 1,
        episodeNum: 3,
      );

      // Simulação: fetchSeriesInfo retornou null (timeout/falha de rede)
      final XtreamSeriesInfo? info = null;

      final targetEpisode = XtreamSeriesEpisode(
        id: item.streamId,
        episodeNum: item.episodeNum ?? 1,
        seasonNumber: item.seasonNumber ?? 1,
        title: 'Lamentis',
        containerExtension: item.containerExtension ?? 'mp4',
        cover: item.coverUrl,
      );

      final effectiveInfo = info ?? XtreamSeriesInfo(
        name: item.title,
        cover: item.coverUrl,
        seasons: [
          XtreamSeriesSeason(
            seasonNumber: item.seasonNumber ?? 1,
            name: 'Temporada ${item.seasonNumber ?? 1}',
          ),
        ],
        episodesBySeason: {
          item.seasonNumber ?? 1: [targetEpisode],
        },
      );

      expect(effectiveInfo.name, equals('Loki'));
      expect(effectiveInfo.seasons.length, equals(1));
      expect(effectiveInfo.episodesBySeason[1]?.length, equals(1));
      expect(effectiveInfo.episodesBySeason[1]?.first.id, equals(9901));
      expect(effectiveInfo.episodesBySeason[1]?.first.containerExtension, equals('mkv'));

      // Valida que o SmartSourceResolver consegue gerar candidatos para o episódio sintetizado
      final catalog = XtreamCatalogService(
        serverUrl: 'http://test.iptv:8080',
        username: 'usr',
        password: 'pwd',
      );
      final urls = SmartSourceResolver.instance.generateCandidateUrls(
        catalogService: catalog,
        episode: targetEpisode,
      );

      expect(urls.isNotEmpty, isTrue);
      expect(urls.any((u) => u.contains('/series/usr/pwd/9901.mkv')), isTrue);
      expect(urls.any((u) => u.contains('/series/usr/pwd/9901.mp4')), isTrue);
      expect(urls.any((u) => u.contains('/series/usr/pwd/9901.ts')), isTrue);
    });

    test('2.4 Recupera episódio por fallback de temporada e número quando ID foi reindexado no servidor', () {
      final item = ContinueWatchingItem(
        streamId: 5555, // Antigo ID salvo
        seriesId: 10,
        type: ContinueWatchingType.series,
        title: 'Dark',
        subtitle: 'T1:E2 • Mentiras',
        seasonNumber: 1,
        episodeNum: 2,
        position: const Duration(minutes: 30),
        duration: const Duration(minutes: 52),
        updatedAt: DateTime.now(),
      );

      // Servidor reindexou o ID para 7777, mas season e episode_num coincidem
      final info = XtreamSeriesInfo(
        name: 'Dark',
        seasons: [
          const XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1'),
        ],
        episodesBySeason: {
          1: [
            const XtreamSeriesEpisode(id: 7776, episodeNum: 1, seasonNumber: 1, title: 'Segredos'),
            const XtreamSeriesEpisode(id: 7777, episodeNum: 2, seasonNumber: 1, title: 'Mentiras'),
          ],
        },
      );

      var ep = info.findEpisodeById(item.streamId);
      expect(ep, isNull, reason: 'ID 5555 não existe mais no servidor');

      // Fallback por temporada e número
      if (ep == null && item.seasonNumber != null && item.episodeNum != null) {
        ep = info.findEpisodeBySeasonAndNum(item.seasonNumber!, item.episodeNum!);
      }

      expect(ep, isNotNull);
      expect(ep!.id, equals(7777), reason: 'Episódio recuperado com sucesso pelo par temporada/número');
      expect(ep.title, equals('Mentiras'));
    });
  });
}
