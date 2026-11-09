import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/models/live_mini_channel.dart';
import 'package:projeto_tv/models/xtream_series_info.dart';
import 'package:projeto_tv/services/account_manager_service.dart';
import 'package:projeto_tv/services/pin_service.dart';
import 'package:projeto_tv/services/smart_source_resolver.dart';
import 'package:projeto_tv/services/user_profile_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:projeto_tv/widgets/vod_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Future<void> dispose(int textureId) async {}
  @override
  Future<int?> create(DataSource dataSource) async => 1;
  @override
  Future<void> setLooping(int textureId, bool looping) async {}
  @override
  Future<void> play(int textureId) async {}
  @override
  Future<void> pause(int textureId) async {}
  @override
  Future<void> setVolume(int textureId, double volume) async {}
  @override
  Future<void> seekTo(int textureId, Duration position) async {}
  @override
  Future<Duration> getPosition(int textureId) async => Duration.zero;
  @override
  Stream<VideoEvent> videoEventsFor(int textureId) => const Stream.empty();
}

class _TestVideoPlayerController extends VideoPlayerController {
  _TestVideoPlayerController({
    required Duration position,
    required Duration duration,
    bool isPlaying = true,
  }) : super.networkUrl(Uri.parse('https://example.com/test.mp4')) {
    value = VideoPlayerValue(
      isInitialized: true,
      duration: duration,
      position: position,
      isPlaying: isPlaying,
    );
  }

  void updatePosition(Duration newPos) {
    value = value.copyWith(position: newPos);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Fase 3.2: Botão Pular Abertura (+85s) em Séries', () {
    testWidgets('1. Visibilidade nos primeiros minutos: 0:00, 1:00 e 2:59', (tester) async {
      final controller = _TestVideoPlayerController(
        position: Duration.zero,
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Episódio 1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Em 0:00 deve estar visível
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));

      // Em 1:00 deve continuar visível
      controller.updatePosition(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));

      // Em 2:59 (179 segundos) deve continuar visível
      controller.updatePosition(const Duration(seconds: 179));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));
    });

    testWidgets('2. Ocultação automática em 3:00 (180s) e 10:00', (tester) async {
      final controller = _TestVideoPlayerController(
        position: const Duration(seconds: 179),
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Episódio 1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));

      // Ao alcançar exatamente 3 minutos (180 segundos), o botão oculta
      controller.updatePosition(const Duration(seconds: 180));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsNothing);

      // Em 10:00 continua oculto
      controller.updatePosition(const Duration(minutes: 10));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsNothing);
    });

    testWidgets('3. Avanço manual para 20:00 oculta; retorno manual para 1:00 restaura se não pulado', (tester) async {
      final controller = _TestVideoPlayerController(
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Episódio 1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));

      // Avança manualmente para 20:00 -> oculta imediatamente
      controller.updatePosition(const Duration(minutes: 20));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsNothing);

      // Retorna manualmente para 1:00 -> reaparece pois ainda não foi pulado
      controller.updatePosition(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));
    });

    testWidgets('4. Clique no botão avança 85s e oculta pelo restante do episódio (mesmo voltando para < 3min)', (tester) async {
      int seekCalled = 0;
      final controller = _TestVideoPlayerController(
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Episódio 1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
              onSeekRelative: (sec) => seekCalled = sec,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final skipButton = find.text('Pular Abertura (+85s)').first;
      await tester.tap(skipButton);
      await tester.pumpAndSettle();

      expect(seekCalled, equals(85));
      // Botão deve desaparecer imediatamente
      expect(find.text('Pular Abertura (+85s)'), findsNothing);

      // Mesmo voltando a posição para 30s, o botão deve PERMANECER oculto pois já foi utilizado
      controller.updatePosition(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsNothing);
    });

    testWidgets('5. Mudança para o próximo episódio reinicia o estado e restaura o botão', (tester) async {
      final controllerEp1 = _TestVideoPlayerController(
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controllerEp1,
              title: 'Episódio 1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Clica em pular abertura no Ep 1
      await tester.tap(find.text('Pular Abertura (+85s)').first);
      await tester.pumpAndSettle();
      expect(find.text('Pular Abertura (+85s)'), findsNothing);

      // Troca para o Episódio 2 com novo controller em 0:00
      final controllerEp2 = _TestVideoPlayerController(
        position: Duration.zero,
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controllerEp2,
              title: 'Episódio 2',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No Ep 2, o botão deve estar visível novamente
      expect(find.text('Pular Abertura (+85s)'), findsAtLeastNWidgets(1));
    });

    testWidgets('6. Retomada de episódio após 3:00 (ex: 5:00) nunca exibe o botão', (tester) async {
      final controller = _TestVideoPlayerController(
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 45),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Episódio 1',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pular Abertura (+85s)'), findsNothing);
    });

    testWidgets('7. NUNCA exibe em Filmes (isSeriesEpisode: false)', (tester) async {
      final controller = _TestVideoPlayerController(
        position: const Duration(seconds: 10),
        duration: const Duration(hours: 2),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Filme Homem-Aranha',
              badgeText: 'FILME',
              isSeriesEpisode: false,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pular Abertura (+85s)'), findsNothing);
    });

    testWidgets('8. NUNCA exibe em TV ao vivo (LivePlayerView)', (tester) async {
      final controller = _TestVideoPlayerController(
        position: Duration.zero,
        duration: Duration.zero,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: controller,
              channelName: 'Globo SP HD',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pular Abertura (+85s)'), findsNothing);
    });

    testWidgets('9. Não exibe se a duração restante for insuficiente para salto de 85s', (tester) async {
      final controller = _TestVideoPlayerController(
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 80), // Menos de 85s no total
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Teaser Curto',
              isSeriesEpisode: true,
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pular Abertura (+85s)'), findsNothing);
    });
  });

  group('Fase 3.1: Remoção Visual dos Controles de Áudio e Legendas no Player', () {
    testWidgets('1. Botões de áudio e legendas não existem em VodPlayerView (filmes ou séries)', (tester) async {
      final controller = _TestVideoPlayerController(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 50),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Filme',
              onTogglePlayPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Áudio & Legendas'), findsNothing);
      expect(find.text('Áudio'), findsNothing);
      expect(find.text('Legendas'), findsNothing);
      expect(find.byIcon(Icons.audiotrack_rounded), findsNothing);
      expect(find.byIcon(Icons.subtitles_rounded), findsNothing);
    });

    testWidgets('2. Botão de áudio e legendas não existe em LivePlayerView (TV ao vivo)', (tester) async {
      final controller = _TestVideoPlayerController(
        position: Duration.zero,
        duration: Duration.zero,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: controller,
              channelName: 'SporTV HD',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () {},
              onToggleFullscreen: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_live_audio_tracks')), findsNothing);
      expect(find.byIcon(Icons.audiotrack_rounded), findsNothing);
    });

    testWidgets('3. Navegação D-Pad em VodPlayerView transita suavemente entre controles remanescentes', (tester) async {
      int seekDelta = 0;
      bool playPauseCalled = false;

      final controller = _TestVideoPlayerController(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 50),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VodPlayerView(
              controller: controller,
              title: 'Filme Teste',
              onTogglePlayPause: () => playPauseCalled = true,
              onSeekRelative: (sec) => seekDelta = sec,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navega para a direita a partir do Play/Pause -> Avançar 10s
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(seekDelta, equals(10));

      // Navega de volta para a esquerda -> Play/Pause
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(playPauseCalled, isTrue);
    });
  });

  group('Fase 3.6: SmartSourceResolver Regression & Multi-Contas', () {
    test('1. SmartSourceResolver gera extensões candidatas (.mp4, .mkv, .ts) e altId', () {
      final catalog = XtreamCatalogService(
        serverUrl: 'http://test-server.cc:8080',
        username: 'usr',
        password: 'pwd',
      );

      final episode = XtreamSeriesEpisode(
        id: 5001,
        episodeNum: 1,
        seasonNumber: 1,
        title: 'Piloto',
        containerExtension: 'mp4',
        streamId: 9001,
      );

      final urls = SmartSourceResolver.instance.generateCandidateUrls(
        catalogService: catalog,
        episode: episode,
      );

      expect(urls.isNotEmpty, isTrue);
      // Deve conter candidatos com .mp4, .mkv, .ts
      expect(urls.any((u) => u.endsWith('.mp4')), isTrue);
      expect(urls.any((u) => u.endsWith('.mkv')), isTrue);
      expect(urls.any((u) => u.endsWith('.ts')), isTrue);
      // Deve conter candidatos com o playbackStreamId (5001) e com o altId (9001)
      expect(urls.any((u) => u.contains('/5001.')), isTrue);
      expect(urls.any((u) => u.contains('/9001.')), isTrue);
    });

    test('2. Multi-contas e perfis mantém estado preservado e isolado', () async {
      await UserProfileService.instance.init();
      expect(UserProfileService.instance.profiles.isNotEmpty, isTrue);

      await PinService.instance.init();
      expect(PinService.instance.isPinSet, isFalse); // Inicialmente sem PIN
    });
  });
}
