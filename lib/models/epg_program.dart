import '../services/xmltv_parser.dart';
import 'xtream_catalog.dart';

/// Representa um programa individual da grade do Guia Eletrônico de Programação (EPG).
class EpgProgram {
  final String channelId;
  final String title;
  final String? description;
  final DateTime? startTime;
  final DateTime? endTime;
  final bool? forcedNowPlaying;

  const EpgProgram({
    required this.channelId,
    required this.title,
    this.description,
    this.startTime,
    this.endTime,
    this.forcedNowPlaying,
  });

  /// Verifica se o programa está no ar no momento indicado (padrão DateTime.now()).
  /// Realiza comparação estrita em UTC para eliminar inconsistências entre fusos horários.
  bool isAiringAt([DateTime? now]) {
    if (forcedNowPlaying == true) return true;
    if (startTime == null) return false;
    final currentUtc = (now ?? DateTime.now()).toUtc();
    final sUtc = startTime!.toUtc();
    if (endTime != null) {
      final eUtc = endTime!.toUtc();
      return (currentUtc.isAfter(sUtc) || currentUtc.isAtSameMomentAs(sUtc)) && currentUtc.isBefore(eUtc);
    }
    // Se não tem término declarado, considera ativo se iniciado há menos de 4 horas
    return (currentUtc.isAfter(sUtc) || currentUtc.isAtSameMomentAs(sUtc)) &&
        currentUtc.difference(sUtc) < const Duration(hours: 4);
  }

  /// Retorna o progresso de 0.0 a 1.0 do programa no ar, ou null se horários não disponíveis.
  double? getProgress([DateTime? now]) {
    if (startTime == null || endTime == null) return null;
    final currentUtc = (now ?? DateTime.now()).toUtc();
    final sUtc = startTime!.toUtc();
    final eUtc = endTime!.toUtc();
    if (currentUtc.isBefore(sUtc)) return 0.0;
    if (currentUtc.isAfter(eUtc)) return 1.0;
    final total = eUtc.difference(sUtc).inMilliseconds;
    if (total <= 0) return 0.0;
    final elapsed = currentUtc.difference(sUtc).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  /// Formatação limpa de horário de início e fim no formato HH:mm - HH:mm,
  /// convertida com precisão para o fuso horário local do dispositivo (ex.: Horário de Brasília).
  String get formattedTimeRange {
    if (startTime == null) return '';
    final startStr = _formatTime(startTime!);
    if (endTime == null) return startStr;
    final endStr = _formatTime(endTime!);
    return '$startStr - $endStr';
  }

  static String _formatTime(DateTime dt) {
    // Converte para o fuso local do dispositivo
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Constrói a partir de um programa retornado pela API Xtream Codes,
  /// priorizando timestamps UNIX em UTC sobre strings não qualificadas de fuso.
  factory EpgProgram.fromXtream(XtreamEpgProgram p, {required String channelId}) {
    DateTime? start;
    if (p.startTimestamp != null && p.startTimestamp! > 0) {
      start = DateTime.fromMillisecondsSinceEpoch(p.startTimestamp! * 1000, isUtc: true);
    } else if (p.start != null) {
      start = XmltvParser.parseXmltvDate(p.start);
    }

    DateTime? end;
    if (p.stopTimestamp != null && p.stopTimestamp! > 0) {
      end = DateTime.fromMillisecondsSinceEpoch(p.stopTimestamp! * 1000, isUtc: true);
    } else if (p.end != null) {
      end = XmltvParser.parseXmltvDate(p.end);
    }

    if (start != null && end != null && end.isBefore(start)) {
      end = null;
    }

    return EpgProgram(
      channelId: channelId,
      title: p.title,
      description: p.description,
      startTime: start,
      endTime: end,
      forcedNowPlaying: p.isNowPlaying,
    );
  }

  Map<String, dynamic> toJson() => {
    'channelId': channelId,
    'title': title,
    if (description != null) 'description': description,
    if (startTime != null) 'startTime': startTime!.toUtc().toIso8601String(),
    if (endTime != null) 'endTime': endTime!.toUtc().toIso8601String(),
    if (forcedNowPlaying != null) 'forcedNowPlaying': forcedNowPlaying,
  };

  factory EpgProgram.fromJson(Map<String, dynamic> json) {
    return EpgProgram(
      channelId: json['channelId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString(),
      startTime: json['startTime'] != null ? DateTime.tryParse(json['startTime'] as String)?.toUtc() : null,
      endTime: json['endTime'] != null ? DateTime.tryParse(json['endTime'] as String)?.toUtc() : null,
      forcedNowPlaying: json['forcedNowPlaying'] as bool?,
    );
  }
}

/// Agrupamento de programação de um canal, com ordenação cronológica e derivação consistente de horários.
class EpgChannelSchedule {
  final String channelId;
  final List<EpgProgram> programs;

  EpgChannelSchedule({
    required this.channelId,
    required List<EpgProgram> programs,
  }) : programs = _preparePrograms(programs);

  static List<EpgProgram> _preparePrograms(List<EpgProgram> list) {
    final sorted = List<EpgProgram>.from(list)..sort((a, b) {
      if (a.startTime == null && b.startTime == null) return 0;
      if (a.startTime == null) return 1;
      if (b.startTime == null) return -1;
      return a.startTime!.compareTo(b.startTime!);
    });

    final result = <EpgProgram>[];
    for (int i = 0; i < sorted.length; i++) {
      final cur = sorted[i];
      if (cur.endTime == null && i + 1 < sorted.length && sorted[i + 1].startTime != null) {
        result.add(EpgProgram(
          channelId: cur.channelId,
          title: cur.title,
          description: cur.description,
          startTime: cur.startTime,
          endTime: sorted[i + 1].startTime,
          forcedNowPlaying: cur.forcedNowPlaying,
        ));
      } else {
        result.add(cur);
      }
    }
    return List<EpgProgram>.unmodifiable(result);
  }

  /// Programa atualmente no ar no horário especificado (ou agora se omitido)
  EpgProgram? findCurrentProgram([DateTime? atTime]) {
    final now = atTime ?? DateTime.now();
    for (final p in programs) {
      if (p.isAiringAt(now)) return p;
    }
    for (final p in programs) {
      if (p.forcedNowPlaying == true) return p;
    }
    return null;
  }

  /// Próximo programa a ser transmitido após o horário especificado (ou agora se omitido)
  EpgProgram? findNextProgram([DateTime? atTime]) {
    final now = atTime ?? DateTime.now();
    final current = findCurrentProgram(now);
    if (current != null) {
      final idx = programs.indexOf(current);
      if (idx >= 0 && idx + 1 < programs.length) {
        return programs[idx + 1];
      }
    }

    final nowUtc = now.toUtc();
    for (final p in programs) {
      if (p.startTime != null && p.startTime!.toUtc().isAfter(nowUtc)) {
        return p;
      }
    }
    return null;
  }

  /// Programa atualmente no ar (ou null se nenhum estiver passando no momento)
  EpgProgram? get currentProgram => findCurrentProgram();

  /// Próximo programa a ser transmitido imediatamente após o atual
  EpgProgram? get nextProgram => findNextProgram();
}
