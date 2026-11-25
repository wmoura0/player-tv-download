// Modelos para informações detalhadas de séries, temporadas e episódios
// obtidos a partir do endpoint get_series_info da API Xtream Codes.

class XtreamSeriesEpisode {
  final int id;
  final int? streamId;
  final int episodeNum;
  final String title;
  final String? containerExtension;
  final int seasonNumber;
  final String? plot;
  final String? duration;
  final int? durationSecs;
  final String? cover;
  final String? rating;
  final String? directSource;

  const XtreamSeriesEpisode({
    required this.id,
    this.streamId,
    required this.episodeNum,
    required this.title,
    this.containerExtension,
    required this.seasonNumber,
    this.plot,
    this.duration,
    this.durationSecs,
    this.cover,
    this.rating,
    this.directSource,
  });

  /// Retorna o ID canônico prioritário para reprodução (o stream_id real do servidor)
  int get playbackStreamId => id;

  factory XtreamSeriesEpisode.fromJson(
    Map<String, dynamic> json, {
    required int fallbackSeasonNumber,
    int? fallbackEpisodeNum,
  }) {
    final info = (json['info'] is Map<String, dynamic>)
        ? json['info'] as Map<String, dynamic>
        : (json['info'] is Map)
            ? Map<String, dynamic>.from(json['info'] as Map)
            : <String, dynamic>{};

    final rawEpNum = json['episode_num'] ?? json['episode_number'] ?? info['episode_num'] ?? fallbackEpisodeNum;
    final episodeNum = int.tryParse(rawEpNum?.toString() ?? '') ?? fallbackEpisodeNum ?? 1;

    final rawSeason = json['season'] ?? json['season_number'] ?? info['season'] ?? fallbackSeasonNumber;
    final seasonNumber = int.tryParse(rawSeason?.toString() ?? '') ?? fallbackSeasonNumber;

    // Resolução inteligente e robusta do ID real de reprodução:
    final rawStreamId = json['stream_id'] ?? info['stream_id'];
    final parsedStreamId = int.tryParse(rawStreamId?.toString() ?? '');

    final rawEpisodeId = json['episode_id'] ?? info['episode_id'];
    final parsedEpisodeId = int.tryParse(rawEpisodeId?.toString() ?? '');

    final rawJsonId = json['id'];
    final parsedJsonId = int.tryParse(rawJsonId?.toString() ?? '');

    final rawInfoId = info['id'];
    final parsedInfoId = int.tryParse(rawInfoId?.toString() ?? '');

    final rawCustomSid = json['custom_sid'] ?? info['custom_sid'];
    final parsedCustomSid = int.tryParse(rawCustomSid?.toString() ?? '');

    // Se json['id'] for apenas o índice ordinal do episódio e info['id'] for o ID global, prioriza o global
    final int? parsedId;
    if (parsedJsonId != null && parsedJsonId == episodeNum && parsedInfoId != null && parsedInfoId != episodeNum) {
      parsedId = parsedInfoId;
    } else {
      parsedId = parsedJsonId ?? parsedInfoId;
    }

    int resolvedId = 0;
    int? altId;

    if (parsedStreamId != null && parsedStreamId > 0 && parsedId != null && parsedId > 0) {
      if (parsedStreamId == parsedId) {
        resolvedId = parsedStreamId;
        altId = (parsedEpisodeId != null && parsedEpisodeId != parsedStreamId && parsedEpisodeId != episodeNum)
            ? parsedEpisodeId
            : null;
      } else if (parsedId == episodeNum && parsedStreamId != episodeNum) {
        // "id" era apenas o índice/número do episódio (ex: 64, 105) e "stream_id" é o identificador real do arquivo
        resolvedId = parsedStreamId;
        altId = parsedId;
      } else if (parsedStreamId == episodeNum && parsedId != episodeNum) {
        // "stream_id" era apenas o índice/número do episódio e "id" é o identificador real do arquivo
        resolvedId = parsedId;
        altId = parsedStreamId;
      } else {
        // Quando nenhum dos dois coincide com o número do episódio,
        // se um deles for nitidamente o ID global do banco Xtream (ex: > 1000 enquanto o outro <= 500 ou 5x maior),
        // o identificador global é priorizado.
        if (parsedId > 1000 && parsedStreamId <= 500) {
          resolvedId = parsedId;
          altId = parsedStreamId;
        } else if (parsedStreamId > 1000 && parsedId <= 500) {
          resolvedId = parsedStreamId;
          altId = parsedId;
        } else if (parsedId > parsedStreamId * 5) {
          resolvedId = parsedId;
          altId = parsedStreamId;
        } else {
          resolvedId = parsedStreamId;
          altId = parsedId;
        }
      }
    } else if (parsedStreamId != null && parsedStreamId > 0) {
      resolvedId = parsedStreamId;
      altId = (parsedEpisodeId != null && parsedEpisodeId != parsedStreamId)
          ? parsedEpisodeId
          : (parsedId != null && parsedId != parsedStreamId ? parsedId : null);
    } else if (parsedId != null && parsedId > 0) {
      resolvedId = parsedId;
      altId = (parsedEpisodeId != null && parsedEpisodeId != parsedId) ? parsedEpisodeId : null;
    } else if (parsedEpisodeId != null && parsedEpisodeId > 0) {
      resolvedId = parsedEpisodeId;
    }

    if (altId == null) {
      if (parsedCustomSid != null && parsedCustomSid > 0 && parsedCustomSid != resolvedId) {
        altId = parsedCustomSid;
      } else if (parsedJsonId != null && parsedJsonId > 0 && parsedJsonId != resolvedId) {
        altId = parsedJsonId;
      } else if (parsedInfoId != null && parsedInfoId > 0 && parsedInfoId != resolvedId) {
        altId = parsedInfoId;
      }
    }

    final rawTitle = json['title']?.toString() ?? info['title']?.toString() ?? json['name']?.toString() ?? 'Episódio $episodeNum';
    final title = rawTitle.trim().isNotEmpty ? rawTitle.trim() : 'Episódio $episodeNum';

    final rawExt = json['container_extension']?.toString() ??
        info['container_extension']?.toString() ??
        json['extension']?.toString() ??
        info['extension']?.toString() ??
        json['video_type']?.toString() ??
        info['video_type']?.toString();
    final containerExtension = (rawExt != null && rawExt.trim().isNotEmpty)
        ? rawExt.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        : null;

    final rawPlot = info['plot']?.toString() ?? json['plot']?.toString() ?? info['overview']?.toString();
    final plot = (rawPlot != null && rawPlot.trim().isNotEmpty) ? rawPlot.trim() : null;

    final rawDuration = info['duration']?.toString() ?? json['duration']?.toString();
    final duration = (rawDuration != null && rawDuration.trim().isNotEmpty) ? rawDuration.trim() : null;

    final rawDurationSecs = info['duration_secs'] ?? info['duration_seconds'] ?? json['duration_secs'];
    final durationSecs = int.tryParse(rawDurationSecs?.toString() ?? '');

    String? pickNonEmptyImage(List<dynamic> candidates) {
      for (final raw in candidates) {
        if (raw == null) continue;
        final trimmed = raw.toString().trim();
        if (trimmed.isNotEmpty && trimmed.toLowerCase() != 'null') {
          return trimmed;
        }
      }
      return null;
    }

    final cover = pickNonEmptyImage([
      info['movie_image'],
      info['episode_image'],
      info['still_path'],
      json['movie_image'],
      json['episode_image'],
      json['still_path'],
      json['cover'],
      info['cover_big'],
      json['cover_big'],
      info['cover'],
      json['stream_icon'],
      info['image'],
      json['image'],
    ]);

    final rawRating = info['rating']?.toString() ?? json['rating']?.toString();
    final rating = (rawRating != null && rawRating.trim().isNotEmpty) ? rawRating.trim() : null;

    final rawDirect = json['direct_source']?.toString();
    final directSource = (rawDirect != null && rawDirect.trim().isNotEmpty) ? rawDirect.trim() : null;

    return XtreamSeriesEpisode(
      id: resolvedId,
      streamId: altId,
      episodeNum: episodeNum,
      title: title,
      containerExtension: containerExtension,
      seasonNumber: seasonNumber,
      plot: plot,
      duration: duration,
      durationSecs: durationSecs,
      cover: cover,
      rating: rating,
      directSource: directSource,
    );
  }
}

class XtreamSeriesSeason {
  final int seasonNumber;
  final String name;
  final int? episodeCount;
  final String? airDate;
  final String? overview;
  final String? cover;

  const XtreamSeriesSeason({
    required this.seasonNumber,
    required this.name,
    this.episodeCount,
    this.airDate,
    this.overview,
    this.cover,
  });

  factory XtreamSeriesSeason.fromJson(Map<String, dynamic> json, {int? fallbackSeasonNumber}) {
    final rawNumber = json['season_number'] ?? json['season'] ?? fallbackSeasonNumber;
    final parsedNum = int.tryParse(rawNumber?.toString() ?? '') ??
        int.tryParse(RegExp(r'\d+').firstMatch(rawNumber?.toString() ?? '')?.group(0) ?? '');
    final seasonNumber = parsedNum ?? fallbackSeasonNumber ?? 1;

    final rawName = json['name']?.toString().trim();
    final name = (rawName != null && rawName.isNotEmpty) ? rawName : 'Temporada $seasonNumber';

    final rawCount = json['episode_count'] ?? json['episodes_count'];
    final episodeCount = int.tryParse(rawCount?.toString() ?? '');

    final rawDate = json['air_date']?.toString().trim();
    final airDate = (rawDate != null && rawDate.isNotEmpty) ? rawDate : null;

    final rawOverview = json['overview']?.toString().trim();
    final overview = (rawOverview != null && rawOverview.isNotEmpty) ? rawOverview : null;

    final rawCover = json['cover']?.toString() ?? json['cover_big']?.toString();
    final cover = (rawCover != null && rawCover.trim().isNotEmpty) ? rawCover.trim() : null;

    return XtreamSeriesSeason(
      seasonNumber: seasonNumber,
      name: name,
      episodeCount: episodeCount,
      airDate: airDate,
      overview: overview,
      cover: cover,
    );
  }
}

class XtreamSeriesInfo {
  final String name;
  final String? serverReturnedName;
  final String? cover;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final String? rating;
  final String? backdrop;
  final String? youtubeTrailer;
  final String? episodeRunTime;
  final List<XtreamSeriesSeason> seasons;
  final Map<int, List<XtreamSeriesEpisode>> episodesBySeason;
  final String rawEpisodesShape;
  final int rawEpisodeEntriesCount;
  final int skippedEpisodeEntriesCount;

  const XtreamSeriesInfo({
    required this.name,
    this.serverReturnedName,
    this.cover,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.rating,
    this.backdrop,
    this.youtubeTrailer,
    this.episodeRunTime,
    required this.seasons,
    required this.episodesBySeason,
    this.rawEpisodesShape = 'unknown',
    this.rawEpisodeEntriesCount = 0,
    this.skippedEpisodeEntriesCount = 0,
  });

  int get totalEpisodeCount =>
      episodesBySeason.values.fold<int>(0, (sum, list) => sum + list.length);

  static int? _parseSeasonKey(dynamic key) {
    if (key == null) return null;
    if (key is int) return key;
    final str = key.toString().trim();
    if (str.isEmpty) return null;
    final direct = int.tryParse(str);
    if (direct != null) return direct;
    final m = RegExp(r'\d+').firstMatch(str);
    return m != null ? int.tryParse(m.group(0)!) : null;
  }

  static bool _looksLikeEpisodeObject(Map raw) {
    return raw.containsKey('id') ||
        raw.containsKey('stream_id') ||
        raw.containsKey('episode_id') ||
        raw.containsKey('episode_num') ||
        raw.containsKey('episode_number') ||
        raw.containsKey('container_extension') ||
        raw.containsKey('direct_source');
  }

  factory XtreamSeriesInfo.fromJson(
    Map<String, dynamic> json, {
    String? fallbackName,
    String? fallbackCover,
    String? fallbackPlot,
  }) {
    final info = (json['info'] is Map<String, dynamic>)
        ? json['info'] as Map<String, dynamic>
        : (json['info'] is Map)
            ? Map<String, dynamic>.from(json['info'] as Map)
            : <String, dynamic>{};

    final rawInfoName = info['name']?.toString().trim();
    final serverReturnedName =
        (rawInfoName != null && rawInfoName.isNotEmpty) ? rawInfoName : null;
    final cleanFallback = fallbackName?.trim();
    final name = serverReturnedName ??
        ((cleanFallback != null && cleanFallback.isNotEmpty)
            ? cleanFallback
            : 'Série sem título');

    final rawCover = info['cover']?.toString() ?? info['cover_big']?.toString() ?? fallbackCover;
    final cover = (rawCover != null && rawCover.trim().isNotEmpty) ? rawCover.trim() : null;

    final rawPlot = info['plot']?.toString() ?? fallbackPlot;
    final plot = (rawPlot != null && rawPlot.trim().isNotEmpty) ? rawPlot.trim() : null;

    final rawCast = info['cast']?.toString().trim();
    final cast = (rawCast != null && rawCast.isNotEmpty) ? rawCast : null;

    final rawDirector = info['director']?.toString().trim();
    final director = (rawDirector != null && rawDirector.isNotEmpty) ? rawDirector : null;

    final rawGenre = info['genre']?.toString().trim();
    final genre = (rawGenre != null && rawGenre.isNotEmpty) ? rawGenre : null;

    final rawReleaseDate = info['releaseDate']?.toString() ?? info['releasedate']?.toString();
    final releaseDate = (rawReleaseDate != null && rawReleaseDate.trim().isNotEmpty) ? rawReleaseDate.trim() : null;

    final rawRating = info['rating']?.toString().trim();
    final rating = (rawRating != null && rawRating.isNotEmpty) ? rawRating : null;

    String? backdropUrl;
    final rawBackdrop = info['backdrop_path'];
    if (rawBackdrop is List && rawBackdrop.isNotEmpty) {
      backdropUrl = rawBackdrop.first?.toString();
    } else if (rawBackdrop is String && rawBackdrop.isNotEmpty) {
      backdropUrl = rawBackdrop;
    }

    final rawTrailer = info['youtube_trailer']?.toString().trim();
    final youtubeTrailer = (rawTrailer != null && rawTrailer.isNotEmpty) ? rawTrailer : null;

    final rawRunTime = info['episode_run_time']?.toString().trim();
    final episodeRunTime = (rawRunTime != null && rawRunTime.isNotEmpty) ? rawRunTime : null;

    // 1. Processar Episódios organizados por temporada (suportando variações reais de servidores Xtream)
    final episodesMap = <int, List<XtreamSeriesEpisode>>{};
    final rawEpisodes = json['episodes'];
    var rawEpisodesShape = 'null';
    var rawEntriesCount = 0;
    var skippedEntriesCount = 0;
    final perSeasonCounters = <int, int>{};

    void addEpisodeFromMap(
      Map epRaw, {
      required int fallbackSeason,
      int? fallbackEpNum,
    }) {
      rawEntriesCount++;
      final epMap = Map<String, dynamic>.from(epRaw);
      final epSeasonHint =
          _parseSeasonKey(epMap['season'] ?? epMap['season_number']) ??
              fallbackSeason;
      final nextOrdinal = (perSeasonCounters[epSeasonHint] ?? 0) + 1;
      final ep = XtreamSeriesEpisode.fromJson(
        epMap,
        fallbackSeasonNumber: epSeasonHint,
        fallbackEpisodeNum: fallbackEpNum ?? nextOrdinal,
      );
      if (ep.id <= 0) {
        skippedEntriesCount++;
        return;
      }
      perSeasonCounters[ep.seasonNumber] =
          (perSeasonCounters[ep.seasonNumber] ?? 0) + 1;
      episodesMap.putIfAbsent(ep.seasonNumber, () => []).add(ep);
    }

    if (rawEpisodes is Map) {
      if (rawEpisodes.isEmpty) {
        rawEpisodesShape = 'empty_map';
      } else {
        var sawListValue = false;
        var sawMapValue = false;
        rawEpisodes.forEach((key, val) {
          final seasonNum = _parseSeasonKey(key) ?? 1;
          if (val is List) {
            sawListValue = true;
            for (var i = 0; i < val.length; i++) {
              final epJson = val[i];
              if (epJson is Map) {
                addEpisodeFromMap(
                  epJson,
                  fallbackSeason: seasonNum,
                  fallbackEpNum: i + 1,
                );
              } else if (epJson != null) {
                rawEntriesCount++;
                skippedEntriesCount++;
              }
            }
          } else if (val is Map) {
            sawMapValue = true;
            if (_looksLikeEpisodeObject(val)) {
              addEpisodeFromMap(val, fallbackSeason: seasonNum);
            } else {
              // Mapa de episódios indexados por chave (ex.: PHP {"1": {ep1}, "2": {ep2}})
              var idx = 0;
              val.forEach((innerKey, innerVal) {
                if (innerVal is Map) {
                  idx++;
                  final innerEpHint = _parseSeasonKey(innerKey) ?? idx;
                  addEpisodeFromMap(
                    innerVal,
                    fallbackSeason: seasonNum,
                    fallbackEpNum: innerEpHint > 0 && innerEpHint < 10000
                        ? null
                        : idx,
                  );
                } else if (innerVal != null) {
                  rawEntriesCount++;
                  skippedEntriesCount++;
                }
              });
            }
          }
        });
        if (sawMapValue && !sawListValue) {
          rawEpisodesShape = 'map_of_maps';
        } else if (sawListValue && sawMapValue) {
          rawEpisodesShape = 'mixed_map';
        } else if (sawListValue) {
          rawEpisodesShape = 'map_of_lists';
        } else {
          rawEpisodesShape = 'map_other';
        }
      }
    } else if (rawEpisodes is List) {
      if (rawEpisodes.isEmpty) {
        rawEpisodesShape = 'empty_list';
      } else {
        var sawNestedList = false;
        var sawFlatMap = false;
        for (var i = 0; i < rawEpisodes.length; i++) {
          final entry = rawEpisodes[i];
          if (entry is List) {
            sawNestedList = true;
            final listSeasonHint = i == 0 && rawEpisodes.first == null ? 1 : i + 1;
            for (var j = 0; j < entry.length; j++) {
              final epJson = entry[j];
              if (epJson is Map) {
                addEpisodeFromMap(
                  epJson,
                  fallbackSeason: listSeasonHint,
                  fallbackEpNum: j + 1,
                );
              } else if (epJson != null) {
                rawEntriesCount++;
                skippedEntriesCount++;
              }
            }
          } else if (entry is Map) {
            sawFlatMap = true;
            final seasonNum =
                _parseSeasonKey(entry['season'] ?? entry['season_number']) ?? 1;
            addEpisodeFromMap(entry, fallbackSeason: seasonNum);
          } else if (entry != null) {
            rawEntriesCount++;
            skippedEntriesCount++;
          }
        }
        if (sawNestedList && !sawFlatMap) {
          rawEpisodesShape = 'nested_list';
        } else if (sawNestedList && sawFlatMap) {
          rawEpisodesShape = 'mixed_list';
        } else if (sawFlatMap) {
          rawEpisodesShape = 'flat_list';
        } else {
          rawEpisodesShape = 'list_other';
        }
      }
    } else if (rawEpisodes != null) {
      rawEpisodesShape = 'other_${rawEpisodes.runtimeType}';
    }

    // Ordenar episódios dentro de cada temporada pelo número do episódio
    episodesMap.forEach((seasonNum, list) {
      list.sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
    });

    // 2. Processar e deduplicar Temporadas
    final seasonsByNumber = <int, XtreamSeriesSeason>{};
    final rawSeasons = json['seasons'];

    void registerSeason(XtreamSeriesSeason s) {
      final existing = seasonsByNumber[s.seasonNumber];
      if (existing == null) {
        seasonsByNumber[s.seasonNumber] = s;
      } else {
        // Prefere o registro com mais metadados sem perder contagem real
        seasonsByNumber[s.seasonNumber] = XtreamSeriesSeason(
          seasonNumber: s.seasonNumber,
          name: s.name != 'Temporada ${s.seasonNumber}' ? s.name : existing.name,
          episodeCount: s.episodeCount ?? existing.episodeCount,
          airDate: s.airDate ?? existing.airDate,
          overview: s.overview ?? existing.overview,
          cover: s.cover ?? existing.cover,
        );
      }
    }

    if (rawSeasons is List) {
      for (var i = 0; i < rawSeasons.length; i++) {
        final sJson = rawSeasons[i];
        if (sJson is Map) {
          registerSeason(
            XtreamSeriesSeason.fromJson(
              Map<String, dynamic>.from(sJson),
            ),
          );
        }
      }
    } else if (rawSeasons is Map) {
      rawSeasons.forEach((key, val) {
        if (val is Map) {
          final fallbackNum = _parseSeasonKey(key);
          registerSeason(
            XtreamSeriesSeason.fromJson(
              Map<String, dynamic>.from(val),
              fallbackSeasonNumber: fallbackNum,
            ),
          );
        }
      });
    }

    // Se o servidor não enviou array seasons ou omitiu temporadas existentes nos episódios,
    // sintetiza as temporadas a partir das chaves do mapa de episódios
    for (final seasonNum in episodesMap.keys) {
      if (!seasonsByNumber.containsKey(seasonNum)) {
        seasonsByNumber[seasonNum] = XtreamSeriesSeason(
          seasonNumber: seasonNum,
          name: 'Temporada $seasonNum',
          episodeCount: episodesMap[seasonNum]?.length,
        );
      }
    }

    // Ordenar as temporadas crescentemente pelo número da temporada
    final seasonsList = seasonsByNumber.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));

    return XtreamSeriesInfo(
      name: name,
      serverReturnedName: serverReturnedName,
      cover: cover,
      plot: plot,
      cast: cast,
      director: director,
      genre: genre,
      releaseDate: releaseDate,
      rating: rating,
      backdrop: backdropUrl,
      youtubeTrailer: youtubeTrailer,
      episodeRunTime: episodeRunTime,
      seasons: seasonsList,
      episodesBySeason: episodesMap,
      rawEpisodesShape: rawEpisodesShape,
      rawEpisodeEntriesCount: rawEntriesCount,
      skippedEpisodeEntriesCount: skippedEntriesCount,
    );
  }

  /// Localiza um episódio pelo seu ID (ou streamId alternativo) em qualquer temporada.
  XtreamSeriesEpisode? findEpisodeById(int episodeId) {
    if (episodeId <= 0) return null;
    for (final seasonEps in episodesBySeason.values) {
      for (final ep in seasonEps) {
        if (ep.id == episodeId || (ep.streamId != null && ep.streamId == episodeId)) {
          return ep;
        }
      }
    }
    return null;
  }

  /// Localiza um episódio pelo número da temporada e número do episódio.
  XtreamSeriesEpisode? findEpisodeBySeasonAndNum(int seasonNumber, int episodeNum) {
    final seasonEps = episodesBySeason[seasonNumber];
    if (seasonEps != null) {
      for (final ep in seasonEps) {
        if (ep.episodeNum == episodeNum) return ep;
      }
    }
    return null;
  }

  /// Retorna o próximo episódio sequencial na série.
  /// 1. Tenta o próximo episódio na mesma temporada.
  /// 2. Se for o último episódio da temporada atual, tenta o primeiro episódio da próxima temporada.
  /// 3. Retorna null se não houver próximo episódio.
  XtreamSeriesEpisode? getNextEpisode(XtreamSeriesEpisode current) {
    final currentSeasonEps = episodesBySeason[current.seasonNumber];
    if (currentSeasonEps != null && currentSeasonEps.isNotEmpty) {
      final currentIndex = currentSeasonEps.indexWhere((ep) =>
          ep.id == current.id ||
          (ep.streamId != null && ep.streamId == current.id) ||
          (current.streamId != null && ep.id == current.streamId) ||
          ep.episodeNum == current.episodeNum);
      if (currentIndex != -1 && currentIndex + 1 < currentSeasonEps.length) {
        return currentSeasonEps[currentIndex + 1];
      }
    }

    // Procura na próxima temporada existente que contenha episódios
    final sortedSeasonNumbers = <int>{
      ...seasons.map((s) => s.seasonNumber),
      ...episodesBySeason.keys,
    }.toList()
      ..sort();
    final idx = sortedSeasonNumbers.indexOf(current.seasonNumber);
    final nextSeasonIndex = idx >= 0
        ? idx + 1
        : sortedSeasonNumbers.indexWhere((s) => s > current.seasonNumber);

    if (nextSeasonIndex >= 0) {
      for (var i = nextSeasonIndex; i < sortedSeasonNumbers.length; i++) {
        final nextSeasonNum = sortedSeasonNumbers[i];
        final nextSeasonEps = episodesBySeason[nextSeasonNum];
        if (nextSeasonEps != null && nextSeasonEps.isNotEmpty) {
          return nextSeasonEps.first;
        }
      }
    }

    return null;
  }

  /// Indica se a série retornada pela API contém apenas registros órfãos ou stubs,
  /// onde nenhum episódio possui extensão de container válida nem metadados reais (duração, capa, plot).
  bool get isOrphanedOrStub {
    if (episodesBySeason.isEmpty) return true;
    for (final episodes in episodesBySeason.values) {
      for (final ep in episodes) {
        if ((ep.containerExtension != null && ep.containerExtension!.trim().isNotEmpty) ||
            (ep.duration != null && ep.duration!.isNotEmpty) ||
            (ep.durationSecs != null && ep.durationSecs! > 0) ||
            (ep.plot != null && ep.plot!.isNotEmpty) ||
            (ep.cover != null && ep.cover!.isNotEmpty)) {
          return false;
        }
      }
    }
    return true;
  }
}
