import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/main.dart';
import 'package:projeto_tv/models/channel.dart';
import 'package:projeto_tv/models/playlist.dart';
import 'package:projeto_tv/screens/global_search_screen.dart';
import 'package:projeto_tv/screens/playlist_channels_screen.dart';
import 'package:projeto_tv/screens/splash_screen.dart';
import 'package:projeto_tv/screens/xtream_login_screen.dart';
import 'package:projeto_tv/services/secure_storage_service.dart';
import 'package:projeto_tv/services/xtream_auth_service.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

class MockSecureStorage extends SecureStorageService {
  String? mockUser;
  String? mockPass;
  String? mockServer;

  MockSecureStorage({this.mockUser, this.mockPass, this.mockServer});

  @override
  Future<String?> getUsername() async => mockUser;
  @override
  Future<String?> getPassword() async => mockPass;
  @override
  Future<String?> getServerUrl() async => mockServer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fase 3.1: Diagnóstico de Rede e TLS (xtream_auth_service)', () {
    test('1. HandshakeException com certificado fora da validade diagnostica data/hora desatualizada', () async {
      final mockClient = MockClient((request) async {
        throw const HandshakeException(
          'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: certificate is not yet valid or has expired, check current time)',
        );
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'https://servidor-teste.com:8443',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
      );

      expect(result.status, equals(XtreamAuthStatus.tlsClockMismatch));
      expect(result.isTlsClockMismatch, isTrue);
      expect(result.isNetworkOrTimeout, isTrue);
      expect(result.isAuthFailure, isFalse);
      expect(result.message, contains('Data/Hora no Fire TV'));
      expect(result.message, contains('Configurações'));
    });

    test('2. Falha comum de SocketException é diagnosticada como falha de rede comum', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('Connection refused');
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'http://servidor-offline.com',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
      );

      expect(result.status, equals(XtreamAuthStatus.networkError));
      expect(result.isTlsClockMismatch, isFalse);
      expect(result.isNetworkOrTimeout, isTrue);
      expect(result.isAuthFailure, isFalse);
    });

    test('3. Resposta de credenciais inválidas é classificada como isAuthFailure', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '{"user_info":{"auth":0,"status":"Disabled","message":"Your account has expired"}}',
          200,
        );
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'http://servidor.com',
        username: 'user1',
        password: 'pwd',
        client: mockClient,
      );

      expect(result.isAuthFailure, isTrue);
      expect(result.isNetworkOrTimeout, isFalse);
    });
  });

  group('Fase 3.2: Inicialização Offline-First (splash_screen)', () {
    testWidgets('1. Timeout ou erro de rede com credenciais salvas abre HomeScreen no modo offline/cache', (tester) async {
      final storage = MockSecureStorage(
        mockUser: 'usuario_valido',
        mockPass: 'senha_valida',
        mockServer: 'http://servidor-offline.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SplashScreen(
            secureStorage: storage,
            animationDuration: const Duration(milliseconds: 100),
            autoNavigate: true,
          ),
        ),
      );

      // Aguarda conclusão da animação e resolução de timeout
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      // Não deve ter ido para a tela de login; deve estar na HomeScreen com o usuário salvo
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(XtreamLoginScreen), findsNothing);
      expect(find.textContaining('usuario_valido'), findsWidgets);

      // Avança o timer de preload em segundo plano da HomeScreen para não deixar timers pendentes
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('2. Credenciais vazias ou sem login direcionam para XtreamLoginScreen', (tester) async {
      final storage = MockSecureStorage(
        mockUser: null,
        mockPass: null,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SplashScreen(
            secureStorage: storage,
            animationDuration: const Duration(milliseconds: 100),
            autoNavigate: true,
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.byType(XtreamLoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });
  });

  group('Fase 3.3: Busca Global Progressiva e M3U (global_search_screen)', () {
    testWidgets('1. Toque em canal M3U abre PlaylistChannelsScreen com o canal selecionado', (tester) async {
      final playlist = M3uPlaylist(
        id: 'p1',
        name: 'Minha Lista M3U',
        url: 'http://lista.m3u',
        channelCount: 1,
        lastUpdated: DateTime.now(),
        channels: [
          M3uChannel(
            name: 'Band TV',
            streamUrl: 'http://band.stream.m3u8',
            groupTitle: 'Abertos',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GlobalSearchScreen(
            accountKey: 'test_key',
            activeM3uPlaylist: playlist,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Digita "Band" na pesquisa
      await tester.enterText(find.byType(TextField), 'Band');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Band TV'), findsOneWidget);

      // Clica no canal M3U resultante
      await tester.tap(find.text('Band TV'));
      await tester.pumpAndSettle();

      // Verifica navegação para PlaylistChannelsScreen
      expect(find.byType(PlaylistChannelsScreen), findsOneWidget);
    });

    test('2. XtreamCatalogService expõe streams em memória para busca sem pico de RAM', () {
      final service = XtreamCatalogService(
        serverUrl: 'http://test.com',
        username: 'usr',
        password: 'pwd',
      );

      expect(service.cachedAllLiveStreams, isNull);
      expect(service.cachedAllVodStreams, isNull);
      expect(service.cachedAllSeries, isNull);
    });
  });
}
