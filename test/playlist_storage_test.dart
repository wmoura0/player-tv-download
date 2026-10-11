import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:projeto_tv/models/channel.dart';
import 'package:projeto_tv/services/playlist_storage.dart';

void main() {
  group('PlaylistStorageService Tests', () {
    late Directory tempDir;
    late PlaylistStorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tempDir = await Directory.systemTemp.createTemp('player_tv_test_');
      storage = PlaylistStorageService(prefs: prefs, storageDir: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Salva lista, carrega metadados e canais do disco com sucesso', () async {
      const channels = [
        M3uChannel(
          name: 'Canal 1',
          streamUrl: 'http://stream.com/1',
          groupTitle: 'Notícias',
          logoUrl: 'http://logo.com/1.png',
        ),
        M3uChannel(
          name: 'Canal 2',
          streamUrl: 'http://stream.com/2',
          groupTitle: 'Filmes',
        ),
      ];

      final saved = await storage.savePlaylist(
        name: 'Minha Lista',
        url: 'http://servidor.com/lista.m3u',
        channels: channels,
      );

      expect(saved.name, equals('Minha Lista'));
      expect(saved.channelCount, equals(2));

      // Verificar listas salvas
      final playlists = await storage.getPlaylists();
      expect(playlists.length, equals(1));
      expect(playlists.first.name, equals('Minha Lista'));
      expect(playlists.first.channelCount, equals(2));

      // Verificar carregamento dos canais persistidos
      final loadedChannels = await storage.loadChannels(saved.id);
      expect(loadedChannels.length, equals(2));
      expect(loadedChannels[0].name, equals('Canal 1'));
      expect(loadedChannels[0].groupTitle, equals('Notícias'));
      expect(loadedChannels[0].logoUrl, equals('http://logo.com/1.png'));
      expect(loadedChannels[1].name, equals('Canal 2'));
    });

    test('Remove lista e seu arquivo de canais', () async {
      final saved = await storage.savePlaylist(
        name: 'Lista para remover',
        url: 'http://exemplo.com/remover.m3u',
        channels: [
          const M3uChannel(name: 'Canal X', streamUrl: 'http://x.com/stream'),
        ],
      );

      var playlists = await storage.getPlaylists();
      expect(playlists.length, equals(1));

      await storage.deletePlaylist(saved.id);

      playlists = await storage.getPlaylists();
      expect(playlists.isEmpty, isTrue);

      final channels = await storage.loadChannels(saved.id);
      expect(channels.isEmpty, isTrue);
    });
  });
}
