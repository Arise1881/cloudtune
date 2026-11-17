import 'package:flutter/material.dart';

/// Global accent color, configurable from settings.
class ThemeState {
  ThemeState._();

  static final ValueNotifier<Color> accent =
      ValueNotifier(const Color(0xFF1DB954));

  static Color get value => accent.value;

  static void set(Color color) => accent.value = color;
}
