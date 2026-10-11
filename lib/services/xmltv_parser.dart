import 'dart:isolate';
import '../models/epg_program.dart';

/// Resultado estruturado do processamento de um feed XMLTV.
class XmltvParseResult {
  /// Canais declarados: mapeamento de channel id -> lista de display names
  final Map<String, List<String>> channelNames;

  /// Programação agrupada por channel id
  final Map<String, List<EpgProgram>> programsByChannel;

  const XmltvParseResult({
    required this.channelNames,
    required this.programsByChannel,
  });

  static const XmltvParseResult empty = XmltvParseResult(
    channelNames: {},
    programsByChannel: {},
  );
}

/// Parser de alto desempenho em Dart puro para arquivos XMLTV (Guia de Programação).
/// Executa processamento seguro e isolado para não bloquear a thread de interface.
class XmltvParser {
  /// Decodifica entidades HTML/XML comuns
  static String unescapeXml(String input) {
    if (!input.contains('&')) return input;
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&#34;', '"');
  }

  /// Converte carimbo de data/hora padrão XMLTV (`YYYYMMDDhhmmss [+/-]ZZZZ`) para [DateTime].
  /// Trata com precisão o deslocamento de fuso horário internacional (ex.: +0000, -0300, Z).
  static DateTime? parseXmltvDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final text = raw.trim();

    // Regex para extrair YYYY MM DD hh mm [ss] [offset]
    final reg = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-]\d{4}|Z)?$');
    final match = reg.firstMatch(text);
    if (match == null) {
      // Fallback para ISO-8601 comum se fornecido em formato ISO
      return DateTime.tryParse(text);
    }

    try {
      final year = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final day = int.parse(match.group(3)!);
      final hour = int.parse(match.group(4)!);
      final minute = int.parse(match.group(5)!);
      final second = match.group(6) != null ? int.parse(match.group(6)!) : 0;
      final tz = match.group(7);

      if (tz == null || tz == 'Z') {
        // Se explicitamente 'Z' ou sem offset, trata como UTC
        return DateTime.utc(year, month, day, hour, minute, second);
      }

      // Trata offset no formato +HHMM ou -HHMM
      final sign = tz.startsWith('-') ? -1 : 1;
      final offsetClean = tz.replaceAll(RegExp(r'[+-]'), '');
      if (offsetClean.length == 4) {
        final tzHour = int.parse(offsetClean.substring(0, 2));
        final tzMin = int.parse(offsetClean.substring(2, 4));
        final offsetDuration = Duration(hours: tzHour, minutes: tzMin) * sign;

        // Horário fornecido menos o offset = Horário UTC correspondente
        final dtUtc = DateTime.utc(year, month, day, hour, minute, second).subtract(offsetDuration);
        return dtUtc;
      }

      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// Realiza o parsing de uma string XMLTV completa.
  /// Se o conteúdo for grande (> 100 KB), desvia automaticamente para Isolate.run.
  static Future<XmltvParseResult> parse(String xmlContent) async {
    if (xmlContent.trim().isEmpty) return XmltvParseResult.empty;

    if (xmlContent.length > 100000) {
      try {
        return await Isolate.run(() => _parseSync(xmlContent));
      } catch (_) {
        // Fallback síncrono em caso de ambiente sem suporte a Isolate.run
        return _parseSync(xmlContent);
      }
    }

    return _parseSync(xmlContent);
  }

  /// Motor de parsing síncrono para XMLTV
  static XmltvParseResult _parseSync(String content) {
    if (!content.contains('<tv') && !content.contains('<programme')) {
      return XmltvParseResult.empty;
    }

    final channelNames = <String, List<String>>{};
    final programsByChannel = <String, List<EpgProgram>>{};

    // 1. Extração de canais: <channel id="..."> ... <display-name>...</display-name> ... </channel>
    final channelRegex = RegExp(
      r'<channel\s+[^>]*id=["\x27]([^"\x27]+)["\x27][^>]*>(.*?)<\/channel>',
      dotAll: true,
      caseSensitive: false,
    );

    final displayNameRegex = RegExp(
      r'<display-name[^>]*>(.*?)<\/display-name>',
      dotAll: true,
      caseSensitive: false,
    );

    for (final m in channelRegex.allMatches(content)) {
      final chId = m.group(1)?.trim();
      if (chId == null || chId.isEmpty) continue;

      final body = m.group(2) ?? '';
      final names = <String>[];
      for (final nameMatch in displayNameRegex.allMatches(body)) {
        final name = unescapeXml(nameMatch.group(1)?.trim() ?? '');
        if (name.isNotEmpty && !names.contains(name)) {
          names.add(name);
        }
      }
      channelNames[chId] = names;
    }

    // 2. Extração de programas: <programme start="..." stop="..." channel="..."> ... </programme>
    final programmeRegex = RegExp(
      r'<programme\s+([^>]*?)>(.*?)<\/programme>',
      dotAll: true,
      caseSensitive: false,
    );

    final titleRegex = RegExp(r'<title[^>]*>(.*?)<\/title>', dotAll: true, caseSensitive: false);
    final descRegex = RegExp(r'<desc[^>]*>(.*?)<\/desc>', dotAll: true, caseSensitive: false);

    for (final progMatch in programmeRegex.allMatches(content)) {
      final attrs = progMatch.group(1) ?? '';
      final body = progMatch.group(2) ?? '';

      final startStr = _extractAttr(attrs, 'start');
      final stopStr = _extractAttr(attrs, 'stop');
      final channelId = _extractAttr(attrs, 'channel');

      if (channelId == null || channelId.isEmpty) continue;

      final titleMatch = titleRegex.firstMatch(body);
      final rawTitle = titleMatch != null ? unescapeXml(titleMatch.group(1)?.trim() ?? '') : '';
      final title = rawTitle.isNotEmpty ? rawTitle : 'Sem título';

      final descMatch = descRegex.firstMatch(body);
      final desc = descMatch != null ? unescapeXml(descMatch.group(1)?.trim() ?? '') : null;

      final startTime = parseXmltvDate(startStr);
      final endTime = parseXmltvDate(stopStr);

      // Tratamento de horários inconsistentes: se fim for anterior ao início, descarta horário final inválido
      DateTime? safeEnd = endTime;
      if (startTime != null && safeEnd != null && safeEnd.isBefore(startTime)) {
        safeEnd = null;
      }

      final program = EpgProgram(
        channelId: channelId,
        title: title,
        description: desc?.isNotEmpty == true ? desc : null,
        startTime: startTime,
        endTime: safeEnd,
      );

      programsByChannel.putIfAbsent(channelId, () => []).add(program);
    }

    // Ordenar programas de cada canal por horário de início
    for (final list in programsByChannel.values) {
      list.sort((a, b) {
        if (a.startTime == null && b.startTime == null) return 0;
        if (a.startTime == null) return 1;
        if (b.startTime == null) return -1;
        return a.startTime!.compareTo(b.startTime!);
      });
    }

    return XmltvParseResult(
      channelNames: channelNames,
      programsByChannel: programsByChannel,
    );
  }

  static String? _extractAttr(String text, String attrName) {
    final reg = RegExp('$attrName=["\x27]([^"\x27]+)["\x27]', caseSensitive: false);
    final m = reg.firstMatch(text);
    return m?.group(1)?.trim();
  }
}
