import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:projeto_tv/screens/splash_screen.dart';
import 'package:projeto_tv/screens/xtream_login_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('JessFlix SplashScreen Tests', () {
    testWidgets('Renderiza centelha, monograma e título JessFlix durante a abertura', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SplashScreen(
            autoNavigate: false,
            animationDuration: Duration(milliseconds: 1000),
          ),
        ),
      );

      // Início da animação (centelha ciano ativa)
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SplashScreen), findsOneWidget);

      // Avança para meio da animação (monograma visível)
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(Image), findsOneWidget);

      // Avança para o fim da animação (título e subtítulo visíveis)
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('SUA TV & STREAMING'), findsOneWidget);
    });

    testWidgets('Transiciona suavemente para a tela de Login quando não há credenciais salvas', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SplashScreen(
            autoNavigate: true,
            animationDuration: Duration(milliseconds: 500),
          ),
        ),
      );

      // Avança a animação completa e transição
      await tester.pumpAndSettle();

      // Confirma que transicionou para XtreamLoginScreen
      expect(find.byType(XtreamLoginScreen), findsOneWidget);
      expect(find.text('JessFlix'), findsOneWidget);
      expect(find.text('Servidor / DNS'), findsOneWidget);
    });
  });
}
