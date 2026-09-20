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
echo "==> 4) Worker deploy: ${WORKER}"
curl -fsS -X PUT \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -F "main.js=@${DIR}/repair-log-worker.js;type=application/javascript+module" \
  -F "metadata={\"body_part\":\"main.js\",\"bindings\":[]};type=application/json" \
  "${API}/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER}" >/dev/null
echo "    worker yuklendi"

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
echo "==> 6) Custom domain: ${HOSTNAME} -> ${WORKER}"
step6() (
  set -o pipefail
  curl -fsS -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"hostname\":\"${HOSTNAME}\",\"service\":\"${WORKER}\",\"environment\":\"production\",\"zone_id\":\"${ZONE_ID}\"}" \
    "${API}/accounts/${ACCOUNT_ID}/workers/domains"
)
set +e
R=$(step6)
set -e
echo "$R" | jq_check
DID=$(echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('id','ALREADY')) if d.get('success') else print('')")
if [ -n "$DID" ]; then echo "    domain baglandi: ${DID}"; fi

echo
echo "==> Bitti. Test:"
echo "curl https://${HOSTNAME}/api/repair-log \\"
echo "  -X POST -H 'Content-Type: application/json' \\"
echo "  -d '{\"event_type\":\"test\",\"message\":\"test from setup\"}'"