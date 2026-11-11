import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/webview_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.player.m3u/device');

  group('WebViewPlayerService Tests', () {
    final List<MethodCall> calls = [];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (MethodCall methodCall) async {
          calls.add(methodCall);
          if (methodCall.method == 'isWebViewPocSupported') {
            return true;
          }
          if (methodCall.method == 'openWebViewPoc') {
            return true;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });

    test('isSupported consulta host Android e retorna true', () async {
      final supported = await WebViewPlayerService.isSupported();
      expect(supported, isTrue);
      expect(calls.length, 1);
      expect(calls.first.method, 'isWebViewPocSupported');
    });

    test('openPocPlayer envia url padrao de assets quando omitida', () async {
      final result = await WebViewPlayerService.openPocPlayer();
      expect(result, isTrue);
      expect(calls.length, 1);
      expect(calls.first.method, 'openWebViewPoc');
      final args = calls.first.arguments as Map;
      expect(args['url'], 'file:///android_asset/poc_player.html');
      expect(args['title'], contains('JessFlix WebView PoC'));
    });

    test('openPocPlayer respeita URL e titulo customizados', () async {
      final result = await WebViewPlayerService.openPocPlayer(
        url: 'https://example.com/test.html',
        title: 'Player Customizado',
      );
      expect(result, isTrue);
      expect(calls.first.method, 'openWebViewPoc');
      final args = calls.first.arguments as Map;
      expect(args['url'], 'https://example.com/test.html');
      expect(args['title'], 'Player Customizado');
    });
  });
}
