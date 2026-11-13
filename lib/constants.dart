import 'package:flutter/material.dart';

/// Spotify klonu renk paleti: siyah arkaplan, yeşil vurgu, koyu gri kartlar.
class AppColors {
  // Spotify siyah arkaplan
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF121212);
  static const card = Color(0xFF181818);
  static const cardHover = Color(0xFF282828);
  static const cardLight = Color(0xFF2A2A2A);

  // Spotify yeşil vurgu
  static const accent = Color(0xFF1DB954);
  static const accentBright = Color(0xFF1ED760);
  static const accentDark = Color(0xFF1AA34A);

  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
  static const textTertiary = Color(0xFF808080);
  static const textDisabled = Color(0xFF4A4A4A);

  static const primary = Color(0xFF000000);
  static const onPrimary = Color(0xFF1DB954);
  static const error = Color(0xFFCF6679);

  static const gradientTop = Color(0xFF000000);
  static const gradientBottom = Color(0xFF121212);

  /// Spotify renk seçenekleri (kullanıcı profil rengi gibi).
  static const List<Color> accentColors = [
    accent,      // Yeşil (Spotify varsayılan)
    Color(0xFF1ED760), // Açık yeşil
    Color(0xFF1AA34A), // Koyu yeşil
    Color(0xFF1DB954),
  ];

  static const List<String> accentNames = [
    'Yeşil',
    'Yeşil 2',
    'Yeşil 3',
    'Yeşil 4',
  ];
}

class AppStrings {
  static const appName = 'CloudTune';
  static const offlineTitle = 'Çevrimdışı mod';
  static const offlineMessage = 'İnternet erişimi yok. İndirdiğin şarkılar çalmaya hazır.';
  static const searchHint = 'Şarkı, sanatçı veya albüm ara';
  static const emptySearch = 'Aramak için bir şeyler yazın';
  static const noResults = 'Sonuç bulunamadı';
  static const downloadsEmpty = 'Henüz indirilen şarkı yok.\nÇevrimdışı dinlemek için şarkı indirin.';
  static const favoritesEmpty = 'Beğendiğin şarkılar burada görünecek';
  static const likedSongs = 'Beğenilen Şarkılar';
  static const yourLibrary = 'Kütüphanen';
  static const madeForYou = 'Sana Özel';
  static const recentlyPlayed = 'Son Çalınanlar';
  static const topCharts = 'En Popüler';
  static const categories = 'Kategoriler';
  static const createPlaylist = 'Yeni Çalma Listesi Oluştur';
  static const addToPlaylist = 'Çalma listesine ekle';
  static const likeSong = 'Şarkıyı beğen';
  static const unlikeSong = 'Beğeni kaldır';
}

/// Ana sayfa vitrinindeki küratörlü bölümler.
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
