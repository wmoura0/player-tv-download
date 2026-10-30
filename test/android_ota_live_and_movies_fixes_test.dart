import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/update_manifest.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/ota_update_service.dart';
import 'package:projeto_tv/services/player_stability_manager.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/widgets/ota_update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class _FakeVideoPlayerController extends VideoPlayerController {
  _FakeVideoPlayerController(VideoPlayerValue initialValue)
      : super.networkUrl(Uri.parse('https://example.com/live.ts')) {
    value = initialValue;
  }

  int playCallCount = 0;

  @override
  Future<void> play() async {
    playCallCount++;
    value = value.copyWith(isPlaying: true, isBuffering: false);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('android_fixes_test_');
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.loadSettings();
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('OTA Update - Verificação Rápida, Cache-Busting e Auto-Check', () {
    test('checkForUpdates inclui timestamp _t e headers de cache-busting', () async {
      String? capturedUrl;
      Map<String, String>? capturedHeaders;

      final mockClient = MockClient((request) async {
        capturedUrl = request.url.toString();
        capturedHeaders = request.headers;

        final manifestData = {
          'version': '1.3.0',
          'versionCode': 5,
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.3.0/app.apk',
          'fileSize': 50000000,
          'sha256': 'a' * 64,
          'releaseNotes': 'Melhorias de estabilidade e catálogo.',
        };
        return http.Response(jsonEncode(manifestData), 200, headers: {'content-type': 'application/json'});
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(customUrl: 'https://example.com/updates/latest.json');

      expect(result.hasUpdate, isTrue);
      expect(capturedUrl, contains('_t='));
      expect(capturedHeaders?['Cache-Control'], equals('no-cache, no-store, must-revalidate'));
      expect(capturedHeaders?['Pragma'], equals('no-cache'));
    });

    testWidgets('OtaUpdateDialog renderiza informações da nova versão e botões de ação', (tester) async {
      final manifest = UpdateManifest(
        version: '1.3.0',
        versionCode: 5,
        apkUrl: 'https://github.com/wmoura0/player-tv-download/releases/download/v1.3.0/app.apk',
        fileSize: 45000000,
        sha256: 'a' * 64,
        releaseNotes: '1. Atualização rápida sem cache\n2. Correção de travadas na TV',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OtaUpdateDialog(manifest: manifest),
          ),
        ),
      );

      expect(find.text('Atualização Disponível'), findsOneWidget);
      expect(find.text('Versão 1.3.0 (Build 5)'), findsOneWidget);
      expect(find.text('Atualizar Agora'), findsOneWidget);
      expect(find.text('Lembrar Mais Tarde'), findsOneWidget);
      expect(find.textContaining('Correção de travadas na TV'), findsOneWidget);
    });

    testWidgets('checkSilentlyOnStartup respeita intervalo seguro e não dispara se verificado recentemente', (tester) async {
      int requestCount = 0;
      final mockClient = MockClient((request) async {
        requestCount++;
        final manifestData = {
          'version': '1.3.0',
          'versionCode': 5,
          'apkUrl': 'https://github.com/wmoura0/player-tv-download/releases/download/v1.3.0/app.apk',
          'fileSize': 45000000,
          'sha256': 'a' * 64,
          'releaseNotes': 'Notas de teste',
        };
        return http.Response(jsonEncode(manifestData), 200);
      });

      final service = OtaUpdateService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  await service.checkSilentlyOnStartup(context);
                },
                child: const Text('Check'),
              );
            },
          ),
        ),
      );

      // Primeira execução: executa checagem remota e abre o modal
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(requestCount, equals(1));
      expect(find.text('Lembrar Mais Tarde'), findsOneWidget);

      // Fecha o diálogo para simular a dispensa pelo usuário
      await tester.tap(find.text('Lembrar Mais Tarde'));
      await tester.pumpAndSettle();

      // Segunda execução imediata: é bloqueada pelo intervalo seguro (throttle de 2h)
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(requestCount, equals(1), reason: 'Não deve disparar requisições repetitivas no servidor');
    });
  });

  group('TV ao Vivo - Estabilidade do Player e Prevenção de Travadas', () {
    test('Não invoca controller.play() repetitivamente em loops curtos de micro-buffering', () async {
      final fakeController = _FakeVideoPlayerController(
        const VideoPlayerValue(
          duration: Duration.zero,
          position: Duration.zero,
          isPlaying: false,
          isBuffering: false,
          isInitialized: true,
        ),
      );

      final manager = PlayerStabilityManager(
        isLiveStream: true,
        isMpegTsStream: false,
        stallDetectionInterval: const Duration(milliseconds: 50),
        maxStallDuration: const Duration(seconds: 4),
      );

      manager.startStallMonitoring(fakeController);

      // Espera 300ms (abaixo do limiar de jitter de 1500ms)
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fakeController.playCallCount, equals(0),
          reason: 'Micro-hesitações iniciais não devem disparar soft play forçado');

      manager.dispose();
    });

    test('isMpegTsUrl detecta corretamente endpoints Xtream e fluxos .ts', () {
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.tv:8080/live/user/pass/12345.ts'), isTrue);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.tv:8080/live/user/pass/12345'), isTrue);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.tv:8080/live/user/pass/12345.m3u8'), isFalse);
      expect(PlayerStabilityManager.isMpegTsUrl('http://server.tv:8080/movie/user/pass/12345.mp4'), isFalse);
      expect(PlayerStabilityManager.isMpegTsUrl(null), isFalse);
      expect(PlayerStabilityManager.isMpegTsUrl(''), isFalse);
    });
  });

  group('Aba Filmes - Seleção Automática de Categoria e Proteção contra Adulto', () {
    test('isAdultCategory identifica corretamente nomes de categorias adultas', () {
      expect(XtreamCatalogScreen.isAdultCategory('Filmes Adultos'), isTrue);
      expect(XtreamCatalogScreen.isAdultCategory('ADULTOS +18'), isTrue);
      expect(XtreamCatalogScreen.isAdultCategory('XXX Premium'), isTrue);
      expect(XtreamCatalogScreen.isAdultCategory('Canais 18+'), isTrue);
      expect(XtreamCatalogScreen.isAdultCategory('Playboy TV'), isTrue);
      expect(XtreamCatalogScreen.isAdultCategory('Sensual & Erótico'), isTrue);
      expect(XtreamCatalogScreen.isAdultCategory('Privé Cinema'), isTrue);

      // Categorias legítimas não devem ser marcadas como adultas
      expect(XtreamCatalogScreen.isAdultCategory('Lançamentos 2026'), isFalse);
      expect(XtreamCatalogScreen.isAdultCategory('Ação e Aventura'), isFalse);
      expect(XtreamCatalogScreen.isAdultCategory('Comédia Nacional'), isFalse);
      expect(XtreamCatalogScreen.isAdultCategory('Ficção Científica'), isFalse);
      expect(XtreamCatalogScreen.isAdultCategory('Sexta-feira 13 Coleção'), isFalse);
    });

    test('determineInitialVodCategory prioriza categoria de Lançamentos quando disponível', () {
      final categories = [
        const XtreamCategory(id: '1', name: 'Comédia'),
        const XtreamCategory(id: '2', name: 'Lançamentos 2026'),
        const XtreamCategory(id: '3', name: 'Ação'),
        const XtreamCategory(id: '4', name: 'Adulto +18'),
      ];

      final selectedId = XtreamCatalogScreen.determineInitialVodCategory(categories);
      expect(selectedId, equals('2'), reason: 'Deve priorizar a categoria de Lançamentos');
    });

    test('determineInitialVodCategory prioriza Recém-adicionados quando disponível', () {
      final categories = [
        const XtreamCategory(id: '10', name: 'Documentários'),
        const XtreamCategory(id: '20', name: 'Filmes Recém-adicionados'),
        const XtreamCategory(id: '30', name: 'Terror'),
      ];

      final selectedId = XtreamCatalogScreen.determineInitialVodCategory(categories);
      expect(selectedId, equals('20'));
    });

    test('determineInitialVodCategory escolhe primeira categoria segura e NUNCA adulta nem Todas', () {
      final categories = [
        const XtreamCategory(id: '99', name: 'Adulto 18+'),
        const XtreamCategory(id: '100', name: 'XXX Cinema'),
        const XtreamCategory(id: '15', name: 'Ação e Aventura'),
        const XtreamCategory(id: '25', name: 'Drama'),
      ];

      final selectedId = XtreamCatalogScreen.determineInitialVodCategory(categories);
      expect(selectedId, equals('15'), reason: 'Deve ignorar adultas e selecionar a primeira segura');
      expect(selectedId, isNot(equals('all')));
      expect(selectedId, isNot(equals('99')));
      expect(selectedId, isNot(equals('100')));
    });

    testWidgets('Aba Filmes: ao visualizar Todas, filtra filmes de categorias adultas', (tester) async {
      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_vod_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '10', 'category_name': 'Lançamentos 2026'},
              {'category_id': '20', 'category_name': 'Filmes Adultos +18'},
            ]),
            200,
          );
        }
        if (action == 'get_vod_streams') {
          final allStreams = [
            {'stream_id': 101, 'name': 'Avatar 3', 'category_id': '10'},
            {'stream_id': 999, 'name': 'Título Proibido 18+', 'category_id': '20'},
          ];
          return http.Response(jsonEncode(allStreams), 200);
        }
        return http.Response('[]', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
        cacheDirectoryOverride: tempDir,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.movies,
            catalogService: service,
          ),
        ),
      );

      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }

      // 1. Ao abrir, seleciona Lançamentos 2026 automaticamente (não Todas, não Adulto)
      expect(find.text('Avatar 3'), findsOneWidget);
      expect(find.text('Título Proibido 18+'), findsNothing);

      // 2. Ao navegar para Todas, o filtro protetor oculta títulos de categorias adultas
      await tester.tap(find.text('Todas'));
      await tester.pump();
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();

      expect(find.text('Avatar 3'), findsOneWidget);
      expect(find.text('Título Proibido 18+'), findsNothing,
          reason: 'Conteúdos da categoria adulta não devem aparecer no catálogo geral Todas');
    });
  });
}
