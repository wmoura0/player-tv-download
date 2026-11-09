/// Modelo de perfil de usuário local com dados isolados (Favoritos, Histórico, Progresso).
class UserProfile {
  final String id;
  final String name;
  final bool isKids;
  final int avatarColor;
  final String avatarIconName;
  final DateTime createdAt;

  const UserProfile({
    required this.id,
    required this.name,
    this.isKids = false,
    this.avatarColor = 0xFF00E5FF,
    this.avatarIconName = 'person',
    required this.createdAt,
  });

  UserProfile copyWith({
    String? id,
    String? name,
    bool? isKids,
    int? avatarColor,
    String? avatarIconName,
    DateTime? createdAt,
  }) {
    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      isKids: isKids ?? this.isKids,
      avatarColor: avatarColor ?? this.avatarColor,
      avatarIconName: avatarIconName ?? this.avatarIconName,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'isKids': isKids,
      'avatarColor': avatarColor,
      'avatarIconName': avatarIconName,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Perfil',
      isKids: json['isKids'] as bool? ?? false,
      avatarColor: json['avatarColor'] as int? ?? 0xFF00E5FF,
      avatarIconName: json['avatarIconName'] as String? ?? 'person',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
