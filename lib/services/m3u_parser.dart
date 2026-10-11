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

/// Parser de listas M3U/M3U8 com extração de canais, categorias e logos.
class M3uParser {
  /// Baixa o conteúdo M3U a partir de uma URL e faz o parsing dos canais.
  static Future<List<M3uChannel>> fetchAndParse(
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

      // Decodificação flexível para UTF-8 (removendo BOM se presente) ou latin1
      String content;
      try {
        content = utf8.decode(response.bodyBytes);
      } catch (_) {
        content = latin1.decode(response.bodyBytes);
      }

      return parse(content);
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
    if (content.trim().isEmpty) {
      throw const M3uParseException('O conteúdo da lista está vazio.');
    }

    // Limpa BOM (Byte Order Mark) se presente
    final cleanContent = content.startsWith('\uFEFF') ? content.substring(1) : content;
    final lines = const LineSplitter().convert(cleanContent);

    final channels = <M3uChannel>[];

    // Variáveis temporárias para armazenar os atributos do canal atual
    String? currentName;
    String? currentGroup;
    String? currentLogo;
    String? currentTvgId;
    String? currentTvgName;
    bool awaitingUrl = false;

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i].trim();
      if (rawLine.isEmpty) continue;

      if (rawLine.startsWith('#EXTINF:')) {
        awaitingUrl = true;
        currentGroup = _extractAttribute(rawLine, 'group-title');
        currentLogo = _extractAttribute(rawLine, 'tvg-logo');
        currentTvgId = _extractAttribute(rawLine, 'tvg-id');
        currentTvgName = _extractAttribute(rawLine, 'tvg-name');

        // O nome do canal é tudo após a última vírgula da linha #EXTINF
        final commaIndex = rawLine.lastIndexOf(',');
        if (commaIndex != -1 && commaIndex < rawLine.length - 1) {
          final extractedName = rawLine.substring(commaIndex + 1).trim();
          currentName = extractedName.isNotEmpty ? extractedName : currentTvgName;
        } else {
          currentName = currentTvgName;
        }
      } else if (rawLine.startsWith('#EXTGRP:')) {
        // Suporte opcional à tag alternativa de grupo #EXTGRP
        final groupFromTag = rawLine.substring(8).trim();
        if (groupFromTag.isNotEmpty) {
          currentGroup = groupFromTag;
        }
      } else if (awaitingUrl && !rawLine.startsWith('#')) {
        // Encontramos a linha com a URL do stream
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

        // Resetar para o próximo canal
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

    return channels;
  }

  /// Extrai o valor de um atributo específico na linha #EXTINF.
  static String? _extractAttribute(String line, String attributeName) {
    // Procura por attributeName="valor" ou attributeName='valor' ou attributeName=valor
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
