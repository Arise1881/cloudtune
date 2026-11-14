# CloudTune 3.0

YouTube destekli müzik çalar. **Cloudflare, Worker veya tünel kullanmaz**; tüm istekler doğrudan YouTube'a gider.

Kabul edilen bağlantı adresleri: `youtu.be`, `m.youtube.com`, `youtube.com`, `www.youtube.com`
(video, shorts, embed ve `list=` çalma listesi bağlantıları). Başka alan adları reddedilir.

## Neler var

- Yeni anasayfa: arama + bağlantı yapıştırma, yatay şarkı bölümleri, mini oynatıcı
- Tam ekran oynatıcı, arka planda çalma ve bildirim kontrolleri
- Android'de bu dört adrese ait bağlantılara dokununca CloudTune ile açma
- Akış adresi süresi dolarsa aynı konumdan otomatik devam

Eski sürümdeki çevrimdışı indirme, ekolayzer, oda sistemi, OTA güncelleme vb. özellikler bu sürümde **yok**.

## Derleme

GitHub'a yükleyip `main` dalına push et: **Actions → Android APK** çalışır, APK'lar artifact olarak iner.

Kendi bilgisayarında (Flutter kuruluysa):

```
bash tool/bootstrap.sh
flutter test
flutter build apk --release --split-per-abi
```

`tool/bootstrap.sh`, `flutter create` ile android klasörünü üretir ve `tool/patch_android.py` ile
izinleri, ses servisini ve YouTube bağlantı filtrelerini ekler.
