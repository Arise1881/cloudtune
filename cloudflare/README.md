# CloudTune — Cloudflare yapılandırması (tek kaynak)

Bu klasör CloudTune'un **tek** Cloudflare yapılandırmasını içerir. Eski
tünel/worker adları ve dağınık scriptler kaldırıldı.

## Canlı durum

| Bileşen | Ad | Durum |
|---|---|---|
| Worker | `cloudtune-repair` | ✅ yayında — `https://cloudtune-repair.cloudtune-5b3.workers.dev` |
| Worker | `cloudtune-stream` | ✅ yayında — `https://cloudtune-stream.cloudtune-5b3.workers.dev` |
| Worker | `cloudtune-dist` | ✅ yayında — tanıtım sayfasının worker kopyası |
| Tünel | `cloudtune` / `23d9da7b-178f-424a-8f7d-671c7708445b` | ⏸ oluşturuldu, **inactive** (zone yok) |

Uygulama **önce doğrudan YouTube'a** bağlanır. Yalnızca akış alınamazsa
`cloudtune-stream` worker'ı denenir; onarım kaydı `cloudtune-repair`
worker'ına gider. Hata mesajı kullanıcıya hiçbir zaman gösterilmez.

## Uç noktalar

```
GET  https://cloudtune-stream.cloudtune-5b3.workers.dev/health
GET  https://cloudtune-stream.cloudtune-5b3.workers.dev/v1/resolve?id=<videoId>
GET  https://cloudtune-stream.cloudtune-5b3.workers.dev/v1/stream/<videoId>
GET  https://cloudtune-repair.cloudtune-5b3.workers.dev/api/health
POST https://cloudtune-repair.cloudtune-5b3.workers.dev/api/repair-log
POST https://cloudtune-repair.cloudtune-5b3.workers.dev/api/device-report
```

## E-posta zinciri

`POST /api/repair-log` sırasıyla şunları dener:

1. `SENDGRID_API_KEY` secret'ı varsa SendGrid
2. MailChannels (yalnızca doğrulanmış alan adı varsa)
3. FormSubmit (`formsubmit.co/ajax/CloudTune@hotmail.com`)

FormSubmit anahtarsız çalışır ama **ilk kayıtta** `CloudTune@hotmail.com`
adresine bir "Activate Form" e-postası gönderir. O bağlantı bir kez
tıklanınca e-posta zinciri kalıcı olarak çalışır. Onaydan önce worker
`{"ok":true,"mailed":false}` döner; uygulama tarafı sessizce devam eder.

> **Durum (15.11.2026):** FormSubmit aktivasyonu henüz etkin değil —
> `mailed:false` sürüyor. Zincir açılana kadar kayıtlar kaybolmuyor:
> worker son adım olarak kaydı **özel** `Arise1881/cloudtune-reports`
> deposunda "CloudTune onarim kayitlari" başlıklı issue'ya yorum olarak
> ekler (`{"ok":true,"mailed":false,"filed":true}`).

## E-posta yedeği (GitHub deposit)

`GH_TOKEN` secret'ı tanımlıysa ve e-posta gönderilemezse kayıt özel depoya
işlenir. Secret'ı eklemek için:

```bash
curl -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"GH_TOKEN","text":"<token>","type":"secret_text"}' \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/scripts/cloudtune-repair/secrets"
```

Token yalnızca `cloudtune-reports` deposuna issue yazabilmelidir (fine-grained
token önerilir). `mailed:true` alındığında bu adım hiç çalışmaz.

## Tünel hakkında

`23d9da7b-178f-424a-8f7d-671c7708445b` kimliğiyle tünel hesapta mevcut.
Ancak Cloudflare hesabında **kayıtlı alan adı (zone) yok**; bu yüzden
`repair.cloudtune.app` / `stream.cloudtune.app` gibi genel adresler
oluşturulamıyor. Alan adı eklenirse:

```bash
export CLOUDFLARE_API_TOKEN='...'   # Workers Scripts + Cloudflare Tunnel (+ DNS) yetkili
export ZONE_NAME='alanadin.com'
bash cloudflare/setup.sh            # DNS CNAME'lerini de yazar
bash cloudflare/tunnel.sh start     # yerel relay 8787/8788'e bağlar
```

Worker'lar alan adı olmadan da `*.workers.dev` üzerinden çalıştığı için
alan adı zorunlu değil.

## Kurulum (yeniden)

```bash
export CLOUDFLARE_API_TOKEN='...'
bash cloudflare/setup.sh
```

`setup.sh`:

1. Hesabı doğrular, tünel kimliğini kontrol eder.
2. Zone varsa DNS CNAME'lerini yazar; yoksa bu adımı atlar.
3. `cloudtune-repair` + `cloudtune-stream` worker'larını yükler.
4. `*.workers.dev` alt alan adlarını açar.
5. Sağlık kontrolü yapar.

## Doğrulama

```bash
curl https://cloudtune-repair.cloudtune-5b3.workers.dev/api/health
curl https://cloudtune-stream.cloudtune-5b3.workers.dev/health
curl -H 'Range: bytes=0-200000' -o /dev/null -w '%{http_code}\n' \
  https://cloudtune-stream.cloudtune-5b3.workers.dev/v1/stream/dQw4w9WgXcQ
curl -X POST https://cloudtune-repair.cloudtune-5b3.workers.dev/api/repair-log \
  -H 'content-type: application/json' \
  -d '{"event_type":"selftest","message":"ok"}'
```
