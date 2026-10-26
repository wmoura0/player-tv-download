import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/ota_update_service.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Correção 1 & 2: Persistência de Progresso e Proteção contra Saída Rápida', () {
    test('Protege progresso salvo quando o usuário abre e fecha o player rapidamente (< 10s)', () async {
      final service = PlaybackProgressService();
      const accountKey = 'server1_user1';
      const streamId = 101;

      // 1. Simula progresso existente de 45 minutos (2700s de 7200s)
      final existingItem = ContinueWatchingItem(
        streamId: streamId,
        type: ContinueWatchingType.movie,
        title: 'Interestelar',
        position: const Duration(seconds: 2700),
        duration: const Duration(seconds: 7200),
        updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );

      await service.saveContinueWatchingItem(
        accountKey: accountKey,
        item: existingItem,
      );

      // Verifica se está salvo
      var list = await service.getContinueWatchingList(accountKey: accountKey);
      expect(list.length, equals(1));
      expect(list.first.position.inSeconds, equals(2700));

      // 2. Usuário abre o filme novamente, mas sai durante o carregamento inicial (ex.: 2 segundos de reprodução)
      // O item transitório com 2s tem canResume == false (precisa >= 10s)
      final transientItem = ContinueWatchingItem(
        streamId: streamId,
        type: ContinueWatchingType.movie,
        title: 'Interestelar',
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 7200),
        updatedAt: DateTime.now(),
      );

      // 3. Salva a saída rápida
      await service.saveContinueWatchingItem(
        accountKey: accountKey,
        item: transientItem,
      );

      // 4. Garante que o progresso anterior (2700s) foi PRESERVADO e não apagado
      list = await service.getContinueWatchingList(accountKey: accountKey);
      expect(list.length, equals(1), reason: 'O item não deve ser apagado na saída rápida');
      expect(list.first.position.inSeconds, equals(2700),
          reason: 'O progresso útil anterior deve ser retido');
    });

    test('Atualiza normalmente o progresso quando a reprodução é válida (>= 10s)', () async {
      final service = PlaybackProgressService();
      const accountKey = 'server1_user1';
      const streamId = 102;

      final item1 = ContinueWatchingItem(
        streamId: streamId,
        type: ContinueWatchingType.movie,
        title: 'Gladiador',
        position: const Duration(seconds: 600),
        duration: const Duration(seconds: 7200),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 30)),
      );
      await service.saveContinueWatchingItem(accountKey: accountKey, item: item1);

      // Usuário assistiu até 1800s
      final item2 = ContinueWatchingItem(
        streamId: streamId,
        type: ContinueWatchingType.movie,
        title: 'Gladiador',
        position: const Duration(seconds: 1800),
        duration: const Duration(seconds: 7200),
        updatedAt: DateTime.now(),
      );
      await service.saveContinueWatchingItem(accountKey: accountKey, item: item2);

      final list = await service.getContinueWatchingList(accountKey: accountKey);
      expect(list.length, equals(1));
      expect(list.first.position.inSeconds, equals(1800));
    });

    test('Remove item do Continuar Assistindo ao atingir conclusão (> 95%)', () async {
      final service = PlaybackProgressService();
      const accountKey = 'server1_user1';
      const streamId = 103;

      final item = ContinueWatchingItem(
        streamId: streamId,
        type: ContinueWatchingType.movie,
        title: 'Filme Quase no Fim',
        position: const Duration(seconds: 6900),
        duration: const Duration(seconds: 7000), // > 95%
        updatedAt: DateTime.now(),
      );
      expect(item.isCompleted, isTrue);

      await service.saveContinueWatchingItem(accountKey: accountKey, item: item);

      final list = await service.getContinueWatchingList(accountKey: accountKey);
      expect(list.isEmpty, isTrue, reason: 'Filmes concluídos devem ser removidos do índice');
    });

    test('Preserva progresso por episódio em séries e registra último episódio assistido', () async {
      final service = PlaybackProgressService();
      const accountKey = 'server1_user1';
      const seriesId = 55;
      const episodeId = 1001;

      await service.saveEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        position: const Duration(minutes: 25),
        duration: const Duration(minutes: 50),
      );

      await service.saveLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
        seasonNumber: 1,
        episodeNum: 3,
      );

      final epProg = await service.getEpisodeProgress(
        accountKey: accountKey,
        seriesId: seriesId,
        episodeId: episodeId,
      );
      expect(epProg, isNotNull);
      expect(epProg!.position.inMinutes, equals(25));

      final lastEp = await service.getLastWatchedEpisode(
        accountKey: accountKey,
        seriesId: seriesId,
      );
      expect(lastEp, isNotNull);
      expect(lastEp!['episodeId'], equals(1001));
      expect(lastEp['seasonNumber'], equals(1));
      expect(lastEp['episodeNum'], equals(3));
    });
  });

  group('Correção 3: Diferenciação entre Busca (Seek), Buffering e Pausa Real', () {
    testWidgets('Não exibe badge PAUSADO durante avanço ou recuo de 10s', (tester) async {
      int relativeSeekTriggered = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Teste Seek',
              fitMode: LiveVideoFitMode.contain,
              onTogglePlayPause: () {},
              onSeekRelative: (delta) {
                relativeSeekTriggered = delta;
              },
            ),
          ),
        ),
      );

      // Inicialmente não deve haver 'PAUSADO'
      expect(find.text('PAUSADO'), findsNothing);

      // Toca no botão de avançar 10s
      await tester.tap(find.byIcon(Icons.forward_10_rounded));
      await tester.pump(); // Inicia o estado de relative seek

      expect(relativeSeekTriggered, equals(10));
      // Garante que o indicador de 'PAUSADO' NÃO aparece durante o seek
      expect(find.text('PAUSADO'), findsNothing);

      // Toca no botão de recuar 10s
      await tester.tap(find.byIcon(Icons.replay_10_rounded));
      await tester.pump();

      expect(relativeSeekTriggered, equals(-10));
      expect(find.text('PAUSADO'), findsNothing);
    });

    testWidgets('Não exibe badge PAUSADO quando o player está em buffering', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Teste Buffering',
              fitMode: LiveVideoFitMode.contain,
              isBuffering: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('PAUSADO'), findsNothing);
    });

    testWidgets('Exibe badge PAUSADO quando o usuário aciona pausa explicitamente', (tester) async {
      bool togglePlayPauseCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: null,
              title: 'Teste Pausa Usuário',
              fitMode: LiveVideoFitMode.contain,
              onTogglePlayPause: () {
                togglePlayPauseCalled = true;
              },
            ),
          ),
        ),
      );

      // Antes do toque
      expect(find.text('PAUSADO'), findsNothing);

      // Usuário toca no botão central de Play/Pause
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();

      expect(togglePlayPauseCalled, isTrue);
      // Após o toggle explícito com controller null (isPlaying = false), 'PAUSADO' deve aparecer
      expect(find.text('PAUSADO'), findsOneWidget);
    });
  });

  group('Correção 4: Tratamento Semântico de OTA e Código HTTP 404', () {
    test('HTTP 404 reporta UpdateStatus.channelNotPublished e mensagem informativa', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(
        customUrl: 'https://raw.githubusercontent.com/wmoura0/player-tv-download/main/updates/latest.json',
      );

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isFalse);
      expect(result.isChannelNotPublished, isTrue);
      expect(service.status, equals(UpdateStatus.channelNotPublished));
      expect(result.errorMessage, contains('ainda não publicado ou configurado'));
      expect(result.errorMessage, isNot(contains('atualizado')));
    });

    test('HTTP 401 ou 403 reporta erro de acesso e não finge estar atualizado', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Forbidden', 403);
      });

      final service = OtaUpdateService(client: mockClient);
      final result = await service.checkForUpdates(
        customUrl: 'https://raw.githubusercontent.com/wmoura0/player-tv-download/main/updates/latest.json',
      );

      expect(result.hasUpdate, isFalse);
      expect(result.isUpToDate, isFalse);
      expect(result.isChannelNotPublished, isFalse);
      expect(service.status, equals(UpdateStatus.error));
      expect(result.errorMessage, contains('403'));
    });
  });
}
