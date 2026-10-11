import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/xtream_account.dart';
import 'url_sanitizer.dart';

enum XtreamAuthStatus {
  success,
  invalidCredentials,
  endpointNotFound,
  unauthorized,
  incompatibleResponse,
  networkError,
}

/// Resultado detalhado da tentativa de autenticação com a API Xtream Codes.
class XtreamAuthResult {
  final XtreamAuthStatus status;
  final String message;
  final XtreamAccount? account;
  final int? httpStatusCode;

  const XtreamAuthResult({
    required this.status,
    required this.message,
    this.account,
    this.httpStatusCode,
  });

  bool get isSuccess => status == XtreamAuthStatus.success;

  factory XtreamAuthResult.success(XtreamAccount account) {
    return XtreamAuthResult(
      status: XtreamAuthStatus.success,
      message: 'Autenticado com sucesso!',
      account: account,
      httpStatusCode: 200,
    );
  }

  factory XtreamAuthResult.invalidCredentials(String message, {int? statusCode}) {
    return XtreamAuthResult(
      status: XtreamAuthStatus.invalidCredentials,
      message: message,
      httpStatusCode: statusCode ?? 200,
    );
  }

  factory XtreamAuthResult.endpointNotFound(String message) {
    return XtreamAuthResult(
      status: XtreamAuthStatus.endpointNotFound,
      message: message,
      httpStatusCode: 404,
    );
  }

  factory XtreamAuthResult.unauthorized(String message, int statusCode) {
    return XtreamAuthResult(
      status: XtreamAuthStatus.unauthorized,
      message: message,
      httpStatusCode: statusCode,
    );
  }

  factory XtreamAuthResult.incompatibleResponse(String message, {int? statusCode}) {
    return XtreamAuthResult(
      status: XtreamAuthStatus.incompatibleResponse,
      message: message,
      httpStatusCode: statusCode,
    );
  }

  factory XtreamAuthResult.networkError(String message) {
    return XtreamAuthResult(
      status: XtreamAuthStatus.networkError,
      message: message,
    );
  }
}

/// Serviço de conexão e autenticação com a API padrão Xtream Codes.
class XtreamAuthService {
  /// Normaliza a URL do servidor garantindo o protocolo e removendo barras extras.
  static String normalizeServerUrl(String rawServerUrl) {
    var trimmed = rawServerUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }

    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }

    return trimmed;
  }

  /// Autentica usuário e senha contra a rota player_api.php do servidor.
  static Future<XtreamAuthResult> authenticate({
    required String serverUrl,
    required String username,
    required String password,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final cleanServer = normalizeServerUrl(serverUrl);
    final sanitizedBase = UrlSanitizer.sanitize(cleanServer);

    final uri = Uri.tryParse('$cleanServer/player_api.php');
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return XtreamAuthResult.networkError(
        'Endereço de servidor inválido. Informe um endereço começando com http:// ou https://',
      );
    }

    final queryUri = uri.replace(
      queryParameters: {
        'username': username.trim(),
        'password': password.trim(),
      },
    );

    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(
            queryUri,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
              'Accept': 'application/json, */*',
            },
          )
          .timeout(timeout);

      // Tratamento por código de status HTTP
      if (response.statusCode == 404) {
        return XtreamAuthResult.endpointNotFound(
          'O servidor respondeu com status 404 (Não Encontrado) em $sanitizedBase. '
          'O endpoint "player_api.php" não está disponível neste endereço ou porta. '
          'Verifique se é necessário especificar uma porta (ex: :8080) ou se o servidor suporta a API Xtream Codes.',
        );
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        return XtreamAuthResult.unauthorized(
          'Acesso negado pelo servidor (Código HTTP ${response.statusCode}).',
          response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        return XtreamAuthResult.networkError(
          'O servidor retornou um código de erro HTTP ${response.statusCode} em $sanitizedBase.',
        );
      }

      // Decodificação segura da resposta JSON
      dynamic decoded;
      try {
        final bodyText = utf8.decode(response.bodyBytes);
        decoded = jsonDecode(bodyText);
      } catch (_) {
        return XtreamAuthResult.incompatibleResponse(
          'O servidor respondeu com formato incompatível (não-JSON). '
          'Pode se tratar de uma página HTML de boas-vindas ou bloqueio de proxy.',
          statusCode: response.statusCode,
        );
      }

      if (decoded is! Map<String, dynamic>) {
        return XtreamAuthResult.incompatibleResponse(
          'Resposta inesperada da API: a resposta recebida não contém os dados esperados do Xtream Codes.',
          statusCode: response.statusCode,
        );
      }

      final userInfo = decoded['user_info'] as Map<String, dynamic>?;
      if (userInfo == null) {
        final message = decoded['message']?.toString() ?? 'Resposta sem dados de usuário.';
        return XtreamAuthResult.incompatibleResponse(
          'O servidor não retornou as informações de conta ("user_info"). Mensagem: $message',
          statusCode: response.statusCode,
        );
      }

      final auth = userInfo['auth'];
      final isAuth = auth == 1 || auth == '1';

      if (!isAuth) {
        final status = userInfo['status']?.toString() ?? 'Inativo';
        final message = userInfo['message']?.toString() ??
            'Credenciais inválidas ou conta com status "$status".';
        return XtreamAuthResult.invalidCredentials(message, statusCode: response.statusCode);
      }

      final account = XtreamAccount.fromApiResponse(
        serverUrl: cleanServer,
        username: username,
        json: decoded,
      );

      return XtreamAuthResult.success(account);
    } on TimeoutException {
      return XtreamAuthResult.networkError(
        'Tempo limite de conexão esgotado ao acessar $sanitizedBase. Verifique sua conexão ou se o servidor está online.',
      );
    } on SocketException catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.message);
      return XtreamAuthResult.networkError(
        'Falha de rede ao conectar em $sanitizedBase: $safeErr',
      );
    } catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      return XtreamAuthResult.networkError(
        'Erro inesperado na comunicação com o servidor: $safeErr',
      );
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }
}
