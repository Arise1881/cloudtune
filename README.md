# CloudTune

Açık kaynak, reklamsız müzik çalar. Şarkılar **doğrudan cihazdan YouTube** üzerinden aranır ve çalınır; aracı sunucu, hesap veya abonelik gerekmez.

| Platform | Durum | Paket |
|---|---|---|
| Android 5.0+ (telefon / tablet / katlanabilir) | ✅ | `CloudTune-universal.apk` (tüm ABI'ler) |
| Android arm64 | ✅ | `CloudTune-arm64.apk` |
| Android armv7 | ✅ | `CloudTune-armv7.apk` |
| Android x86_64 | ✅ | `CloudTune-x86_64.apk` |
| Linux x86_64 | ✅ | `CloudTune-linux.deb`, `CloudTune-linux.tar.gz` |
| Windows 11 | ✅ | `CloudTune-windows.zip` |
| iOS (AltStore / SideStore) | ✅ | `apps.json` kaynağı, imzasız IPA |

> **Hangi APK?** Cihazınızın mimarisini bilmiyorsanız `CloudTune-universal.apk`'yı indirin. Uygulama içi güncelleyici cihazın ABI'sini algılar (`Abi.current`) ve doğru paketi seçer; uygun paket yoksa evrensel APK'ya düşer.

---

## İlk kurulum (yeni kullanıcı)

1. [Son sürüm](https://github.com/Arise1881/cloudtune-dist/releases/tag/cloudtune-latest) sayfasından platformunuza uygun dosyayı indirin.
2. Android'de **Bilinmeyen kaynaklardan yükleme** iznini verin (Ayarlar → Güvenlik). Paket imzalı olduğu için Google Play koruması uyarı verebilir; devam edin.
3. APK'yı kurun ve uygulamayı açın.
4. İlk açılışta izinler:
   - **Bildirimler** — arka plan çalma ve kilit ekranı kontrolleri için,
   - **Mikrofon** — yalnızca sesli arama düğmesine bastığınızda kullanılır; uygulama sürekli dinlemez,
   - **Depolama** (Android 9 ve altı) — şarkıları `Download/CloudTune` klasörüne kaydetmek için.
5. Ayarlar → **Tema** seçeneğinden *Koyu / Açık / Sistem* modunu seçin. Vurgu rengi ve OLED siyah zemin de buradan ayarlanır.
6. Arama kutusuna şarkı/sanatçı yazın veya bir YouTube bağlantısı yapıştırın. İlk parçayı çaldıktan sonra **yukarıdan aşağıya kaydırarak** ana sayfa ve arama sonuçlarını yenileyebilirsiniz.

İlk açılışta hiçbir hesap, anahtar veya sunucu ayarı gerekmez. Dinleme geçmişi, beğeniler ve çalma listeleri yalnızca cihazda saklanır.

---

## Özellikler

### Çalma
- **Doğrudan YouTube** — arama, video/çalma listesi çözümlemesi ve akış cihazda yapılır
- **Sonsuz radyo** — kuyruk bitince ilgili parçalarla devam eder; tek ileri atlamada otomatik atlama yoktur
- **Arka plan çalma** — ekran kilitliyken devam eder; foreground servis duraklatmada kapanmaz, böylece ilk ses/çizirti sorunu oluşmaz
- **Kilit ekranı / bildirim kontrolleri** — şarkı bilgisi, ileri–geri, beğeni, medya tuşları
- **Ekolayzer** — açılışta ve ayar değişiminde uygulanır; parça başına uygulanmadığı için kesilme yapmaz
- **Çizirti önleme** — kaynak değişiminden önce ses kazancı sabitlenir

### Arama ve keşif
- **Metin arama** — şarkı, sanatçı ve YouTube bağlantıları
- **Sesli arama** — mikrofona kısa dokunuşta dinleme açılır ve konuşma bitince arama yapılır; basılı tutup bırakınca söylenen metin aranır. Hata sonrası otomatik yeniden dinleme yoktur. Mikrofon yalnızca kullanıcı dokunduğunda aktiftir.
- **Sanatçı parçaları** — arama sonuçlarında “Çalma Listeleri ve Şarkılar” başlığı altında sanatçının tüm parçaları listelenir
- **Kişisel ana sayfa** — dinleme geçmişine göre bölümler; içerik kendiliğinden değişmez, `RefreshIndicator` ile yenilenir
- **Pull-to-refresh** — ana sayfa ve arama sonuçları yukarıdan aşağıya kaydırıldığında güncellenir

### Kütüphane ve sosyal
- **Çalma listeleri** — tek kaydırmalı liste, “Tümünü çal”
- **Sanatçı profilleri** — sanatçının tüm parçaları tek listede
- **İndirilenler** — Android `Download/CloudTune`, masaüstü Belgeler klasörü; internet olmadan çalınabilir
- **Oda** — oda koduyla paylaşım, avatar, beğeniler (MQTT üzerinden eşzamanlı)
- **18 vurgu rengi**, açık/koyu/sistem teması, OLED siyah zemin

### Bakım ve güncelleme
- **Uygulama içi güncelleme** — `update.json` manifestini okur, ABI'ye uygun APK'yı indirir
- **Gizli onarım botu** — akış hatalarını sessizce onarır, düşük pil/CPU kullanır
- **Bağlantı desteği** — `youtu.be`, `m.youtube.com`, `music.youtube.com`, `youtube.com`, `www.youtube.com`; Ayarlar'dan açılıp kapatılabilir

Kullanıcıya bağlantı bilgisi veya ham hata mesajı gösterilmez; hatalar Türkçe açıklamalarla eşlenir.

### Onarım zinciri
1. Doğrudan YouTube akışını yeniden dene
2. Cihaz raporunu `CloudTune@hotmail.com` adresine ilet (anonym; platform, sürüm, video kimliği)

---

## Depo yapısı

```
lib/
  main.dart                  Uygulama girişi, ThemeData, sistem teması dinleyicisi
  core/
    app_palette.dart         Tema duyarlı renk paleti (açık/koyu yüzeyler, metin, ayırıcı)
    theme_state.dart         Vurgu rengi + çözümlenmiş parlaklık (ThemeMode.system dahil)
    settings_service.dart    Yerel tercihler (tema, ekolayzer, dil, radyo, indirme)
    player_controller.dart   ExoPlayer kuyruğu, geçişler, ses, ekolayzer, prefetch
    youtube_service.dart     InnerTube arama, sanatçı parçaları, akış çözümleme
    library.dart             Geçmiş, beğeniler, çalma listeleri
    download_service.dart    Cihaza indirme ve çevrimdışı çalma
    update_service.dart      OTA manifest, ABI'ye göre APK seçimi, kurulum
    room_service.dart        MQTT oda durumu
    repair_bot.dart          Sessiz hata onarımı
    link_resolver.dart       YouTube bağlantı çözümleme
    link_handler.dart        Uygulama içi bağlantı yönlendirme
    models.dart              Track ve veri modelleri
    test_tracks.dart         Debug/emülatör test parçaları
  ui/
    home_page.dart           Ana sayfa, arama, sesli arama, feed/sonuç yenileme
    player_page.dart         Tam ekran oynatıcı
    mini_player.dart         Alt mini oynatıcı
    track_tile.dart          Parça satırı
  screens/
    settings_screen.dart     Tema, ekolayzer, bağlantılar, indirme ayarları
    artist_page.dart         Sanatçı parçaları
    playlist_page.dart       Çalma listesi detayı
    my_playlists_page.dart   Çalma listelerim
    downloads_page.dart      İndirilenler
    room_page.dart           Oda ekranı
android/                     Android Gradle + manifest (minSdk 21, tüm ABI'ler)
linux/ windows/ ios/ web/    Masaüstü ve web runner'ları
tool/bootstrap.sh            Android platform dosyalarını üret/yamala
tool/patch_android.py        Android yapılandırma yamaları
test/                        Birim testler
release.sh                   Build → artifact → GitHub release → manifest push
```

---

## Derleme

Gereksinimler: Flutter SDK, Android SDK (API 35+), Java 17.

```bash
bash tool/bootstrap.sh          # Android platform dosyalarını üret/yamala
flutter pub get
flutter test
flutter analyze

# Android — tüm cihazlar için evrensel APK
flutter build apk --release

# Android — cihaz başına küçük APK'lar
flutter build apk --release --split-per-abi

# Masaüstü / web
flutter build linux --release
flutter build windows --release   # Windows makinede
flutter build ios --release --no-codesign  # macOS'ta
flutter build web --release
```

Sürüm yayınlama (APK + Linux + GitHub release + `update.json` + `apps.json` + Pages):

```bash
bash release.sh patch           # major | minor | patch | current
```

`release.sh` şunları yapar: `pubspec.yaml` sürümünü artırır, analyze/build çalıştırır, arm64/armv7/x86_64/universal APK + deb/tar.gz hazırlar, GitHub release asset'lerini günceller, dağıtım reposundaki `update.json`, `apps.json`, `index.html`, `README.md` dosyalarını push eder, kaynak repoyu push eder ve iOS/Windows CI iş akışlarını tetikler.

---

## Güncelleme mekanizması

Uygulama açılışta şu manifesti okur:

```
https://raw.githubusercontent.com/Arise1881/cloudtune-dist/main/update.json
```

Manifest `version`, `versionCode`, `notes` ve `platforms` alanlarını içerir. Android için `android-arm64`, `android-armv7`, `android-x86_64` ve `android-universal` bağlantıları bulunur. Güncelleme indirilmeden önce cihazın ABI'si belirlenir; uygun paket yoksa evrensel paket kullanılır.

Aynı manifest GitHub Pages üzerinden de yayınlanır:
`https://arise1881.github.io/cloudtune-dist/update.json` (CDN önbelleği nedeniyle raw bağlantı her zaman güncel kaynaktır).

---

## Gizlilik

Dinleme geçmişi, beğeniler, çalma listeleri, avatar ve dil/tercüme tercihleri **yalnızca cihazda** saklanır. Uygulamanın çalışması için PC veya özel sunucu gerekmez; YouTube/Invidious ve MQTT dış servisleri doğrudan cihazdan erişilir. Sunucuya gönderilen tek veri, çözülemeyen bir akış hatasında gönderilen anonim cihaz raporudur.

## Altyapı

Cloudflare tüneli ve worker'ları: [`cloudflare/README.md`](cloudflare/README.md)

## Lisans

MIT — bkz. [LICENSE](LICENSE).
