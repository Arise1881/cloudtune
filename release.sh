#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Melody yayın script'i
# Tek komutla: build → artifact hazırla → GitHub release güncelle
# ============================================================

# Parametreler
BUMP="${1:-patch}"  # major / minor / patch (varsayılan: patch)

# Ortam değişkenleri
export PATH="/home/msi/development/flutter/bin:$PATH"
export ANDROID_SDK_ROOT=/home/msi/android-sdk
PROJECT="/home/msi/Belgeler/Default Project/sonora"
DIST="/tmp/opencode/melody-dist"
STAGING="/tmp/opencode/melody-release"
GH_TOKEN="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"
RELEASE_TAG="melody-latest"

cd "$PROJECT"

# ─── 1. Mevcut sürümü oku ───
CURRENT=$(grep "^version:" pubspec.yaml | sed 's/version: //')
MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d+ -f1 | cut -d. -f3)
BUILD=$(echo "$CURRENT" | cut -d+ -f2)

echo "Mevcut: $CURRENT"

# ─── 2. Sürümü yükselt ───
case "$BUMP" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
  current) : ;;  # pubspec sürümünü aynen kullan, asset'leri yeniden yayınla
  *) echo "Geçersiz bump: $BUMP (major/minor/patch/current)"; exit 1 ;;
esac
NEW_VER="$MAJOR.$MINOR.$PATCH"
NEW_BUILD=$((BUILD+1))
[[ "$BUMP" == "current" ]] && NEW_BUILD=$BUILD
NEW_FULL="$NEW_VER+$NEW_BUILD"
NEW_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Yeni: $NEW_FULL"

# pubspec güncelle (bump=current ise sürüm aynen kalır)
[[ "$BUMP" != "current" ]] && sed -i "s/^version:.*/version: $NEW_FULL/" pubspec.yaml

# ─── 3. Analiz ───
echo "── flutter analyze ──"
flutter analyze | tail -3

# ─── 4. Build ───
echo "── Android split APK ──"
flutter build apk --release --split-per-abi 2>&1 | tail -3

echo "── Android universal APK ──"
flutter build apk --release 2>&1 | tail -3

echo "── Linux ──"
flutter build linux --release 2>&1 | tail -3
echo "── Windows (yalnızca Windows makinede) ──"
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* || "$(uname -s)" == MSYS* ]]; then
  flutter build windows --release 2>&1 | tail -3
fi
echo "── iOS (yalnızca macOS makinede) ──"
if [[ "$(uname -s)" == Darwin ]]; then
  flutter build ios --release --no-codesign 2>&1 | tail -3
fi

# ─── 5. Artifact'leri hazırla ───
echo "── Artifact hazırlama ──"
mkdir -p "$STAGING"
cp -f build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$STAGING/Melody.apk"
cp -f build/app/outputs/flutter-apk/app-release.apk "$STAGING/Melody-universal.apk"
cp -f build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk "$STAGING/Melody-armeabi-v7a.apk"
cp -f build/app/outputs/flutter-apk/app-x86_64-release.apk "$STAGING/Melody-x86_64.apk"

# Linux tar.gz
cd build/linux/x64/release
tar -czf "$STAGING/Melody-linux.tar.gz" bundle
cd "$PROJECT"

# Windows zip (yalnızca Windows makinede build edilirse)
if [[ -f build/windows/x64/runner/Release/melody.exe ]]; then
  echo "── Windows paketle ──"
  cd build/windows/x64/runner/Release
  zip -qr "$STAGING/Melody-windows.zip" . -x "*.pdb" -x "flutter_windows.dll" -x "Darwin*"
  cd "$PROJECT"
fi

# iOS ipa (yalnızca macOS makinede build edilirse)
if [[ -d build/ios/iphoneos ]]; then
  echo "── iOS paketle ──"
  mkdir -p /tmp/opencode/ipa/Payload
  cp -R build/ios/iphoneos/*.app /tmp/opencode/ipa/Payload/
  cd /tmp/opencode/ipa
  zip -qr "$STAGING/Melody.ipa" Payload
  cd "$PROJECT"
fi

# DEB paketle
DEB_DIR="/tmp/opencode/melody-deb"
mkdir -p "$DEB_DIR/usr/share/melody" "$DEB_DIR/DEBIAN"
rm -rf "$DEB_DIR/usr/share/melody/"* 2>/dev/null || true
cp -a build/linux/x64/release/bundle/. "$DEB_DIR/usr/share/melody/"
cat > "$DEB_DIR/DEBIAN/control" <<EOF
Package: melody
Version: $NEW_VER
Section: sound
Priority: optional
Architecture: amd64
Maintainer: Arise1881 <arise1881@users.noreply.github.com>
Description: Melody — YouTube müzik çalar (reklamsız)
 Installed-Size: $(du -sk "$DEB_DIR/usr/share/melody" | cut -f1)
EOF

# Masaüstü girişi (.desktop) + uygulama ikonu — DE menülerinde görünür
mkdir -p "$DEB_DIR/usr/share/applications" \
  "$DEB_DIR/usr/share/icons/hicolor/512x512/apps" \
  "$DEB_DIR/DEBIAN"
cat > "$DEB_DIR/usr/share/applications/melody.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Melody
GenericName=Music Player
Comment=Spotify tarzı müzik çalar (YouTube, reklamsız)
Exec=/usr/share/melody/melody
Icon=melody
Terminal=false
Categories=Audio;AudioVideo;Player;
StartupWMClass=melody
EOF
cp -f "$DIST/icon.png" "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/melody.png"
cat > "$DEB_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "$DEB_DIR/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$DEB_DIR" "$STAGING/melody_${NEW_VER}_amd64.deb" 2>&1 | tail -1

echo "Artifact'ler hazır:"
ls -la "$STAGING/"

# ─── 6. update.json güncelle ───
cd "$DIST"
python3 -c "
import json
with open('update.json') as f:
    d = json.load(f)
d['version'] = '$NEW_VER'
d['versionCode'] = $NEW_BUILD
d['notes'] = 'Melody $NEW_VER'
d['platforms']['linux'] = 'https://github.com/Arise1881/melody-dist/releases/download/$RELEASE_TAG/melody_${NEW_VER}_amd64.deb'
with open('update.json', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print(f'update.json -> {d[\"version\"]} / {d[\"versionCode\"]}')
"

# ─── 6b. apps.json (iOS AltStore kaynağı) sürümünü güncelle ───
python3 -c "
import json
p = 'apps.json'
with open(p) as f:
    a = json.load(f)
app = a['apps'][0]
app['version'] = '$NEW_VER'
app['versionDate'] = '$NEW_DATE'
with open(p, 'w') as f:
    json.dump(a, f, indent=2, ensure_ascii=False)
print(f'apps.json -> {app[\"version\"]} / {app[\"versionDate\"]}')
"

# ─── 7. GitHub release asset'lerini güncelle ───
echo "── Eski asset'leri sil ──"
RELEASE_ID=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/melody-dist/releases/tags/$RELEASE_TAG" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

ASSET_IDS=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/melody-dist/releases/tags/$RELEASE_TAG" \
  | python3 -c "
import sys,json,os.path
skip = set()
if os.path.exists('$STAGING/Melody.ipa'): skip.add('Melody.ipa')
if os.path.exists('$STAGING/Melody-windows.zip'): skip.add('Melody-windows.zip')
for a in json.load(sys.stdin)['assets']:
    if a['name'] not in skip:
        print(a['id'])
")
for aid in $ASSET_IDS; do
  curl -s -o /dev/null -X DELETE \
    -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/Arise1881/melody-dist/releases/assets/$aid"
done

echo "── Yeni asset'leri yükle ──"
UPLOAD="https://uploads.github.com/repos/Arise1881/melody-dist/releases/$RELEASE_ID/assets"
for f in Melody.apk Melody-universal.apk Melody-armeabi-v7a.apk Melody-x86_64.apk Melody-linux.tar.gz; do
  MIME="application/octet-stream"
  [[ "$f" == *.apk ]] && MIME="application/vnd.android.package-archive"
  [[ "$f" == *.tar.gz ]] && MIME="application/gzip"
  curl -s -o /dev/null -w "$f -> %{http_code}\n" -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: $MIME" \
    --data-binary "@$STAGING/$f" \
    "$UPLOAD?name=$f"
done

# deb (yeni isimle)
DEB_FILE="melody_${NEW_VER}_amd64.deb"
curl -s -o /dev/null -w "$DEB_FILE -> %{http_code}\n" -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/vnd.debian.binary-package" \
  --data-binary "@$STAGING/$DEB_FILE" \
  "$UPLOAD?name=$DEB_FILE"

# Windows + iOS paketleri (yalnızca build edilen varsa yenilenir)
for f in Melody-windows.zip Melody.ipa; do
  if [[ -f "$STAGING/$f" ]]; then
    curl -s -o /dev/null -w "$f -> %{http_code}\n" -X POST \
      -H "Authorization: token $GH_TOKEN" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@$STAGING/$f" \
      "$UPLOAD?name=$f"
  fi
done

# Eski deb asset'ini sil (farklı isimde kalabilir)
OLD_DEB_ID=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/melody-dist/releases/tags/$RELEASE_TAG" \
  | python3 -c "
import sys,json
for a in json.load(sys.stdin)['assets']:
    if a['name'].startswith('melody_') and a['name'] != '$DEB_FILE':
        print(a['id'])
" 2>/dev/null)
if [ -n "$OLD_DEB_ID" ]; then
  for aid in $OLD_DEB_ID; do
    curl -s -o /dev/null -X DELETE \
      -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/Arise1881/melody-dist/releases/assets/$aid"
  done
  echo "Eski deb asset silindi"
fi

# index.html ve README'deki deb linklerini güncelle
sed -i "s|melody_[0-9.]*_amd64.deb|$DEB_FILE|g" index.html
sed -i "s|melody_[0-9.]*_amd64.deb|$DEB_FILE|g" README.md

# ─── 8. index.html + README + update.json push et ───
echo "── Push ──"
git add update.json apps.json index.html README.md
git -c user.name="Arise1881" -c user.email="arise1881@users.noreply.github.com" \
  commit -m "v$NEW_FULL: $BUMP bump, Pages manifest URL, release guncellemesi" 2>&1 | tail -1
git push "https://x-access-token:${GH_TOKEN}@github.com/Arise1881/melody-dist.git" main 2>&1 | tail -1

# ─── 8b. Kaynak repoyu push et (CI aynı sürümü derlesin) ───
cd "$PROJECT"
git add pubspec.yaml
git -c user.name="Arise1881" -c user.email="arise1881@users.noreply.github.com" \
  commit -m "chore: surum $NEW_FULL" 2>&1 | tail -1 || true
git push "https://x-access-token:${GH_TOKEN}@github.com/Arise1881/melody.git" HEAD 2>&1 | tail -1

# ─── 8c. iOS + Windows CI derlemelerini tetikle ───
echo "── iOS + Windows derlemelerini tetikle ──"
for wf in ios-build.yml windows-build.yml; do
  curl -s -o /dev/null -w "$wf -> %{http_code}\n" -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/Arise1881/melody/actions/workflows/$wf/dispatches" \
    -d '{"ref":"main"}'
done

# ─── 9. Son doğrulama ───
echo "── Son doğrulama ──"
curl -s -o /dev/null -w "GitHub Pages -> %{http_code}\n" "https://arise1881.github.io/melody-dist/update.json"
curl -s "https://arise1881.github.io/melody-dist/update.json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Pages manifest -> {d[\"version\"]} / {d[\"versionCode\"]}')"

echo ""
echo "✅ Yayın tamamlandı: v$NEW_FULL"
echo "   Melody APK (arm64): $(ls -lh $STAGING/Melody.apk | awk '{print $5}')"
echo "   Melody APK (universal): $(ls -lh $STAGING/Melody-universal.apk | awk '{print $5}')"
echo "   DEB: $(ls -lh $STAGING/$DEB_FILE | awk '{print $5}')"
echo "   tar.gz: $(ls -lh $STAGING/Melody-linux.tar.gz | awk '{print $5}')"
