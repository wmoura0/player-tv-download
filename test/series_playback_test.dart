import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/screens/series_detail_screen.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('XtreamCatalogService Series Stream URLs Tests', () {
    test('Gera URLs de episódio de série com extensão padrão mp4 e credenciais codificadas', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user@teste',
        password: 'pass#123',
      );

      const episode = XtreamSeriesEpisode(
        id: 7701,
        episodeNum: 1,
        title: 'Piloto',
        seasonNumber: 1,
        containerExtension: null,
      );

      final urls = service.buildSeriesStreamUrls(episode);

      expect(urls.length, greaterThanOrEqualTo(3));
      // 1ª URL: Rota padrão Xtream Codes para séries com extensão default mp4
      expect(urls[0], equals('http://ls-prime.site/series/user%40teste/pass%23123/7701.mp4'));
      // 2ª URL: Alternativa mkv
      expect(urls[1], equals('http://ls-prime.site/series/user%40teste/pass%23123/7701.mkv'));
      // 3ª URL: Alternativa legada direta sem /series/
      expect(urls[2], equals('http://ls-prime.site/user%40teste/pass%23123/7701.mp4'));
    });

    test('Respeita containerExtension quando fornecido pelo episódio (ex: mkv)', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'usuario',
        password: 'senha',
      );

      const episode = XtreamSeriesEpisode(
        id: 9942,
        episodeNum: 5,
        title: 'O Confronto',
        seasonNumber: 2,
        containerExtension: 'mkv',
      );

      final urls = service.buildSeriesStreamUrls(episode);

      expect(urls[0], equals('http://ls-prime.site/series/usuario/senha/9942.mkv'));
      expect(urls[1], equals('http://ls-prime.site/series/usuario/senha/9942.mp4'));
      expect(urls[2], equals('http://ls-prime.site/usuario/senha/9942.mkv'));
    });
  });

  group('XtreamSeriesInfo Model & Ordering Tests', () {
    test('Ordena temporadas e episódios por seus números mesmo recebendo fora de ordem', () {
      final jsonSample = {
        'info': {
          'name': 'Breaking Bad',
          'plot': 'Um professor de química...',
          'genre': 'Drama',
          'rating': '9.5',
        },
        // Temporadas intencionalmente fora de ordem
        'seasons': [
          {'season_number': 2, 'name': 'Temporada 2', 'episode_count': 2},
          {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 2},
        ],
        // Episódios intencionalmente desordenados
        'episodes': {
          '2': [
            {'id': 202, 'episode_num': 2, 'title': 'Episódio 2 da T2', 'container_extension': 'mp4'},
            {'id': 201, 'episode_num': 1, 'title': 'Episódio 1 da T2', 'container_extension': 'mp4'},
          ],
          '1': [
            {'id': 102, 'episode_num': 2, 'title': 'Gato no Saco', 'container_extension': 'mp4'},
            {'id': 101, 'episode_num': 1, 'title': 'Piloto', 'container_extension': 'mp4'},
          ],
        },
      };

      final seriesInfo = XtreamSeriesInfo.fromJson(jsonSample);

      // Validação das temporadas: devem estar ordenadas crescentemente (1, depois 2)
      expect(seriesInfo.seasons.length, equals(2));
      expect(seriesInfo.seasons[0].seasonNumber, equals(1));
      expect(seriesInfo.seasons[1].seasonNumber, equals(2));

      // Validação dos episódios da Temporada 1: 101 (Ep 1), depois 102 (Ep 2)
      final t1Eps = seriesInfo.episodesBySeason[1]!;
      expect(t1Eps.length, equals(2));
      expect(t1Eps[0].episodeNum, equals(1));
      expect(t1Eps[0].id, equals(101));
      expect(t1Eps[1].episodeNum, equals(2));
      expect(t1Eps[1].id, equals(102));

      // Validação dos episódios da Temporada 2: 201 (Ep 1), depois 202 (Ep 2)
      final t2Eps = seriesInfo.episodesBySeason[2]!;
      expect(t2Eps[0].episodeNum, equals(1));
      expect(t2Eps[0].id, equals(201));
      expect(t2Eps[1].episodeNum, equals(2));
      expect(t2Eps[1].id, equals(202));
    });

    test('Sintetiza temporadas ausentes a partir das chaves dos episódios', () {
      final jsonSample = {
        'info': {'name': 'Dark'},
        'seasons': [], // Servidor retornou lista vazia de temporadas
        'episodes': {
          '1': [
            {'id': 501, 'episode_num': 1, 'title': 'Segredos'},
          ],
          '2': [
            {'id': 502, 'episode_num': 1, 'title': 'Déjà-vu'},
          ],
        },
      };

      final seriesInfo = XtreamSeriesInfo.fromJson(jsonSample);

      expect(seriesInfo.seasons.length, equals(2));
      expect(seriesInfo.seasons[0].seasonNumber, equals(1));
      expect(seriesInfo.seasons[1].seasonNumber, equals(2));
    });

    test('getNextEpisode avança corretamente na mesma temporada e transita entre temporadas', () {
      const ep1 = XtreamSeriesEpisode(id: 1, episodeNum: 1, title: 'Ep 1', seasonNumber: 1);
      const ep2 = XtreamSeriesEpisode(id: 2, episodeNum: 2, title: 'Ep 2', seasonNumber: 1);
      const ep3 = XtreamSeriesEpisode(id: 3, episodeNum: 1, title: 'Ep 1', seasonNumber: 2);

      const seriesInfo = XtreamSeriesInfo(
        name: 'Série Teste',
        seasons: [
          XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1'),
          XtreamSeriesSeason(seasonNumber: 2, name: 'Temporada 2'),
        ],
        episodesBySeason: {
          1: [ep1, ep2],
          2: [ep3],
        },
      );

      // 1. Avanço na mesma temporada: T1:E1 -> T1:E2
      final next1 = seriesInfo.getNextEpisode(ep1);
      expect(next1, isNotNull);
      expect(next1!.id, equals(2));

      // 2. Transição para próxima temporada: T1:E2 -> T2:E1
      final next2 = seriesInfo.getNextEpisode(ep2);
      expect(next2, isNotNull);
      expect(next2!.id, equals(3));
      expect(next2.seasonNumber, equals(2));

      // 3. Fim da série: T2:E1 não tem próximo
      final next3 = seriesInfo.getNextEpisode(ep3);
      expect(next3, isNull);
    });
  });

  group('PlaybackProgressService Series Isolation Tests', () {
    test('Isola progresso por conta, série e episódio sem colidir com filmes', () async {
      final service = PlaybackProgressService();
      const accountKey = 'serverA_userA';
      const seriesId = 10;
      const episodeId = 101;

      // Grava progresso de episódio de série
      await service.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 45),
      );

      // Grava último episódio assistido
      await service.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        seasonNumber: 1,
        episodeNum: 1,
      );

      // Recupera progresso do episódio
      final epProg = await service.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
      );
      expect(epProg, isNotNull);
      expect(epProg!.position.inMinutes, equals(15));

      // Outra série ou outro episódio não deve conter esse progresso
      final otherEpProg = await service.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: 102,
      );
      expect(otherEpProg, isNull);

      final otherSeriesProg = await service.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: 11,
        episodeId: episodeId,
      );
      expect(otherSeriesProg, isNull);

      // Não colide com getProgress de filmes (VOD)
      final vodProg = await service.getProgress(
        accountKey: accountKey,
        streamId: episodeId,
      );
      expect(vodProg, isNull);

      // Verifica último episódio salvo da série
      final lastWatched = await service.getLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
      );
      expect(lastWatched, isNotNull);
      expect(lastWatched!['episodeId'], equals(101));
      expect(lastWatched['seasonNumber'], equals(1));
    });
  });

  group('SeriesDetailScreen Widget Tests', () {
    testWidgets('Exibe metadados, seletor de temporadas e lista de episódios reais', (tester) async {
      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_series_info'));
        expect(request.url.queryParameters['series_id'], equals('55'));

        final body = jsonEncode({
          'info': {
            'name': 'Chernobyl',
            'plot': 'História do acidente nuclear de 1986.',
            'rating': '9.4',
            'releaseDate': '2019-05-06',
            'genre': 'Drama / Histórico',
          },
          'seasons': [
            {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 2},
          ],
          'episodes': {
            '1': [
              {
                'id': 5501,
                'episode_num': 1,
                'title': '1:23:45',
                'info': {'duration': '59 min', 'plot': 'A explosão do reator 4.'},
              },
              {
                'id': 5502,
                'episode_num': 2,
                'title': 'Por Favor, Mantenham a Calma',
                'info': {'duration': '65 min', 'plot': 'Evacuação de Pripyat.'},
              },
            ],
          },
        });
        return http.Response(body, 200);
      });

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
        client: mockClient,
      );

      const seriesItem = XtreamSeriesItem(
        seriesId: 55,
        name: 'Chernobyl',
        categoryId: '3',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SeriesDetailScreen(
            series: seriesItem,
            catalogService: catalogService,
            accountKey: 'server_user',
          ),
        ),
      );

      // Estado de carregamento
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      // Metadados carregados
      expect(find.text('Chernobyl'), findsNWidgets(2)); // AppBar e Header
      expect(find.text('SÉRIE'), findsOneWidget);
      expect(find.text('9.4'), findsOneWidget);
      expect(find.text('História do acidente nuclear de 1986.'), findsOneWidget);

      // Seletor de Temporadas
      expect(find.text('Temporada 1'), findsOneWidget);

      // Episódios
      expect(find.text('1:23:45'), findsOneWidget);
      expect(find.text('59 min'), findsOneWidget);
      expect(find.text('Por Favor, Mantenham a Calma'), findsOneWidget);
      expect(find.text('65 min'), findsOneWidget);
    });
  });

  group('VodPlayerView Series & Next Episode Overlay Tests', () {
    testWidgets('Renderiza badge SÉRIE, botão de próximo episódio e overlay de contagem regressiva', (tester) async {
      bool nextEpisodeClicked = false;
      bool cancelClicked = false;
      bool watchNowClicked = false;

      // 1. Testa controles normais com botão de próximo episódio (sem contagem regressiva ativa)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Chernobyl • T1:E1 - 1:23:45',
              badgeText: 'SÉRIE',
              fitMode: LiveVideoFitMode.contain,
              onTogglePlayPause: () {},
              onNextEpisode: () => nextEpisodeClicked = true,
              nextEpisodeTitle: 'T1:E2 - Por Favor, Mantenham a Calma',
              nextEpisodeCountdown: null,
              onCancelNextEpisode: () => cancelClicked = true,
              onPlayNextEpisodeNow: () => watchNowClicked = true,
            ),
          ),
        ),
      );

      // Badge de Série
      expect(find.text('SÉRIE'), findsOneWidget);
      expect(find.text('Chernobyl • T1:E1 - 1:23:45'), findsNWidgets(2));

      // Botão de Próximo Episódio nos controles centrais
      expect(find.byTooltip('Próximo episódio'), findsOneWidget);
      await tester.tap(find.byTooltip('Próximo episódio'));
      expect(nextEpisodeClicked, isTrue);

      // 2. Testa overlay de contagem regressiva cancelável pós-conclusão
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Chernobyl • T1:E1 - 1:23:45',
              badgeText: 'SÉRIE',
              fitMode: LiveVideoFitMode.contain,
              onTogglePlayPause: () {},
              onNextEpisode: () => nextEpisodeClicked = true,
              nextEpisodeTitle: 'T1:E2 - Por Favor, Mantenham a Calma',
              nextEpisodeCountdown: 5,
              onCancelNextEpisode: () => cancelClicked = true,
              onPlayNextEpisodeNow: () => watchNowClicked = true,
            ),
          ),
        ),
      );

      expect(find.text('Próximo Episódio'), findsOneWidget);
      expect(find.text('T1:E2 - Por Favor, Mantenham a Calma'), findsOneWidget);
      expect(find.text('Iniciando em 5s...'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
      expect(find.text('Assistir agora'), findsOneWidget);

      // Tocar em Cancelar
      await tester.tap(find.text('Cancelar'));
      expect(cancelClicked, isTrue);

      // Tocar em Assistir Agora
      await tester.tap(find.text('Assistir agora'));
      expect(watchNowClicked, isTrue);
    });
  });
}
