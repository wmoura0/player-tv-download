enum AccountType {
  xtream,
  m3u,
}

/// Modelo de conta para o sistema de gerenciamento de múltiplas contas do JessFlix.
class ManagedAccount {
  final String id;
  final String name;
  final AccountType type;
  final String serverUrl;
  final String? username;
  final String? password;
  final bool isCurrent;
  final DateTime createdAt;

  const ManagedAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.serverUrl,
    this.username,
    this.password,
    this.isCurrent = false,
    required this.createdAt,
  });

  ManagedAccount copyWith({
    String? id,
    String? name,
    AccountType? type,
    String? serverUrl,
    String? username,
    String? password,
    bool? isCurrent,
    DateTime? createdAt,
  }) {
    return ManagedAccount(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      isCurrent: isCurrent ?? this.isCurrent,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'serverUrl': serverUrl,
      'username': username,
      'password': password,
      'isCurrent': isCurrent,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory ManagedAccount.fromJson(Map<String, dynamic> json) {
    return ManagedAccount(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Conta',
      type: (json['type'] as String?) == 'm3u' ? AccountType.m3u : AccountType.xtream,
      serverUrl: json['serverUrl'] as String? ?? '',
      username: json['username'] as String?,
      password: json['password'] as String?,
      isCurrent: json['isCurrent'] as bool? ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
