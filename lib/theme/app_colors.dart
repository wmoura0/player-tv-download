import 'package:flutter/material.dart';

/// Paleta oficial de cores do Player TV baseada no layout de referência
///
/// 1. Azul principal (#3EA6FF):
///    Ações principais, botões, ícones ativos, indicadores de abas selecionadas,
///    elementos de progresso e rótulos de cartões.
///
/// 2. Azul escuro (#1E2C42):
///    Superfícies de cartões, painéis, menus, áreas de conteúdo, abas não selecionadas.
///
/// 3. Ciano de seleção (#00E5FF):
///    Foco oficial do controle remoto (D-Pad), contorno dos itens em foco (aprox. 2.5px),
///    realce de seleção por teclado e interação.
///
/// 4. Cores base de contraste:
///    Fundo profundo (#070F18) e bordas discretas (#26394F).
abstract final class AppColors {
  // Tokens Oficiais Obrigatórios
  static const Color primary = Color(0xFF3EA6FF);
  static const Color surfaceSecondary = Color(0xFF1E2C42);
  static const Color focusCyan = Color(0xFF00E5FF);
  static const Color background = Color(0xFF070F18);
  static const Color borderSubtle = Color(0xFF26394F);

  // Aliases semânticos para clareza em toda a base de código
  static const Color cardBackground = surfaceSecondary;
  static const Color activeIcon = primary;
  static const Color activeAction = primary;
  static const Color focusOutline = focusCyan;

  // Cores neutras complementares para contraste e legibilidade
  static const Color textPrimary = Color(0xFFF5F8FC);
  static const Color textSecondary = Color(0xFF8DAEC4);
  static const Color textMuted = Color(0xFF64748B);
  static const Color divider = Color(0xFF1B2838);

  // Cores funcionais de status mantidas
  static const Color success = Color(0xFF00E676);
  static const Color warning = Color(0xFFFFB300);
  static const Color error = Color(0xFFEF5350);

  // Espessura padrão para contorno de foco D-Pad (aprox 2.5px)
  static const double focusBorderWidth = 2.5;
  static const double normalBorderWidth = 1.2;

  /// Retorna o ThemeData oficial configurado com os tokens da paleta
  static ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    primaryColor: primary,
    colorScheme: const ColorScheme.dark(
      primary: primary,
      secondary: focusCyan,
      surface: surfaceSecondary,
      error: error,
    ),
  );

  /// Retorna BoxDecoration para cartões em estilo oficial
  static BoxDecoration cardBoxDecoration({
    bool isFocused = false,
    double borderRadius = 14.0,
    Color? surfaceColor,
  }) {
    return BoxDecoration(
      color: surfaceColor ?? surfaceSecondary,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: isFocused ? focusCyan : borderSubtle,
        width: isFocused ? focusBorderWidth : normalBorderWidth,
      ),
      boxShadow: isFocused
          ? [
              BoxShadow(
                color: focusCyan.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ]
          : const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
    );
  }
}
