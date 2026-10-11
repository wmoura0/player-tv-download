import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/channel.dart';
import 'url_sanitizer.dart';

class M3uParseException implements Exception {
  final String message;
  const M3uParseException(this.message);

  @override
  String toString() => message;
}

/// Resultado do parsing de uma lista M3U contendo canais e metadados como URL de EPG.
class M3uParseResult {
  final List<M3uChannel> channels;
  final String? epgUrl;

  const M3uParseResult({
    required this.channels,
    this.epgUrl,
  });
}

/// Parser de listas M3U/M3U8 com extração de canais, categorias, logos e URL de EPG.
class M3uParser {
  /// Baixa o conteúdo M3U a partir de uma URL e faz o parsing dos canais.
  static Future<List<M3uChannel>> fetchAndParse(
    String rawUrl, {
    Duration timeout = const Duration(seconds: 30),
    http.Client? client,
  }) async {
    final result = await fetchAndParseWithMetadata(
      rawUrl,
      timeout: timeout,
      client: client,
    );
    return result.channels;
  }

  /// Baixa o conteúdo M3U e retorna canais e metadados de EPG.
  static Future<M3uParseResult> fetchAndParseWithMetadata(
    String rawUrl, {
    Duration timeout = const Duration(seconds: 30),
    http.Client? client,
  }) async {
    final sanitizedUrl = UrlSanitizer.sanitize(rawUrl);
    final uri = Uri.tryParse(rawUrl.trim());

    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw const M3uParseException('URL inválida. Informe um endereço começando com http:// ou https://');
    }

    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(
            uri,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
              'Accept': '*/*',
            },
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        throw M3uParseException(
          'Falha ao carregar a lista (Código HTTP ${response.statusCode}) em $sanitizedUrl',
        );
      }

      String content;
      try {
        content = utf8.decode(response.bodyBytes);
      } catch (_) {
        content = latin1.decode(response.bodyBytes);
      }

      return parseWithMetadata(content);
    } on M3uParseException {
      rethrow;
    } catch (e) {
      final safeError = UrlSanitizer.sanitizeErrorMessage(e.toString());
      throw M3uParseException('Erro de conexão ao acessar $sanitizedUrl: $safeError');
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }

  /// Realiza o parsing de uma string com conteúdo M3U em uma lista de [M3uChannel].
  static List<M3uChannel> parse(String content) {
    return parseWithMetadata(content).channels;
  }

  /// Realiza o parsing de uma string M3U retornando canais e URL do EPG se fornecida.
  static M3uParseResult parseWithMetadata(String content) {
    if (content.trim().isEmpty) {
      throw const M3uParseException('O conteúdo da lista está vazio.');
    }

    final cleanContent = content.startsWith('\uFEFF') ? content.substring(1) : content;
    final lines = const LineSplitter().convert(cleanContent);

    final channels = <M3uChannel>[];
    String? epgUrl;

    String? currentName;
    String? currentGroup;
    String? currentLogo;
    String? currentTvgId;
    String? currentTvgName;
    bool awaitingUrl = false;

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i].trim();
      if (rawLine.isEmpty) continue;

      if (rawLine.startsWith('#EXTM3U')) {
        epgUrl = _extractAttribute(rawLine, 'url-tvg') ??
            _extractAttribute(rawLine, 'x-tvg-url');
      } else if (rawLine.startsWith('#EXTINF:')) {
        awaitingUrl = true;
        currentGroup = _extractAttribute(rawLine, 'group-title');
        currentLogo = _extractAttribute(rawLine, 'tvg-logo');
        currentTvgId = _extractAttribute(rawLine, 'tvg-id');
        currentTvgName = _extractAttribute(rawLine, 'tvg-name');

        final commaIndex = rawLine.lastIndexOf(',');
        if (commaIndex != -1 && commaIndex < rawLine.length - 1) {
          final extractedName = rawLine.substring(commaIndex + 1).trim();
          currentName = extractedName.isNotEmpty ? extractedName : currentTvgName;
        } else {
          currentName = currentTvgName;
        }
      } else if (rawLine.startsWith('#EXTGRP:')) {
        final groupFromTag = rawLine.substring(8).trim();
        if (groupFromTag.isNotEmpty) {
          currentGroup = groupFromTag;
        }
      } else if (awaitingUrl && !rawLine.startsWith('#')) {
        final streamUrl = rawLine;

        channels.add(
          M3uChannel(
            name: currentName != null && currentName.isNotEmpty
                ? currentName
                : 'Canal ${channels.length + 1}',
            streamUrl: streamUrl,
            groupTitle: currentGroup != null && currentGroup.isNotEmpty
                ? currentGroup
                : 'Outros',
            logoUrl: currentLogo,
            tvgId: currentTvgId,
            tvgName: currentTvgName,
          ),
        );

        currentName = null;
        currentGroup = null;
        currentLogo = null;
        currentTvgId = null;
        currentTvgName = null;
        awaitingUrl = false;
      }
    }

    if (channels.isEmpty) {
      throw const M3uParseException(
        'Conteúdo M3U incompatível ou nenhum canal válido encontrado no arquivo.',
      );
    }

    return M3uParseResult(
      channels: channels,
      epgUrl: epgUrl,
    );
  }

  /// Extrai o valor de um atributo específico na linha #EXTINF ou #EXTM3U.
  static String? _extractAttribute(String line, String attributeName) {
    final regex = RegExp(
      '$attributeName=(?:"([^"]*)"|\'([^\']*)\'|([^\\s,]+))',
      caseSensitive: false,
    );
    final match = regex.firstMatch(line);
    if (match != null) {
      return match.group(1) ?? match.group(2) ?? match.group(3);
    }
    return null;
  }
}
