import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/favorite_item.dart';
import 'package:projeto_tv/models/managed_account.dart';
import 'package:projeto_tv/services/account_manager_service.dart';
import 'package:projeto_tv/services/favorites_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/secure_storage_service.dart';
import 'package:projeto_tv/services/user_profile_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'xtream_server_url': 'http://server.test:8080',
      'xtream_username': 'user_primary',
      'xtream_password': 'pass_primary',
      'xtream_credentials_initialized': 'true',
    });

    await UserProfileService.instance.init();
    await AccountManagerService.instance.init();
    FavoritesService.resetInstanceForTesting();
  });

  group('AccountManagerService - Migration and Multi-Account', () {
    test('idempotently migrates existing SecureStorage credentials without data loss', () async {
      final secureStorage = SecureStorageService();
      final prefs = await SharedPreferences.getInstance();

      final manager = AccountManagerService.forTesting(prefs: prefs, secureStorage: secureStorage);
      await manager.init(prefs, secureStorage);

      expect(manager.accounts.length, equals(1));
      final primary = manager.accounts.first;
      expect(primary.username, equals('user_primary'));
      expect(primary.serverUrl, equals('http://server.test:8080'));
      expect(primary.isCurrent, isTrue);

      // Re-inicialização não duplica a conta
      await manager.init(prefs, secureStorage);
      expect(manager.accounts.length, equals(1));
    });

    test('adds second account and switches between accounts updating secure storage', () async {
      final secureStorage = SecureStorageService();
      final prefs = await SharedPreferences.getInstance();

      final manager = AccountManagerService.forTesting(prefs: prefs, secureStorage: secureStorage);
      await manager.init(prefs, secureStorage);

      final secondAccount = ManagedAccount(
        id: 'acc_backup',
        name: 'Lista Reserva',
        type: AccountType.xtream,
        serverUrl: 'http://backup.server:8080',
        username: 'backup_user',
        password: 'backup_password',
        createdAt: DateTime.now(),
      );

      await manager.addAccount(secondAccount);
      expect(manager.accounts.length, equals(2));

      // Alterna para segunda conta
      await manager.switchAccount('acc_backup');
      expect(manager.currentAccount?.id, equals('acc_backup'));
      expect(await secureStorage.getUsername(), equals('backup_user'));
      expect(await secureStorage.getServerUrl(), equals('http://backup.server:8080'));
    });

    test('prevents deleting the only account in system', () async {
      final secureStorage = SecureStorageService();
      final prefs = await SharedPreferences.getInstance();

      final manager = AccountManagerService.forTesting(prefs: prefs, secureStorage: secureStorage);
      await manager.init(prefs, secureStorage);

      expect(manager.accounts.length, equals(1));
      final deleted = await manager.removeAccount(manager.accounts.first.id);
      expect(deleted, isFalse);
      expect(manager.accounts.length, equals(1));
    });
  });

  group('UserProfileService - Profiles Management and Scoped Keys', () {
    test('initializes default profile with backward-compatible key', () async {
      expect(UserProfileService.instance.profiles, isNotEmpty);
      expect(UserProfileService.instance.currentProfile.id, equals(UserProfileService.defaultProfileId));

      // Chave scoped para perfil default deve ser idêntica à chave base original
      const originalAccountKey = 'http_server_test_8080_user_primary';
      final scopedKey = UserProfileService.instance.getScopedKey(originalAccountKey);
      expect(scopedKey, equals(originalAccountKey));
    });

    test('generates isolated scoped key for custom profile', () async {
      final newProfile = await UserProfileService.instance.createProfile(
        name: 'Crianças',
        isKids: true,
      );

      await UserProfileService.instance.switchProfile(newProfile.id);
      expect(UserProfileService.instance.currentProfile.isKids, isTrue);

      const originalAccountKey = 'acc_key_123';
      final scopedKey = UserProfileService.instance.getScopedKey(originalAccountKey);
      expect(scopedKey, equals('acc_key_123_p_${newProfile.id}'));
    });

    test('prevents deleting default profile', () async {
      final deleted = await UserProfileService.instance.deleteProfile(UserProfileService.defaultProfileId);
      expect(deleted, isFalse);
    });
  });

  group('Profiles Data Isolation - Playback Progress and Favorites', () {
    test('isolates continue watching and playback progress between profiles', () async {
      final prefs = await SharedPreferences.getInstance();
      final progressService = PlaybackProgressService(prefs: prefs);
      const accountKey = 'acc_test_key';

      // 1. Perfil Principal assiste filme 101 até 15 minutos
      await UserProfileService.instance.switchProfile(UserProfileService.defaultProfileId);
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: 101,
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 90),
      );

      final p1 = await progressService.getProgress(accountKey: accountKey, streamId: 101);
      expect(p1, isNotNull);
      expect(p1?.position.inMinutes, equals(15));

      // 2. Cria e alterna para Perfil Kids
      final kidsProfile = await UserProfileService.instance.createProfile(name: 'Kids', isKids: true);
      await UserProfileService.instance.switchProfile(kidsProfile.id);

      // No perfil Kids, o filme 101 NÃO tem progresso
      final pKids = await progressService.getProgress(accountKey: accountKey, streamId: 101);
      expect(pKids, isNull);

      // Perfil Kids assiste filme 202
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: 202,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 60),
      );

      final pKids202 = await progressService.getProgress(accountKey: accountKey, streamId: 202);
      expect(pKids202, isNotNull);

      // 3. Retorna ao Perfil Principal: filme 101 intacto, filme 202 não existe
      await UserProfileService.instance.switchProfile(UserProfileService.defaultProfileId);
      final p1After = await progressService.getProgress(accountKey: accountKey, streamId: 101);
      expect(p1After?.position.inMinutes, equals(15));

      final p1Movie202 = await progressService.getProgress(accountKey: accountKey, streamId: 202);
      expect(p1Movie202, isNull);
    });

    test('isolates favorites between profiles', () async {
      final prefs = await SharedPreferences.getInstance();
      final favService = FavoritesService(prefs: prefs);
      const scope = 'test_scope';

      // Perfil Principal adiciona favorito
      await UserProfileService.instance.switchProfile(UserProfileService.defaultProfileId);
      favService.clearCache();
      await favService.loadFavorites(scope);

      await favService.addFavorite(
        FavoriteItem(
          id: '50',
          scopeKey: scope,
          type: FavoriteType.movie,
          name: 'Filme Favorito do Pai',
          addedAt: DateTime.now(),
        ),
      );

      expect(favService.isFavorite(scopeKey: scope, type: FavoriteType.movie, id: '50'), isTrue);

      // Cria Perfil Infantil
      final kidsProfile = await UserProfileService.instance.createProfile(name: 'Kids Fav', isKids: true);
      await UserProfileService.instance.switchProfile(kidsProfile.id);
      favService.clearCache();
      await favService.loadFavorites(scope);

      // No perfil infantil, o favorito do pai NÃO está presente
      expect(favService.isFavorite(scopeKey: scope, type: FavoriteType.movie, id: '50'), isFalse);
    });
  });
}
