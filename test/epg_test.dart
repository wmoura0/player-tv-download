import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/xtream_catalog.dart';
import 'package:projeto_tv/services/xtream_catalog_service.dart';

void main() {
  group('Xtream EPG Tests', () {
    test('Decodifica programa EPG com strings em texto puro e base64', () {
      final base64Title = base64.encode(utf8.encode('Jornal Nacional'));
      final base64Desc = base64.encode(utf8.encode('Principais notícias do dia no Brasil e no mundo.'));

      final jsonPlain = {
        'id': '101',
        'title': 'Globo Esporte',
        'description': 'Cobertura esportiva diária.',
        'start': '2026-10-09 13:00:00',
        'end': '2026-10-09 13:30:00',
        'now_playing': 0,
      };

      final jsonB64 = {
        'id': '102',
        'title': base64Title,
        'description': base64Desc,
        'start': '2026-10-09 20:30:00',
        'end': '2026-10-09 21:20:00',
        'now_playing': 1,
      };

      final progPlain = XtreamEpgProgram.fromJson(jsonPlain);
      expect(progPlain.title, equals('Globo Esporte'));
      expect(progPlain.description, equals('Cobertura esportiva diária.'));
      expect(progPlain.isNowPlaying, isFalse);

      final progB64 = XtreamEpgProgram.fromJson(jsonB64);
      expect(progB64.title, equals('Jornal Nacional'));
      expect(progB64.description, equals('Principais notícias do dia no Brasil e no mundo.'));
      expect(progB64.isNowPlaying, isTrue);
    });

    test('fetchShortEpg consulta action=get_short_epg e retorna lista estruturada', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.queryParameters['action'], equals('get_short_epg'));
        expect(request.url.queryParameters['stream_id'], equals('555'));

        final body = jsonEncode({
          'epg_listings': [
            {
              'id': '1',
              'title': 'Filme da Tarde',
              'start': '2026-10-09 15:00:00',
              'end': '2026-10-09 17:00:00',
              'now_playing': 1,
            },
            {
              'id': '2',
              'title': 'Novela das Seis',
              'start': '2026-10-09 17:00:00',
              'end': '2026-10-09 18:00:00',
              'now_playing': 0,
            },
          ]
        });

        return http.Response(body, 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
      );

      final epg = await service.fetchShortEpg(555);
      expect(epg.length, equals(2));
      expect(epg.first.title, equals('Filme da Tarde'));
      expect(epg.first.isNowPlaying, isTrue);
      expect(epg[1].title, equals('Novela das Seis'));
      expect(epg[1].isNowPlaying, isFalse);
    });

    test('fetchShortEpg retorna lista vazia de forma segura quando ausente ou servidor falha sem inventar dados', () async {
      final mockClient = MockClient((request) async {
        // Servidor retorna objeto sem epg_listings ou vazio
        return http.Response('{}', 200);
      });

      final service = XtreamCatalogService(
        serverUrl: 'http://test-server.tv',
        username: 'user',
        password: 'pwd',
        client: mockClient,
      );

      final epg = await service.fetchShortEpg(999);
      expect(epg, isEmpty);
    });
  });
}
