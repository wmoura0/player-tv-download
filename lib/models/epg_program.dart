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
  bool isAiringAt([DateTime? now]) {
    if (forcedNowPlaying == true) return true;
    final current = now ?? DateTime.now();
    if (startTime != null && endTime != null) {
      return (current.isAfter(startTime!) || current.isAtSameMomentAs(startTime!)) &&
          current.isBefore(endTime!);
    }
    return false;
  }

  /// Retorna o progresso de 0.0 a 1.0 do programa no ar, ou null se horários não disponíveis.
  double? getProgress([DateTime? now]) {
    if (startTime == null || endTime == null) return null;
    final current = now ?? DateTime.now();
    if (current.isBefore(startTime!)) return 0.0;
    if (current.isAfter(endTime!)) return 1.0;
    final total = endTime!.difference(startTime!).inMilliseconds;
    if (total <= 0) return 0.0;
    final elapsed = current.difference(startTime!).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  /// Formatação limpa de horário de início e fim no formato HH:mm - HH:mm.
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

  /// Constrói a partir de um programa retornado pela API Xtream Codes
  factory EpgProgram.fromXtream(XtreamEpgProgram p, {required String channelId}) {
    DateTime? parseXtreamDate(String? str) {
      if (str == null || str.trim().isEmpty) return null;
      try {
        // Tenta ISO-8601 direto
        return DateTime.tryParse(str) ?? DateTime.tryParse(str.replaceAll(' ', 'T'));
      } catch (_) {
        return null;
      }
    }

    final start = parseXtreamDate(p.start);
    final end = parseXtreamDate(p.end);

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
    if (startTime != null) 'startTime': startTime!.toIso8601String(),
    if (endTime != null) 'endTime': endTime!.toIso8601String(),
    if (forcedNowPlaying != null) 'forcedNowPlaying': forcedNowPlaying,
  };

  factory EpgProgram.fromJson(Map<String, dynamic> json) {
    return EpgProgram(
      channelId: json['channelId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString(),
      startTime: json['startTime'] != null ? DateTime.tryParse(json['startTime'] as String) : null,
      endTime: json['endTime'] != null ? DateTime.tryParse(json['endTime'] as String) : null,
      forcedNowPlaying: json['forcedNowPlaying'] as bool?,
    );
  }
}

/// Agrupamento de programação de um canal
class EpgChannelSchedule {
  final String channelId;
  final List<EpgProgram> programs;

  const EpgChannelSchedule({
    required this.channelId,
    required this.programs,
  });

  /// Programa atualmente no ar (ou null se nenhum estiver passando no momento)
  EpgProgram? get currentProgram {
    final now = DateTime.now();
    for (final p in programs) {
      if (p.isAiringAt(now)) return p;
    }
    // Se não encontrou por data estrita, verifica se algum tem forcedNowPlaying
    for (final p in programs) {
      if (p.forcedNowPlaying == true) return p;
    }
    return null;
  }

  /// Próximo programa a ser transmitido imediatamente após o atual
  EpgProgram? get nextProgram {
    final now = DateTime.now();
    final current = currentProgram;
    if (current != null) {
      final idx = programs.indexOf(current);
      if (idx >= 0 && idx + 1 < programs.length) {
        return programs[idx + 1];
      }
    }

    // Fallback: primeiro programa cujo início seja futuro
    for (final p in programs) {
      if (p.startTime != null && p.startTime!.isAfter(now)) {
        return p;
      }
    }
    return null;
  }

  /// Aliases de conveniência
  EpgProgram? getNowPlaying() => currentProgram;
  EpgProgram? getNextProgram() => nextProgram;
}
