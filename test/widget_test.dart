import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:projeto_tv/main.dart';
import 'package:projeto_tv/models/xtream_account.dart';
import 'package:projeto_tv/screens/playlists_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
      'Inicia na tela de Login Xtream, permite pular para tela principal e acessar listas M3U',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const PlayerTvApp());
    await tester.pumpAndSettle();

    // 1. Deve exibir a tela de login inicial
    expect(find.text('Player TV'), findsOneWidget);
    expect(find.text('Servidor / DNS'), findsOneWidget);
    expect(find.text('Usuário'), findsOneWidget);
    expect(find.text('Senha'), findsOneWidget);
    expect(find.text('Conectar via Xtream Codes'), findsOneWidget);

    final skipButton = find.text('Continuar para Listas M3U (Sem Login)');
    expect(skipButton, findsOneWidget);

    // 2. Toca em "Continuar para Listas M3U (Sem Login)"
    await tester.ensureVisible(skipButton);
    await tester.pumpAndSettle();
    await tester.tap(skipButton);
    await tester.pumpAndSettle();

    // 3. Deve exibir a tela inicial (HomeScreen) com os cards e a barra inferior
    expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);
    expect(find.byKey(const Key('cat_movies')), findsOneWidget);
    expect(find.byKey(const Key('cat_series')), findsOneWidget);
    expect(find.byKey(const Key('bottom_nav_home')), findsOneWidget);

    // 4. Toca no card "TV ao vivo" no modo sem login para abrir o gerenciador M3U
    await tester.tap(find.byKey(const Key('cat_live_tv')));
    await tester.pumpAndSettle();

    // 5. Deve abrir o Gerenciador de Listas M3U preservado
    expect(find.text('Gerenciador de Listas'), findsOneWidget);
    expect(find.text('Nenhuma lista adicionada'), findsOneWidget);
  });

  testWidgets(
      'Com conta Xtream autenticada, HomeScreen exibe status e cards navegam para catálogos reais',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    const account = XtreamAccount(
      serverUrl: 'http://ls-prime.site',
      username: 'usuarioTeste',
      isAuthorized: true,
      status: 'Active',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: HomeScreen(xtreamAccount: account),
      ),
    );
    await tester.pumpAndSettle();

    // Deve exibir o badge de usuário no topo
    expect(find.text('usuarioTeste'), findsOneWidget);

    // Toca no card TV ao vivo
    await tester.tap(find.byKey(const Key('cat_live_tv')));
    await tester.pump();

    // Deve navegar para o catálogo de TV ao vivo
    expect(find.text('TV ao vivo'), findsWidgets);
  });

  testWidgets(
      'PlaylistsScreen em orientação horizontal de celular (altura 360) não gera overflow no estado vazio',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      const MaterialApp(
        home: PlaylistsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Nenhuma lista adicionada'), findsOneWidget);
    expect(find.text('Adicionar Primeira Lista'), findsOneWidget);
  });
}
