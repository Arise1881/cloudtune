#!/usr/bin/env bash
# CloudTune yerel akış relay'ini ve geçici cloudflared tünelini başlatır.
# Tünel URL'i https://<rastgele>.trycloudflare.com biçiminde olur; bu URL'i
# uygulamada Ayarlar > Akış Proxy URL alanına girin (ya da kodda
# MusicService._defaultProxyUrl değerini güncelleyin).
#
# Gereksinimler: python3, yt-dlp (PATH'te), cloudflared.
set -euo pipefail

PORT="${PORT:-8099}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/tmp}"

echo "Relay başlatılıyor (:$PORT)..."
setsid nohup python3 "$HERE/relay.py" \
  >"$LOG_DIR/cloudtune-relay.log" 2>&1 </dev/null &

sleep 2
echo "cloudflared tüneli başlatılıyor..."
setsid nohup cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate \
  >"$LOG_DIR/cloudtune-tunnel.log" 2>&1 </dev/null &

sleep 6
echo "--- Sağlık kontrolü ---"
curl -s --max-time 5 "http://127.0.0.1:$PORT/health" && echo " (yerel relay ok)"

URL="$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudtune-cloudflare.log" 2>/dev/null | tail -1 || true)"
if [ -z "$URL" ]; then
  URL="$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR"/cloudtune-*.log 2>/dev/null | tail -1 || true)"
fi

echo
if [ -n "${URL:-}" ]; then
  echo "Tünel URL: $URL"
  echo "Bu adresi uygulamada Ayarlar > Akış Proxy URL alanına girin:"
  echo "  $URL"
else
  echo "Tünel URL'i loglardan okunamadı; '$LOG_DIR/cloudtune-relay.log' ve"
  echo "cloudflared çıktısını kontrol edin."
fi
