#!/usr/bin/env python3
"""flutter create sonrası AndroidManifest.xml'i CloudTune için yamalar.

- İnternet / ön plan servisi / bildirim izinleri
- Arka plan ses servisi (just_audio_background)
- youtu.be, m.youtube.com, youtube.com, www.youtube.com bağlantılarını açma
"""
import re
import sys
from pathlib import Path

MANIFEST = Path(sys.argv[1] if len(sys.argv) > 1 else
                "android/app/src/main/AndroidManifest.xml")
GRADLE = Path("android/app/build.gradle.kts")
PROPS = Path("android/gradle.properties")

HOSTS = ["youtu.be", "m.youtube.com", "youtube.com", "www.youtube.com"]


def patch_min_sdk() -> None:
    """Android 7.0+ destegi: minSdk'i acikca 24 olarak sabitle.

    Literal `minSdk = 24` satiri Flutter migrasyonunda `flutter.minSdkVersion`
    olarak geri yazilir; property tabanli satir migrasyona takilmaz. Flutter
    3.x ve app_links bagimliligi API 24'ten dusuk degeri desteklemez.
    """
    if PROPS.exists():
        text = PROPS.read_text(encoding="utf-8")
        if "cloudtune.minSdk" not in text:
            text += "\n# Flutter 3.x + app_links icin minimum SDK=24 (Android 7.0).\ncloudtune.minSdk=24\n"
            PROPS.write_text(text, encoding="utf-8")
    if GRADLE.exists():
        text = GRADLE.read_text(encoding="utf-8")
        if "cloudtune.minSdk" not in text:
            text = re.sub(
                r"minSdk\s*=\s*flutter\.minSdkVersion",
                'minSdk = (project.property("cloudtune.minSdk") as String).toInt()',
                text,
                count=1,
            )
            GRADLE.write_text(text, encoding="utf-8")


patch_min_sdk()

PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.WAKE_LOCK",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    "android.permission.POST_NOTIFICATIONS",
]

text = MANIFEST.read_text(encoding="utf-8")

if "com.ryanheise.audioservice.AudioService" in text:
    print("Manifest zaten yamalı, atlandı.")
    sys.exit(0)

# 1) İzinler
perm_xml = "".join(
    f'    <uses-permission android:name="{p}"/>\n'
    for p in PERMISSIONS
    if p not in text
)
text = text.replace("<application", perm_xml + "    <application", 1)

# 2) Ana aktivite: ses servisiyle uyumlu sınıf
text = re.sub(
    r'android:name="\.MainActivity"',
    'android:name="com.ryanheise.audioservice.AudioServiceActivity"',
    text,
    count=1,
)

# 3) YouTube bağlantıları için intent-filter
hosts_xml = "\n".join(
    f'                <data android:host="{h}"/>' for h in HOSTS)
intent_filter = f"""            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https"/>
                <data android:scheme="http"/>
{hosts_xml}
            </intent-filter>
"""
text = text.replace("        </activity>", intent_filter + "        </activity>", 1)

# 4) Servis, alıcı ve Flutter'ın kendi derin bağlantı yönlendirmesini kapat
extras = """        <meta-data
            android:name="flutter_deeplinking_enabled"
            android:value="false"/>
        <service
            android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>
        <receiver
            android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>
"""
text = text.replace("    </application>", extras + "    </application>", 1)

# 5) Uygulama adı
text = re.sub(r'android:label="[^"]*"', 'android:label="CloudTune"', text, count=1)

MANIFEST.write_text(text, encoding="utf-8")
print("AndroidManifest.xml yamalandı.")
