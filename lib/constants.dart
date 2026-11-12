import 'package:flutter/material.dart';

/// Rich iPhone-tema paleti: canlı vurgu renkleri, cam-efekt kartlar,
/// koyu gradient arkaplanlar.
class AppColors {
  // Temel koyu tema
  static const background = Color(0xFF0A0A0A);
  static const surface = Color(0xFF121212);
  static const card = Color(0xFF1A1A1A);
  static const cardLight = Color(0xFF222222);
  static const cardHover = Color(0xFF2A2A2A);

  // Vurgu renkleri (iPhone/Safari tarzı canlılık)
  static const accent = Color(0xFF1DB954);   // Spotify yeşil (varsayılan)
  static const accentBright = Color(0xFF1ED760);
  static const accentPink = Color(0xFFFF3B30);
  static const accentBlue = Color(0xFF007AFF);
  static const accentPurple = Color(0xFFBF5AF2);
  static const accentOrange = Color(0xFFFF9500);
  static const accentTeal = Color(0xFF00C2A9);

  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
  static const textTertiary = Color(0xFF808080);
  static const primary = Color(0xFF0A0A0A);
  static const onPrimary = Color(0xFF1DB954);
  static const error = Color(0xFFCF6679);

  static const gradientTop = Color(0xFF1F3D2B);
  static const gradientBottom = Color(0xFF0A0A0A);

  /// Tüm vurgu renkleri (settings seçici için).
  static const List<Color> accentColors = [
    accent,
    accentPink,
    accentBlue,
    accentPurple,
    accentOrange,
    accentTeal,
  ];

  /// Renklerin görünen isimleri.
  static const List<String> accentNames = [
    'Yeşil',
    'Pembe',
    'Mavi',
    'Mor',
    'Turuncu',
    'Sıvı',
  ];
}

class AppStrings {
  static const appName = 'CloudTune';
  static const offlineTitle = 'Çevrimdışı mod';
  static const offlineMessage = 'İnternet erişimi yok. İndirdiğin şarkılar çalmaya hazır.';
  static const searchHint = 'Şarkı, sanatçı veya albüm ara';
  static const emptySearch = 'Ne dinlemek istediğini ara';
  static const noResults = 'Sonuç bulunamadı';
  static const downloadsEmpty = 'Henüz indirilen şarkı yok.\nÇevrimdışı dinlemek için şarkı indir.';
  static const favoritesEmpty = 'Beğendiğin şarkılar burada görünecek';
}

/// Ana sayfa vitrinindeki küratörlü bölümler.
/// Her bölüm bir arama sorgusuna karşılık gelir.
const Map<String, String> curatedSections = {
  'Türkçe Pop Hits': 'türkçe pop',
  'Yabancı Listeler': 'pop hits',
  'Rock Klasikleri': 'classic rock',
  'Lo-Fi & Odak': 'lofi',
  'Rap & Hip-Hop': 'rap hip hop',
  'Elektronik': 'electronic',
  'Akustik': 'acoustic',
  '90\'lar Nostalji': '90s',
};

const String downloadsFolderName = 'cloudtune_downloads';
const String libraryFileName = 'cloudtune_library.json';