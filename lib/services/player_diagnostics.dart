import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'url_sanitizer.dart';

/// Resultado estruturado da sondagem HTTP de diagnóstico do stream
class HttpProbeResult {
  final int? statusCode;
  final String? contentType;
  final int? contentLength;
  final String? redirectedUrl;
  final String? serverHeader;
  final String? errorMessage;
  final int elapsedMs;

  const HttpProbeResult({
    this.statusCode,
    this.contentType,
    this.contentLength,
    this.redirectedUrl,
    this.serverHeader,
    this.errorMessage,
    required this.elapsedMs,
  });

  bool get isSuccess => statusCode != null && statusCode! >= 200 && statusCode! < 300;
  bool get isForbidden => statusCode == 401 || statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isServerError => statusCode != null && statusCode! >= 500;
}

/// Detalhes extraídos de erros de reprodução do Media3/ExoPlayer e rede
class DiagnosticErrorDetails {
  final String? errorCodeName;
  final int? errorCode;
  final int? exoPlayerHttpStatus;
  final int? probeHttpStatus;
  final String? causeClass;
  final String? causeMessage;
  final String shortUiMessage;
  final String technicalSummary;

  const DiagnosticErrorDetails({
    this.errorCodeName,
    this.errorCode,
    this.exoPlayerHttpStatus,
    this.probeHttpStatus,
    this.causeClass,
    this.causeMessage,
    required this.shortUiMessage,
    required this.technicalSummary,
  });

  bool get isAuthOrForbidden =>
      exoPlayerHttpStatus == 401 ||
      exoPlayerHttpStatus == 403 ||
      probeHttpStatus == 401 ||
      probeHttpStatus == 403;

  bool get isResourceNotFound =>
      exoPlayerHttpStatus == 404 ||
      probeHttpStatus == 404 ||
      shortUiMessage.contains('404') ||
      shortUiMessage.contains('não encontrado');

  bool get isFormatOrContainerError =>
      errorCode == 3001 ||
      errorCode == 3003 ||
      errorCodeName == 'ERROR_CODE_PARSING_CONTAINER_MALFORMED' ||
      errorCodeName == 'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED' ||
      errorCodeName == 'ERROR_CODE_PARSER_BAD_MEDIA_MANIFEST' ||
      (causeClass != null &&
          (causeClass!.contains('Decoder') ||
              causeClass!.contains('Parser') ||
              causeClass!.contains('MediaCodec')));
}

/// Utilitário central de diagnóstico instrumental para o player JessFlix no Fire TV.
/// Registra logs com a tag unificada [JESSFLIX_PLAYER], captura status HTTP reais do stream
/// e extrai com precisão as causas técnicas ocultadas por trás de mensagens genéricas.
class PlayerDiagnostics {
  static const MethodChannel _channel = MethodChannel('com.player.m3u/device');

  /// Registra uma mensagem diagnóstica no console Flutter e no Android Logcat sob a tag JESSFLIX_PLAYER
  static void log(String subTag, String message) {
    final formatted = '[$subTag] $message';
    debugPrint('[JESSFLIX_PLAYER]$formatted');
    try {
      _channel.invokeMethod('logPlayer', {'message': formatted}).catchError((_) {});
    } catch (_) {}
  }

  /// Emite em conjunto as tags obrigatórias de status do ExoPlayer e probe
  static void logDiagnosticDetails(DiagnosticErrorDetails details) {
    log('PLAYER][EXOPLAYER_HTTP_STATUS', details.exoPlayerHttpStatus != null ? '${details.exoPlayerHttpStatus}' : 'N/D');
    log('PLAYER][PROBE_HTTP_STATUS', details.probeHttpStatus != null ? '${details.probeHttpStatus}' : 'N/D');
    log('PLAYER][ERROR_CODE', details.errorCode != null ? '${details.errorCode}' : 'N/D');
    log('PLAYER][CAUSE_CLASS', details.causeClass ?? 'N/D');
  }

  /// Realiza uma sondagem HTTP leve e rápida ao endpoint do stream antes ou durante o erro
  /// para registrar com certeza o status HTTP e Content-Type do servidor remoto.
  static Future<HttpProbeResult> probeStreamUrl(
    String rawUrl, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final sw = Stopwatch()..start();
    final sanitized = UrlSanitizer.sanitize(rawUrl);
    log('HTTP_PROBE', 'Iniciando sondagem HTTP para: $sanitized');

    try {
      final uri = Uri.parse(rawUrl);
      final client = http.Client();

      final reqHeaders = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
        'Range': 'bytes=0-1024',
        ...?headers,
      };

      final request = http.Request('GET', uri)..headers.addAll(reqHeaders);
      var streamedResponse = await client.send(request).timeout(timeout);

      // Se retornou 404, 405 ou 416 com Range header, tentar HEAD sem Range
      // para evitar falsos 404/416 causados por proxies ou servidores que não suportam Range
      if (streamedResponse.statusCode == 404 ||
          streamedResponse.statusCode == 416 ||
          streamedResponse.statusCode == 405) {
        try {
          final fallbackHeaders = <String, String>{
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
            ...?headers,
          };
          final headReq = http.Request('HEAD', uri)..headers.addAll(fallbackHeaders);
          final headRes = await client.send(headReq).timeout(const Duration(seconds: 3));
          if (headRes.statusCode >= 200 && headRes.statusCode < 400) {
            streamedResponse = headRes;
          }
        } catch (_) {}
      }

      sw.stop();

      final statusCode = streamedResponse.statusCode;
      final contentType = streamedResponse.headers['content-type'];
      final contentLength = streamedResponse.contentLength;
      final server = streamedResponse.headers['server'];
      final location = streamedResponse.headers['location'];

      client.close();

      final result = HttpProbeResult(
        statusCode: statusCode,
        contentType: contentType,
        contentLength: contentLength,
        redirectedUrl: location != null ? UrlSanitizer.sanitize(location) : null,
        serverHeader: server,
        elapsedMs: sw.elapsedMilliseconds,
      );

      log('HTTP_STATUS', 'Código retornado: $statusCode em ${sw.elapsedMilliseconds}ms | Content-Type: ${contentType ?? 'N/D'} | Content-Length: ${contentLength ?? 'N/D'}');
      if (location != null) {
        log('HTTP_REDIRECT', 'Redirecionamento para: ${UrlSanitizer.sanitize(location)}');
      }

      return result;
    } catch (e) {
      sw.stop();
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      log('HTTP_PROBE_ERROR', 'Falha na sondagem HTTP (${sw.elapsedMilliseconds}ms): $safeErr');

      return HttpProbeResult(
        errorMessage: safeErr,
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }

  /// Analisa detalhadamente a exceção lançada pelo ExoPlayer/Media3 ou Flutter
  static DiagnosticErrorDetails analyzeError(Object error, {HttpProbeResult? probe}) {
    final rawText = error.toString();
    final lower = rawText.toLowerCase();

    String? codeName;
    int? code;
    int? exoPlayerHttpStatus;
    final int? probeHttpStatus = probe?.statusCode;
    String? causeClass;
    String? causeMsg;
    String shortUi;

    // 1. Extração de ErrorCode do Media3 (ExoPlayer)
    final codeMatch = RegExp(r'error\s*code\s*[:=]\s*(\d+)', caseSensitive: false).firstMatch(rawText);
    if (codeMatch != null) {
      code = int.tryParse(codeMatch.group(1)!);
    }

    // 2. Extração de ErrorCodeName
    final nameMatch = RegExp(r'ERROR_CODE_[A-Z0-9_]+').firstMatch(rawText);
    if (nameMatch != null) {
      codeName = nameMatch.group(0);
    }

    // 3. Extração explícita de HTTP Status vindo diretamente do ExoPlayer
    final exoStatusMatch = RegExp(r'(?:response\s*code|status\s*code)\s*[:=]\s*(\d+)', caseSensitive: false).firstMatch(rawText);
    if (exoStatusMatch != null) {
      exoPlayerHttpStatus = int.tryParse(exoStatusMatch.group(1)!);
    }

    // 4. Extração de classe de causa e códigos específicos
    final isTlsError = lower.contains('handshake') ||
        lower.contains('certpathvalidator') ||
        lower.contains('certificate_verify_failed') ||
        lower.contains('sslhandshakeexception') ||
        lower.contains('certpathvalidatorexception') ||
        lower.contains('trust anchor');

    final isClockMismatch = isTlsError &&
        (lower.contains('not yet valid') ||
            lower.contains('expired') ||
            lower.contains('current time') ||
            lower.contains('validity') ||
            lower.contains('time of'));

    if (isClockMismatch) {
      causeClass = 'SSLHandshakeException (Data/Hora incorreta)';
      causeMsg =
          'O certificado SSL não pôde ser validado porque o relógio do Fire TV está desatualizado. Ajuste data e hora nas configurações do sistema.';
      shortUi = 'Data/Hora do dispositivo incorreta (Falha SSL/TLS)';
    } else if (isTlsError) {
      causeClass = 'SSLHandshakeException';
      causeMsg = 'Falha no aperto de mão seguro (Handshake TLS) com o servidor de streaming.';
      shortUi = 'Falha de Certificado SSL/TLS';
    } else if (lower.contains('cleartext http traffic') || lower.contains('cleartext not permitted')) {
      causeClass = 'CleartextNotPermittedException';
      causeMsg = 'O sistema operacional bloqueou tráfego HTTP sem criptografia';
      shortUi = 'Bloqueio de rede Cleartext (HTTP)';
    } else if (exoPlayerHttpStatus == 401 ||
        exoPlayerHttpStatus == 403 ||
        lower.contains('response code: 403') ||
        lower.contains('response code: 401') ||
        lower.contains('code: 403') ||
        lower.contains('code: 401') ||
        lower.contains('403 forbidden') ||
        lower.contains('401 unauthorized')) {
      causeClass = 'HttpDataSource\$InvalidResponseCodeException';
      exoPlayerHttpStatus ??= (lower.contains('401') ? 401 : 403);
      causeMsg = 'Servidor rejeitou acesso com HTTP $exoPlayerHttpStatus (Token expirado ou limite de conexões simultâneas)';
      shortUi = 'HTTP $exoPlayerHttpStatus (Acesso Negado / Limite de Telas)';
    } else if (code == 3001 || codeName == 'ERROR_CODE_PARSING_CONTAINER_MALFORMED') {
      causeClass = 'ParserException\$BadContainer';
      causeMsg = 'Container de mídia corrompido ou incompatível com a extensão (Media3 3001)';
      shortUi = 'Formato/Container malformado (Media3 3001)';
    } else if (code == 3003 || codeName == 'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED') {
      causeClass = 'ParserException\$UnsupportedContainer';
      causeMsg = 'Container de mídia não suportado pelo hardware ou extensão incorreta (Media3 3003)';
      shortUi = 'Container não suportado (Media3 3003)';
    } else if (exoPlayerHttpStatus == 404 ||
        lower.contains('response code: 404') ||
        lower.contains('code: 404') ||
        lower.contains('404 not found')) {
      causeClass = 'HttpDataSource\$InvalidResponseCodeException';
      exoPlayerHttpStatus = 404;
      causeMsg = 'ExoPlayer recebeu HTTP 404: Arquivo de mídia não encontrado no servidor remoto';
      shortUi = 'HTTP 404 — Arquivo não encontrado no servidor';
    } else if (probe?.isNotFound == true) {
      // O ExoPlayer falhou por outra razão, mas o probe HTTP detectou 404 na URL
      causeClass = lower.contains('httpdatasource') ? 'HttpDataSource\$InvalidResponseCodeException' : 'HttpProbeNotFound';
      causeMsg = 'Sondagem HTTP retornou 404: Arquivo inexistente ou URL inválida';
      shortUi = 'Sondagem HTTP 404 (Arquivo inexistente)';
    } else if (exoPlayerHttpStatus != null && exoPlayerHttpStatus >= 500) {
      causeClass = 'HttpDataSource\$InvalidResponseCodeException';
      causeMsg = 'Servidor de streaming com erro interno (HTTP $exoPlayerHttpStatus)';
      shortUi = 'HTTP $exoPlayerHttpStatus (Erro interno no servidor)';
    } else if (probe?.isServerError == true) {
      causeClass = 'HttpDataSource\$InvalidResponseCodeException';
      causeMsg = 'Servidor de streaming com erro interno (HTTP ${probe?.statusCode})';
      shortUi = 'HTTP ${probe?.statusCode ?? '5xx'} (Erro interno no servidor)';
    } else if (error is TimeoutException || lower.contains('timeoutexception') || lower.contains('tempo limite')) {
      causeClass = 'TimeoutException';
      causeMsg = 'O servidor não respondeu ou não iniciou o fluxo dentro do tempo limite';
      shortUi = 'Timeout (Servidor não respondeu em 25s)';
    } else if (lower.contains('decoderinitializationexception') ||
        lower.contains('mediacodec') ||
        lower.contains('no_suitable_decoder') ||
        lower.contains('unrecognizedinputformat') ||
        lower.contains('parserexception')) {
      causeClass = 'MediaCodecRenderer\$DecoderInitializationException';
      causeMsg = 'Formato de container ou codec de áudio/vídeo incompatível com o hardware do Fire TV';
      shortUi = 'Codec/Formato não suportado pelo Fire TV';
    } else if (lower.contains('unknownhostexception') ||
        lower.contains('connectexception') ||
        lower.contains('socketexception') ||
        lower.contains('network is unreachable') ||
        lower.contains('httpdatasourceexception')) {
      causeClass = 'HttpDataSource\$HttpDataSourceException';
      causeMsg = 'Falha de conexão TCP/DNS com o servidor de streaming';
      shortUi = 'Erro de Conexão de Rede (Host inacessível)';
    } else {
      causeClass = error.runtimeType.toString();
      causeMsg = UrlSanitizer.sanitizeErrorMessage(rawText);
      shortUi = codeName != null ? 'Erro Media3 ($codeName)' : 'Erro de reprodução (${probe?.statusCode != null ? 'HTTP ${probe!.statusCode}' : 'ver logcat'})';
    }

    final summary = StringBuffer();
    summary.write('Causa: $causeClass');
    if (codeName != null) summary.write(' | Código: $codeName');
    if (code != null) summary.write(' ($code)');
    if (exoPlayerHttpStatus != null) summary.write(' | ExoPlayer HTTP: $exoPlayerHttpStatus');
    if (probeHttpStatus != null) summary.write(' | Probe HTTP: $probeHttpStatus');
    if (probe?.contentType != null) summary.write(' | Tipo: ${probe!.contentType}');
    summary.write(' | Detalhe: $causeMsg');

    return DiagnosticErrorDetails(
      errorCodeName: codeName,
      errorCode: code,
      exoPlayerHttpStatus: exoPlayerHttpStatus,
      probeHttpStatus: probeHttpStatus,
      causeClass: causeClass,
      causeMessage: causeMsg,
      shortUiMessage: shortUi,
      technicalSummary: summary.toString(),
    );
  }
}
