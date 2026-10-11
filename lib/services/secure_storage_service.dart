import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Serviço responsável pelo armazenamento seguro e criptografado de credenciais
/// utilizando Android Keystore / EncryptedSharedPreferences.
class SecureStorageService {
  static const _keyServerUrl = 'xtream_server_url';
  static const _keyUsername = 'xtream_username';
  static const _keyPassword = 'xtream_password';
  static const _keyInitialized = 'xtream_credentials_initialized';

  final FlutterSecureStorage _storage;

  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: true),
            );

  /// Retorna se a inicialização padrão de credenciais já foi executada.
  Future<bool> isInitialized() async {
    final val = await _storage.read(key: _keyInitialized);
    return val == 'true';
  }

  /// Marca que a inicialização de credenciais foi concluída.
  Future<void> markInitialized() async {
    await _storage.write(key: _keyInitialized, value: 'true');
  }

  /// Salva as credenciais no armazenamento seguro criptografado.
  Future<void> saveCredentials({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    await _storage.write(key: _keyServerUrl, value: serverUrl.trim());
    await _storage.write(key: _keyUsername, value: username.trim());
    await _storage.write(key: _keyPassword, value: password.trim());
    await markInitialized();
  }

  /// Recupera a URL do servidor salva.
  Future<String?> getServerUrl() async {
    return _storage.read(key: _keyServerUrl);
  }

  /// Recupera o nome de usuário salvo.
  Future<String?> getUsername() async {
    return _storage.read(key: _keyUsername);
  }

  /// Recupera a senha criptografada.
  Future<String?> getPassword() async {
    return _storage.read(key: _keyPassword);
  }

  /// Verifica se há credenciais salvas.
  Future<bool> hasCredentials() async {
    final user = await getUsername();
    final pass = await getPassword();
    return user != null && user.isNotEmpty && pass != null && pass.isNotEmpty;
  }

  /// Remove todas as credenciais salvas.
  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyServerUrl);
    await _storage.delete(key: _keyUsername);
    await _storage.delete(key: _keyPassword);
  }
}
