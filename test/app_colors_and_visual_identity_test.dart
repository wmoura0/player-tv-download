import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/theme/app_colors.dart';

void main() {
  group('Paleta Oficial de Três Cores e Tokens de Identidade Visual', () {
    test('Validação exata dos tokens centrais da paleta oficial', () {
      // 1. Azul Principal #3EA6FF - Ações e destaques visuais
      expect(AppColors.primary, equals(const Color(0xFF3EA6FF)));
      expect(AppColors.primary.toARGB32(), equals(0xFF3EA6FF));

      // 2. Azul Escuro #1E2C42 - Superfícies secundárias, cartões e painéis
      expect(AppColors.surfaceSecondary, equals(const Color(0xFF1E2C42)));
      expect(AppColors.surfaceSecondary.toARGB32(), equals(0xFF1E2C42));

      // 3. Ciano de Seleção #00E5FF - Foco oficial do controle remoto D-pad
      expect(AppColors.focusCyan, equals(const Color(0xFF00E5FF)));
      expect(AppColors.focusCyan.toARGB32(), equals(0xFF00E5FF));

      // 4. Fundo Geral #070F18
      expect(AppColors.background, equals(const Color(0xFF070F18)));
      expect(AppColors.background.toARGB32(), equals(0xFF070F18));

      // 5. Bordas Sutis #26394F
      expect(AppColors.borderSubtle, equals(const Color(0xFF26394F)));
      expect(AppColors.borderSubtle.toARGB32(), equals(0xFF26394F));
    });

    test('Regra de aplicação: Azul principal e Ciano de foco são cores estritamente distintas', () {
      expect(AppColors.primary, isNot(equals(AppColors.focusCyan)));
      expect(AppColors.primary, isNot(equals(AppColors.surfaceSecondary)));
      expect(AppColors.focusCyan, isNot(equals(AppColors.surfaceSecondary)));
    });

    test('Espessura da borda de foco para navegação por controle remoto', () {
      expect(AppColors.focusBorderWidth, greaterThanOrEqualTo(2.0));
    });

    test('Tema padrão integra tokens oficiais', () {
      final theme = AppColors.darkTheme;
      expect(theme.scaffoldBackgroundColor, equals(AppColors.background));
      expect(theme.primaryColor, equals(AppColors.primary));
      expect(theme.colorScheme.primary, equals(AppColors.primary));
      expect(theme.colorScheme.surface, equals(AppColors.surfaceSecondary));
    });
  });
}
