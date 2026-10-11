import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:projeto_tv/models/epg_program.dart';
import 'package:projeto_tv/services/epg_service.dart';
import 'package:projeto_tv/services/player_stability_manager.dart';
import 'package:projeto_tv/services/xmltv_parser.dart';
import 'package:projeto_tv/widgets/epg_guide_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XMLTV Parser Unit Tests', () {
    test('Faz parse de canais e programas com fuso horário UTC e offsets (+0000, -0300)', () async {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="globo.br">
    <display-name>TV Globo HD</display-name>
    <display-name>Globo</display-name>
  </channel>
  <channel id="sportv.br">
    <display-name>SporTV</display-name>
  </channel>

  <programme start="20261011120000 +0000" stop="20261011130000 +0000" channel="globo.br">
    <title lang="pt">Jornal Hoje &amp; Notícias</title>
    <desc lang="pt">Edição especial com as principais manchetes &lt;ao vivo&gt;.</desc>
  </programme>

  <programme start="20261011090000 -0300" stop="20261011103000 -0300" channel="sportv.br">
    <title>Tá na Área</title>
    <desc>Debate esportivo matinal.</desc>
  </programme>
</tv>''';

      final result = await XmltvParser.parse(xml);

      expect(result.channelNames['globo.br'], contains('TV Globo HD'));
      expect(result.channelNames['globo.br'], contains('Globo'));
      expect(result.channelNames['sportv.br'], contains('SporTV'));

      final globoProgs = result.programsByChannel['globo.br']!;
      expect(globoProgs.length, equals(1));
      expect(globoProgs.first.title, equals('Jornal Hoje & Notícias'));
      expect(globoProgs.first.description, equals('Edição especial com as principais manchetes <ao vivo>.'));
      expect(globoProgs.first.startTime, equals(DateTime.utc(2026, 10, 11, 12, 0, 0)));
      expect(globoProgs.first.endTime, equals(DateTime.utc(2026, 10, 11, 13, 0, 0)));

      final sportvProgs = result.programsByChannel['sportv.br']!;
      expect(sportvProgs.length, equals(1));
      expect(sportvProgs.first.title, equals('Tá na Área'));
      // 09:00 -0300 = 12:00 UTC
      expect(sportvProgs.first.startTime, equals(DateTime.utc(2026, 10, 11, 12, 0, 0)));
      // 10:30 -0300 = 13:30 UTC
      expect(sportvProgs.first.endTime, equals(DateTime.utc(2026, 10, 11, 13, 30, 0)));
    });

    test('Progresso do programa varia entre 0.0 e 1.0 e formata horário localmente', () {
      final now = DateTime.now();
      final prog = EpgProgram(
        channelId: 'ch1',
        title: 'Programa em Exibição',
        startTime: now.subtract(const Duration(minutes: 30)),
        endTime: now.add(const Duration(minutes: 30)),
      );

      expect(prog.isAiringAt(now), isTrue);
      final progress = prog.getProgress(now);
      expect(progress, closeTo(0.5, 0.05));
      expect(prog.formattedTimeRange, isNotEmpty);
    });

    test('Programa fora da faixa retorna isAiringAt false e progresso clampado', () {
      final now = DateTime.now();
      final pastProg = EpgProgram(
        channelId: 'ch1',
        title: 'Programa Passado',
        startTime: now.subtract(const Duration(hours: 3)),
        endTime: now.subtract(const Duration(hours: 2)),
      );

      expect(pastProg.isAiringAt(now), isFalse);
      expect(pastProg.getProgress(now), equals(1.0));

      final futureProg = EpgProgram(
        channelId: 'ch1',
        title: 'Programa Futuro',
        startTime: now.add(const Duration(hours: 1)),
        endTime: now.add(const Duration(hours: 2)),
      );

      expect(futureProg.isAiringAt(now), isFalse);
      expect(futureProg.getProgress(now), equals(0.0));
    });
  });

  group('EpgService Integration Tests', () {
    test('Associa canal M3U por tvgId, tvgName e nome do canal sem dados fictícios', () async {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="globo.sp">
    <display-name>Globo SP HD</display-name>
  </channel>
  <programme start="20261011120000 +0000" stop="20261011130000 +0000" channel="globo.sp">
    <title>SP TV 1ª Edição</title>
  </programme>
</tv>''';

      final mockClient = MockClient((request) async {
        return http.Response(xml, 200, headers: {'content-type': 'application/xml'});
      });

      final tempDir = await Directory.systemTemp.createTemp('epg_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      final service = EpgService.forTesting(client: mockClient, diskCacheDir: tempDir);
      await service.loadXmltvFromUrl('http://mock.epg/xmltv.xml');

      // 1. Busca por tvg-id exato
      final byId = service.findScheduleForM3uChannel(tvgId: 'globo.sp');
      expect(byId, isNotNull);
      expect(byId!.programs.first.title, equals('SP TV 1ª Edição'));

      // 2. Busca por nome do canal mapeado
      final byName = service.findScheduleForM3uChannel(channelName: 'Globo SP HD');
      expect(byName, isNotNull);
      expect(byName!.programs.first.title, equals('SP TV 1ª Edição'));

      // 3. Canal sem EPG retorna null (sem inventar programação)
      final notFound = service.findScheduleForM3uChannel(
        tvgId: 'desconhecido.123',
        channelName: 'Canal Misterioso',
      );
      expect(notFound, isNull);
    });

    test('Trata falha de rede ou XML inválido sem lançar exceções', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final tempDir = await Directory.systemTemp.createTemp('epg_err_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      final service = EpgService.forTesting(client: mockClient, diskCacheDir: tempDir);
      // Não deve lançar exceção
      await service.loadXmltvFromUrl('http://mock.epg/error.xml');

      final result = service.findScheduleForM3uChannel(tvgId: 'qualquer');
      expect(result, isNull);
    });
  });

  group('PlayerStabilityManager Tests', () {
    test('Watchdog de timeout de abertura dispara callback após tempo limite', () async {
      bool timedOut = false;
      final manager = PlayerStabilityManager(
        openTimeout: const Duration(milliseconds: 50),
      );

      manager.startOpenWatchdog(() {
        timedOut = true;
      });

      expect(timedOut, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(timedOut, isTrue);

      manager.dispose();
    });

    test('clearOpenWatchdog cancela o timeout quando conexão é estabelecida antes do limite', () async {
      bool timedOut = false;
      final manager = PlayerStabilityManager(
        openTimeout: const Duration(milliseconds: 80),
      );

      manager.startOpenWatchdog(() {
        timedOut = true;
      });

      // Stream abriu com sucesso aos 20ms
      await Future<void>.delayed(const Duration(milliseconds: 20));
      manager.clearOpenWatchdog();

      // Aguarda até passar dos 80ms
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(timedOut, isFalse);

      manager.dispose();
    });

    test('Reconexão progressiva limita tentativas ao maxRetries (máximo 3)', () async {
      bool failedState = false;
      String? errorMessage;

      final manager = PlayerStabilityManager(
        maxRetries: 3,
        onError: (msg) {
          errorMessage = msg;
        },
        onStateChanged: (state) {
          if (state == PlayerRecoveryState.failed) {
            failedState = true;
          }
        },
      );

      expect(manager.retryCount, equals(0));

      // 1ª tentativa
      manager.scheduleRetry('Erro 1');
      expect(manager.retryCount, equals(1));

      // 2ª tentativa
      manager.scheduleRetry('Erro 2');
      expect(manager.retryCount, equals(2));

      // 3ª tentativa
      manager.scheduleRetry('Erro 3');
      expect(manager.retryCount, equals(3));
      expect(failedState, isFalse);

      // 4ª tentativa - excede limite
      manager.scheduleRetry('Erro 4');
      expect(manager.retryCount, equals(3));
      expect(failedState, isTrue);
      expect(errorMessage, contains('após 3 tentativas'));

      manager.dispose();
    });

    test('dispose cancela todos os timers pendentes e descarta manager', () async {
      int reconnectCalls = 0;
      final manager = PlayerStabilityManager(
        onReconnectRequest: (count) async => reconnectCalls++,
      );

      manager.scheduleRetry('Teste dispose');
      expect(manager.isDisposed, isFalse);

      manager.dispose();
      expect(manager.isDisposed, isTrue);

      // Aguarda qualquer timer pendente
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(reconnectCalls, equals(0));
    });

    test('categorizeError sanitiza mensagens e oculta credenciais ou tokens', () {
      final safe1 = PlayerStabilityManager.categorizeError('SocketException: failed to connect to http://user:pass123@server.tv:8080/live.m3u8');
      expect(safe1, isNot(contains('pass123')));
      expect(safe1, contains('Falha de conexão com a rede'));

      final safe2 = PlayerStabilityManager.categorizeError('HttpException 404: stream http://secret:token@stream.tv/404.ts not found');
      expect(safe2, isNot(contains('token')));
      expect(safe2, contains('Transmissão não encontrada'));
    });

    test('Suprime eventos concorrentes ou duplicados de falha idêntica em menos de 600ms', () {
      int reconnectCalls = 0;
      final manager = PlayerStabilityManager(
        maxRetries: 3,
        onReconnectRequest: (count) async => reconnectCalls++,
      );

      // Primeiro erro
      manager.scheduleRetry('Falha na rede');
      expect(manager.retryCount, equals(1));

      // Erro idêntico disparado imediatamente (< 600ms)
      manager.scheduleRetry('Falha na rede');
      expect(manager.retryCount, equals(1)); // Não deve ter incrementado

      manager.dispose();
    });

    test('pauseMonitoring limpa watchdogs e timers de stall ativos', () {
      final manager = PlayerStabilityManager(
        onReconnectRequest: (count) async {},
      );

      manager.startOpenWatchdog(() {});
      manager.pauseMonitoring();

      // Não deve falhar nem lançar exceção
      expect(manager.isDisposed, isFalse);
      manager.dispose();
    });

    test('attemptSoftRecovery lida com controller nulo de forma segura', () async {
      final manager = PlayerStabilityManager(
        onReconnectRequest: (count) async {},
      );

      final result = await manager.attemptSoftRecovery(null);
      expect(result, isFalse);

      manager.dispose();
    });
  });

  group('XMLTV Edge-Cases & Timezone Offsets', () {
    test('Faz parse de offsets com dois-pontos (-03:00, +02:00), época UNIX e ISO-8601', () {
      // 1. Offset de Brasília com formato ISO/XMLTV com dois-pontos (-03:00)
      final dtColon = XmltvParser.parseXmltvDate('20261011153000 -03:00');
      expect(dtColon, isNotNull);
      // 15:30 -03:00 = 18:30 UTC
      expect(dtColon, equals(DateTime.utc(2026, 10, 11, 18, 30, 0)));

      // 2. Offset positivo com dois-pontos (+02:00)
      final dtPos = XmltvParser.parseXmltvDate('20261011153000 +02:00');
      expect(dtPos, isNotNull);
      // 15:30 +02:00 = 13:30 UTC
      expect(dtPos, equals(DateTime.utc(2026, 10, 11, 13, 30, 0)));

      // 3. Timestamp UNIX em segundos
      // 1791720000 = 2026-10-11 12:00:00 UTC
      final dtUnix = XmltvParser.parseXmltvDate('1791720000');
      expect(dtUnix, isNotNull);
      expect(dtUnix, equals(DateTime.fromMillisecondsSinceEpoch(1791720000 * 1000, isUtc: true)));

      // 4. ISO-8601 completo
      final dtIso = XmltvParser.parseXmltvDate('2026-10-11T12:00:00Z');
      expect(dtIso, isNotNull);
      expect(dtIso, equals(DateTime.utc(2026, 10, 11, 12, 0, 0)));
    });

    test('Transição cronológica entre programa anterior, atual e próximo', () {
      final refTime = DateTime.utc(2026, 10, 11, 14, 30, 0);

      final p1 = EpgProgram(
        channelId: 'ch1',
        title: 'Jornal da Manhã',
        startTime: DateTime.utc(2026, 10, 11, 12, 0, 0),
        endTime: DateTime.utc(2026, 10, 11, 14, 0, 0),
      );

      final p2 = EpgProgram(
        channelId: 'ch1',
        title: 'Filme da Tarde',
        startTime: DateTime.utc(2026, 10, 11, 14, 0, 0),
        endTime: DateTime.utc(2026, 10, 11, 16, 0, 0),
      );

      final p3 = EpgProgram(
        channelId: 'ch1',
        title: 'Novela da Noite',
        startTime: DateTime.utc(2026, 10, 11, 16, 0, 0),
        endTime: DateTime.utc(2026, 10, 11, 17, 30, 0),
      );

      final schedule = EpgChannelSchedule(
        channelId: 'ch1',
        programs: [p3, p1, p2], // Desordenado propositalmente
      );

      // Confirma ordenação cronológica automática
      expect(schedule.programs[0].title, equals('Jornal da Manhã'));
      expect(schedule.programs[1].title, equals('Filme da Tarde'));
      expect(schedule.programs[2].title, equals('Novela da Noite'));

      // Verifica programa em exibição no instante refTime (14:30 UTC)
      final current = schedule.findCurrentProgram(refTime);
      expect(current, isNotNull);
      expect(current!.title, equals('Filme da Tarde'));
      expect(current.isAiringAt(refTime), isTrue);

      // Verifica próximo programa
      final next = schedule.findNextProgram(refTime);
      expect(next, isNotNull);
      expect(next!.title, equals('Novela da Noite'));

      // Programa anterior já encerrou
      expect(p1.isAiringAt(refTime), isFalse);
    });
  });

  group('EpgGuideDialog UI Tests', () {
    testWidgets('Exibe estado informativo honesto quando não há programação (sem dados falsos)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EpgGuideDialog(
              channelName: 'Canal Sem EPG',
              schedule: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Canal Sem EPG'), findsOneWidget);
      expect(find.text('Guia de Programação (EPG)'), findsOneWidget);
      expect(find.text('Programação indisponível para este canal.'), findsOneWidget);
      expect(find.textContaining('Nenhum dado de guia (EPG) foi fornecido pelo servidor'), findsOneWidget);
      // Não exibe horários falsos ou badges fictícios
      expect(find.text('NO AR'), findsNothing);
    });

    testWidgets('Destaque visual do programa NO AR com badge vermelho e barra de progresso', (tester) async {
      final now = DateTime.now();

      final schedule = EpgChannelSchedule(
        channelId: 'test_ch',
        programs: [
          EpgProgram(
            channelId: 'test_ch',
            title: 'Programa Anterior',
            startTime: now.subtract(const Duration(hours: 2)),
            endTime: now.subtract(const Duration(minutes: 10)),
          ),
          EpgProgram(
            channelId: 'test_ch',
            title: 'Programa ao Vivo Atual',
            startTime: now.subtract(const Duration(minutes: 10)),
            endTime: now.add(const Duration(minutes: 50)),
          ),
          EpgProgram(
            channelId: 'test_ch',
            title: 'Próximo Programa',
            startTime: now.add(const Duration(minutes: 50)),
            endTime: now.add(const Duration(hours: 2)),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpgGuideDialog(
              channelName: 'Canal Brasil',
              schedule: schedule,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Confirma que os 3 programas estão listados
      expect(find.text('Programa Anterior'), findsOneWidget);
      expect(find.text('Programa ao Vivo Atual'), findsOneWidget);
      expect(find.text('Próximo Programa'), findsOneWidget);

      // Exatamente 1 badge "NO AR" para o programa que está passando agora
      expect(find.text('NO AR'), findsOneWidget);

      // Indicador de progresso presente para o programa atual
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });
}
