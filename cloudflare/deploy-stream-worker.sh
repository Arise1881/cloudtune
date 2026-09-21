#!/usr/bin/env bash
# CloudTune stream relay worker deploy'u — wrangler gerektirmez.
#
# Kullanım:
#   export CLOUDFLARE_API_TOKEN='...' ; bash cloudflare/deploy-stream-worker.sh
#   veya token'ı dosyaya koy:  printf '%s' 'TOKEN' > /tmp/opencode/cf_token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_FILE="$SCRIPT_DIR/stream-proxy.js"
WORKER_NAME="cloudtune-stream"
API="https://api.cloudflare.com/client/v4"

TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f /tmp/opencode/cf_token ]; then
  TOKEN="$(cat /tmp/opencode/cf_token)"
fi
if [ -z "$TOKEN" ]; then
  echo "HATA: CLOUDFLARE_API_TOKEN yok. export ile ya da /tmp/opencode/cf_token dosyasina yaz." >&2
  exit 1
fi
[ -f "$WORKER_FILE" ] || { echo "HATA: $WORKER_FILE yok" >&2; exit 1; }

ACCOUNT_ID="$(
  curl -fsS -H "Authorization: Bearer $TOKEN" "${API}/accounts" |
  python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])"
)"
echo "account: $ACCOUNT_ID"

echo "==> stream relay worker yukleniyor: $WORKER_NAME"
RESP="$(curl -sS -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/javascript" \
  --data-binary @"$WORKER_FILE" \
  "${API}/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}")"
echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print('OK script:', d['result']['id']) if d.get('success') else (print('HATA:', d.get('errors')), sys.exit(1))"

echo "==> workers.dev subdomain aciliyor"
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" \
  "${API}/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" \
  -H "Content-Type: application/json" -d '{"enabled":true}' > /dev/null || true

echo "==>     URL tahmin:"
SUBD="$(
  curl -fsS -H "Authorization: Bearer $TOKEN" "${API}/accounts/${ACCOUNT_ID}/workers/subdomain" |
  python3 -c "import json,sys; print(json.load(sys.stdin)['result']['subdomain'])"
)"
echo "     https://${WORKER_NAME}.${SUBD}.workers.dev  (user-facing)"

# Varsayılan olarak diagnostic endpoint. Token sonrası çalıştır:
if [ "${TEST:-0}" = "1" ]; then
  URL="https://${WORKER_NAME}.${SUBD}.workers.dev"
  echo "==> test ..."
  curl -s -m 15 -o /dev/null -w "health: %{http_code}\n" "$URL/health"
  curl -s -m 30 -H "Range: bytes=0-1023" -o /tmp/opencode/wtest.bin -w "v1/stream: %{http_code} %{size_download}B %{content_type}\n" "$URL/v1/stream/dQw4w9WgXcQ"
  xxd /tmp/opencode/wtest.bin 2>/dev/null | head -1
fi