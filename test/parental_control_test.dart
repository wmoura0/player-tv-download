import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/pin_service.dart';
import 'package:projeto_tv/widgets/pin_entry_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PinService.instance.init();
    PinService.instance.lockSession();
  });

  group('PinService - Security and Lockout', () {
    test('initial state has no PIN set', () {
      expect(PinService.instance.isPinSet, isFalse);
      expect(PinService.instance.isLockedOut, isFalse);
    });

    test('sets and verifies 4-digit PIN with SHA-256 and Salt', () async {
      final success = await PinService.instance.setPin('1234');
      expect(success, isTrue);
      expect(PinService.instance.isPinSet, isTrue);

      // PIN correto
      expect(PinService.instance.verifyPin('1234'), isTrue);

      // PIN incorreto
      expect(PinService.instance.verifyPin('9999'), isFalse);
    });

    test('rejects PIN with non-numeric or length != 4', () async {
      expect(await PinService.instance.setPin('123'), isFalse);
      expect(await PinService.instance.setPin('12345'), isFalse);
      expect(await PinService.instance.setPin('abcd'), isFalse);
    });

    test('triggers 30-second lockout after 5 consecutive failed attempts', () async {
      await PinService.instance.setPin('4321');

      for (var i = 0; i < 4; i++) {
        expect(PinService.instance.verifyPin('0000'), isFalse);
        expect(PinService.instance.isLockedOut, isFalse);
      }

      // 5ª tentativa incorreta
      expect(PinService.instance.verifyPin('0000'), isFalse);
      expect(PinService.instance.isLockedOut, isTrue);
      expect(PinService.instance.lockoutSecondsRemaining, greaterThan(0));

      // Mesmo com o PIN correto, rejeita durante lockout
      expect(PinService.instance.verifyPin('4321'), isFalse);
    });

    test('removes PIN after providing current valid PIN', () async {
      await PinService.instance.setPin('5555');
      expect(PinService.instance.isPinSet, isTrue);

      // Tenta remover com PIN incorreto
      final failedRemove = await PinService.instance.removePin('1111');
      expect(failedRemove, isFalse);
      expect(PinService.instance.isPinSet, isTrue);

      // Remove com PIN correto
      final okRemove = await PinService.instance.removePin('5555');
      expect(okRemove, isTrue);
      expect(PinService.instance.isPinSet, isFalse);
    });
  });

  group('PinService - Content and Category Gating', () {
    test('identifies adult category names proactively', () {
      expect(PinService.instance.isAdultCategory('Canais +18 Adultos'), isTrue);
      expect(PinService.instance.isAdultCategory('XXX Eroticos'), isTrue);
      expect(PinService.instance.isAdultCategory('Porn Hot HD'), isTrue);
      expect(PinService.instance.isAdultCategory('Filmes de Ação'), isFalse);
      expect(PinService.instance.isAdultCategory('Desenhos Animados'), isFalse);
    });

    test('locks category when PIN is set and adult filter is active', () async {
      await PinService.instance.setPin('1111');
      await PinService.instance.setHideAdultContent(true);

      expect(PinService.instance.isCategoryLocked('cat_adult', categoryName: 'Canais +18'), isTrue);
      expect(PinService.instance.isCategoryLocked('cat_sports', categoryName: 'Esportes'), isFalse);

      // Desbloqueio temporário de sessão
      PinService.instance.unlockCategoryForSession('cat_adult');
      expect(PinService.instance.isCategoryLocked('cat_adult', categoryName: 'Canais +18'), isFalse);

      // Trava novamente ao resetar sessão
      PinService.instance.lockSession();
      expect(PinService.instance.isCategoryLocked('cat_adult', categoryName: 'Canais +18'), isTrue);
    });

    test('locks categories explicitly marked by user', () async {
      await PinService.instance.setPin('1111');
      await PinService.instance.setCategoryLocked('custom_locked_id', true);

      expect(PinService.instance.isCategoryLocked('custom_locked_id'), isTrue);

      await PinService.instance.setCategoryLocked('custom_locked_id', false);
      expect(PinService.instance.isCategoryLocked('custom_locked_id'), isFalse);
    });
  });

  group('PinEntryDialog - Widget Interaction', () {
    testWidgets('renders keypad and supports physical number keys', (tester) async {
      await PinService.instance.setPin('2580');

      bool? dialogResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  dialogResult = await PinEntryDialog.show(ctx);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(find.text('Controle Parental'), findsOneWidget);

      // Pressiona as teclas físicas 2, 5, 8, 0
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();

      // Diálogo deve fechar com sucesso
      expect(dialogResult, isTrue);
      expect(find.byType(PinEntryDialog), findsNothing);
    });

    testWidgets('shows error feedback on incorrect PIN', (tester) async {
      await PinService.instance.setPin('1234');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => PinEntryDialog.show(ctx),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      // Digita PIN incorreto via teclas físicas: 9 9 9 9
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.pumpAndSettle();

      // Deve permanecer aberto e exibir mensagem de erro
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(find.textContaining('PIN incorreto'), findsOneWidget);
    });
  });
}
