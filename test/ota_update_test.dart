import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/update_manifest.dart';
import 'package:projeto_tv/services/ota_update_service.dart';

void main() {
  group('Manifesto de Atualização OTA (UpdateManifest)', () {
    const validJson = {
      'version': '1.1.0',
      'versionCode': 4,
      'minSupportedVersion': '1.0.0',
      'apkUrl': 'https://raw.githubusercontent.com/wmoura0/player-tv-download/main/releases/PlayerTV-release.apk',
      'fileSize': 52428800,
      'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'releaseNotes': '1. Redesign com paleta oficial.\n2. Atualizador próprio OTA.',
      'publishedAt': '2026-10-25T16:00:00.000Z',
      'mandatory': false,
    };

    test('Desserializa JSON válido com todos os campos preenchidos', () {
      final manifest = UpdateManifest.fromJson(validJson);
      expect(manifest.version, equals('1.1.0'));
      expect(manifest.versionCode, equals(4));
      expect(manifest.minSupportedVersion, equals('1.0.0'));
      expect(manifest.apkUrl, startsWith('https://'));
      expect(manifest.fileSize, equals(52428800));
      expect(manifest.formattedSize, equals('50.0 MB'));
      expect(manifest.sha256, equals('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'));
      expect(manifest.releaseNotes, contains('Redesign'));
      expect(manifest.mandatory, isFalse);
    });

    test('Rejeita URL de APK não-HTTPS por segurança', () {
      final insecureJson = Map<String, dynamic>.from(validJson)
        ..['apkUrl'] = 'http://insecure-server.com/app.apk';
      expect(() => UpdateManifest.fromJson(insecureJson), throwsFormatException);
    });

    test('Rejeita SHA-256 com tamanho ou caracteres inválidos', () {
      final invalidHashJson = Map<String, dynamic>.from(validJson)
        ..['sha256'] = 'invalida-hash-curta';
      expect(() => UpdateManifest.fromJson(invalidHashJson), throwsFormatException);

      final nonHexHashJson = Map<String, dynamic>.from(validJson)
        ..['sha256'] = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
      expect(() => UpdateManifest.fromJson(nonHexHashJson), throwsFormatException);
    });

    test('Rejeita fileSize ou versionCode zerados ou negativos', () {
      final zeroSizeJson = Map<String, dynamic>.from(validJson)..['fileSize'] = 0;
      expect(() => UpdateManifest.fromJson(zeroSizeJson), throwsFormatException);

      final negativeVersionJson = Map<String, dynamic>.from(validJson)..['versionCode'] = -1;
      expect(() => UpdateManifest.fromJson(negativeVersionJson), throwsFormatException);
    });

    test('Serialização e reversibilidade JSON', () {
      final manifest = UpdateManifest.fromJson(validJson);
      final jsonMap = manifest.toJson();
      final roundTrip = UpdateManifest.fromJson(jsonMap);
      expect(roundTrip.version, equals(manifest.version));
      expect(roundTrip.versionCode, equals(manifest.versionCode));
      expect(roundTrip.sha256, equals(manifest.sha256));
    });
  });

  group('Serviço de Atualização OTA (OtaUpdateService)', () {
    test('Detecta nova versão quando versionCode é superior à instalada', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('.json')) {
          final manifestData = {
            'version': '1.0.3',
            'versionCode': 4,
            'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.0.3/app.apk',
            'fileSize': 45000000,
            'sha256': 'a' * 64,
            'releaseNotes': 'Notas de teste',
          };
          return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('Not Found', 404);
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isTrue);
      expect(result.isUpToDate, isFalse);
      expect(result.manifest?.versionCode, equals(4));
    });

    test('Indica que aplicativo está atualizado quando versionCode é igual ou inferior', () async {
      final mockClient = MockClient((request) async {
        final manifestData = {
          'version': '1.0.2',
          'versionCode': OtaUpdateService.currentVersionCode, // Mesma versão instalada
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.0.2/app.apk',
          'fileSize': 45000000,
          'sha256': 'b' * 64,
          'releaseNotes': 'Versão corrente',
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isTrue);
    });

    test('Trata HTTP 404 como canal não publicado ou configurado', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isFalse);
      expect(result.isChannelNotPublished, isTrue);
      expect(service.status, equals(UpdateStatus.channelNotPublished));
      expect(result.errorMessage, contains('ainda não publicado ou configurado'));
    });

    test('Trata erro de servidor HTTP de forma controlada', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/latest.json');

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isFalse);
      expect(result.errorMessage, contains('500'));
    });

    test('Rejeita URL de manifesto insegura (HTTP)', () async {
      final service = OtaUpdateService();
      final result = await service.checkForUpdates(customUrl: 'http://insecure.site/latest.json');

      expect(result.hasUpdate, isFalse);
      expect(result.errorMessage, contains('HTTPS'));
    });
  });
}
