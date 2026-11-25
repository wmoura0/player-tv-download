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

    // 1. Inspeciona tags em [...] e (...) mantendo qualificadores significativos (ex.: (US), (UK), (Mexico))
    // e removendo apenas tags técnicas de áudio/vídeo e anos (armazenados em `years`).
    String working = trimmed.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]|\(([^)]*)\)'),
      (match) {
        final innerRaw = match.group(1) ?? match.group(2) ?? '';
        final innerNorm = _normalizePunctuation(innerRaw);
        if (innerNorm.isEmpty) return ' ';

        final yearMatch = RegExp(r'^((?:19|20)\d{2})$').firstMatch(innerNorm);
        if (yearMatch != null) {
          years.add(yearMatch.group(1)!);
          return ' ';
        }

        if (_knownEditionTags.contains(innerNorm)) {
          return ' ';
        }

        // Caso contenha múltiplos tokens (ex.: "DUB 2021" ou "US FHD"), separa anos e tags conhecidas
        final tokens = innerNorm.split(' ');
        final remainingQualifiers = <String>[];
        for (final tok in tokens) {
          if (RegExp(r'^(19|20)\d{2}$').hasMatch(tok)) {
            years.add(tok);
          } else if (!_knownEditionTags.contains(tok)) {
            remainingQualifiers.add(tok);
          }
        }
        if (remainingQualifiers.isNotEmpty) {
          qualifiers.add(remainingQualifiers.join(' '));
        }
        return ' ';
      },
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

  /// Compara o título solicitado pelo usuário com `info['name']` retornado por `get_series_info`.
  static SeriesIdentityConsistency verifySeriesInfoIdentity({
    required String requestedTitle,
    required String? serverReturnedName,
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
