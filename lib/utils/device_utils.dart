import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Utilitários para compatibilidade e comportamento adaptativo entre Celular Android e Android/Fire TV.
class DeviceUtils {
  static const MethodChannel _deviceChannel = MethodChannel('com.player.m3u/device');
  static bool? _cachedIsTv;
  static bool? _mockIsPipSupported;

  /// Notificador reativo do estado de Picture-in-Picture (PiP).
  /// Verdadeiro quando o aplicativo estiver minimizado na janela flutuante nativa do Android.
  static final ValueNotifier<bool> isPipMode = ValueNotifier<bool>(false);

  /// Inicializa e consulta a identificação nativa da plataforma Android/Fire TV.
  static Future<void> init() async {
    try {
      _deviceChannel.setMethodCallHandler((call) async {
        if (call.method == 'onPipModeChanged') {
          final inPip = call.arguments as bool? ?? false;
          isPipMode.value = inPip;
        }
      });

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

  static bool _isScreenKeepOnActive = false;
  static Timer? _screenKeepOnReleaseTimer;

  /// Retorna se o bloqueio de suspensão (KEEP_SCREEN_ON) está ativo.
  static bool get isScreenKeepOnActive => _isScreenKeepOnActive;

  /// Atualiza o bloqueio de suspensão da tela de forma coordenada.
  /// Se [shouldKeepOn] for `true`, cancela qualquer liberação pendente e assegura a tela ativa.
  /// Se [shouldKeepOn] for `false`, utiliza um período de tolerância ([gracePeriod]) para não
  /// desativar acidentalmente a tela durante transições (como troca de canais ou alternância de tela cheia),
  /// a menos que [immediate] seja `true` (ex: fechar player ou sair do app).
  static Future<void> updateScreenKeepAlive({
    required bool shouldKeepOn,
    bool immediate = true,
    Duration gracePeriod = const Duration(seconds: 8),
  }) async {
    if (shouldKeepOn) {
      _screenKeepOnReleaseTimer?.cancel();
      _screenKeepOnReleaseTimer = null;
      if (!_isScreenKeepOnActive) {
        _isScreenKeepOnActive = true;
        debugPrint('[DEVICE] Bloqueio de suspensão da tela ativado (KEEP_SCREEN_ON = true).');
        try {
          await _deviceChannel.invokeMethod('keepScreenOn', {'enable': true});
        } catch (_) {}
      }
    } else {
      if (immediate) {
        _screenKeepOnReleaseTimer?.cancel();
        _screenKeepOnReleaseTimer = null;
        if (_isScreenKeepOnActive) {
          _isScreenKeepOnActive = false;
          debugPrint('[DEVICE] Bloqueio de suspensão da tela liberado imediatamente (KEEP_SCREEN_ON = false).');
          try {
            await _deviceChannel.invokeMethod('keepScreenOn', {'enable': false});
          } catch (_) {}
        }
      } else if (_isScreenKeepOnActive && _screenKeepOnReleaseTimer == null) {
        _screenKeepOnReleaseTimer = Timer(gracePeriod, () async {
          _screenKeepOnReleaseTimer = null;
          _isScreenKeepOnActive = false;
          debugPrint('[DEVICE] Bloqueio de suspensão liberado após período de tolerância (KEEP_SCREEN_ON = false).');
          try {
            await _deviceChannel.invokeMethod('keepScreenOn', {'enable': false});
          } catch (_) {}
        });
      }
    }
  }

  /// Mantém a tela ligada durante a reprodução de vídeo para impedir bloqueio acidental.
  static Future<void> setKeepScreenOn(bool enable) async {
    await updateScreenKeepAlive(shouldKeepOn: enable, immediate: !enable);
  }

  @visibleForTesting
  static void resetScreenKeepAliveForTesting() {
    _screenKeepOnReleaseTimer?.cancel();
    _screenKeepOnReleaseTimer = null;
    _isScreenKeepOnActive = false;
  }

  /// Verifica se o dispositivo possui suporte nativo a Picture-in-Picture (PiP).
  /// Retorna false em dispositivos de TV (Android TV / Fire TV) para não ativar PiP indevidamente.
  static Future<bool> isPipSupported() async {
    if (_mockIsPipSupported != null) return _mockIsPipSupported!;
    if (isTv) return false;
    try {
      final supported = await _deviceChannel.invokeMethod<bool>('isPipSupported');
      return supported ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Define se o Picture-in-Picture deve ser ativado automaticamente ao minimizar o aplicativo.
  /// Deve ser chamado com `enabled: true` quando um canal ao vivo estiver em reprodução ativa,
  /// e `enabled: false` quando o player for pausado ou fechado.
  static Future<void> setPipState({
    required bool enabled,
    int aspectNumerator = 16,
    int aspectDenominator = 9,
  }) async {
    if (isTv) return;
    try {
      await _deviceChannel.invokeMethod('setPipState', {
        'enabled': enabled,
        'aspectNumerator': aspectNumerator,
        'aspectDenominator': aspectDenominator,
      });
    } catch (_) {
      // Ignora falhas em plataformas sem o plugin
    }
  }

  /// Solicita a entrada manual no modo Picture-in-Picture (PiP).
  static Future<bool> enterPip({
    int aspectNumerator = 16,
    int aspectDenominator = 9,
  }) async {
    if (isTv) return false;
    try {
      final entered = await _deviceChannel.invokeMethod<bool>('enterPip', {
        'aspectNumerator': aspectNumerator,
        'aspectDenominator': aspectDenominator,
      });
      return entered ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Permite injetar o suporte a PiP para testes controlados.
  @visibleForTesting
  static void setMockIsPipSupported(bool? value) {
    _mockIsPipSupported = value;
  }

  /// Verifica se o aplicativo possui autorização do sistema para instalar pacotes APK.
  static Future<bool> canRequestPackageInstalls() async {
    try {
      final res = await _deviceChannel.invokeMethod<bool>('canRequestPackageInstalls');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Abre a tela de permissões do Android para permitir a instalação de fontes desconhecidas para este app.
  static Future<bool> openInstallPermissionSettings() async {
    try {
      final res = await _deviceChannel.invokeMethod<bool>('openInstallPermissionSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Dispara a instalação nativa do APK através do PackageInstaller oficial via FileProvider.
  static Future<bool> installApk(String filePath) async {
    try {
      final res = await _deviceChannel.invokeMethod<bool>('installApk', {'filePath': filePath});
      return res ?? false;
    } catch (e) {
      debugPrint('Erro ao acionar instalador de pacotes: $e');
      return false;
    }
  }

  /// Atalhos comuns de seleção (OK / Enter / Espaço / Botão A do gamepad) para controle remoto
  static const Map<ShortcutActivator, Intent> dpadSelectShortcuts = {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  };

  /// Atalhos para canais: seleção (OK) e favoritos (Menu/Context Menu/Botão X do gamepad)
  static const Map<ShortcutActivator, Intent> dpadChannelShortcuts = {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.contextMenu): FavoriteToggleIntent(),
    SingleActivator(LogicalKeyboardKey.info): FavoriteToggleIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonX): FavoriteToggleIntent(),
  };

  /// Cria o mapa de ações padrão para acionar um [onTap] a partir de um [ActivateIntent]
  static Map<Type, Action<Intent>> activateAction(VoidCallback onTap) {
    return {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) => onTap(),
      ),
    };
  }

  /// Cria o mapa de ações para canais com suporte a seleção e alternância de favoritos
  static Map<Type, Action<Intent>> channelActions({
    required VoidCallback onTap,
    VoidCallback? onToggleFavorite,
  }) {
    return {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) => onTap(),
      ),
      if (onToggleFavorite != null)
        FavoriteToggleIntent: CallbackAction<FavoriteToggleIntent>(
          onInvoke: (_) => onToggleFavorite(),
        ),
    };
  }
}

/// Intent para acionamento de favoritos via atalho do controle remoto (ex: Tecla Menu).
class FavoriteToggleIntent extends Intent {
  const FavoriteToggleIntent();
}
