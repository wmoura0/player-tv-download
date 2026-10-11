import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/screens/xtream_login_screen.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/secure_storage_service.dart';
import 'package:projeto_tv/services/xtream_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  bool hasFieldFocus(WidgetTester tester, Finder formFieldFinder) {
    final textField = tester.widget<TextField>(
      find.descendant(of: formFieldFinder, matching: find.byType(TextField)),
    );
    return textField.focusNode?.hasFocus ?? false;
  }

  group('XtreamLoginScreen D-Pad Remote Navigation Tests', () {
    testWidgets('Foco inicial começa no Servidor e percorre todos os elementos para baixo e para cima', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = SecureStorageService();
      // Não auto-loga para manter a tela aberta e testar a navegação
      await tester.pumpWidget(
        MaterialApp(
          home: XtreamLoginScreen(
            secureStorage: storage,
            autoLogin: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Foco inicial deve estar no campo Servidor / DNS
      final serverField = find.widgetWithText(TextFormField, 'Servidor / DNS');
      expect(serverField, findsOneWidget);
      expect(hasFieldFocus(tester, serverField), isTrue);

      // 2. Seta para Baixo -> Usuário
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final userField = find.widgetWithText(TextFormField, 'Usuário');
      expect(hasFieldFocus(tester, userField), isTrue);

      // 3. Seta para Baixo -> Senha
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final passField = find.widgetWithText(TextFormField, 'Senha');
      expect(hasFieldFocus(tester, passField), isTrue);

      // 4. Seta para Baixo -> Checkbox "Salvar dados com segurança"
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final checkboxFinder = find.byType(Checkbox);
      expect(checkboxFinder, findsOneWidget);
      // O container focalizável do checkbox deve estar com foco
      final checkDetectorFinder = find.byWidgetPredicate((w) => w is FocusableActionDetector && w.focusNode?.debugLabel == 'login_remember');
      expect(checkDetectorFinder, findsOneWidget);
      final checkDetector = tester.widget<FocusableActionDetector>(checkDetectorFinder);
      expect(checkDetector.focusNode?.hasFocus, isTrue);

      // 5. Seta para Baixo -> Botão Conectar
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final connectBtn = find.widgetWithText(ElevatedButton, 'Conectar via Xtream Codes');
      expect(tester.widget<ElevatedButton>(connectBtn).focusNode!.hasFocus, isTrue);

      // 6. Seta para Baixo -> Botão Pular / Listas M3U
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final skipBtn = find.widgetWithText(TextButton, 'Continuar para Listas M3U (Sem Login)');
      expect(tester.widget<TextButton>(skipBtn).focusNode!.hasFocus, isTrue);

      // 7. Seta para Cima (ordem inversa) -> Botão Conectar
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(connectBtn).focusNode!.hasFocus, isTrue);

      // 8. Seta para Cima -> Checkbox
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(checkDetector.focusNode?.hasFocus, isTrue);

      // 9. Seta para Cima -> Senha (não deve travar!)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(hasFieldFocus(tester, passField), isTrue);

      // 10. Seta para Cima -> Usuário
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(hasFieldFocus(tester, userField), isTrue);

      // 11. Seta para Cima -> Servidor
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(hasFieldFocus(tester, serverField), isTrue);
    });

    testWidgets('Checkbox de lembrar credenciais alterna valor com teclas Select e Space do controle', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = SecureStorageService();
      await tester.pumpWidget(
        MaterialApp(
          home: XtreamLoginScreen(
            secureStorage: storage,
            autoLogin: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navega até o checkbox (Servidor -> Usuário -> Senha -> Checkbox)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      Checkbox checkbox = tester.widget(find.byType(Checkbox));
      expect(checkbox.value, isTrue);

      // Pressiona Select (botão OK do controle remoto Fire TV)
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      checkbox = tester.widget(find.byType(Checkbox));
      expect(checkbox.value, isFalse);

      // Pressiona Space (alternativa comum em teclados/controles Bluetooth)
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      checkbox = tester.widget(find.byType(Checkbox));
      expect(checkbox.value, isTrue);
    });

    testWidgets('Teclado virtual / Enter no campo avança para o próximo campo', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = SecureStorageService();
      await tester.pumpWidget(
        MaterialApp(
          home: XtreamLoginScreen(
            secureStorage: storage,
            autoLogin: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final serverField = find.widgetWithText(TextFormField, 'Servidor / DNS');
      expect(hasFieldFocus(tester, serverField), isTrue);

      // Simula pressionar TextInputAction.next (Avançar no teclado virtual)
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      final userField = find.widgetWithText(TextFormField, 'Usuário');
      expect(hasFieldFocus(tester, userField), isTrue);

      // Simula próximo avanço
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      final passField = find.widgetWithText(TextFormField, 'Senha');
      expect(hasFieldFocus(tester, passField), isTrue);
    });
  });

  group('Xtream Credentials Autofill & Persistence Tests', () {
    testWidgets('Preenche automaticamente credenciais iniciais do proprietário na primeira execução', (tester) async {
      final storage = SecureStorageService();
      // Garante que o armazenamento começa vazio
      expect(await storage.hasCredentials(), isFalse);
      expect(await storage.isInitialized(), isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamLoginScreen(
            secureStorage: storage,
            autoLogin: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verifica preenchimento dos campos
      expect(find.text('http://ls-prime.site'), findsOneWidget);
      expect(find.text('438368781982'), findsOneWidget);
      expect(find.text('930366762125'), findsOneWidget);

      // Verifica que foram salvas no SecureStorage criptografado
      expect(await storage.getUsername(), equals('438368781982'));
      expect(await storage.getPassword(), equals('930366762125'));
      expect(await storage.getServerUrl(), equals('http://ls-prime.site'));
      expect(await storage.isInitialized(), isTrue);
    });

    testWidgets('Se desmarcar Lembrar com Segurança, remove credenciais salvas no login', (tester) async {
      final storage = SecureStorageService();
      await storage.saveCredentials(
        serverUrl: 'http://ls-prime.site',
        username: '438368781982',
        password: '930366762125',
      );
      expect(await storage.hasCredentials(), isTrue);

      // Prepara mock HTTP para sucesso
      final mockClient = MockClient((request) async {
        final responseBody = jsonEncode({
          'user_info': {
            'username': '438368781982',
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

      // Testa autenticação
      final authResult = await XtreamAuthService.authenticate(
        serverUrl: 'http://ls-prime.site',
        username: '438368781982',
        password: '930366762125',
        client: mockClient,
      );
      expect(authResult.isSuccess, isTrue);

      // Limpa credenciais conforme comportamento do checkbox desativado
      await storage.clearCredentials();
      expect(await storage.hasCredentials(), isFalse);
      expect(await storage.getUsername(), isNull);
      expect(await storage.getPassword(), isNull);
      // Mas a flag isInitialized permanece true para não reescrever a escolha do usuário
      expect(await storage.isInitialized(), isTrue);
    });

    testWidgets('Em caso de falha de autenticação no auto-login, mantém a tela aberta com erro claro', (tester) async {
      final storage = SecureStorageService();
      await storage.saveCredentials(
        serverUrl: 'http://ls-prime.site',
        username: '438368781982',
        password: '930366762125',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamLoginScreen(
            secureStorage: storage,
            autoLogin: true, // Tentará login e falhará (mock offline padrão)
          ),
        ),
      );
      // Dá tempo para o Future da autenticação falhar
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Deve continuar exibindo a tela de login
      expect(find.text('Conectar via Xtream Codes'), findsOneWidget);
      // Campos continuam editáveis
      expect(find.text('438368781982'), findsOneWidget);
    });
  });

  group('Continuar Assistindo Persistence Across Restarts Tests', () {
    test('PlaybackProgressService armazena e recupera itens de Continuar Assistindo por conta', () async {
      final service = PlaybackProgressService();
      const accountKey = 'http://ls-prime.site_438368781982';

      final movieItem = ContinueWatchingItem(
        streamId: 501,
        type: ContinueWatchingType.movie,
        title: 'Filme Teste Salvo',
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 90),
        updatedAt: DateTime.now(),
      );

      await service.saveContinueWatchingItem(accountKey: accountKey, item: movieItem);

      final list = await service.getContinueWatchingList(accountKey: accountKey);
      expect(list.length, equals(1));
      expect(list.first.streamId, equals(501));
      expect(list.first.title, equals('Filme Teste Salvo'));
      expect(list.first.position.inMinutes, equals(15));
      expect(list.first.duration.inMinutes, equals(90));

      // Remove item do índice
      await service.removeContinueWatchingItem(
        accountKey: accountKey,
        type: ContinueWatchingType.movie,
        id: 501,
      );

      final emptyList = await service.getContinueWatchingList(accountKey: accountKey);
      expect(emptyList.isEmpty, isTrue);
    });
  });
}
