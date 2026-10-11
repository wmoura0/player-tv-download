import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/services/xtream_auth_service.dart';

void main() {
  group('XtreamAuthService Tests', () {
    test('Normaliza URLs de servidores adequadamente', () {
      expect(
        XtreamAuthService.normalizeServerUrl('ls-prime.site'),
        equals('http://ls-prime.site'),
      );
      expect(
        XtreamAuthService.normalizeServerUrl('http://ls-prime.site:8080/'),
        equals('http://ls-prime.site:8080'),
      );
      expect(
        XtreamAuthService.normalizeServerUrl('https://servidor.com///'),
        equals('https://servidor.com'),
      );
    });

    test('Autentica com sucesso quando API retorna auth: 1', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/player_api.php'));
        expect(request.url.queryParameters['username'], equals('usuario'));
        expect(request.url.queryParameters['password'], equals('senha123'));

        final responseBody = jsonEncode({
          'user_info': {
            'username': 'usuario',
            'auth': 1,
            'status': 'Active',
            'exp_date': 1780000000,
            'max_connections': '2',
            'active_cons': '0',
          },
          'server_info': {
            'url': 'ls-prime.site',
            'port': '80',
          },
        });

        return http.Response(responseBody, 200, headers: {'content-type': 'application/json'});
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'http://ls-prime.site',
        username: 'usuario',
        password: 'senha123',
        client: mockClient,
      );

      expect(result.isSuccess, isTrue);
      expect(result.status, equals(XtreamAuthStatus.success));
      expect(result.account, isNotNull);
      expect(result.account!.username, equals('usuario'));
      expect(result.account!.status, equals('Active'));
      expect(result.account!.maxConnections, equals(2));
    });

    test('Retorna invalidCredentials quando servidor retorna auth: 0', () async {
      final mockClient = MockClient((request) async {
        final responseBody = jsonEncode({
          'user_info': {
            'auth': 0,
            'status': 'Disabled',
            'message': 'Conta desativada ou senha incorreta.',
          },
        });

        return http.Response(responseBody, 200, headers: {'content-type': 'application/json'});
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'http://ls-prime.site',
        username: 'usuario',
        password: 'senha_errada',
        client: mockClient,
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, equals(XtreamAuthStatus.invalidCredentials));
      expect(result.message, contains('Conta desativada'));
      expect(result.message, isNot(contains('senha_errada')));
    });

    test('Retorna endpointNotFound quando servidor responde 404', () async {
      final mockClient = MockClient((request) async {
        return http.Response('404 Not Found', 404);
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'http://ls-prime.site',
        username: 'usuario',
        password: 'secret_password',
        client: mockClient,
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, equals(XtreamAuthStatus.endpointNotFound));
      expect(result.message, contains('404'));
      expect(result.message, isNot(contains('secret_password')));
    });

    test('Retorna incompatibleResponse quando servidor responde HTML em vez de JSON', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '<!DOCTYPE html><html><body>Welcome to nginx!</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });

      final result = await XtreamAuthService.authenticate(
        serverUrl: 'http://ls-prime.site',
        username: 'usuario',
        password: 'minha_senha',
        client: mockClient,
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, equals(XtreamAuthStatus.incompatibleResponse));
      expect(result.message, contains('incompatível'));
      expect(result.message, isNot(contains('minha_senha')));
    });
  });
}
