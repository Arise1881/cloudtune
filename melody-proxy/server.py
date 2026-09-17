#!/usr/bin/env python3
"""Melody akış proxy sunucusu.

YouTube artık akış URL'lerini po_token ile koruyor. Bu sunucu, yt-dlp'nin
yerleşik po_token üretimi (VISIONOS client) ile doğrudan googlevideo akış
URL'leri üretir. Melody  önce bu sunucuya sorar, akış alamazsa Invidious'a
düşer.

Endpoints:
  GET /health
  GET /api/v1/stream?video_id=...        -> ses akış URL'leri (JSON)
  GET /api/v1/search?q=...&limit=12      -> şarkı listesi (JSON)

Kurulum:
  python3 -m venv venv
  venv/bin/pip install -U yt-dlp
  venv/bin/python server.py [--port 8800] [--host 0.0.0.0]

Not: yt-dlp'nin tam fonksiyon kalması için bir JS runtime önerilir
(deno veya node). Yoksa yine de VISIONOS client ile akış çözülür.
"""

import json
import time
import os
import re
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

YTDLP = os.environ.get("YTDLP_PATH", "yt-dlp")
AUDIO_FMT = "140/bestaudio"

_MAX_AUDIO = 6  # Tek video için en fazla döndürülecek akış adayı


def _ytdlp_version():
    """yt-dlp sürüm dizesi."""
    proc = subprocess.run(
        [YTDLP, "--version"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    return (proc.stdout or proc.stderr or "?").strip().splitlines()[0][:40] \
        if proc.returncode == 0 else "bilinmiyor"


def _ytdlp_json(args, timeout=90):
    """yt-dlp [-J] çağrısı, JSON çıktı döner."""
    proc = subprocess.run(
        [YTDLP, "-J", "--no-warnings", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()
        raise RuntimeError((tail[-1] if tail else "yt-dlp hata")[:400])
    return json.loads(proc.stdout)


def solve_stream(video_id):
    """Video için po_token destekli ses akış URL'leri üret."""
    info = _ytdlp_json([
        "-f", AUDIO_FMT,
        f"https://www.youtube.com/watch?v={video_id}",
    ])

    fmts = info.get("formats") or []
    urls = []
    itag = info.get("format_id")
    for f in fmts:
        vc = str(f.get("vcodec") or "none")
        ac = str(f.get("acodec") or "none")
        if vc != "none" or ac == "none":
            continue
        if f.get("protocol") not in ("https", "http"):
            continue
        url = f.get("url")
        if not url or "googlevideo" not in url:
            continue
        urls.append({
            "itag": f.get("format_id"),
            "ext": f.get("ext"),
            "abr": f.get("abr"),
            "quality": f.get("quality") or f.get("format_note"),
            "url": url,
        })
    # itag eşleşen (çözülen) önce, sonra kaliteli m4a önce
    urls.sort(key=lambda u: (u["itag"] != itag, u["ext"] != "m4a",
                             -(u["abr"] or 0)))
    urls = urls[:_MAX_AUDIO]

    print(f"[{time.strftime('%H:%M:%S')}] stream {video_id}: fmt={AUDIO_FMT} secilen={info.get('format_id')} nfmt={len(fmts)} urls={[u['itag'] for u in urls]}", flush=True)

    if not urls:
        raise RuntimeError("ses akışı bulunamadı")

    return {
        "title": info.get("title"),
        "duration": info.get("duration"),
        "thumbnail": (info.get("thumbnail") or ""),
        "channel": info.get("channel") or info.get("uploader"),
        "urls": urls,
    }


def search(query, limit=12):
    """yt-dlp ytsearch ile şarkı listesi (id, başlık, kanal, kapak)."""
    info = _ytdlp_json([
        "--flat-playlist", "ytsearch%d:%s" % (limit, query),
    ], timeout=60)
    songs = []
    for e in info.get("entries") or []:
        vid = e.get("id")
        if not vid:
            continue
        th = e.get("thumbnail") or ""
        try:
            th = next(
                (t.get("url", "") for t in (e.get("thumbnails") or [])
                 if t.get("url")),
                th,
            )
        except Exception:
            pass
        songs.append({
            "videoId": vid,
            "title": e.get("title"),
            "channel": e.get("channel") or e.get("uploader"),
            "duration": e.get("duration"),
            "thumbnail": th,
            "url": "https://www.youtube.com/watch?v=%s" % vid,
        })
    return {"songs": songs}


class Handler(BaseHTTPRequestHandler):
    server_version = "MelodyProxy/1.0"

    def log_message(self, fmt, *args):  # sessiz log
        pass

    def _relay(self, video_id, fmt):
        """yt-dlp akışını sunucu üzerinden doğrudan ileter: telefon
        googlevideo CDN'ine hiç bağlanmaz — operatör engelini aşar."""
        url = f"https://www.youtube.com/watch?v={video_id}"
        proc = subprocess.Popen(
            [
                YTDLP, "--no-warnings", "--no-playlist", "-q",
                "-f", fmt, "-o", "-", "--buffer-size", "2M", url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        self.send_response(200)
        self.send_header(
            "Content-Type", "audio/webm" if fmt == "251" else "audio/mp4")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            proc.kill()

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg):
        self._send(code, {"ok": False, "error": msg})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_GET(self):
        try:
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)
            print(f"[{time.strftime('%H:%M:%S')}] {self.client_address[0]} GET {u.path}", flush=True)
        except Exception:
            pass
        try:
            if u.path == "/health":
                return self._send(200, {
                    "ok": True,
                    "service": "melody-proxy",
                    "ytdlp": {
                        "version": _ytdlp_version(),
                        "path": YTDLP,
                    },
                })

            if u.path == "/api/v1/stream":
                vid = (q.get("video_id") or [""])[0]
                # YouTube video kimlikleri: 11 karakter, harf/rakam/_/- izinli.
                if not vid or not re.fullmatch(r"[A-Za-z0-9_-]{6,15}", vid):
                    return self._err(400, "geçersiz video_id")
                return self._send(200, {"ok": True, **solve_stream(vid)})

            if u.path == "/api/v1/relay":
                vid = (q.get("video_id") or [""])[0]
                if not vid or not re.fullmatch(r"[A-Za-z0-9_-]{6,15}", vid):
                    return self._err(400, "geçersiz video_id")
                fmt = (q.get("format") or ["140"])[0]
                if fmt not in ("139", "140", "251"):
                    fmt = "140"
                self._relay(vid, fmt)
                return

            if u.path == "/api/v1/stream_direct":
                vid = (q.get("video_id") or [""])[0]
                if not vid or not re.fullmatch(r"[A-Za-z0-9_-]{6,15}", vid):
                    return self._err(400, "geçersiz video_id")
                data = solve_stream(vid)
                urls = data.get("urls") or []
                if not urls:
                    return self._err(502, "akış URL'si yok")
                self.send_response(302)
                self.send_header("Location", urls[0]["url"])
                self.end_headers()
                return

            if u.path == "/api/v1/search":
                query = (q.get("q") or [""])[0].strip()
                try:
                    limit = max(1, min(30, int((q.get("limit") or ["12"])[0])))
                except ValueError:
                    limit = 12
                if not query:
                    return self._err(400, "eksik q parametresi")
                return self._send(200, {"ok": True, **search(query, limit)})

            return self._err(404, "bilinmeyen endpoint")
        except subprocess.TimeoutExpired:
            return self._err(504, "yt-dlp zaman aşımı")
        except Exception as e:
            return self._err(500, str(e))


def main():
    host = sys.argv[sys.argv.index("--host") + 1] if "--host" in sys.argv else "0.0.0.0"
    port = 8800
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    elif "MELODY_PORT" in os.environ:
        port = int(os.environ["MELODY_PORT"])

    server = ThreadingHTTPServer((host, port), Handler)
    print("Melody proxy: http://%s:%d (yt-dlp %s)" % (host, port, _ytdlp_version()))
    server.serve_forever()


if __name__ == "__main__":
    main()