import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel.dart';
import '../models/playlist.dart';
import 'm3u_parser.dart';

/// Serviço responsável por persistir e gerenciar listas M3U localmente.
class PlaylistStorageService {
  static const _playlistsKey = 'saved_m3u_playlists_v1';

  final SharedPreferences? _prefsOverride;
  final Directory? _storageDirOverride;

  PlaylistStorageService({
    SharedPreferences? prefs,
    Directory? storageDir,
  })  : _prefsOverride = prefs,
        _storageDirOverride = storageDir;

  Future<SharedPreferences> _getPrefs() async {
    return _prefsOverride ?? await SharedPreferences.getInstance();
  }

  Future<Directory> _getStorageDir() async {
    if (_storageDirOverride != null) return _storageDirOverride;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/playlists');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      // Fallback para diretório temporário do sistema se getApplicationDocumentsDirectory falhar
      final tempDir = Directory('${Directory.systemTemp.path}/player_tv_playlists');
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }
      return tempDir;
    }
  }

  File _getChannelsFile(Directory dir, String playlistId) {
    return File('${dir.path}/playlist_$playlistId.json');
  }

  /// Retorna todas as listas salvas (metadados).
  Future<List<M3uPlaylist>> getPlaylists() async {
    final prefs = await _getPrefs();
    final jsonList = prefs.getStringList(_playlistsKey) ?? [];

    final playlists = <M3uPlaylist>[];
    for (final jsonStr in jsonList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        playlists.add(M3uPlaylist.fromJson(map));
      } catch (_) {
        // Ignorar itens corrompidos
      }
    }

    // Ordenar pelas mais recentes
    playlists.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
    return playlists;
  }

  /// Salva uma nova lista ou atualiza uma existente junto com seus canais.
  Future<M3uPlaylist> savePlaylist({
    required String name,
    required String url,
    required List<M3uChannel> channels,
    String? existingId,
    String? epgUrl,
  }) async {
    final id = existingId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now();

    final playlist = M3uPlaylist(
      id: id,
      name: name.trim(),
      url: url.trim(),
      channelCount: channels.length,
      lastUpdated: now,
      channels: channels,
      epgUrl: epgUrl,
    );

    // 1. Salvar os canais em arquivo local JSON
    final dir = await _getStorageDir();
    final file = _getChannelsFile(dir, id);
    final channelsJson = jsonEncode(channels.map((c) => c.toJson()).toList());
    await file.writeAsString(channelsJson, flush: true);

    // 2. Salvar os metadados no SharedPreferences
    final prefs = await _getPrefs();
    final existingPlaylists = await getPlaylists();

    final updatedPlaylists = existingPlaylists.where((p) => p.id != id).toList();
    updatedPlaylists.insert(0, playlist);

    final rawList = updatedPlaylists.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_playlistsKey, rawList);

    return playlist;
  }

  /// Carrega os canais de uma lista específica a partir do disco.
  Future<List<M3uChannel>> loadChannels(String playlistId) async {
    final dir = await _getStorageDir();
    final file = _getChannelsFile(dir, playlistId);

    if (!await file.exists()) {
      return [];
    }

    final rawJson = await file.readAsString();
    if (rawJson.trim().isEmpty) return [];

    final list = jsonDecode(rawJson) as List<dynamic>;
    return list
        .map((item) => M3uChannel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Exclui uma lista e o seu arquivo de canais local.
  Future<void> deletePlaylist(String playlistId) async {
    final prefs = await _getPrefs();
    final playlists = await getPlaylists();
    final remaining = playlists.where((p) => p.id != playlistId).toList();

    final rawList = remaining.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_playlistsKey, rawList);

    final dir = await _getStorageDir();
    final file = _getChannelsFile(dir, playlistId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Atualiza a lista baixando novamente o conteúdo M3U a partir da URL.
  Future<M3uPlaylist> refreshPlaylist(M3uPlaylist playlist) async {
    final result = await M3uParser.fetchAndParseWithMetadata(playlist.url);
    return savePlaylist(
      name: playlist.name,
      url: playlist.url,
      channels: result.channels,
      existingId: playlist.id,
      epgUrl: result.epgUrl ?? playlist.epgUrl,
    );
  }
}
