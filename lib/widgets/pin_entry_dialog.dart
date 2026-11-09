import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/pin_service.dart';
import '../theme/app_colors.dart';

/// Diálogo de entrada de PIN de 4 dígitos especialmente otimizado para Android TV e Fire OS.
/// Permite interação completa via controle remoto D-Pad (teclado 3x4 em tela)
/// ou por teclas numéricas físicas do controle (0-9).
class PinEntryDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final bool isCreatingNewPin;
  final ValueChanged<String>? onPinCreated;

  const PinEntryDialog({
    super.key,
    this.title = 'Controle Parental',
    this.subtitle = 'Digite o PIN de 4 dígitos para acessar este conteúdo.',
    this.isCreatingNewPin = false,
    this.onPinCreated,
  });

  /// Exibe o diálogo e retorna true se o PIN foi autenticado com sucesso
  static Future<bool> show(
    BuildContext context, {
    String title = 'Controle Parental',
    String subtitle = 'Digite o PIN de 4 dígitos para acessar este conteúdo.',
    bool isCreatingNewPin = false,
    ValueChanged<String>? onPinCreated,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PinEntryDialog(
        title: title,
        subtitle: subtitle,
        isCreatingNewPin: isCreatingNewPin,
        onPinCreated: onPinCreated,
      ),
    );
    return result ?? false;
  }

  @override
  State<PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<PinEntryDialog> {
  final List<String> _enteredDigits = [];
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'PinDialogRoot');
  final List<FocusNode> _keypadFocusNodes = List.generate(12, (i) => FocusNode(debugLabel: 'PinKey_$i'));

  String? _errorMessage;
  Timer? _lockoutTimer;
  int _lockoutRemaining = 0;

  @override
  void initState() {
    super.initState();
    _checkLockout();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Foca inicialmente no botão "1" (índice 0)
        _keypadFocusNodes[0].requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _rootFocusNode.dispose();
    for (final fn in _keypadFocusNodes) {
      fn.dispose();
    }
    super.dispose();
  }

  void _checkLockout() {
    if (PinService.instance.isLockedOut) {
      _lockoutRemaining = PinService.instance.lockoutSecondsRemaining;
      _errorMessage = 'Bloqueado por excesso de tentativas. Aguarde $_lockoutRemaining s.';
      _lockoutTimer?.cancel();
      _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final rem = PinService.instance.lockoutSecondsRemaining;
        setState(() {
          _lockoutRemaining = rem;
          if (rem <= 0) {
            timer.cancel();
            _errorMessage = null;
          } else {
            _errorMessage = 'Bloqueado por excesso de tentativas. Aguarde $rem s.';
          }
        });
      });
    }
  }

  void _onDigitPressed(String digit) {
    if (PinService.instance.isLockedOut) return;
    if (_enteredDigits.length < 4) {
      setState(() {
        _enteredDigits.add(digit);
        _errorMessage = null;
      });

      if (_enteredDigits.length == 4) {
        _submitPin();
      }
    }
  }

  void _onBackspacePressed() {
    if (_enteredDigits.isNotEmpty) {
      setState(() {
        _enteredDigits.removeLast();
        _errorMessage = null;
      });
    }
  }

  void _submitPin() {
    final pin = _enteredDigits.join();
    if (pin.length != 4) return;

    if (widget.isCreatingNewPin) {
      widget.onPinCreated?.call(pin);
      Navigator.of(context).pop(true);
      return;
    }

    final isValid = PinService.instance.verifyPin(pin);
    if (isValid) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _enteredDigits.clear();
        if (PinService.instance.isLockedOut) {
          _checkLockout();
        } else {
          final remaining = PinService.maxAttempts - PinService.instance.failedAttempts;
          _errorMessage = 'PIN incorreto. Tentativas restantes: $remaining';
        }
      });
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Teclas numéricas diretas do controle remoto (0-9)
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      _onDigitPressed('0');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      _onDigitPressed('1');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      _onDigitPressed('2');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      _onDigitPressed('3');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
      _onDigitPressed('4');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
      _onDigitPressed('5');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
      _onDigitPressed('6');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
      _onDigitPressed('7');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
      _onDigitPressed('8');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
      _onDigitPressed('9');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
      _onBackspacePressed();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop(false);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _rootFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: AlertDialog(
        backgroundColor: AppColors.surfaceSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderSubtle),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Ícone e Título
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(40),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.primary.withAlpha(100), width: 1.5),
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    color: AppColors.focusCyan,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 14),

                // Visualizador dos 4 Dígitos
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(4, (index) {
                    final isFilled = index < _enteredDigits.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isFilled ? AppColors.focusCyan : Colors.transparent,
                        border: Border.all(
                          color: isFilled ? AppColors.focusCyan : AppColors.borderSubtle,
                          width: 2,
                        ),
                        boxShadow: isFilled
                            ? const [
                                BoxShadow(
                                  color: Color(0x6600E5FF),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 12),

                // Mensagem de Erro / Lockout
                if (_errorMessage != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0x33EF5350),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0x66EF5350)),
                    ),
                    child: Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFFCDD2),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                // Teclado Numérico 3x4
                _buildKeypad(),

                const SizedBox(height: 12),
                // Botão de Cancelar
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.borderSubtle),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  ),
                  child: const Text('Cancelar', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildKeypadRow(['1', '2', '3'], [0, 1, 2]),
        const SizedBox(height: 8),
        _buildKeypadRow(['4', '5', '6'], [3, 4, 5]),
        const SizedBox(height: 8),
        _buildKeypadRow(['7', '8', '9'], [6, 7, 8]),
        const SizedBox(height: 8),
        _buildKeypadRow(['⌫', '0', 'OK'], [9, 10, 11]),
      ],
    );
  }

  Widget _buildKeypadRow(List<String> labels, List<int> indices) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(labels.length, (col) {
        final label = labels[col];
        final index = indices[col];
        final fn = _keypadFocusNodes[index];

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: AnimatedBuilder(
            animation: fn,
            builder: (context, _) {
              final isFocused = fn.hasFocus;
              final isAction = label == '⌫' || label == 'OK';

              return InkWell(
                focusNode: fn,
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  if (label == '⌫') {
                    _onBackspacePressed();
                  } else if (label == 'OK') {
                    _submitPin();
                  } else {
                    _onDigitPressed(label);
                  }
                },
                child: Container(
                  width: 58,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isFocused
                        ? AppColors.focusCyan
                        : (isAction ? AppColors.surfaceSecondary : AppColors.background),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isFocused ? Colors.white : AppColors.borderSubtle,
                      width: isFocused ? 2 : 1,
                    ),
                    boxShadow: isFocused
                        ? const [
                            BoxShadow(
                              color: Color(0x6600E5FF),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: isFocused
                          ? Colors.black
                          : (isAction ? AppColors.textPrimary : AppColors.textPrimary),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      }),
    );
  }
}
