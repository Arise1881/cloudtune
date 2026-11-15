# CloudTune — Cloudflare yapılandırması (tek kaynak)

Bu klasör CloudTune'un **tek** Cloudflare yapılandırmasını içerir. Eski
tünel/worker adları ve dağınık scriptler kaldırıldı.

## Bileşenler

| Bileşen | Ad | Görev |
|---|---|---|
| Tünel | `cloudtune` / `23d9da7b-178f-424a-8f7d-671c7708445b` | `repair.cloudtune.app` ve `stream.cloudtune.app` adreslerini yerel servise bağlar |
| Worker | `cloudtune-repair` | Onarım kaydı + cihaz raporu; `CloudTune@hotmail.com` adresine e-posta iletir |
| Worker | `cloudtune-stream` | Ses akışı yedeği (`/v1/resolve`, `/v1/stream/<id>`, `/health`) |

Uygulama **önce doğrudan YouTube'a** bağlanır. Yalnızca akış alınamazsa
sırasıyla `cloudtune-stream` worker'ı ve `repair` tüneli denenir. Hata
mesajı kullanıcıya hiçbir zaman gösterilmez.

## Yeni tünel kimliği

```
TUNNEL_ID=23d9da7b-178f-424a-8f7d-671c7708445b
TUNNEL_NAME=cloudtune
```

Eski tünel kimlikleri ve `cloudtune-repair-log` adlı eski worker bu sürümle
birlikte kullanımdan kaldırıldı.

## Kurulum

```bash
export CLOUDFLARE_API_TOKEN='...'          # Workers + DNS + Tunnel yetkili
export SENDGRID_API_KEY='...'              # opsiyonel; yoksa MailChannels denenir
bash cloudflare/setup.sh
```

`setup.sh` şunları yapar:

1. Hesap ve zone'u doğrular (`cloudtune.app`).
2. `23d9da7b-...` tünelini doğrular/oluşturur ve DNS CNAME'lerini yazar.
3. `cloudtune-repair` + `cloudtune-stream` worker'larını yükler.
4. workers.dev alt alan adlarını açar.
5. Sağlık kontrolü yapar.

## Yerel tünel (sunucu tarafı)

```bash
bash cloudflare/tunnel.sh start     # arka planda cloudflared
bash cloudflare/tunnel.sh status
bash cloudflare/tunnel.sh stop
```

Kimlik dosyası: `~/.cloudflared/23d9da7b-178f-424a-8f7d-671c7708445b.json`

## Doğrulama

```bash
curl https://cloudtune-repair.cloudtune-5b3.workers.dev/api/health
curl https://cloudtune-stream.cloudtune-5b3.workers.dev/health
curl -X POST https://cloudtune-repair.cloudtune-5b3.workers.dev/api/repair-log \
  -H 'content-type: application/json' \
  -d '{"event_type":"selftest","message":"ok"}'
```
