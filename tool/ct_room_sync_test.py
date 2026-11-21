#!/usr/bin/env python3
"""Two-device CloudTune room sync harness.

Runs the real app on two Android devices/emulators and checks that a shared
room: plays the same track, converges playback position, and propagates
pause / seek / next / add / remove from either side.

Usage:
  python3 tool/ct_room_sync_test.py full [--apk build/app/outputs/flutter-apk/app-debug.apk]
  python3 tool/ct_room_sync_test.py verify ROOM
  python3 tool/ct_room_sync_test.py publish ROOM ACTION [JSON_PAYLOAD]

Defaults: emulator-5554 = host, emulator-5556 = guest.
Override with CT_DEVICE_A / CT_DEVICE_B. MQTT commands require paho-mqtt.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid

RELAY_HOST = "test.mosquitto.org"
RELAY_PORT = 8081
TOPIC_PREFIX = "cloudtune/rooms/v1"
EMPTY_PASSWORD_HASH = "811c9dc5"  # FNV-1a of ""

A = os.environ.get("CT_DEVICE_A", "emulator-5554")
B = os.environ.get("CT_DEVICE_B", "emulator-5556")
APK = None


def adb_binary():
    found = shutil.which("adb")
    if found:
        return found
    for base in (
        os.environ.get("ANDROID_HOME"),
        os.environ.get("ANDROID_SDK_ROOT"),
        "/home/msi/android-sdk",
    ):
        if base:
            candidate = os.path.join(base, "platform-tools", "adb")
            if os.path.exists(candidate):
                return candidate
    raise SystemExit("adb bulunamadı. PATH veya ANDROID_HOME ayarlayın.")


ADB = adb_binary()


def adb(dev, *args, timeout=45):
    proc = subprocess.run(
        [ADB, "-s", dev, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.stdout


def ui_xml(dev):
    adb(dev, "shell", "uiautomator", "dump", "/sdcard/ct_ui.xml")
    return adb(dev, "shell", "cat", "/sdcard/ct_ui.xml")


def descs(dev):
    xml = ui_xml(dev).replace("><", ">\n<")
    return re.findall(r'content-desc="([^"]*)"', xml)


def ui_text(dev):
    """Visible text nodes. Chat messages are Text, not content-desc."""
    xml = ui_xml(dev).replace("><", ">\n<")
    return re.findall(r'text="([^"]*)"', xml)


def scroll_to_bottom(dev):
    match = re.search(r"(\d+)x(\d+)", adb(dev, "shell", "wm", "size"))
    if not match:
        return
    width, height = int(match.group(1)), int(match.group(2))
    x = width // 2
    adb(
        dev,
        "shell",
        "input",
        "swipe",
        str(x),
        str(int(height * 0.78)),
        str(x),
        str(int(height * 0.28)),
        "300",
    )


def chat_field(dev):
    boxes = edit_boxes(dev)
    if not boxes:
        for _ in range(6):
            scroll_to_bottom(dev)
            time.sleep(1)
            boxes = edit_boxes(dev)
            if boxes:
                break
    if not boxes:
        return None
    box = boxes[-1]
    send = bounds(dev, "Gönder")
    # Flutter, sohbet listesini de EditText semantik kutusuna dahil ediyor;
    # kutunun merkezi listeye düşer. Gerçek giriş satırı Gönder düğmesiyle
    # aynı yüksekliktedir.
    if send is not None:
        return ((box[0] + box[2]) // 2, send[1])
    return ((box[0] + box[2]) // 2, (box[1] + box[3]) // 2)


def send_chat(dev, text):
    field = chat_field(dev)
    if field is None:
        return False
    clear_type(dev, field, text)
    send = bounds(dev, "Gönder")
    if send is None:
        return False
    tap(dev, send)
    time.sleep(2)
    return text in " | ".join(descs(dev) + ui_text(dev))


def bounds(dev, text):
    xml = ui_xml(dev).replace("><", ">\n<")
    for line in xml.splitlines():
        if f'content-desc="{text}"' in line or f'text="{text}"' in line:
            match = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', line)
            if match:
                x1, y1, x2, y2 = map(int, match.groups())
                return (x1 + x2) // 2, (y1 + y2) // 2
    return None


def tap(dev, point):
    adb(dev, "shell", "input", "tap", str(point[0]), str(point[1]))


def edit_boxes(dev):
    """Raw bounds of visible EditText widgets, in document order."""
    xml = ui_xml(dev).replace("><", ">\n<")
    boxes = []
    for line in xml.splitlines():
        if "android.widget.EditText" not in line or 'NAF="true"' in line:
            continue
        match = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', line)
        if match:
            boxes.append(tuple(map(int, match.groups())))
    return boxes


def edit_fields(dev):
    """Centers of visible EditText widgets, in document order."""
    return [((box[0] + box[2]) // 2, (box[1] + box[3]) // 2) for box in edit_boxes(dev)]


def clear_type(dev, point, text):
    tap(dev, point)
    adb(dev, "shell", "input", "keyevent", "123")
    for _ in range(45):
        adb(dev, "shell", "input", "keyevent", "67")
    # `input text` boşluğu ayırıcı sanıp sonrasını kesiyor; %s kullanılmalı.
    adb(dev, "shell", "input", "text", text.replace(" ", "%s"))
    adb(dev, "shell", "input", "keyevent", "111")


def start_app(dev):
    adb(dev, "shell", "am", "start", "-n", "com.cloudtune.app/.MainActivity")
    time.sleep(7)


def rooms_tab(dev):
    # Kitaplık ayrı bir rotaysa önce geri dön; Odalar sekmesine dokunmak
    # bu durumda sayfayı değiştirmez.
    current = descs(dev)
    if any("Dinleme Geçmişi" in item or "Beğenilenler" in item for item in current):
        back = bounds(dev, "Back")
        if back:
            tap(dev, back)
            time.sleep(1)
    point = bounds(dev, "Odalar")
    if point is None:
        point = bounds(dev, "Odalar (Beta)")
    if point is None:
        point = (618, 223) if dev == A else (2208, 120)
    tap(dev, point)
    time.sleep(2)


def library_tab(dev):
    point = bounds(dev, "Kitaplığım")
    if point is None:
        point = (810, 372) if dev == A else (1920, 234)
    tap(dev, point)
    time.sleep(2)


def create_room(dev, display_name, room_name):
    rooms_tab(dev)
    # Sabit koordinatlar yerine etiketleri bul: Beta yazısı/yerleşim
    # değişince eski koordinatlar yanlış alana yazıyordu.
    fields = edit_fields(dev)
    name_field = fields[0] if fields else (300, 864)
    clear_type(dev, name_field, display_name)
    # İlk alan yazılınca klavye yerleşimi kayabilir; ikinci koordinatı yeniden oku.
    fields = edit_fields(dev)
    room_field = fields[1] if len(fields) > 1 else (300, 1445)
    clear_type(dev, room_field, room_name)
    time.sleep(1)
    create = bounds(dev, "Odayı kur")
    tap(dev, create or ((540, 1786) if dev == A else (1280, 928)))
    match = None
    text = ""
    # Relay/OTP gecikmesinde 7 sn bazen yetmiyor; oda ekranı gelene kadar bekle.
    for _ in range(10):
        time.sleep(2)
        text = " | ".join(descs(dev))
        match = re.search(r"\b([A-Z0-9]{6})\b", text)
        if match:
            break
    return (match.group(1) if match else None), text


def join_room(dev, code):
    rooms_tab(dev)
    point = None
    xml = ui_xml(dev).replace("><", ">\n<")
    for line in xml.splitlines():
        if code in line:
            match = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', line)
            if match:
                x1, y1, x2, y2 = map(int, match.groups())
                point = ((x1 + x2) // 2, (y1 + y2) // 2)
                break
    if point is None:
        return False
    tap(dev, point)
    time.sleep(1)
    consent = bounds(dev, "İzin ver")
    if consent:
        tap(dev, consent)
    time.sleep(7)
    # Keşif listesindeki kart metni de kodu içerir; yalnızca oda ekranındaki
    # "Katılımcı" başlığı gerçek katılımı doğrular.
    return any(code in item and "Katılımcı" in item for item in descs(dev))


def add_from_library(dev):
    library_tab(dev)
    points = []
    xml = ui_xml(dev).replace("><", ">\n<")
    for line in xml.splitlines():
        if 'content-desc="Odaya ekle"' in line:
            match = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', line)
            if match:
                x1, y1, x2, y2 = map(int, match.groups())
                points.append(((x1 + x2) // 2, (y1 + y2) // 2))
    if not points:
        return False
    tap(dev, points[-1])
    time.sleep(3)
    return True


def media_state(dev):
    """Return first CloudTune playback state: dict(state, position, title)."""
    lines = adb(dev, "shell", "dumpsys", "media_session").splitlines()
    for index, line in enumerate(lines):
        if "package=com.cloudtune.app" not in line:
            continue
        result = {"state": "?", "position": -1, "title": ""}
        # mediaButtonReceiver satırı da "com.cloudtune.app" içerdiğinden eski
        # erken çıkış state satırına hiç ulaşmıyordu. Sabit pencere tara.
        for follow in lines[index + 1 : index + 30]:
            if result["state"] == "?":
                match = re.search(r"\{state=([A-Z]+)\(\d+\)", follow)
                if match:
                    result["state"] = match.group(1)
            if result["position"] < 0:
                match = re.search(r"\bposition=(\d+)", follow)
                if match:
                    result["position"] = int(match.group(1))
            if not result["title"]:
                match = re.search(r"description=([^,]+),", follow)
                if match:
                    result["title"] = match.group(1).strip()
            if result["state"] != "?" and result["position"] >= 0 and result["title"]:
                break
        return result
    return {"state": "?", "position": -1, "title": ""}


def publish_command(room, action, extra=None):
    try:
        import paho.mqtt.client as mqtt
    except ImportError as exc:
        raise SystemExit(
            "MQTT komutları için paho-mqtt gerekli: pip install paho-mqtt"
        ) from exc

    channel = f"{room.upper()}-{EMPTY_PASSWORD_HASH}"
    topic = f"{TOPIC_PREFIX}/{channel}/events"
    now = int(time.time() * 1000)
    client = mqtt.Client(
        client_id=f"ct_harness_{uuid.uuid4().hex[:8]}",
        transport="websockets",
    )
    client.ws_set_options(path="/mqtt")
    client.tls_set()
    client.connect(RELAY_HOST, RELAY_PORT, 60)
    client.loop_start()
    time.sleep(1)
    payload = {
        "id": f"harness_{uuid.uuid4().hex}",
        "action": action,
        "at": now,
        **(extra or {}),
    }
    envelope = {
        "room": room.upper(),
        "channel": channel,
        "type": "command",
        "clientId": f"harness_{uuid.uuid4().hex[:8]}",
        "name": "SyncTest",
        "isHost": False,
        "at": now,
        "payload": payload,
    }
    info = client.publish(topic, json.dumps(envelope), qos=1)
    info.wait_for_publish(5)
    published = info.is_published()
    time.sleep(1)
    client.loop_stop()
    client.disconnect()
    return published


def wait_until(predicate, timeout=20, interval=1, label=""):
    deadline = time.monotonic() + timeout
    last = False
    while time.monotonic() < deadline:
        last = bool(predicate())
        if last:
            return True
        time.sleep(interval)
    print(f"  timeout: {label}")
    return last


def reset_devices():
    for dev in (A, B):
        adb(dev, "shell", "am", "force-stop", "com.cloudtune.app")
        if APK and os.path.exists(APK):
            adb(dev, "install", "-r", APK)
        adb(dev, "logcat", "-c")
        start_app(dev)


def sample_sync(timeout=45, tolerance=250):
    stable = 0
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        states = [media_state(A), media_state(B)]
        positions = [item["position"] for item in states]
        diff = abs(positions[0] - positions[1]) if min(positions) >= 0 else 10**9
        if all(item["state"] == "PLAYING" for item in states) and diff <= tolerance:
            stable += 1
            if stable >= 3:
                return True, diff, states
        else:
            stable = 0
        time.sleep(2)
    return False, diff, states


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(' — ' + detail) if detail else ''}")
    return bool(ok)


def run_full(apk=None):
    global APK
    APK = apk
    results = []
    print(f"Devices: host={A} guest={B}")
    reset_devices()

    code, text = create_room(A, "SyncHost", "SyncRoom")
    results.append(check("room created", bool(code), text[-120:]))
    if not code:
        return 1
    print(f"Room: {code}")

    joined = False
    for _ in range(4):
        if join_room(B, code):
            joined = True
            break
        time.sleep(5)
    results.append(check("guest joined", joined))
    if not joined:
        return 1

    added = add_from_library(A)
    results.append(check("host added track", added))
    if not added:
        return 1

    # Tam sıra tek bir state paketinde gelir; relay gecikmesinde düğme pasif
    # kalır. UI hazır olmadan oynat'a basmak komutu hiç göndermez.
    guest_ready = wait_until(
        lambda: any(d.startswith("Sıra (") for d in descs(B)),
        timeout=30,
        label="guest received shared queue",
    )
    results.append(check("guest sees shared queue", guest_ready))
    if not guest_ready:
        return 1

    play_point = bounds(B, "Oynat")
    if play_point is None:
        play_point = (1280, 1268)
    tap(B, play_point)
    playing = wait_until(
        lambda: all(media_state(d)["state"] == "PLAYING" for d in (A, B)),
        timeout=30,
        label="both playing",
    )
    results.append(check("guest play propagates", playing))
    if not playing:
        return 1

    synced, diff, states = sample_sync()
    results.append(
        check("position converges", synced, f"diff={diff}ms titles={[s['title'] for s in states]}")
    )

    publish_command(code, "pause")
    paused = wait_until(
        lambda: all(media_state(d)["state"] == "PAUSED" for d in (A, B)),
        timeout=15,
        label="both paused",
    )
    results.append(check("pause propagates", paused))

    publish_command(code, "seek", {"positionMs": 30000})
    sought = wait_until(
        lambda: all(abs(media_state(d)["position"] - 30000) < 3000 for d in (A, B)),
        timeout=15,
        label="seek to 30s",
    )
    results.append(check("seek propagates", sought))

    publish_command(
        code,
        "add",
        {
            "track": {
                "id": "synctest_next",
                "title": "Sync Test Next",
                "artist": "SoundHelix",
                "sourceUrl": (
                    "https://www.soundhelix.com/examples/mp3/"
                    "SoundHelix-Song-3.mp3"
                ),
            }
        },
    )
    time.sleep(3)
    rooms_tab(A)
    rooms_tab(B)
    queued = wait_until(
        lambda: all(any("Sıra (2)" in d for d in descs(dev)) for dev in (A, B)),
        timeout=15,
        label="shared queue has 2 tracks",
    )
    results.append(check("add propagates", queued))

    title_before = media_state(A)["title"]
    publish_command(code, "next")
    changed = wait_until(
        lambda: all(media_state(d)["title"] != title_before for d in (A, B)),
        timeout=25,
        label="both advance to next track",
    )
    results.append(
        check(
            "next uses shared queue",
            changed,
            f"titles={[media_state(d)['title'] for d in (A, B)]}",
        )
    )

    publish_command(code, "remove", {"trackId": "cttest02"})
    removed = wait_until(
        lambda: all(any("Sıra (1)" in d for d in descs(dev)) for dev in (A, B)),
        timeout=15,
        label="shared queue back to 1 track",
    )
    results.append(check("remove propagates", removed))

    # Sohbet mesajları Text düğümüdür; content-desc taraması yanlış negatif
    # veriyordu. İki yönü de gerçek UI metninden doğrula.
    rooms_tab(A)
    rooms_tab(B)
    for _ in range(4):
        scroll_to_bottom(B)
        time.sleep(0.5)
    host_sent = send_chat(A, "Selam guest")
    guest_sees = wait_until(
        lambda: "Selam guest" in " | ".join(descs(B) + ui_text(B)),
        timeout=15,
        label="host chat reaches guest",
    )
    results.append(check("host chat propagates", host_sent and guest_sees))

    guest_sent = send_chat(B, "Selam host")
    host_sees = wait_until(
        lambda: "Selam host" in " | ".join(descs(A) + ui_text(A)),
        timeout=15,
        label="guest chat reaches host",
    )
    results.append(check("guest chat propagates", guest_sent and host_sees))

    failed = results.count(False)
    print(f"\nResult: {len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    command = sys.argv[1]
    if command == "full":
        apk = None
        if "--apk" in sys.argv:
            apk = sys.argv[sys.argv.index("--apk") + 1]
        return run_full(apk)
    if command == "verify":
        if len(sys.argv) < 3:
            print("Usage: verify ROOM")
            return 2
        ok, diff, states = sample_sync()
        print(states)
        return 0 if ok else 1
    if command == "publish":
        if len(sys.argv) < 4:
            print("Usage: publish ROOM ACTION [JSON_PAYLOAD]")
            return 2
        extra = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
        return 0 if publish_command(sys.argv[2], sys.argv[3], extra) else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
