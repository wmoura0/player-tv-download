import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/m3u_parser.dart';

void main() {
  group('M3uParser Tests', () {
    test('Faz parsing de lista M3U padrão com atributos e categorias', () {
      const m3uContent = '''
#EXTM3U
#EXTINF:-1 tvg-id="globo.br" tvg-name="Globo SP" tvg-logo="https://exemplo.com/globo.png" group-title="Abertos", Globo SP HD
http://stream.exemplo.com/globo/index.m3u8
#EXTINF:-1 tvg-id="espn.br" tvg-logo="https://exemplo.com/espn.png" group-title="Esportes", ESPN Brasil
http://stream.exemplo.com/espn/index.m3u8
''';

      final channels = M3uParser.parse(m3uContent);

      expect(channels.length, equals(2));

      // Canal 1
      expect(channels[0].name, equals('Globo SP HD'));
      expect(channels[0].groupTitle, equals('Abertos'));
      expect(channels[0].logoUrl, equals('https://exemplo.com/globo.png'));
      expect(channels[0].streamUrl, equals('http://stream.exemplo.com/globo/index.m3u8'));
      expect(channels[0].tvgId, equals('globo.br'));
      expect(channels[0].tvgName, equals('Globo SP'));

      // Canal 2
      expect(channels[1].name, equals('ESPN Brasil'));
      expect(channels[1].groupTitle, equals('Esportes'));
      expect(channels[1].logoUrl, equals('https://exemplo.com/espn.png'));
      expect(channels[1].streamUrl, equals('http://stream.exemplo.com/espn/index.m3u8'));
    });

    test('Suporta tag #EXTGRP alternativa para categoria', () {
      const m3uContent = '''
#EXTM3U
#EXTINF:-1, Canal de Notícias
#EXTGRP:Notícias 24h
http://stream.exemplo.com/noticias.m3u8
''';

      final channels = M3uParser.parse(m3uContent);
      expect(channels.length, equals(1));
      expect(channels[0].name, equals('Canal de Notícias'));
      expect(channels[0].groupTitle, equals('Notícias 24h'));
    });

    test('Atribui valores padrão quando atributos estiverem ausentes', () {
      const m3uContent = '''
#EXTINF:-1, Canal Sem Atributos
http://stream.exemplo.com/live.m3u8
''';

      final channels = M3uParser.parse(m3uContent);
      expect(channels.length, equals(1));
      expect(channels[0].name, equals('Canal Sem Atributos'));
      expect(channels[0].groupTitle, equals('Outros'));
      expect(channels[0].logoUrl, isNull);
    });

    test('Lança M3uParseException para conteúdo vazio ou inválido', () {
      expect(
        () => M3uParser.parse(''),
        throwsA(isA<M3uParseException>()),
      );

      expect(
        () => M3uParser.parse('Texto qualquer sem formato m3u'),
        throwsA(isA<M3uParseException>()),
      );
    });
  });
}
