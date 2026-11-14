#!/usr/bin/env bash
# Android platform dosyalarını üretir ve CloudTune için yamalar.
# Kullanım (proje kökünde): bash tool/bootstrap.sh
set -euo pipefail

TMP="$(mktemp -d)"
cp pubspec.yaml "$TMP/pubspec.yaml"
cp -r lib "$TMP/lib"
cp -r test "$TMP/test"

flutter create --platforms=android --org com.cloudtune --project-name cloudtune .

# flutter create kendi örnek dosyalarını yazmış olabilir: bizimkileri geri koy.
cp "$TMP/pubspec.yaml" pubspec.yaml
rm -rf lib test
cp -r "$TMP/lib" lib
cp -r "$TMP/test" test

python3 tool/patch_android.py
flutter pub get
