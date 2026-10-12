#!/usr/bin/env python3
"""Yerel YouTube ses relay'i.

Amaç: YouTube'un cihaz-içi (mobil/Dart) isteklerine uyguladığı bot korumasını
aşmak. Relay, yt-dlp ile sesi çözer ve istemciye byte olarak aktarır.

Uç noktalar:
  GET /health                 -> "ok"
  GET /v1/stream/<videoId>    -> "<scheme>://<host>/stream/<videoId>" (URL döner)
  GET /stream/<videoId>       -> yt-dlp ile ses akışını byte byte aktarır
  HEAD /stream/<videoId>      -> 200 (player ön kontrolü için)

Uygulama, Ayarlar > Akış Proxy URL alanına bu sunucunun adresini girer
(ör. http://10.0.2.2:8099 emülatörden host'a, ya da bir https tünel URL'i).

Çalıştırma:
    python3 relay.py            # varsayılan port 8099
    PORT=9000 python3 relay.py
"""

import http.server
import os
import socketserver
import subprocess
import urllib.parse

YTDLP = os.environ.get("YTDLP", "yt-dlp")
PORT = int(os.environ.get("PORT", "8099"))


def _resolve_scheme_host(headers):
    host = headers.get("Host")
    scheme = headers.get("X-Forwarded-Proto") or (
        "https" if host and "trycloudflare" in host else "http"
    )
    return scheme, host


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")

    def _stream_tail(self):
        return urllib.parse.urlparse(self.path).path[len("/stream/"):]

    def do_HEAD(self):
        if urllib.parse.urlparse(self.path).path.startswith("/stream/"):
            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", "audio/webm")
            self.send_header("Accept-Ranges", "none")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            self._write_text(200, "ok")
            return
        if path.startswith("/v1/stream/"):
            vid = path[len("/v1/stream/"):]
            scheme, host = _resolve_scheme_host(self.headers)
            self._write_text(200, f"{scheme}://{host}/stream/{vid}")
            return
        if path.startswith("/stream/"):
            self._pipe_ytdlp(self._stream_tail())
            return
        self.send_response(404)
        self.end_headers()

    def _write_text(self, code, body):
        data = body.encode()
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _pipe_ytdlp(self, vid):
        watch = f"https://www.youtube.com/watch?v={vid}"
        proc = subprocess.Popen(
            [YTDLP, "--no-warnings", "--no-playlist",
             "-f", "bestaudio/best", "-o", "-", watch],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "audio/webm")
        self.send_header("Accept-Ranges", "none")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            try:
                proc.kill()
            except Exception:
                pass

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    print(f"CloudTune relay listening on :{PORT} (yt-dlp={YTDLP})")
    Server(("0.0.0.0", PORT), Handler).serve_forever()
