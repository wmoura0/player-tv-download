import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/screens/xtream_catalog_screen.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';
import 'package:projeto_tv/services/epg_service.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fire TV Stability, EPG & Navigation v12 Tests', () {
    late XtreamCatalogService mockService;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({'xtream_password': 'test_password'});
      EpgService.instance.clearMemoryCache();

      final mockClient = MockClient((request) async {
        final action = request.url.queryParameters['action'];
        final catId = request.url.queryParameters['category_id'];
        final streamId = request.url.queryParameters['stream_id'];

        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '10', 'category_name': 'Telecine'},
              {'category_id': '20', 'category_name': 'HBO'},
            ]),
            200,
          );
        }

        if (action == 'get_live_streams') {
          final streams = [
            {
              'num': 1,
              'name': 'Telecine Premium HD',
              'stream_type': 'live',
              'stream_id': 101,
              'stream_icon': 'http://example.com/logo101.png',
              'epg_channel_id': 'tc_premium',
              'added': '',
              'category_id': '10',
              'custom_sid': '',
              'tv_archive': 0,
              'direct_source': '',
              'tv_archive_duration': 0,
            },
            {
              'num': 2,
              'name': 'Telecine Action HD',
              'stream_type': 'live',
              'stream_id': 102,
              'stream_icon': 'http://example.com/logo102.png',
              'epg_channel_id': 'tc_action',
              'added': '',
              'category_id': '10',
              'custom_sid': '',
              'tv_archive': 0,
              'direct_source': '',
              'tv_archive_duration': 0,
            },
            {
              'num': 3,
              'name': 'HBO Max HD',
              'stream_type': 'live',
              'stream_id': 201,
              'stream_icon': 'http://example.com/logo201.png',
              'epg_channel_id': 'hbo_max',
              'added': '',
              'category_id': '20',
              'custom_sid': '',
              'tv_archive': 0,
              'direct_source': '',
              'tv_archive_duration': 0,
            },
          ];

          if (catId == '10') {
            return http.Response(jsonEncode([streams[0], streams[1]]), 200);
          }
          if (catId == '20') {
            return http.Response(jsonEncode([streams[2]]), 200);
          }
          return http.Response(jsonEncode(streams), 200);
        }

        if (action == 'get_short_epg' || action == 'get_simple_data_table') {
          if (streamId == '101') {
            return http.Response(
              jsonEncode({
                'epg_listings': [
                  {
                    'id': '1001',
                    'title': utf8.fuse(base64).encode('O Poderoso Chefão'),
                    'start': '2026-10-13 14:00:00',
                    'end': '2026-10-13 17:00:00',
                    'description': utf8.fuse(base64).encode('Filme clássico'),
                  },
                ],
              }),
              200,
            );
          }
          if (streamId == '102') {
            return http.Response(
              jsonEncode({
                'epg_listings': [
                  {
                    'id': '1002',
                    'title': utf8.fuse(base64).encode('Velozes e Furiosos'),
                    'start': '2026-10-13 15:00:00',
                    'end': '2026-10-13 17:30:00',
                    'description': utf8.fuse(base64).encode('Filme de ação'),
                  },
                ],
              }),
              200,
            );
          }
        }

        return http.Response('[]', 200);
      });

      mockService = XtreamCatalogService(
        serverUrl: 'http://example.com',
        username: 'test_user',
        password: 'test_password',
        client: mockClient,
      );
    });

    Future<void> waitForLoad(WidgetTester tester) async {
      await tester.pump();
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();
    }

    testWidgets('Landscape layout não possui barra horizontal superior nem faixa abaixo do mini player', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: mockService,
          ),
        ),
      );
      await waitForLoad(tester);

      // 1. Barra de navegação superior foi removida
      expect(find.byKey(const Key('catalog_tab_live')), findsNothing);
      expect(find.byKey(const Key('catalog_tab_movies')), findsNothing);
      expect(find.byKey(const Key('catalog_tab_series')), findsNothing);

      // 2. Faixa redundante abaixo do mini-player com botão "Tela Cheia" foi removida
      expect(find.text('Tela Cheia'), findsNothing);

      // 3. Painel EPG ocupa o espaço
      expect(find.textContaining('PROGRAMAÇÃO'), findsOneWidget);
    });

    testWidgets('Botão Voltar preserva a categoria selecionada e não reseta para todas', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: XtreamCatalogScreen(
            type: XtreamCatalogType.live,
            catalogService: mockService,
          ),
        ),
      );
      await waitForLoad(tester);

      // Seleciona a categoria "Telecine" (id 10)
      await tester.tap(find.byKey(const Key('sidebar_cat_10')));
      await waitForLoad(tester);

      expect(find.text('Telecine Premium HD'), findsOneWidget);
      expect(find.text('Telecine Action HD'), findsOneWidget);
      expect(find.text('HBO Max HD'), findsNothing);

      // Filtra com busca
      await tester.enterText(find.byType(TextField).first, 'Action');
      await tester.pumpAndSettle();

      expect(find.text('Telecine Action HD'), findsOneWidget);
      expect(find.text('Telecine Premium HD'), findsNothing);

      // Simula evento de Voltar (Android Back / Remote Back)
      final dynamic popScope = tester.widget(find.byWidgetPredicate((w) => w is PopScope).first);
      popScope.onPopInvokedWithResult(false, null);
      await tester.pumpAndSettle();

      // Busca é limpa e a categoria DEVE continuar preservada ("Telecine", não volta para "all")
      expect(find.text('Telecine Premium HD'), findsOneWidget);
      expect(find.text('Telecine Action HD'), findsOneWidget);
      expect(find.text('HBO Max HD'), findsNothing);
    });

    testWidgets('LivePlayerView em tela cheia permite navegação D-pad entre canal anterior e próximo', (tester) async {
      bool prevClicked = false;
      bool nextClicked = false;
      bool playPauseClicked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LivePlayerView(
              controller: null,
              channelName: 'Telecine Premium HD',
              isFullscreen: true,
              isLoading: false,
              onTogglePlayPause: () => playPauseClicked = true,
              onToggleFullscreen: () {},
              onPreviousChannel: () => prevClicked = true,
              onNextChannel: () => nextClicked = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Encontra botões centrais
      expect(find.byKey(const Key('btn_prev_channel')), findsOneWidget);
      expect(find.byKey(const Key('btn_center_play_pause')), findsOneWidget);
      expect(find.byKey(const Key('btn_next_channel')), findsOneWidget);

      // Clica em canal anterior
      await tester.tap(find.byKey(const Key('btn_prev_channel')));
      await tester.pump();
      expect(prevClicked, isTrue);

      // Clica em próximo canal
      await tester.tap(find.byKey(const Key('btn_next_channel')));
      await tester.pump();
      expect(nextClicked, isTrue);

      // Clica em play/pause
      await tester.tap(find.byKey(const Key('btn_center_play_pause')));
      await tester.pump();
      expect(playPauseClicked, isTrue);
    });
  });
}
