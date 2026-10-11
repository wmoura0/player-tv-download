import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/url_sanitizer.dart';

void main() {
  group('UrlSanitizer Tests', () {
    test('Mascara credenciais em formato user:pass no host', () {
      const raw = 'http://meuusuario:minhasenha123@iptv.exemplo.com:8080/live.m3u8';
      final sanitized = UrlSanitizer.sanitize(raw);
      expect(sanitized, contains('***:***@iptv.exemplo.com:8080'));
      expect(sanitized, isNot(contains('meuusuario')));
      expect(sanitized, isNot(contains('minhasenha123')));
    });

    test('Mascara parâmetros sensíveis na query string', () {
      const raw =
          'https://servidor.com/get.php?username=usuarioTeste&password=senhaSegura&token=token123&type=m3u';
      final sanitized = UrlSanitizer.sanitize(raw);

      expect(sanitized, contains('username=***'));
      expect(sanitized, contains('password=***'));
      expect(sanitized, contains('token=***'));
      expect(sanitized, contains('type=m3u')); // parâmetro não sensível mantido
      expect(sanitized, isNot(contains('usuarioTeste')));
      expect(sanitized, isNot(contains('senhaSegura')));
      expect(sanitized, isNot(contains('token123')));
    });

    test('Preserva URLs comuns sem credenciais', () {
      const raw = 'https://stream.exemplo.com/canais/lista.m3u';
      final sanitized = UrlSanitizer.sanitize(raw);
      expect(sanitized, equals(raw));
    });

    test('Mascara URLs sensíveis embutidas em mensagens de erro', () {
      const rawError =
          'SocketException: Failed host lookup em http://admin:secreto@api.tv.com/get.php?key=chave123';
      final sanitizedError = UrlSanitizer.sanitizeErrorMessage(rawError);

      expect(sanitizedError, isNot(contains('admin')));
      expect(sanitizedError, isNot(contains('secreto')));
      expect(sanitizedError, isNot(contains('chave123')));
      expect(sanitizedError, contains('key=***'));
    });
    test('Mascara credenciais no path de streams Xtream Codes', () {
      const raw = 'http://ls-prime.site/live/usuarioSecreto/senhaSecreta123/9876.ts';
      final sanitized = UrlSanitizer.sanitize(raw);
      expect(sanitized, contains('/live/***/***/9876.ts'));
      expect(sanitized, isNot(contains('usuarioSecreto')));
      expect(sanitized, isNot(contains('senhaSecreta123')));
    });

    test('Mascara credenciais em URLs Xtream sem prefixo /live/', () {
      const raw = 'http://ls-prime.site/usuarioSecreto/senhaSecreta123/9876.ts';
      final sanitized = UrlSanitizer.sanitize(raw);
      expect(sanitized, contains('ls-prime.site/***/***/9876.ts'));
      expect(sanitized, isNot(contains('usuarioSecreto')));
      expect(sanitized, isNot(contains('senhaSecreta123')));
    });
  });
}
