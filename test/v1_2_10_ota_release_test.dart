import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/services/ota_update_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceUtils.setMockAppVersion(versionCode: 13, versionName: '1.2.10');
  });

  tearDown(() {
    DeviceUtils.setMockAppVersion(versionCode: 13, versionName: '1.2.10');
  });

  group('JessFlix v1.2.10+13 — Verificações de Versão e Atualização OTA', () {
    test('DeviceUtils e OtaUpdateService refletem a nova versão instalada (1.2.10+13)', () {
      expect(DeviceUtils.installedVersionCode, equals(13));
      expect(DeviceUtils.installedVersionName, equals('1.2.10'));
      expect(OtaUpdateService.currentVersionCode, equals(13));
      expect(OtaUpdateService.currentVersionName, equals('1.2.10'));
    });

    test('Dispositivo com v1.2.9+12 detecta disponibilidade da atualização v1.2.10+13 via OTA', () async {
      // Simula dispositivo rodando a versão anterior v1.2.9+12
      DeviceUtils.setMockAppVersion(versionCode: 12, versionName: '1.2.9');

      final mockClient = MockClient((request) async {
        final manifestData = {
          'version': '1.2.10',
          'versionCode': 13,
          'minSupportedVersion': '1.0.0',
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.2.10/JessFlix-v1.2.10.apk',
          'fileSize': 60000000,
          'sha256': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
          'releaseNotes': 'Correção P0.3 de reprodução de séries e laboratório WebView PoC.',
          'publishedAt': '2026-11-11T16:00:00.000Z',
          'mandatory': false,
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isTrue, reason: 'versionCode 13 deve ser reconhecido como atualização para v1.2.9+12');
      expect(result.manifest?.version, equals('1.2.10'));
      expect(result.manifest?.versionCode, equals(13));
      expect(result.manifest?.apkUrl, contains('v1.2.10'));
    });

    test('Dispositivo atualizado para v1.2.10+13 reporta estar atualizado e não entra em loop', () async {
      DeviceUtils.setMockAppVersion(versionCode: 13, versionName: '1.2.10');

      final mockClient = MockClient((request) async {
        final manifestData = {
          'version': '1.2.10',
          'versionCode': 13,
          'minSupportedVersion': '1.0.0',
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.2.10/JessFlix-v1.2.10.apk',
          'fileSize': 60000000,
          'sha256': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
          'releaseNotes': 'Mesma versão já instalada',
          'publishedAt': '2026-11-11T16:00:00.000Z',
          'mandatory': false,
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isTrue);
      expect(service.status, equals(UpdateStatus.upToDate));
    });
  });
}
