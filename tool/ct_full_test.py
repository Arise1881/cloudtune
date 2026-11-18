#!/usr/bin/env python3
"""CloudTune emulator full test harness.

Tek komutla uninstall -> install -> izin -> deep link -> etkileşimler ->
logcat crash taraması -> UI hata taraması -> audio/media_session dökümü ->
ekran görüntüleri üretir. Tüm çıktı OUT altına, özet JSON raporu
OUT/report.json dosyasına yazılır.

Kullanim:
  ADB_SERIAL=emulator-5554 python3 tool/ct_full_test.py \
      --apk build/app/outputs/flutter-apk/app-debug.apk

  python3 tool/ct_full_test.py --apk <debug-apk> --serial emulator-5556 \
      --wait 30 --search-text "lofi" --action-delay 2
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

PACKAGE = "com.cloudtune.app"
DEEP_LINK = "cloudtune://test/play"
OUT = Path("/tmp/opencode/cloudtune-emulator-test")

# uiautomator her adimda AndroidRuntime'i normal sekilde baslatir; yalnizca
# gercek fatal/exception satirlari crash sayilir.
CRASH_RE = re.compile(
    r"(FATAL EXCEPTION|E AndroidRuntime:.*(?:Exception|Error)|"
    r"MissingPluginException|Unhandled Exception|"
    r"E/flutter(?:[\s:\[]|$))",
    re.IGNORECASE,
)
# Test parcalarinin sahte kapaklari 404 donebilir; bu bir uygulama hatasi
# degildir ve crash sayilmamalidir.
IGNORE_LOG_RE = re.compile(
    r"(Error loading artUri|FlutterImageDecoderImplDefault|hqdefault\.jpg)",
    re.IGNORECASE,
)
UI_ERROR_RE = re.compile(r"(parça\s+oynatılamadı|oynatılamadı)", re.IGNORECASE)

SHUFFLE_PATTERNS = ("shuffle", "karıştır", "karistir", "rastgele", "shuffle_mode")
REPEAT_PATTERNS = ("repeat", "tekrar", "loop", "repeat_mode")
PLAYLIST_PATTERNS = (
    "oluşturulan çalma listeleri",
    "çalma listeleri",
    "çalma listesi",
    "playlist",
    "kitaplığım",
    "listelerim",
)
ROOM_PATTERNS = ("odalar", "oda", "room", "groups")
MIC_PATTERNS = ("sesle ara", "dinlemeyi durdur", "mikrofon", "mic", "voice")
SEARCH_PATTERNS = ("şarkı ara", "youtube bağlantısı", "ara", "search", "edittext")

DEFAULT_RESOLUTION = (1080, 1920)
BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


# ---------------------------------------------------------------------------
# Temel adb / yardımcı fonksiyonlar
# ---------------------------------------------------------------------------


def run(cmd: list[str], *, timeout: int = 60, check: bool = False):
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"Komut zaman aşımı ({' '.join(cmd)}): {exc}") from exc
    except OSError as exc:
        raise RuntimeError(f"Komut başlatılamadı ({' '.join(cmd)}): {exc}") from exc
    if check and result.returncode != 0:
        raise RuntimeError(
            f"Komut başarısız ({' '.join(cmd)}):\n{result.stdout}\n{result.stderr}"
        )
    return result


def adb(serial: str, *args: str, timeout: int = 60):
    return run(["adb", "-s", serial, *args], timeout=timeout)


def adb_bytes(serial: str, *args: str, timeout: int = 60):
    try:
        return subprocess.run(
            ["adb", "-s", serial, *args],
            capture_output=True,
            timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise RuntimeError(f"adb exec-out başarısız: {exc}") from exc


def wait_for_device(serial: str, timeout: int = 120) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = adb(serial, "get-state", timeout=10).stdout.strip()
        if last == "device":
            return last
        time.sleep(2)
    raise TimeoutError(f"{serial} hazir olmadi (son durum: {last!r})")


def wait_for_boot(serial: str, timeout: int = 180) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = adb(serial, "shell", "getprop", "sys.boot_completed", timeout=10).stdout.strip()
        if last == "1":
            return last
        time.sleep(2)
    raise TimeoutError(f"Emulator boot tamamlanmadi (sys.boot_completed={last!r})")


def screen_size(serial: str) -> tuple[int, int]:
    out = adb(serial, "shell", "wm", "size", timeout=10).stdout
    sizes = re.findall(r"(?:Override|Physical) size:\s*(\d+)x(\d+)", out)
    if sizes:
        w, h = sizes[-1]
        return int(w), int(h)
    return DEFAULT_RESOLUTION


def ui_nodes(xml: str) -> list[dict[str, str]]:
    """uiautomator XML -> attribute sözlükleri (bozuk XML'e dayanıklı)."""
    nodes: list[dict[str, str]] = []
    try:
        root = ET.fromstring(xml)
        nodes = [dict(el.attrib) for el in root.iter("node")]
    except ET.ParseError:
        for chunk in re.findall(r"<node\b[^>]*>", xml):
            nodes.append(dict(re.findall(r'([\w:-]+)="([^"]*)"', chunk)))
    return nodes


def parse_bounds(raw: str) -> tuple[int, int, int, int] | None:
    match = BOUNDS_RE.search(raw or "")
    if not match:
        return None
    x1, y1, x2, y2 = (int(v) for v in match.groups())
    return x1, y1, x2, y2


def find_target(
    xml: str,
    patterns: tuple[str, ...],
    resolution: tuple[int, int],
    *,
    class_hint: str | None = None,
    prefer_clickable: bool = True,
    fallback: tuple[int, int] | None = None,
) -> dict[str, Any]:
    """UI dump'ta text/content-desc/resource-id ara; yoksa koordinat döndür."""
    pats = [p.casefold() for p in patterns if p]
    best: dict[str, Any] | None = None
    best_score = 0

    for attrs in ui_nodes(xml):
        fields = {
            "text": attrs.get("text", ""),
            "desc": attrs.get("content-desc", ""),
            "id": attrs.get("resource-id", ""),
            "class": attrs.get("class", ""),
        }
        score = 0
        matched = ""
        for key, value in fields.items():
            folded = value.casefold()
            if not folded:
                continue
            for pattern in pats:
                if pattern in folded:
                    score += 3 if key in ("text", "desc") else 1
                    if not matched:
                        matched = f"{key}='{value}'"
                    break
        if class_hint and class_hint.casefold() in fields["class"].casefold():
            score += 2
        if prefer_clickable and attrs.get("clickable") == "true":
            score += 1

        bounds = parse_bounds(attrs.get("bounds", ""))
        if score > best_score and bounds:
            x1, y1, x2, y2 = bounds
            best_score = score
            best = {
                "x": (x1 + x2) // 2,
                "y": (y1 + y2) // 2,
                "method": "ui_dump",
                "match": matched,
            }

    if best is not None:
        return best
    if fallback is not None:
        return {
            "x": fallback[0],
            "y": fallback[1],
            "method": "fallback",
            "match": "",
        }
    raise RuntimeError(f"UI'da hedef bulunamadi: {patterns}")


def describe(target: dict[str, Any]) -> str:
    suffix = f" [{target['match']}]" if target.get("match") else ""
    return f"{target['method']}@{target['x']},{target['y']}{suffix}"


def encode_input_text(text: str) -> str:
    """`input text` için ASCII-güvenli gösterim (boşluk -> %s)."""
    encoded = []
    for char in text:
        if char == " ":
            encoded.append("%s")
        elif char.isascii() and char.isalnum():
            encoded.append(char)
    return "".join(encoded) or "test"


def extract_ui_errors(xml: str) -> list[str]:
    errors: list[str] = []
    for attrs in ui_nodes(xml):
        text = attrs.get("text", "") or attrs.get("content-desc", "")
        if text and UI_ERROR_RE.search(text):
            errors.append(text)
    return errors


# ---------------------------------------------------------------------------
# Ana akış
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, help="Debug APK yolu")
    parser.add_argument(
        "--serial",
        default=os.environ.get("ADB_SERIAL", "emulator-5554"),
        help="ADB serial (veya ADB_SERIAL ortam değişkeni)",
    )
    parser.add_argument(
        "--wait", type=int, default=25, help="Deep link sonrası bekleme (saniye)"
    )
    parser.add_argument(
        "--action-delay",
        type=float,
        default=1.5,
        help="Etkileşimler arası bekleme (saniye)",
    )
    parser.add_argument(
        "--search-text",
        default="cloudtune test",
        help="Arama alanına yazılacak metin (ASCII önerilir)",
    )
    parser.add_argument(
        "--out", type=Path, default=OUT, help="Çıktı dizini (varsayılan: %s)" % OUT
    )
    args = parser.parse_args()

    apk = Path(args.apk)
    if not apk.exists():
        print(f"APK bulunamadi: {apk}", file=sys.stderr)
        return 2
    if shutil.which("adb") is None:
        print("adb bulunamadi; Android SDK platform-tools PATH icinde olmali.", file=sys.stderr)
        return 2

    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "serial": args.serial,
        "apk": str(apk),
        "started_at": datetime.now(timezone.utc).isoformat(),
        "steps": [],
        "crashes": [],
        "ui_playback_errors": [],
        "screenshots": [],
        "ui_dumps": [],
        "interactions": {},
        "dumpsys": {},
    }
    all_xml: list[str] = []
    action_delay = max(0.2, args.action_delay)
    exit_code = 1

    def step(name: str, ok: bool, detail: str = "") -> None:
        report["steps"].append({"name": name, "ok": bool(ok), "detail": detail})
        print(f"[{'OK' if ok else 'FAIL'}] {name} {detail}".rstrip(), flush=True)

    def do(name: str, fn: Callable[[], tuple[bool, str]]) -> bool:
        try:
            ok, detail = fn()
        except Exception as exc:  # her adım bağımsız devam etsin
            ok, detail = False, f"{type(exc).__name__}: {exc}"
        step(name, ok, detail)
        return bool(ok)

    def shot(name: str) -> str:
        png = out / f"{name}.png"
        raw = adb_bytes(args.serial, "exec-out", "screencap", "-p", timeout=30)
        png.write_bytes(raw.stdout)
        size = png.stat().st_size
        report["screenshots"].append(str(png))
        return f"{png.name} ({size} bytes)"

    def dump(name: str) -> str:
        remote = f"/sdcard/window_ct_{name}.xml"
        adb(args.serial, "shell", "rm", "-f", remote, timeout=10)
        adb(args.serial, "shell", "uiautomator", "dump", remote, timeout=45)
        xml = adb(args.serial, "shell", "cat", remote, timeout=20).stdout
        (out / f"{name}.xml").write_text(xml, encoding="utf-8", errors="replace")
        report["ui_dumps"].append(str(out / f"{name}.xml"))
        all_xml.append(xml)
        return xml

    def tap(target: dict[str, Any]) -> str:
        adb(
            args.serial,
            "shell",
            "input",
            "tap",
            str(target["x"]),
            str(target["y"]),
            timeout=15,
        )
        return describe(target)

    def long_press(target: dict[str, Any], hold_ms: int = 800) -> str:
        # Aynı noktaya swipe: basılı tut + bırak. MikrofonGestureDetector
        # onTapDown/onTapUp akışını tetikler.
        adb(
            args.serial,
            "shell",
            "input",
            "swipe",
            str(target["x"]),
            str(target["y"]),
            str(target["x"]),
            str(target["y"]),
            str(hold_ms),
            timeout=20,
        )
        return f"{describe(target)} hold={hold_ms}ms"

    last_xml = ""

    try:
        wait_for_device(args.serial)
        boot = wait_for_boot(args.serial)
        step("emulator_ready", True, f"sys.boot_completed={boot}")

        width, height = screen_size(args.serial)
        report["screen_size"] = f"{width}x{height}"
        res = (width, height)

        adb(args.serial, "logcat", "-c", timeout=20)
        # Uygulama aciksa pm uninstall DELETE_FAILED_INTERNAL_ERROR verir.
        adb(args.serial, "shell", "am", "force-stop", PACKAGE, timeout=20)
        uninstall = adb(args.serial, "shell", "pm", "uninstall", PACKAGE, timeout=45)
        if "Failure" in uninstall.stdout:
            uninstall = adb(
                args.serial, "shell", "pm", "uninstall", PACKAGE, timeout=45
            )
        uninstall_ok = "Failure" not in uninstall.stdout
        step(
            "uninstall",
            uninstall_ok,
            uninstall.stdout.strip() or "paket yoktu",
        )

        install = adb(args.serial, "install", "-r", str(apk), timeout=180)
        install_ok = "Success" in install.stdout
        install_lines = install.stdout.strip().splitlines()
        do(
            "install",
            lambda: (
                install_ok,
                (install_lines[-1] if install_lines else "") or "install",
            ),
        )
        if not install_ok:
            raise RuntimeError(
                "APK kurulamadi, etkileşimler atlandi: "
                f"{(install.stdout + install.stderr).strip()[-500:]}"
            )

        grant = adb(
            args.serial,
            "shell",
            "pm",
            "grant",
            PACKAGE,
            "android.permission.RECORD_AUDIO",
            timeout=30,
        )
        report["mic_permission_granted"] = grant.returncode == 0
        step("mic_permission_grant", grant.returncode == 0, grant.stderr.strip())

        start = adb(
            args.serial,
            "shell",
            "am",
            "start",
            "-a",
            "android.intent.action.VIEW",
            "-d",
            DEEP_LINK,
            timeout=30,
        )
        # `am start` hata mesajina ragmen 0 dondurur; metni de kontrol et.
        start_text = f"{start.stdout}\n{start.stderr}"
        deep_ok = start.returncode == 0 and "Error:" not in start_text
        step("deep_link_start", deep_ok, start_text.strip().splitlines()[-1:] and start_text.strip().splitlines()[-1] or "")

        time.sleep(args.wait)
        step("settle", True, f"{args.wait}s")

        # --- Etkileşim adımları -------------------------------------------
        # Koordinat fallback'leri ekran oranına göre hesaplanır; UI dump'ta
        # text/content-desc bulge gelirse gerçek node merkezi kullanılır.

        def act_home() -> tuple[bool, str]:
            nonlocal last_xml
            last_xml = dump("01_home")
            png = shot("01_home")
            loaded = bool(last_xml.strip()) and any(
                p in last_xml.casefold()
                for p in ("ana sayfa", "şarkı ara", "cloudtune", "şimdi")
            )
            return loaded, png

        do("home_loaded", act_home)

        def act_search() -> tuple[bool, str]:
            nonlocal last_xml
            target = find_target(
                last_xml,
                SEARCH_PATTERNS,
                res,
                class_hint="EditText",
                fallback=(int(width * 0.42), int(height * 0.105)),
            )
            tap(target)
            # Ana sayfadaki arama ikonu Search sekmesine geçip alanı odaklar;
            # TextField'ın ağaçta oluşması için bir kare beklenir.
            time.sleep(action_delay)
            adb(
                args.serial,
                "shell",
                "input",
                "text",
                encode_input_text(args.search_text),
                timeout=15,
            )
            adb(args.serial, "shell", "input", "keyevent", "66", timeout=15)
            time.sleep(action_delay)
            last_xml = dump("02_search")
            png = shot("02_search")
            report["interactions"]["search"] = {
                "query": args.search_text,
                "target": target,
            }
            return True, f"query={args.search_text!r} {describe(target)} {png}"

        do("search_type_enter", act_search)

        def act_mic() -> tuple[bool, str]:
            nonlocal last_xml
            target = find_target(
                last_xml,
                MIC_PATTERNS,
                res,
                fallback=(int(width * 0.92), int(height * 0.105)),
            )
            gesture = long_press(target, 800)
            time.sleep(action_delay)
            last_xml = dump("03_mic")
            png = shot("03_mic")
            report["interactions"]["mic_long_press"] = {
                "target": target,
                "gesture": gesture,
                "permission_granted": report["mic_permission_granted"],
            }
            return True, f"{gesture} {png}"

        do("mic_long_press", act_mic)

        def ensure_player_page() -> str:
            nonlocal last_xml
            if any(
                p in last_xml.casefold()
                for p in ("şimdi çalıyor", *SHUFFLE_PATTERNS, *REPEAT_PATTERNS)
            ):
                return "already_open"
            mini = find_target(
                last_xml,
                ("şimdi çalıyor", "mini player", "oynat"),
                res,
                fallback=(int(width * 0.50), int(height * 0.925)),
            )
            tap(mini)
            time.sleep(action_delay)
            last_xml = dump("04_player_open")
            return describe(mini)

        def act_shuffle() -> tuple[bool, str]:
            nonlocal last_xml
            opened = ensure_player_page()
            target = find_target(
                last_xml,
                SHUFFLE_PATTERNS,
                res,
                fallback=(int(width * 0.18), int(height * 0.80)),
            )
            tap(target)
            time.sleep(action_delay)
            last_xml = dump("04_shuffle")
            png = shot("04_shuffle")
            report["interactions"]["shuffle"] = {"target": target, "player": opened}
            return True, f"{describe(target)} player={opened} {png}"

        do("shuffle_tap", act_shuffle)

        def act_repeat() -> tuple[bool, str]:
            nonlocal last_xml
            target = find_target(
                last_xml,
                REPEAT_PATTERNS,
                res,
                fallback=(int(width * 0.82), int(height * 0.80)),
            )
            tap(target)
            time.sleep(action_delay)
            last_xml = dump("05_repeat")
            png = shot("05_repeat")
            report["interactions"]["repeat"] = {"target": target}
            return True, f"{describe(target)} {png}"

        do("repeat_tap", act_repeat)

        def act_playlist() -> tuple[bool, str]:
            nonlocal last_xml
            target = find_target(
                last_xml,
                PLAYLIST_PATTERNS,
                res,
                fallback=(int(width * 0.625), int(height * 0.95)),
            )
            tap(target)
            time.sleep(action_delay)
            last_xml = dump("06_playlist")
            png = shot("06_playlist")
            report["interactions"]["playlist_tab"] = {"target": target}
            return True, f"{describe(target)} {png}"

        do("playlist_tab", act_playlist)

        def act_room() -> tuple[bool, str]:
            nonlocal last_xml
            target = find_target(
                last_xml,
                ROOM_PATTERNS,
                res,
                fallback=(int(width * 0.375), int(height * 0.95)),
            )
            tap(target)
            time.sleep(action_delay)
            last_xml = dump("07_room")
            png = shot("07_room")
            report["interactions"]["room_tab"] = {"target": target}
            return True, f"{describe(target)} {png}"

        do("room_tab", act_room)

        def act_home_return() -> tuple[bool, str]:
            nonlocal last_xml
            target = find_target(
                last_xml,
                ("ana sayfa", "home"),
                res,
                fallback=(int(width * 0.125), int(height * 0.95)),
            )
            tap(target)
            time.sleep(action_delay)
            last_xml = dump("08_home_return")
            png = shot("08_home_return")
            return True, f"{describe(target)} {png}"

        do("home_return", act_home_return)

        # --- Ses akışı / media session ------------------------------------
        def act_audio() -> tuple[bool, str]:
            audio = adb(args.serial, "shell", "dumpsys", "audio", timeout=45).stdout
            media = adb(
                args.serial, "shell", "dumpsys", "media_session", timeout=45
            ).stdout
            (out / "dumpsys_audio.txt").write_text(audio, encoding="utf-8", errors="replace")
            (out / "dumpsys_media_session.txt").write_text(
                media, encoding="utf-8", errors="replace"
            )
            report["dumpsys"] = {"audio": audio, "media_session": media}

            playing = "state=PlaybackState" in media and "active" in media.casefold()
            has_output = (
                "AudioPlaybackConfiguration" in audio or "player piid" in audio
            )
            report["media_session_active"] = playing
            report["audio_output_detected"] = has_output
            return has_output, f"audio={len(audio)}B media={len(media)}B active={playing}"

        do("audio_media_dumps", act_audio)

        # --- Hata taraması -------------------------------------------------
        def act_crash_scan() -> tuple[bool, str]:
            logcat = adb(
                args.serial, "logcat", "-d", "-v", "threadtime", timeout=45
            ).stdout
            lines = logcat.splitlines()
            crashes = [
                line
                for line in lines
                if CRASH_RE.search(line) and not IGNORE_LOG_RE.search(line)
            ]
            report["crashes"] = crashes[-40:]
            report["crash_count"] = len(crashes)
            (out / "logcat.txt").write_text(
                "\n".join(lines), encoding="utf-8", errors="replace"
            )
            return not crashes, f"{len(crashes)} suspicious line"

        do("no_crash", act_crash_scan)

        def act_ui_error_scan() -> tuple[bool, str]:
            errors: list[str] = []
            for xml in all_xml:
                for text in extract_ui_errors(xml):
                    if text not in errors:
                        errors.append(text)
            report["ui_playback_errors"] = errors
            return not errors, (
                "temiz" if not errors else " | ".join(errors[:3])
            )

        do("no_ui_playback_error", act_ui_error_scan)

        def act_final_shot() -> tuple[bool, str]:
            final_xml = dump("09_final")
            png = shot("09_final")
            return bool(final_xml.strip()), png

        do("final_screenshot", act_final_shot)

    except KeyboardInterrupt:
        step("aborted", False, "KeyboardInterrupt")
        exit_code = 130
    except Exception as exc:
        step("fatal", False, f"{type(exc).__name__}: {exc}")
        exit_code = 2
    else:
        exit_code = 0
    finally:
        failed = [s for s in report["steps"] if not s["ok"]]
        report["failed_count"] = len(failed)
        report["ok"] = not failed
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        (out / "report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    print(f"\nRapor: {out / 'report.json'}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
