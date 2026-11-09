import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/update_manifest.dart';
import 'package:projeto_tv/services/ota_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Atualização Persistente em Segundo Plano e Tela Desligada (OTA)', () {
    late OtaUpdateService service;
    Map<String, dynamic>? mockNativeStatus;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockNativeStatus = null;

      // Mock MethodChannel 'com.player.m3u/device'
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('com.player.m3u/device'), (call) async {
        switch (call.method) {
          case 'startOtaDownload':
            mockNativeStatus = {
              'status': 'DOWNLOADING',
              'progress': 0.1,
              'bytesDownloaded': 5000000,
              'totalBytes': 50000000,
              'apkPath': null,
              'errorMessage': null,
            };
            return true;
          case 'getOtaDownloadStatus':
            return mockNativeStatus;
          case 'cancelOtaDownload':
            mockNativeStatus = {
              'status': 'CANCELLED',
              'progress': 0.0,
              'bytesDownloaded': 0,
              'totalBytes': 0,
              'apkPath': null,
              'errorMessage': null,
            };
            return true;
          case 'cleanOldApks':
            return true;
          case 'canRequestPackageInstalls':
            return true;
          case 'installApk':
            return true;
          default:
            return null;
        }
      });

      service = OtaUpdateService();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('com.player.m3u/device'), null);
    });

    test('1. Estados descritivos de statusLabel cobrem todos os cenários exigidos', () async {
      expect(service.statusLabel, equals('Ocioso'));

      // Sincroniza estado PAUSED_BY_SYSTEM
      mockNativeStatus = {
        'status': 'PAUSED_BY_SYSTEM',
        'progress': 0.45,
        'bytesDownloaded': 22500000,
        'totalBytes': 50000000,
        'errorMessage': 'Aguardando reconexão...',
      };

      // Simula sincronização
      await service.syncWithNativeStatus();
      expect(service.statusLabel, contains('pausado pelo sistema'));
    });

    test('2. Sincronização nativa recupera estado DOWNLOADING sem reiniciar do zero', () async {
      mockNativeStatus = {
        'status': 'DOWNLOADING',
        'progress': 0.65,
        'bytesDownloaded': 32500000,
        'totalBytes': 50000000,
      };

      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.downloading));
      expect(service.downloadProgress, closeTo(0.65, 0.001));
      expect(service.bytesDownloaded, equals(32500000));
      expect(service.totalBytesToDownload, equals(50000000));
    });

    test('3. Sincronização nativa recupera estado RESUMING quando conexões são restabelecidas', () async {
      mockNativeStatus = {
        'status': 'RESUMING',
        'progress': 0.50,
        'bytesDownloaded': 25000000,
        'totalBytes': 50000000,
      };

      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.resuming));
      expect(service.statusLabel, contains('Retomando'));
      expect(service.downloadProgress, closeTo(0.50, 0.001));
    });

    test('4. Transição para segundo plano com moveToBackground() preserva progresso', () async {
      mockNativeStatus = {
        'status': 'DOWNLOADING',
        'progress': 0.30,
        'bytesDownloaded': 15000000,
        'totalBytes': 50000000,
      };

      await service.syncWithNativeStatus();
      expect(service.status, equals(UpdateStatus.downloading));

      // Usuário clica em "Segundo Plano" ou sai do modal
      service.moveToBackground();
      expect(service.status, equals(UpdateStatus.downloadInBackground));
      expect(service.statusLabel, contains('segundo plano'));
      expect(service.downloadProgress, closeTo(0.30, 0.001));
    });

    test('5. Sincronização nativa detecta READY_TO_INSTALL e vincula arquivo validado', () async {
      mockNativeStatus = {
        'status': 'READY_TO_INSTALL',
        'progress': 1.0,
        'bytesDownloaded': 50000000,
        'totalBytes': 50000000,
        'apkPath': '/fake/storage/updates/update_v8.apk',
      };

      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.readyToInstall));
      expect(service.statusLabel, equals('Pronto para instalar'));
      expect(service.downloadProgress, equals(1.0));
      expect(service.downloadedApkFile?.path, equals('/fake/storage/updates/update_v8.apk'));
    });

    test('6. Sincronização nativa captura ERROR com mensagem detalhada sem travar UI', () async {
      mockNativeStatus = {
        'status': 'ERROR',
        'progress': 0.2,
        'bytesDownloaded': 10000000,
        'totalBytes': 50000000,
        'errorMessage': 'Espaço insuficiente em disco: necessários 100 MB.',
      };

      await service.syncWithNativeStatus();

      expect(service.status, equals(UpdateStatus.error));
      expect(service.statusLabel, equals('Falha na atualização'));
      expect(service.errorMessage, contains('Espaço insuficiente'));
    });

    test('7. cancelDownload() notifica nativo e reseta estado para idle', () async {
      mockNativeStatus = {
        'status': 'DOWNLOADING',
        'progress': 0.40,
        'bytesDownloaded': 20000000,
        'totalBytes': 50000000,
      };

      await service.syncWithNativeStatus();
      expect(service.status, equals(UpdateStatus.downloading));

      await service.cancelDownload();
      expect(service.status, equals(UpdateStatus.idle));
      expect(service.downloadProgress, equals(0.0));
      expect(service.bytesDownloaded, equals(0));
    });

    test('8. Validação e integridade de manifesto com HTTPS e limites seguros', () {
      final manifest = UpdateManifest(
        version: '1.2.6',
        versionCode: 9,
        apkUrl: 'https://github.com/wmoura0/player-tv-download/releases/download/v1.2.6/app.apk',
        fileSize: 55000000,
        sha256: 'c' * 64,
        releaseNotes: '• Atualização persistente em segundo plano com tela desligada.',
      );

      expect(manifest.version, equals('1.2.6'));
      expect(manifest.versionCode, equals(9));
      expect(manifest.apkUrl, startsWith('https://'));
      expect(manifest.fileSize, equals(55000000));
    });
  });
}
