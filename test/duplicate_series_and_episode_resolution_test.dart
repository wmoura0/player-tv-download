import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';
import 'package:projeto_tv/services/url_sanitizer.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Auditoria e Resolução de Séries Duplicadas e Erro HTTP 404', () {
    late XtreamCatalogService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = XtreamCatalogService(
        serverUrl: 'http://stream.servidor.com:8080',
        username: 'user_teste',
        password: 'pass_teste_123',
      );
    });

    // Cenário 1: Duas séries com o mesmo nome e IDs diferentes (isolamento por seriesId)
    test('1. Duas séries com o mesmo nome possuem IDs distintos e isolados', () {
      final jsonSerieA = {
        'num': 1,
        'name': 'FullMetal Alchemist Brotherhood',
        'series_id': 10501,
        'cover': 'http://cover.com/a.jpg',
        'plot': 'História dos irmãos Elric - Versão A',
        'category_id': '10',
      };

      final jsonSerieB = {
        'num': 2,
        'name': 'FullMetal Alchemist Brotherhood',
        'series_id': 10502,
        'cover': 'http://cover.com/b.jpg',
        'plot': 'História dos irmãos Elric - Versão B',
        'category_id': '15',
      };

      final serieA = XtreamSeriesItem.fromJson(jsonSerieA);
      final serieB = XtreamSeriesItem.fromJson(jsonSerieB);

      expect(serieA.name, equals(serieB.name));
      expect(serieA.seriesId, equals(10501));
      expect(serieB.seriesId, equals(10502));
      expect(serieA.seriesId, isNot(equals(serieB.seriesId)));
      expect(serieA.categoryId, equals('10'));
      expect(serieB.categoryId, equals('15'));
    });

    // Cenário 2: Episódios de ambas acessados independentemente sem colisão
    test('2. Episódios de ambas as séries são identificados independentemente', () {
      final epA = XtreamSeriesEpisode.fromJson({
        'id': '77801',
        'stream_id': '77801',
        'episode_num': 64,
        'title': 'Episódio 64 - Jornada Final (Série A)',
        'container_extension': 'mp4',
      }, fallbackSeasonNumber: 1);

      final epB = XtreamSeriesEpisode.fromJson({
        'id': '99402',
        'stream_id': '99402',
        'episode_num': 64,
        'title': 'Episódio 64 - Jornada Final (Série B)',
        'container_extension': 'mp4',
      }, fallbackSeasonNumber: 1);

      expect(epA.id, equals(77801));
      expect(epB.id, equals(99402));

      final urlsA = service.buildSeriesStreamUrls(epA);
      final urlsB = service.buildSeriesStreamUrls(epB);

      expect(urlsA.first, contains('/77801.mp4'));
      expect(urlsB.first, contains('/99402.mp4'));
      expect(urlsA.first, isNot(equals(urlsB.first)));
    });

    // Cenário 3: Episódio 64 da série com colisão (id: 64, stream_id: 184920, episode_num: 64)
    test('3. Episódio com colisão id=64 e stream_id=184920 resolve stream_id prioritário e contingência', () {
      // Simula painel Xtream que retorna id numérico igual ao número do episódio e o verdadeiro stream_id em stream_id
      final epColisao = XtreamSeriesEpisode.fromJson({
        'id': 64,
        'stream_id': 184920,
        'episode_num': 64,
        'title': 'Episódio 64 - O Fim da Viagem',
        'container_extension': 'mp4',
      }, fallbackSeasonNumber: 1);

      // O resolvedId deve priorizar o stream_id real do MySQL streams (184920)
      expect(epColisao.id, equals(184920));
      expect(epColisao.streamId, equals(64));

      final urls = service.buildSeriesStreamUrls(epColisao);

      // A primeira URL DEVE apontar para o stream_id real (184920) evitando HTTP 404
      expect(urls.first, contains('/184920.mp4'));
      // E a lista deve conter URLs de contingência tanto com outras extensões quanto com o ID alternativo
      expect(urls.any((u) => u.contains('/184920.mkv')), isTrue);
      expect(urls.any((u) => u.contains('/184920.ts')), isTrue);
      expect(urls.any((u) => u.contains('/64.mp4')), isTrue);
    });

    // Cenário 4: Séries com múltiplas temporadas estruturadas
    test('4. Séries com múltiplas temporadas agrupam episódios sem mistura', () {
      final mockData = {
        'seasons': [
          {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 30},
          {'season_number': 2, 'name': 'Temporada 2', 'episode_count': 34},
        ],
        'info': {
          'name': 'FullMetal Alchemist Brotherhood',
          'cover': 'http://cover.com/fma.jpg',
        },
        'episodes': {
          '1': [
            {'id': 1001, 'episode_num': 1, 'title': 'Episódio 1'},
            {'id': 1030, 'episode_num': 30, 'title': 'Episódio 30'},
          ],
          '2': [
            {'id': 2001, 'episode_num': 1, 'title': 'Episódio 1 T2'},
            {'id': 2034, 'episode_num': 34, 'title': 'Episódio 64 Geral'},
          ],
        },
      };

      final seriesInfo = XtreamSeriesInfo.fromJson(mockData);

      expect(seriesInfo.seasons.length, equals(2));
      expect(seriesInfo.episodesBySeason.containsKey(1), isTrue);
      expect(seriesInfo.episodesBySeason.containsKey(2), isTrue);
      expect(seriesInfo.episodesBySeason[1]!.first.id, equals(1001));
      expect(seriesInfo.episodesBySeason[2]!.last.id, equals(2034));
      expect(seriesInfo.episodesBySeason[2]!.last.seasonNumber, equals(2));
    });

    // Cenário 5: Séries com extensões diferentes (.mp4, .mkv, .ts)
    test('5. Suporte a diferentes extensões de série (.mp4, .mkv, .ts) com contingência ordenada', () {
      final epTs = XtreamSeriesEpisode.fromJson({
        'id': 5001,
        'episode_num': 1,
        'title': 'Ep 1 TS',
        'container_extension': 'ts',
      }, fallbackSeasonNumber: 1);

      final epMkv = XtreamSeriesEpisode.fromJson({
        'id': 5002,
        'episode_num': 2,
        'title': 'Ep 2 MKV',
        'container_extension': 'mkv',
      }, fallbackSeasonNumber: 1);

      final urlsTs = service.buildSeriesStreamUrls(epTs);
      final urlsMkv = service.buildSeriesStreamUrls(epMkv);

      // Para o episódio com .ts, a rota prioritária DEVE terminar em .ts
      expect(urlsTs.first, endsWith('/5001.ts'));
      expect(urlsTs.any((u) => u.endsWith('/5001.mp4')), isTrue);
      expect(urlsTs.any((u) => u.endsWith('/5001.mkv')), isTrue);

      // Para o episódio com .mkv, a rota prioritária DEVE terminar em .mkv
      expect(urlsMkv.first, endsWith('/5002.mkv'));
      expect(urlsMkv.any((u) => u.endsWith('/5002.mp4')), isTrue);
      expect(urlsMkv.any((u) => u.endsWith('/5002.ts')), isTrue);
    });

    // Cenário 6: Cache de séries e isolamento no armazenamento persistente
    test('6. Chaves de armazenamento e progresso isolam séries duplicadas pelo seriesId', () async {
      final progressService = PlaybackProgressService();
      const accountKey = 'acc_xtream_teste';
      const seriesIdA = 10501;
      const seriesIdB = 10502;
      const episodeId = 64;

      await progressService.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesIdA,
        episodeId: episodeId,
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 24),
      );

      await progressService.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesIdB,
        episodeId: episodeId,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 24),
      );

      final progA = await progressService.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesIdA,
        episodeId: episodeId,
      );

      final progB = await progressService.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesIdB,
        episodeId: episodeId,
      );

      expect(progA, isNotNull);
      expect(progB, isNotNull);
      expect(progA!.position, equals(const Duration(minutes: 15)));
      expect(progB!.position, equals(const Duration(minutes: 5)));
      expect(progA.position, isNot(equals(progB.position)));
    });

    // Cenário 7: Reprodução de filmes (não regressão de VOD)
    test('7. Geração de URLs de filmes (VOD) permanece íntegra e sem regressão', () {
      final movie = XtreamVodStream.fromJson({
        'stream_id': 8812,
        'name': 'O Poderoso Chefão',
        'container_extension': 'mp4',
        'category_id': '5',
      });

      expect(movie.streamId, equals(8812));
      final urls = service.buildVodStreamUrls(movie);
      expect(urls.first, equals('http://stream.servidor.com:8080/movie/user_teste/pass_teste_123/8812.mp4'));
      expect(urls.any((u) => u.endsWith('/8812.mkv')), isTrue);
    });

    // Cenário 8: Reprodução de TV ao vivo (não regressão de Live)
    test('8. Geração de URLs de TV ao vivo permanece íntegra e sem regressão', () {
      final live = XtreamLiveStream.fromJson({
        'stream_id': 4401,
        'name': 'Globo SP HD',
        'stream_type': 'live',
        'category_id': '1',
      });

      expect(live.streamId, equals(4401));
      final urls = service.buildLiveStreamUrls(live);
      expect(urls.first, equals('http://stream.servidor.com:8080/live/user_teste/pass_teste_123/4401.ts'));
      expect(urls.any((u) => u.endsWith('/4401.m3u8')), isTrue);
    });

    // Cenário 9: Tratamento de HTTP 401, 403 e 404 diferenciando ExoPlayer vs Probe
    test('9. Diferenciação rigorosa entre HTTP 404 do ExoPlayer e HTTP 404 do Probe', () {
      // Caso 9a: ExoPlayer recebe 404 diretamente
      final errExo404 = PlayerDiagnostics.analyzeError(
        'androidx.media3.datasource.HttpDataSource\$InvalidResponseCodeException: Response code: 404',
      );
      expect(errExo404.exoPlayerHttpStatus, equals(404));
      expect(errExo404.probeHttpStatus, isNull);
      expect(errExo404.shortUiMessage, contains('HTTP 404'));
      expect(errExo404.causeClass, contains('HttpDataSource'));

      // Caso 9b: ExoPlayer falhou com erro genérico de socket, mas o Probe retornou 404
      const probe404 = HttpProbeResult(statusCode: 404, elapsedMs: 120);
      final errProbeOnly = PlayerDiagnostics.analyzeError(
        'java.net.ConnectException: Connection refused',
        probe: probe404,
      );
      expect(errProbeOnly.exoPlayerHttpStatus, isNull);
      expect(errProbeOnly.probeHttpStatus, equals(404));
      expect(errProbeOnly.shortUiMessage, contains('Sondagem HTTP 404'));

      // Caso 9c: HTTP 401/403 (autenticação ou limite de telas)
      const probe403 = HttpProbeResult(statusCode: 403, elapsedMs: 80);
      final err403 = PlayerDiagnostics.analyzeError(
        'HttpDataSource: response code: 403',
        probe: probe403,
      );
      expect(err403.exoPlayerHttpStatus, equals(403));
      expect(err403.probeHttpStatus, equals(403));
      expect(err403.shortUiMessage, contains('HTTP 403'));
      expect(err403.causeMessage, contains('Token expirado ou limite de conexões'));
    });

    // Cenário 10: Ausência de vazamento de credenciais nos logs (UrlSanitizer)
    test('10. Sanitização de credenciais em URLs e mensagens de erro', () {
      const sensitiveUrl = 'http://stream.servidor.com:8080/series/meu_usuario/senha_ultra_secreta/184920.mp4';
      final sanitized = UrlSanitizer.sanitize(sensitiveUrl);

      expect(sanitized, isNot(contains('meu_usuario')));
      expect(sanitized, isNot(contains('senha_ultra_secreta')));
      expect(sanitized, contains('***'));
      expect(sanitized, contains('184920.mp4'));

      const sensitiveError = 'HttpDataSourceException ao acessar http://server.com/series/usr99/pwd888/ep.ts: 404';
      final sanitizedErr = UrlSanitizer.sanitizeErrorMessage(sensitiveError);

      expect(sanitizedErr, isNot(contains('usr99')));
      expect(sanitizedErr, isNot(contains('pwd888')));
      expect(sanitizedErr, contains('***'));
    });

    // Cenário 11: Colisão invertida (id: 184920, stream_id: 64, episode_num: 64)
    test('11. Episódio com colisão invertida id=184920 e stream_id=64 resolve ID real prioritário', () {
      final epInvertido = XtreamSeriesEpisode.fromJson({
        'id': 184920,
        'stream_id': 64,
        'episode_num': 64,
        'title': 'Episódio 64 - O Fim da Viagem (Invertido)',
        'container_extension': 'mp4',
      }, fallbackSeasonNumber: 1);

      // O resolvedId deve ser 184920 (o stream id real) e altId deve ser 64
      expect(epInvertido.id, equals(184920));
      expect(epInvertido.streamId, equals(64));
      expect(epInvertido.playbackStreamId, equals(184920));

      final urls = service.buildSeriesStreamUrls(epInvertido);
      expect(urls.first, contains('/184920.mp4'));
      expect(urls[1], contains('/64.mp4'));
    });

    // Cenário 12: findEpisodeById localiza por id principal ou por streamId alternativo
    test('12. findEpisodeById localiza tanto pelo id resolvido quanto pelo streamId alternativo', () {
      final mockInfo = XtreamSeriesInfo.fromJson({
        'info': {'name': 'FullMetal Alchemist Brotherhood'},
        'episodes': {
          '1': [
            {
              'id': 64,
              'stream_id': 184920,
              'episode_num': 64,
              'title': 'Episódio 64',
            },
          ],
        },
      });

      final byRealStreamId = mockInfo.findEpisodeById(184920);
      final byAltEpisodeId = mockInfo.findEpisodeById(64);

      expect(byRealStreamId, isNotNull);
      expect(byAltEpisodeId, isNotNull);
      expect(identical(byRealStreamId, byAltEpisodeId), isTrue);
      expect(byRealStreamId!.id, equals(184920));
      expect(byRealStreamId.episodeNum, equals(64));
    });

    // Cenário 13: findEpisodeBySeasonAndNum localiza por temporada e número
    test('13. findEpisodeBySeasonAndNum recupera episódio por temporada e índice', () {
      final mockInfo = XtreamSeriesInfo.fromJson({
        'info': {'name': 'FullMetal Alchemist Brotherhood'},
        'episodes': {
          '5': [
            {
              'id': 184920,
              'stream_id': 64,
              'episode_num': 14,
              'title': 'Episódio 14',
            },
          ],
        },
      });

      final ep = mockInfo.findEpisodeBySeasonAndNum(5, 14);
      expect(ep, isNotNull);
      expect(ep!.id, equals(184920));
      expect(ep.seasonNumber, equals(5));
      expect(ep.episodeNum, equals(14));
    });

    // Cenário 14: Prioridade de rotas de contingência com alternativeEpisodeId
    test('14. Contingência de URL tenta imediatamente alternativeEpisodeId antes de esgotar tentativas', () {
      final urls = service.buildSeriesStreamUrlsById(
        184920,
        extension: 'mp4',
        alternativeEpisodeId: 64,
      );

      // A 1ª URL deve ser 184920.mp4
      expect(urls[0], contains('/184920.mp4'));
      // A 2ª URL DEVE ser a alternativa com a mesma extensão (64.mp4)
      expect(urls[1], contains('/64.mp4'));
      // A 3ª e 4ª são as extensões alternativas
      expect(urls[2], contains('/184920.mkv'));
      expect(urls[3], contains('/64.mkv'));
    });
  });
}
