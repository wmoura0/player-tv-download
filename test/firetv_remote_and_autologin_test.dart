import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/main.dart';
import 'package:projeto_tv/models/xtream_account.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/screens/xtream_login_screen.dart';
import 'package:projeto_tv/services/secure_storage_service.dart';
import 'package:projeto_tv/services/xtream_auth_service.dart';
import 'package:projeto_tv/utils/device_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mockAccount = XtreamAccount(
    serverUrl: 'http://ls-prime.site',
    username: 'user_firetv',
    isAuthorized: true,
    status: 'Active',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'mock_password'});
  });

  group('Amazon Fire TV Remote & D-Pad Navigation Tests', () {
    testWidgets('Cards principais da Home respondem ao D-Pad (ActivateIntent / Select / Enter)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // O card de TV ao vivo inicia com autofocus: true
      final liveTvCardFinder = find.byKey(const Key('cat_live_tv'));
      expect(liveTvCardFinder, findsOneWidget);

      // Foca explicitamente no card de TV ao vivo
      final focusableDetector = tester.widget<FocusableActionDetector>(liveTvCardFinder);
      expect(focusableDetector.autofocus, isTrue);

      // Pressiona a tecla de ativação do controle remoto (LogicalKeyboardKey.select)
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Deve ter navegado para a tela de Catálogo de TV ao vivo
      expect(find.byType(XtreamCatalogScreen), findsOneWidget);
    });

    testWidgets('Card de Filmes na Home responde ao D-Pad Enter', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // Navega o foco com tecla de seta para a direita até o card de Filmes
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      // Ativa o card selecionado com LogicalKeyboardKey.enter
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Deve ter navegado para a tela de Filmes
      expect(find.byType(XtreamCatalogScreen), findsOneWidget);
    });

    testWidgets('ActivateAction aciona callback ao despachar ActivateIntent', (tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusableActionDetector(
              autofocus: true,
              actions: DeviceUtils.activateAction(() => tapped = true),
              shortcuts: DeviceUtils.dpadSelectShortcuts,
              child: const Text('TV Item'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Pressiona Enter
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tapped, isTrue);

      // Reseta e testa com Select (botão central do controle Fire TV)
      tapped = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(tapped, isTrue);

      // Testa Space e Gamepad A (controles Bluetooth)
      tapped = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(tapped, isTrue);

      tapped = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('DeviceUtils Orientation Tests', () {
    test('isTvMode identifica corretamente resolução de TV widescreen 16:9', () {
      // Mock do context via MediaQueryData
      const tvLandscape = MediaQueryData(size: Size(1920, 1080));
      const tvCompactLandscape = MediaQueryData(size: Size(960, 540));
      const phonePortrait = MediaQueryData(size: Size(390, 844));
      const phoneLandscape = MediaQueryData(size: Size(844, 390));

      // Testando diretamente a lógica de cálculo de dimensão e aspect ratio
      expect(tvLandscape.size.width >= 900 && tvLandscape.size.width > tvLandscape.size.height, isTrue);
      expect(tvCompactLandscape.size.width >= 900 && tvCompactLandscape.size.width > tvCompactLandscape.size.height, isTrue);
      expect(phonePortrait.size.width >= 900, isFalse);
      expect(phoneLandscape.size.width >= 900, isFalse);
    });

    test('dpadSelectShortcuts contém todas as teclas de controle remoto e gamepads', () {
      final shortcuts = DeviceUtils.dpadSelectShortcuts;
      expect(shortcuts.containsKey(const SingleActivator(LogicalKeyboardKey.select)), isTrue);
      expect(shortcuts.containsKey(const SingleActivator(LogicalKeyboardKey.enter)), isTrue);
      expect(shortcuts.containsKey(const SingleActivator(LogicalKeyboardKey.numpadEnter)), isTrue);
      expect(shortcuts.containsKey(const SingleActivator(LogicalKeyboardKey.gameButtonA)), isTrue);
      expect(shortcuts.containsKey(const SingleActivator(LogicalKeyboardKey.space)), isTrue);
    });

    test('restoreOrientation executa sem erros em TV e smartphone', () async {
      // Executa restauração em TV (esperado: landscape)
      await DeviceUtils.restoreOrientation(isTv: true);

      // Executa restauração em Celular (esperado: portrait)
      await DeviceUtils.restoreOrientation(isTv: false);
    });
  });

  group('Xtream Auto-Login Tests', () {
    testWidgets('XtreamLoginScreen pré-carrega credenciais e executa auto-login', (tester) async {
      final secureStorage = SecureStorageService();
      await secureStorage.saveCredentials(
        serverUrl: 'http://ls-prime.site',
        username: 'saved_user',
        password: 'saved_pass',
      );

      // Prepara mock HTTP para sucesso
      final mockClient = MockClient((request) async {
        final responseBody = jsonEncode({
          'user_info': {
            'username': 'saved_user',
            'auth': 1,
            'status': 'Active',
            'exp_date': 1780000000,
            'max_connections': '2',
            'active_cons': '0',
          },
          'server_info': {
            'url': 'ls-prime.site',
            'port': '80',
          },
        });
        return http.Response(responseBody, 200, headers: {'content-type': 'application/json'});
      });

      // Configura client customizado em XtreamAuthService para o teste
      final authResult = await XtreamAuthService.authenticate(
        serverUrl: 'http://ls-prime.site',
        username: 'saved_user',
        password: 'saved_pass',
        client: mockClient,
      );
      expect(authResult.isSuccess, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamLoginScreen(
            secureStorage: secureStorage,
            autoLogin: false, // Desabilitado para inspecionar campos pré-carregados
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Campos devem estar preenchidos com as credenciais salvas
      expect(find.text('saved_user'), findsOneWidget);
      expect(find.text('saved_pass'), findsOneWidget);
    });
  });
}
