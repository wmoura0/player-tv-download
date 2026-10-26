// Modelos para informações detalhadas de séries, temporadas e episódios
// obtidos a partir do endpoint get_series_info da API Xtream Codes.

class XtreamSeriesEpisode {
  final int id;
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

    final rawId = json['id'] ?? json['stream_id'] ?? info['id'] ?? info['stream_id'];
    final id = int.tryParse(rawId?.toString() ?? '') ?? 0;

    final rawEpNum = json['episode_num'] ?? json['episode_number'] ?? info['episode_num'] ?? fallbackEpisodeNum;
    final episodeNum = int.tryParse(rawEpNum?.toString() ?? '') ?? fallbackEpisodeNum ?? 1;

    final rawSeason = json['season'] ?? json['season_number'] ?? info['season'] ?? fallbackSeasonNumber;
    final seasonNumber = int.tryParse(rawSeason?.toString() ?? '') ?? fallbackSeasonNumber;

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

    final rawCover = info['movie_image']?.toString() ??
        json['cover']?.toString() ??
        info['cover_big']?.toString() ??
        json['cover_big']?.toString();
    final cover = (rawCover != null && rawCover.trim().isNotEmpty) ? rawCover.trim() : null;

    final rawRating = info['rating']?.toString() ?? json['rating']?.toString();
    final rating = (rawRating != null && rawRating.trim().isNotEmpty) ? rawRating.trim() : null;

    final rawDirect = json['direct_source']?.toString();
    final directSource = (rawDirect != null && rawDirect.trim().isNotEmpty) ? rawDirect.trim() : null;

    return XtreamSeriesEpisode(
      id: id,
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
    final rawNumber = json['season_number'] ?? json['season'] ?? json['id'] ?? fallbackSeasonNumber;
    final seasonNumber = int.tryParse(rawNumber?.toString() ?? '') ?? fallbackSeasonNumber ?? 1;

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

  const XtreamSeriesInfo({
    required this.name,
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
  });

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

    final name = (info['name']?.toString() ?? fallbackName ?? 'Série sem título').trim();

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

    // 1. Processar Episódios organizados por temporada
    final episodesMap = <int, List<XtreamSeriesEpisode>>{};
    final rawEpisodes = json['episodes'];

    if (rawEpisodes is Map) {
      // Formato padrão: {"1": [ep1, ep2], "2": [ep3, ep4]}
      rawEpisodes.forEach((key, val) {
        final seasonNum = int.tryParse(key.toString()) ?? 1;
        if (val is List) {
          final list = <XtreamSeriesEpisode>[];
          for (var i = 0; i < val.length; i++) {
            final epJson = val[i];
            if (epJson is Map) {
              list.add(
                XtreamSeriesEpisode.fromJson(
                  Map<String, dynamic>.from(epJson),
                  fallbackSeasonNumber: seasonNum,
                  fallbackEpisodeNum: i + 1,
                ),
              );
            }
          }
          if (list.isNotEmpty) {
            episodesMap[seasonNum] = list;
          }
        }
      });
    } else if (rawEpisodes is List) {
      // Formato alternativo: lista plana de episódios
      for (var i = 0; i < rawEpisodes.length; i++) {
        final epJson = rawEpisodes[i];
        if (epJson is Map) {
          final epMap = Map<String, dynamic>.from(epJson);
          final seasonNum = int.tryParse(epMap['season']?.toString() ?? '') ?? 1;
          final ep = XtreamSeriesEpisode.fromJson(
            epMap,
            fallbackSeasonNumber: seasonNum,
            fallbackEpisodeNum: i + 1,
          );
          episodesMap.putIfAbsent(ep.seasonNumber, () => []).add(ep);
        }
      }
    }

    // Ordenar episódios dentro de cada temporada pelo número do episódio
    episodesMap.forEach((seasonNum, list) {
      list.sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
    });

    // 2. Processar Temporadas
    final seasonsList = <XtreamSeriesSeason>[];
    final rawSeasons = json['seasons'];

    if (rawSeasons is List) {
      for (var sJson in rawSeasons) {
        if (sJson is Map) {
          seasonsList.add(XtreamSeriesSeason.fromJson(Map<String, dynamic>.from(sJson)));
        }
      }
    } else if (rawSeasons is Map) {
      rawSeasons.forEach((key, val) {
        if (val is Map) {
          final fallbackNum = int.tryParse(key.toString());
          seasonsList.add(XtreamSeriesSeason.fromJson(Map<String, dynamic>.from(val), fallbackSeasonNumber: fallbackNum));
        }
      });
    }

    // Se o servidor não enviou array seasons ou omitiu temporadas existentes nos episódios,
    // sintetiza as temporadas a partir das chaves do mapa de episódios
    final existingSeasonNumbers = seasonsList.map((s) => s.seasonNumber).toSet();
    for (final seasonNum in episodesMap.keys) {
      if (!existingSeasonNumbers.contains(seasonNum)) {
        seasonsList.add(
          XtreamSeriesSeason(
            seasonNumber: seasonNum,
            name: 'Temporada $seasonNum',
            episodeCount: episodesMap[seasonNum]?.length,
          ),
        );
      }
    }

    // Ordenar as temporadas crescentemente pelo número da temporada
    seasonsList.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));

    return XtreamSeriesInfo(
      name: name,
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
    );
  }

  /// Localiza um episódio pelo seu ID em qualquer temporada.
  XtreamSeriesEpisode? findEpisodeById(int episodeId) {
    for (final seasonEps in episodesBySeason.values) {
      for (final ep in seasonEps) {
        if (ep.id == episodeId) return ep;
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
      final currentIndex = currentSeasonEps.indexWhere((ep) => ep.id == current.id);
      if (currentIndex != -1 && currentIndex + 1 < currentSeasonEps.length) {
        return currentSeasonEps[currentIndex + 1];
      }
    }

    // Procura na próxima temporada existente que contenha episódios
    final sortedSeasonNumbers = seasons.map((s) => s.seasonNumber).toList()..sort();
    final nextSeasonIndex = sortedSeasonNumbers.indexOf(current.seasonNumber) + 1;

    for (var i = nextSeasonIndex; i < sortedSeasonNumbers.length; i++) {
      final nextSeasonNum = sortedSeasonNumbers[i];
      final nextSeasonEps = episodesBySeason[nextSeasonNum];
      if (nextSeasonEps != null && nextSeasonEps.isNotEmpty) {
        return nextSeasonEps.first;
      }
    }

    return null;
  }
}
