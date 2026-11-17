import 'package:flutter/material.dart';

/// Global theme state: accent color + resolved brightness.
class ThemeState {
  ThemeState._();

  static final ValueNotifier<Color> accent =
      ValueNotifier(const Color(0xFF1DB954));

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
