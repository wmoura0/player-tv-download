import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Gerenciador central de notificações temporárias (toasts) à prova de
/// `accessibleNavigation` em Android TV / Fire TV.
///
/// Diferente do `SnackBar` com `SnackBarAction` do Material (que não fecha
/// automaticamente quando `MediaQuery.accessibleNavigation` está ativo no
/// Fire OS), este serviço garante:
/// - Duração efetiva via [Timer] explícito;
/// - Cancelamento imediato de qualquer notificação anterior ao exibir uma nova;
/// - Descarte limpo em transições de tela (`dismiss()`) e em `dispose()`;
/// - Botão de ação opcional que não captura foco automaticamente do D-pad.
class AppToastService {
  AppToastService._();
  static final AppToastService instance = AppToastService._();

  OverlayEntry? _currentEntry;
  Timer? _dismissTimer;
  String? _activeMessage;
  bool _isVisible = false;

  /// Retorna `true` se há uma notificação visível no momento.
  bool get isVisible => _isVisible;

  /// Mensagem atualmente exibida (ou `null` se oculta).
  String? get activeMessage => _activeMessage;

  /// Exibe uma notificação temporária substituindo imediatamente qualquer aviso anterior.
  void show(
    BuildContext context, {
    required String message,
    Duration duration = const Duration(milliseconds: 3500),
    String? actionLabel,
    VoidCallback? onAction,
    IconData icon = Icons.info_outline_rounded,
    Color accentColor = AppColors.focusCyan,
  }) {
    dismiss();

    // Limpa eventuais SnackBars residuais do Material para nunca acumular barras inferiores.
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _activeMessage = message;
    _isVisible = true;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) {
        final bottomSafe = MediaQuery.viewPaddingOf(overlayContext).bottom;
        return Positioned(
          left: 24,
          right: 24,
          bottom: 20 + bottomSafe,
          child: ExcludeFocus(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    key: const Key('app_toast_banner'),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141E30),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: accentColor.withValues(alpha: 0.65),
                        width: 1.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x88000000),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: accentColor, size: 18),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (actionLabel != null && onAction != null) ...[
                          const SizedBox(width: 12),
                          TextButton(
                            key: const Key('app_toast_action_btn'),
                            style: TextButton.styleFrom(
                              foregroundColor: accentColor,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              minimumSize: const Size(0, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              final callback = onAction;
                              dismiss();
                              callback();
                            },
                            child: Text(
                              actionLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _currentEntry = entry;
    overlay.insert(entry);

    _dismissTimer = Timer(duration, dismiss);
  }

  /// Remove imediatamente a notificação ativa e cancela seu timer.
  void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _activeMessage = null;
    _isVisible = false;
    final entry = _currentEntry;
    _currentEntry = null;
    if (entry != null) {
      try {
        if (entry.mounted) {
          entry.remove();
        }
      } catch (_) {}
    }
  }
}
