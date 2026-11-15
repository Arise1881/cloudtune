#!/usr/bin/env bash
# CloudTune — tek komutla Cloudflare kurulumu.
# Tünel: 23d9da7b-178f-424a-8f7d-671c7708445b
# Worker'lar: cloudtune-repair, cloudtune-stream
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://api.cloudflare.com/client/v4"
ZONE_NAME="${ZONE_NAME:-cloudtune.app}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-23d9da7b-178f-424a-8f7d-671c7708445b}"
REPAIR_WORKER="cloudtune-repair"
STREAM_WORKER="cloudtune-stream"

TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f /tmp/opencode/cf_token ]; then
  TOKEN="$(cat /tmp/opencode/cf_token)"
fi
if [ -z "$TOKEN" ]; then
  echo "HATA: CLOUDFLARE_API_TOKEN tanimli degil (veya /tmp/opencode/cf_token yok)." >&2
  exit 1
fi

cf() { curl -fsS -H "Authorization: Bearer $TOKEN" "$@"; }
jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']$1) if d.get('success') else (print('HATA:', d.get('errors')), sys.exit(1))"; }

echo "==> Hesap"
ACCOUNT_ID="$(cf "$API/accounts" | jqp "[0]['id']")"
echo "    $ACCOUNT_ID"

echo "==> Tünel dogrulama: $TUNNEL_ID"
cf "$API/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" >/dev/null \
  || { echo "HATA: tünel bulunamadi. Dashboard > Zero Trust > Tunnels uzerinden olusturun." >&2; exit 1; }
echo "    OK"

echo "==> Zone: $ZONE_NAME (opsiyonel)"
ZONE_ID=""
if [ -n "$ZONE_NAME" ]; then
  ZONE_ID="$(cf "$API/zones?name=$ZONE_NAME" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')")"
fi

if [ -z "$ZONE_ID" ]; then
  echo "    zone yok — DNS adimi atlandi (workers.dev uzerinden calisir)"
else
  echo "    $ZONE_ID"
  echo "==> DNS CNAME"
  for host in repair stream; do
    NAME="$host"
    CONTENT="$TUNNEL_ID.cfargotunnel.com"
    RID="$(cf "$API/zones/$ZONE_ID/dns_records?type=CNAME&name=$host.$ZONE_NAME" \
          | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')")"
    if [ -n "$RID" ]; then
      cf -X PATCH -H "Content-Type: application/json" \
        -d "{\"content\":\"$CONTENT\",\"proxied\":true}" \
        "$API/zones/$ZONE_ID/dns_records/$RID" >/dev/null
      echo "    $NAME -> guncellendi"
    else
      cf -X POST -H "Content-Type: application/json" \
        -d "{\"type\":\"CNAME\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"proxied\":true}" \
        "$API/zones/$ZONE_ID/dns_records" >/dev/null
      echo "    $NAME -> eklendi"
    fi
  done
fi

echo "==> Worker: $REPAIR_WORKER"
BINDINGS="[]"
if [ -n "${CLOUDFLARE_KV_NAMESPACE_ID:-}" ]; then
  BINDINGS="[{\"name\":\"KV\",\"type\":\"kv_namespace\",\"namespace_id\":\"${CLOUDFLARE_KV_NAMESPACE_ID}\"}]"
fi
cf -X PUT \
  -F "metadata={\"body_part\":\"worker.js\",\"bindings\":${BINDINGS}};type=application/json" \
  -F "worker.js=@${DIR}/repair-log-worker.js;type=application/javascript" \
  "$API/accounts/$ACCOUNT_ID/workers/scripts/$REPAIR_WORKER" >/dev/null
echo "    yuklendi"

echo "==> Worker: $STREAM_WORKER"
cf -X PUT \
  -F "metadata={\"main_module\":\"worker.js\",\"compatibility_date\":\"2024-09-23\"};type=application/json" \
  -F "worker.js=@${DIR}/stream-proxy.js;type=application/javascript+module" \
  "$API/accounts/$ACCOUNT_ID/workers/scripts/$STREAM_WORKER" >/dev/null
echo "    yuklendi"

if [ -n "${SENDGRID_API_KEY:-}" ]; then
  for W in "$REPAIR_WORKER" "$STREAM_WORKER"; do
    cf -X PUT -H "Content-Type: application/json" \
      -d "{\"name\":\"SENDGRID_API_KEY\",\"text\":\"${SENDGRID_API_KEY}\"}" \
      "$API/accounts/$ACCOUNT_ID/workers/scripts/$W/secrets" >/dev/null || true
  done
  echo "==> SendGrid anahtari yazildi"
fi

echo "==> workers.dev alt alan adlari"
for W in "$REPAIR_WORKER" "$STREAM_WORKER"; do
  cf -X POST -H "Content-Type: application/json" -d '{"enabled":true}' \
    "$API/accounts/$ACCOUNT_ID/workers/scripts/$W/subdomain" >/dev/null || true
done

if [ -n "${CLOUDFLARE_KV_NAMESPACE_ID:-}" ] && [ -n "$ZONE_ID" ]; then
  echo "==> Zone route: repair.$ZONE_NAME/*"
  cf -X POST -H "Content-Type: application/json" \
    -d "{\"pattern\":\"repair.$ZONE_NAME/*\",\"script\":\"$REPAIR_WORKER\"}" \
    "$API/zones/$ZONE_ID/workers/routes" >/dev/null || true
fi

echo "==> Saglik kontrolu"
for URL in \
  "https://$REPAIR_WORKER.cloudtune-5b3.workers.dev/api/health" \
  "https://$STREAM_WORKER.cloudtune-5b3.workers.dev/health"; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)"
  echo "    $URL -> ${CODE:-erisilemedi}"
done

echo
echo "Bitti. Tüneli baslatmak icin: bash cloudflare/tunnel.sh start"
