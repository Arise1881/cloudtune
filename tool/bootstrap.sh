#!/usr/bin/env bash
# Android platform dosyalarını üretir ve CloudTune için yamalar.
# Kullanım (proje kökünde): bash tool/bootstrap.sh
set -euo pipefail

TMP="$(mktemp -d)"
cp pubspec.yaml "$TMP/pubspec.yaml"
cp -r lib "$TMP/lib"
cp -r test "$TMP/test"
# flutter create MainActivity.kt ve debug manifest'i örnek sürümle üzerine
# yazar; native saver, Whisper izni ve test deep link'i kaybolmasın.
MAIN_ACTIVITY="android/app/src/main/kotlin/com/cloudtune/app/MainActivity.kt"
DEBUG_MANIFEST="android/app/src/debug/AndroidManifest.xml"
[[ -f "$MAIN_ACTIVITY" ]] && cp "$MAIN_ACTIVITY" "$TMP/MainActivity.kt"
[[ -f "$DEBUG_MANIFEST" ]] && cp "$DEBUG_MANIFEST" "$TMP/debug-AndroidManifest.xml"

flutter create --platforms=android --org com.cloudtune --project-name cloudtune .

# flutter create kendi örnek dosyalarını yazmış olabilir: bizimkileri geri koy.
cp "$TMP/pubspec.yaml" pubspec.yaml
rm -rf lib test
cp -r "$TMP/lib" lib
cp -r "$TMP/test" test
[[ -f "$TMP/MainActivity.kt" ]] && cp "$TMP/MainActivity.kt" "$MAIN_ACTIVITY"
[[ -f "$TMP/debug-AndroidManifest.xml" ]] && \
  cp "$TMP/debug-AndroidManifest.xml" "$DEBUG_MANIFEST"

python3 tool/patch_android.py
flutter pub get
