// Modelo para metadados detalhados de um filme obtidos via get_vod_info.

class XtreamVodInfo {
  final int streamId;
  final String name;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final String? duration;
  final int? durationSecs;
  final String? cover;
  final String? backdrop;
  final String? rating;
  final String? containerExtension;

  const XtreamVodInfo({
    required this.streamId,
    required this.name,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.duration,
    this.durationSecs,
    this.cover,
    this.backdrop,
    this.rating,
    this.containerExtension,
  });

  factory XtreamVodInfo.fromJson(Map<String, dynamic> json, {int? fallbackStreamId, String? fallbackName}) {
    final info = (json['info'] is Map<String, dynamic>)
        ? json['info'] as Map<String, dynamic>
        : (json['info'] is Map)
            ? Map<String, dynamic>.from(json['info'] as Map)
            : <String, dynamic>{};

    final movieData = (json['movie_data'] is Map<String, dynamic>)
        ? json['movie_data'] as Map<String, dynamic>
        : (json['movie_data'] is Map)
            ? Map<String, dynamic>.from(json['movie_data'] as Map)
            : <String, dynamic>{};

    final rawStreamId = movieData['stream_id'] ?? info['stream_id'] ?? fallbackStreamId;
    final streamId = int.tryParse(rawStreamId?.toString() ?? '') ?? fallbackStreamId ?? 0;

    final name = (info['name']?.toString() ?? movieData['name']?.toString() ?? fallbackName ?? 'Filme sem título').trim();

    // Backdrop pode vir como List ou String
    String? backdropUrl;
    final rawBackdrop = info['backdrop_path'];
    if (rawBackdrop is List && rawBackdrop.isNotEmpty) {
      backdropUrl = rawBackdrop.first?.toString();
    } else if (rawBackdrop is String && rawBackdrop.isNotEmpty) {
      backdropUrl = rawBackdrop;
    }

    final rawPlot = info['plot']?.toString().trim();
    final plot = (rawPlot != null && rawPlot.isNotEmpty) ? rawPlot : null;

    final rawCast = info['cast']?.toString().trim();
    final cast = (rawCast != null && rawCast.isNotEmpty) ? rawCast : null;

    final rawDirector = info['director']?.toString().trim();
    final director = (rawDirector != null && rawDirector.isNotEmpty) ? rawDirector : null;

    final rawGenre = info['genre']?.toString().trim();
    final genre = (rawGenre != null && rawGenre.isNotEmpty) ? rawGenre : null;

    final rawReleaseDate = info['releasedate']?.toString() ?? info['releaseDate']?.toString();
    final releaseDate = (rawReleaseDate != null && rawReleaseDate.trim().isNotEmpty) ? rawReleaseDate.trim() : null;

    final rawDuration = info['duration']?.toString().trim();
    final duration = (rawDuration != null && rawDuration.isNotEmpty) ? rawDuration : null;

    final rawDurationSecs = info['duration_secs'] ?? info['duration_seconds'];
    final durationSecs = int.tryParse(rawDurationSecs?.toString() ?? '');

    final rawCover = info['movie_image']?.toString() ?? info['cover_big']?.toString() ?? movieData['stream_icon']?.toString();
    final cover = (rawCover != null && rawCover.trim().isNotEmpty) ? rawCover.trim() : null;

    final rawRating = info['rating']?.toString().trim();
    final rating = (rawRating != null && rawRating.isNotEmpty) ? rawRating : null;

    final ext = movieData['container_extension']?.toString() ??
        info['container_extension']?.toString() ??
        movieData['extension']?.toString() ??
        info['extension']?.toString();
    final containerExtension = (ext != null && ext.trim().isNotEmpty)
        ? ext.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        : null;

    return XtreamVodInfo(
      streamId: streamId,
      name: name,
      plot: plot,
      cast: cast,
      director: director,
      genre: genre,
      releaseDate: releaseDate,
      duration: duration,
      durationSecs: durationSecs,
      cover: cover,
      backdrop: backdropUrl,
      rating: rating,
      containerExtension: containerExtension,
    );
  }
}
