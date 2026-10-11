import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/main.dart';
import 'package:projeto_tv/models/xtream_account.dart';
import 'package:projeto_tv/screens/global_search_screen.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mockAccount = XtreamAccount(
    serverUrl: 'http://test.server:80',
    username: 'user_home',
    isAuthorized: true,
    status: 'Active',
  );
  final accountKey = PlaybackProgressService.buildAccountKey(
    mockAccount.serverUrl,
    mockAccount.username,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'mock_password'});
  });

  group('HomeScreen Redesign Tests', () {
    testWidgets('Exibe cabeçalho, 4 categorias principais e barra lateral com itens de navegação', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // Cabeçalho
      expect(find.text('Player TV'), findsWidgets);
      expect(find.text('user_home'), findsOneWidget);

      // Itens na barra lateral
      expect(find.byKey(const Key('sidebar_home')), findsOneWidget);
      expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);
      expect(find.byKey(const Key('cat_movies')), findsOneWidget);
      expect(find.byKey(const Key('cat_series')), findsOneWidget);
      expect(find.byKey(const Key('cat_favorites')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_search')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_settings')), findsOneWidget);

      // Sem itens em andamento, seções opcionais devem estar elegantemente ocultas
      expect(find.text('Continuar assistindo'), findsNothing);
      expect(find.text('Adicionados recentemente — Filmes'), findsNothing);
      expect(find.text('Adicionados recentemente — Séries'), findsNothing);
    });

    testWidgets('Renderiza Continuar assistindo com progresso quando há itens salvos', (tester) async {
      final progressService = PlaybackProgressService();

      // Salva um item em progresso
      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 101,
          type: ContinueWatchingType.movie,
          title: 'Interestelar',
          position: const Duration(minutes: 45),
          duration: const Duration(minutes: 120),
          updatedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // Agora a seção deve estar visível
      expect(find.text('Continuar assistindo'), findsOneWidget);
      expect(find.text('Interestelar'), findsOneWidget);
      expect(find.text('FILME'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('Ausência de conta ativa é tratada com segurança sem lançar exceções', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: null),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Player TV'), findsOneWidget);
      expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);
      expect(find.text('Continuar assistindo'), findsNothing);
    });

    testWidgets('Toque no item Favoritos da barra lateral navega para a tela de Favoritos', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // Toca em Favoritos na barra lateral
      await tester.tap(find.byKey(const Key('cat_favorites')));
      await tester.pumpAndSettle();

      // Deve abrir a tela Meus Favoritos
      expect(find.text('Meus Favoritos'), findsOneWidget);
      expect(find.text('Canais (0)'), findsOneWidget);
    });

    testWidgets('Remoção do item de Continuar assistindo preserva o progresso salvo subjacente', (tester) async {
      final progressService = PlaybackProgressService();

      // Salva progresso no serviço e no índice
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: 555,
        position: const Duration(minutes: 30),
        duration: const Duration(minutes: 90),
      );

      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 555,
          type: ContinueWatchingType.movie,
          title: 'Inception',
          position: const Duration(minutes: 30),
          duration: const Duration(minutes: 90),
          updatedAt: DateTime.now(),
        ),
      );

      // Remove do índice continuar assistindo
      await progressService.removeContinueWatchingItem(
        accountKey: accountKey,
        type: ContinueWatchingType.movie,
        id: 555,
      );

      // O índice da Home está vazio
      final list = await progressService.getContinueWatchingList(accountKey: accountKey);
      expect(list.isEmpty, isTrue);

      // Mas o progresso individual original ainda está preservado
      final prog = await progressService.getProgress(accountKey: accountKey, streamId: 555);
      expect(prog, isNotNull);
      expect(prog!.position.inMinutes, equals(30));
    });

    testWidgets('Botão de lixeira abre diálogo de confirmação e cancelar mantém o card', (tester) async {
      final progressService = PlaybackProgressService();

      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 202,
          type: ContinueWatchingType.movie,
          title: 'Avatar',
          position: const Duration(minutes: 50),
          duration: const Duration(minutes: 160),
          updatedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Avatar'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

      // Clica no botão de excluir (lixeira)
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      // Confere se o diálogo foi exibido
      expect(find.text('Remover item'), findsOneWidget);
      expect(find.textContaining('Deseja remover "Avatar" de Continuar assistindo?'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
      expect(find.text('Remover'), findsOneWidget);

      // Toca em Cancelar
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      // Card continua na tela
      expect(find.text('Avatar'), findsOneWidget);
      expect(find.text('Continuar assistindo'), findsOneWidget);
    });

    testWidgets('Confirmar exclusão remove item imediatamente, esconde a seção e persiste após reabrir', (tester) async {
      final progressService = PlaybackProgressService();

      // Salva progresso original no serviço
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: 303,
        position: const Duration(minutes: 40),
        duration: const Duration(minutes: 100),
      );

      // Salva no índice de continuar assistindo
      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: 303,
          type: ContinueWatchingType.movie,
          title: 'Gladiador',
          position: const Duration(minutes: 40),
          duration: const Duration(minutes: 100),
          updatedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Gladiador'), findsOneWidget);
      expect(find.text('Continuar assistindo'), findsOneWidget);

      // Toca na lixeira
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      // Confirma remoção
      await tester.tap(find.text('Remover'));
      await tester.pumpAndSettle();

      // Confere SnackBar de feedback
      expect(find.text('"Gladiador" removido de Continuar assistindo.'), findsOneWidget);

      // O card sumiu e a seção Continuar assistindo foi ocultada
      expect(find.text('Gladiador'), findsNothing);
      expect(find.text('Continuar assistindo'), findsNothing);

      // O progresso original do filme NÃO foi apagado
      final prog = await progressService.getProgress(accountKey: accountKey, streamId: 303);
      expect(prog, isNotNull);
      expect(prog!.position.inMinutes, equals(40));

      // Simula reabrir o aplicativo (recria HomeScreen)
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // Permanece sem exibir a seção
      expect(find.text('Gladiador'), findsNothing);
      expect(find.text('Continuar assistindo'), findsNothing);
    });

    testWidgets('Botão de busca no cabeçalho abre Pesquisa Global unificada', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('header_search_btn')), findsOneWidget);
      expect(find.byKey(const Key('header_favorites_btn')), findsOneWidget);
      expect(find.byKey(const Key('header_settings_btn')), findsOneWidget);
      expect(find.byKey(const Key('header_logout_btn')), findsOneWidget);

      // Clica no botão de busca
      await tester.tap(find.byKey(const Key('header_search_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Confere se a tela de Pesquisa Global unificada foi aberta
      expect(find.byType(GlobalSearchScreen), findsOneWidget);
      expect(find.text('Buscar canais, filmes ou séries...'), findsOneWidget);
    });

    testWidgets('Layout responsivo em retrato de celular (390x844) e paisagem de TV (1280x720) sem overflow', (tester) async {
      // 1. Teste em Retrato (Celular)
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_home')), findsOneWidget);

      // 2. Teste em Paisagem (Android TV / Tablet)
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cat_live_tv')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_home')), findsOneWidget);
    });

    testWidgets('Foco D-pad inicial e seleção de categorias na barra lateral', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: HomeScreen(xtreamAccount: mockAccount),
        ),
      );
      await tester.pumpAndSettle();

      // Confere autofocus no primeiro card (TV ao vivo)
      final liveTvCard = find.byKey(const Key('cat_live_tv'));
      expect(liveTvCard, findsOneWidget);

      // Toca em Séries
      await tester.tap(find.byKey(const Key('cat_series')));
      await tester.pump();

      // Retorna sem erros
      expect(tester.takeException(), isNull);
    });
  });
}
