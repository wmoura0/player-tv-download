import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerDiagnostics - analyzeError', () {
    test('identifica erro de HTTP 403 / limite de conexões via probe ou mensagem', () {
      const probe = HttpProbeResult(statusCode: 403, elapsedMs: 50);
      final details = PlayerDiagnostics.analyzeError(
        'ExoPlayerImplInternal error [errorCode: 2004] (response code: 403)',
        probe: probe,
      );

      expect(details.shortUiMessage, contains('HTTP 403'));
      expect(details.causeClass, contains('HttpDataSource'));
      expect(details.errorCode, equals(2004));
      expect(details.technicalSummary, contains('403'));
    });

    test('identifica erro de HTTP 404 / arquivo não encontrado', () {
      const probe = HttpProbeResult(statusCode: 404, elapsedMs: 30);
      final details = PlayerDiagnostics.analyzeError(
        'Media3 PlaybackException: ERROR_CODE_IO_FILE_NOT_FOUND',
        probe: probe,
      );

      expect(details.shortUiMessage, contains('HTTP 404'));
      expect(details.errorCodeName, equals('ERROR_CODE_IO_FILE_NOT_FOUND'));
    });

    test('identifica bloqueio de tráfego Cleartext HTTP', () {
      final details = PlayerDiagnostics.analyzeError(
        'java.io.IOException: Cleartext HTTP traffic to example.com not permitted',
      );

      expect(details.shortUiMessage, contains('Cleartext'));
      expect(details.causeClass, equals('CleartextNotPermittedException'));
    });

    test('identifica falha de decodificação / codec de vídeo/áudio incompatível', () {
      final details = PlayerDiagnostics.analyzeError(
        'androidx.media3.exoplayer.mediacodec.MediaCodecRenderer\$DecoderInitializationException: No suitable decoder for video/hevc',
      );

      expect(details.shortUiMessage, contains('Codec/Formato'));
      expect(details.causeClass, contains('MediaCodecRenderer'));
    });

    test('identifica TimeoutException quando servidor demora a responder', () {
      final details = PlayerDiagnostics.analyzeError(
        TimeoutException('Connection timed out after 25s'),
      );

      expect(details.shortUiMessage, contains('Timeout'));
      expect(details.causeClass, equals('TimeoutException'));
    });

    test('extrai error code numérico e nome de código Media3', () {
      final details = PlayerDiagnostics.analyzeError(
        'PlaybackException error code: 3001 ERROR_CODE_PARSER_BAD_MEDIA_MANIFEST',
      );

      expect(details.errorCode, equals(3001));
      expect(details.errorCodeName, equals('ERROR_CODE_PARSER_BAD_MEDIA_MANIFEST'));
    });

    test('sanitiza credenciais contidas em mensagens de erro genéricas', () {
      final details = PlayerDiagnostics.analyzeError(
        'Exception: Erro ao abrir stream http://server.com:8080/movie/user123/passSecret123/99.mp4',
      );

      expect(details.causeMessage, isNot(contains('passSecret123')));
      expect(details.technicalSummary, isNot(contains('passSecret123')));
      expect(details.causeMessage, contains('***'));
    });
  });
}
