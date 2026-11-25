import 'dart:async';
import 'package:flutter/material.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../services/cloud_progress_sync_service.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/player_diagnostics.dart';
import '../services/series_identity_verifier.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';
import 'series_player_screen.dart';

/// Tela de detalhes para séries inspirada no layout Silo (IPTV moderno para Fire TV / Android TV),
/// com imagem de fundo panorâmica, gradientes cinematográficos, botão de continuação/próximo episódio
/// direto no destaque da tela, seletor de temporadas em pills horizontais e lista de episódios reais.
class SeriesDetailScreen extends StatefulWidget {
  final XtreamSeriesItem series;
  final XtreamCatalogService catalogService;
  final String accountKey;

  const SeriesDetailScreen({
    super.key,
    required this.series,
    required this.catalogService,
    required this.accountKey,
  });

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  final PlaybackProgressService _progressService = PlaybackProgressService();

  bool _isLoading = true;
  String? _errorMessage;
  SeriesInfoFetchResult? _lastFetchResult;
  XtreamSeriesInfo? _seriesInfo;
  int _selectedSeasonNumber = 1;
  bool _hasInitializedSeason = false;
  bool _isFavorite = false;
  int _loadGeneration = 0;

  // Mapa de progresso salvo por episodeId
  final Map<int, PlaybackProgress> _episodesProgress = {};

  // Episódio e ação principal calculados para o Hero Button
  XtreamSeriesEpisode? _primaryEpisode;
  Duration? _primaryPosition;
  String _primaryButtonLabel = '';

  late XtreamSeriesItem _currentSeries;

  @override
  void initState() {
    super.initState();
    _currentSeries = widget.series;
    _isFavorite = FavoritesService.instance.isFavorite(
      scopeKey: widget.accountKey,
      type: FavoriteType.series,
      id: _currentSeries.seriesId.toString(),
    );
    FavoritesService.instance.addListener(_onFavoritesChanged);
    _loadSeriesData();
  }

  @override
  void didUpdateWidget(covariant SeriesDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series.seriesId != widget.series.seriesId ||
        oldWidget.accountKey != widget.accountKey) {
      _loadGeneration++;
      _currentSeries = widget.series;
      _seriesInfo = null;
      _lastFetchResult = null;
      _errorMessage = null;
      _hasInitializedSeason = false;
      _episodesProgress.clear();
      _primaryEpisode = null;
      _primaryPosition = null;
      _primaryButtonLabel = '';
      _isFavorite = FavoritesService.instance.isFavorite(
        scopeKey: widget.accountKey,
        type: FavoriteType.series,
        id: _currentSeries.seriesId.toString(),
      );
      _loadSeriesData();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    FavoritesService.instance.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) {
      setState(() {
        _isFavorite = FavoritesService.instance.isFavorite(
          scopeKey: widget.accountKey,
          type: FavoriteType.series,
          id: _currentSeries.seriesId.toString(),
        );
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final item = FavoriteItem.fromSeriesItem(
      accountKey: widget.accountKey,
      series: _currentSeries,
    );
    final isFav = await FavoritesService.instance.toggleFavorite(item);
    if (mounted) {
      setState(() => _isFavorite = isFav);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isFav ? 'Série adicionada aos favoritos' : 'Série removida dos favoritos',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: isFav ? const Color(0xFF00E5FF) : const Color(0xFF37474F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  bool _shouldAttemptReindexRecovery(SeriesInfoFetchResult result) {
    switch (result.category) {
      case SeriesInfoErrorCategory.serverReturnedNoEpisodes:
      case SeriesInfoErrorCategory.httpNotFound:
      case SeriesInfoErrorCategory.emptyBody:
      case SeriesInfoErrorCategory.unexpectedJsonStructure:
      case SeriesInfoErrorCategory.identityMismatch:
      case SeriesInfoErrorCategory.staleOrIncoherentCache:
        return true;
      case SeriesInfoErrorCategory.none:
        return !result.hasUsableEpisodes;
      case SeriesInfoErrorCategory.invalidServerUrl:
      case SeriesInfoErrorCategory.authDenied:
      case SeriesInfoErrorCategory.httpServerError:
      case SeriesInfoErrorCategory.httpOtherError:
      case SeriesInfoErrorCategory.timeout:
      case SeriesInfoErrorCategory.networkError:
      case SeriesInfoErrorCategory.tlsError:
      case SeriesInfoErrorCategory.htmlErrorPage:
      case SeriesInfoErrorCategory.invalidJson:
      case SeriesInfoErrorCategory.parserIgnoredEpisodes:
      case SeriesInfoErrorCategory.reindexedSeriesId:
      case SeriesInfoErrorCategory.unknown:
        return false;
    }
  }

  String _formatSeriesErrorMessage(SeriesInfoFetchResult result) {
    switch (result.category) {
      case SeriesInfoErrorCategory.identityMismatch:
        return 'Os dados retornados pelo servidor não pertencem a "${_currentSeries.name}". '
            'Por segurança, a associação automática foi bloqueada.';
      case SeriesInfoErrorCategory.parserIgnoredEpisodes:
        return result.userMessage ??
            'O servidor retornou episódios em um formato não reconhecido pelo leitor.';
      case SeriesInfoErrorCategory.serverReturnedNoEpisodes:
        return 'O servidor retornou 0 episódios cadastrados para "${_currentSeries.name}". '
            'Você pode tentar "Atualizar dados" para verificar novamente.';
      case SeriesInfoErrorCategory.httpNotFound:
      case SeriesInfoErrorCategory.emptyBody:
      case SeriesInfoErrorCategory.unexpectedJsonStructure:
        return '${result.userMessage ?? 'Cadastro da série indisponível ou reindexado no servidor.'} '
            'Toque em "Atualizar dados" para tentar recarregar.';
      case SeriesInfoErrorCategory.authDenied:
      case SeriesInfoErrorCategory.httpServerError:
      case SeriesInfoErrorCategory.httpOtherError:
      case SeriesInfoErrorCategory.timeout:
      case SeriesInfoErrorCategory.networkError:
      case SeriesInfoErrorCategory.tlsError:
      case SeriesInfoErrorCategory.htmlErrorPage:
      case SeriesInfoErrorCategory.invalidJson:
      case SeriesInfoErrorCategory.invalidServerUrl:
      case SeriesInfoErrorCategory.staleOrIncoherentCache:
      case SeriesInfoErrorCategory.reindexedSeriesId:
      case SeriesInfoErrorCategory.unknown:
      case SeriesInfoErrorCategory.none:
        return result.userMessage ??
            'Não foi possível carregar as informações e episódios desta série.';
    }
  }

  Future<SeriesInfoFetchResult?> _tryRecoverUnambiguousReindexedSeries({
    required XtreamSeriesItem target,
  }) async {
    if (SeriesIdentityVerifier.parseTitleParts(target.name).canonicalBase.isEmpty) {
      return null;
    }

    XtreamSeriesItem? matched;

    final cachedUnion = widget.catalogService.getAllCachedSeriesUnionSync();
    if (cachedUnion.isNotEmpty) {
      matched = SeriesIdentityVerifier.findUnambiguousSeriesMatch(
        target: target,
        candidates: cachedUnion,
      );
    }

    if (matched == null &&
        target.categoryId.isNotEmpty &&
        target.categoryId != '0' &&
        target.categoryId != 'all') {
      try {
        final catList = await widget.catalogService.fetchSeries(
          categoryId: target.categoryId,
          forceRefresh: true,
        );
        matched = SeriesIdentityVerifier.findUnambiguousSeriesMatch(
          target: target,
          candidates: catList,
        );
      } catch (_) {}
    }

    if (matched == null) {
      try {
        final allList = await widget.catalogService.fetchSeries(
          categoryId: 'all',
          forceRefresh: true,
        );
        matched = SeriesIdentityVerifier.findUnambiguousSeriesMatch(
          target: target,
          candidates: allList,
        );
      } catch (_) {}
    }

    if (matched == null) return null;

    final candidateResult = await widget.catalogService.fetchSeriesInfoDetailed(
      matched.seriesId,
      forceRefresh: true,
      expectedSeriesName: target.name,
      expectedCoverUrl: matched.cover ?? target.cover,
    );
    if (!candidateResult.hasUsableEpisodes ||
        candidateResult.identityConsistency == SeriesIdentityConsistency.mismatch) {
      return null;
    }

    final candidateInfo = candidateResult.info!;
    PlayerDiagnostics.logSeriesDiagnostic(
      SeriesDiagnosticRecord(
        timestamp: DateTime.now(),
        requestType: 'series_reindex_recovery',
        anonymizedId: UrlSanitizer.anonymizeId('${target.seriesId}->${matched.seriesId}'),
        cacheSource: 'network',
        httpStatus: candidateResult.httpStatus,
        elapsedMs: candidateResult.elapsedMs,
        seasonCount: candidateInfo.seasons.length,
        episodeCount: candidateInfo.totalEpisodeCount,
        rawEpisodesShape: candidateInfo.rawEpisodesShape,
        rawEpisodeEntriesCount: candidateInfo.rawEpisodeEntriesCount,
        errorCategory: SeriesInfoErrorCategory.reindexedSeriesId,
        identityConsistency: candidateResult.identityConsistency,
        classification: DiagnosticClassification.confirmedServerIssue,
        sanitizedNote: 'Série reindexada no servidor com identidade confirmada.',
      ),
    );

    if (widget.accountKey.trim().isNotEmpty) {
      await _progressService.migrateSeriesProgressNonDestructively(
        accountKey: widget.accountKey,
        oldSeriesId: target.seriesId,
        newSeriesId: matched.seriesId,
        seriesName: target.name,
        coverUrl: matched.cover ?? target.cover,
        newSeriesInfo: candidateInfo,
      );

      final wasOldFavorited = FavoritesService.instance.isFavorite(
        scopeKey: widget.accountKey,
        type: FavoriteType.series,
        id: target.seriesId.toString(),
      );
      if (wasOldFavorited) {
        await FavoritesService.instance.migrateSeriesFavoriteId(
          accountKey: widget.accountKey,
          oldSeriesId: target.seriesId,
          newSeries: matched,
        );
      }
    }

    _currentSeries = matched;
    return candidateResult;
  }

  Future<void> _reloadProgressFromLateSync(XtreamSeriesInfo info, int expectedGen) async {
    if (!mounted || expectedGen != _loadGeneration) return;
    await _loadEpisodesProgress(info, expectedGen: expectedGen);
    if (!mounted || expectedGen != _loadGeneration) return;
    setState(() {
      final preferredSeason = _primaryEpisode?.seasonNumber;
      if (!_hasInitializedSeason &&
          preferredSeason != null &&
          info.seasons.any((s) => s.seasonNumber == preferredSeason)) {
        _selectedSeasonNumber = preferredSeason;
      }
    });
  }

  Future<void> _loadSeriesData({bool forceRefresh = false}) async {
    final gen = ++_loadGeneration;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _lastFetchResult = null;
    });

    try {
      // Garantir favoritos carregados no cold start para refletir estado real e migração segura
      if (widget.accountKey.trim().isNotEmpty) {
        await FavoritesService.instance.loadFavorites(widget.accountKey);
        if (!mounted || gen != _loadGeneration) return;
        _isFavorite = FavoritesService.instance.isFavorite(
          scopeKey: widget.accountKey,
          type: FavoriteType.series,
          id: _currentSeries.seriesId.toString(),
        );
      }

      var syncCompletedInline = false;
      final rawSyncFuture = widget.accountKey.trim().isNotEmpty
          ? CloudProgressSyncService.instance
              .syncAccount(
                widget.accountKey,
                progressService: _progressService,
              )
              .catchError((_) => false)
          : Future<bool>.value(false);

      unawaited(
        rawSyncFuture.then((changed) {
          if (syncCompletedInline &&
              changed &&
              mounted &&
              gen == _loadGeneration &&
              _seriesInfo != null) {
            unawaited(_reloadProgressFromLateSync(_seriesInfo!, gen));
          }
        }),
      );

      final syncFuture = rawSyncFuture.timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );

      // 1. Consulta estruturada com verificação estrita de identidade
      var result = await widget.catalogService.fetchSeriesInfoDetailed(
        _currentSeries.seriesId,
        forceRefresh: forceRefresh,
        expectedSeriesName: _currentSeries.name,
        expectedCoverUrl: _currentSeries.cover,
      );
      if (!mounted || gen != _loadGeneration) return;

      if (!forceRefresh && result.fromCache && result.hasUsableEpisodes) {
        unawaited(_revalidateSeriesInfoFromNetwork(_currentSeries.seriesId, gen));
      }

      // 2. Recuperação automática SOMENTE quando o ID pode ter sido reindexado e há correspondência inequívoca
      if (_shouldAttemptReindexRecovery(result)) {
        final recovered = await _tryRecoverUnambiguousReindexedSeries(
          target: _currentSeries,
        );
        if (!mounted || gen != _loadGeneration) return;
        if (recovered != null) {
          result = recovered;
        }
      }

      final info = result.info;
      if (result.category == SeriesInfoErrorCategory.identityMismatch ||
          info == null ||
          !result.hasUsableEpisodes) {
        setState(() {
          _isLoading = false;
          _seriesInfo = null;
          _lastFetchResult = result;
          _errorMessage = _formatSeriesErrorMessage(result);
        });
        return;
      }

      await syncFuture;
      syncCompletedInline = true;
      if (!mounted || gen != _loadGeneration) return;

      // Carregar progresso dos episódios antes de selecionar a temporada inicial
      await _loadEpisodesProgress(info, expectedGen: gen);
      if (!mounted || gen != _loadGeneration) return;

      final preferredSeason = _primaryEpisode?.seasonNumber;
      final hasPreferredSeason = preferredSeason != null &&
          info.seasons.any((s) => s.seasonNumber == preferredSeason);
      final initialSeason = (!_hasInitializedSeason && hasPreferredSeason)
          ? preferredSeason
          : (info.seasons.any((s) => s.seasonNumber == _selectedSeasonNumber)
              ? _selectedSeasonNumber
              : (info.seasons.isNotEmpty ? info.seasons.first.seasonNumber : 1));
      _hasInitializedSeason = true;

      setState(() {
        _seriesInfo = info;
        _lastFetchResult = result;
        _selectedSeasonNumber = initialSeason;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGeneration) return;
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      setState(() {
        _isLoading = false;
        _seriesInfo = null;
        _errorMessage = 'Erro ao carregar série: $safeErr';
      });
    }
  }

  Future<void> _revalidateSeriesInfoFromNetwork(int seriesId, int expectedGen) async {
    try {
      final freshResult = await widget.catalogService
          .fetchSeriesInfoDetailed(
            seriesId,
            forceRefresh: true,
            expectedSeriesName: _currentSeries.name,
            expectedCoverUrl: _currentSeries.cover,
          )
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () => const SeriesInfoFetchResult(
              category: SeriesInfoErrorCategory.timeout,
              classification: DiagnosticClassification.networkFailure,
            ),
          );
      if (!mounted ||
          expectedGen != _loadGeneration ||
          seriesId != _currentSeries.seriesId ||
          !freshResult.hasUsableEpisodes ||
          freshResult.identityConsistency == SeriesIdentityConsistency.mismatch) {
        return;
      }
      final freshInfo = freshResult.info!;
      await _loadEpisodesProgress(freshInfo, expectedGen: expectedGen);
      if (!mounted ||
          expectedGen != _loadGeneration ||
          seriesId != _currentSeries.seriesId) {
        return;
      }
      setState(() {
        _seriesInfo = freshInfo;
        _lastFetchResult = freshResult;
        if (!freshInfo.seasons.any((s) => s.seasonNumber == _selectedSeasonNumber) &&
            freshInfo.seasons.isNotEmpty) {
          _selectedSeasonNumber = freshInfo.seasons.first.seasonNumber;
        }
      });
    } catch (_) {}
  }

  Future<void> _loadEpisodesProgress(
    XtreamSeriesInfo info, {
    int? expectedGen,
  }) async {
    // 1. Consultar último episódio assistido salvo (com fallback por Continue Watching / ledger se necessário)
    var lastWatched = await _progressService.getLastWatchedEpisode(
      accountKey: widget.accountKey,
      seriesId: _currentSeries.seriesId,
    );

    if (expectedGen != null && (!mounted || expectedGen != _loadGeneration)) return;

    // 2. Consultar progresso de todos os episódios disponíveis em paralelo sem limpar o mapa antes do await
    final allEpisodes = info.episodesBySeason.values.expand((list) => list).toList();
    final progressEntries = await Future.wait(
      allEpisodes.map((ep) async {
        final prog = await _progressService.getEpisodeProgress(
          accountKey: widget.accountKey,
          seriesId: _currentSeries.seriesId,
          episodeId: ep.id,
        );
        return MapEntry(ep.id, prog);
      }),
    );

    if (expectedGen != null && (!mounted || expectedGen != _loadGeneration)) return;

    final loadedProgress = <int, PlaybackProgress>{};
    for (final entry in progressEntries) {
      if (entry.value != null) {
        loadedProgress[entry.key] = entry.value!;
      }
    }

    // Fallback P6: se lastWatched está ausente ou aponta para episódio não encontrado diretamente,
    // reconcilia via índice/ledger/Continue Watching da mesma série pelo título exato.
    bool needsFallback = lastWatched == null;
    if (!needsFallback) {
      final lwEpId = lastWatched['episodeId'];
      final lwSeason = lastWatched['seasonNumber'];
      final lwNum = lastWatched['episodeNum'];
      final foundById = (lwEpId != null) ? info.findEpisodeById(lwEpId) : null;
      final foundBySN = (lwSeason != null && lwNum != null)
          ? info.findEpisodeBySeasonAndNum(lwSeason, lwNum)
          : null;
      if (foundById == null && foundBySN == null) {
        needsFallback = true;
      }
    }

    if (needsFallback && widget.accountKey.trim().isNotEmpty) {
      final fallback = await _progressService.findSeriesProgressFallback(
        accountKey: widget.accountKey,
        seriesId: _currentSeries.seriesId,
        seriesName: _currentSeries.name,
        seriesInfo: info,
      );
      if (expectedGen != null && (!mounted || expectedGen != _loadGeneration)) return;
      if (fallback != null) {
        lastWatched = fallback;
      }
    }

    XtreamSeriesEpisode? primaryEpisode;
    Duration? primaryPosition;
    var primaryButtonLabel = '';

    // 3. Determinar episódio para o botão principal (Continuar / Próximo / Assistir / Rever)
    if (lastWatched != null) {
      final lastEpId = lastWatched['episodeId'];
      final lastSeason = lastWatched['seasonNumber'];
      final lastNum = lastWatched['episodeNum'];
      final isPromotedNext = lastWatched['isPromotedNext'] == 1;
      final isMarkedCompleted = lastWatched['isCompleted'] == 1;
      final fallbackPosSecs = lastWatched['positionSeconds'] ?? 0;
      final fallbackDurSecs = lastWatched['durationSeconds'] ?? 0;

      XtreamSeriesEpisode? lastEp = (lastEpId != null) ? info.findEpisodeById(lastEpId) : null;
      if (lastEp == null && lastSeason != null && lastNum != null) {
        lastEp = info.findEpisodeBySeasonAndNum(lastSeason, lastNum);
        // Se o ID do episódio mudou no servidor mas temporada/número coincidem, migra o progresso salvo para o novo ID
        if (lastEp != null && lastEpId != null && lastEpId > 0 && lastEp.id != lastEpId) {
          final migratedProg = await _progressService.getEpisodeProgress(
            accountKey: widget.accountKey,
            seriesId: _currentSeries.seriesId,
            episodeId: lastEpId,
          );
          if (expectedGen != null && (!mounted || expectedGen != _loadGeneration)) return;
          if (migratedProg != null &&
              (migratedProg.canResume || migratedProg.isCompleted)) {
            loadedProgress[lastEp.id] = migratedProg;
            unawaited(
              _progressService.saveEpisodeProgress(
                accountKey: widget.accountKey,
                seriesId: _currentSeries.seriesId,
                episodeId: lastEp.id,
                position: migratedProg.position,
                duration: migratedProg.duration,
              ),
            );
          }
          unawaited(
            _progressService.saveLastWatchedEpisode(
              accountKey: widget.accountKey,
              seriesId: _currentSeries.seriesId,
              episodeId: lastEp.id,
              seasonNumber: lastEp.seasonNumber,
              episodeNum: lastEp.episodeNum,
              isPromotedNext: isPromotedNext,
            ),
          );
        }
      }

      if (lastEp != null) {
        var prog = loadedProgress[lastEp.id];
        if (prog == null && !isMarkedCompleted && fallbackPosSecs >= 10) {
          final recoveredDur = fallbackDurSecs > 0
              ? Duration(seconds: fallbackDurSecs)
              : (lastEp.durationSecs != null && lastEp.durationSecs! > 0
                  ? Duration(seconds: lastEp.durationSecs!)
                  : Duration.zero);
          final recoveredProg = PlaybackProgress(
            streamId: lastEp.id,
            position: Duration(seconds: fallbackPosSecs),
            duration: recoveredDur,
            updatedAt: DateTime.now(),
          );
          loadedProgress[lastEp.id] = recoveredProg;
          prog = recoveredProg;
          unawaited(
            _progressService.saveEpisodeProgress(
              accountKey: widget.accountKey,
              seriesId: _currentSeries.seriesId,
              episodeId: lastEp.id,
              position: recoveredProg.position,
              duration: recoveredProg.duration,
            ),
          );
        }

        if (prog != null && prog.canResume && !isMarkedCompleted) {
          // Episódio foi interrompido: continuar exatamente do ponto salvo
          primaryEpisode = lastEp;
          primaryPosition = prog.position;
          primaryButtonLabel = 'CONTINUAR S${lastEp.seasonNumber}E${lastEp.episodeNum}';
        } else if (isPromotedNext && !isMarkedCompleted) {
          // Este episódio já é o próximo promovido pela conclusão do anterior
          primaryEpisode = lastEp;
          primaryPosition = Duration.zero;
          primaryButtonLabel = 'PRÓXIMO S${lastEp.seasonNumber}E${lastEp.episodeNum}';
        } else {
          // Episódio foi concluído: disponibilizar o próximo episódio válido (sem voltar ao Ep 1 indevidamente)
          final nextEp = info.getNextEpisode(lastEp);
          if (nextEp != null) {
            final nextProg = loadedProgress[nextEp.id];
            if (nextProg != null && nextProg.canResume) {
              primaryEpisode = nextEp;
              primaryPosition = nextProg.position;
              primaryButtonLabel = 'CONTINUAR S${nextEp.seasonNumber}E${nextEp.episodeNum}';
            } else {
              primaryEpisode = nextEp;
              primaryPosition = Duration.zero;
              primaryButtonLabel = 'PRÓXIMO S${nextEp.seasonNumber}E${nextEp.episodeNum}';
            }
          } else {
            // Todos os episódios foram concluídos: opção de rever a série
            final firstSeason = info.seasons.firstOrNull;
            final firstEp = firstSeason != null
                ? info.episodesBySeason[firstSeason.seasonNumber]?.firstOrNull
                : null;
            if (firstEp != null) {
              primaryEpisode = firstEp;
              primaryPosition = Duration.zero;
              primaryButtonLabel = 'REVER S${firstEp.seasonNumber}E${firstEp.episodeNum}';
            }
          }
        }
      }
    }

    // Se não encontrou pelo último assistido, busca qualquer episódio com progresso em andamento
    if (primaryEpisode == null && loadedProgress.isNotEmpty) {
      for (final season in info.seasons) {
        final eps = info.episodesBySeason[season.seasonNumber] ?? [];
        for (final ep in eps) {
          final prog = loadedProgress[ep.id];
          if (prog != null && prog.canResume) {
            primaryEpisode = ep;
            primaryPosition = prog.position;
            primaryButtonLabel = 'CONTINUAR S${ep.seasonNumber}E${ep.episodeNum}';
            break;
          }
        }
        if (primaryEpisode != null) break;
      }
    }

    // Se ainda não há nenhum episódio iniciado, o botão principal oferece começar o Ep 1
    if (primaryEpisode == null) {
      final firstSeason = info.seasons.firstOrNull;
      final firstEp = firstSeason != null
          ? info.episodesBySeason[firstSeason.seasonNumber]?.firstOrNull
          : null;
      if (firstEp != null) {
        primaryEpisode = firstEp;
        primaryPosition = Duration.zero;
        primaryButtonLabel = 'ASSISTIR S${firstEp.seasonNumber}E${firstEp.episodeNum}';
      }
    }

    if (expectedGen != null && (!mounted || expectedGen != _loadGeneration)) return;

    _episodesProgress
      ..clear()
      ..addAll(loadedProgress);
    _primaryEpisode = primaryEpisode;
    _primaryPosition = primaryPosition;
    _primaryButtonLabel = primaryButtonLabel;

    // 4. Auto-reconciliação do card "Continuar assistindo" da Home:
    // Respeita itens ocultados ou limpos pelo usuário (P1: never resurrects on detail open).
    if (widget.accountKey.trim().isNotEmpty &&
        primaryEpisode != null &&
        (primaryButtonLabel.startsWith('CONTINUAR') ||
            primaryButtonLabel.startsWith('PRÓXIMO'))) {
      final primaryEp = primaryEpisode;
      final pos = primaryPosition ?? Duration.zero;
      final prog = loadedProgress[primaryEp.id];
      final dur = (prog != null && prog.duration > Duration.zero)
          ? prog.duration
          : (primaryEp.durationSecs != null && primaryEp.durationSecs! > 0
              ? Duration(seconds: primaryEp.durationSecs!)
              : Duration.zero);

      final isNextPromoted = primaryButtonLabel.startsWith('PRÓXIMO');
      if (isNextPromoted &&
          (lastWatched == null ||
              lastWatched['episodeId'] != primaryEp.id ||
              lastWatched['isPromotedNext'] != 1)) {
        unawaited(
          _progressService.saveLastWatchedEpisode(
            accountKey: widget.accountKey,
            seriesId: _currentSeries.seriesId,
            episodeId: primaryEp.id,
            seasonNumber: primaryEp.seasonNumber,
            episodeNum: primaryEp.episodeNum,
            isPromotedNext: true,
          ),
        );
      }

      final lastTimeMs = lastWatched != null ? (lastWatched['time'] ?? 0) : 0;
      final effectiveUpdatedAt = prog?.updatedAt ??
          (lastTimeMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(lastTimeMs)
              : DateTime.now());

      unawaited(
        _progressService.ensureContinueWatchingSeriesItem(
          accountKey: widget.accountKey,
          item: ContinueWatchingItem(
            streamId: primaryEp.id,
            seriesId: _currentSeries.seriesId,
            type: ContinueWatchingType.series,
            title: _currentSeries.name.isNotEmpty ? _currentSeries.name : info.name,
            subtitle: 'T${primaryEp.seasonNumber}:E${primaryEp.episodeNum} • ${primaryEp.title}',
            coverUrl: primaryEp.cover ?? _currentSeries.cover ?? info.cover,
            position: pos,
            duration: dur,
            updatedAt: effectiveUpdatedAt,
            containerExtension: primaryEp.containerExtension,
            categoryId: _currentSeries.categoryId,
            seasonNumber: primaryEp.seasonNumber,
            episodeNum: primaryEp.episodeNum,
          ),
        ),
      );
    }
  }

  void _onEpisodeTap(XtreamSeriesEpisode episode) {
    final prog = _episodesProgress[episode.id];
    // Inicia diretamente a reprodução do episódio no ponto salvo ou do início
    if (prog != null && prog.canResume) {
      _startPlayback(episode, initialPosition: prog.position);
    } else {
      _startPlayback(episode, initialPosition: Duration.zero);
    }
  }

  Future<void> _startPlayback(XtreamSeriesEpisode episode, {Duration? initialPosition}) async {
    if (_seriesInfo == null) return;
    final genAtLaunch = _loadGeneration;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesPlayerScreen(
          series: _currentSeries,
          seriesInfo: _seriesInfo!,
          initialEpisode: episode,
          catalogService: widget.catalogService,
          accountKey: widget.accountKey,
          initialPosition: initialPosition,
          seriesInfoIsFresh: _lastFetchResult != null && !_lastFetchResult!.fromCache,
        ),
      ),
    );

    // Ao voltar do player, restaura imediatamente a orientação e atualiza progresso
    if (mounted && genAtLaunch == _loadGeneration) {
      DeviceUtils.restoreOrientation();
      if (_seriesInfo != null) {
        await _loadEpisodesProgress(_seriesInfo!, expectedGen: genAtLaunch);
        if (mounted && genAtLaunch == _loadGeneration) setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: DeviceUtils.dpadChannelShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          FavoriteToggleIntent: CallbackAction<FavoriteToggleIntent>(
            onInvoke: (_) {
              _toggleFavorite();
              return null;
            },
          ),
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF070D16),
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 16.0),
          child: Column(
            children: [
              _buildTopBar(),
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Carregando temporadas e episódios...',
                        style: TextStyle(color: Color(0xFFB0BEC5), fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      final diagLabel = _lastFetchResult != null &&
              _lastFetchResult!.category != SeriesInfoErrorCategory.none
          ? 'Diagnóstico: ${_lastFetchResult!.category.name}'
              '${_lastFetchResult!.httpStatus != null ? ' • HTTP ${_lastFetchResult!.httpStatus}' : ''}'
              ' • Origem: ${_lastFetchResult!.classification.name}'
          : null;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 16.0),
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Color(0xFFEF5350), size: 48),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ),
                      if (diagLabel != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          diagLabel,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF78909C),
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        autofocus: true,
                        onPressed: () => _loadSeriesData(forceRefresh: true),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Atualizar dados'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final info = _seriesInfo!;
    final backdropUrl = info.backdrop ?? info.cover ?? _currentSeries.cover;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Imagem de fundo panorâmica (Backdrop)
        if (backdropUrl != null && backdropUrl.trim().isNotEmpty)
          Positioned.fill(
            child: Image.network(
              backdropUrl,
              fit: BoxFit.cover,
              cacheWidth: 1280,
              errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
            ),
          ),

        // 2. Gradiente Horizontal (escurecimento suave à esquerda para garantir legibilidade dos textos)
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color(0xFF070D16),
                  const Color(0xFF070D16).withValues(alpha: 0.95),
                  const Color(0xFF070D16).withValues(alpha: 0.72),
                  const Color(0xFF070D16).withValues(alpha: 0.35),
                ],
                stops: const [0.0, 0.45, 0.75, 1.0],
              ),
            ),
          ),
        ),

        // 3. Gradiente Vertical (escurecimento sutil no topo e forte na base para os episódios)
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xCC070D16),
                  Colors.transparent,
                  const Color(0xF2070D16),
                ],
                stops: const [0.0, 0.28, 1.0],
              ),
            ),
          ),
        ),

        // 4. Conteúdo Rolável em Primeiro Plano
        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;

              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isLandscape ? 36.0 : 18.0,
                  vertical: 16.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Barra Superior com botão Voltar em pill e título
                    _buildTopBar(),
                    const SizedBox(height: 16),

                    // Seção de Destaque da Série (Título, Badges, Sinopse e Botões Silo)
                    _buildHeroSection(info, constraints),
                    const SizedBox(height: 32),

                    // Seção "Temporadas"
                    _buildSeasonSectionHeader(),
                    const SizedBox(height: 14),

                    // Seletor de Temporadas em pills horizontais
                    _buildSeasonSelector(info),
                    const SizedBox(height: 20),

                    // Lista de Episódios da Temporada Selecionada
                    _buildEpisodesList(info),
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _BackButtonPill(
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            _currentSeries.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8A99AD),
            ),
          ),
        ),
        IconButton(
          tooltip: _isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
          icon: Icon(
            _isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
            color: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFFF0F4F8),
          ),
          onPressed: _toggleFavorite,
        ),
      ],
    );
  }

  Widget _buildHeroSection(XtreamSeriesInfo info, BoxConstraints constraints) {
    final isLandscape = constraints.maxWidth > constraints.maxHeight;
    final year = info.releaseDate?.split('-').firstOrNull;
    final rating = info.rating ?? _currentSeries.rating;
    final genre = info.genre ?? _currentSeries.genre;
    final plot = info.plot ?? _currentSeries.plot;

    final heroWidth = isLandscape ? (constraints.maxWidth * 0.62).clamp(380.0, 760.0) : double.infinity;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: heroWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Título da Série
          Text(
            info.name,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF0F4F8),
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 10),

          // Badges: SÉRIE, Ano, Avaliação com Estrela e Gêneros
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00E5FF), width: 1.2),
                ),
                child: const Text(
                  'SÉRIE',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (year != null && year.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.6), width: 1.2),
                  ),
                  child: Text(
                    year,
                    style: const TextStyle(
                      color: Color(0xFFF0F4F8),
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              if (rating != null && rating.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB300).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFFB300), width: 1.2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star_rounded, color: Color(0xFFFFB300), size: 14),
                      const SizedBox(width: 4),
                      Text(
                        rating,
                        style: const TextStyle(
                          color: Color(0xFFFFB300),
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              if (genre != null && genre.isNotEmpty)
                Text(
                  genre,
                  style: const TextStyle(
                    color: Color(0xFF90A4AE),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Sinopse
          if (plot != null && plot.trim().isNotEmpty) ...[
            Text(
              plot,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: Color(0xFFCFD8DC),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Botões de Ação Hero Silo:
          // Botão 1: Destaque Primário Silo (CONTINUAR S... / PRÓXIMO S... / ASSISTIR S...)
          // Botão 2: Favoritos em Pill (REMOVER DOS FAVORITOS / ADICIONAR AOS FAVORITOS)
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_primaryEpisode != null && _primaryButtonLabel.isNotEmpty)
                _SiloPrimaryButton(
                  label: _primaryButtonLabel,
                  autofocus: true,
                  onTap: () => _startPlayback(_primaryEpisode!, initialPosition: _primaryPosition),
                ),
              _SiloFavoriteButton(
                isFavorite: _isFavorite,
                onToggle: _toggleFavorite,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonSectionHeader() {
    return const Text(
      'Temporadas',
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: Color(0xFFF0F4F8),
        letterSpacing: 0.3,
      ),
    );
  }

  Widget _buildSeasonSelector(XtreamSeriesInfo info) {
    if (info.seasons.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: info.seasons.map((season) {
          final isSelected = season.seasonNumber == _selectedSeasonNumber;
          return Padding(
            padding: const EdgeInsets.only(right: 10.0),
            child: _SeasonChip(
              season: season,
              isSelected: isSelected,
              onSelected: () {
                setState(() => _selectedSeasonNumber = season.seasonNumber);
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEpisodesList(XtreamSeriesInfo info) {
    final episodes = info.episodesBySeason[_selectedSeasonNumber] ?? [];

    if (episodes.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Nenhum episódio cadastrado para esta temporada.',
              style: TextStyle(color: Color(0xFF90A4AE), fontSize: 14),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => _loadSeriesData(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Atualizar dados'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      );
    }

    String? firstNonEmptyUrl(List<String?> candidates) {
      for (final c in candidates) {
        if (c != null) {
          final trimmed = c.trim();
          if (trimmed.isNotEmpty && trimmed.toLowerCase() != 'null') {
            return trimmed;
          }
        }
      }
      return null;
    }

    final currentSeason = info.seasons
        .where((s) => s.seasonNumber == _selectedSeasonNumber)
        .firstOrNull;
    final fallbackImageUrl = firstNonEmptyUrl([
      currentSeason?.cover,
      info.backdrop,
      info.cover,
      _currentSeries.cover,
    ]);

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: episodes.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final ep = episodes[index];
        final prog = _episodesProgress[ep.id];

        return _EpisodeTile(
          episode: ep,
          progress: prog,
          fallbackImageUrl: fallbackImageUrl,
          onTap: () => _onEpisodeTap(ep),
        );
      },
    );
  }
}

/// Botão de Voltar em Pill estilizado
class _BackButtonPill extends StatefulWidget {
  final VoidCallback onBack;

  const _BackButtonPill({required this.onBack});

  @override
  State<_BackButtonPill> createState() => _BackButtonPillState();
}

class _BackButtonPillState extends State<_BackButtonPill> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onBack();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _isFocused ? AppColors.surfaceSecondary : AppColors.surfaceSecondary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _isFocused ? AppColors.focusCyan : AppColors.borderSubtle,
              width: _isFocused ? AppColors.focusBorderWidth : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_back_rounded,
                size: 16,
                color: _isFocused ? AppColors.focusCyan : AppColors.textPrimary,
              ),
              const SizedBox(width: 6),
              Text(
                'Voltar',
                style: TextStyle(
                  color: _isFocused ? AppColors.focusCyan : AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão Principal Silo com destaque intenso no foco do controle remoto
class _SiloPrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  const _SiloPrimaryButton({
    required this.label,
    required this.onTap,
    this.autofocus = true,
  });

  @override
  State<_SiloPrimaryButton> createState() => _SiloPrimaryButtonState();
}

class _SiloPrimaryButtonState extends State<_SiloPrimaryButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused ? AppColors.focusCyan : AppColors.primary,
              width: _isFocused ? AppColors.focusBorderWidth : 1.5,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.6),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.play_arrow_rounded,
                size: 26,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão de Favoritos Silo em Pill com destaque visual no controle remoto
class _SiloFavoriteButton extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onToggle;

  const _SiloFavoriteButton({
    required this.isFavorite,
    required this.onToggle,
  });

  @override
  State<_SiloFavoriteButton> createState() => _SiloFavoriteButtonState();
}

class _SiloFavoriteButtonState extends State<_SiloFavoriteButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onToggle();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
          decoration: BoxDecoration(
            color: _isFocused
                ? AppColors.surfaceSecondary
                : AppColors.surfaceSecondary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (widget.isFavorite ? AppColors.error.withValues(alpha: 0.6) : AppColors.borderSubtle),
              width: _isFocused ? AppColors.focusBorderWidth : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.45),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 20,
                color: widget.isFavorite ? AppColors.error : AppColors.textPrimary,
              ),
              const SizedBox(width: 8),
              Text(
                widget.isFavorite ? 'REMOVER DOS FAVORITOS' : 'ADICIONAR AOS FAVORITOS',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Seletor de Temporada em Pill com destaque ciano
class _SeasonChip extends StatefulWidget {
  final XtreamSeriesSeason season;
  final bool isSelected;
  final VoidCallback onSelected;

  const _SeasonChip({
    required this.season,
    required this.isSelected,
    required this.onSelected,
  });

  @override
  State<_SeasonChip> createState() => _SeasonChipState();
}

class _SeasonChipState extends State<_SeasonChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onSelected();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onSelected,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.primary.withValues(alpha: 0.22)
                : (_isFocused ? AppColors.surfaceSecondary : AppColors.surfaceSecondary.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (widget.isSelected ? AppColors.primary : AppColors.borderSubtle),
              width: _isFocused || widget.isSelected ? AppColors.focusBorderWidth : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Text(
            widget.season.name,
            style: TextStyle(
              color: widget.isSelected ? AppColors.primary : (_isFocused ? AppColors.focusCyan : AppColors.textSecondary),
              fontWeight: widget.isSelected || _isFocused ? FontWeight.bold : FontWeight.w500,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Linha de episódio com miniatura 16:9, destaque de foco e indicador de progresso
class _EpisodeTile extends StatefulWidget {
  final XtreamSeriesEpisode episode;
  final PlaybackProgress? progress;
  final String? fallbackImageUrl;
  final VoidCallback onTap;

  const _EpisodeTile({
    required this.episode,
    required this.progress,
    this.fallbackImageUrl,
    required this.onTap,
  });

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _isFocused = false;

  Widget _buildEpisodeThumbnail(
    XtreamSeriesEpisode ep,
    double width,
    double height,
  ) {
    final rawCover = ep.cover?.trim();
    final imageUrl = (rawCover != null &&
            rawCover.isNotEmpty &&
            rawCover.toLowerCase() != 'null')
        ? rawCover
        : widget.fallbackImageUrl;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _isFocused ? AppColors.focusCyan : AppColors.borderSubtle,
          width: _isFocused ? 1.6 : 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              Image.network(
                imageUrl,
                width: width,
                height: height,
                fit: BoxFit.cover,
                cacheWidth: 280,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _buildThumbnailFallback(),
              )
            else
              _buildThumbnailFallback(),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.45),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.35),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 5,
              left: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: _isFocused
                        ? AppColors.focusCyan
                        : Colors.white.withValues(alpha: 0.25),
                    width: 1,
                  ),
                ),
                child: Text(
                  'E${ep.episodeNum}',
                  style: TextStyle(
                    color: _isFocused ? AppColors.focusCyan : Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailFallback() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF141D2F), Color(0xFF0A0F1A)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_creation_outlined,
          color: AppColors.primary.withValues(alpha: 0.65),
          size: 26,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final prog = widget.progress;
    final hasProgress = prog != null && prog.canResume;
    final progressFraction = (hasProgress && prog.duration.inMilliseconds > 0)
        ? (prog.position.inMilliseconds / prog.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final isCompact = MediaQuery.sizeOf(context).width < 500;
    final thumbWidth = isCompact ? 112.0 : 136.0;
    final thumbHeight = isCompact ? 63.0 : 76.0;

    return FocusableActionDetector(
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _isFocused ? AppColors.surfaceSecondary : AppColors.surfaceSecondary.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (hasProgress ? AppColors.primary.withValues(alpha: 0.6) : AppColors.borderSubtle),
              width: _isFocused ? AppColors.focusBorderWidth : 1.0,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.4),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildEpisodeThumbnail(ep, thumbWidth, thumbHeight),
                  const SizedBox(width: 12),

                  // Título e Duração
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ep.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _isFocused ? AppColors.focusCyan : AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 8,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (ep.duration != null && ep.duration!.isNotEmpty)
                              Text(
                                ep.duration!,
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                              ),
                            if (hasProgress)
                              Text(
                                '•  ${PlaybackProgressService.formatDuration(prog.position)} assistido',
                                style: const TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 8),
                  // Ícone de Play
                  Icon(
                    Icons.play_circle_fill_rounded,
                    color: _isFocused ? AppColors.focusCyan : AppColors.primary,
                    size: 30,
                  ),
                ],
              ),

              // Barra de progresso visual se tiver progresso salvo
              if (hasProgress) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progressFraction,
                    minHeight: 3,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                ),
              ],

              // Sinopse do episódio (se disponível)
              if (ep.plot != null && ep.plot!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  ep.plot!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF8A99AD),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
