<p align="center">
  <img src="https://raw.githubusercontent.com/Arise1881/melody-dist/main/icon.png" width="120" height="120" alt="Melody">
  <h1 align="center">🎵 Melody</h1>
  <p align="center"><b>Spotify temalı, açık kaynak, YouTube destekli müzik çalar</b></p>
  <p align="center">
    <a href="#-özellikler"><img src="https://img.shields.io/badge/özellikler-40%2B-1DB954?style=flat-square"></a>
    <a href="#-kurulum"><img src="https://img.shields.io/badge/platformlar-Android%20•%20iOS%20•%20Linux%20•%20Windows%2011-1E88E5?style=flat-square"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/lisans-MIT-9C27B0?style=flat-square"></a>
    <a href="https://github.com/Arise1881/melody-dist"><img src="https://img.shields.io/badge/yayın-melody--dist-1DB954?style=flat-square"></a>
  </p>
</p>

> 🚀 **Melody**, YouTube üzerinden şarkı çalan, indiren ve **arka planda** durmaksızın
> müzik dinleten premium arayüzlü bir müzik uygulamasıdır. Karanlık/açık tema,
> 5 vurgu rengi, ekolayzer, oda sistemi ve daha fazlası kutudan çıkar.

---

## ✨ Ekran Görüntüleri

<div align="center">
  <img src="https://raw.githubusercontent.com/Arise1881/melody-dist/main/video-poster.png" width="600" alt="Melody tanıtım">
  <br><br>
  <img src="https://raw.githubusercontent.com/Arise1881/melody-dist/main/apk-qr.png" width="180" alt="Android QR kod">
  <img src="https://raw.githubusercontent.com/Arise1881/melody-dist/main/ipa-qr.png" width="180" alt="iOS QR kod">
</div>

---

## 🎯 Özellikler

### 🖤 Oynatma
| | |
|---|---|
| ✅ Sonsuz otomatik çalma | Şarkı bitince benzer şarkılar otomatik gelir, hiç susmaz |
| ✅ Arka plan çalma | Ekran kilitliyken / uygulama kapalıyken devam eder |
| ✅ Kilit ekranı kontrolleri | Bildirim + medya butonları (play/pause/skip) |
| ✅ Oynatma hızı | 0.5x – 2x arası 6 kademe |
| ✅ Crossfade | Şarkı geçişlerinde yumuşak ses (2-10 sn, ayarlanabilir) |
| ✅ Karıştır / Tekrar | Shuffle, repeat one/all |
| ✅ Oturum kaldırma | Kapatılan şarkı aynı konumdan geri gelir |

### 🎛 Ses Kalitesi
| | |
|---|---|
| ✅ 5 kalite kademesi | Auto, Ultra (lossless), Yüksek (320kbps), Orta, Düşük |
| ✅ 7 bant ekolayzer | Flat, Pop, Rock, Jazz, Klasik, Bas, Vokal |
| ✅ Akıllı önbellek | Sıradaki şarkı önceden çözülür → anında geçiş |

### 📚 Kitaplık
| | |
|---|---|
| ✅ Arama | Canlı arama, son aramalar |
| ✅ İndirmeler | Çevrimdışı dinleme + ilerleme göstergesi + boyut takibi |
| ✅ Favoriler | Kalp ile beğen, tek listeden yönet |
| ✅ Çalma listeleri | Oluştur, yeniden adlandır, sil, karıştır |
| ✅ Dinleme geçmişi | Son çalınanlar otomatik kaydedilir |
| ✅ Radyo | Bir şarkıdan sonsuz benzer şarkı akışı |
| ✅ Şarkı sözleri | Eşzamanlı vurgulu (pseudo-sync) |

### 🌍 Bağlantılı Özellikler
| | |
|---|---|
| ✅ Oda sistemi | Kodla katıl, senkronize dinle |
| ✅ Çevrimdışı mod | Manuel kapat, yalnızca indirilenler |
| ✅ OTA güncelleme | Açık kaynaktan anında cihazlara güncelleme |

### 🎨 Arayüz
| | |
|---|---|
| ✅ Karanlık / Açık tema | Tek dokunuşla geçiş |
| ✅ 5 vurgu rengi | Yeşil, Mavi, Mor, Kırmızı, Turuncu |
| ✅ Trend ana sayfa | Küratörlü yatay akışlar |
| ✅ Mini oynatıcı | Gezinirken bile şarkı kontrolü |
| ✅ Uyku zamanlayıcısı | 5dk – 1sa arası otomatik durdur |

---

## 📥 Kurulum

| Platform | Yöntem |
|---|---|
| **Android (arm64)** | [Melody.apk indir](https://github.com/Arise1881/melody-dist/releases/download/melody-latest/Melody.apk) · 21 MB |
| **Android (evrensel)** | [Melody-universal.apk indir](https://github.com/Arise1881/melody-dist/releases/download/melody-latest/Melody-universal.apk) · 59 MB |
| **iOS** | [AltStore kaynağı ekle](altstore://source?url=https://raw.githubusercontent.com/Arise1881/melody-dist/main/apps.json) veya [ipa](https://github.com/Arise1881/melody-dist/releases/download/melody-latest/Melody.ipa) |
| **Linux (deb)** | `sudo apt install ./melody_2.1.3_amd64.deb` |
| **Linux (tar.gz)** | [Melody-linux.tar.gz](https://github.com/Arise1881/melody-dist/releases/download/melody-latest/Melody-linux.tar.gz) |
| **Windows 11** | Kaynak + GitHub Actions ile derlenir → `Melody-windows.zip` (release) |
| **Qt/Bağımsız** | `flutter run` (geliştirme) |

> 📲 **Otomatik güncelleme:** Uygulama açıldığında `update.json` kontrol edilir.
> Yeni sürüm varsa banner görünür → tek dokunuşla indir + kur. Arka planda müzik
> kesilmez; güncelleme ayrı oturumda tamamlanır.

---

## 🏗 Mimari

```
lib/
├── constants.dart                # Tema token'ları, metinler, küratörlü bölümler
├── models/song.dart              # Şarkı modeli (JSON serileştirme)
├── services/
│   ├── music_service.dart        # youtube_explode_dart: arama + akış çözümleme
│   ├── player_service.dart       # just_audio + arka plan oynatıcı (kuyruk/radyo/hız)
│   ├── download_manager.dart     # Parça parça indirme + formatBytes depolama
│   ├── library_store.dart        # Favoriler / listeler / indirmeler (kalıcı)
│   ├── connectivity_service.dart # Çevrimdışı izleme + manuel çevrimdışı
│   ├── equalizer_service.dart    # 5 bant EQ → ses çarpanı
│   ├── theme_service.dart        # Tema modu + 5 vurgu rengi (kalıcı)
│   ├── room_service.dart         # Oda oluştur / katıl / senkronize çal
│   ├── update_service.dart       # OTA manifest kontrolü + kurulum
│   └── download_manager.dart     # İndirme havuzu + önbellek temizleme
├── screens/                      # Root, Home, Search, Library, NowPlaying…
├── widgets/                      # MiniPlayer, SongTile, Artwork, OfflineBanner
└── .github/workflows/            # Windows 11 derleme pipeline
```

---

## 🛠 Çalıştırma

```bash
flutter pub get
flutter run                      # bağlı cihaz / masaüstü
flutter build apk --release      # Android
flutter build apk --split-per-abi
flutter build ipa                # iOS (macOS gerekir)
flutter build linux --release    # Linux
flutter build windows --release  # Windows 11
```

---

## ⚖️ Yasal

Bu uygulama yalnızca açık kaynak kütüphaneler kullanır ve hiçbir içeriği barındırmaz.
İndirilen içeriklerin kullanımından geliştirici sorumlu değildir; telif haklarına uyun.

## 📄 Lisans

MIT © 2026 Arise1881 · [melody-dist](https://github.com/Arise1881/melody-dist) yayın sayfası