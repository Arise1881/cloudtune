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
  static const error = Color(0xFFCF6679);

  static const gradientTop = Color(0xFF1F3D2B);
}

class AppStrings {
  static const appName = 'Melody';
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
  'Türkçe Pop Hits': 'türkçe pop 2026 hit şarkılar',
  'Yabancı Listeler': 'top hits 2026 playlist',
  'Rock Klasikleri': 'classic rock greatest hits',
  'Lo-Fi & Odak': 'lofi hip hop study beats',
  'Rap & Hip-Hop': 'rap türkçe 2026',
  'Elektronik': 'electronic dance music mix 2026',
  'Akustik': 'acoustic covers playlist',
  '90\'lar Nostalji': '90s hits playlist',
};

const String downloadsFolderName = 'sonora_downloads';
const String libraryFileName = 'sonora_library.json';
