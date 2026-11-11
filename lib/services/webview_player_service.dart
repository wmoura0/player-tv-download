import 'package:flutter/services.dart';

/// Serviço experimental da Prova de Conceito (PoC) do WebView Player para Fire TV.
/// Totalmente isolado do Media3/ExoPlayer e das rotinas principais de streaming.
class WebViewPlayerService {
  static const MethodChannel _channel = MethodChannel('com.player.m3u/device');

  /// Verifica se o ambiente host Android suporta o lançamento da WebViewPlayerActivity.
  static Future<bool> isSupported() async {
    try {
      final res = await _channel.invokeMethod<bool>('isWebViewPocSupported');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Lança a WebViewPlayerActivity nativa em tela cheia com URL e título especificados.
  static Future<bool> openPocPlayer({String? url, String? title}) async {
    try {
      final res = await _channel.invokeMethod<bool>('openWebViewPoc', {
        'url': url ?? 'file:///android_asset/poc_player.html',
        'title': title ?? 'JessFlix WebView PoC (Experimental)',
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
