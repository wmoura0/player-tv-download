/// Modelo representando um canal extraído de uma lista M3U.
class M3uChannel {
  final String name;
  final String streamUrl;
  final String groupTitle;
  final String? logoUrl;
  final String? tvgId;
  final String? tvgName;

  const M3uChannel({
    required this.name,
    required this.streamUrl,
    this.groupTitle = 'Geral',
    this.logoUrl,
    this.tvgId,
    this.tvgName,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'streamUrl': streamUrl,
      'groupTitle': groupTitle,
      'logoUrl': logoUrl,
      'tvgId': tvgId,
      'tvgName': tvgName,
    };
  }

  factory M3uChannel.fromJson(Map<String, dynamic> json) {
    return M3uChannel(
      name: json['name'] as String? ?? 'Canal sem nome',
      streamUrl: json['streamUrl'] as String? ?? '',
      groupTitle: json['groupTitle'] as String? ?? 'Geral',
      logoUrl: json['logoUrl'] as String?,
      tvgId: json['tvgId'] as String?,
      tvgName: json['tvgName'] as String?,
    );
  }
}
