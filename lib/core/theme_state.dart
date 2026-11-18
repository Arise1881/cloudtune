import 'package:flutter/material.dart';

/// Global theme state: accent color + resolved brightness.
class ThemeState {
  ThemeState._();

  /// Varsayılan vurgu rengi. Ayarlar listesindeki ilk renkle aynıdır.
  static const int defaultAccentArgb = 0xFF1DB954;

  static final ValueNotifier<Color> accent =
      ValueNotifier(const Color(defaultAccentArgb));

  /// `ThemeMode.system` cihaz parlaklığından çözümlenir; palet buradan okur.
  static final ValueNotifier<Brightness> brightness =
      ValueNotifier(Brightness.dark);

  static Color get value => accent.value;

  static bool get isDark => brightness.value == Brightness.dark;

  static void set(Color color) => accent.value = color;

  static void applyThemeMode(ThemeMode mode, {Brightness? platform}) {
    final device = platform ??
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final dark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system && device == Brightness.dark);
    final next = dark ? Brightness.dark : Brightness.light;
    if (brightness.value != next) brightness.value = next;
  }
}
