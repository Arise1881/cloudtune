# CloudTune

Açık kaynak, reklamsız müzik çalar. Şarkılar **doğrudan YouTube** üzerinden
aranır ve çalınır; aracı sunucu, reklam veya hesap gerekmez.

| Platform | Durum |
|---|---|
| Android (arm64 / armv7 / x86_64 / evrensel) | ✅ |
| Linux (deb + tar.gz) | ✅ |
| Windows 11 (zip) | ✅ |
| iOS (imzasız IPA, AltStore/SideStore) | ✅ |

## Özellikler

- **Doğrudan YouTube** — arama, video ve çalma listesi çözümlemesi cihazda yapılır
- **Sonsuz radyo** — kuyruk bitince ilgili parçalarla devam eder
- **Kilit ekranı / bildirim kontrolleri** — şarkı bilgisi, ileri–geri, beğeni
- **Çalma listeleri** — tek kaydırmalı liste, “Tümünü çal”
- **Sanatçı profilleri** — sanatçının tüm parçaları tek listede
- **Kişisel ana sayfa** — dinleme geçmişine göre şekillenen bölümler
- **Oda** — kendi görselini avatar yap, beğendiklerini topla
- **Cihaza indirme** — Android’de `Download/CloudTune`, masaüstünde Belgeler
- **Bağlantı desteği** — `youtu.be`, `m.youtube.com`, `youtube.com`,
  `www.youtube.com`; Ayarlar’dan açılıp kapatılabilir
- **Gizli onarım botu** — akış hatalarını sessizce onarır, düşük pil/CPU kullanır
- **18 vurgu rengi** ve uygulama içi güncelleme

Kullanıcıya bağlantı bilgisi veya hata mesajı gösterilmez.

## Onarım zinciri

1. Doğrudan YouTube akışını yeniden dene
2. Cloudflare yedek akışı (`cloudflare/`)
3. Cihaz raporunu `CloudTune@hotmail.com` adresine ilet

## Derleme

```bash
bash tool/bootstrap.sh          # Android platform dosyalarını üret/yamala
flutter test
flutter build apk --release --split-per-abi
```

Sürüm yayınlama (APK + Linux + release güncelleme + `update.json`):

```bash
bash release.sh patch           # major | minor | patch | current
```

## Altyapı

Cloudflare tüneli ve worker’ları: [`cloudflare/README.md`](cloudflare/README.md)

## Lisans

MIT
