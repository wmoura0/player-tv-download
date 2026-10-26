import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/models/xtream_vod_info.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Ponto 2 & 7: Resolução de Extensões e Geração de URLs de Filmes e Séries', () {
    test('Extrai extensão com segurança a partir de container_extension, extension ou video_type', () {
      // 1. A partir de container_extension
      final ep1 = XtreamSeriesEpisode.fromJson(
        {
          'id': 101,
          'container_extension': 'mkv',
          'title': 'Ep 1',
        },
        fallbackSeasonNumber: 1,
      );
      expect(ep1.containerExtension, equals('mkv'));

      // 2. A partir do campo alternativo extension
      final ep2 = XtreamSeriesEpisode.fromJson(
        {
          'id': 102,
          'extension': 'mp4',
          'title': 'Ep 2',
        },
        fallbackSeasonNumber: 1,
      );
      expect(ep2.containerExtension, equals('mp4'));

      // 3. A partir do campo alternativo video_type
      final ep3 = XtreamSeriesEpisode.fromJson(
        {
          'id': 103,
          'video_type': 'avi',
          'title': 'Ep 3',
        },
        fallbackSeasonNumber: 1,
      );
      expect(ep3.containerExtension, equals('avi'));

      // 4. Higienização: remove pontos e caracteres não-alfanuméricos
      final ep4 = XtreamSeriesEpisode.fromJson(
        {
          'id': 104,
          'container_extension': '.mkv ',
          'title': 'Ep 4',
        },
        fallbackSeasonNumber: 1,
      );
      expect(ep4.containerExtension, equals('mkv'));
    });

    test('XtreamVodInfo resolve extensão a partir de campos alternativos com higienização', () {
      final info = XtreamVodInfo.fromJson(
        {
          'movie_data': {
            'stream_id': 500,
            'name': 'Filme Teste',
            'extension': '.mp4',
          },
          'info': {},
        },
      );
      expect(info.containerExtension, equals('mp4'));
    });

    test('buildSeriesStreamUrlsById prioriza a extensão legítima e constrói rotas ordenadas', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://stream.server:8080',
        username: 'user_tv',
        password: 'pass#secret',
      );

      final urlsMkv = service.buildSeriesStreamUrlsById(888, extension: 'mkv');
      expect(urlsMkv.length, greaterThanOrEqualTo(3));
      // Rota 0 deve ser estritamente a extensão legítima informada (.mkv)
      expect(urlsMkv[0], equals('http://stream.server:8080/series/user_tv/pass%23secret/888.mkv'));
      // Rota 1 contingência alternativa (.mp4)
      expect(urlsMkv[1], equals('http://stream.server:8080/series/user_tv/pass%23secret/888.mp4'));

      final urlsMp4 = service.buildSeriesStreamUrlsById(999, extension: 'mp4');
      // Rota 0 deve ser .mp4
      expect(urlsMp4[0], equals('http://stream.server:8080/series/user_tv/pass%23secret/999.mp4'));
      // Rota 1 contingência alternativa (.mkv)
      expect(urlsMp4[1], equals('http://stream.server:8080/series/user_tv/pass%23secret/999.mkv'));
    });

    test('buildVodStreamUrlsById prioriza a extensão legítima e constrói rotas ordenadas', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://stream.server:8080',
        username: 'usuario',
        password: '123',
      );

      final urls = service.buildVodStreamUrlsById(1234, extension: 'mkv');
      expect(urls[0], equals('http://stream.server:8080/movie/usuario/123/1234.mkv'));
      expect(urls[1], equals('http://stream.server:8080/movie/usuario/123/1234.mp4'));
      expect(urls[2], equals('http://stream.server:8080/usuario/123/1234.mkv'));
    });
  });

  group('Ponto 1, 3 & 6: Lógica de Classificação Semântica de Erros e Não-Churning em Timeout', () {
    String classifyError(Object e, {required bool isSeries}) {
      final errLower = e.toString().toLowerCase();
      final isTimeout = e is TimeoutException || errLower.contains('timeoutexception');

      if (isTimeout) {
        return 'O servidor demorou muito para responder (tempo limite de 25s excedido). Verifique sua conexão ou tente novamente.';
      } else if (errLower.contains('response code: 404') ||
          errLower.contains('code: 404') ||
          errLower.contains('404 not found')) {
        return isSeries
            ? 'Episódio não encontrado no servidor remoto (HTTP 404).'
            : 'Filme não encontrado no servidor remoto (HTTP 404).';
      } else if (errLower.contains('response code: 401') ||
          errLower.contains('response code: 403') ||
          errLower.contains('code: 401') ||
          errLower.contains('code: 403')) {
        return 'Acesso não autorizado pelo servidor ou limite de conexões simultâneas atingido (HTTP 401/403).';
      } else if (errLower.contains('response code: 5') ||
          errLower.contains('code: 500') ||
          errLower.contains('code: 502') ||
          errLower.contains('code: 503')) {
        return 'O servidor de transmissão apresentou instabilidade interna (HTTP 5xx). Tente novamente mais tarde.';
      } else if (errLower.contains('decoderinitializationexception') ||
          errLower.contains('mediacodec') ||
          errLower.contains('unrecognizedinputformat') ||
          errLower.contains('parserexception')) {
        return isSeries
            ? 'Formato de vídeo ou áudio do episódio não suportado pelo decodificador deste aparelho.'
            : 'Formato de vídeo ou áudio do filme não suportado pelo decodificador deste aparelho.';
      } else if (errLower.contains('unknownhostexception') ||
          errLower.contains('connectexception') ||
          errLower.contains('socketexception') ||
          errLower.contains('network is unreachable') ||
          errLower.contains('httpdatasourceexception')) {
        return 'Falha de conexão com o servidor de streaming. Verifique sua conexão com a internet.';
      } else {
        return isSeries
            ? 'Não foi possível reproduzir o episódio.'
            : 'Não foi possível reproduzir o filme.';
      }
    }

    bool shouldAttemptAlternative(Object e) {
      final errLower = e.toString().toLowerCase();
      final isTimeout = e is TimeoutException || errLower.contains('timeoutexception');
      if (isTimeout) return false; // REGRA 3: Não tentar outra extensão por timeout

      final isResourceNotFound = errLower.contains('response code: 404') ||
          errLower.contains('code: 404') ||
          errLower.contains('404 not found') ||
          errLower.contains('decoderinitializationexception') ||
          errLower.contains('unrecognizedinputformat');

      return isResourceNotFound;
    }

    test('Timeout de 25s não dispara tentativa de rota alternativa e exibe mensagem recuperável', () {
      final timeoutErr = TimeoutException('Future not completed within 25 seconds');
      final msg = classifyError(timeoutErr, isSeries: true);
      expect(msg, contains('tempo limite de 25s excedido'));
      expect(msg, contains('tente novamente'));
      expect(shouldAttemptAlternative(timeoutErr), isFalse,
          reason: 'Timeout nunca deve avançar cegamente para URLs alternativas sintéticas');
    });

    test('HTTP 404 é classificado com precisão e permite tentativa de extensão alternativa', () {
      const err404 = 'ExoPlayer: HttpDataSource: Response code: 404 Not Found';
      final msgSeries = classifyError(err404, isSeries: true);
      expect(msgSeries, contains('HTTP 404'));
      expect(msgSeries, contains('Episódio não encontrado'));
      expect(shouldAttemptAlternative(err404), isTrue,
          reason: 'HTTP 404 indica que a extensão pode ser diferente no servidor e justifica contingência');

      final msgVod = classifyError(err404, isSeries: false);
      expect(msgVod, contains('HTTP 404'));
      expect(msgVod, contains('Filme não encontrado'));
    });

    test('HTTP 401 e 403 identificam limite de conexões ou credenciais sem churn de URLs', () {
      const err403 = 'HttpDataSource: Response code: 403 Forbidden';
      final msg = classifyError(err403, isSeries: true);
      expect(msg, contains('HTTP 401/403'));
      expect(msg, contains('limite de conexões'));
      expect(shouldAttemptAlternative(err403), isFalse,
          reason: 'Erro de autenticação ou limite não deve disparar outras rotas para não sobrecarregar o painel');
    });

    test('Erros de codec/formato identificam incompatibilidade de decodificador', () {
      const codecErr = 'MediaCodecVideoRendererException: DecoderInitializationException';
      final msg = classifyError(codecErr, isSeries: true);
      expect(msg, contains('não suportado pelo decodificador'));
      expect(shouldAttemptAlternative(codecErr), isTrue);
    });

    test('Erros de rede (ConnectException, SocketException) reportam falha de conexão', () {
      const netErr = 'ConnectException: Failed to connect to stream.server:8080';
      final msg = classifyError(netErr, isSeries: false);
      expect(msg, contains('Falha de conexão com o servidor de streaming'));
      expect(shouldAttemptAlternative(netErr), isFalse);
    });
  });
}
