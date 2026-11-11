import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import 'settings_service.dart';
import 'url_sanitizer.dart';
import 'xtream_auth_service.dart';
import 'xtream_catalog_service.dart';

/// Status do resultado da resolução inteligente de fontes.
enum SmartSourceStatus {
  resolved,
  allFailed,
  skippedDisabled,
}

/// Resultado detalhado da resolução de fonte pelo SmartSourceResolver.
class SmartSourceResult {
  final SmartSourceStatus status;
  final String? workingUrl;
  final String? containerExtension;
  final int attemptsCount;
  final List<String> testedUrls;
  final String? diagnosticMessage;
  final XtreamSeriesEpisode? recoveredEpisode;
  final int? recoveredSeriesId;

  const SmartSourceResult({
    required this.status,
    this.workingUrl,
    this.containerExtension,
    this.attemptsCount = 0,
    this.testedUrls = const [],
    this.diagnosticMessage,
    this.recoveredEpisode,
    this.recoveredSeriesId,
  });

  bool get isSuccess => status == SmartSourceStatus.resolved && workingUrl != null;
}

/// Serviço inteligente de recuperação de episódios e contingência de streaming Xtream.
/// Especialmente projetado para contornar discrepâncias de extensão (.mp4 vs .mkv vs .ts),
/// inversões de ID (id vs stream_id), direct_source e erros HTTP 404 em séries longas
/// como "Diários de um Vampiro".
class SmartSourceResolver {
  static final SmartSourceResolver instance = SmartSourceResolver._internal();

  SmartSourceResolver._internal();

  /// Cache em memória das fontes comprovadamente funcionais por episódio
  /// Chave: "$seriesId-$episodeId"
  final Map<String, String> _validatedSourceCache = {};

  @visibleForTesting
  void clearCache() => _validatedSourceCache.clear();

  bool hasCachedSource(int? seriesId, int episodeId) {
    final key = '${seriesId ?? 0}-$episodeId';
    return _validatedSourceCache.containsKey(key);
  }

  String? getCachedSource(int? seriesId, int episodeId) {
    final key = '${seriesId ?? 0}-$episodeId';
    return _validatedSourceCache[key];
  }

  /// Normaliza títulos de séries para comparação resiliente, removendo anos duplicados,
  /// tags entre parênteses/colchetes e espaços supérfluos.
  static String normalizeTitle(String title) {
    return title
        .replaceAll(RegExp(r'\s*\(\d{4}\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
  }

  /// Gera a lista exaustiva e ordenada de candidatos de URL para o episódio
  List<String> generateCandidateUrls({
    required XtreamCatalogService catalogService,
    required XtreamSeriesEpisode episode,
    String? preferredExtensionOverride,
  }) {
    final cleanServer = XtreamAuthService.normalizeServerUrl(catalogService.serverUrl);
    final user = Uri.encodeComponent(catalogService.username.trim());
    final pass = Uri.encodeComponent(catalogService.password.trim());

    final preferredExtSetting = preferredExtensionOverride ??
        SettingsService.instance.preferredContainerExtension;

    // Extensões candidatas priorizadas
    final rawExt = episode.containerExtension?.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '') ?? 'mp4';
    final candidateExtensions = <String>[];

    if (preferredExtSetting != 'auto' && preferredExtSetting.isNotEmpty) {
      candidateExtensions.add(preferredExtSetting);
    }
    if (!candidateExtensions.contains(rawExt)) {
      candidateExtensions.add(rawExt);
    }
    // Adiciona extensões comuns para garantir cobertura integral
    for (final ext in ['mp4', 'mkv', 'ts']) {
      if (!candidateExtensions.contains(ext)) {
        candidateExtensions.add(ext);
      }
    }

    // IDs candidatos (id principal, alternativeEpisodeId / streamId)
    final candidateIds = <int>[episode.id];
    if (episode.streamId != null &&
        episode.streamId! > 0 &&
        episode.streamId != episode.id &&
        !candidateIds.contains(episode.streamId!)) {
      candidateIds.add(episode.streamId!);
    }

    final candidateUrls = <String>[];
    void addCandidate(String u) {
      final sanitized = u.trim();
      if (sanitized.isNotEmpty && !candidateUrls.contains(sanitized)) {
        candidateUrls.add(sanitized);
      }
    }

    // 1. Rota padrão /series/ com formatos priorizados e IDs candidatos
    for (final ext in candidateExtensions) {
      for (final epId in candidateIds) {
        addCandidate('$cleanServer/series/$user/$pass/$epId.$ext');
      }
    }

    // 2. Direct Source (se o servidor Xtream enviou direct_source no JSON do episódio)
    final direct = episode.directSource?.trim();
    if (direct != null && direct.isNotEmpty) {
      if (direct.startsWith('http://') || direct.startsWith('https://')) {
        addCandidate(direct);
      } else {
        final normDirect = direct.startsWith('/') ? direct : '/$direct';
        addCandidate('$cleanServer$normDirect');
      }
    }

    // 3. Rota legada direta sem /series/ ($serverUrl/$user/$pass/$id.$ext)
    for (final ext in candidateExtensions) {
      for (final epId in candidateIds) {
        addCandidate('$cleanServer/$user/$pass/$epId.$ext');
      }
    }

    // 4. Rota alternativa VOD /movie/ para servidores Xtream que mapeiam episódios como VOD
    for (final ext in candidateExtensions) {
      for (final epId in candidateIds) {
        addCandidate('$cleanServer/movie/$user/$pass/$epId.$ext');
      }
    }

    // 5. Contingência de protocolo HTTP <-> HTTPS caso o servidor suporte ou redirecione
    if (cleanServer.startsWith('http://')) {
      final httpsServer = cleanServer.replaceFirst('http://', 'https://');
      for (final ext in candidateExtensions) {
        addCandidate('$httpsServer/series/$user/$pass/${episode.id}.$ext');
      }
    }

    return candidateUrls;
  }

  /// Sonda uma URL candidata com requisição HTTP Range leve para validar sem crash
  Future<bool> probeUrl(
    String url, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(url);
      final req = http.Request('GET', uri)
        ..headers.addAll({
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
          'Range': 'bytes=0-1024',
          'Accept': '*/*',
        });

      final streamedResponse = await httpClient.send(req).timeout(timeout);
      final code = streamedResponse.statusCode;
      final len = streamedResponse.contentLength;

      // Status 416 (Range Not Satisfiable) confirma que o arquivo existe no servidor mas não aceita Range de 1024
      if (code == 416) {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
        return true;
      }

      // Se o servidor retornou 404, o recurso NÃO existe. NUNCA fazer fallback para HEAD!
      if (code == 404) {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
        return false;
      }

      // Respostas com Content-Length explicitamente 0 não são fluxos de mídia válidos
      if (len != null && len == 0) {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
        return false;
      }

      // Se retornou 400 (Bad Request), 405 (Method Not Allowed) ou 501 (Not Implemented) para Range GET,
      // tenta HEAD sem Range caso o proxy intermediário rejeite cabeçalhos Range.
      if (code == 400 || code == 405 || code == 501) {
        try {
          streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
          final headReq = http.Request('HEAD', uri)
            ..headers.addAll({
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
              'Accept': '*/*',
            });
          final headRes = await httpClient.send(headReq).timeout(const Duration(seconds: 2));
          final headCode = headRes.statusCode;
          headRes.stream.listen((_) {}).cancel().catchError((_) {});
          if (headCode >= 200 && headCode < 400) {
            return true;
          }
          return false;
        } catch (_) {
          return false;
        }
      } else {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
      }

      // Status 200..399 confirmam recurso existente
      final isValid = (code >= 200 && code < 400);
      return isValid;
    } catch (_) {
      return false;
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }

  /// Tenta recuperar um episódio cuja série tenha sido reindexada pelo provedor sob um novo seriesId.
  Future<SmartSourceResult?> tryRecoverReindexedEpisode({
    required XtreamCatalogService catalogService,
    required int oldSeriesId,
    required XtreamSeriesEpisode episode,
    String? seriesTitle,
    String? categoryId,
    http.Client? probeClient,
    Duration? timeout,
  }) async {
    if (seriesTitle == null || seriesTitle.trim().isEmpty) return null;

    final targetClean = normalizeTitle(seriesTitle);
    if (targetClean.isEmpty) return null;

    debugPrint('[SMART SOURCE] Tentando recuperar episódio por reindexação da série: "$seriesTitle" (ID antigo: $oldSeriesId, S${episode.seasonNumber}:E${episode.episodeNum})');

    // 1. Obtém lista atualizada da categoria (com forceRefresh para expirar cache antigo)
    List<XtreamSeriesItem> candidateSeries = [];
    try {
      if (categoryId != null && categoryId != '0' && categoryId != 'all') {
        candidateSeries = await catalogService.fetchSeries(categoryId: categoryId, forceRefresh: true);
      }
      if (candidateSeries.isEmpty) {
        candidateSeries = await catalogService.fetchSeries(categoryId: 'all');
      }
    } catch (_) {}

    final matching = candidateSeries.where((s) {
      if (s.seriesId == oldSeriesId) return false;
      final norm = normalizeTitle(s.name);
      return norm == targetClean || norm.contains(targetClean) || targetClean.contains(norm);
    }).toList();

    for (final matched in matching) {
      try {
        final info = await catalogService.fetchSeriesInfo(matched.seriesId, forceRefresh: true);
        if (info == null || info.isOrphanedOrStub) continue;

        final newEp = info.findEpisodeBySeasonAndNum(episode.seasonNumber, episode.episodeNum);
        if (newEp == null) continue;

        // Gera URLs do episódio recuperado
        final candidateUrls = generateCandidateUrls(
          catalogService: catalogService,
          episode: newEp,
        );

        for (final u in candidateUrls) {
          final ok = await probeUrl(u, client: probeClient, timeout: timeout ?? const Duration(seconds: 4));
          if (ok) {
            final ext = u.split('.').last.split('?').first.toLowerCase();
            debugPrint('[SMART SOURCE] [REINDEX SUCESSO] Episódio recuperado com sucesso! Novo SeriesID=${matched.seriesId}, Novo EpID=${newEp.id}: ${UrlSanitizer.sanitize(u)}');
            return SmartSourceResult(
              status: SmartSourceStatus.resolved,
              workingUrl: u,
              containerExtension: ext,
              recoveredEpisode: newEp,
              recoveredSeriesId: matched.seriesId,
              diagnosticMessage: 'Episódio recuperado por reindexação no provedor (Novo ID: ${newEp.id}).',
            );
          }
        }
      } catch (_) {}
    }

    return null;
  }

  /// Resolve a melhor fonte funcional para o episódio testando candidatos de forma inteligente.
  Future<SmartSourceResult> resolveBestSource({
    required XtreamCatalogService catalogService,
    required XtreamSeriesEpisode episode,
    int? seriesId,
    String? seriesName,
    String? categoryId,
    ValueChanged<String>? onProgressMessage,
    http.Client? probeClient,
    Duration? timeoutPerProbe,
  }) async {
    if (!SettingsService.instance.enableSmartSource) {
      return const SmartSourceResult(
        status: SmartSourceStatus.skippedDisabled,
        diagnosticMessage: 'Smart Source desativado nas configurações.',
      );
    }

    final cacheKey = '${seriesId ?? 0}-${episode.id}';
    final cached = _validatedSourceCache[cacheKey];
    if (cached != null) {
      debugPrint('[SMART SOURCE] [CACHE HIT] Fonte recuperada instantaneamente do cache: ${UrlSanitizer.sanitize(cached)}');
      return SmartSourceResult(
        status: SmartSourceStatus.resolved,
        workingUrl: cached,
        attemptsCount: 0,
        diagnosticMessage: 'Fonte recuperada do cache local.',
      );
    }

    final candidates = generateCandidateUrls(
      catalogService: catalogService,
      episode: episode,
    );

    final tested = <String>[];
    final timeout = timeoutPerProbe ??
        Duration(seconds: SettingsService.instance.smartSourceTimeoutSecs);

    debugPrint('[SMART SOURCE] Iniciando resolução inteligente para episódio ID=${episode.id} (T${episode.seasonNumber}:E${episode.episodeNum}). ${candidates.length} candidatos gerados.');

    for (var i = 0; i < candidates.length; i++) {
      final candidateUrl = candidates[i];
      tested.add(candidateUrl);

      final ext = candidateUrl.split('.').last.split('?').first.toLowerCase();
      onProgressMessage?.call('Recuperando fonte do episódio... (Tentativa ${i + 1}/${candidates.length} - Formato ${ext.toUpperCase()})');

      final success = await probeUrl(candidateUrl, client: probeClient, timeout: timeout);
      if (success) {
        debugPrint('[SMART SOURCE] [SUCESSO] Fonte funcional validada na tentativa ${i + 1}: ${UrlSanitizer.sanitize(candidateUrl)}');
        _validatedSourceCache[cacheKey] = candidateUrl;
        return SmartSourceResult(
          status: SmartSourceStatus.resolved,
          workingUrl: candidateUrl,
          containerExtension: ext,
          attemptsCount: i + 1,
          testedUrls: tested,
          diagnosticMessage: 'Fonte validada com sucesso no formato ${ext.toUpperCase()}.',
        );
      }
    }

    // Se todos os candidatos diretos falharam (404/indisponível), tenta verificar se a série foi reindexada
    if (seriesId != null && seriesId > 0 && seriesName != null) {
      onProgressMessage?.call('Verificando reindexação da série no catálogo...');
      final reindexed = await tryRecoverReindexedEpisode(
        catalogService: catalogService,
        oldSeriesId: seriesId,
        episode: episode,
        seriesTitle: seriesName,
        categoryId: categoryId,
        probeClient: probeClient,
        timeout: timeout,
      );
      if (reindexed != null) {
        _validatedSourceCache[cacheKey] = reindexed.workingUrl!;
        return reindexed;
      }
    }

    debugPrint('[SMART SOURCE] [FALHA] Nenhum candidato respondeu com status 200/206 após ${candidates.length} tentativas.');
    return SmartSourceResult(
      status: SmartSourceStatus.allFailed,
      attemptsCount: candidates.length,
      testedUrls: tested,
      diagnosticMessage: 'Episódio indisponível no servidor (HTTP 404). O arquivo foi removido pelo provedor.',
    );
  }
}
