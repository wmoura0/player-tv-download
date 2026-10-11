/// Utilitário de segurança para mascarar credenciais sensíveis em URLs.
class UrlSanitizer {
  static final _sensitiveParamKeys = {
    'username',
    'user',
    'usr',
    'password',
    'pass',
    'pwd',
    'token',
    'key',
    'secret',
    'auth',
  };

  /// Mascara usuário, senha e tokens de consulta de uma URL.
  static String sanitize(String rawUrl) {
    if (rawUrl.trim().isEmpty) return rawUrl;

    try {
      final uri = Uri.tryParse(rawUrl.trim());
      if (uri == null || !uri.hasScheme) {
        return _maskRegexFallback(rawUrl);
      }

      // 1. Mascarar credenciais no authority (ex: http://user:pass@host)
      String? userInfo;
      if (uri.userInfo.isNotEmpty) {
        userInfo = '***:***';
      }

      // 2. Mascarar parâmetros sensíveis de consulta
      final sanitizedQueryParams = <String, dynamic>{};
      uri.queryParameters.forEach((key, value) {
        if (_sensitiveParamKeys.contains(key.toLowerCase())) {
          sanitizedQueryParams[key] = '***';
        } else {
          sanitizedQueryParams[key] = value;
        }
      });

      final sanitizedUri = uri.replace(
        userInfo: userInfo,
        queryParameters: sanitizedQueryParams.isNotEmpty ? sanitizedQueryParams : null,
      );

      var sanitizedStr = sanitizedUri.toString().replaceAll(RegExp(r'%2[aA]%2[aA]%2[aA]'), '***');
      return _maskXtreamPath(sanitizedStr);
    } catch (_) {
      return _maskRegexFallback(rawUrl);
    }
  }

  static String _maskXtreamPath(String url) {
    // Formato com prefixo: /live/user/pass/123.ts
    var res = url.replaceAllMapped(
      RegExp(r'(/(?:live|movie|series)/)([^/]+)/([^/]+)/([0-9]+(?:\.[a-zA-Z0-9]+)?)', caseSensitive: false),
      (m) => '${m.group(1)}***/***/${m.group(4)}',
    );
    // Formato direto: :port/user/pass/123.ts
    res = res.replaceAllMapped(
      RegExp(r'(https?://[^/]+/)(?!live/|movie/|series/|player_api)([^/]+)/([^/]+)/([0-9]+(?:\.[a-zA-Z0-9]+)?)', caseSensitive: false),
      (m) => '${m.group(1)}***/***/${m.group(4)}',
    );
    return res;
  }

  /// Limpa mensagens de erro que possam conter URLs com credenciais embutidas.
  static String sanitizeErrorMessage(String message) {
    if (message.isEmpty) return message;

    final urlRegex = RegExp(r'https?://[^\s]+');
    return message.replaceAllMapped(urlRegex, (match) {
      final matchedUrl = match.group(0) ?? '';
      return sanitize(matchedUrl);
    });
  }

  static String _maskRegexFallback(String text) {
    // Fallback com regex caso o Uri.tryParse falhe
    var result = text;
    for (final param in _sensitiveParamKeys) {
      result = result.replaceAllMapped(
        RegExp('([?&]$param=)([^&\\s]+)', caseSensitive: false),
        (match) => '${match.group(1)}***',
      );
    }
    result = result.replaceAllMapped(
      RegExp(r'(https?://)([^:@\s]+):([^@\s]+)@', caseSensitive: false),
      (match) => '${match.group(1)}***:***@',
    );
    return result;
  }
}
