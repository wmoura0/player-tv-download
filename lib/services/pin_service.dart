import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço responsável pelo gerenciamento de Controle Parental,
/// Bloqueio por PIN de 4 dígitos (com hash SHA-256 e Salt),
/// bloqueio de categorias adultas (+18) e bloqueio manual de categorias selecionadas.
class PinService extends ChangeNotifier {
  static final PinService instance = PinService._internal();

  PinService._internal();

  @visibleForTesting
  PinService.forTesting({SharedPreferences? prefs}) {
    _prefs = prefs;
  }

  SharedPreferences? _prefs;

  static const String _keyPinHash = 'parental_pin_hash';
  static const String _keyPinSalt = 'parental_pin_salt';
  static const String _keyHideAdult = 'parental_hide_adult';
  static const String _keyLockedCats = 'parental_locked_categories';

  String? _pinHash;
  String? _pinSalt;
  bool _hideAdult = true; // Por padrão, proteção ativa se houver PIN configurado
  Set<String> _lockedCategories = {};

  // Gerenciamento de tentativas e lockout
  int _failedAttempts = 0;
  DateTime? _lockoutUntil;
  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(seconds: 30);

  // Sessões desbloqueadas temporariamente em memória
  final Set<String> _sessionUnlockedCategories = {};
  bool _sessionMasterUnlocked = false;

  /// Expressões regulares para detecção proativa de categorias adultas
  static final RegExp _adultPattern = RegExp(
    r'(\b\+?18\+?\b|\badult[oa]s?\b|\bxxx\b|\ber[oó]tic[oa]s?\b|\bporn\b|\bsexy\b|\bhot\b|\bonlyfans\b|\bredlight\b|\bhentai\b)',
    caseSensitive: false,
  );

  /// Inicializa o serviço e lê as configurações do SharedPreferences
  Future<void> init([SharedPreferences? prefs]) async {
    _prefs = prefs ?? await SharedPreferences.getInstance();
    _pinHash = _prefs?.getString(_keyPinHash);
    _pinSalt = _prefs?.getString(_keyPinSalt);
    _hideAdult = _prefs?.getBool(_keyHideAdult) ?? true;
    final locked = _prefs?.getStringList(_keyLockedCats) ?? [];
    _lockedCategories = locked.toSet();
    notifyListeners();
  }

  /// Indica se um PIN já foi configurado pelo usuário
  bool get isPinSet => _pinHash != null && _pinHash!.isNotEmpty;

  /// Indica se o conteúdo adulto deve ser oculto/bloqueado
  bool get isAdultContentHidden => _hideAdult;

  /// Categorias explicitamente bloqueadas
  Set<String> get lockedCategories => Set.unmodifiable(_lockedCategories);

  /// Número de tentativas falhas consecutivas
  int get failedAttempts => _failedAttempts;

  /// Verifica se o usuário está atualmente em tempo de bloqueio (cooldown)
  bool get isLockedOut {
    if (_lockoutUntil == null) return false;
    if (DateTime.now().isBefore(_lockoutUntil!)) {
      return true;
    }
    // Cooldown expirou
    _lockoutUntil = null;
    _failedAttempts = 0;
    return false;
  }

  /// Retorna quantos segundos restam no cooldown
  int get lockoutSecondsRemaining {
    if (!isLockedOut || _lockoutUntil == null) return 0;
    final diff = _lockoutUntil!.difference(DateTime.now()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  /// Gera um salt criptográfico aleatório
  String _generateSalt() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Calcula o hash SHA-256 do PIN concatenado ao Salt
  String _hashPin(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  /// Configura ou altera o PIN de 4 dígitos
  Future<bool> setPin(String newPin) async {
    final cleanPin = newPin.trim();
    if (cleanPin.length != 4 || int.tryParse(cleanPin) == null) {
      return false;
    }

    final salt = _generateSalt();
    final hash = _hashPin(cleanPin, salt);

    _pinSalt = salt;
    _pinHash = hash;

    await _prefs?.setString(_keyPinSalt, salt);
    await _prefs?.setString(_keyPinHash, hash);

    _failedAttempts = 0;
    _lockoutUntil = null;
    notifyListeners();
    return true;
  }

  /// Valida o PIN inserido com proteção de lockout
  bool verifyPin(String enteredPin) {
    if (isLockedOut) return false;
    if (!isPinSet) return true; // Sem PIN configurado

    final cleanPin = enteredPin.trim();
    final calculatedHash = _hashPin(cleanPin, _pinSalt ?? '');

    if (calculatedHash == _pinHash) {
      _failedAttempts = 0;
      _lockoutUntil = null;
      return true;
    } else {
      _failedAttempts++;
      if (_failedAttempts >= maxAttempts) {
        _lockoutUntil = DateTime.now().add(lockoutDuration);
      }
      return false;
    }
  }

  /// Remove o PIN de controle parental após confirmação do PIN atual
  Future<bool> removePin(String currentPin) async {
    if (!verifyPin(currentPin)) return false;

    _pinHash = null;
    _pinSalt = null;
    _sessionMasterUnlocked = false;
    _sessionUnlockedCategories.clear();

    await _prefs?.remove(_keyPinHash);
    await _prefs?.remove(_keyPinSalt);
    notifyListeners();
    return true;
  }

  /// Ativa ou desativa o bloqueio automático de conteúdo adulto
  Future<void> setHideAdultContent(bool hide) async {
    _hideAdult = hide;
    await _prefs?.setBool(_keyHideAdult, hide);
    notifyListeners();
  }

  /// Verifica se o nome da categoria corresponde a conteúdo adulto
  bool isAdultCategory(String? categoryName) {
    if (categoryName == null || categoryName.trim().isEmpty) return false;
    return _adultPattern.hasMatch(categoryName);
  }

  /// Verifica se uma categoria específica está protegida por PIN.
  /// Retorna true se:
  /// 1. O PIN estiver configurado e
  /// 2. (A categoria está em `lockedCategories` OU
  ///     (`isAdultContentHidden` e o nome da categoria é adulto)) E
  /// 3. Não estiver temporariamente desbloqueada nesta sessão.
  bool isCategoryLocked(String categoryId, {String? categoryName}) {
    if (!isPinSet) return false;
    if (_sessionMasterUnlocked) return false;
    if (_sessionUnlockedCategories.contains(categoryId)) return false;

    final isManuallyLocked = _lockedCategories.contains(categoryId);
    final isAdult = _hideAdult && isAdultCategory(categoryName);

    return isManuallyLocked || isAdult;
  }

  /// Desbloqueia uma categoria para a sessão atual em memória
  void unlockCategoryForSession(String categoryId) {
    _sessionUnlockedCategories.add(categoryId);
    notifyListeners();
  }

  /// Desbloqueia globalmente o controle parental para a sessão atual em memória
  void unlockMasterForSession() {
    _sessionMasterUnlocked = true;
    notifyListeners();
  }

  /// Bloqueia novamente todas as categorias na sessão
  void lockSession() {
    _sessionMasterUnlocked = false;
    _sessionUnlockedCategories.clear();
    notifyListeners();
  }

  /// Bloqueia ou desbloqueia manualmente uma categoria e persiste
  Future<void> setCategoryLocked(String categoryId, bool locked) async {
    if (locked) {
      _lockedCategories.add(categoryId);
    } else {
      _lockedCategories.remove(categoryId);
      _sessionUnlockedCategories.remove(categoryId);
    }
    await _prefs?.setStringList(_keyLockedCats, _lockedCategories.toList());
    notifyListeners();
  }

  Future<void> toggleCategoryLock(String categoryId) async {
    final isLocked = _lockedCategories.contains(categoryId);
    await setCategoryLocked(categoryId, !isLocked);
  }
}
