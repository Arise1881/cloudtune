# Sonora - Melody v2.1.3

**Sonora**, açık kaynaklı bir müzik çalar ve indiricidir. Flutter ile geliştirilmiştir
ve **Android + iOS** platformlarını destekler.

## 🆕 v2.1.3 Yeni Özellikler

| Özellik | Açıklama |
|---|---|
| **Oda Sistemi** | Oda oluşturma, katilım (kodlu/şifresiz), profil fotoğrafı, odadaki senkronizasyon |
| **Tema Renkleri** | Karanlık, Açık, Mavi, Yeşil, Mor - 5 renk seçeneği + dynamic accent |
| **Animated GIF** | Artwork widget'ı GIF'leri destekli |
| **Emoji Desteği** | Ayarlar üzerinden etkinleştirilebilir |
| **Medya Kalite** | Ultra (lossless), Yüksek (320kbps), Orta (128kbps), Düşük (48kbps), Auto |
| **Ekolayzer** | 5 bantlı + 7 preset (flat, pop, rock, jazz, classical, bass boost, vocal) |
| **İndirilenler** | Boyut takibi + indirme butonu + çalma listesi indirme |
| **Otomatik Devam** | Oynatma bittiğinde odadaki senkronizasyon + rasgele şarkı |
| **Dinleme Geçmişi** | Son çalınanlar histori |
| **Uyku Zamanlayıcısı** | 10dk-2sa arası otomatik durdurma |
| **Dynamic UI** | Now playing dynamik renk/ararka plan (Spotify tarzı) |

## Özellikler

| Özellik | Açıklama |
|---|---|
| **Arama** | Şarkı/sanatçı araması, son aramalar kaydı |
| **Ana Sayfa** | Küratörlü bölümler, hızlı erişim, oda erişimi |
| **Oynatma** | Arka planda çalma, kilit ekranı kontrolleri, sıra, karıştır, tekrar |
| **İndirme** | Tek dokunuşla çevrimdışı dinleme; ilerleme göstergesi |
| **Çevrimdışı Mod** | İnternet yokken otomatically olarak yalnızca indirilenler çalınır |
| **Kitaplık** | Beğeniler, kullanıcı çalma listeleri, indirilenler yönetimi |

## 📱 v2.1.3 Dağıtım Durumu

| Ortam | Sürüm | Durum |
|-------|-------|-------|
| **GitHub Repo** | 2.1.3+30 | Güncellendi ✅ |
| **GitHub Pages** (`update.json`) | 2.1.3 | 10 dakika içinde cihaz refresh |
| **APKlar** | Melody.apk (arm64, 21 MB) + Melody-universal.apk (57 MB) | Derlendi ve staged ✅ |
| **CDN Refresh** | `max-age=600` | 10 dakika içinde tamamen ✅ |

## 🔄 Update Mekanizması

- **2.1.0 ve eski**: Update banner'ı gösterilir → 2.1.3'e güncellenir
- **2.1.1 ve 2.1.2**: Update banner'ı gösterilir
- **2.1.3**: ❌ Banner gösterilmez (zaten güncel)
- **2.1.4 ve sonrası**: ❌ Banner gösterilmez (güncel sürümden yeni)

## Mimari

```
lib/
├── constants.dart              # Tema renkleri, metinler, küratörlü bölümler
├── models/song.dart            # Şarkı modeli (JSON serileştirme)
├── services/
│   ├── music_service.dart      # youtube_explode_dart: arama + akış çözümleme
│   ├── player_service.dart     # just_audio + just_audio_background oynatıcı
│   ├── download_manager.dart   # Parça parça indirme + ilerleme yayını
│   ├── library_store.dart      # Favoriler/listeler/indirmeler (JSON kalıcılık)
│   └── connectivity_service.dart # connectivity_plus ile çevrimdışı izleme
├── screens/                    # Root, Home, Search, Library, NowPlaying...
└── widgets/                    # MiniPlayer, SongTile, Artwork, OfflineBanner
```

## Çalıştırma

```bash
flutter pub get
flutter run                 # bağlı cihazda
flutter build apk --release # Android APK
flutter build ipa           # iOS (macOS gerekir)
```

## Yasal Not

Bu uygulama yalnızca açık kaynak kütüphanelerle çalışır ve hiçbir içeriği barındırmaz.
İndirilen içeriklerin kullanımından uygulamanın geliştiricisi sorumlu değildir;
telif hakkı yasalarına uyun.

## Lisans

MIT
