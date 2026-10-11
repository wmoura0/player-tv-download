import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Representação do progresso de reprodução salvo para um filme.
class PlaybackProgress {
  final int streamId;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const PlaybackProgress({
    required this.streamId,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  /// Considera o filme concluído quando faltam menos de 45 segundos ou atingiu mais de 96%
  bool get isCompleted {
    if (duration.inSeconds <= 0) return false;
    final remainingSecs = duration.inSeconds - position.inSeconds;
    return remainingSecs <= 45 || (position.inSeconds / duration.inSeconds) >= 0.96;
  }

  /// Oferece retomar somente se assistiu pelo menos 10 segundos e ainda não concluiu
  bool get canResume {
    return position.inSeconds >= 10 && !isCompleted;
  }
}

/// Tipo de conteúdo no índice de continuar assistindo
enum ContinueWatchingType { movie, series }

/// Item do índice consolidado "Continuar Assistindo" para a tela inicial
class ContinueWatchingItem {
  final int streamId; // streamId do filme ou episodeId da série
  final int? seriesId; // seriesId quando for série
  final ContinueWatchingType type;
  final String title;
  final String? subtitle; // Ex: 'T1:E2'
  final String? coverUrl;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final String? containerExtension;
  final String? categoryId;
  final int? seasonNumber;
  final int? episodeNum;

  const ContinueWatchingItem({
    required this.streamId,
    this.seriesId,
    required this.type,
    required this.title,
    this.subtitle,
    this.coverUrl,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.containerExtension,
    this.categoryId,
    this.seasonNumber,
    this.episodeNum,
  });

  double get progressRatio {
    if (duration.inMilliseconds <= 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool get isCompleted {
    if (duration.inSeconds <= 0) return false;
    final remainingSecs = duration.inSeconds - position.inSeconds;
    return remainingSecs <= 45 || (position.inSeconds / duration.inSeconds) >= 0.96;
  }

  bool get canResume {
    return position.inSeconds >= 10 && !isCompleted;
  }

  Map<String, dynamic> toJson() => {
    'streamId': streamId,
    'seriesId': seriesId,
    'type': type.name,
    'title': title,
    'subtitle': subtitle,
    'coverUrl': coverUrl,
    'pos': position.inMilliseconds,
    'dur': duration.inMilliseconds,
    'time': updatedAt.millisecondsSinceEpoch,
    'containerExtension': containerExtension,
    'categoryId': categoryId,
    'seasonNumber': seasonNumber,
    'episodeNum': episodeNum,
  };

  factory ContinueWatchingItem.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'movie';
    final type = typeStr == 'series' ? ContinueWatchingType.series : ContinueWatchingType.movie;
    final posMs = json['pos'] as int? ?? 0;
    final durMs = json['dur'] as int? ?? 0;
    final timeMs = json['time'] as int? ?? 0;

    return ContinueWatchingItem(
      streamId: json['streamId'] as int? ?? 0,
      seriesId: json['seriesId'] as int?,
      type: type,
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      coverUrl: json['coverUrl'] as String?,
      position: Duration(milliseconds: posMs),
      duration: Duration(milliseconds: durMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      containerExtension: json['containerExtension'] as String?,
      categoryId: json['categoryId']?.toString(),
      seasonNumber: json['seasonNumber'] as int?,
      episodeNum: json['episodeNum'] as int?,
    );
  }
}

/// Serviço responsável por persistir e recuperar o progresso de filmes (VOD)
/// de forma associada à conta/servidor ativo, evitando conflito entre servidores.
class PlaybackProgressService {
  final SharedPreferences? prefs;

  PlaybackProgressService({this.prefs});

  Future<SharedPreferences> _getPrefs() async {
    return prefs ?? await SharedPreferences.getInstance();
  }

  /// Gera a chave de escopo da conta/servidor
  static String buildAccountKey(String serverUrl, String username) {
    final cleanServer = serverUrl.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final cleanUser = username.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return '${cleanServer}_$cleanUser';
  }

  String _buildStorageKey(String accountKey, int streamId) {
    return 'vod_prog_${accountKey}_$streamId';
  }

  /// Salva a posição assistida de um filme.
  /// Se o filme estiver próximo do final, remove a chave para não retomar nos créditos finais.
  Future<void> saveProgress({
    required String accountKey,
    required int streamId,
    required Duration position,
    required Duration duration,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);

    final progress = PlaybackProgress(
      streamId: streamId,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );

    // Se estiver praticamente finalizado, limpa a posição salva
    if (progress.isCompleted) {
      await prefs.remove(key);
      return;
    }

    // Só grava se tiver assistido pelo menos 10 segundos
    if (position.inSeconds >= 10) {
      final data = {
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': progress.updatedAt.millisecondsSinceEpoch,
      };
      await prefs.setString(key, jsonEncode(data));
    }
  }

  /// Recupera o progresso de um filme. Retorna nulo se não houver progresso válido para retomar.
  Future<PlaybackProgress?> getProgress({
    required String accountKey,
    required int streamId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final posMs = data['pos'] as int? ?? 0;
      final durMs = data['dur'] as int? ?? 0;
      final timeMs = data['time'] as int? ?? 0;

      final progress = PlaybackProgress(
        streamId: streamId,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      );

      if (progress.canResume) {
        return progress;
      } else {
        // Se já concluiu ou tem menos de 10s, limpa do storage
        await prefs.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Limpa o progresso salvo de um filme (ex.: ao escolher "Assistir do início")
  Future<void> clearProgress({
    required String accountKey,
    required int streamId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildStorageKey(accountKey, streamId);
    await prefs.remove(key);
  }

  // =========================================================================
  // PROGRESSO DE EPISÓDIOS DE SÉRIES (Isolado por conta, série e episódio)
  // =========================================================================

  String _buildEpisodeStorageKey(String accountKey, int seriesId, int episodeId) {
    return 'series_prog_${accountKey}_${seriesId}_$episodeId';
  }

  String _buildSeriesLastKey(String accountKey, int seriesId) {
    return 'series_last_${accountKey}_$seriesId';
  }

  /// Salva a posição assistida de um episódio de série.
  Future<void> saveEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
    required Duration position,
    required Duration duration,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);

    final progress = PlaybackProgress(
      streamId: episodeId,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );

    // Se estiver praticamente finalizado, limpa a posição salva
    if (progress.isCompleted) {
      await prefs.remove(key);
      return;
    }

    // Só grava se tiver assistido pelo menos 10 segundos
    if (position.inSeconds >= 10) {
      final data = {
        'pos': position.inMilliseconds,
        'dur': duration.inMilliseconds,
        'time': progress.updatedAt.millisecondsSinceEpoch,
      };
      await prefs.setString(key, jsonEncode(data));
    }
  }

  /// Recupera o progresso de um episódio de série. Retorna nulo se não houver progresso válido para retomar.
  Future<PlaybackProgress?> getEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final posMs = data['pos'] as int? ?? 0;
      final durMs = data['dur'] as int? ?? 0;
      final timeMs = data['time'] as int? ?? 0;

      final progress = PlaybackProgress(
        streamId: episodeId,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      );

      if (progress.canResume) {
        return progress;
      } else {
        await prefs.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Limpa o progresso salvo de um episódio de série.
  Future<void> clearEpisodeProgress({
    required String accountKey,
    required int seriesId,
    required int episodeId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildEpisodeStorageKey(accountKey, seriesId, episodeId);
    await prefs.remove(key);
  }

  /// Salva a referência do último episódio assistido em uma série.
  Future<void> saveLastWatchedEpisode({
    required String accountKey,
    required int seriesId,
    required int episodeId,
    required int seasonNumber,
    required int episodeNum,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildSeriesLastKey(accountKey, seriesId);
    final data = {
      'episodeId': episodeId,
      'seasonNumber': seasonNumber,
      'episodeNum': episodeNum,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(key, jsonEncode(data));
  }

  /// Recupera o último episódio assistido em uma série.
  Future<Map<String, int>?> getLastWatchedEpisode({
    required String accountKey,
    required int seriesId,
  }) async {
    final prefs = await _getPrefs();
    final key = _buildSeriesLastKey(accountKey, seriesId);
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      return {
        'episodeId': data['episodeId'] as int? ?? 0,
        'seasonNumber': data['seasonNumber'] as int? ?? 1,
        'episodeNum': data['episodeNum'] as int? ?? 1,
      };
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // ÍNDICE COMPLEMENTAR: CONTINUAR ASSISTINDO (HOME)
  // =========================================================================

  String _buildContinueWatchingKey(String accountKey) {
    return 'continue_watching_$accountKey';
  }

  /// Recupera a lista de conteúdos com progresso útil para continuar assistindo.
  /// Conteúdos concluídos ou inválidos são filtrados automaticamente.
  Future<List<ContinueWatchingItem>> getContinueWatchingList({
    required String accountKey,
  }) async {
    if (accountKey.trim().isEmpty) return [];
    final prefs = await _getPrefs();
    final key = _buildContinueWatchingKey(accountKey);
    final rawList = prefs.getStringList(key) ?? [];

    final result = <ContinueWatchingItem>[];
    for (final raw in rawList) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final item = ContinueWatchingItem.fromJson(map);
        if (item.canResume && item.title.isNotEmpty) {
          result.add(item);
        }
      } catch (_) {}
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// Salva ou atualiza um item no índice de continuar assistindo.
  Future<void> saveContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingItem item,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final key = _buildContinueWatchingKey(accountKey);

    final currentList = await getContinueWatchingList(accountKey: accountKey);
    currentList.removeWhere((i) {
      if (i.type == item.type) {
        if (item.type == ContinueWatchingType.movie) {
          return i.streamId == item.streamId;
        } else {
          return (i.seriesId ?? i.streamId) == (item.seriesId ?? item.streamId);
        }
      }
      return false;
    });

    if (item.canResume) {
      currentList.insert(0, item);
    }

    final capped = currentList.take(10).toList();
    final jsonList = capped.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(key, jsonList);
  }

  /// Remove um item específico do índice de continuar assistindo sem apagar o progresso existente.
  Future<void> removeContinueWatchingItem({
    required String accountKey,
    required ContinueWatchingType type,
    required int id,
  }) async {
    if (accountKey.trim().isEmpty) return;
    final prefs = await _getPrefs();
    final key = _buildContinueWatchingKey(accountKey);
    final currentList = await getContinueWatchingList(accountKey: accountKey);

    currentList.removeWhere((i) {
      if (i.type == type) {
        if (type == ContinueWatchingType.movie) {
          return i.streamId == id;
        } else {
          return (i.seriesId ?? i.streamId) == id;
        }
      }
      return false;
    });

    final jsonList = currentList.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList(key, jsonList);
  }

  /// Formata uma duração em string legível (ex: 01:23:45 ou 05:30)
  static String formatDuration(Duration duration) {
    if (duration.isNegative) return '00:00';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    final mStr = minutes.toString().padLeft(2, '0');
    final sStr = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      final hStr = hours.toString().padLeft(2, '0');
      return '$hStr:$mStr:$sStr';
    }
    return '$mStr:$sStr';
  }
}
