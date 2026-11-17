import 'package:flutter/material.dart';

import 'theme_state.dart';

/// Tema duyarlı renkler.
///
/// Widget'larda sabit `Colors.white54` / `Color(0xFF242424)` kullanımı açık
/// temada siyah yazı + koyu zemin üretiyordu. Tüm yüzeyler ve ikincil metinler
/// bu paletten okunur; koyu/açık ayrımı tek yerden yönetilir.
class AppPalette {
  const AppPalette._();

  static bool get dark => ThemeState.isDark;

  static Color get scaffold =>
      dark ? const Color(0xFF121212) : const Color(0xFFF7F7F7);

  static Color get surface =>
      dark ? const Color(0xFF181818) : const Color(0xFFFFFFFF);

  static Color get card =>
      dark ? const Color(0xFF242424) : const Color(0xFFEFEFEF);

  static Color get cardAlt =>
      dark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF);

  static Color get cardRaised =>
      dark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8);

  static Color get input =>
      dark ? const Color(0xFF242424) : const Color(0xFFECECEC);

  /// Zorunlu beyaz metinler (ör. vurgu rengi üzerindeki ikonlar) dışında
  /// birincil metin rengi.
  static Color get text => dark ? Colors.white : const Color(0xFF181818);

  static Color get textMuted =>
      dark ? const Color(0xB3FFFFFF) : const Color(0xA6181818);

  static Color get textSubtle =>
      dark ? const Color(0x8AFFFFFF) : const Color(0x8A181818);

  static Color get textFaint =>
      dark ? const Color(0x61FFFFFF) : const Color(0x61181818);

  static Color get iconSubtle =>
      dark ? const Color(0x99FFFFFF) : const Color(0x99181818);

  static Color get iconFaint =>
      dark ? const Color(0x3DFFFFFF) : const Color(0x3D181818);

  static Color get divider =>
      dark ? const Color(0x1FFFFFFF) : const Color(0x1A181818);

  static Color get overlay =>
      dark ? const Color(0x1FFFFFFF) : const Color(0x0D181818);

  static Color get dangerSurface =>
      dark ? const Color(0x24F44336) : const Color(0x12F44336);
}
