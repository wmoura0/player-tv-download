import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/favorite_item.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/services/favorites_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M3U Channel Identifier Security Tests', () {
    test('buildM3uChannelId utiliza tvgId limpo quando presente', () {
      final id = FavoriteItem.buildM3uChannelId(
        name: 'Globo SP',
        streamUrl: 'http://user:pass123@iptv.com:8080/live/user/pass/100.m3u8',
        tvgId: 'Globo.sp.hd',
      );

      expect(id, equals('tvg_globo_sp_hd'));
      expect(id, isNot(contains('pass123')));
      expect(id, isNot(contains('http')));
    });

    test('buildM3uChannelId gera identificador seguro e estável quando não há tvgId', () {
      final id1 = FavoriteItem.buildM3uChannelId(
        name: 'Canal Aberto',
        streamUrl: 'http://secret_user:secret_pass@server.net/stream/999.ts?token=xyz123',
        tvgId: null,
      );

      final id2 = FavoriteItem.buildM3uChannelId(
        name: 'Canal Aberto',
        streamUrl: 'http://secret_user:secret_pass@server.net/stream/999.ts?token=xyz123',
        tvgId: '',
      );

      expect(id1, equals(id2));
      expect(id1.startsWith('ch_canal_aberto_'), isTrue);
      // NUNCA deve expor usuário, senha ou token na chave gerada
      expect(id1, isNot(contains('secret_user')));
      expect(id1, isNot(contains('secret_pass')));
      expect(id1, isNot(contains('token')));
      expect(id1, isNot(contains('xyz123')));
    });
  });

  group('FavoriteItem Model & Conversions Tests', () {
    test('Converte de e para XtreamLiveStream mantendo metadados', () {
      const liveStream = XtreamLiveStream(
        num: 1,
        name: 'CNN Brasil HD',
        streamType: 'live',
        streamId: 501,
        streamIcon: 'https://cdn.com/cnn.png',
        categoryId: '2',
      );

      final item = FavoriteItem.fromLiveStream(
        accountKey: 'server_acc1',
        stream: liveStream,
      );

      expect(item.id, equals('501'));
      expect(item.scopeKey, equals('server_acc1'));
      expect(item.type, equals(FavoriteType.live));
      expect(item.name, equals('CNN Brasil HD'));
      expect(item.iconUrl, equals('https://cdn.com/cnn.png'));

      final restored = item.toLiveStream();
      expect(restored.streamId, equals(501));
      expect(restored.name, equals('CNN Brasil HD'));
      expect(restored.streamIcon, equals('https://cdn.com/cnn.png'));
    });

    test('Converte de e para XtreamVodStream mantendo metadados e extensão', () {
      const vod = XtreamVodStream(
        num: 2,
        name: 'Oppenheimer (2023)',
        streamId: 888,
        streamIcon: 'https://cdn.com/opp.jpg',
        rating: '8.9',
        containerExtension: 'mkv',
        categoryId: '15',
      );

      final item = FavoriteItem.fromVodStream(
        accountKey: 'server_acc1',
        movie: vod,
      );

      expect(item.id, equals('888'));
      expect(item.type, equals(FavoriteType.movie));
      expect(item.containerExtension, equals('mkv'));
      expect(item.rating, equals('8.9'));

      final restored = item.toVodStream();
      expect(restored.streamId, equals(888));
      expect(restored.containerExtension, equals('mkv'));
      expect(restored.rating, equals('8.9'));
    });

    test('Serialização e desserialização JSON de FavoriteItem é íntegra', () {
      final now = DateTime.now();
      final original = FavoriteItem(
        id: '123',
        scopeKey: 'test_scope',
        type: FavoriteType.series,
        name: 'Breaking Bad',
        iconUrl: 'http://img.com/bb.jpg',
        rating: '9.5',
        categoryId: 'drama',
        addedAt: now,
      );

      final json = original.toJson();
      final deserialized = FavoriteItem.fromJson(json);

      expect(deserialized.id, equals('123'));
      expect(deserialized.scopeKey, equals('test_scope'));
      expect(deserialized.type, equals(FavoriteType.series));
      expect(deserialized.name, equals('Breaking Bad'));
      expect(deserialized.rating, equals('9.5'));
    });
  });

  group('FavoritesService Persistence & Isolation Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FavoritesService.resetInstanceForTesting();
    });

    test('Adiciona, consulta e remove favoritos com persistência', () async {
      final service = FavoritesService();

      final item = FavoriteItem(
        id: '101',
        scopeKey: 'acc_demo',
        type: FavoriteType.live,
        name: 'Canal Notícias',
        addedAt: DateTime.now(),
      );

      // 1. Inicialmente não é favorito
      expect(service.isFavorite(scopeKey: 'acc_demo', type: FavoriteType.live, id: '101'), isFalse);

      // 2. Adiciona
      await service.addFavorite(item);
      expect(service.isFavorite(scopeKey: 'acc_demo', type: FavoriteType.live, id: '101'), isTrue);

      // 3. Consulta lista
      final favs = await service.getFavorites(scopeKey: 'acc_demo');
      expect(favs.length, equals(1));
      expect(favs.first.name, equals('Canal Notícias'));

      // 4. Nova instância do serviço carrega os dados persistidos
      final newService = FavoritesService();
      final reloaded = await newService.loadFavorites('acc_demo');
      expect(reloaded.length, equals(1));
      expect(newService.isFavorite(scopeKey: 'acc_demo', type: FavoriteType.live, id: '101'), isTrue);

      // 5. Remove
      await newService.removeFavorite(scopeKey: 'acc_demo', type: FavoriteType.live, id: '101');
      expect(newService.isFavorite(scopeKey: 'acc_demo', type: FavoriteType.live, id: '101'), isFalse);
      final emptyFavs = await newService.getFavorites(scopeKey: 'acc_demo');
      expect(emptyFavs, isEmpty);
    });

    test('toggleFavorite adiciona quando não existe e remove quando existe', () async {
      final service = FavoritesService();

      final item = FavoriteItem(
        id: '202',
        scopeKey: 'acc_demo',
        type: FavoriteType.movie,
        name: 'Filme Ação',
        addedAt: DateTime.now(),
      );

      // Primeira alternância: adiciona
      final added = await service.toggleFavorite(item);
      expect(added, isTrue);
      expect(service.isFavorite(scopeKey: 'acc_demo', type: FavoriteType.movie, id: '202'), isTrue);

      // Segunda alternância: remove
      final removed = await service.toggleFavorite(item);
      expect(removed, isFalse);
      expect(service.isFavorite(scopeKey: 'acc_demo', type: FavoriteType.movie, id: '202'), isFalse);
    });

    test('Isola estritamente favoritos entre contas Xtream diferentes', () async {
      final service = FavoritesService();

      final itemContaA = FavoriteItem(
        id: '303',
        scopeKey: 'servidor_a_user1',
        type: FavoriteType.live,
        name: 'Canal Exclusivo Conta A',
        addedAt: DateTime.now(),
      );

      await service.addFavorite(itemContaA);

      // Conta A tem o favorito
      expect(service.isFavorite(scopeKey: 'servidor_a_user1', type: FavoriteType.live, id: '303'), isTrue);
      final favsA = await service.getFavorites(scopeKey: 'servidor_a_user1');
      expect(favsA.length, equals(1));

      // Conta B NÃO tem o favorito
      expect(service.isFavorite(scopeKey: 'servidor_b_user2', type: FavoriteType.live, id: '303'), isFalse);
      final favsB = await service.getFavorites(scopeKey: 'servidor_b_user2');
      expect(favsB, isEmpty);
    });

    test('Isola itens com o mesmo ID numérico mas tipos de conteúdo diferentes', () async {
      final service = FavoritesService();

      // Mesmo ID numérico: 777
      final canal777 = FavoriteItem(
        id: '777',
        scopeKey: 'acc_main',
        type: FavoriteType.live,
        name: 'Canal 777',
        addedAt: DateTime.now(),
      );

      final filme777 = FavoriteItem(
        id: '777',
        scopeKey: 'acc_main',
        type: FavoriteType.movie,
        name: 'Filme 777',
        addedAt: DateTime.now(),
      );

      // Adiciona apenas o canal
      await service.addFavorite(canal777);

      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.live, id: '777'), isTrue);
      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.movie, id: '777'), isFalse);
      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.series, id: '777'), isFalse);

      // Adiciona o filme
      await service.addFavorite(filme777);
      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.live, id: '777'), isTrue);
      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.movie, id: '777'), isTrue);

      // Remove apenas o canal
      await service.removeFavorite(scopeKey: 'acc_main', type: FavoriteType.live, id: '777');
      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.live, id: '777'), isFalse);
      expect(service.isFavorite(scopeKey: 'acc_main', type: FavoriteType.movie, id: '777'), isTrue);
    });

    test('Notifica ouvintes (notifyListeners) ao adicionar ou remover favoritos', () async {
      final service = FavoritesService();
      int notificationCount = 0;
      service.addListener(() => notificationCount++);

      final item = FavoriteItem(
        id: '555',
        scopeKey: 'acc_notify',
        type: FavoriteType.series,
        name: 'Série Notificada',
        addedAt: DateTime.now(),
      );

      await service.addFavorite(item);
      expect(notificationCount, equals(1));

      await service.removeFavorite(scopeKey: 'acc_notify', type: FavoriteType.series, id: '555');
      expect(notificationCount, equals(2));
    });
  });
}
