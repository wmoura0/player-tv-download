import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/models/xtream_vod_info.dart';
import 'package:projeto_tv/services/playback_progress_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/screens/vod_detail_screen.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('XtreamCatalogService VOD Stream URLs Tests', () {
    test('Gera URLs de filme com extensão padrão mp4 e credenciais codificadas', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user@teste',
        password: 'pass#123',
      );

      const movie = XtreamVodStream(
        streamId: 8812,
        name: 'Interestelar',
        categoryId: '2',
        containerExtension: null,
      );

      final urls = service.buildVodStreamUrls(movie);

      expect(urls.length, greaterThanOrEqualTo(3));
      // 1ª URL: Rota padrão Xtream Codes para filme com extensão default mp4
      expect(urls[0], equals('http://ls-prime.site/movie/user%40teste/pass%23123/8812.mp4'));
      // 2ª URL: Alternativa mkv
      expect(urls[1], equals('http://ls-prime.site/movie/user%40teste/pass%23123/8812.mkv'));
      // 3ª URL: Alternativa legada direta sem /movie/
      expect(urls[2], equals('http://ls-prime.site/user%40teste/pass%23123/8812.mp4'));
    });

    test('Respeita containerExtension quando fornecido pelo catálogo (ex: mkv)', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'usuario',
        password: 'senha',
      );

      const movie = XtreamVodStream(
        streamId: 5432,
        name: 'Oppenheimer',
        categoryId: '2',
        containerExtension: 'mkv',
      );

      final urls = service.buildVodStreamUrls(movie);

      expect(urls.first, equals('http://ls-prime.site/movie/usuario/senha/5432.mkv'));
      expect(urls[1], equals('http://ls-prime.site/movie/usuario/senha/5432.mp4'));
      expect(urls[2], equals('http://ls-prime.site/usuario/senha/5432.mkv'));
    });
  });

  group('PlaybackProgressService Tests', () {
    test('Gera chave de escopo estável por servidor e usuário', () {
      final key1 = PlaybackProgressService.buildAccountKey('http://ls-prime.site:8080', 'usuario1');
      final key2 = PlaybackProgressService.buildAccountKey('http://outro-servidor.net', 'usuario1');
      final key3 = PlaybackProgressService.buildAccountKey('http://ls-prime.site:8080', 'usuario2');

      expect(key1, isNot(equals(key2)));
      expect(key1, isNot(equals(key3)));
      expect(key1, contains('usuario1'));
    });

    test('Formata durações adequadamente em HH:MM:SS e MM:SS', () {
      expect(
        PlaybackProgressService.formatDuration(const Duration(hours: 2, minutes: 15, seconds: 30)),
        equals('02:15:30'),
      );
      expect(
        PlaybackProgressService.formatDuration(const Duration(minutes: 5, seconds: 4)),
        equals('05:04'),
      );
      expect(
        PlaybackProgressService.formatDuration(Duration.zero),
        equals('00:00'),
      );
    });

    test('Salva, recupera e descarta progresso ao concluir filme', () async {
      SharedPreferences.setMockInitialValues({});
      final service = PlaybackProgressService();
      const accountKey = 'server1_user1';
      const streamId = 1001;

      // 1. Posição inicial insignificante (< 10s) não deve ser salva
      await service.saveProgress(
        accountKey: accountKey,
        streamId: streamId,
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 90),
      );
      final p0 = await service.getProgress(accountKey: accountKey, streamId: streamId);
      expect(p0, isNull);

      // 2. Salva posição intermediária (ex: 25 minutos de um filme de 90 min)
      await service.saveProgress(
        accountKey: accountKey,
        streamId: streamId,
        position: const Duration(minutes: 25),
        duration: const Duration(minutes: 90),
      );
      final p1 = await service.getProgress(accountKey: accountKey, streamId: streamId);
      expect(p1, isNotNull);
      expect(p1!.canResume, isTrue);
      expect(p1.position.inMinutes, equals(25));

      // 3. Salva posição nos últimos 30 segundos (concluído) -> deve remover
      await service.saveProgress(
        accountKey: accountKey,
        streamId: streamId,
        position: const Duration(minutes: 89, seconds: 40),
        duration: const Duration(minutes: 90),
      );
      final p2 = await service.getProgress(accountKey: accountKey, streamId: streamId);
      expect(p2, isNull);

      // 4. Salva novamente e testa clearProgress explícito ("Assistir do início")
      await service.saveProgress(
        accountKey: accountKey,
        streamId: streamId,
        position: const Duration(minutes: 40),
        duration: const Duration(minutes: 90),
      );
      await service.clearProgress(accountKey: accountKey, streamId: streamId);
      final p3 = await service.getProgress(accountKey: accountKey, streamId: streamId);
      expect(p3, isNull);
    });
  });

  group('XtreamVodInfo Model Tests', () {
    test('Faz parse seguro de JSON completo com sinopse, duração e avaliação', () {
      final json = {
        'info': {
          'name': 'Duna: Parte 2',
          'plot': 'Paul Atreides se une a Chani e aos Fremen...',
          'genre': 'Ficção Científica',
          'director': 'Denis Villeneuve',
          'cast': 'Timothée Chalamet, Zendaya',
          'releasedate': '2024-03-01',
          'duration': '02:46:00',
          'duration_secs': 9960,
          'rating': '8.6',
          'movie_image': 'http://cdn.exemplo.com/duna2.jpg',
          'backdrop_path': ['http://cdn.exemplo.com/backdrop.jpg'],
        },
        'movie_data': {
          'stream_id': 777,
          'container_extension': 'mp4',
        },
      };

      final info = XtreamVodInfo.fromJson(json);

      expect(info.streamId, equals(777));
      expect(info.name, equals('Duna: Parte 2'));
      expect(info.plot, contains('Paul Atreides'));
      expect(info.genre, equals('Ficção Científica'));
      expect(info.director, equals('Denis Villeneuve'));
      expect(info.duration, equals('02:46:00'));
      expect(info.durationSecs, equals(9960));
      expect(info.cover, equals('http://cdn.exemplo.com/duna2.jpg'));
      expect(info.backdrop, equals('http://cdn.exemplo.com/backdrop.jpg'));
      expect(info.rating, equals('8.6'));
      expect(info.containerExtension, equals('mp4'));
    });

    test('Tolera payload vazio ou ausente sem lançar exceções', () {
      final info = XtreamVodInfo.fromJson({}, fallbackStreamId: 123, fallbackName: 'Filme Fallback');

      expect(info.streamId, equals(123));
      expect(info.name, equals('Filme Fallback'));
      expect(info.plot, isNull);
      expect(info.cover, isNull);
    });
  });

  group('VodDetailScreen Widget Tests', () {
    testWidgets('Exibe capa, título e botão Assistir filme quando não há progresso salvo', (tester) async {
      SharedPreferences.setMockInitialValues({});

      final service = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
      );

      const movie = XtreamVodStream(
        streamId: 900,
        name: 'Matrix',
        categoryId: '1',
        rating: '8.7',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: VodDetailScreen(
            movie: movie,
            catalogService: service,
            accountKey: 'test_account',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Matrix'), findsWidgets);
      expect(find.text('FILME'), findsOneWidget);
      expect(find.text('8.7'), findsOneWidget);
      expect(find.text('Assistir filme'), findsOneWidget);
      expect(find.text('Continuar de onde parou'), findsNothing);
    });

    testWidgets('Exibe Continuar de onde parou e Assistir do início quando há progresso salvo', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final progressService = PlaybackProgressService();
      const accountKey = 'test_account';
      const streamId = 901;

      // Grava 42 minutos e 15 segundos assistidos
      await progressService.saveProgress(
        accountKey: accountKey,
        streamId: streamId,
        position: const Duration(minutes: 42, seconds: 15),
        duration: const Duration(hours: 2),
      );

      final catalogService = XtreamCatalogService(
        serverUrl: 'http://ls-prime.site',
        username: 'user',
        password: 'pass',
      );

      const movie = XtreamVodStream(
        streamId: streamId,
        name: 'Gladiador',
        categoryId: '1',
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

      expect(find.text('Gladiador'), findsWidgets);
      expect(find.textContaining('Continuar de onde parou (42:15)'), findsOneWidget);
      expect(find.text('Assistir do início'), findsOneWidget);
    });
  });

  group('VodPlayerView Widget Tests', () {
    testWidgets('Exibe controles essenciais de VOD: -10s, Play/Pause, +10s, tempo e Original/Preencher', (tester) async {
      LiveVideoFitMode currentMode = LiveVideoFitMode.contain;
      bool playPauseToggled = false;
      int seekRelativeValue = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return VodPlayerView(
                  controller: null,
                  title: 'Vingadores',
                  fitMode: currentMode,
                  onFitModeChanged: (mode) => setState(() => currentMode = mode),
                  onTogglePlayPause: () => playPauseToggled = true,
                  onSeekRelative: (v) => seekRelativeValue = v,
                );
              },
            ),
          ),
        ),
      );

      // Não deve gerar exceção
      expect(tester.takeException(), isNull);
      expect(find.text('Vingadores'), findsWidgets);
      expect(find.text('FILME'), findsOneWidget);

      // Botões de navegação VOD
      expect(find.byIcon(Icons.replay_10_rounded), findsOneWidget);
      expect(find.byIcon(Icons.forward_10_rounded), findsOneWidget);
      expect(find.text('Original'), findsOneWidget);

      // Toca em -10s
      await tester.tap(find.byIcon(Icons.replay_10_rounded));
      expect(seekRelativeValue, equals(-10));

      // Toca em Play/Pause
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      expect(playPauseToggled, isTrue);

      // Alterna proporção para Preencher
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(currentMode, equals(LiveVideoFitMode.cover));
      expect(find.text('Preencher'), findsOneWidget);
    });
  });
}
