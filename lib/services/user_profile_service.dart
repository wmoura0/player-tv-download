import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_profile.dart';

/// Serviço responsável pelo gerenciamento de múltiplos perfis de usuário locais,
/// permitindo que membros da família tenham favoritos, histórico e progresso isolados.
class UserProfileService extends ChangeNotifier {
  static final UserProfileService instance = UserProfileService._internal();

  UserProfileService._internal();

  @visibleForTesting
  UserProfileService.forTesting({SharedPreferences? prefs}) {
    _prefs = prefs;
  }

  static const String _keyProfiles = 'user_profiles_list_v1';
  static const String _keyCurrentProfileId = 'user_current_profile_id_v1';
  static const String defaultProfileId = 'default_profile';

  SharedPreferences? _prefs;

  final List<UserProfile> _profiles = [];
  String _currentProfileId = defaultProfileId;

  List<UserProfile> get profiles => List.unmodifiable(_profiles);

  UserProfile get currentProfile {
    if (_profiles.isEmpty) {
      return _createDefaultProfile();
    }
    return _profiles.firstWhere(
      (p) => p.id == _currentProfileId,
      orElse: () => _profiles.first,
    );
  }

  UserProfile _createDefaultProfile() {
    return UserProfile(
      id: defaultProfileId,
      name: 'Principal',
      isKids: false,
      avatarColor: 0xFF00E5FF,
      avatarIconName: 'person',
      createdAt: DateTime.now(),
    );
  }

  /// Inicializa o serviço e garante a existência do perfil padrão retrocompatível
  Future<void> init([SharedPreferences? prefs]) async {
    _prefs = prefs ?? await SharedPreferences.getInstance();

    _profiles.clear();
    final jsonList = _prefs?.getStringList(_keyProfiles) ?? [];

    for (final raw in jsonList) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _profiles.add(UserProfile.fromJson(map));
      } catch (_) {}
    }

    if (_profiles.isEmpty) {
      final defaultProfile = _createDefaultProfile();
      _profiles.add(defaultProfile);
      await _saveToDisk();
    }

    _currentProfileId = _prefs?.getString(_keyCurrentProfileId) ?? defaultProfileId;
    if (!_profiles.any((p) => p.id == _currentProfileId)) {
      _currentProfileId = _profiles.first.id;
    }

    notifyListeners();
  }

  Future<void> _saveToDisk() async {
    final jsonList = _profiles.map((p) => jsonEncode(p.toJson())).toList();
    await _prefs?.setStringList(_keyProfiles, jsonList);
    await _prefs?.setString(_keyCurrentProfileId, _currentProfileId);
  }

  /// Gera a chave de armazenamento isolada por perfil.
  /// Se o perfil atual for o "Principal" (padrão), retorna a chave base original sem sufixo,
  /// garantindo 100% de preservação dos dados pré-existentes do usuário.
  String getScopedKey(String baseKey) {
    if (_currentProfileId == defaultProfileId) {
      return baseKey;
    }
    return '${baseKey}_p_$_currentProfileId';
  }

  /// Alterna o perfil ativo
  Future<void> switchProfile(String profileId) async {
    if (!_profiles.any((p) => p.id == profileId)) return;

    _currentProfileId = profileId;
    await _prefs?.setString(_keyCurrentProfileId, profileId);
    notifyListeners();
  }

  /// Cria um novo perfil de usuário
  Future<UserProfile> createProfile({
    required String name,
    bool isKids = false,
    int? avatarColor,
    String? avatarIconName,
  }) async {
    final newId = 'profile_${DateTime.now().millisecondsSinceEpoch}';
    final profile = UserProfile(
      id: newId,
      name: name.trim().isNotEmpty ? name.trim() : 'Novo Perfil',
      isKids: isKids,
      avatarColor: avatarColor ?? (isKids ? 0xFFFFB74D : 0xFF00E5FF),
      avatarIconName: avatarIconName ?? (isKids ? 'child_care' : 'person'),
      createdAt: DateTime.now(),
    );

    _profiles.add(profile);
    await _saveToDisk();
    notifyListeners();
    return profile;
  }

  /// Atualiza os dados de um perfil
  Future<void> updateProfile(UserProfile updated) async {
    final index = _profiles.indexWhere((p) => p.id == updated.id);
    if (index != -1) {
      _profiles[index] = updated;
      await _saveToDisk();
      notifyListeners();
    }
  }

  /// Exclui um perfil (o perfil padrão nunca pode ser excluído)
  Future<bool> deleteProfile(String profileId) async {
    if (profileId == defaultProfileId || _profiles.length <= 1) {
      return false;
    }

    final wasCurrent = _currentProfileId == profileId;
    _profiles.removeWhere((p) => p.id == profileId);

    if (wasCurrent) {
      _currentProfileId = defaultProfileId;
    }

    await _saveToDisk();
    notifyListeners();
    return true;
  }
}
