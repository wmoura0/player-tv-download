import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/xtream_series_info.dart';
import 'cloud_progress_sync_service.dart';
import 'user_profile_service.dart';

/// Representação do progresso de reprodução salvo para um filme.
class PlaybackProgress {
  final int streamId;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const PlaybackProgress({
    required this.streamId,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  /// Considera o filme concluído quando faltam menos de 45 segundos ou atingiu mais de 96%
  bool get isCompleted {
    if (duration.inSeconds <= 0) return false;
    final remainingSecs = duration.inSeconds - position.inSeconds;
    return remainingSecs <= 45 || (position.inSeconds / duration.inSeconds) >= 0.96;
  }

  /// Oferece retomar somente se assistiu pelo menos 10 segundos e ainda não concluiu
  bool get canResume {
    return position.inSeconds >= 10 && !isCompleted;
  }
}

/// Tipo de conteúdo no índice de continuar assistindo
enum ContinueWatchingType { movie, series }

/// Item do índice consolidado "Continuar Assistindo" para a tela inicial
class ContinueWatchingItem {
  final int streamId; // streamId do filme ou episodeId da série
  final int? seriesId; // seriesId quando for série
  final ContinueWatchingType type;
  final String title;
  final String? subtitle; // Ex: 'T1:E2'
  final String? coverUrl;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final String? containerExtension;
  final String? categoryId;
  final int? seasonNumber;
  final int? episodeNum;
  final DateTime? manualResetAt;

  const ContinueWatchingItem({
    required this.streamId,
    this.seriesId,
    required this.type,
    required this.title,
    this.subtitle,
    this.coverUrl,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.containerExtension,
    this.categoryId,
    this.seasonNumber,
    this.episodeNum,
    this.manualResetAt,
  });

  ContinueWatchingItem copyWith({
    int? streamId,
    int? seriesId,
    ContinueWatchingType? type,
    String? title,
    String? subtitle,
    String? coverUrl,
    Duration? position,
    Duration? duration,
    DateTime? updatedAt,
    String? containerExtension,
    String? categoryId,
    int? seasonNumber,
    int? episodeNum,
    DateTime? manualResetAt,
  }) {
    return ContinueWatchingItem(
      streamId: streamId ?? this.streamId,
      seriesId: seriesId ?? this.seriesId,
      type: type ?? this.type,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      coverUrl: coverUrl ?? this.coverUrl,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      updatedAt: updatedAt ?? this.updatedAt,
      containerExtension: containerExtension ?? this.containerExtension,
      categoryId: categoryId ?? this.categoryId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNum: episodeNum ?? this.episodeNum,
      manualResetAt: manualResetAt ?? this.manualResetAt,
    );
  }

  double get progressRatio {
    if (duration.inMilliseconds <= 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool get isCompleted {
    if (duration.inSeconds <= 0) return false;
    final remainingSecs = duration.inSeconds - position.inSeconds;
    return remainingSecs <= 45 || (position.inSeconds / duration.inSeconds) >= 0.96;
  }

  bool get canResume {
    if (isCompleted) return false;
    if (position.inSeconds >= 10) return true;
    // Séries com próximo episódio promovido com posição inicial zero podem ser retomadas
    if (type == ContinueWatchingType.series && position == Duration.zero && (episodeNum ?? 0) >= 1) {
      return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
    'streamId': streamId,
    'seriesId': seriesId,
    'type': type.name,
    'title': title,
    'subtitle': subtitle,
    'coverUrl': coverUrl,
    'pos': position.inMilliseconds,
    'dur': duration.inMilliseconds,
    'time': updatedAt.millisecondsSinceEpoch,
    'containerExtension': containerExtension,
    'categoryId': categoryId,
    'seasonNumber': seasonNumber,
    'episodeNum': episodeNum,
    if (manualResetAt != null) 'manualResetAt': manualResetAt!.millisecondsSinceEpoch,
  };

  factory ContinueWatchingItem.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'movie';
    final type = typeStr == 'series' ? ContinueWatchingType.series : ContinueWatchingType.movie;
    final posMs = json['pos'] as int? ?? 0;
    final durMs = json['dur'] as int? ?? 0;
    final timeMs = json['time'] as int? ?? 0;
    final resetMs = json['manualResetAt'] as int?;

    return ContinueWatchingItem(
      streamId: json['streamId'] as int? ?? 0,
      seriesId: json['seriesId'] as int?,
      type: type,
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      coverUrl: json['coverUrl'] as String?,
      position: Duration(milliseconds: posMs),
      duration: Duration(milliseconds: durMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      containerExtension: json['containerExtension'] as String?,
      categoryId: json['categoryId']?.toString(),
      seasonNumber: json['seasonNumber'] as int?,
      episodeNum: json['episodeNum'] as int?,
      manualResetAt: (resetMs != null && resetMs > 0)
          ? DateTime.fromMillisecondsSinceEpoch(resetMs)
          : null,
    );
  }
}

/// Serviço responsável por persistir e recuperar o progresso de filmes (VOD)
/// de forma associada à conta/servidor ativo, evitando conflito entre servidores.
class PlaybackProgressService {
  final SharedPreferences? prefs;

  PlaybackProgressService({this.prefs});

  Future<SharedPreferences> _getPrefs() async {
    return prefs ?? await SharedPreferences.getInstance();
  }

  /// Gera a chave de escopo da conta/servidor
  static String buildAccountKey(String serverUrl, String username) {
    final cleanServer = serverUrl.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final cleanUser = username.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return '${cleanServer}_$cleanUser';
  }

  String _effectiveAccountKey(String accountKey) {
    return UserProfileService.instance.getScopedKey(accountKey);
  }

  String _buildStorageKey(String accountKey, int streamId) {
    final effective = _effectiveAccountKey(accountKey);
    return 'vod_prog_${effective}_$streamId';
  }

  /// Salva a posição assistida de um filme.
  /// Se o filme estiver próximo do final, remove a chave para não retomar nos créditos finais.
  Future<void> saveProgress({
    required String accountKey,
    required int streamId,
    required Duration position,
    required Duration duration,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);

    final progress = PlaybackProgress(
      streamId: streamId,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );

    // Se estiver praticamente finalizado, limpa a posição salva
    if (progress.isCompleted) {
      await prefs.remove(key);
      return;
    }

    // Proteção contra gravações antigas concorrentes
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        final existing = jsonDecode(raw);
        final existingTime = existing['time'] as int?;
        if (existingTime != null && existingTime > progress.updatedAt.millisecondsSinceEpoch) {
          return;
        }
      } catch (_) {}
    }

    // Só grava se tiver assistido pelo menos 10 segundos
    if (position.inSeconds >= 10) {
      final data = {
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': progress.updatedAt.millisecondsSinceEpoch,
      };
      await prefs.setString(key, jsonEncode(data));
    }
  }

  /// Recupera o progresso de um filme. Retorna nulo se não houver progresso válido para retomar.
  Future<PlaybackProgress?> getProgress({
    required String accountKey,
    required int streamId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final posMs = data['pos'] as int? ?? 0;
      final durMs = data['dur'] as int? ?? 0;
      final timeMs = data['time'] as int? ?? 0;

      final progress = PlaybackProgress(
        streamId: streamId,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      );

      if (progress.canResume) {
        return progress;
      } else {
        // Se já concluiu ou tem menos de 10s, limpa do storage
        await prefs.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Limpa o progresso salvo de um filme (ex.: ao escolher "Assistir do início")
  Future<void> clearProgress({
    required String accountKey,
    required int streamId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);
    await prefs.remove(key);

    final listKey = _buildContinueWatchingKey(accountKey);
    final rawList = prefs.getStringList(listKey) ?? [];
    ContinueWatchingItem? existingItem;
    final filtered = <String>[];
    for (final raw in rawList) {
      try {
        final item = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (item.type == ContinueWatchingType.movie && item.streamId == streamId) {
          existingItem = item;
          continue;
        }
        filtered.add(raw);
      } catch (_) {}
    }
    if (existingItem != null) {
      await prefs.setStringList(listKey, filtered);
    }

    final now = DateTime.now();
    final resetItem = (existingItem ??
            ContinueWatchingItem(
              streamId: streamId,
              type: ContinueWatchingType.movie,
              title: 'VOD #$streamId',
              position: Duration.zero,
              duration: Duration.zero,
              updatedAt: now,
            ))
        .copyWith(
      position: Duration.zero,
      duration: Duration.zero,
      updatedAt: now,
      manualResetAt: now,
    );
    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: resetItem,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  // =========================================================================
  // PROGRESSO DE EPISÓDIOS DE SÉRIES (Isolado por conta, série e episódio)
  // =========================================================================

  String _buildEpisodeStorageKey(String accountKey, int seriesId, int episodeId) {
    final effective = _effectiveAccountKey(accountKey);
    return 'series_prog_${effective}_${seriesId}_$episodeId';
  }

  String _buildSeriesLastKey(String accountKey, int seriesId) {
    final effective = _effectiveAccountKey(accountKey);
    return 'series_last_${effective}_$seriesId';
  }

  /// Salva a posição assistida de um episódio de série.
  Future<void> saveEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
    required Duration position,
    required Duration duration,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);

    final progress = PlaybackProgress(
      streamId: episodeId,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );

    // Se estiver praticamente finalizado, limpa a posição salva
    if (progress.isCompleted) {
      await prefs.remove(key);
      return;
    }

    // Proteção contra gravações antigas concorrentes
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        final existing = jsonDecode(raw);
        final existingTime = existing['time'] as int?;
        if (existingTime != null && existingTime > progress.updatedAt.millisecondsSinceEpoch) {
          return;
        }
      } catch (_) {}
    }

    // Só grava se tiver assistido pelo menos 10 segundos
    if (position.inSeconds >= 10) {
      final data = {
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': progress.updatedAt.millisecondsSinceEpoch,
      };
      await prefs.setString(key, jsonEncode(data));
    }
  }

  /// Recupera o progresso de um episódio de série. Retorna nulo se não houver progresso válido para retomar.
  Future<PlaybackProgress?> getEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final posMs = data['pos'] as int? ?? 0;
      final durMs = data['dur'] as int? ?? 0;
      final timeMs = data['time'] as int? ?? 0;

      final progress = PlaybackProgress(
        streamId: episodeId,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      );

      if (progress.canResume) {
        return progress;
      } else {
        await prefs.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Limpa o progresso salvo de um episódio de série.
  Future<void> clearEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);
    await prefs.remove(key);
  }

  /// Salva a referência do último episódio assistido em uma série.
  Future<void> saveLastWatchedEpisode({
    required String accountKey,
    required int seriesId,
    required int episodeId,
    required int seasonNumber,
    required int episodeNum,
    bool isPromotedNext = false,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildSeriesLastKey(accountKey, seriesId);
    final data = {
      'episodeId': episodeId,
      'seasonNumber': seasonNumber,
      'episodeNum': episodeNum,
      'isPromotedNext': isPromotedNext,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(key, jsonEncode(data));
  }

  /// Recupera o último episódio assistido em uma série.
  Future<Map<String, int>?> getLastWatchedEpisode({
    required String accountKey,
    required int seriesId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildSeriesLastKey(accountKey, seriesId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      return {
        'episodeId': data['episodeId'] as int? ?? 0,
        'seasonNumber': data['seasonNumber'] as int? ?? 1,
        'episodeNum': data['episodeNum'] as int? ?? 1,
        'isPromotedNext': (data['isPromotedNext'] == true ? 1 : 0),
        'time': data['time'] as int? ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // ÍNDICE COMPLEMENTAR: CONTINUAR ASSISTINDO (HOME)
  // =========================================================================

  String _buildContinueWatchingKey(String accountKey) {
    final effective = _effectiveAccountKey(accountKey);
    return 'continue_watching_$effective';
  }

  /// Recupera a lista de conteúdos com progresso útil para continuar assistindo.
  /// Conteúdos concluídos ou inválidos são filtrados automaticamente.
  Future<List<ContinueWatchingItem>> getContinueWatchingList({
    required String accountKey,
  }) async {
    if (accountKey.trim().isEmpty) return [];
    final prefs = await _getPrefs();
    final key = _buildContinueWatchingKey(accountKey);
    final rawList = prefs.getStringList(key) ?? [];

    final result = <ContinueWatchingItem>[];
    for (final raw in rawList) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final item = ContinueWatchingItem.fromJson(map);
        if (item.canResume && item.title.isNotEmpty) {
          result.add(item);
        }
      } catch (_) {}
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// Salva ou atualiza um item no índice de continuar assistindo.
  Future<void> saveContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingItem item,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final key = _buildContinueWatchingKey(accountKey);

    final currentList = await getContinueWatchingList(accountKey: accountKey);
    final existingIndex = currentList.indexWhere((i) {
      if (i.type == item.type) {
        if (item.type == ContinueWatchingType.movie) {
          return i.streamId == item.streamId;
        } else {
          return (i.seriesId ?? i.streamId) == (item.seriesId ?? item.streamId);
        }
      }
      return false;
    });
    final existingItem = existingIndex >= 0 ? currentList[existingIndex] : null;

    var effectiveItem = item;
    if (existingItem != null &&
        existingItem.manualResetAt != null &&
        effectiveItem.manualResetAt == null &&
        !effectiveItem.isCompleted) {
      effectiveItem = effectiveItem.copyWith(
        manualResetAt: existingItem.manualResetAt,
      );
    }

    // Proteção contra gravações concorrentes desatualizadas:
    // Se o item persistido já possui timestamp posterior ao que está sendo gravado, ignora
    if (existingItem != null && existingItem.updatedAt.isAfter(effectiveItem.updatedAt)) {
      return;
    }

    currentList.removeWhere((i) {
      if (i.type == effectiveItem.type) {
        if (effectiveItem.type == ContinueWatchingType.movie) {
          return i.streamId == effectiveItem.streamId;
        } else {
          return (i.seriesId ?? i.streamId) == (effectiveItem.seriesId ?? effectiveItem.streamId);
        }
      }
      return false;
    });

    if (effectiveItem.canResume) {
      currentList.insert(0, effectiveItem);
    } else if (effectiveItem.isCompleted) {
      // Concluído normalmente: item removido do índice
    } else if (existingItem != null && existingItem.canResume) {
      // Proteção: se a sessão atual não atingiu o limite (ex.: saída durante carregamento/busca),
      // preserva o progresso anterior válido em vez de apagá-lo
      currentList.insert(0, existingItem);
    } else if (effectiveItem.type == ContinueWatchingType.series &&
        (effectiveItem.episodeNum ?? 0) >= 1 &&
        effectiveItem.position.inSeconds < 10) {
      // Se um episódio promovido (posição 0) ou recém-aberto foi fechado antes de 10s,
      // mantém o episódio na lista com posição 00:00 em vez de descartar a série da Home.
      currentList.insert(
        0,
        effectiveItem.copyWith(position: Duration.zero),
      );
    }

    currentList.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final capped = currentList.take(20).toList();
    final jsonList = capped.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(key, jsonList);

    if (effectiveItem.canResume ||
        effectiveItem.isCompleted ||
        effectiveItem.manualResetAt != null) {
      final isImmediate = effectiveItem.isCompleted ||
          effectiveItem.position == Duration.zero ||
          effectiveItem.manualResetAt != null;
      final shouldPush = await CloudProgressSyncService.instance
          .persistLocalLedgerChange(
        accountKey: accountKey,
        item: effectiveItem,
        immediatePush: isImmediate,
      );
      if (shouldPush) {
        CloudProgressSyncService.instance.triggerBackgroundSync(
          accountKey,
          progressService: this,
          force: isImmediate,
        );
      }
    }
  }

  /// Garante que uma série que possui episódio ativo para CONTINUAR ou PRÓXIMO
  /// esteja presente e sincronizada no índice "Continuar assistindo" da Home.
  /// Se o item já existir na lista com progresso igual ou mais avançado, não altera a ordem.
  Future<void> ensureContinueWatchingSeriesItem({
    required String accountKey,
    required ContinueWatchingItem item,
  }) async {
    if (accountKey.trim().isEmpty || !item.canResume) return;
    final currentList = await getContinueWatchingList(accountKey: accountKey);
    final existingIndex = currentList.indexWhere((i) {
      if (i.type == ContinueWatchingType.series) {
        return (i.seriesId ?? i.streamId) == (item.seriesId ?? item.streamId);
      }
      return false;
    });

    if (existingIndex >= 0) {
      final existing = currentList[existingIndex];
      // Se o item na Home já está no mesmo episódio (ou mais avançado) e na mesma posição, nada a fazer
      if (compareAdvancement(existing, item) >= 0 &&
          existing.streamId == item.streamId &&
          (existing.position.inSeconds - item.position.inSeconds).abs() < 2) {
        return;
      }
    }

    await saveContinueWatchingItem(
      accountKey: accountKey,
      item: item,
    );
  }

  /// Reconcilia automaticamente séries que possuem `series_last` ativo no dispositivo
  /// mas ficaram fora da lista `continue_watching` (ex.: saída nos créditos finais em versões anteriores).
  Future<bool> reconcileOrphanedSeriesContinueWatching({
    required String accountKey,
    Future<XtreamSeriesInfo?> Function(int seriesId)? getCachedSeriesInfo,
    String? Function(int seriesId)? getSeriesTitleSync,
    String? Function(int seriesId)? getSeriesCoverSync,
    String? Function(int seriesId)? getSeriesCategoryIdSync,
  }) async {
    if (accountKey.trim().isEmpty) return false;
    final prefs = await _getPrefs();
    final effective = _effectiveAccountKey(accountKey);
    final lastPrefix = 'series_last_${effective}_';

    final currentList = await getContinueWatchingList(accountKey: accountKey);
    final activeSeriesIds = <int>{};
    for (final item in currentList) {
      if (item.type == ContinueWatchingType.series) {
        activeSeriesIds.add(item.seriesId ?? item.streamId);
      }
    }

    final ledgerMap = await CloudProgressSyncService.instance
        .loadLocalLedgerForReconciliation(accountKey);

    bool addedAny = false;
    final allKeys = prefs.getKeys();
    for (final k in allKeys) {
      if (!k.startsWith(lastPrefix)) continue;
      final seriesIdStr = k.substring(lastPrefix.length);
      final seriesId = int.tryParse(seriesIdStr);
      if (seriesId == null || seriesId <= 0 || activeSeriesIds.contains(seriesId)) {
        continue;
      }

      final lastData = await getLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
      );
      if (lastData == null) continue;

      final lastEpId = lastData['episodeId'] ?? 0;
      final lastSeason = lastData['seasonNumber'] ?? 1;
      final lastEpNum = lastData['episodeNum'] ?? 1;
      final isPromotedNext = lastData['isPromotedNext'] == 1;
      final lastTimeMs = lastData['time'] ?? 0;

      if (lastEpId <= 0) continue;

      final cachedInfo = await getCachedSeriesInfo?.call(seriesId);
      final ledgerItem = ledgerMap['series_$seriesId'];
      // Se o usuário removeu manualmente no botão X da Home após o último registro de reprodução, respeita a remoção
      if (ledgerItem != null &&
          ledgerItem.isCompleted &&
          lastTimeMs > 0 &&
          ledgerItem.updatedAt.millisecondsSinceEpoch > lastTimeMs + 1000 &&
          !isPromotedNext) {
        final epProgCheck = await getEpisodeProgress(
          accountKey: accountKey,
          seriesId: seriesId,
          episodeId: lastEpId,
        );
        if (epProgCheck == null) {
          // Mas se existir próximo episódio no cache da série, foi conclusão de episódio nos créditos finais!
          if (cachedInfo == null) continue;
          final currentEp = cachedInfo.findEpisodeById(lastEpId) ??
              cachedInfo.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
          final nextEp = currentEp != null ? cachedInfo.getNextEpisode(currentEp) : null;
          if (nextEp == null) continue;
        }
      }

      final epProg = await getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: lastEpId,
      );

      XtreamSeriesEpisode? targetEp;
      Duration targetPos = Duration.zero;
      Duration targetDur = Duration.zero;

      if (epProg != null && epProg.canResume) {
        targetEp = cachedInfo?.findEpisodeById(lastEpId) ??
            cachedInfo?.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
        targetPos = epProg.position;
        targetDur = epProg.duration;
      } else if (isPromotedNext) {
        targetEp = cachedInfo?.findEpisodeById(lastEpId) ??
            cachedInfo?.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
        targetPos = Duration.zero;
        targetDur = (targetEp?.durationSecs != null && targetEp!.durationSecs! > 0)
            ? Duration(seconds: targetEp.durationSecs!)
            : Duration.zero;
      } else if (cachedInfo != null) {
        final lastEp = cachedInfo.findEpisodeById(lastEpId) ??
            cachedInfo.findEpisodeBySeasonAndNum(lastSeason, lastEpNum);
        if (lastEp != null) {
          final nextEp = cachedInfo.getNextEpisode(lastEp);
          if (nextEp != null) {
            targetEp = nextEp;
            final nextProg = await getEpisodeProgress(
              accountKey: accountKey,
              seriesId: seriesId,
              episodeId: nextEp.id,
            );
            targetPos = (nextProg != null && nextProg.canResume)
                ? nextProg.position
                : Duration.zero;
            targetDur = (nextProg != null && nextProg.duration > Duration.zero)
                ? nextProg.duration
                : ((nextEp.durationSecs != null && nextEp.durationSecs! > 0)
                    ? Duration(seconds: nextEp.durationSecs!)
                    : Duration.zero);
            await saveLastWatchedEpisode(
              accountKey: accountKey,
              seriesId: seriesId,
              episodeId: nextEp.id,
              seasonNumber: nextEp.seasonNumber,
              episodeNum: nextEp.episodeNum,
              isPromotedNext: targetPos == Duration.zero,
            );
          }
        }
      }

      if (targetEp == null && (epProg == null || !epProg.canResume) && !isPromotedNext) {
        continue;
      }

      final title = getSeriesTitleSync?.call(seriesId) ??
          cachedInfo?.name ??
          ledgerItem?.title ??
          '';
      if (title.trim().isEmpty || title.startsWith('Série #')) continue;

      final effSeason = targetEp?.seasonNumber ?? lastSeason;
      final effEpNum = targetEp?.episodeNum ?? lastEpNum;
      final effEpId = targetEp?.id ?? lastEpId;
      final effEpTitle = targetEp?.title ?? 'Episódio $effEpNum';
      final cover = targetEp?.cover ??
          getSeriesCoverSync?.call(seriesId) ??
          cachedInfo?.cover ??
          ledgerItem?.coverUrl;
      final categoryId = getSeriesCategoryIdSync?.call(seriesId) ??
          ledgerItem?.categoryId;
      final ext = targetEp?.containerExtension ?? ledgerItem?.containerExtension;
      final updatedAt = epProg?.updatedAt ??
          (lastTimeMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(lastTimeMs)
              : DateTime.now());

      await saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: effEpId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: title,
          subtitle: 'T$effSeason:E$effEpNum • $effEpTitle',
          coverUrl: cover,
          position: targetPos,
          duration: targetDur,
          updatedAt: updatedAt,
          containerExtension: ext,
          categoryId: categoryId,
          seasonNumber: effSeason,
          episodeNum: effEpNum,
        ),
      );
      addedAny = true;
    }

    return addedAny;
  }

  /// Remove um item específico do índice de continuar assistindo sem apagar o progresso existente.
  Future<void> removeContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final key = _buildContinueWatchingKey(accountKey);
    final currentList = await getContinueWatchingList(accountKey: accountKey);

    ContinueWatchingItem? removedItem;
    currentList.removeWhere((i) {
      if (i.type == type) {
        final matches = (type == ContinueWatchingType.movie)
            ? i.streamId == id
            : (i.seriesId ?? i.streamId) == id;
        if (matches) {
          removedItem = i;
        }
        return matches;
      }
      return false;
    });

    final jsonList = currentList.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(key, jsonList);

    final now = DateTime.now();
    int? lastSeason = removedItem?.seasonNumber;
    int? lastEpisodeNum = removedItem?.episodeNum;
    int streamId = removedItem?.streamId ?? id;
    if (removedItem == null && type == ContinueWatchingType.series) {
      final last = await getLastWatchedEpisode(accountKey: accountKey, seriesId: id);
      if (last != null) {
        streamId = (last['episodeId'] ?? 0) > 0 ? last['episodeId']! : id;
        lastSeason = last['seasonNumber'];
        lastEpisodeNum = last['episodeNum'];
      }
    }
    final dur = (removedItem != null && removedItem!.duration > Duration.zero)
        ? removedItem!.duration
        : const Duration(seconds: 60);
    final completedTombstone = (removedItem ??
            ContinueWatchingItem(
              streamId: streamId,
              seriesId: type == ContinueWatchingType.series ? id : null,
              type: type,
              title: type == ContinueWatchingType.series ? 'Série #$id' : 'VOD #$id',
              position: dur,
              duration: dur,
              updatedAt: now,
              seasonNumber: lastSeason,
              episodeNum: lastEpisodeNum,
            ))
        .copyWith(
      streamId: streamId,
      position: dur,
      duration: dur,
      updatedAt: now,
      seasonNumber: lastSeason,
      episodeNum: lastEpisodeNum,
    );
    final shouldPush = await CloudProgressSyncService.instance
        .persistLocalLedgerChange(
      accountKey: accountKey,
      item: completedTombstone,
      immediatePush: true,
    );
    if (shouldPush) {
      CloudProgressSyncService.instance.triggerBackgroundSync(
        accountKey,
        progressService: this,
        force: true,
      );
    }
  }

  /// Aplica localmente um item vencedor vindo da sincronização em nuvem sem disparar reenvio.
  Future<void> applySyncedItem({
    required String accountKey,
    required ContinueWatchingItem item,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();

    if (item.type == ContinueWatchingType.movie) {
      final progKey = _buildStorageKey(accountKey, item.streamId);
      final shouldClear = item.isCompleted ||
          (item.manualResetAt != null && item.position.inSeconds < 10);
      if (shouldClear) {
        await prefs.remove(progKey);
        await _upsertOrRemoveContinueWatchingLocal(
          prefs: prefs,
          accountKey: accountKey,
          item: item,
          remove: true,
        );
      } else {
        if (item.position.inSeconds >= 10 && item.duration > Duration.zero) {
          await prefs.setString(
            progKey,
            jsonEncode({
              'pos': item.position.inMilliseconds,
              'dur': item.duration.inMilliseconds,
              'time': item.updatedAt.millisecondsSinceEpoch,
            }),
          );
        }
        await _upsertOrRemoveContinueWatchingLocal(
          prefs: prefs,
          accountKey: accountKey,
          item: item,
          remove: !item.canResume,
        );
      }
      return;
    }

    // Série
    final seriesId = item.seriesId ?? item.streamId;
    final oldLast = await getLastWatchedEpisode(
      accountKey: accountKey,
      seriesId: seriesId,
    );
    if (oldLast != null &&
        oldLast['episodeId'] != null &&
        oldLast['episodeId'] != item.streamId) {
      await prefs.remove(
        _buildEpisodeStorageKey(accountKey, seriesId, oldLast['episodeId']!),
      );
    }

    final epProgKey = _buildEpisodeStorageKey(accountKey, seriesId, item.streamId);
    final lastKey = _buildSeriesLastKey(accountKey, seriesId);

    if (item.isCompleted) {
      await prefs.remove(epProgKey);
      await prefs.setString(
        lastKey,
        jsonEncode({
          'episodeId': item.streamId,
          'seasonNumber': item.seasonNumber ?? 1,
          'episodeNum': item.episodeNum ?? 1,
          'isPromotedNext': false,
          'time': item.updatedAt.millisecondsSinceEpoch,
        }),
      );
      await _upsertOrRemoveContinueWatchingLocal(
        prefs: prefs,
        accountKey: accountKey,
        item: item,
        remove: true,
      );
      return;
    }

    if (item.manualResetAt != null &&
        item.position.inSeconds < 10 &&
        (item.seasonNumber ?? 1) <= 1 &&
        (item.episodeNum ?? 1) <= 1) {
      await prefs.remove(epProgKey);
      await prefs.remove(lastKey);
      await _upsertOrRemoveContinueWatchingLocal(
        prefs: prefs,
        accountKey: accountKey,
        item: item,
        remove: true,
      );
      return;
    }

    final isPromotedNext = item.position == Duration.zero && item.canResume;
    await prefs.setString(
      lastKey,
      jsonEncode({
        'episodeId': item.streamId,
        'seasonNumber': item.seasonNumber ?? 1,
        'episodeNum': item.episodeNum ?? 1,
        'isPromotedNext': isPromotedNext,
        'time': item.updatedAt.millisecondsSinceEpoch,
      }),
    );

    if (item.position.inSeconds >= 10 && item.duration > Duration.zero) {
      await prefs.setString(
        epProgKey,
        jsonEncode({
          'pos': item.position.inMilliseconds,
          'dur': item.duration.inMilliseconds,
          'time': item.updatedAt.millisecondsSinceEpoch,
        }),
      );
    } else if (item.position == Duration.zero) {
      await prefs.remove(epProgKey);
    }

    await _upsertOrRemoveContinueWatchingLocal(
      prefs: prefs,
      accountKey: accountKey,
      item: item,
      remove: !item.canResume,
    );
  }

  Future<void> _upsertOrRemoveContinueWatchingLocal({
    required SharedPreferences prefs,
    required String accountKey,
    required ContinueWatchingItem item,
    required bool remove,
  }) async {
    final key = _buildContinueWatchingKey(accountKey);
    final rawList = prefs.getStringList(key) ?? [];
    final currentList = <ContinueWatchingItem>[];
    for (final raw in rawList) {
      try {
        final parsed = ContinueWatchingItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (parsed.type == item.type) {
          final matches = (item.type == ContinueWatchingType.movie)
              ? parsed.streamId == item.streamId
              : (parsed.seriesId ?? parsed.streamId) ==
                  (item.seriesId ?? item.streamId);
          if (matches) continue;
        }
        if (parsed.canResume && parsed.title.isNotEmpty) {
          currentList.add(parsed);
        }
      } catch (_) {}
    }
    if (!remove && item.canResume && item.title.isNotEmpty) {
      currentList.add(item);
    }
    currentList.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final capped = currentList.take(20).toList();
    await prefs.setStringList(
      key,
      capped.map((i) => jsonEncode(i.toJson())).toList(),
    );
  }

  /// Compara dois estados de reprodução para determinar qual está mais avançado.
  /// Retorna > 0 quando [a] está mais avançado que [b], < 0 quando [b] está mais avançado e 0 em empate exato.
  static int compareAdvancement(ContinueWatchingItem a, ContinueWatchingItem b) {
    if (a.type != b.type) {
      return a.updatedAt.compareTo(b.updatedAt);
    }

    if (a.type == ContinueWatchingType.movie) {
      if (a.isCompleted != b.isCompleted) {
        return a.isCompleted ? 1 : -1;
      }
      final posCmp = a.position.inMilliseconds.compareTo(b.position.inMilliseconds);
      if (posCmp != 0) return posCmp;
      return a.updatedAt.compareTo(b.updatedAt);
    }

    // Séries: temporada -> episódio -> conclusão -> posição -> timestamp
    final sCmp = (a.seasonNumber ?? 1).compareTo(b.seasonNumber ?? 1);
    if (sCmp != 0) return sCmp;

    final eCmp = (a.episodeNum ?? 1).compareTo(b.episodeNum ?? 1);
    if (eCmp != 0) return eCmp;

    final cCmp = (a.isCompleted ? 1 : 0).compareTo(b.isCompleted ? 1 : 0);
    if (cCmp != 0) return cCmp;

    final posCmp = a.position.inMilliseconds.compareTo(b.position.inMilliseconds);
    if (posCmp != 0) return posCmp;

    return a.updatedAt.compareTo(b.updatedAt);
  }

  /// Seleciona o item prevalente entre o estado [local] e o [remote] dando prioridade
  /// absoluta ao progresso mais avançado, exceto quando houver reinício manual explícito posterior.
  static ContinueWatchingItem pickMoreAdvanced(
    ContinueWatchingItem local,
    ContinueWatchingItem remote,
  ) {
    final localReset = local.manualResetAt;
    final remoteReset = remote.manualResetAt;

    ContinueWatchingItem winner;
    ContinueWatchingItem loser;

    if (localReset != null &&
        localReset.isAfter(remote.updatedAt) &&
        (remoteReset == null || localReset.isAfter(remoteReset))) {
      winner = local;
      loser = remote;
    } else if (remoteReset != null &&
        remoteReset.isAfter(local.updatedAt) &&
        (localReset == null || remoteReset.isAfter(localReset))) {
      winner = remote;
      loser = local;
    } else if (compareAdvancement(local, remote) >= 0) {
      winner = local;
      loser = remote;
    } else {
      winner = remote;
      loser = local;
    }

    final mergedCover = (winner.coverUrl != null && winner.coverUrl!.trim().isNotEmpty)
        ? winner.coverUrl
        : loser.coverUrl;
    final mergedExt = (winner.containerExtension != null && winner.containerExtension!.trim().isNotEmpty)
        ? winner.containerExtension
        : loser.containerExtension;
    final mergedCat = (winner.categoryId != null && winner.categoryId!.trim().isNotEmpty)
        ? winner.categoryId
        : loser.categoryId;

    return winner.copyWith(
      coverUrl: mergedCover,
      containerExtension: mergedExt,
      categoryId: mergedCat,
    );
  }

  /// Formata uma duração em string legível (ex: 01:23:45 ou 05:30)
  static String formatDuration(Duration duration) {
    if (duration.isNegative) return '00:00';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    final mStr = minutes.toString().padLeft(2, '0');
    final sStr = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      final hStr = hours.toString().padLeft(2, '0');
      return '$hStr:$mStr:$sStr';
    }
    return '$mStr:$sStr';
  }
}
