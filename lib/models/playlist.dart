import 'channel.dart';

/// Modelo representando uma lista M3U cadastrada no aplicativo.
class M3uPlaylist {
  final String id;
  final String name;
  final String url;
  final int channelCount;
  final DateTime lastUpdated;
  final List<M3uChannel>? channels;

  const M3uPlaylist({
    required this.id,
    required this.name,
    required this.url,
    required this.channelCount,
    required this.lastUpdated,
    this.channels,
  });

  M3uPlaylist copyWith({
    String? id,
    String? name,
    String? url,
    int? channelCount,
    DateTime? lastUpdated,
    List<M3uChannel>? channels,
  }) {
    return M3uPlaylist(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      channelCount: channelCount ?? this.channelCount,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      channels: channels ?? this.channels,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'url': url,
      'channelCount': channelCount,
      'lastUpdated': lastUpdated.toIso8601String(),
    };
  }

  factory M3uPlaylist.fromJson(Map<String, dynamic> json, {List<M3uChannel>? channels}) {
    return M3uPlaylist(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Lista sem nome',
      url: json['url'] as String? ?? '',
      channelCount: json['channelCount'] as int? ?? 0,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.tryParse(json['lastUpdated'] as String) ?? DateTime.now()
          : DateTime.now(),
      channels: channels,
    );
  }
}
