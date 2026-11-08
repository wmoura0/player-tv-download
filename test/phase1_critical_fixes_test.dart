import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/favorite_item.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/player_diagnostics.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fase 1.1: Identificação de Episódios Xtream e Séries Longas (>100 Eps)', () {
    test('1. Resolve episódio de série longa (>100 episódios) quando id == episodeNum', () {
      final json = {
        'id': '105',
        'stream_id': '84201',
        'episode_num': '105',
        'season': '1',
        'title': 'One Piece - Episódio 105',
        'container_extension': 'mp4',
      };

      final ep = XtreamSeriesEpisode.fromJson(json, fallbackSeasonNumber: 1);
      expect(ep.episodeNum, equals(105));
      expect(ep.playbackStreamId, equals(84201));
      expect(ep.streamId, equals(105)); // altId preservado
      expect(ep.containerExtension, equals('mp4'));
    });

    test('2. Resolve episódio de série longa quando stream_id == episodeNum (invertido)', () {
      final json = {
        'id': '99402',
        'stream_id': '150',
        'episode_num': '150',
        'season': '2',
        'title': 'Naruto Shippuden - Episódio 150',
        'container_extension': 'mkv',
      };

      final ep = XtreamSeriesEpisode.fromJson(json, fallbackSeasonNumber: 2);
      expect(ep.episodeNum, equals(150));
      expect(ep.playbackStreamId, equals(99402));
      expect(ep.streamId, equals(150)); // altId preservado
      expect(ep.containerExtension, equals('mkv'));
    });

    test('3. Reconhece campo episode_id explícito vindo da API Xtream', () {
      final json = {
        'episode_id': '77123',
        'stream_id': '77123',
        'episode_num': '12',
        'title': 'Episódio com episode_id',
      };

      final ep = XtreamSeriesEpisode.fromJson(json, fallbackSeasonNumber: 1);
      expect(ep.playbackStreamId, equals(77123));
      expect(ep.episodeNum, equals(12));
    });

    test('4. Sem valores mágicos: ambos IDs diferentes de episodeNum priorizam stream_id e guardam id', () {
      final json = {
        'id': '45',
        'stream_id': '82',
        'episode_num': '1',
        'season': '1',
        'title': 'Episódio com IDs sequenciais baixos',
      };

      final ep = XtreamSeriesEpisode.fromJson(json, fallbackSeasonNumber: 1);
      expect(ep.playbackStreamId, equals(82));
      expect(ep.streamId, equals(45));
    });
  });

  group('Fase 1.2: Diagnóstico Media3 (3001, 3003, 401, 403, 404, TLS)', () {
    test('1. Código Media3 3001 é identificado como erro de container/formato', () {
      final details = PlayerDiagnostics.analyzeError(
        'ExoPlayer error code: 3001 ERROR_CODE_PARSING_CONTAINER_MALFORMED',
      );
      expect(details.isFormatOrContainerError, isTrue);
      expect(details.isAuthOrForbidden, isFalse);
      expect(details.shortUiMessage, contains('3001'));
    });

    test('2. Código Media3 3003 é identificado como container não suportado', () {
      final details = PlayerDiagnostics.analyzeError(
        'ExoPlayer error code: 3003 ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED',
      );
      expect(details.isFormatOrContainerError, isTrue);
      expect(details.isAuthOrForbidden, isFalse);
      expect(details.shortUiMessage, contains('3003'));
    });

    test('3. HTTP 401 e 403 são identificados como autorização e nunca rota alternativa', () {
      final details401 = PlayerDiagnostics.analyzeError('response code: 401');
      final details403 = PlayerDiagnostics.analyzeError('response code: 403');
      expect(details401.isAuthOrForbidden, isTrue);
      expect(details403.isAuthOrForbidden, isTrue);
      expect(details401.isResourceNotFound, isFalse);
    });

    test('4. HTTP 404 é identificado como recurso não encontrado', () {
      final details404 = PlayerDiagnostics.analyzeError('response code: 404');
      expect(details404.isResourceNotFound, isTrue);
      expect(details404.isAuthOrForbidden, isFalse);
    });

    test('5. TLS Handshake com certificado expirado/fora da validade diagnostica data/hora incorreta', () {
      final details = PlayerDiagnostics.analyzeError(
        'HandshakeException: Certificate_verify_failed: certificate is not yet valid or has expired, check current time',
      );
      expect(details.shortUiMessage, contains('Data/Hora'));
      expect(details.causeMessage, contains('relógio do Fire TV'));
    });
  });

  group('Fase 1.3: Favoritos com directSource e compatibilidade legada', () {
    test('1. Serializa e desserializa FavoriteItem preservando containerExtension e directSource', () {
      final item = FavoriteItem(
        id: '1234',
        scopeKey: 'server_user',
        type: FavoriteType.movie,
        name: 'Matrix',
        containerExtension: 'mkv',
        directSource: 'http://direct.stream/matrix.mkv',
        addedAt: DateTime(2026, 11, 7, 22, 0),
      );

      final json = item.toJson();
      expect(json['containerExtension'], equals('mkv'));
      expect(json['directSource'], equals('http://direct.stream/matrix.mkv'));

      final restored = FavoriteItem.fromJson(json);
      expect(restored.containerExtension, equals('mkv'));
      expect(restored.directSource, equals('http://direct.stream/matrix.mkv'));
      final vod = restored.toVodStream();
      expect(vod.containerExtension, equals('mkv'));
      expect(vod.directSource, equals('http://direct.stream/matrix.mkv'));
    });

    test('2. Compatibilidade legada: JSON de favorito antigo sem directSource carrega normalmente', () {
      final legacyJson = {
        'id': '5678',
        'scopeKey': 'server_user',
        'type': 'movie',
        'name': 'Inception',
        'containerExtension': 'mp4',
        'addedAt': '2026-10-01T12:00:00.000Z',
      };

      final restored = FavoriteItem.fromJson(legacyJson);
      expect(restored.id, equals('5678'));
      expect(restored.name, equals('Inception'));
      expect(restored.containerExtension, equals('mp4'));
      expect(restored.directSource, isNull);
    });
  });

  group('Fase 1.4: Continuar Assistindo e Próximo Episódio', () {
    test('1. Próximo episódio promovido com posição 00:00 tem canResume == true', () {
      final nextEpItem = ContinueWatchingItem(
        streamId: 9901,
        seriesId: 105,
        type: ContinueWatchingType.series,
        title: 'Breaking Bad',
        subtitle: 'T1:E2 • Episódio 2',
        position: Duration.zero,
        duration: const Duration(minutes: 48),
        updatedAt: DateTime.now(),
        episodeNum: 2,
        seasonNumber: 1,
      );

      expect(nextEpItem.canResume, isTrue);
      expect(nextEpItem.isCompleted, isFalse);
    });

    test('2. Filme com menos de 10s não pode ser retomado', () {
      final movieItem = ContinueWatchingItem(
        streamId: 501,
        type: ContinueWatchingType.movie,
        title: 'Gladiador',
        position: const Duration(seconds: 5),
        duration: const Duration(hours: 2),
        updatedAt: DateTime.now(),
      );

      expect(movieItem.canResume, isFalse);
    });

    test('3. Proteção contra gravação antiga concorrente em saveContinueWatchingItem', () async {
      SharedPreferences.setMockInitialValues({});
      final service = PlaybackProgressService();
      const accountKey = 'test_acc';

      final newerTime = DateTime.now();
      final olderTime = newerTime.subtract(const Duration(minutes: 5));

      final newerItem = ContinueWatchingItem(
        streamId: 101,
        type: ContinueWatchingType.movie,
        title: 'Interestelar',
        position: const Duration(minutes: 30),
        duration: const Duration(hours: 2),
        updatedAt: newerTime,
      );

      await service.saveContinueWatchingItem(accountKey: accountKey, item: newerItem);

      // Tenta gravar versão antiga com updatedAt anterior
      final olderItem = ContinueWatchingItem(
        streamId: 101,
        type: ContinueWatchingType.movie,
        title: 'Interestelar',
        position: const Duration(minutes: 10),
        duration: const Duration(hours: 2),
        updatedAt: olderTime,
      );

      await service.saveContinueWatchingItem(accountKey: accountKey, item: olderItem);

      final list = await service.getContinueWatchingList(accountKey: accountKey);
      expect(list.length, equals(1));
      expect(list.first.position, equals(const Duration(minutes: 30)));
    });
  });

  group('Fase 1.5: Navegação D-Pad em VodPlayerView', () {
    testWidgets('1. Com controles visíveis, setas D-Pad navegam foco entre botões', (tester) async {
      int seekDelta = 0;
      bool playPauseToggled = false;
      bool nextEpCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Filme Teste',
              onTogglePlayPause: () => playPauseToggled = true,
              onSeekRelative: (sec) => seekDelta = sec,
              onNextEpisode: () => nextEpCalled = true,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Pressiona ArrowRight para mover de Play/Pause para Avançar 10s
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      // Pressiona Select no botão Avançar 10s
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(seekDelta, equals(10));

      // Pressiona ArrowRight novamente para mover para Próximo Episódio
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      // Pressiona Select no Próximo Episódio
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(nextEpCalled, isTrue);

      // Pressiona ArrowLeft para voltar ao Avançar 10s, depois ao Play/Pause
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      // Pressiona Select no Play/Pause
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(playPauseToggled, isTrue);
    });

    testWidgets('2. No overlay de erro, D-Pad navega entre Tentar Novamente e Voltar', (tester) async {
      bool retried = false;
      bool backed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Filme com Erro',
              errorMessage: 'Falha 404',
              onTogglePlayPause: () {},
              onRetry: () => retried = true,
              onBack: () => backed = true,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tentar novamente está focado por padrão; Select ativa retry
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(retried, isTrue);

      // Pressiona ArrowRight para focar botão Voltar
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      // Pressiona Select ativa voltar
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(backed, isTrue);
    });

    testWidgets('3. No overlay de próximo episódio, D-Pad navega entre Cancelar e Assistir Agora', (tester) async {
      bool canceled = false;
      bool playedNow = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Episódio Concluído',
              nextEpisodeCountdown: 5,
              nextEpisodeTitle: 'T1:E2',
              onTogglePlayPause: () {},
              onCancelNextEpisode: () => canceled = true,
              onPlayNextEpisodeNow: () => playedNow = true,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Assistir Agora está focado por padrão; Select ativa
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(playedNow, isTrue);

      // ArrowLeft move para Cancelar
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(canceled, isTrue);
    });
  });
}
