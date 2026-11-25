import 'package:flutter/foundation.dart';
import '../models/xtream_catalog.dart';

/// Grau de consistência entre a série solicitada e o retorno de `get_series_info`.
enum SeriesIdentityConsistency {
  verifiedExact,
  verifiedNormalized,
  unverifiedMissingServerName,
  mismatch,
  notApplicable,
}

/// Componentes estruturados de um título de série/filme para comparação estrita.
@immutable
class SeriesTitleParts {
  final String canonicalBase;
  final Set<String> years;
  final Set<String> qualifiers;

  const SeriesTitleParts({
    required this.canonicalBase,
    required this.years,
    required this.qualifiers,
  });
}

/// Utilitário estrito de verificação de identidade de séries.
///
/// Garante que:
/// - Não haja associação por substring parcial (`.contains()`);
/// - Não haja desambiguação baseada em `rating`;
/// - Correspondências ambíguas nunca sejam selecionadas automaticamente;
/// - Qualificadores distintos (ex.: `(US)` vs `(UK)`, spin-offs, reboot com ano distinto) sejam preservados.
class SeriesIdentityVerifier {
  static const Set<String> _knownEditionTags = {
    'l',
    'leg',
    'legendado',
    'legendada',
    'dub',
    'dublado',
    'dublada',
    'dual',
    'dual audio',
    'dualaudio',
    'multi',
    'multi audio',
    'multiaudio',
    'hd',
    'fhd',
    'uhd',
    '4k',
    '8k',
    'sd',
    'cam',
    'h265',
    'h264',
    'x265',
    'x264',
    'hevc',
    '1080p',
    '720p',
    '2160p',
    'nacional',
    'completo',
    'completa',
    'temporada completa',
    'pt',
    'pt br',
    'ptbr',
    'sub',
    'subtitulado',
    'subtitulada',
    'serie',
    'series',
    'netflix',
    'prime',
    'prime video',
    'amazon',
    'amazon prime',
    'disney',
    'disney plus',
    'hbo',
    'hbo max',
    'max',
    'apple',
    'apple tv',
    'apple tv plus',
    'globoplay',
    'paramount',
    'paramount plus',
    'star',
    'star plus',
    'starz',
    'crunchyroll',
    'discovery',
    'vip',
    'lancamento',
    'lancamentos',
    'novo',
    'novidade',
    'br',
    'bra',
    'en',
    'eng',
    'es',
    'esp',
    'lat',
    'latino',
    'ing',
    'ingles',
    'portugues',
    'dub leg',
    'dub e leg',
    'dublado legendado',
    'hdr',
    'hdr10',
    'dolby',
    'atmos',
    'web',
    'web dl',
    'webdl',
    'bluray',
    'blu ray',
    'hdcam',
    '4k uhd',
    'uhd 4k',
    'fhd 4k',
  };

  /// Remove acentos/diacríticos comuns do português, espanhol e inglês.
  static String stripDiacritics(String input) {
    if (input.isEmpty) return input;
    const mapping = <String, String>{
      'á': 'a',
      'à': 'a',
      'â': 'a',
      'ã': 'a',
      'ä': 'a',
      'å': 'a',
      'Á': 'A',
      'À': 'A',
      'Â': 'A',
      'Ã': 'A',
      'Ä': 'A',
      'Å': 'A',
      'é': 'e',
      'è': 'e',
      'ê': 'e',
      'ë': 'e',
      'É': 'E',
      'È': 'E',
      'Ê': 'E',
      'Ë': 'E',
      'í': 'i',
      'ì': 'i',
      'î': 'i',
      'ï': 'i',
      'Í': 'I',
      'Ì': 'I',
      'Î': 'I',
      'Ï': 'I',
      'ó': 'o',
      'ò': 'o',
      'ô': 'o',
      'õ': 'o',
      'ö': 'o',
      'Ó': 'O',
      'Ò': 'O',
      'Ô': 'O',
      'Õ': 'O',
      'Ö': 'O',
      'ú': 'u',
      'ù': 'u',
      'û': 'u',
      'ü': 'u',
      'Ú': 'U',
      'Ù': 'U',
      'Û': 'U',
      'Ü': 'U',
      'ç': 'c',
      'Ç': 'C',
      'ñ': 'n',
      'Ñ': 'N',
      'ý': 'y',
      'ÿ': 'y',
      'Ý': 'Y',
    };

    final buf = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      buf.write(mapping[ch] ?? ch);
    }
    return buf.toString();
  }

  static String _normalizePunctuation(String raw) {
    return stripDiacritics(raw)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isTechnicalOnlySegment(String normSegment, Set<String> yearsOut) {
    if (normSegment.isEmpty) return true;
    if (RegExp(r'^((?:19|20)\d{2})$').hasMatch(normSegment)) {
      yearsOut.add(normSegment);
      return true;
    }
    if (_knownEditionTags.contains(normSegment)) {
      return true;
    }
    final tokens = normSegment.split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return true;

    final localYears = <String>{};
    var i = 0;
    while (i < tokens.length) {
      var matchedLen = 0;
      for (final len in const [3, 2, 1]) {
        if (i + len <= tokens.length) {
          final phrase = tokens.sublist(i, i + len).join(' ');
          if (_knownEditionTags.contains(phrase)) {
            matchedLen = len;
            break;
          }
        }
      }
      if (matchedLen > 0) {
        i += matchedLen;
        continue;
      }
      if (RegExp(r'^(?:19|20)\d{2}$').hasMatch(tokens[i])) {
        localYears.add(tokens[i]);
        i++;
        continue;
      }
      return false;
    }
    yearsOut.addAll(localYears);
    return true;
  }

  static String _stripBracketsAndTechnicalSuffixes(
    String raw, {
    required Set<String> years,
    required Set<String> qualifiers,
  }) {
    // 1. Inspeciona tags em [...] e (...) mantendo qualificadores significativos (ex.: (US), (UK), (Mexico))
    // e removendo apenas tags técnicas de áudio/vídeo/streaming e anos (armazenados em `years`).
    String working = raw.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]|\(([^)]*)\)'),
      (match) {
        final innerRaw = match.group(1) ?? match.group(2) ?? '';
        final innerNorm = _normalizePunctuation(innerRaw);
        if (innerNorm.isEmpty) return ' ';

        if (_isTechnicalOnlySegment(innerNorm, years)) {
          return ' ';
        }

        // Mantém tokens não técnicos como qualificador estrutural
        final tokens = innerNorm.split(' ').where((t) => t.isNotEmpty).toList();
        final remainingQualifiers = <String>[];
        var i = 0;
        while (i < tokens.length) {
          var matchedLen = 0;
          for (final len in const [3, 2, 1]) {
            if (i + len <= tokens.length &&
                _knownEditionTags.contains(tokens.sublist(i, i + len).join(' '))) {
              matchedLen = len;
              break;
            }
          }
          if (matchedLen > 0) {
            i += matchedLen;
          } else if (RegExp(r'^(?:19|20)\d{2}$').hasMatch(tokens[i])) {
            years.add(tokens[i]);
            i++;
          } else {
            remainingQualifiers.add(tokens[i]);
            i++;
          }
        }
        if (remainingQualifiers.isNotEmpty) {
          qualifiers.add(remainingQualifiers.join(' '));
        }
        return ' ';
      },
    );

    // 2. Remove sufixos técnicos após separadores '|' ou ' - ' (ex.: "- Dublado | 4K UHD")
    while (true) {
      final pipeIdx = working.lastIndexOf('|');
      final dashIdx = working.lastIndexOf(' - ');
      final int sepIdx;
      final int sepLen;
      if (pipeIdx > dashIdx) {
        sepIdx = pipeIdx;
        sepLen = 1;
      } else if (dashIdx >= 0) {
        sepIdx = dashIdx;
        sepLen = 3;
      } else {
        break;
      }

      final prefix = working.substring(0, sepIdx).trim();
      final suffix = working.substring(sepIdx + sepLen).trim();
      if (prefix.isEmpty) break;
      final normSuffix = _normalizePunctuation(suffix);
      if (_isTechnicalOnlySegment(normSuffix, years)) {
        working = prefix;
      } else {
        break;
      }
    }

    return working;
  }

  /// Extrai base canônica, anos explícitos e qualificadores não-técnicos de um título.
  static SeriesTitleParts parseTitleParts(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return const SeriesTitleParts(
        canonicalBase: '',
        years: <String>{},
        qualifiers: <String>{},
      );
    }

    final years = <String>{};
    final qualifiers = <String>{};

    final working = _stripBracketsAndTechnicalSuffixes(
      trimmed,
      years: years,
      qualifiers: qualifiers,
    );

    // 2. Extrai eventual ano solto no final ou no meio do título se houver texto restante além do ano
    var baseBeforeYear = _normalizePunctuation(working);
    final trailingYears = RegExp(r'\b((?:19|20)\d{2})\b').allMatches(baseBeforeYear).toList();
    if (trailingYears.isNotEmpty) {
      final candidateWithoutYears = baseBeforeYear
          .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (candidateWithoutYears.isNotEmpty) {
        for (final m in trailingYears) {
          years.add(m.group(1)!);
        }
        baseBeforeYear = candidateWithoutYears;
      } else {
        // Título cujo nome próprio é um ano (ex.: "1883", "1923", "2012")
        for (final m in trailingYears) {
          years.add(m.group(1)!);
        }
      }
    }

    return SeriesTitleParts(
      canonicalBase: baseBeforeYear,
      years: Set<String>.unmodifiable(years),
      qualifiers: Set<String>.unmodifiable(qualifiers),
    );
  }

  /// Verifica de forma estrita se dois títulos representam a MESMA série.
  /// Nunca utiliza comparação por substring (`.contains()`).
  static bool areSameSeriesIdentity(String titleA, String titleB) {
    final a = parseTitleParts(titleA);
    final b = parseTitleParts(titleB);

    if (a.canonicalBase.isEmpty || b.canonicalBase.isEmpty) {
      return false;
    }
    if (a.canonicalBase != b.canonicalBase) {
      return false;
    }

    // Qualificadores distintos como (US) vs (UK) ou '' vs (Mexico) impedem associação
    if (a.qualifiers.length != b.qualifiers.length ||
        !a.qualifiers.containsAll(b.qualifiers)) {
      return false;
    }

    // Se ambas informam anos explícitos e não há interseção (ex.: reboot 2007 vs 2021), rejeita
    if (a.years.isNotEmpty && b.years.isNotEmpty) {
      final intersects = a.years.any(b.years.contains);
      if (!intersects) {
        return false;
      }
    }

    return true;
  }

  static String? _normalizeCoverUrl(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'null') return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return trimmed.toLowerCase();
    }
    final normalizedPath = parsed.path == '/' ? '' : parsed.path;
    final queryPart = parsed.hasQuery ? '?${parsed.query}' : '';
    return '${parsed.host.toLowerCase()}$normalizedPath$queryPart';
  }

  static bool _matchesBasePlusSubtitle(String reqTitle, String srvTitle) {
    final yearsA = <String>{};
    final qualsA = <String>{};
    final yearsB = <String>{};
    final qualsB = <String>{};

    final cleanA = _stripBracketsAndTechnicalSuffixes(
      reqTitle.trim(),
      years: yearsA,
      qualifiers: qualsA,
    );
    final cleanB = _stripBracketsAndTechnicalSuffixes(
      srvTitle.trim(),
      years: yearsB,
      qualifiers: qualsB,
    );

    if (qualsA.length != qualsB.length || !qualsA.containsAll(qualsB)) {
      return false;
    }
    if (yearsA.isNotEmpty && yearsB.isNotEmpty && !yearsA.any(yearsB.contains)) {
      return false;
    }

    final sepRegex = RegExp(r'\s*:\s+|\s+-\s+');
    final matchA = sepRegex.firstMatch(cleanA);
    final matchB = sepRegex.firstMatch(cleanB);
    if ((matchA != null) == (matchB != null)) {
      return false;
    }

    final mainA = _normalizePunctuation(
      matchA != null ? cleanA.substring(0, matchA.start) : cleanA,
    );
    final mainB = _normalizePunctuation(
      matchB != null ? cleanB.substring(0, matchB.start) : cleanB,
    );
    return mainA.isNotEmpty && mainA == mainB;
  }

  /// Compara o título solicitado pelo usuário com `info['name']` retornado por `get_series_info`.
  static SeriesIdentityConsistency verifySeriesInfoIdentity({
    required String requestedTitle,
    required String? serverReturnedName,
    String? expectedCoverUrl,
    String? serverReturnedCoverUrl,
  }) {
    final reqTrimmed = requestedTitle.trim();
    if (reqTrimmed.isEmpty) {
      return SeriesIdentityConsistency.notApplicable;
    }

    final srvTrimmed = serverReturnedName?.trim() ?? '';
    if (srvTrimmed.isEmpty || srvTrimmed == 'Série sem título') {
      return SeriesIdentityConsistency.unverifiedMissingServerName;
    }

    if (stripDiacritics(reqTrimmed).toLowerCase() ==
        stripDiacritics(srvTrimmed).toLowerCase()) {
      return SeriesIdentityConsistency.verifiedExact;
    }

    if (areSameSeriesIdentity(reqTrimmed, srvTrimmed)) {
      return SeriesIdentityConsistency.verifiedNormalized;
    }

    final expectedCover = _normalizeCoverUrl(expectedCoverUrl);
    final returnedCover = _normalizeCoverUrl(serverReturnedCoverUrl);
    if (expectedCover != null &&
        returnedCover != null &&
        expectedCover == returnedCover) {
      return SeriesIdentityConsistency.verifiedNormalized;
    }

    if (_matchesBasePlusSubtitle(reqTrimmed, srvTrimmed)) {
      return SeriesIdentityConsistency.verifiedNormalized;
    }

    return SeriesIdentityConsistency.mismatch;
  }

  /// Seleciona APENAS uma correspondência inequívoca para [target] dentre [candidates].
  ///
  /// - Nunca usa `rating` como evidência de identidade.
  /// - Nunca aceita correspondência parcial por substring.
  /// - Quando houver múltiplos candidatos com o mesmo título canônico, desambigua somente
  ///   por capa idêntica única ou mesma categoria válida única; caso contrário retorna `null`.
  static XtreamSeriesItem? findUnambiguousSeriesMatch({
    required XtreamSeriesItem target,
    required Iterable<XtreamSeriesItem> candidates,
    bool excludeSameId = true,
  }) {
    final dedupById = <int, XtreamSeriesItem>{};
    for (final c in candidates) {
      if (excludeSameId && c.seriesId == target.seriesId) {
        continue;
      }
      if (!areSameSeriesIdentity(target.name, c.name)) {
        continue;
      }
      if (c.seriesId > 0) {
        dedupById.putIfAbsent(c.seriesId, () => c);
      }
    }
    final matching = dedupById.values.toList(growable: false);

    if (matching.isEmpty) return null;
    if (matching.length == 1) return matching.first;

    // Tentativa estrita de desambiguação sem rating e sem escolha arbitrária:
    // 1. Capa exatamente igual e não vazia em apenas 1 candidato
    final targetCover = target.cover?.trim() ?? '';
    if (targetCover.isNotEmpty) {
      final byCover = matching
          .where((c) => (c.cover?.trim() ?? '') == targetCover)
          .toList();
      if (byCover.length == 1) {
        return byCover.first;
      }
    }

    // 2. Mesma categoria válida ('0'/'all' ignorados) em apenas 1 candidato
    final targetCat = target.categoryId.trim();
    if (targetCat.isNotEmpty && targetCat != '0' && targetCat != 'all') {
      final byCat = matching.where((c) => c.categoryId.trim() == targetCat).toList();
      if (byCat.length == 1) {
        return byCat.first;
      }
    }

    // Permanece ambíguo: rejeitar em vez de escolher o primeiro da lista!
    return null;
  }
}
