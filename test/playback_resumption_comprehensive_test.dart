import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Playback Resumption Comprehensive Tests', () {
    const accountKey = 'server_teste_usuario1';

    test('1. Retomada de filme com posição salva válida', () async {
      final progressService = PlaybackProgressService();
      const movieId = 2001;
      final savedPos = const Duration(minutes: 32, seconds: 15);
      final totalDur = const Duration(hours: 1, minutes: 50);

      // Salva progresso no serviço
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: movieId,
        position: savedPos,
        duration: totalDur,
      );

      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: movieId,
          type: ContinueWatchingType.movie,
          title: 'Filme de Ação',
          position: savedPos,
          duration: totalDur,
          updatedAt: DateTime.now(),
        ),
      );

      // Recupera o progresso do filme
      final retrieved = await progressService.getProgress(
        accountKey: accountKey,
        streamId: movieId,
      );
      expect(retrieved, isNotNull);
      expect(retrieved!.position, equals(savedPos));
      expect(retrieved.duration, equals(totalDur));
      expect(retrieved.canResume, isTrue);

      // Verifica na lista de Continuar Assistindo
      final continueList = await progressService.getContinueWatchingList(accountKey: accountKey);
      expect(continueList.length, equals(1));
      expect(continueList.first.streamId, equals(movieId));
      expect(continueList.first.type, equals(ContinueWatchingType.movie));
      expect(continueList.first.position, equals(savedPos));
    });

    test('2. Retomada de episódio de série com posição salva', () async {
      final progressService = PlaybackProgressService();
      const seriesId = 500;
      const episodeId = 5012;
      final savedPos = const Duration(minutes: 18, seconds: 40);
      final totalDur = const Duration(minutes: 45);

      await progressService.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        position: savedPos,
        duration: totalDur,
      );

      await progressService.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        seasonNumber: 2,
        episodeNum: 4,
      );

      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: episodeId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: 'Série de Ficção',
          subtitle: 'T2:E4 • O Retorno',
          position: savedPos,
          duration: totalDur,
          updatedAt: DateTime.now(),
          seasonNumber: 2,
          episodeNum: 4,
        ),
      );

      // Recupera o episódio
      final epProg = await progressService.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
      );
      expect(epProg, isNotNull);
      expect(epProg!.position, equals(savedPos));
      expect(epProg.canResume, isTrue);

      final lastWatched = await progressService.getLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
      );
      expect(lastWatched, isNotNull);
      expect(lastWatched!['episodeId'], equals(episodeId));
      expect(lastWatched['seasonNumber'], equals(2));
      expect(lastWatched['episodeNum'], equals(4));

      final continueList = await progressService.getContinueWatchingList(accountKey: accountKey);
      expect(continueList.first.streamId, equals(episodeId));
      expect(continueList.first.seriesId, equals(seriesId));
      expect(continueList.first.type, equals(ContinueWatchingType.series));
      expect(continueList.first.position, equals(savedPos));
    });

    test('3. Início de conteúdo sem histórico (a partir do início)', () async {
      final progressService = PlaybackProgressService();
      const unplayedMovieId = 3001;

      final prog = await progressService.getProgress(
        accountKey: accountKey,
        streamId: unplayedMovieId,
      );
      expect(prog, isNull);

      final continueList = await progressService.getContinueWatchingList(accountKey: accountKey);
      expect(continueList.where((i) => i.streamId == unplayedMovieId), isEmpty);
    });

    test('4. Transição entre episódios (próximo episódio e avanço de sequência)', () async {
      final episodes = [
        const XtreamSeriesEpisode(id: 101, episodeNum: 1, seasonNumber: 1, title: 'Episódio 1'),
        const XtreamSeriesEpisode(id: 102, episodeNum: 2, seasonNumber: 1, title: 'Episódio 2'),
        const XtreamSeriesEpisode(id: 201, episodeNum: 1, seasonNumber: 2, title: 'Episódio 1 da T2'),
      ];

      final seriesInfo = XtreamSeriesInfo(
        name: 'Série Sequencial',
        seasons: [
          const XtreamSeriesSeason(seasonNumber: 1, name: 'Temporada 1'),
          const XtreamSeriesSeason(seasonNumber: 2, name: 'Temporada 2'),
        ],
        episodesBySeason: {
          1: [episodes[0], episodes[1]],
          2: [episodes[2]],
        },
      );

      // Próximo episódio na mesma temporada
      final next1 = seriesInfo.getNextEpisode(episodes[0]);
      expect(next1, isNotNull);
      expect(next1!.id, equals(102));
      expect(next1.episodeNum, equals(2));

      // Próximo episódio transicionando de temporada (T1 -> T2)
      final nextSeasonEp = seriesInfo.getNextEpisode(episodes[1]);
      expect(nextSeasonEp, isNotNull);
      expect(nextSeasonEp!.id, equals(201));
      expect(nextSeasonEp.seasonNumber, equals(2));
      expect(nextSeasonEp.episodeNum, equals(1));

      // Último episódio da série retorna null
      final noNext = seriesInfo.getNextEpisode(episodes[2]);
      expect(noNext, isNull);
    });

    test('5. Reprodução de filme após assistir série (isolamento mútuo)', () async {
      final progressService = PlaybackProgressService();
      const seriesId = 40;
      const episodeId = 401;
      const movieId = 88;

      // Salva série
      await progressService.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 40),
      );
      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: episodeId,
          seriesId: seriesId,
          type: ContinueWatchingType.series,
          title: 'Série Teste',
          position: const Duration(minutes: 20),
          duration: const Duration(minutes: 40),
          updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        ),
      );

      // Salva filme posterior
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: movieId,
        position: const Duration(minutes: 45),
        duration: const Duration(hours: 2),
      );
      await progressService.saveContinueWatchingItem(
        accountKey: accountKey,
        item: ContinueWatchingItem(
          streamId: movieId,
          type: ContinueWatchingType.movie,
          title: 'Filme Posterior',
          position: const Duration(minutes: 45),
          duration: const Duration(hours: 2),
          updatedAt: DateTime.now(),
        ),
      );

      // Ambos coexistem ordenados pelo mais recente
      final list = await progressService.getContinueWatchingList(accountKey: accountKey);
      expect(list.length, equals(2));
      expect(list.first.type, equals(ContinueWatchingType.movie));
      expect(list.first.streamId, equals(movieId));
      expect(list.last.type, equals(ContinueWatchingType.series));
      expect(list.last.streamId, equals(episodeId));
    });

    test('6. Retomada após reiniciar o aplicativo (persistência entre instâncias)', () async {
      final storageMap = <String, Object>{};
      SharedPreferences.setMockInitialValues(storageMap);

      // Instância A grava
      final serviceA = PlaybackProgressService();
      await serviceA.saveProgress(
        accountKey: accountKey,
        streamId: 999,
        position: const Duration(minutes: 50),
        duration: const Duration(hours: 1, minutes: 40),
      );

      // Instância B (simula nova abertura do app) lê
      final serviceB = PlaybackProgressService();
      final retrieved = await serviceB.getProgress(accountKey: accountKey, streamId: 999);
      expect(retrieved, isNotNull);
      expect(retrieved!.position, equals(const Duration(minutes: 50)));
    });

    test('7. Tratamento de posição salva inválida ou maior que a duração do vídeo', () async {
      final progressService = PlaybackProgressService();
      const movieId = 777;

      // Posição que excede 96% ou 45 segundos do fim é considerada concluída e não é retornada para retomar
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: movieId,
        position: const Duration(minutes: 119),
        duration: const Duration(hours: 2),
      );

      final retrieved = await progressService.getProgress(accountKey: accountKey, streamId: movieId);
      expect(retrieved, isNull); // Finalizado não retoma

      // Posição de menos de 10 segundos também não é retornada
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: 778,
        position: const Duration(seconds: 4),
        duration: const Duration(hours: 2),
      );
      final tooShort = await progressService.getProgress(accountKey: accountKey, streamId: 778);
      expect(tooShort, isNull);
    });

    test('8. Tratamento de URLs candidatas e contingência para filmes e episódios', () {
      final catalogService = XtreamCatalogService(
        serverUrl: 'http://cdn-teste.com:8080',
        username: 'user_safe',
        password: 'pass_safe',
      );

      // Teste para filme
      const movie = XtreamVodStream(streamId: 1234, name: 'Matrix', categoryId: '1', containerExtension: 'mkv');
      final vodUrls = catalogService.buildVodStreamUrls(movie);
      expect(vodUrls.first, equals('http://cdn-teste.com:8080/movie/user_safe/pass_safe/1234.mkv'));
      expect(vodUrls[1], equals('http://cdn-teste.com:8080/movie/user_safe/pass_safe/1234.mp4'));

      // Teste para episódio
      const ep = XtreamSeriesEpisode(id: 4321, episodeNum: 3, seasonNumber: 1, title: 'Piloto', containerExtension: 'mp4');
      final seriesUrls = catalogService.buildSeriesStreamUrls(ep);
      expect(seriesUrls.first, equals('http://cdn-teste.com:8080/series/user_safe/pass_safe/4321.mp4'));
      expect(seriesUrls[1], equals('http://cdn-teste.com:8080/series/user_safe/pass_safe/4321.mkv'));
    });

    test('9. Isolamento estrito de progresso entre diferentes conteúdos e contas', () async {
      final progressService = PlaybackProgressService();
      const account1 = 'serverA_userA';
      const account2 = 'serverB_userB';

      // Salva mesmo ID 10 em contas diferentes
      await progressService.saveProgress(
        accountKey: account1,
        streamId: 10,
        position: const Duration(minutes: 15),
        duration: const Duration(hours: 1),
      );
      await progressService.saveProgress(
        accountKey: account2,
        streamId: 10,
        position: const Duration(minutes: 45),
        duration: const Duration(hours: 1),
      );

      final p1 = await progressService.getProgress(accountKey: account1, streamId: 10);
      final p2 = await progressService.getProgress(accountKey: account2, streamId: 10);

      expect(p1!.position, equals(const Duration(minutes: 15)));
      expect(p2!.position, equals(const Duration(minutes: 45)));

      // Série ID 10 vs Filme ID 10 na mesma conta não colidem
      await progressService.saveEpisodeProgress(
        accountKey: account1,
        seriesId: 100,
        episodeId: 10,
        position: const Duration(minutes: 25),
        duration: const Duration(minutes: 50),
      );

      final epProg = await progressService.getEpisodeProgress(
        accountKey: account1,
        seriesId: 100,
        episodeId: 10,
      );
      final movieProg = await progressService.getProgress(accountKey: account1, streamId: 10);

      expect(epProg!.position, equals(const Duration(minutes: 25)));
      expect(movieProg!.position, equals(const Duration(minutes: 15)));
    });
  });
}
