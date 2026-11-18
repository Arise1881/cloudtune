#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CloudTune yayın script'i
# Tek komutla: build → artifact hazırla → GitHub release güncelle
# ============================================================

# Parametreler
BUMP="${1:-patch}"  # major / minor / patch (varsayılan: patch)

# Ortam değişkenleri — sabit kullanıcı yolu yok, başka makinede de çalışır.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${FLUTTER_BIN:-$HOME/development/flutter/bin}:$PATH"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
TMP_ROOT="${CT_TMP_ROOT:-${TMPDIR:-/tmp}/opencode}"
mkdir -p "$TMP_ROOT"
PROJECT="${CT_PROJECT_DIR:-$SCRIPT_DIR}"
DIST="${CT_DIST_DIR:-$TMP_ROOT/cloudtune-dist}"
STAGING="${CT_STAGING_DIR:-$TMP_ROOT/cloudtune-release}"
# Token sürüm kontrolünde saklanmaz; ortam değişkeninden veya yerel dosyadan okunur.
GH_TOKEN="${GH_TOKEN:-}"
if [[ -z "$GH_TOKEN" && -f "$HOME/.config/cloudtune-gh-token" ]]; then
  GH_TOKEN="$(cat "$HOME/.config/cloudtune-gh-token")"
fi
if [[ -z "$GH_TOKEN" ]]; then
  echo "GH_TOKEN gerekli (ortam değişkeni veya ~/.config/cloudtune-gh-token)"
  exit 1
fi
# Token yalnızca bu komutların URL'sinde tutulur; remote config'e yazılmaz.
ct_repo_url() {
  printf 'https://x-access-token:%s@github.com/%s' "$GH_TOKEN" "$1"
}
if [[ ! -d "$DIST/.git" ]]; then
  echo "Dağıtım reposu klonlanıyor: $DIST"
  git clone "$(ct_repo_url Arise1881/cloudtune-dist.git)" "$DIST"
fi
RELEASE_TAG="cloudtune-latest"

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
# Kaynak README dosya haritasındaki sürümü de yeni sürüme taşı (yalnızca
# mevcut sürümü; Windows eski paket notundaki 3.0.5+206 korunur).
# sed'de noktalar regex wildcard olduğu için Python ile literal değiştirme.
python3 - "$CURRENT" "$NEW_FULL" <<'PY'
import sys
old, new = sys.argv[1], sys.argv[2]
p = 'README.md'
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY

# ─── 3. Analiz ───
# Generated.xcconfig sürümünü pubspec'ten yenile; aksi halde iOS eski
# sürüm numarasıyla derlenebilir.
flutter pub get

echo "── flutter analyze ──"
flutter analyze

echo "── flutter test ──"
flutter test

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
rm -f "$STAGING"/CloudTune-* "$STAGING"/CloudTune.ipa "$STAGING"/*.deb 2>/dev/null || true
cp -f build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$STAGING/CloudTune-arm64.apk"
cp -f build/app/outputs/flutter-apk/app-release.apk "$STAGING/CloudTune-universal.apk"
cp -f build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk "$STAGING/CloudTune-armv7.apk"
cp -f build/app/outputs/flutter-apk/app-x86_64-release.apk "$STAGING/CloudTune-x86_64.apk"

# media_kit Linux motoru libmpv kullanır. Flutter RUNPATH $ORIGIN/lib olduğu
# için kütüphaneyi bundle/lib içine koyuyoruz; deb ayrıca libmpv2'ye bağlı.
LIBMPV=$(ldconfig -p 2>/dev/null | awk '/libmpv\.so\.2 .* => \// {print $NF; exit}')
if [[ -n "$LIBMPV" ]]; then
  mkdir -p build/linux/x64/release/bundle/lib
  cp -L "$LIBMPV" build/linux/x64/release/bundle/lib/libmpv.so.2
  ln -sfn libmpv.so.2 build/linux/x64/release/bundle/lib/libmpv.so
  # media_kit libmpv'yi dlopen ile yükler; ana binary'nin ldd çıktısında
  # görünmez. Bundle içindeki kütüphanenin kendisini ve bağımlılıklarını
  # doğrula, böylece bozuk tarball üretilmez.
  MPV_LIB="build/linux/x64/release/bundle/lib/libmpv.so.2"
  [[ -f "$MPV_LIB" ]] || { echo "HATA: $MPV_LIB bulunamadı."; exit 1; }
  if ldd "$MPV_LIB" | grep -q 'not found'; then
    echo "HATA: libmpv.so.2 bağımlılıkları eksik."
    ldd "$MPV_LIB"
    exit 1
  fi
  echo "libmpv bundle'a eklendi: $LIBMPV"
else
  echo "HATA: libmpv.so.2 bulunamadı; Linux paketi üretilemez."
  exit 1
fi
# Release ikilisi zaten -s ile strip ediliyor; yine de emin ol.
strip build/linux/x64/release/bundle/cloudtune 2>/dev/null || true

# Linux tar.gz — masaüstü entegrasyonu bundle içinde de olsun.
# %k .desktop dosyasının kendisidir; $0 olarak kabuğa geçirip dizinini buluyoruz.
# Böylece tarball herhangi bir klasöre açıldığında da binary çalışır.
BUNDLE="build/linux/x64/release/bundle"
cat > "$BUNDLE/cloudtune.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=CloudTune
GenericName=Music Player
Comment=Spotify tarzı müzik çalar (YouTube, reklamsız)
Exec=sh -c 'cd "$(dirname "$0")" && exec ./cloudtune "$@"' "%k"
Icon=cloudtune
Terminal=false
Categories=Audio;AudioVideo;Player;
StartupWMClass=com.cloudtune.app
EOF
cp -f "$DIST/icon.png" "$BUNDLE/cloudtune.png"
cd build/linux/x64/release
tar -czf "$STAGING/CloudTune-linux.tar.gz" bundle
cd "$PROJECT"

# Windows zip (yalnızca Windows makinede build edilirse)
if [[ -f build/windows/x64/runner/Release/cloudtune.exe ]]; then
  echo "── Windows paketle ──"
  cd build/windows/x64/runner/Release
  # flutter_windows.dll ZORUNLU runtime dosyası; pakete mutlaka girmeli.
  zip -qr "$STAGING/CloudTune-windows.zip" . -x "*.pdb"
  cd "$PROJECT"
fi

# iOS ipa (yalnızca macOS makinede build edilirse)
if [[ -d build/ios/iphoneos ]]; then
  echo "── iOS paketle ──"
  IPA_DIR="$TMP_ROOT/cloudtune-ipa"
  rm -rf "$IPA_DIR/Payload"
  mkdir -p "$IPA_DIR/Payload"
  cp -R build/ios/iphoneos/*.app "$IPA_DIR/Payload/"
  cd "$IPA_DIR"
  zip -qr "$STAGING/CloudTune.ipa" Payload
  cd "$PROJECT"
fi

# DEB paketle
DEB_DIR="$TMP_ROOT/cloudtune-deb"
rm -rf "$DEB_DIR"
mkdir -p "$DEB_DIR/usr/share/cloudtune" "$DEB_DIR/DEBIAN"
cp -a build/linux/x64/release/bundle/. "$DEB_DIR/usr/share/cloudtune/"
# Sadece sürüm artışında değil, build artışında da yükseltme yapılabilsin.
cat > "$DEB_DIR/DEBIAN/control" <<EOF
Package: cloudtune
Version: $NEW_VER-$NEW_BUILD
Section: sound
Priority: optional
Architecture: amd64
Depends: libmpv2 (>= 0.35)
Maintainer: Arise1881 <arise1881@users.noreply.github.com>
Description: CloudTune — YouTube müzik çalar (reklamsız)
 Installed-Size: $(du -sk "$DEB_DIR/usr/share/cloudtune" | cut -f1)
EOF

# Masaüstü girişi (.desktop) + uygulama ikonu — DE menülerinde görünür
mkdir -p "$DEB_DIR/usr/share/applications" \
  "$DEB_DIR/usr/share/icons/hicolor/512x512/apps" \
  "$DEB_DIR/DEBIAN"
cat > "$DEB_DIR/usr/share/applications/cloudtune.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CloudTune
GenericName=Music Player
Comment=Spotify tarzı müzik çalar (YouTube, reklamsız)
Exec=/usr/share/cloudtune/cloudtune
Icon=cloudtune
Terminal=false
Categories=Audio;AudioVideo;Player;
# GTK g_set_prgname("com.cloudtune.app") ile eşleşmeli; aksi halde dock ikonu
# ayrı pencere olarak görünür.
StartupWMClass=com.cloudtune.app
EOF
cp -f "$DIST/icon.png" "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/cloudtune.png"
# Kabuktan `cloudtune` ile başlatılabilsin.
mkdir -p "$DEB_DIR/usr/bin"
ln -sfn /usr/share/cloudtune/cloudtune "$DEB_DIR/usr/bin/cloudtune"
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
dpkg-deb --build --root-owner-group "$DEB_DIR" "$STAGING/CloudTune-linux.deb" 2>&1 | tail -1

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
d['notes'] = 'Yerel Whisper sesli arama; oda presence/ack ve kişi sayısı düzeltmeleri; Android R8 + kaynak küçültme + HTTPS-only; Linux deb/tar.gz strip, libmpv doğrulama ve masaüstü entegrasyonu; Windows LTCG + runtime DLL; iOS obfuscation. Windows/iOS binary CI ödeme limiti nedeniyle eski.'
d['platforms']['linux'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-linux.deb'
d['platforms']['linux-targz'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-linux.tar.gz'
d['platforms']['android-arm64'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-arm64.apk'
d['platforms']['android-armv7'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-armv7.apk'
d['platforms']['android-x86_64'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-x86_64.apk'
d['platforms']['android-universal'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-universal.apk'
d['platforms']['windows'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-windows.zip'
d['platforms']['web'] = 'https://github.com/Arise1881/cloudtune-dist/releases/download/$RELEASE_TAG/CloudTune-web.zip'
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
app['versionDescription'] = 'CloudTune $NEW_FULL — R8/strip/LTCG/obfuscation, oda presence/ack ve kişi sayısı düzeltmeleri'
with open(p, 'w') as f:
    json.dump(a, f, indent=2, ensure_ascii=False)
print(f'apps.json -> {app[\"version\"]} / {app[\"versionDate\"]}')
"

# ─── 7. GitHub release asset'lerini güncelle ───
echo "── Eski asset'leri sil ──"
RELEASE_ID=$(curl -fsS -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/cloudtune-dist/releases/tags/$RELEASE_TAG" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Release başlığını gerçek sürümle güncelle
curl -s -o /dev/null -X PATCH \
  -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/cloudtune-dist/releases/$RELEASE_ID" \
  -d "{\"name\":\"CloudTune $NEW_VER (build $NEW_BUILD)\",\"tag_name\":\"$RELEASE_TAG\"}"
echo "Release başlığı -> CloudTune $NEW_VER (build $NEW_BUILD)"

ASSET_IDS=$(curl -fsS -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/cloudtune-dist/releases/tags/$RELEASE_TAG" \
  | python3 -c "
import sys,json,os.path
skip = {'CloudTune.ipa', 'CloudTune-windows.zip', 'CloudTune-web.zip'}
for a in json.load(sys.stdin)['assets']:
    if a['name'] not in skip:
        print(a['id'])
")
for aid in $ASSET_IDS; do
  curl -fsS -o /dev/null -X DELETE \
    -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/Arise1881/cloudtune-dist/releases/assets/$aid"
done

echo "── Yeni asset'leri yükle ──"
UPLOAD="https://uploads.github.com/repos/Arise1881/cloudtune-dist/releases/$RELEASE_ID/assets"
for f in CloudTune-arm64.apk CloudTune-armv7.apk CloudTune-x86_64.apk CloudTune-universal.apk CloudTune-linux.tar.gz; do
  MIME="application/octet-stream"
  [[ "$f" == *.apk ]] && MIME="application/vnd.android.package-archive"
  [[ "$f" == *.tar.gz ]] && MIME="application/gzip"
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: $MIME" \
    --data-binary "@$STAGING/$f" \
    "$UPLOAD?name=$f")
  echo "$f -> $CODE"
  [[ "$CODE" =~ ^2 ]] || { echo "HATA: $f yüklenemedi"; exit 1; }
done

# deb (yeni isimle)
DEB_FILE="CloudTune-linux.deb"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/vnd.debian.binary-package" \
  --data-binary "@$STAGING/$DEB_FILE" \
  "$UPLOAD?name=$DEB_FILE")
echo "$DEB_FILE -> $CODE"
[[ "$CODE" =~ ^2 ]] || { echo "HATA: deb yüklenemedi"; exit 1; }

# Windows + iOS paketleri (yalnızca build edilen varsa yenilenir)
for f in CloudTune-windows.zip CloudTune.ipa; do
  if [[ -f "$STAGING/$f" ]]; then
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: token $GH_TOKEN" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@$STAGING/$f" \
      "$UPLOAD?name=$f")
    echo "$f -> $CODE"
    [[ "$CODE" =~ ^2 ]] || { echo "HATA: $f yüklenemedi"; exit 1; }
  fi
done

# Eski deb asset'ini sil (farklı isimde kalabilir)
OLD_DEB_ID=$(curl -fsS -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/Arise1881/cloudtune-dist/releases/tags/$RELEASE_TAG" \
  | python3 -c "
import sys,json
for a in json.load(sys.stdin)['assets']:
    if a['name'].startswith('cloudtune_') and a['name'] != '$DEB_FILE':
        print(a['id'])
" 2>/dev/null)
if [ -n "$OLD_DEB_ID" ]; then
  for aid in $OLD_DEB_ID; do
    curl -fsS -o /dev/null -X DELETE \
      -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/Arise1881/cloudtune-dist/releases/assets/$aid"
  done
  echo "Eski deb asset silindi"
fi

# index.html ve README'deki deb linklerini güncelle
sed -i "s|cloudtune_[0-9.]*_amd64.deb|$DEB_FILE|g" index.html
sed -i "s|cloudtune_[0-9.]*_amd64.deb|$DEB_FILE|g" README.md

# ─── 8. index.html + README + update.json push et ───
echo "── Push ──"
git add update.json apps.json index.html README.md
git -c user.name="Arise1881" -c user.email="arise1881@users.noreply.github.com" \
  commit -m "v$NEW_FULL: $BUMP bump, Pages manifest URL, release guncellemesi" 2>&1 | tail -1
git push "$(ct_repo_url Arise1881/cloudtune-dist.git)" main 2>&1 | tail -1

# ─── 8b. Kaynak repoyu push et (CI aynı sürümü derlesin) ───
cd "$PROJECT"
# Yalnızca sürüm dosyaları; bootstrap/generated çıktılar yanlışlıkla
# commit edilmesin. Platform dosyaları ayrıca elle commit edilir.
git add pubspec.yaml README.md
git -c user.name="Arise1881" -c user.email="arise1881@users.noreply.github.com" \
  commit -m "chore: surum $NEW_FULL - tam yeniden yazim" 2>&1 | tail -1 || true
git push "$(ct_repo_url Arise1881/cloudtune.git)" HEAD 2>&1 | tail -1

# ─── 8c. iOS + Windows CI derlemelerini tetikle ───
echo "── iOS + Windows derlemelerini tetikle ──"
for wf in ios-build.yml windows-build.yml; do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/Arise1881/cloudtune/actions/workflows/$wf/dispatches" \
    -d '{"ref":"main"}')
  echo "$wf -> $CODE"
  [[ "$CODE" =~ ^2 ]] || echo "UYARI: $wf tetiklenemedi (billing olabilir)"
done

# ─── 9. Son doğrulama ───
echo "── Son doğrulama ──"
# Pages build CDN'i birkaç saniye gecikebilir; kısa bir backoff ile bekle.
for attempt in $(seq 1 12); do
  LIVE=$(curl -fsS "https://arise1881.github.io/cloudtune-dist/update.json?check=$attempt" 2>/dev/null || echo '{}')
  LIVE_VER=$(printf '%s' "$LIVE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
  [[ "$LIVE_VER" == "$NEW_VER" ]] && break
  sleep 5
done
echo "Pages manifest -> ${LIVE_VER:-eski} / hedef $NEW_VER"
[[ "$LIVE_VER" == "$NEW_VER" ]] || echo "UYARI: Pages henüz yeni manifest'i yayınlamadı; birazdan kontrol edin."

echo ""
echo "✅ Yayın tamamlandı: v$NEW_FULL"
echo "   CloudTune APK (arm64): $(ls -lh $STAGING/CloudTune-arm64.apk | awk '{print $5}')"
echo "   CloudTune APK (universal): $(ls -lh $STAGING/CloudTune-universal.apk | awk '{print $5}')"
echo "   DEB: $(ls -lh $STAGING/$DEB_FILE | awk '{print $5}')"
echo "   tar.gz: $(ls -lh $STAGING/CloudTune-linux.tar.gz | awk '{print $5}')"
