import 'package:flutter_test/flutter_test.dart';
import 'package:projeto_tv/services/settings_service.dart';
import 'package:projeto_tv/widgets/live_player_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SettingsService Unit Tests', () {
    test('Inicializa com valores padrão adequados para Smart TV e mobile', () async {
      final settings = SettingsService.instance;
      await settings.loadSettings();

      expect(settings.accentColor, equals(AccentColorOption.cyan));
      expect(settings.posterDensity, equals(PosterDensity.normal));
      expect(settings.reduceAnimations, isFalse);
      expect(settings.defaultAspectRatio, equals(LiveVideoFitMode.contain));
      expect(settings.enableResumePlayback, isTrue);
      expect(settings.enableAutoPlayNextEpisode, isTrue);
    });

    test('Persiste alterações de cor de destaque e notifica ouvintes', () async {
      final settings = SettingsService.instance;
      await settings.loadSettings();

      int notifyCount = 0;
      settings.addListener(() => notifyCount++);

      await settings.setAccentColor(AccentColorOption.electricBlue);
      expect(settings.accentColor, equals(AccentColorOption.electricBlue));
      expect(notifyCount, greaterThan(0));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pref_accent_color'), equals('electric_blue'));
    });

    test('Persiste densidade de pôsteres, aspect ratio e preferências de reprodução', () async {
      final settings = SettingsService.instance;
      await settings.loadSettings();

      await settings.setPosterDensity(PosterDensity.compact);
      await settings.setDefaultAspectRatio(LiveVideoFitMode.cover);
      await settings.setReduceAnimations(true);
      await settings.setEnableResumePlayback(false);
      await settings.setEnableAutoPlayNextEpisode(false);

      expect(settings.posterDensity, equals(PosterDensity.compact));
      expect(settings.defaultAspectRatio, equals(LiveVideoFitMode.cover));
      expect(settings.reduceAnimations, isTrue);
      expect(settings.enableResumePlayback, isFalse);
      expect(settings.enableAutoPlayNextEpisode, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pref_poster_density'), equals('compact'));
      expect(prefs.getString('pref_default_aspect_ratio'), equals('cover'));
      expect(prefs.getBool('pref_reduce_animations'), isTrue);
      expect(prefs.getBool('pref_enable_resume_playback'), isFalse);
      expect(prefs.getBool('pref_enable_autoplay_next_episode'), isFalse);
    });

    test('Recarrega corretamente preferências existentes no SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'pref_accent_color': 'emerald',
        'pref_poster_density': 'comfortable',
        'pref_reduce_animations': true,
        'pref_default_aspect_ratio': 'cover',
        'pref_enable_resume_playback': false,
        'pref_enable_autoplay_next_episode': true,
      });

      final settings = SettingsService.instance;
      await settings.loadSettings();

      expect(settings.accentColor, equals(AccentColorOption.emerald));
      expect(settings.posterDensity, equals(PosterDensity.comfortable));
      expect(settings.reduceAnimations, isTrue);
      expect(settings.defaultAspectRatio, equals(LiveVideoFitMode.cover));
      expect(settings.enableResumePlayback, isFalse);
      expect(settings.enableAutoPlayNextEpisode, isTrue);
    });
  });
}
