/// Modelo leve para canais exibidos no Mini-Guia OSD lateral durante reprodução ao vivo.
class LiveMiniChannelItem {
  final String id;
  final String name;
  final int number;
  final String? logoUrl;
  final String? groupTitle;
  final String? currentProgram;
  final bool isCurrent;

  const LiveMiniChannelItem({
    required this.id,
    required this.name,
    required this.number,
    this.logoUrl,
    this.groupTitle,
    this.currentProgram,
    this.isCurrent = false,
  });

  LiveMiniChannelItem copyWith({
    String? id,
    String? name,
    int? number,
    String? logoUrl,
    String? groupTitle,
    String? currentProgram,
    bool? isCurrent,
  }) {
    return LiveMiniChannelItem(
      id: id ?? this.id,
      name: name ?? this.name,
      number: number ?? this.number,
      logoUrl: logoUrl ?? this.logoUrl,
      groupTitle: groupTitle ?? this.groupTitle,
      currentProgram: currentProgram ?? this.currentProgram,
      isCurrent: isCurrent ?? this.isCurrent,
    );
  }
}
