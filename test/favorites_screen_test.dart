import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/favorite_item.dart';
import 'package:projeto_tv/models/xtream_account.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/screens/favorites_screen.dart';
import 'package:projeto_tv/screens/vod_detail_screen.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/services/favorites_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FavoritesService service;
  const mockAccount = XtreamAccount(
    serverUrl: 'http://test.server:80',
    username: 'user_fav',
    isAuthorized: true,
    status: 'Active',
  );
  final accountKey = PlaybackProgressService.buildAccountKey(
    mockAccount.serverUrl,
    mockAccount.username,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'xtream_password': 'mock_password'});
    FavoritesService.resetInstanceForTesting();
    service = FavoritesService.instance;
  });

  group('FavoritesScreen Widget Tests', () {
    testWidgets('Exibe abas com contagem zerada e estado vazio inicial', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FavoritesScreen(
            xtreamAccount: mockAccount,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Meus Favoritos'), findsOneWidget);
      expect(find.text('Canais (0)'), findsOneWidget);
      expect(find.text('Filmes (0)'), findsOneWidget);
      expect(find.text('Séries (0)'), findsOneWidget);
      expect(find.text('Nenhum item em canais de TV ao vivo'), findsOneWidget);
    });

    testWidgets('Exibe itens favoritados em suas respectivas abas', (tester) async {
      final canalFav = FavoriteItem(
        id: '10',
        scopeKey: accountKey,
        type: FavoriteType.live,
        name: 'Globo HD',
        addedAt: DateTime.now(),
      );

      final filmeFav = FavoriteItem(
        id: '20',
        scopeKey: accountKey,
        type: FavoriteType.movie,
        name: 'Interestelar',
        rating: '8.7',
        addedAt: DateTime.now(),
      );

      final serieFav = FavoriteItem(
        id: '30',
        scopeKey: accountKey,
        type: FavoriteType.series,
        name: 'Stranger Things',
        rating: '8.6',
        addedAt: DateTime.now(),
      );

      await service.addFavorite(canalFav);
      await service.addFavorite(filmeFav);
      await service.addFavorite(serieFav);

      await tester.pumpWidget(
        const MaterialApp(
          home: FavoritesScreen(
            xtreamAccount: mockAccount,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Confere abas com contagens
      expect(find.text('Canais (1)'), findsOneWidget);
      expect(find.text('Filmes (1)'), findsOneWidget);
      expect(find.text('Séries (1)'), findsOneWidget);

      // Aba 1: Canal visível
      expect(find.text('Globo HD'), findsOneWidget);

      // Troca para Aba 2 (Filmes)
      await tester.tap(find.text('Filmes (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Interestelar'), findsOneWidget);

      // Troca para Aba 3 (Séries)
      await tester.tap(find.text('Séries (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Stranger Things'), findsOneWidget);
    });

    testWidgets('Remoção de favorito exibe feedback visual e SnackBar com Desfazer', (tester) async {
      final canal = FavoriteItem(
        id: '99',
        scopeKey: accountKey,
        type: FavoriteType.live,
        name: 'ESPN Brasil',
        addedAt: DateTime.now(),
      );
      await service.addFavorite(canal);

      await tester.pumpWidget(
        const MaterialApp(
          home: FavoritesScreen(
            xtreamAccount: mockAccount,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ESPN Brasil'), findsOneWidget);

      // Clica no botão de remover favorito
      await tester.tap(find.byTooltip('Remover dos favoritos'));
      await tester.pumpAndSettle();

      // Confere SnackBar
      expect(find.text('"ESPN Brasil" removido dos favoritos.'), findsOneWidget);
      expect(find.text('Desfazer'), findsOneWidget);

      // Confere que agora a aba está vazia
      expect(find.text('Canais (0)'), findsOneWidget);
    });
  });

  group('Detail Screens Favorites Toggle Tests', () {
    testWidgets('VodDetailScreen alterna favorito via botão na AppBar', (tester) async {
      const movie = XtreamVodStream(
        streamId: 500,
        name: 'Matrix',
        categoryId: '1',
      );

      final catalogService = XtreamCatalogService(
        serverUrl: mockAccount.serverUrl,
        username: mockAccount.username,
        password: 'password',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: VodDetailScreen(
            movie: movie,
            catalogService: catalogService,
            accountKey: accountKey,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Inicialmente não é favorito
      expect(service.isFavorite(scopeKey: accountKey, type: FavoriteType.movie, id: '500'), isFalse);
      expect(find.byTooltip('Adicionar aos favoritos'), findsWidgets);

      // Toca no botão da AppBar para favoritar
      await tester.tap(find.byTooltip('Adicionar aos favoritos').first);
      await tester.pumpAndSettle();

      // Agora é favorito
      expect(service.isFavorite(scopeKey: accountKey, type: FavoriteType.movie, id: '500'), isTrue);
      expect(find.byTooltip('Remover dos favoritos'), findsWidgets);
    });

    testWidgets('SeriesDetailScreen alterna favorito via botão na AppBar', (tester) async {
      const series = XtreamSeriesItem(
        seriesId: 600,
        name: 'Dark',
        categoryId: '2',
      );

      final catalogService = XtreamCatalogService(
        serverUrl: mockAccount.serverUrl,
        username: mockAccount.username,
        password: 'password',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: series,
            catalogService: catalogService,
            accountKey: accountKey,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Inicialmente não é favorito
      expect(service.isFavorite(scopeKey: accountKey, type: FavoriteType.series, id: '600'), isFalse);

      // Toca no botão da AppBar
      await tester.tap(find.byTooltip('Adicionar aos favoritos'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Agora é favorito
      expect(service.isFavorite(scopeKey: accountKey, type: FavoriteType.series, id: '600'), isTrue);
    });
  });
}
