import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/managed_account.dart';
import 'secure_storage_service.dart';

/// Serviço responsável por gerenciar múltiplas contas (Xtream Codes e Listas M3U),
/// garantindo migração idempotente e segura da conta existente sem perda de dados.
class AccountManagerService extends ChangeNotifier {
  static final AccountManagerService instance = AccountManagerService._internal();

  AccountManagerService._internal();

  static const String _keyAccounts = 'managed_accounts_list_v1';
  static const String _keyCurrentAccountId = 'managed_current_account_id_v1';

  SharedPreferences? _prefs;
  SecureStorageService? _secureStorage;

  @visibleForTesting
  AccountManagerService.forTesting({
    SharedPreferences? prefs,
    SecureStorageService? secureStorage,
  }) {
    _prefs = prefs;
    _secureStorage = secureStorage;
  }

  final List<ManagedAccount> _accounts = [];
  String? _currentAccountId;

  List<ManagedAccount> get accounts => List.unmodifiable(_accounts);

  ManagedAccount? get currentAccount {
    if (_accounts.isEmpty) return null;
    return _accounts.firstWhere(
      (a) => a.id == _currentAccountId,
      orElse: () => _accounts.first,
    );
  }

  /// Inicializa o gerenciador e realiza migração idempotente da conta ativa atual
  Future<void> init([SharedPreferences? prefs, SecureStorageService? secureStorage]) async {
    _prefs = prefs ?? await SharedPreferences.getInstance();
    _secureStorage = secureStorage ?? SecureStorageService();

    _accounts.clear();
    final jsonList = _prefs?.getStringList(_keyAccounts) ?? [];

    for (final raw in jsonList) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _accounts.add(ManagedAccount.fromJson(map));
      } catch (_) {}
    }

    _currentAccountId = _prefs?.getString(_keyCurrentAccountId);

    // Migração idempotente se não houver contas gerenciadas gravadas ainda
    if (_accounts.isEmpty) {
      await _migrateExistingPrimaryAccount();
    }

    if (_accounts.isNotEmpty) {
      if (_currentAccountId == null || !_accounts.any((a) => a.id == _currentAccountId)) {
        _currentAccountId = _accounts.first.id;
        await _prefs?.setString(_keyCurrentAccountId, _currentAccountId!);
      }
    }

    notifyListeners();
  }

  Future<void> _migrateExistingPrimaryAccount() async {
    final storage = _secureStorage ?? SecureStorageService();
    final hasCreds = await storage.hasCredentials();

    if (hasCreds) {
      final server = await storage.getServerUrl() ?? '';
      final user = await storage.getUsername() ?? '';
      final pass = await storage.getPassword() ?? '';

      final primaryAccount = ManagedAccount(
        id: 'primary_xtream',
        name: 'JessFlix Principal',
        type: AccountType.xtream,
        serverUrl: server,
        username: user,
        password: pass,
        isCurrent: true,
        createdAt: DateTime.now(),
      );

      _accounts.add(primaryAccount);
      _currentAccountId = primaryAccount.id;
      await _saveToDisk();
      debugPrint('[ACCOUNT MANAGER] [MIGRAÇÃO] Conta primária migrada com sucesso: id=${primaryAccount.id}, user=$user');
    }
  }

  Future<void> _saveToDisk() async {
    final jsonList = _accounts.map((a) => jsonEncode(a.toJson())).toList();
    await _prefs?.setStringList(_keyAccounts, jsonList);
    if (_currentAccountId != null) {
      await _prefs?.setString(_keyCurrentAccountId, _currentAccountId!);
    }
  }

  /// Alterna a conta ativa e atualiza as credenciais seguras caso seja Xtream
  Future<void> switchAccount(String accountId) async {
    final target = _accounts.firstWhere((a) => a.id == accountId, orElse: () => throw Exception('Conta não encontrada'));

    _currentAccountId = target.id;
    for (var i = 0; i < _accounts.length; i++) {
      final a = _accounts[i];
      _accounts[i] = a.copyWith(isCurrent: a.id == target.id);
    }

    await _saveToDisk();

    // Se for Xtream, sincroniza com o SecureStorageService para compatibilidade integral
    if (target.type == AccountType.xtream && target.username != null && target.password != null) {
      final storage = _secureStorage ?? SecureStorageService();
      await storage.saveCredentials(
        serverUrl: target.serverUrl,
        username: target.username!,
        password: target.password!,
      );
    }

    notifyListeners();
  }

  /// Adiciona uma nova conta
  Future<void> addAccount(ManagedAccount newAccount, {bool makeCurrent = false}) async {
    // Evita duplicidade por ID
    _accounts.removeWhere((a) => a.id == newAccount.id);
    _accounts.add(newAccount);

    if (makeCurrent || _accounts.length == 1) {
      await switchAccount(newAccount.id);
    } else {
      await _saveToDisk();
      notifyListeners();
    }
  }

  /// Remove uma conta (não remove se for a única)
  Future<bool> removeAccount(String accountId) async {
    if (_accounts.length <= 1) {
      return false; // Não permite excluir a única conta ativa
    }

    final wasCurrent = _currentAccountId == accountId;
    _accounts.removeWhere((a) => a.id == accountId);

    if (wasCurrent) {
      await switchAccount(_accounts.first.id);
    } else {
      await _saveToDisk();
      notifyListeners();
    }
    return true;
  }
}
