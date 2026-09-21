#!/usr/bin/env bash
set -euo pipefail

ZONE_NAME="cloudtune.app"
TUNNEL_NAME="cloudtune-repair"
TUNNEL="cloudtune-repair-log"
WORKER="cloudtune-repair-log"
HOSTNAME="repair.cloudtune.app"

AUTH=Authorization

echo "==> Cloudflare setup: ${ZONE_NAME}"
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "HATA: CLOUDFLARE_API_TOKEN tanimli degil." >&2
  echo "export CLOUDFLARE_API_TOKEN='...'" >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://api.cloudflare.com/client/v4"

jq_check() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print('ERR:', d.get('errors')) if not d.get('success') else sys.exit(0)"
}

echo
echo "==> 0) Account ID"
ACCOUNT=$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "${API}/accounts")
echo "$ACCOUNT" | jq_check
ACCOUNT_ID=$(echo "$ACCOUNT" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])")
echo "    account_id = ${ACCOUNT_ID}"

echo
echo "==> 1) Zone: ${ZONE_NAME} (varsa gec, yoksa ekle)"
ZONE=$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "${API}/zones?name=${ZONE_NAME}")
ZONE_ID=$(echo "$ZONE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d['success'] and d['result'] else '')")
if [ -z "$ZONE_ID" ]; then
  R=$(curl -fsS -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${ZONE_NAME}\",\"account\":{\"id\":\"${ACCOUNT_ID}\"},\"type\":\"full\"}" "${API}/zones")
  echo "$R" | jq_check
  ZONE_ID=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['id'])")
  echo "    zone eklendi: ${ZONE_ID}"
  echo "    !!! Nameserver'lari kayit sağlayicinizda degistirin:"
  echo "$R" | python3 -c "import json,sys; [print('    -', n) for n in json.load(sys.stdin)['result']['name_servers']]"
  echo "    !!! Zone aktiflesene kadar DNS + test calismaz (5-30 dk)."
else
  echo "    zone zaten var: ${ZONE_ID}"
fi

echo
echo "==> 2) Tunnel: ${TUNNEL_NAME} (varsa al, yoksa olustur)"
# CLOUDFLARE_TUNNEL_ID ile tünel sabitlenebilir (uygulamanın yazılı olduğu ID).
if [ -n "${CLOUDFLARE_TUNNEL_ID:-}" ]; then
  TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID}"
  # Sabitlenen tünel hesapta var mı kontrol et (name secmeli gecme).
  T=$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "${API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}")
  if ! echo "$T" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get('success') else 1)
"; then
    echo "    HATA: sabit tünel bulunamadi: ${TUNNEL_ID}" >&2
    exit 1
  fi
  echo "    sabit tünel doğrulandi: ${TUNNEL_ID}"
else
  T=$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "${API}/accounts/${ACCOUNT_ID}/cfd_tunnel?is_deleted=false")
  TUNNEL_ID=$(echo "$T" | python3 -c "import json,sys; d=json.load(sys.stdin); r=[x for x in d.get('result',[]) if x['name']=='${TUNNEL_NAME}']; print(r[0]['id'] if r else '')")
  if [ -z "$TUNNEL_ID" ]; then
    R=$(curl -fsS -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
      -d "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\"}" "${API}/accounts/${ACCOUNT_ID}/cfd_tunnel")
    echo "$R" | jq_check
    TUNNEL_ID=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['id'])")
    echo "    tunnel: ${TUNNEL_ID}"
  else
    echo "    tunnel zaten var: ${TUNNEL_ID}"
  fi
fi

echo
echo "==> 3) DNS CNAME: repair -> ${TUNNEL_ID}.cfargotunnel.com (proxied)"
EXISTS=$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "${API}/zones/${ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}")
RID=$(echo "$EXISTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d['success'] and d['result'] else '')")
if [ -n "$RID" ]; then
  curl -fsS -X PATCH -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
    "${API}/zones/${ZONE_ID}/dns_records/${RID}" | jq_check
  echo "    CNAME guncellendi: ${RID}"
else
  curl -fsS -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"repair\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
    "${API}/zones/${ZONE_ID}/dns_records" | jq_check
  echo "    CNAME eklendi"
fi

echo
echo "==> 4) Worker deploy: ${WORKER} (service-worker format)"
BINDINGS="[]"
if [ -n "${CLOUDFLARE_KV_NAMESPACE_ID:-}" ]; then
  BINDINGS="[{\"name\":\"KV\",\"type\":\"kv_namespace\",\"namespace_id\":\"${CLOUDFLARE_KV_NAMESPACE_ID}\"}]"
  echo "    KV namespace bagli: ${CLOUDFLARE_KV_NAMESPACE_ID}"
fi
curl -fsS -X PUT \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -F "metadata={\"body_part\":\"worker.js\",\"bindings\":${BINDINGS}};type=application/json" \
  -F 'worker.js=@'"${DIR}/repair-log-worker.js"';type=application/javascript' \
  "${API}/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER}" | jq_check
echo "    worker yuklendi"

if [ -n "${CLOUDFLARE_KV_NAMESPACE_ID:-}" ]; then
  echo
  echo "==> 4b) Zone route: repair.cloudtune.app/* -> ${WORKER}"
  curl -fsS -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"pattern\":\"repair.cloudtune.app/*\",\"script\":\"${WORKER}\"}" \
    "${API}/zones/${ZONE_ID}/workers/routes" | jq_check
  echo "    route eklendi"
fi

echo
if [ -n "${SENDGRID_API_KEY:-}" ]; then
  echo "==> 5) Secret: SENDGRID_API_KEY"
  curl -fsS -X PUT -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"name\":\"SENDGRID_API_KEY\",\"text\":\"${SENDGRID_API_KEY}\"}" \
    "${API}/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER}/secrets" | jq_check
  echo "    secret yazildi"
else
  echo "==> 5) SENDGRID_API_KEY yok - Worker'a sonra Settings > Variables'ten ekleyin"
fi

echo
echo "==> 6) workers.dev ac (custom domain & zone GEREKMEZ):"
curl -fsS -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
  -d '{"enabled":true}' \
  "${API}/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER}/subdomain" | jq_check
echo "    acik -> https://${WORKER}.cloudtune-5b3.workers.dev"

echo
echo "==> 7) Custom domain: ${HOSTNAME} -> ${WORKER}"
echo "    NOT: Workers Domain API token ile calismaz (10405, legacy auth ister)."
echo "    Zone route yukarida (4b) eklendiyse site zaten calisir:"
echo "    curl https://${HOSTNAME}/api/health"
echo "    Alternatif dashboard: Workers > ${WORKER} > Settings > Domains & Routes."

echo
echo "==> Bitti. Testler:"
echo "curl https://cloudtune-repair-log.cloudtune-5b3.workers.dev/api/health"
echo "curl https://${HOSTNAME}/api/health   (zone aktifse)"
echo "curl https://${HOSTNAME}/api/repair-log \\"
echo "  -X POST -H 'Content-Type: application/json' \\"
echo "  -d '{\"event_type\":\"test\",\"message\":\"test from setup\"}'"
echo
echo "ZONE AKTIFLESTIRME (istege bagli, workers.dev icin GEREKMEZ):"
echo "  Durum: $(curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "${API}/zones/${ZONE_ID}" | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['status'])") (api)"
echo "  cloudtune.app CF nameserver'larina yonelmediyse registrar'da (GoDaddy) nameserver degistir:"
echo "  anita.ns.cloudflare.com  +  etienne.ns.cloudflare.com"
echo
echo "KV namespace (opsiyonel ama onerilir):"
echo "  Yan panelde Workers > KV > Create namespace, sonra:"
echo "  export CLOUDFLARE_KV_NAMESPACE_ID='...'  # ve setup'i tekrar calistirin"
echo
echo "EPOSTA AKISI (SENDGRID_API_KEY onerilir):"
echo "  Worker > Settings > Variables/secrets > SENDGRID_API_KEY ekleyin,"
echo "  veya worker kurulumu icin https://sendgrid.com (3.parti)."