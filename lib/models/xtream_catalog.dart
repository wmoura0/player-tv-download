import 'dart:convert';

// Modelos para o catálogo Xtream Codes (Categorias, TV ao vivo, Filmes e Séries).

class XtreamCategory {
  final String id;
  final String name;
  final int? parentId;

  const XtreamCategory({
    required this.id,
    required this.name,
    this.parentId,
  });

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: json['category_id']?.toString() ?? '0',
      name: json['category_name']?.toString() ?? 'Sem categoria',
      parentId: int.tryParse(json['parent_id']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'category_id': id,
    'category_name': name,
    if (parentId != null) 'parent_id': parentId,
  };
}

class XtreamLiveStream {
  final int streamId;
  final int? num;
  final String name;
  final String? streamIcon;
  final String? epgChannelId;
  final String categoryId;
  final String? streamType;
  final String? directSource;

  const XtreamLiveStream({
    required this.streamId,
    this.num,
    required this.name,
    this.streamIcon,
    this.epgChannelId,
    required this.categoryId,
    this.streamType,
    this.directSource,
  });

  factory XtreamLiveStream.fromJson(Map<String, dynamic> json) {
    return XtreamLiveStream(
      streamId: int.tryParse(json['stream_id']?.toString() ?? '') ?? 0,
      num: int.tryParse(json['num']?.toString() ?? ''),
      name: json['name']?.toString() ?? 'Canal sem nome',
      streamIcon: json['stream_icon']?.toString(),
      epgChannelId: json['epg_channel_id']?.toString(),
      categoryId: json['category_id']?.toString() ?? '0',
      streamType: json['stream_type']?.toString(),
      directSource: json['direct_source']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'stream_id': streamId,
    if (num != null) 'num': num,
    'name': name,
    if (streamIcon != null) 'stream_icon': streamIcon,
    if (epgChannelId != null) 'epg_channel_id': epgChannelId,
    'category_id': categoryId,
    if (streamType != null) 'stream_type': streamType,
    if (directSource != null) 'direct_source': directSource,
  };
}

class XtreamVodStream {
  final int streamId;
  final int? num;
  final String name;
  final String? streamIcon;
  final String? rating;
  final double? rating5based;
  final String categoryId;
  final String? containerExtension;
  final DateTime? addedDate;

  const XtreamVodStream({
    required this.streamId,
    this.num,
    required this.name,
    this.streamIcon,
    this.rating,
    this.rating5based,
    required this.categoryId,
    this.containerExtension,
    this.addedDate,
  });

  factory XtreamVodStream.fromJson(Map<String, dynamic> json) {
    DateTime? addedDate;
    final rawAdded = json['added']?.toString();
    if (rawAdded != null && rawAdded.isNotEmpty) {
      final secs = int.tryParse(rawAdded);
      if (secs != null && secs > 1000000) {
        addedDate = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
      } else {
        addedDate = DateTime.tryParse(rawAdded);
      }
    }

    return XtreamVodStream(
      streamId: int.tryParse(json['stream_id']?.toString() ?? '') ?? 0,
      num: int.tryParse(json['num']?.toString() ?? ''),
      name: json['name']?.toString() ?? 'Filme sem título',
      streamIcon: json['stream_icon']?.toString(),
      rating: json['rating']?.toString(),
      rating5based: double.tryParse(json['rating_5based']?.toString() ?? ''),
      categoryId: json['category_id']?.toString() ?? '0',
      containerExtension: json['container_extension']?.toString(),
      addedDate: addedDate,
    );
  }

  Map<String, dynamic> toJson() => {
    'stream_id': streamId,
    if (num != null) 'num': num,
    'name': name,
    if (streamIcon != null) 'stream_icon': streamIcon,
    if (rating != null) 'rating': rating,
    if (rating5based != null) 'rating_5based': rating5based,
    'category_id': categoryId,
    if (containerExtension != null) 'container_extension': containerExtension,
    if (addedDate != null) 'added': (addedDate!.millisecondsSinceEpoch ~/ 1000).toString(),
  };
}

class XtreamSeriesItem {
  final int seriesId;
  final int? num;
  final String name;
  final String? cover;
  final String? plot;
  final String? genre;
  final String? rating;
  final String categoryId;
  final DateTime? addedDate;

  const XtreamSeriesItem({
    required this.seriesId,
    this.num,
    required this.name,
    this.cover,
    this.plot,
    this.genre,
    this.rating,
    required this.categoryId,
    this.addedDate,
  });

  factory XtreamSeriesItem.fromJson(Map<String, dynamic> json) {
    DateTime? addedDate;
    final rawDate = json['last_modified']?.toString() ?? json['added']?.toString();
    if (rawDate != null && rawDate.isNotEmpty) {
      final secs = int.tryParse(rawDate);
      if (secs != null && secs > 1000000) {
        addedDate = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
      } else {
        addedDate = DateTime.tryParse(rawDate);
      }
    }

    return XtreamSeriesItem(
      seriesId: int.tryParse(json['series_id']?.toString() ?? '') ?? 0,
      num: int.tryParse(json['num']?.toString() ?? ''),
      name: json['name']?.toString() ?? 'Série sem título',
      cover: json['cover']?.toString(),
      plot: json['plot']?.toString(),
      genre: json['genre']?.toString(),
      rating: json['rating']?.toString(),
      categoryId: json['category_id']?.toString() ?? '0',
      addedDate: addedDate,
    );
  }

  Map<String, dynamic> toJson() => {
    'series_id': seriesId,
    if (num != null) 'num': num,
    'name': name,
    if (cover != null) 'cover': cover,
    if (plot != null) 'plot': plot,
    if (genre != null) 'genre': genre,
    if (rating != null) 'rating': rating,
    'category_id': categoryId,
    if (addedDate != null) 'last_modified': (addedDate!.millisecondsSinceEpoch ~/ 1000).toString(),
  };
}

/// Representa um programa do Guia Eletrônico de Programação (EPG) retornado pelo Xtream Codes.
class XtreamEpgProgram {
  final String title;
  final String? description;
  final String? start;
  final String? end;
  final bool isNowPlaying;

  const XtreamEpgProgram({
    required this.title,
    this.description,
    this.start,
    this.end,
    this.isNowPlaying = false,
  });

  factory XtreamEpgProgram.fromJson(Map<String, dynamic> json) {
    String decodeField(dynamic val) {
      if (val == null) return '';
      final str = val.toString().trim();
      if (str.isEmpty) return '';
      try {
        if (RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(str) && str.length % 4 == 0) {
          final bytes = base64.decode(str);
          final decoded = utf8.decode(bytes, allowMalformed: true);
          if (decoded.trim().isNotEmpty) return decoded.trim();
        }
      } catch (_) {}
      return str;
    }

    final rawTitle = decodeField(json['title']);
    final rawDesc = decodeField(json['description']);
    final isNow = json['now_playing'] == 1 || json['now_playing'] == '1';

    return XtreamEpgProgram(
      title: rawTitle.isNotEmpty ? rawTitle : 'Programa sem título',
      description: rawDesc.isNotEmpty ? rawDesc : null,
      start: json['start']?.toString(),
      end: json['end']?.toString(),
      isNowPlaying: isNow,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    if (description != null) 'description': description,
    if (start != null) 'start': start,
    if (end != null) 'end': end,
    'now_playing': isNowPlaying ? 1 : 0,
  };
}
