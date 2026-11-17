import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-only preferences: audio quality, equalizer, OLED background,
/// theme, language and SponsorBlock. Nothing is sent to a server.
class SettingsService extends ChangeNotifier {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  SharedPreferences? _prefs;
  bool _ready = false;

  String _audioQuality = 'high';
  bool _equalizerEnabled = false;
  String _equalizerPreset = 'normal';
  bool _oledBlack = false;
  ThemeMode _themeMode = ThemeMode.dark;
  String _languageCode = 'tr';
  bool _sponsorBlockEnabled = false;

  bool get ready => _ready;
  String get audioQuality => _audioQuality;
  bool get equalizerEnabled => _equalizerEnabled;
  String get equalizerPreset => _equalizerPreset;
  bool get oledBlack => _oledBlack;
  ThemeMode get themeMode => _themeMode;
  String get languageCode => _languageCode;
  bool get sponsorBlockEnabled => _sponsorBlockEnabled;

  static const List<String> audioQualities = [
    'low',
    'medium',
    'high',
    'veryhigh',
  ];

  static const List<String> equalizerPresets = [
    'normal',
    'flat',
    'bass',
    'treble',
    'vocal',
  ];

  static const Map<String, String> supportedLanguages = {
    'tr': 'T\u00fcrk\u00e7e',
    'en': 'English',
    'de': 'Deutsch',
    'fr': 'Fran\u00e7ais',
    'es': 'Espa\u00f1ol',
    'it': 'Italiano',
    'pt': 'Portugu\u00eas',
    'ru': '\u0420\u0443\u0441\u0441\u043a\u0438\u0439',
    'zh': '\u4e2d\u6587',
    'ja': '\u65e5\u672c\u8a9e',
    'ko': '\uD55C\uAD6D\uC5B4',
    'ar': '\u0627\u0644\u0639\u0631\u0628\u064a\u0629',
    'hi': '\u0939\u093f\u0928\u094d\u0926\u0940',
    'nl': 'Nederlands',
    'pl': 'Polski',
    'sv': 'Svenska',
    'da': 'Dansk',
    'no': 'Norsk',
    'fi': 'Suomi',
    'cs': '\u010ce\u0161tina',
    'hu': 'Magyar',
    'ro': 'Rom\u00e2n\u0103',
    'el': '\u0395\u03bb\u03bb\u03b7\u03bd\u03b9\u03ba\u03ac',
    'he': '\u05e2\u05d1\u05e8\u05d9\u05ea',
    'th': '\u0e44\u0e17\u0e22',
    'vi': 'Ti\u1ebfng Vi\u1ec7t',
    'id': 'Bahasa Indonesia',
    'ms': 'Bahasa Melayu',
  };

  Future<void> init() async {
    if (_ready) return;
    try {
      _prefs = await SharedPreferences.getInstance();
      final prefs = _prefs!;
      _audioQuality = prefs.getString('ct.audioQuality') ?? 'high';
      _equalizerEnabled = prefs.getBool('ct.equalizer') ?? false;
      _equalizerPreset = prefs.getString('ct.equalizerPreset') ?? 'normal';
      _oledBlack = prefs.getBool('ct.oledBlack') ?? false;
      _sponsorBlockEnabled = prefs.getBool('ct.sponsorBlock') ?? false;
      _themeMode = _decodeThemeMode(prefs.getString('ct.themeMode'));
      _languageCode = prefs.getString('ct.language') ?? 'tr';
    } catch (_) {
      // Unreadable storage: keep defaults and continue normally.
    }
    _ready = true;
    notifyListeners();
  }

  ThemeMode _decodeThemeMode(String? stored) => switch (stored) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  Future<void> _saveString(String key, String value) async {
    try {
      await _prefs?.setString(key, value);
    } catch (_) {}
  }

  Future<void> _saveBool(String key, bool value) async {
    try {
      await _prefs?.setBool(key, value);
    } catch (_) {}
  }

  Future<void> setAudioQuality(String value) async {
    _audioQuality = value;
    notifyListeners();
    await _saveString('ct.audioQuality', value);
  }

  Future<void> setEqualizerEnabled(bool value) async {
    _equalizerEnabled = value;
    notifyListeners();
    await _saveBool('ct.equalizer', value);
  }

  Future<void> setEqualizerPreset(String value) async {
    _equalizerPreset = value;
    notifyListeners();
    await _saveString('ct.equalizerPreset', value);
  }

  Future<void> setOledBlack(bool value) async {
    _oledBlack = value;
    notifyListeners();
    await _saveBool('ct.oledBlack', value);
  }

  Future<void> setThemeMode(ThemeMode value) async {
    _themeMode = value;
    notifyListeners();
    await _saveString('ct.themeMode', value.name);
  }

  Future<void> setLanguage(String code) async {
    if (!supportedLanguages.containsKey(code)) return;
    _languageCode = code;
    notifyListeners();
    await _saveString('ct.language', code);
  }

  Future<void> setSponsorBlockEnabled(bool value) async {
    _sponsorBlockEnabled = value;
    notifyListeners();
    await _saveBool('ct.sponsorBlock', value);
  }
}
