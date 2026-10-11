import '../models/channel.dart';
import '../models/xtream_catalog.dart';

/// Tipos de conteúdo suportados pelo sistema de favoritos.
enum FavoriteType {
  live,
  movie,
  series,
  m3uChannel,
}

/// Representação unificada e auto-suficiente de um item favoritado.
/// Salva metadados suficientes para renderizar a interface de favoritos
/// mesmo sem conexão ativa ou antes do carregamento completo do catálogo.
class FavoriteItem {
  final String id;
  final String scopeKey;
  final FavoriteType type;
  final String name;
  final String? iconUrl;
  final String? rating;
  final String? categoryId;
  final String? containerExtension;
  final String? streamUrl;
  final DateTime addedAt;

  const FavoriteItem({
    required this.id,
    required this.scopeKey,
    required this.type,
    required this.name,
    this.iconUrl,
    this.rating,
    this.categoryId,
    this.containerExtension,
    this.streamUrl,
    required this.addedAt,
  });

  /// Chave composta única para busca rápida em memória
  String get compositeKey => '$scopeKey#${type.name}#$id';

  /// Constrói um ID estável e seguro para canais M3U, sem expor credenciais ou URLs completas
  static String buildM3uChannelId({
    required String name,
    required String streamUrl,
    String? tvgId,
  }) {
    if (tvgId != null && tvgId.trim().isNotEmpty) {
      final cleanTvg = tvgId.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      return 'tvg_$cleanTvg';
    }

    final uri = Uri.tryParse(streamUrl.trim());
    final path = uri != null ? uri.path : streamUrl;
    final rawKey = '${name.trim().toLowerCase()}|$path';

    // Hash determinístico djb2 de 32-bit
    int hash = 5381;
    for (int i = 0; i < rawKey.length; i++) {
      hash = ((hash << 5) + hash) + rawKey.codeUnitAt(i);
    }
    final cleanName = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final truncated = cleanName.length > 24 ? cleanName.substring(0, 24) : cleanName;
    final hexHash = (hash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return 'ch_${truncated}_$hexHash';
  }

  /// Cria um FavoriteItem a partir de um canal de TV ao vivo Xtream
  factory FavoriteItem.fromLiveStream({
    required String accountKey,
    required XtreamLiveStream stream,
  }) {
    return FavoriteItem(
      id: stream.streamId.toString(),
      scopeKey: accountKey,
      type: FavoriteType.live,
      name: stream.name,
      iconUrl: stream.streamIcon,
      categoryId: stream.categoryId,
      addedAt: DateTime.now(),
    );
  }

  /// Cria um FavoriteItem a partir de um filme (VOD) Xtream
  factory FavoriteItem.fromVodStream({
    required String accountKey,
    required XtreamVodStream movie,
  }) {
    return FavoriteItem(
      id: movie.streamId.toString(),
      scopeKey: accountKey,
      type: FavoriteType.movie,
      name: movie.name,
      iconUrl: movie.streamIcon,
      rating: movie.rating,
      categoryId: movie.categoryId,
      containerExtension: movie.containerExtension,
      addedAt: DateTime.now(),
    );
  }

  /// Cria um FavoriteItem a partir de uma série Xtream
  factory FavoriteItem.fromSeriesItem({
    required String accountKey,
    required XtreamSeriesItem series,
  }) {
    return FavoriteItem(
      id: series.seriesId.toString(),
      scopeKey: accountKey,
      type: FavoriteType.series,
      name: series.name,
      iconUrl: series.cover,
      rating: series.rating,
      categoryId: series.categoryId,
      addedAt: DateTime.now(),
    );
  }

  /// Cria um FavoriteItem a partir de um canal M3U
  factory FavoriteItem.fromM3uChannel({
    required String playlistId,
    required M3uChannel channel,
  }) {
    final channelId = buildM3uChannelId(
      name: channel.name,
      streamUrl: channel.streamUrl,
      tvgId: channel.tvgId,
    );
    return FavoriteItem(
      id: channelId,
      scopeKey: playlistId,
      type: FavoriteType.m3uChannel,
      name: channel.name,
      iconUrl: channel.logoUrl,
      categoryId: channel.groupTitle,
      streamUrl: channel.streamUrl,
      addedAt: DateTime.now(),
    );
  }

  /// Converte para o modelo original XtreamLiveStream para navegação e reprodução
  XtreamLiveStream toLiveStream() {
    return XtreamLiveStream(
      streamId: int.tryParse(id) ?? 0,
      name: name,
      streamIcon: iconUrl,
      categoryId: categoryId ?? '0',
      streamType: 'live',
    );
  }

  /// Converte para o modelo original XtreamVodStream para detalhes e reprodução
  XtreamVodStream toVodStream() {
    return XtreamVodStream(
      streamId: int.tryParse(id) ?? 0,
      name: name,
      streamIcon: iconUrl,
      rating: rating,
      categoryId: categoryId ?? '0',
      containerExtension: containerExtension,
    );
  }

  /// Converte para o modelo original XtreamSeriesItem para detalhes e episódios
  XtreamSeriesItem toSeriesItem() {
    return XtreamSeriesItem(
      seriesId: int.tryParse(id) ?? 0,
      name: name,
      cover: iconUrl,
      rating: rating,
      categoryId: categoryId ?? '0',
    );
  }

  /// Converte para o modelo original M3uChannel para reprodução de listas M3U
  M3uChannel toM3uChannel() {
    return M3uChannel(
      name: name,
      streamUrl: streamUrl ?? '',
      groupTitle: categoryId ?? 'Geral',
      logoUrl: iconUrl,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'scopeKey': scopeKey,
      'type': type.name,
      'name': name,
      'iconUrl': iconUrl,
      'rating': rating,
      'categoryId': categoryId,
      'containerExtension': containerExtension,
      'streamUrl': streamUrl,
      'addedAt': addedAt.toIso8601String(),
    };
  }

  factory FavoriteItem.fromJson(Map<String, dynamic> json) {
    return FavoriteItem(
      id: json['id'] as String? ?? '',
      scopeKey: json['scopeKey'] as String? ?? '',
      type: FavoriteType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => FavoriteType.live,
      ),
      name: json['name'] as String? ?? 'Sem título',
      iconUrl: json['iconUrl'] as String?,
      rating: json['rating'] as String?,
      categoryId: json['categoryId'] as String?,
      containerExtension: json['containerExtension'] as String?,
      streamUrl: json['streamUrl'] as String?,
      addedAt: json['addedAt'] != null
          ? DateTime.tryParse(json['addedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
