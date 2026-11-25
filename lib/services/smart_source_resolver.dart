import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../models/xtream_vod_info.dart';
import 'player_diagnostics.dart';
import 'series_identity_verifier.dart';
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

class _ProbeAttemptOutcome {
  final bool ok;
  final int? statusCode;
  final String? errorKind;

  const _ProbeAttemptOutcome({
    required this.ok,
    this.statusCode,
    this.errorKind,
  });
}

/// Serviço inteligente de recuperação de episódios e contingência de streaming Xtream.
/// Especialmente projetado para contornar discrepâncias de extensão (.mp4 vs .mkv vs .ts),
/// inversões de ID (id vs stream_id), direct_source e erros HTTP 404 em séries longas
/// como "Diários de um Vampiro".
class SmartSourceResolver {
  static final SmartSourceResolver instance = SmartSourceResolver._internal();
  static const int _maxValidatedCacheEntries = 200;

  SmartSourceResolver._internal();

  /// Cache em memória das fontes comprovadamente funcionais por conta e episódio.
  final Map<String, String> _validatedSourceCache = {};

  /// Limpa todas as fontes em cache (obrigatório ao trocar de conta/usuário ou limpar sessão).
  void clearCache() => _validatedSourceCache.clear();

  void _putValidatedCache(String key, String url) {
    _validatedSourceCache.remove(key);
    _validatedSourceCache[key] = url;
    while (_validatedSourceCache.length > _maxValidatedCacheEntries) {
      _validatedSourceCache.remove(_validatedSourceCache.keys.first);
    }
  }

  String _episodeCacheKey(
    int? seriesId,
    int episodeId, {
    XtreamCatalogService? catalogService,
  }) {
    final epPart = '${seriesId ?? 0}-$episodeId';
    if (catalogService != null) {
      return '${catalogService.accountCacheKey}#$epPart';
    }
    return epPart;
  }

  String _vodCacheKey(
    int streamId, {
    XtreamCatalogService? catalogService,
  }) {
    final vodPart = 'vod-$streamId';
    if (catalogService != null) {
      return '${catalogService.accountCacheKey}#$vodPart';
    }
    return vodPart;
  }

  bool hasCachedSource(
    int? seriesId,
    int episodeId, {
    XtreamCatalogService? catalogService,
  }) {
    if (catalogService != null) {
      return _validatedSourceCache.containsKey(
        _episodeCacheKey(seriesId, episodeId, catalogService: catalogService),
      );
    }
    final legacyKey = '${seriesId ?? 0}-$episodeId';
    if (_validatedSourceCache.containsKey(legacyKey)) return true;
    return _validatedSourceCache.keys.any((k) => k.endsWith('#$legacyKey'));
  }

  String? getCachedSource(
    int? seriesId,
    int episodeId, {
    XtreamCatalogService? catalogService,
  }) {
    if (catalogService != null) {
      return _validatedSourceCache[
        _episodeCacheKey(seriesId, episodeId, catalogService: catalogService)
      ];
    }
    final legacyKey = '${seriesId ?? 0}-$episodeId';
    if (_validatedSourceCache.containsKey(legacyKey)) {
      return _validatedSourceCache[legacyKey];
    }
    for (final entry in _validatedSourceCache.entries) {
      if (entry.key.endsWith('#$legacyKey')) {
        return entry.value;
      }
    }
    return null;
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
    final outcome = await _probeUrlDetailed(url, client: client, timeout: timeout);
    return outcome.ok;
  }

  Future<_ProbeAttemptOutcome> _probeUrlDetailed(
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
        return _ProbeAttemptOutcome(ok: true, statusCode: code);
      }

      // Se o servidor retornou 404, o recurso NÃO existe. NUNCA fazer fallback para HEAD!
      if (code == 404) {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
        return _ProbeAttemptOutcome(ok: false, statusCode: code, errorKind: 'http_404');
      }

      if (code == 401 || code == 403) {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
        PlayerDiagnostics.log('SMART_SOURCE_PROBE', 'Acesso negado na sonda (HTTP $code).');
        return _ProbeAttemptOutcome(ok: false, statusCode: code, errorKind: 'http_auth');
      }

      // Respostas com Content-Length explicitamente 0 não são fluxos de mídia válidos
      if (len != null && len == 0) {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
        return _ProbeAttemptOutcome(ok: false, statusCode: code, errorKind: 'empty_body');
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
          final headClHeader = headRes.headers['content-length'];
          final isExplicitZeroHead = headClHeader != null && int.tryParse(headClHeader) == 0;
          headRes.stream.listen((_) {}).cancel().catchError((_) {});
          if (headCode >= 200 && headCode < 400 && !isExplicitZeroHead) {
            return _ProbeAttemptOutcome(ok: true, statusCode: headCode);
          }
          return _ProbeAttemptOutcome(ok: false, statusCode: headCode, errorKind: 'head_failed');
        } catch (e) {
          PlayerDiagnostics.log('SMART_SOURCE_PROBE', 'Falha HEAD fallback: ${e.runtimeType}');
          return const _ProbeAttemptOutcome(ok: false, errorKind: 'network');
        }
      } else {
        streamedResponse.stream.listen((_) {}).cancel().catchError((_) {});
      }

      // Status 200..399 confirmam recurso existente, exceto se Content-Length for explicitamente 0
      final clHeader = streamedResponse.headers['content-length'];
      final isExplicitZero = clHeader != null && int.tryParse(clHeader) == 0;
      final isValid = (code >= 200 && code < 400) && !isExplicitZero;
      return _ProbeAttemptOutcome(
        ok: isValid,
        statusCode: code,
        errorKind: isValid ? null : (isExplicitZero ? 'empty_body' : 'http_$code'),
      );
    } on TimeoutException {
      PlayerDiagnostics.log('SMART_SOURCE_PROBE', 'Timeout durante sondagem de fonte.');
      return const _ProbeAttemptOutcome(ok: false, errorKind: 'timeout');
    } catch (e) {
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      PlayerDiagnostics.log('SMART_SOURCE_PROBE', 'Erro na sondagem (${e.runtimeType}): $safeErr');
      return const _ProbeAttemptOutcome(ok: false, errorKind: 'network');
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }

  String _summarizeFailedProbes(List<_ProbeAttemptOutcome> outcomes) {
    if (outcomes.isEmpty) {
      return 'Nenhuma rota candidata disponível para este conteúdo.';
    }
    if (outcomes.any((o) => o.statusCode == 401 || o.statusCode == 403)) {
      return 'Acesso negado pelo servidor de streaming (HTTP 401/403).';
    }
    if (outcomes.any((o) => o.statusCode != null && o.statusCode! >= 500)) {
      return 'Servidor de streaming indisponível (erro interno HTTP 5xx).';
    }
    if (outcomes.every((o) => o.errorKind == 'timeout' || o.errorKind == 'network')) {
      return 'Falha de rede ou timeout ao tentar acessar todas as rotas.';
    }
    if (outcomes.any((o) => o.statusCode == 404)) {
      return 'Conteúdo indisponível no servidor (HTTP 404). O arquivo foi removido ou reindexado.';
    }
    return 'Não foi possível validar nenhuma rota de reprodução para este conteúdo.';
  }

  /// Tenta recuperar um episódio cuja série tenha sido reindexada pelo provedor sob um novo seriesId
  /// ou cujos episódios tenham recebido novos IDs de transmissão dentro da mesma série.
  ///
  /// Nunca utiliza correspondência parcial por substring ou `rating`, e nunca seleciona
  /// candidatos ambíguos ou séries com nome incompatível em `get_series_info`.
  Future<SmartSourceResult?> tryRecoverReindexedEpisode({
    required XtreamCatalogService catalogService,
    required int oldSeriesId,
    required XtreamSeriesEpisode episode,
    String? seriesTitle,
    String? categoryId,
    http.Client? probeClient,
    Duration? timeout,
    Set<String>? alreadyFailedUrls,
  }) async {
    final timeoutDur = timeout ?? const Duration(seconds: 4);

    // 1. PRIMEIRO PASSO: Verificar se os episódios foram reindexados dentro da própria série existente
    if (oldSeriesId > 0) {
      try {
        debugPrint('[SMART SOURCE] [REINDEX] Verificando novos IDs de episódios na série ID=$oldSeriesId...');
        final freshResult = await catalogService.fetchSeriesInfoDetailed(
          oldSeriesId,
          forceRefresh: true,
          expectedSeriesName: seriesTitle,
        );
        final freshInfo = freshResult.info;
        if (freshResult.identityConsistency != SeriesIdentityConsistency.mismatch &&
            freshInfo != null &&
            !freshInfo.isOrphanedOrStub) {
          final refreshedEp = freshInfo.findEpisodeBySeasonAndNum(
            episode.seasonNumber,
            episode.episodeNum,
          );
          final hasMetadataChanged = refreshedEp != null &&
              (refreshedEp.id != episode.id ||
                  refreshedEp.streamId != episode.streamId ||
                  refreshedEp.containerExtension != episode.containerExtension ||
                  refreshedEp.directSource != episode.directSource);
          if (hasMetadataChanged) {
            final candidateUrls = generateCandidateUrls(
              catalogService: catalogService,
              episode: refreshedEp,
            );
            for (final u in candidateUrls) {
              if (alreadyFailedUrls != null && alreadyFailedUrls.contains(u)) {
                continue;
              }
              final ok = await probeUrl(u, client: probeClient, timeout: timeoutDur);
              if (ok) {
                final ext = u.split('.').last.split('?').first.toLowerCase();
                debugPrint('[SMART SOURCE] [REINDEX SUCESSO] Episódio recuperado na mesma série! SeriesID=$oldSeriesId, Novo EpID=${refreshedEp.id}: ${UrlSanitizer.sanitize(u)}');
                return SmartSourceResult(
                  status: SmartSourceStatus.resolved,
                  workingUrl: u,
                  containerExtension: ext,
                  recoveredEpisode: refreshedEp,
                  recoveredSeriesId: oldSeriesId,
                  diagnosticMessage: 'Episódio recuperado por reindexação interna na série (Novo ID: ${refreshedEp.id}).',
                );
              }
            }
          }
        }
      } catch (e) {
        PlayerDiagnostics.log(
          'SMART_SOURCE_REINDEX',
          'Falha ao consultar série original na tentativa de reindexação: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
        );
      }
    }

    if (seriesTitle == null || seriesTitle.trim().isEmpty) return null;

    final targetItem = XtreamSeriesItem(
      seriesId: oldSeriesId,
      name: seriesTitle,
      categoryId: categoryId ?? '0',
    );
    if (SeriesIdentityVerifier.parseTitleParts(seriesTitle).canonicalBase.isEmpty) {
      return null;
    }

    debugPrint('[SMART SOURCE] Tentando recuperar episódio por reindexação da série (ID antigo: $oldSeriesId, S${episode.seasonNumber}:E${episode.episodeNum})');

    // 2. SEGUNDO PASSO: Busca correspondência estrita e inequívoca em caso de mudança de seriesId
    XtreamSeriesItem? matched;

    final cachedUnion = catalogService.getAllCachedSeriesUnionSync();
    if (cachedUnion.isNotEmpty) {
      matched = SeriesIdentityVerifier.findUnambiguousSeriesMatch(
        target: targetItem,
        candidates: cachedUnion,
      );
    }

    if (matched == null && categoryId != null && categoryId != '0' && categoryId != 'all') {
      try {
        final catList = await catalogService.fetchSeries(categoryId: categoryId, forceRefresh: true);
        matched = SeriesIdentityVerifier.findUnambiguousSeriesMatch(
          target: targetItem,
          candidates: catList,
        );
      } catch (e) {
        PlayerDiagnostics.log(
          'SMART_SOURCE_REINDEX',
          'Falha ao consultar categoria $categoryId: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
        );
      }
    }

    if (matched == null) {
      try {
        final allList = await catalogService.fetchSeries(categoryId: 'all', forceRefresh: true);
        matched = SeriesIdentityVerifier.findUnambiguousSeriesMatch(
          target: targetItem,
          candidates: allList,
        );
      } catch (e) {
        PlayerDiagnostics.log(
          'SMART_SOURCE_REINDEX',
          'Falha ao consultar catálogo geral: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
        );
      }
    }

    if (matched == null) {
      return null;
    }

    try {
      final infoResult = await catalogService.fetchSeriesInfoDetailed(
        matched.seriesId,
        forceRefresh: true,
        expectedSeriesName: seriesTitle,
      );
      final info = infoResult.info;
      if (infoResult.identityConsistency == SeriesIdentityConsistency.mismatch ||
          info == null ||
          info.isOrphanedOrStub) {
        return null;
      }

      final newEp = info.findEpisodeBySeasonAndNum(episode.seasonNumber, episode.episodeNum);
      if (newEp == null) return null;

      final candidateUrls = generateCandidateUrls(
        catalogService: catalogService,
        episode: newEp,
      );

      for (final u in candidateUrls) {
        if (alreadyFailedUrls != null && alreadyFailedUrls.contains(u)) {
          continue;
        }
        final ok = await probeUrl(u, client: probeClient, timeout: timeoutDur);
        if (ok) {
          final ext = u.split('.').last.split('?').first.toLowerCase();
          debugPrint('[SMART SOURCE] [REINDEX SUCESSO] Episódio recuperado em série reindexada! Novo SeriesID=${matched.seriesId}, Novo EpID=${newEp.id}: ${UrlSanitizer.sanitize(u)}');
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
    } catch (e) {
      PlayerDiagnostics.log(
        'SMART_SOURCE_REINDEX',
        'Erro ao sondar série candidata reindexada: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
      );
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
    Set<String>? alreadyFailedUrls,
  }) async {
    if (!SettingsService.instance.enableSmartSource) {
      return const SmartSourceResult(
        status: SmartSourceStatus.skippedDisabled,
        diagnosticMessage: 'Smart Source desativado nas configurações.',
      );
    }

    final cacheKey = _episodeCacheKey(
      seriesId,
      episode.id,
      catalogService: catalogService,
    );
    final cached = _validatedSourceCache[cacheKey];
    if (cached != null) {
      if (alreadyFailedUrls != null && alreadyFailedUrls.contains(cached)) {
        _validatedSourceCache.remove(cacheKey);
        debugPrint('[SMART SOURCE] [CACHE EVICT] URL em cache já falhou no player; invalidando: ${UrlSanitizer.sanitize(cached)}');
      } else {
        debugPrint('[SMART SOURCE] [CACHE HIT] Fonte recuperada instantaneamente do cache: ${UrlSanitizer.sanitize(cached)}');
        return SmartSourceResult(
          status: SmartSourceStatus.resolved,
          workingUrl: cached,
          attemptsCount: 0,
          diagnosticMessage: 'Fonte recuperada do cache local.',
        );
      }
    }

    final candidates = generateCandidateUrls(
      catalogService: catalogService,
      episode: episode,
    );

    final tested = <String>[];
    final outcomes = <_ProbeAttemptOutcome>[];
    final timeout = timeoutPerProbe ??
        Duration(seconds: SettingsService.instance.smartSourceTimeoutSecs);

    debugPrint('[SMART SOURCE] Iniciando resolução inteligente para episódio ID=${episode.id} (T${episode.seasonNumber}:E${episode.episodeNum}). ${candidates.length} candidatos gerados.');

    for (var i = 0; i < candidates.length; i++) {
      final candidateUrl = candidates[i];
      if (alreadyFailedUrls != null && alreadyFailedUrls.contains(candidateUrl)) {
        continue;
      }
      tested.add(candidateUrl);

      final ext = candidateUrl.split('.').last.split('?').first.toLowerCase();
      onProgressMessage?.call('Recuperando fonte do episódio... (Tentativa ${i + 1}/${candidates.length} - Formato ${ext.toUpperCase()})');

      final outcome = await _probeUrlDetailed(candidateUrl, client: probeClient, timeout: timeout);
      outcomes.add(outcome);
      if (outcome.ok) {
        debugPrint('[SMART SOURCE] [SUCESSO] Fonte funcional validada na tentativa ${i + 1}: ${UrlSanitizer.sanitize(candidateUrl)}');
        _putValidatedCache(cacheKey, candidateUrl);
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

    // Se todos os candidatos diretos falharam, verifica reindexação com identidade estrita
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
        alreadyFailedUrls: alreadyFailedUrls,
      );
      if (reindexed != null) {
        _putValidatedCache(cacheKey, reindexed.workingUrl!);
        return reindexed;
      }
    }

    debugPrint('[SMART SOURCE] [FALHA] Nenhum candidato respondeu com sucesso após ${tested.length} tentativas.');
    return SmartSourceResult(
      status: SmartSourceStatus.allFailed,
      attemptsCount: candidates.length,
      testedUrls: tested,
      diagnosticMessage: _summarizeFailedProbes(outcomes),
    );
  }

  XtreamVodStream? _findUnambiguousVodMatch(
    XtreamVodStream target,
    Iterable<XtreamVodStream> candidates,
  ) {
    final dedup = <int, XtreamVodStream>{};
    for (final m in candidates) {
      if (m.streamId == target.streamId || m.streamId <= 0) continue;
      if (SeriesIdentityVerifier.areSameSeriesIdentity(target.name, m.name)) {
        dedup.putIfAbsent(m.streamId, () => m);
      }
    }
    final matching = dedup.values.toList(growable: false);
    if (matching.isEmpty) return null;
    if (matching.length == 1) return matching.first;

    final targetCover = target.streamIcon?.trim() ?? '';
    if (targetCover.isNotEmpty) {
      final byCover = matching
          .where((m) => (m.streamIcon?.trim() ?? '') == targetCover)
          .toList();
      if (byCover.length == 1) return byCover.first;
    }

    final targetCat = target.categoryId.trim();
    if (targetCat.isNotEmpty && targetCat != '0' && targetCat != 'all') {
      final byCat = matching.where((m) => m.categoryId.trim() == targetCat).toList();
      if (byCat.length == 1) return byCat.first;
    }

    return null;
  }

  /// Resolve a melhor fonte funcional para um filme (VOD), descobrindo a extensão real
  /// via `get_vod_info` e recuperando filmes cujo `streamId` foi reindexado no provedor.
  Future<SmartSourceResult> resolveBestVodSource({
    required XtreamCatalogService catalogService,
    required XtreamVodStream movie,
    void Function(String message)? onProgressMessage,
    http.Client? probeClient,
    Duration? perProbeTimeout,
    Set<String>? alreadyFailedUrls,
  }) async {
    if (!SettingsService.instance.enableSmartSource) {
      return const SmartSourceResult(
        status: SmartSourceStatus.skippedDisabled,
        diagnosticMessage: 'Smart Source desativado nas configurações.',
      );
    }

    final cacheKey = _vodCacheKey(movie.streamId, catalogService: catalogService);
    final cached = _validatedSourceCache[cacheKey];
    if (cached != null) {
      if (alreadyFailedUrls != null && alreadyFailedUrls.contains(cached)) {
        _validatedSourceCache.remove(cacheKey);
        debugPrint('[SMART SOURCE] [CACHE EVICT] URL VOD em cache já falhou; invalidando: ${UrlSanitizer.sanitize(cached)}');
      } else {
        final cachedExt = cached.split('.').last.split('?').first.toLowerCase();
        debugPrint('[SMART SOURCE] [CACHE HIT] Fonte VOD recuperada do cache: ${UrlSanitizer.sanitize(cached)}');
        return SmartSourceResult(
          status: SmartSourceStatus.resolved,
          workingUrl: cached,
          containerExtension: cachedExt,
          recoveredSeriesId: movie.streamId,
          attemptsCount: 0,
          diagnosticMessage: 'Fonte do filme recuperada do cache local.',
        );
      }
    }

    final timeout = perProbeTimeout ??
        Duration(seconds: SettingsService.instance.smartSourceTimeoutSecs);
    final tested = <String>[];
    final outcomes = <_ProbeAttemptOutcome>[];

    // 1. Tenta consultar get_vod_info para obter extensão atualizada e metadados reais
    onProgressMessage?.call('Verificando informações reais do filme no servidor...');
    XtreamVodInfo? vodInfo;
    try {
      vodInfo = await catalogService.fetchVodInfo(movie.streamId, forceRefresh: true).timeout(timeout);
    } catch (e) {
      PlayerDiagnostics.log(
        'SMART_SOURCE_VOD',
        'Falha ao consultar get_vod_info: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
      );
    }

    final vodIdentityMismatch = vodInfo != null &&
        vodInfo.name.trim().isNotEmpty &&
        SeriesIdentityVerifier.verifySeriesInfoIdentity(
              requestedTitle: movie.name,
              serverReturnedName: vodInfo.name,
            ) ==
            SeriesIdentityConsistency.mismatch;

    final effectiveExt = (!vodIdentityMismatch &&
            vodInfo?.containerExtension != null &&
            vodInfo!.containerExtension!.trim().isNotEmpty)
        ? vodInfo.containerExtension
        : movie.containerExtension;

    if (!vodIdentityMismatch) {
      final candidates = catalogService.buildVodStreamUrlsById(
        movie.streamId,
        extension: effectiveExt,
        directSource: movie.directSource,
      );

      for (var i = 0; i < candidates.length; i++) {
        final candidateUrl = candidates[i];
        if (alreadyFailedUrls != null && alreadyFailedUrls.contains(candidateUrl)) {
          continue;
        }
        tested.add(candidateUrl);
        final ext = candidateUrl.split('.').last.split('?').first.toLowerCase();
        onProgressMessage?.call('Testando fonte do filme... (Tentativa ${i + 1}/${candidates.length} - Formato ${ext.toUpperCase()})');

        final outcome = await _probeUrlDetailed(candidateUrl, client: probeClient, timeout: timeout);
        outcomes.add(outcome);
        if (outcome.ok) {
          debugPrint('[SMART SOURCE] [VOD SUCESSO] Fonte funcional validada: ${UrlSanitizer.sanitize(candidateUrl)}');
          _putValidatedCache(cacheKey, candidateUrl);
          return SmartSourceResult(
            status: SmartSourceStatus.resolved,
            workingUrl: candidateUrl,
            containerExtension: ext,
            recoveredSeriesId: movie.streamId,
            attemptsCount: i + 1,
            testedUrls: tested,
            diagnosticMessage: 'Fonte do filme validada no formato ${ext.toUpperCase()}.',
          );
        }
      }
    }

    // 2. Se todas as rotas do streamId antigo falharem (ou ID divergir do nome), procura filme reindexado com identidade estrita
    if (SeriesIdentityVerifier.parseTitleParts(movie.name).canonicalBase.isNotEmpty) {
      onProgressMessage?.call('Verificando se o filme foi reindexado no catálogo...');
      XtreamVodStream? matched;

      if (movie.categoryId.isNotEmpty && movie.categoryId != '0' && movie.categoryId != 'all') {
        try {
          final catMovies = await catalogService.fetchVodStreams(
            categoryId: movie.categoryId,
            forceRefresh: true,
          );
          matched = _findUnambiguousVodMatch(movie, catMovies);
        } catch (e) {
          PlayerDiagnostics.log(
            'SMART_SOURCE_VOD',
            'Falha ao buscar VODs da categoria ${movie.categoryId}: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
          );
        }
      }

      if (matched == null) {
        try {
          final allMovies = await catalogService.fetchVodStreams(
            categoryId: 'all',
            forceRefresh: true,
          );
          matched = _findUnambiguousVodMatch(movie, allMovies);
        } catch (e) {
          PlayerDiagnostics.log(
            'SMART_SOURCE_VOD',
            'Falha ao buscar catálogo completo VOD: ${UrlSanitizer.sanitizeErrorMessage(e.toString())}',
          );
        }
      }

      if (matched != null) {
        final matchedCandidates = catalogService.buildVodStreamUrls(matched);
        for (final u in matchedCandidates) {
          if (alreadyFailedUrls != null && alreadyFailedUrls.contains(u)) {
            continue;
          }
          tested.add(u);
          final outcome = await _probeUrlDetailed(u, client: probeClient, timeout: timeout);
          outcomes.add(outcome);
          if (outcome.ok) {
            final ext = u.split('.').last.split('?').first.toLowerCase();
            debugPrint('[SMART SOURCE] [VOD REINDEX SUCESSO] Filme recuperado! Antigo ID=${movie.streamId}, Novo ID=${matched.streamId}: ${UrlSanitizer.sanitize(u)}');
            _putValidatedCache(cacheKey, u);
            return SmartSourceResult(
              status: SmartSourceStatus.resolved,
              workingUrl: u,
              containerExtension: ext,
              recoveredSeriesId: matched.streamId,
              attemptsCount: tested.length,
              testedUrls: tested,
              diagnosticMessage: 'Filme recuperado por reindexação no servidor (Novo ID: ${matched.streamId}).',
            );
          }
        }
      }
    }

    debugPrint('[SMART SOURCE] [VOD FALHA] Nenhum candidato respondeu com sucesso após ${tested.length} tentativas.');
    return SmartSourceResult(
      status: SmartSourceStatus.allFailed,
      attemptsCount: tested.length,
      testedUrls: tested,
      diagnosticMessage: _summarizeFailedProbes(outcomes),
    );
  }
}
