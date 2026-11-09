import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/live_player_view.dart';

/// Cores de destaque suportadas pelo Player TV
enum AccentColorOption {
  cyan(
    id: 'cyan',
    name: 'Ciano (Padrão)',
    color: Color(0xFF00E5FF),
    secondaryColor: Color(0xFF00B0FF),
  ),
  electricBlue(
    id: 'electric_blue',
    name: 'Azul Elétrico',
    color: Color(0xFF2979FF),
    secondaryColor: Color(0xFF1565C0),
  ),
  emerald(
    id: 'emerald',
    name: 'Esmeralda',
    color: Color(0xFF00E676),
    secondaryColor: Color(0xFF00C853),
  ),
  amber(
    id: 'amber',
    name: 'Âmbar',
    color: Color(0xFFFFAB00),
    secondaryColor: Color(0xFFFF8F00),
  );

  final String id;
  final String name;
  final Color color;
  final Color secondaryColor;

  const AccentColorOption({
    required this.id,
    required this.name,
    required this.color,
    required this.secondaryColor,
  });

  static AccentColorOption fromId(String? id) {
    return AccentColorOption.values.firstWhere(
      (opt) => opt.id == id,
      orElse: () => AccentColorOption.cyan,
    );
  }
}

/// Densidade de pôsteres / cards nas telas de catálogo e Home
enum PosterDensity {
  compact(
    id: 'compact',
    name: 'Compacto',
    description: 'Mais itens na tela ao mesmo tempo',
    gridCrossAxisCountPortrait: 4,
    gridCrossAxisCountLandscape: 7,
    cardWidth: 110.0,
    cardHeight: 165.0,
  ),
  normal(
    id: 'normal',
    name: 'Padrão',
    description: 'Equilíbrio ideal entre visual e densidade',
    gridCrossAxisCountPortrait: 3,
    gridCrossAxisCountLandscape: 5,
    cardWidth: 130.0,
    cardHeight: 195.0,
  ),
  comfortable(
    id: 'comfortable',
    name: 'Confortável',
    description: 'Cards maiores com mais detalhes e visibilidade',
    gridCrossAxisCountPortrait: 2,
    gridCrossAxisCountLandscape: 4,
    cardWidth: 155.0,
    cardHeight: 230.0,
  );

  final String id;
  final String name;
  final String description;
  final int gridCrossAxisCountPortrait;
  final int gridCrossAxisCountLandscape;
  final double cardWidth;
  final double cardHeight;

  const PosterDensity({
    required this.id,
    required this.name,
    required this.description,
    required this.gridCrossAxisCountPortrait,
    required this.gridCrossAxisCountLandscape,
    required this.cardWidth,
    required this.cardHeight,
  });

  static PosterDensity fromId(String? id) {
    return PosterDensity.values.firstWhere(
      (d) => d.id == id,
      orElse: () => PosterDensity.normal,
    );
  }
}

/// Serviço de gerenciamento e persistência das configurações do Player TV.
/// Persiste exclusivamente no SharedPreferences local, sem alterar o sistema Android.
class SettingsService extends ChangeNotifier {
  static final SettingsService instance = SettingsService._internal();

  SettingsService._internal();

  static const String _keyAccentColor = 'pref_accent_color';
  static const String _keyPosterDensity = 'pref_poster_density';
  static const String _keyReduceAnimations = 'pref_reduce_animations';
  static const String _keyDefaultAspectRatio = 'pref_default_aspect_ratio';
  static const String _keyEnableResumePlayback = 'pref_enable_resume_playback';
  static const String _keyEnableAutoPlayNextEpisode = 'pref_enable_autoplay_next_episode';
  static const String _keyPreferredAudioLanguage = 'pref_preferred_audio_language';
  static const String _keyEnableSmartSource = 'pref_enable_smart_source';
  static const String _keyPreferredContainerExtension = 'pref_preferred_container_extension';
  static const String _keySmartSourceTimeoutSecs = 'pref_smart_source_timeout_secs';

  AccentColorOption _accentColor = AccentColorOption.cyan;
  PosterDensity _posterDensity = PosterDensity.normal;
  bool _reduceAnimations = false;
  LiveVideoFitMode _defaultAspectRatio = LiveVideoFitMode.contain;
  bool _enableResumePlayback = true;
  bool _enableAutoPlayNextEpisode = true;
  String _preferredAudioLanguage = 'pt';
  bool _enableSmartSource = true;
  String _preferredContainerExtension = 'auto'; // 'auto', 'mp4', 'mkv', 'ts'
  int _smartSourceTimeoutSecs = 4;
  bool _isLoaded = false;

  AccentColorOption get accentColor => _accentColor;
  PosterDensity get posterDensity => _posterDensity;
  bool get reduceAnimations => _reduceAnimations;
  LiveVideoFitMode get defaultAspectRatio => _defaultAspectRatio;
  bool get enableResumePlayback => _enableResumePlayback;
  bool get enableAutoPlayNextEpisode => _enableAutoPlayNextEpisode;
  String get preferredAudioLanguage => _preferredAudioLanguage;
  bool get enableSmartSource => _enableSmartSource;
  String get preferredContainerExtension => _preferredContainerExtension;
  int get smartSourceTimeoutSecs => _smartSourceTimeoutSecs;
  bool get isLoaded => _isLoaded;

  /// Inicializa as configurações lendo do SharedPreferences
  Future<void> loadSettings({SharedPreferences? prefs}) async {
    final sp = prefs ?? await SharedPreferences.getInstance();

    final colorId = sp.getString(_keyAccentColor);
    if (colorId != null) {
      _accentColor = AccentColorOption.fromId(colorId);
    }

    final densityId = sp.getString(_keyPosterDensity);
    if (densityId != null) {
      _posterDensity = PosterDensity.fromId(densityId);
    }

    _reduceAnimations = sp.getBool(_keyReduceAnimations) ?? false;

    final fitId = sp.getString(_keyDefaultAspectRatio);
    if (fitId == 'cover') {
      _defaultAspectRatio = LiveVideoFitMode.cover;
    } else if (fitId == 'fill') {
      _defaultAspectRatio = LiveVideoFitMode.fill;
    } else {
      _defaultAspectRatio = LiveVideoFitMode.contain;
    }

    _enableResumePlayback = sp.getBool(_keyEnableResumePlayback) ?? true;
    _enableAutoPlayNextEpisode = sp.getBool(_keyEnableAutoPlayNextEpisode) ?? true;
    _preferredAudioLanguage = sp.getString(_keyPreferredAudioLanguage) ?? 'pt';
    _enableSmartSource = sp.getBool(_keyEnableSmartSource) ?? true;
    _preferredContainerExtension = sp.getString(_keyPreferredContainerExtension) ?? 'auto';
    _smartSourceTimeoutSecs = sp.getInt(_keySmartSourceTimeoutSecs) ?? 4;

    _isLoaded = true;
    notifyListeners();
  }

  /// Define e persiste a cor de destaque
  Future<void> setAccentColor(AccentColorOption color) async {
    if (_accentColor == color) return;
    _accentColor = color;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_keyAccentColor, color.id);
  }

  /// Define e persiste a densidade de pôsteres
  Future<void> setPosterDensity(PosterDensity density) async {
    if (_posterDensity == density) return;
    _posterDensity = density;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_keyPosterDensity, density.id);
  }

  /// Define e persiste a redução de animações
  Future<void> setReduceAnimations(bool reduce) async {
    if (_reduceAnimations == reduce) return;
    _reduceAnimations = reduce;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyReduceAnimations, reduce);
  }

  /// Define e persiste o modo padrão de aspect ratio do player
  Future<void> setDefaultAspectRatio(LiveVideoFitMode mode) async {
    if (_defaultAspectRatio == mode) return;
    _defaultAspectRatio = mode;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    final String fitValue;
    switch (mode) {
      case LiveVideoFitMode.cover:
        fitValue = 'cover';
        break;
      case LiveVideoFitMode.fill:
        fitValue = 'fill';
        break;
      case LiveVideoFitMode.contain:
        fitValue = 'contain';
        break;
    }
    await sp.setString(_keyDefaultAspectRatio, fitValue);
  }

  /// Define e persiste a retomada automática de reprodução
  Future<void> setEnableResumePlayback(bool enable) async {
    if (_enableResumePlayback == enable) return;
    _enableResumePlayback = enable;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyEnableResumePlayback, enable);
  }

  /// Define e persiste o avanço automático de episódios de séries
  Future<void> setEnableAutoPlayNextEpisode(bool enable) async {
    if (_enableAutoPlayNextEpisode == enable) return;
    _enableAutoPlayNextEpisode = enable;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyEnableAutoPlayNextEpisode, enable);
  }

  /// Define e persiste o idioma de áudio preferencial
  Future<void> setPreferredAudioLanguage(String lang) async {
    if (_preferredAudioLanguage == lang) return;
    _preferredAudioLanguage = lang;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_keyPreferredAudioLanguage, lang);
  }

  /// Define e persiste o Smart Source Resolver
  Future<void> setEnableSmartSource(bool enable) async {
    if (_enableSmartSource == enable) return;
    _enableSmartSource = enable;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyEnableSmartSource, enable);
  }

  /// Define e persiste a extensão de container preferencial
  Future<void> setPreferredContainerExtension(String ext) async {
    if (_preferredContainerExtension == ext) return;
    _preferredContainerExtension = ext;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_keyPreferredContainerExtension, ext);
  }

  /// Define e persiste o timeout do Smart Source
  Future<void> setSmartSourceTimeoutSecs(int secs) async {
    if (_smartSourceTimeoutSecs == secs) return;
    _smartSourceTimeoutSecs = secs;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_keySmartSourceTimeoutSecs, secs);
  }
}
