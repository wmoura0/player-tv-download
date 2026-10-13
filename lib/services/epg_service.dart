import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/epg_program.dart';
import 'url_sanitizer.dart';
import 'xmltv_parser.dart';
import 'xtream_catalog_service.dart';

/// Serviço central de gerenciamento, cache e associação de Guia de Programação (EPG).
/// Suporta tanto recursos EPG da API Xtream Codes quanto feeds XMLTV de listas M3U.
class EpgService extends ChangeNotifier {
  static final EpgService instance = EpgService._internal();

  EpgService._internal({http.Client? client, Directory? diskCacheDir})
      : _client = client ?? http.Client(),
        _diskCacheDirOverride = diskCacheDir;

  /// Construtor visível para testes com injeção de dependências
  @visibleForTesting
  factory EpgService.forTesting({http.Client? client, Directory? diskCacheDir}) {
    return EpgService._internal(client: client, diskCacheDir: diskCacheDir);
  }

  final http.Client _client;
  final Directory? _diskCacheDirOverride;

  // Cache em memória de programações por identificador normalizado de canal
  final Map<String, EpgChannelSchedule> _memoryScheduleCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};

  // Mapeamento normalizado de nomes de canais para identificadores do EPG XMLTV
  final Map<String, String> _channelNameToIdMap = {};

  // URLs de XMLTV já baixadas/processadas na sessão
  final Set<String> _processedXmltvUrls = {};

  static const Duration _xtreamEpgTtl = Duration(minutes: 15);
  static const Duration _xmltvDiskTtl = Duration(hours: 12);

  /// Retorna o diretório para armazenamento do cache local do EPG
  Future<Directory?> _getCacheDirectory() async {
    if (_diskCacheDirOverride != null) return _diskCacheDirOverride;
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  static String _normalizeKey(String? key) {
    if (key == null) return '';
    return key
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  }

  /// Limpa todos os caches de EPG em memória
  void clearMemoryCache() {
    _memoryScheduleCache.clear();
    _cacheTimestamps.clear();
    _channelNameToIdMap.clear();
    _processedXmltvUrls.clear();
    notifyListeners();
  }

  /// Retorna a programação em cache de um canal do Xtream Codes se disponível e válida.
  EpgChannelSchedule? getXtreamCachedSchedule(int streamId) {
    final cacheKey = 'xtream_$streamId';
    final now = DateTime.now();
    if (_memoryScheduleCache.containsKey(cacheKey)) {
      final cachedTime = _cacheTimestamps[cacheKey];
      if (cachedTime != null && now.difference(cachedTime) < _xtreamEpgTtl) {
        return _memoryScheduleCache[cacheKey];
      }
    }
    return null;
  }

  /// Carrega a programação EPG de um canal do Xtream Codes usando `get_short_epg`.
  /// Aplica cache em memória com TTL de 15 minutos para evitar chamadas repetidas na API.
  Future<EpgChannelSchedule?> fetchXtreamChannelEpg({
    required int streamId,
    required XtreamCatalogService catalogService,
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'xtream_$streamId';
    final now = DateTime.now();

    if (!forceRefresh && _memoryScheduleCache.containsKey(cacheKey)) {
      final cachedTime = _cacheTimestamps[cacheKey];
      if (cachedTime != null && now.difference(cachedTime) < _xtreamEpgTtl) {
        return _memoryScheduleCache[cacheKey];
      }
    }

    try {
      final rawList = await catalogService.fetchShortEpg(streamId);
      if (rawList.isEmpty) {
        return null;
      }

      final programs = rawList
          .map((item) => EpgProgram.fromXtream(item, channelId: streamId.toString()))
          .toList();

      final schedule = EpgChannelSchedule(
        channelId: streamId.toString(),
        programs: programs,
      );

      _memoryScheduleCache[cacheKey] = schedule;
      _cacheTimestamps[cacheKey] = now;
      notifyListeners();
      return schedule;
    } catch (e) {
      debugPrint('[EPG SERVICE] Falha ao carregar EPG Xtream para stream $streamId: $e');
      return null;
    }
  }

  /// Carrega e processa um arquivo XMLTV a partir de uma URL (fornecida pela lista M3U).
  /// Utiliza cache em disco para evitar re-download desnecessário de arquivos grandes.
  Future<void> loadXmltvFromUrl(String url, {bool forceRefresh = false}) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) return;
    if (!forceRefresh && _processedXmltvUrls.contains(trimmedUrl)) return;

    final sanitized = UrlSanitizer.sanitize(trimmedUrl);
    debugPrint('[EPG SERVICE] Carregando XMLTV de $sanitized');

    String? xmlContent;
    final urlHash = trimmedUrl.codeUnits.fold<int>(0, (prev, elem) => ((prev << 5) - prev + elem) & 0x7FFFFFFF);
    final cacheFileName = 'epg_${urlHash.toRadixString(16)}.xml';

    final cacheDir = await _getCacheDirectory();
    File? cacheFile;
    if (cacheDir != null) {
      cacheFile = File('${cacheDir.path}/$cacheFileName');
      if (!forceRefresh && await cacheFile.exists()) {
        final lastModified = await cacheFile.lastModified();
        if (DateTime.now().difference(lastModified) < _xmltvDiskTtl) {
          try {
            xmlContent = await cacheFile.readAsString();
            debugPrint('[EPG SERVICE] XMLTV lido do cache em disco ($cacheFileName)');
          } catch (_) {
            xmlContent = null;
          }
        }
      }
    }

    // Se não há cache em disco válido, baixa da rede
    if (xmlContent == null) {
      try {
        final uri = Uri.tryParse(trimmedUrl);
        if (uri == null) return;

        final response = await _client.get(
          uri,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlayerTV/1.0',
            'Accept': '*/*',
          },
        ).timeout(const Duration(seconds: 40));

        if (response.statusCode != 200) {
          debugPrint('[EPG SERVICE] Falha no download do XMLTV (${response.statusCode})');
          return;
        }

        try {
          xmlContent = utf8.decode(response.bodyBytes);
        } catch (_) {
          xmlContent = latin1.decode(response.bodyBytes);
        }

        // Grava no cache em disco
        if (cacheFile != null && xmlContent.isNotEmpty) {
          try {
            await cacheFile.writeAsString(xmlContent);
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('[EPG SERVICE] Erro de rede ao buscar XMLTV: $e');
        return;
      }
    }

    if (xmlContent.isEmpty) return;

    // Processa o conteúdo XMLTV de forma assíncrona
    final result = await XmltvParser.parse(xmlContent);

    // Registra mapeamentos de canal -> ID
    for (final entry in result.channelNames.entries) {
      final chId = entry.key;
      final normId = _normalizeKey(chId);
      if (normId.isNotEmpty) {
        _channelNameToIdMap[normId] = chId;
      }
      for (final displayName in entry.value) {
        final normName = _normalizeKey(displayName);
        if (normName.isNotEmpty) {
          _channelNameToIdMap[normName] = chId;
        }
      }
    }

    // Alimenta o cache de programações
    final now = DateTime.now();
    for (final entry in result.programsByChannel.entries) {
      final chId = entry.key;
      final schedule = EpgChannelSchedule(
        channelId: chId,
        programs: entry.value,
      );
      final normKey = _normalizeKey(chId);
      _memoryScheduleCache[normKey] = schedule;
      _cacheTimestamps[normKey] = now;
    }

    _processedXmltvUrls.add(trimmedUrl);
    notifyListeners();
  }

  /// Localiza a programação para um canal M3U buscando por tvg-id, tvg-name ou nome do canal.
  /// Retorna `null` se nenhuma programação estiver associada ao canal (sem dados fictícios).
  EpgChannelSchedule? findScheduleForM3uChannel({
    String? tvgId,
    String? tvgName,
    String? channelName,
  }) {
    // 1. Tenta correspondência exata por tvg-id
    if (tvgId != null && tvgId.trim().isNotEmpty) {
      final norm = _normalizeKey(tvgId);
      if (_memoryScheduleCache.containsKey(norm)) {
        return _memoryScheduleCache[norm];
      }
      if (_channelNameToIdMap.containsKey(norm)) {
        final mappedId = _normalizeKey(_channelNameToIdMap[norm]);
        if (_memoryScheduleCache.containsKey(mappedId)) {
          return _memoryScheduleCache[mappedId];
        }
      }
    }

    // 2. Tenta correspondência por tvg-name
    if (tvgName != null && tvgName.trim().isNotEmpty) {
      final norm = _normalizeKey(tvgName);
      if (_memoryScheduleCache.containsKey(norm)) {
        return _memoryScheduleCache[norm];
      }
      if (_channelNameToIdMap.containsKey(norm)) {
        final mappedId = _normalizeKey(_channelNameToIdMap[norm]);
        if (_memoryScheduleCache.containsKey(mappedId)) {
          return _memoryScheduleCache[mappedId];
        }
      }
    }

    // 3. Tenta correspondência por channelName limpo
    if (channelName != null && channelName.trim().isNotEmpty) {
      final norm = _normalizeKey(channelName);
      if (_memoryScheduleCache.containsKey(norm)) {
        return _memoryScheduleCache[norm];
      }
      if (_channelNameToIdMap.containsKey(norm)) {
        final mappedId = _normalizeKey(_channelNameToIdMap[norm]);
        if (_memoryScheduleCache.containsKey(mappedId)) {
          return _memoryScheduleCache[mappedId];
        }
      }
    }

    return null;
  }

  /// Conveniência para obter a grade de programação por tvgId ou nome do canal
  EpgChannelSchedule? getSchedule({String? channelId, String? channelName}) {
    return findScheduleForM3uChannel(tvgId: channelId, channelName: channelName);
  }

  /// Conveniência para obter programa atual e próximo programa
  ({EpgProgram? now, EpgProgram? next}) getNowAndNext({
    String? channelId,
    String? channelName,
  }) {
    final schedule = getSchedule(channelId: channelId, channelName: channelName);
    if (schedule == null) return (now: null, next: null);
    return (now: schedule.currentProgram, next: schedule.nextProgram);
  }

  /// Conveniência para carregar XMLTV vinculado a uma lista
  Future<void> loadXmltv({
    String? playlistId,
    required String url,
    bool forceRefresh = false,
  }) {
    return loadXmltvFromUrl(url, forceRefresh: forceRefresh);
  }

  /// Retorna o schedule Xtream em cache se ainda válido, ou null
  EpgChannelSchedule? getCachedXtreamSchedule(int streamId) {
    final cacheKey = 'xtream_$streamId';
    final cached = _memoryScheduleCache[cacheKey];
    if (cached == null) return null;
    final cachedTime = _cacheTimestamps[cacheKey];
    if (cachedTime != null && DateTime.now().difference(cachedTime) < _xtreamEpgTtl) {
      return cached;
    }
    return null;
  }
}
