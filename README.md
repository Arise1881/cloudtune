# CloudTune

Açık kaynak, reklamsız müzik çalar. Şarkılar **doğrudan cihazdan YouTube** üzerinden aranır ve çalınır; aracı sunucu, hesap veya abonelik gerekmez.

| Platform | Durum | Paket |
|---|---|---|
| Android 7.0+ (telefon / tablet / katlanabilir) | ✅ | `CloudTune-universal.apk` (tüm ABI'ler) |
| Android arm64 | ✅ | `CloudTune-arm64.apk` |
| Android armv7 | ✅ | `CloudTune-armv7.apk` |
| Android x86_64 | ✅ | `CloudTune-x86_64.apk` |
| Linux x86_64 | ✅ | `CloudTune-linux.deb` (libmpv2 bağımlı), `CloudTune-linux.tar.gz` |
| Windows 11 | ⚠️ Eski paket | `CloudTune-windows.zip` (3.0.5+206); güncel CI ödeme limiti nedeniyle üretilemedi |
| iOS (AltStore / SideStore) | ⚠️ Eski paket | `CloudTune.ipa`; güncel CI ödeme limiti nedeniyle üretilemedi |

> **Windows/iOS:** GitHub Actions job'ları “recent account payments have failed or spending limit needs to be increased” nedeniyle hiç başlamıyor. Billing/spending limiti düzeltildikten sonra `gh workflow run windows-build.yml` ve `gh workflow run ios-build.yml` ile güncel paketler üretilebilir. Android ve Linux paketleri güncel ve doğrulandı.

> **Linux ses:** Oynatma motoru `media_kit + libmpv`'dir. `deb` paketi `libmpv2`'ye bağlıdır; `apt` bağımlılığı otomatik kurar. `tar.gz` kullanacaksanız sistemde `libmpv2` bulunmalıdır (`sudo apt install libmpv2`). `just_audio` Linux'ta desteklenmediği için ses motoru platforma göre seçilir.

> **Hangi APK?** Cihazınızın mimarisini bilmiyorsanız `CloudTune-universal.apk`'yı indirin. Uygulama içi güncelleyici cihazın ABI'sini algılar (`Abi.current`) ve doğru paketi seçer; uygun paket yoksa evrensel APK'ya düşer.

---

## İlk kurulum (yeni kullanıcı)

1. [Son sürüm](https://github.com/Arise1881/cloudtune-dist/releases/tag/cloudtune-latest) sayfasından platformunuza uygun dosyayı indirin.
2. Android 7.0+ gerekir. **Bilinmeyen kaynaklardan yükleme** iznini verin (Ayarlar → Güvenlik). Paket imzalı olduğu için Google Play koruması uyarı verebilir; devam edin.
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

## Android sürüm ve cihaz uyumu

| Android | API | Destek | Not |
|---|---|---|---|
| 7.0 – 7.1 | 24 – 25 | ✅ | `minSdk 24` — Flutter 3.x ve `app_links` alt sınırı |
| 8.0 – 8.1 | 26 – 27 | ✅ | Evrensel veya ABI'ye özel APK |
| 9 – 10 | 28 – 29 | ✅ | Depolama izni `Download/CloudTune` için istenir |
| 11 – 14 | 30 – 34 | ✅ | Bildirim izni, kilit ekranı kontrolleri |
| 15+ | 35+ | ✅ | `targetSdk 36`, `resizeableActivity`, tablet/katlanabilir |

| Mimari | Paket | Cihaz |
|---|---|---|
| `arm64-v8a` | `CloudTune-arm64.apk` | Çoğu modern telefon/tablet |
| `armeabi-v7a` | `CloudTune-armv7.apk` | Eski 32-bit cihazlar |
| `x86_64` | `CloudTune-x86_64.apk` | x86 tablet, emülatör, ChromeOS |
| Tümü | `CloudTune-universal.apk` | Bilinmeyen mimari / GUI indirmede varsayılan |

`minSdk` değeri `android/gradle.properties` içindeki `cloudtune.minSdk=24`'ten okunur. Flutter'ın minSdk migrasyonu `app/build.gradle.kts` dosyasını geri yazsa bile değer korunur. `AndroidManifest.xml` içindeki `supports-screens` (small→xlarge, anyDensity) ve `resizeableActivity=true` telefon, tablet, katlanabilir ve geniş ekran cihazları kapsar.

---

## Dosya haritası (kaynak depo)

```
README.md                  Bu dosya: özellikler, kurulum, uyum, güncelleme, gizlilik
LICENSE                    MIT lisans
pubspec.yaml / pubspec.lock  Flutter bağımlılıkları ve sürüm (3.0.37+238)
analysis_options.yaml      Dart/Flutter linter kuralları
.metadata                  Flutter proje metadata
release.sh                 Build → analyze/test → artifact → GitHub release → push
.gitignore                 Geçici/üretilmiş dosya hariç tutmaları

lib/
  main.dart                Giriş, AudioService init, ThemeData, sistem teması dinleyicisi,
                           uygulama bağlantıları (app_links)
  core/
    app_palette.dart       Tema duyarlı renk paleti (yüzey, metin, ayırıcı, ikon)
    theme_state.dart       Vurgu rengi + çözümlenmiş Brightness (system dahil)
    settings_service.dart  Cihaz içi tercihler (tema, ekolayzer, dil, radyo, indirme)
    audio_backend.dart     Platform ses motoru: just_audio (Android/iOS), media_kit+libmpv (Linux)
    player_controller.dart Kuyruk, geçiş koruması, ses, ekolayzer, prefetch
    youtube_service.dart   InnerTube arama, sanatçı parçaları, akış çözümleme
    library.dart           Geçmiş, beğeniler, çalma listeleri
    models.dart            Track ve veri modelleri
    download_service.dart  Cihaza indirme, çevrimdışı çalma
    update_service.dart    OTA manifest, ABI seçimi, APK indirme/kurulum
    room_service.dart      MQTT oda durumu
    repair_bot.dart        Sessiz akış onarımı
    link_resolver.dart     YouTube bağlantı çözümleme (5 host)
    link_handler.dart      Uygulama içi bağlantı yönlendirme
    test_tracks.dart       Debug/emülatör test parçaları
  ui/
    home_page.dart         Ana sayfa, arama, sesli arama, feed/sonuç yenileme
    player_page.dart       Tam ekran oynatıcı
    mini_player.dart       Alt mini oynatıcı
    track_tile.dart        Parça satırı
  screens/
    settings_screen.dart   Tema, ekolayzer, bağlantılar, indirme ayarları
    artist_page.dart       Sanatçı parçaları
    playlist_page.dart     Çalma listesi detayı
    my_playlists_page.dart Çalma listelerim
    downloads_page.dart    İndirilenler
    room_page.dart         Oda ekranı

test/link_resolver_test.dart  Bağlantı çözümleme birim testleri (11 test)
tool/bootstrap.sh             flutter create sonrası Android dosyalarını üret/yamala
tool/patch_android.py         Manifest izinleri, intent-filter, servisler, minSdk yaması
.github/workflows/build.yml   Android + Linux CI
.github/workflows/ios-build.yml   iOS IPA derleme (CI)
.github/workflows/windows-build.yml Windows zip derleme (CI)

android/
  build.gradle.kts, settings.gradle.kts, gradle.properties, gradlew*
  gradle/wrapper/            Gradle wrapper
  local.properties           Yerel SDK yolu (repoya alınmaz)
  app/build.gradle.kts       imza, ABI, sürüm, minSdk=24 (property'den)
  app/src/main/AndroidManifest.xml  İzinler, supports-screens, servis/alıcı, intent-filter
  app/src/debug|profile/AndroidManifest.xml  Debug/profile izinleri
  app/src/main/kotlin/.../MainActivity.kt   Android giriş aktivitesi
  app/src/main/res/          launcher ikonları, splash, tema stilleri, keep.xml,
                             network_security_config.xml, favori ikonları
ios/    Runner, AppDelegate, Info.plist, xcassets, xcodeproj/xcworkspace, Flutter config
linux/  CMakeLists, runner/, flutter/  GTK uygulama ve Flutter embedder
windows/ CMakeLists, runner/, flutter/  Win32 uygulama ve Flutter embedder
web/    index.html, manifest.json, favicon.png, icons/, splash/  PWA runner
```

## Dosya haritası (dağıtım deposu — `cloudtune-dist`)

```
README.md       Kullanıcıya yönelik indirme/kurulum/Gizlilik sayfası (GitHub ana sayfası)
index.html      GitHub Pages indirme portalı (QR kodlar, sürüm kartları, bağlantılar)
update.json     OTA manifest: sürüm, versionCode, notlar, platform → asset URL
apps.json       AltStore/SideStore kaynak dosyası (iOS IPA sürümü)
icon.png        Uygulama ikonu (Pages + DEB masaüstü girişi)
header.png      Pages başlık görseli
apk-qr.png      Android indirme QR kodu
ipa-qr.png      iOS kaynak QR kodu
sidestore-qr.png SideStore QR kodu
video-poster.png Pages video kapak görseli
tunnel.txt      Altyapı notu (Cloudflare tüneli)
```

> Release asset'leri (`CloudTune-*.apk`, `.deb`, `.tar.gz`, `.zip`, `.ipa`) depo
> içinde tutulmaz; GitHub release `cloudtune-latest` etiketinde yayınlanır.
> `update.json` ve `index.html` bu asset'leri işaret eder.

---

## Kurulum sonrası doğrulama

```bash
flutter analyze                       # 0 hata
flutter test                          # 11/11
ADB_SERIAL=emulator-xxxx python3 ct_full_test.py   # 20/20 (debug APK)
# Gerçek kullanıcı akışı:
#   uninstall → release APK install → ilk açılış → izinler → tema → arama
```

Gerçek kullanıcı simülasyonunda kontrol edilenler: sürüm `3.0.37 / 238`,
`minSdk=24`, uygulama foreground, mikrofon ilk dokunuşta açılıyor, açık temada
zemin açık/metin koyu, arama sonuçlarında “Çalma Listeleri ve Şarkılar” ve
“Arama Sonuçları” başlıkları, logcat'te crash yok.

---

## Derleme

Gereksinimler: Flutter SDK, Android SDK (API 36 — compileSdk/targetSdk), Java 17.

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
