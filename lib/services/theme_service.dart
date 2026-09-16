import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uygulama teması: açık/koyu mod + dinamik vurgu rengi.
class ThemeService extends ChangeNotifier {
  ThemeService._();

  static final ThemeService instance = ThemeService._();
  static const _kMode = 'theme_mode';
  static const _kAccent = 'theme_accent';
  static const _kEmoji = 'theme_emoji';

  ThemeMode _mode = ThemeMode.dark;
  int _accentIndex = 0;
  bool _emojiEnabled = false;
  bool _init = false;

  ThemeMode get mode => _mode;
  bool get isDark => _mode != ThemeMode.light;
  int get accentIndex => _accentIndex;
  bool get emojiEnabled => _emojiEnabled;

  /// Spotify benzeri vurgu paleti (yazılı yüzeylerde kontrast korunur).
  static const List<Color> accentColors = [
    Color(0xFF1DB954), // Yeşil (Spotify)
    Color(0xFF1E88E5), // Mavi
    Color(0xFF9C27B0), // Mor
    Color(0xFFE53935), // Kırmızı
    Color(0xFFFB8C00), // Turuncu
  ];

  static const List<String> accentNames = [
    'Yeşil',
    'Mavi',
    'Mor',
    'Kırmızı',
    'Turuncu',
  ];

  Color get accent => accentColors[_accentIndex];

  Future<void> init() async {
    if (_init) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = ThemeMode.values[_modeIndex(prefs.getInt(_kMode) ?? 1)];
      _accentIndex = (prefs.getInt(_kAccent) ?? 0)
          .clamp(0, accentColors.length - 1);
      _emojiEnabled = prefs.getBool(_kEmoji) ?? false;
      _init = true;
      notifyListeners();
    } catch (e) {
      debugPrint('tema yükleme uyarısı: $e');
    }
  }

  int _modeIndex(int raw) {
    final len = ThemeMode.values.length;
    return raw < 0 || raw >= len ? 1 : raw;
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kMode, mode.index);
    } catch (e) {
      debugPrint('tema kaydetme uyarısı: $e');
    }
  }

  void toggleMode() => setMode(isDark ? ThemeMode.light : ThemeMode.dark);

  Future<void> setAccentIndex(int index) async {
    _accentIndex = index.clamp(0, accentColors.length - 1);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kAccent, _accentIndex);
    } catch (e) {
      debugPrint('vurgu kaydetme uyarısı: $e');
    }
  }

  Future<void> setEmojiEnabled(bool value) async {
    _emojiEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEmoji, value);
    } catch (e) {
      debugPrint('emoji tercihi kaydetme uyarısı: $e');
    }
  }
}