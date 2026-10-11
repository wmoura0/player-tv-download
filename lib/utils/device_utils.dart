import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Utilitários para compatibilidade e comportamento adaptativo entre Celular Android e Android/Fire TV.
class DeviceUtils {
  static const MethodChannel _deviceChannel = MethodChannel('com.player.m3u/device');
  static bool? _cachedIsTv;

  /// Inicializa e consulta a identificação nativa da plataforma Android/Fire TV.
  static Future<void> init() async {
    try {
      final isTv = await _deviceChannel.invokeMethod<bool>('isTvDevice');
      if (isTv != null) {
        _cachedIsTv = isTv;
      }
    } catch (_) {
      // Ignora falhas em ambientes sem o plugin (ex: desktop, testes)
    }
  }

  /// Retorna `true` apenas se o dispositivo for comprovadamente uma TV (Android TV / Fire TV).
  ///
  /// Regra de decisão estrita:
  /// 1. Prioriza a detecção nativa do sistema operacional (UiModeManager e Leanback).
  /// 2. Caso não esteja em ambiente Android nativo (testes/desktop), utiliza como fallback criterioso
  ///    o `shortestSide >= 600` (padrão oficial do Android para tablets e telas de TV).
  ///    Nunca classifica uma TV exclusivamente pela largura horizontal temporária da tela.
  static bool isTvMode(BuildContext context) {
    if (_cachedIsTv != null) return _cachedIsTv!;
    final media = MediaQuery.maybeOf(context);
    if (media == null) return false;
    return media.size.shortestSide >= 600;
  }

  /// Getter síncrono para verificar se o dispositivo atual é TV.
  static bool get isTv => _cachedIsTv ?? false;

  /// Permite injetar o modo de dispositivo para testes automatizados controlados.
  @visibleForTesting
  static void setMockIsTv(bool? value) {
    _cachedIsTv = value;
  }

  /// Configura a orientação para o modo de navegação normal do aplicativo:
  /// - No Celular: bloqueia na orientação vertical (portraitUp, portraitDown).
  /// - Na TV / Fire TV: preserva a orientação horizontal (landscapeLeft, landscapeRight).
  static Future<void> setNormalOrientation({BuildContext? context, bool? isTv}) async {
    final tv = isTv ?? ((context != null) ? isTvMode(context) : DeviceUtils.isTv);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (tv) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  /// Configura a orientação para reprodução de vídeo em tela cheia:
  /// - Oculta barras do sistema com modo imersivo (`immersiveSticky`).
  /// - Ativa a orientação horizontal (`landscapeLeft`, `landscapeRight`) em qualquer dispositivo.
  static Future<void> setVideoOrientation() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// Restaura imediatamente a orientação ao sair da tela cheia ou fechar players:
  /// - No Celular: restaura imediatamente a orientação vertical (portrait).
  /// - Na TV / Fire TV: mantém a orientação horizontal (landscape).
  static Future<void> restoreOrientation({BuildContext? context, bool? isTv}) async {
    await setNormalOrientation(context: context, isTv: isTv);
  }

  /// Atalhos comuns de seleção (OK / Enter / Espaço / Botão A do gamepad) para controle remoto
  static const Map<ShortcutActivator, Intent> dpadSelectShortcuts = {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  };

  /// Cria o mapa de ações padrão para acionar um [onTap] a partir de um [ActivateIntent]
  static Map<Type, Action<Intent>> activateAction(VoidCallback onTap) {
    return {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) => onTap(),
      ),
    };
  }
}
