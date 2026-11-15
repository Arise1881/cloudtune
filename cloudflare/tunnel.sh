#!/usr/bin/env bash
# CloudTune tünel yönetimi — tek tünel: 23d9da7b-178f-424a-8f7d-671c7708445b
set -euo pipefail

TUNNEL_ID="23d9da7b-178f-424a-8f7d-671c7708445b"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/config.yml"
LOG="/tmp/opencode/cloudtune-tunnel.log"
PIDFILE="/tmp/opencode/cloudtune-tunnel.pid"

command -v cloudflared >/dev/null 2>&1 || {
  echo "cloudflared bulunamadi: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" >&2
  exit 1
}

case "${1:-status}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "Tünel zaten calisiyor (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    setsid nohup cloudflared --config "$CONFIG" tunnel run "$TUNNEL_ID" \
      >"$LOG" 2>&1 </dev/null &
    echo $! >"$PIDFILE"
    sleep 2
    echo "Tünel baslatildi (pid $(cat "$PIDFILE")) — log: $LOG"
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "Tünel durduruldu."
    else
      pkill -f "cloudflared.*$TUNNEL_ID" 2>/dev/null || true
      echo "Calisan tünel yok."
    fi
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "calisiyor (pid $(cat "$PIDFILE"))"
    else
      echo "durdu"
    fi
    tail -n 5 "$LOG" 2>/dev/null || true
    ;;
  validate)
    cloudflared --config "$CONFIG" tunnel ingress validate
    ;;
  *)
    echo "Kullanim: $0 {start|stop|status|validate}" >&2
    exit 1
    ;;
esac
