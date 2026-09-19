import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF181818);
  static const card = Color(0xFF242424);
  static const cardLight = Color(0xFF2E2E2E);
  static const accent = Color(0xFF1DB954);
  static const accentBright = Color(0xFF1ED760);
  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
  static const textTertiary = Color(0xFF808080);
  static const primary = Color(0xFF121212);
  static const onPrimary = Color(0xFF1DB954);
  static const error = Color(0xFFCF6679);

  static const gradientTop = Color(0xFF1F3D2B);
}

class AppStrings {
  static const appName = 'CloudTune';
  static const offlineTitle = 'Çevrimdışı mod';
  static const offlineMessage = 'İnternet bağlantısı yok. İndirdiğin şarkılar çalmaya hazır.';
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

const String downloadsFolderName = 'sonora_downloads';
const String libraryFileName = 'sonora_library.json';
