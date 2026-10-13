import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/screens/hidden_categories_screen.dart';
import 'package:projeto_tv/services/hidden_categories_service.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HiddenCategoriesService Tests', () {
    late HiddenCategoriesService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      service = HiddenCategoriesService.forTesting(prefs: prefs);
      service.clearForTesting();
    });

    test('Inicia sem categorias ocultas', () {
      expect(service.getHiddenCategories('scope_1'), isEmpty);
      expect(service.isHidden('scope_1', 'Esportes'), isFalse);
    });

    test('Oculta e desoculta categoria individualmente', () async {
      await service.setHidden('scope_1', 'Esportes', true);
      expect(service.isHidden('scope_1', 'Esportes'), isTrue);
      expect(service.getHiddenCategories('scope_1'), contains('Esportes'));

      await service.toggleHidden('scope_1', 'Esportes');
      expect(service.isHidden('scope_1', 'Esportes'), isFalse);
      expect(service.getHiddenCategories('scope_1'), isEmpty);
    });

    test('Garante isolamento estrito por fonte (scopeKey)', () async {
      await service.setHidden('playlist_m3u_1', 'Notícias', true);
      await service.setHidden('xtream_account_2', 'Filmes 4K', true);

      expect(service.isHidden('playlist_m3u_1', 'Notícias'), isTrue);
      expect(service.isHidden('playlist_m3u_1', 'Filmes 4K'), isFalse);

      expect(service.isHidden('xtream_account_2', 'Filmes 4K'), isTrue);
      expect(service.isHidden('xtream_account_2', 'Notícias'), isFalse);
    });

    test('Restaura todas as categorias da fonte', () async {
      await service.setHidden('scope_1', 'Cat A', true);
      await service.setHidden('scope_1', 'Cat B', true);
      await service.setHidden('scope_1', 'Cat C', true);
      expect(service.getHiddenCategories('scope_1').length, equals(3));

      await service.restoreAll('scope_1');
      expect(service.getHiddenCategories('scope_1'), isEmpty);
      expect(service.isHidden('scope_1', 'Cat A'), isFalse);
    });
  });

  group('HiddenCategoriesScreen Widget Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await HiddenCategoriesService.instance.init(prefs);
      HiddenCategoriesService.instance.clearForTesting();
    });

    testWidgets('Exibe lista de categorias reais e permite busca rápida', (tester) async {
      const items = [
        HiddenCategoryItem(id: '1', name: 'Abertos HD'),
        HiddenCategoryItem(id: '2', name: 'Documentários'),
        HiddenCategoryItem(id: '3', name: 'Esportes Premium'),
      ];

      await tester.pumpWidget(
        const MaterialApp(
          home: HiddenCategoriesScreen(
            scopeKey: 'test_scope',
            sourceTitle: 'Teste Playlist',
            categories: items,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Abertos HD'), findsOneWidget);
      expect(find.text('Documentários'), findsOneWidget);
      expect(find.text('Esportes Premium'), findsOneWidget);

      // Digita no campo de busca
      await tester.enterText(find.byType(TextField), 'Esp');
      await tester.pumpAndSettle();

      expect(find.text('Esportes Premium'), findsOneWidget);
      expect(find.text('Abertos HD'), findsNothing);
      expect(find.text('Documentários'), findsNothing);
    });

    testWidgets('Permite alternar estado visível/oculto de uma categoria', (tester) async {
      const items = [
        HiddenCategoryItem(id: 'cat_news', name: 'Notícias'),
      ];

      await tester.pumpWidget(
        const MaterialApp(
          home: HiddenCategoriesScreen(
            scopeKey: 'test_scope_toggle',
            sourceTitle: 'Teste Toggle',
            categories: items,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Visível'), findsOneWidget);

      // Toca na categoria para alternar
      await tester.tap(find.text('Notícias'));
      await tester.pumpAndSettle();

      expect(find.text('Oculta'), findsOneWidget);
      expect(HiddenCategoriesService.instance.isHidden('test_scope_toggle', 'cat_news'), isTrue);
    });
  });

  group('VOD Continuous Seek Tests', () {
    testWidgets('Toque rápido na seta direita dispara salto curto de 10s', (tester) async {
      int? soughtSeconds;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Filme Teste',
              onSeekRelative: (delta) {
                soughtSeconds = delta;
              },
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Envia KeyDown e KeyUp em rápida sucessão (< 250ms)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(soughtSeconds, equals(10));
    });

    testWidgets('Toque rápido na seta esquerda dispara salto curto de -10s', (tester) async {
      int? soughtSeconds;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Filme Teste',
              onSeekRelative: (delta) {
                soughtSeconds = delta;
              },
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Envia KeyDown e KeyUp em rápida sucessão (< 250ms)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      expect(soughtSeconds, equals(-10));
    });

    testWidgets('Segurar seta direita entra em seek contínuo acelerado e faz seek ao soltar', (tester) async {
      int? soughtSeconds;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Filme Longo',
              onSeekRelative: (delta) {
                soughtSeconds = delta;
              },
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Pressiona KeyDown
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      // Aguarda 1.2 segundos segurando a tecla (passa pelo threshold de 250ms e acelera)
      await tester.pump(const Duration(milliseconds: 1200));

      // Solta a tecla
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      // Deve ter avançado significativamente mais que um toque simples de 10s
      expect(soughtSeconds, isNotNull);
      expect(soughtSeconds!, greaterThan(30));
    });
  });
}
