#!/bin/bash
# Builds MouseHerdr.app and (with "install") copies it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

# The app's identifier. macOS ties permissions and settings to it, so keep it stable once chosen.
# Put BUNDLE_ID=your.own.id in local.env (not committed) to use your own.
[ -f local.env ] && source local.env
BUNDLE_ID="${BUNDLE_ID:-dev.mouseherdr.app}"

APP="dist/MouseHerdr.app"
swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN=".build/release/MouseHerdr"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MouseHerdr"

# Icon
ICONSET="dist/AppIcon.iconset"; mkdir -p "$ICONSET"
"$BIN" --icon dist/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s dist/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) dist/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" dist/icon.png

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MouseHerdr</string>
  <key>CFBundleDisplayName</key><string>MouseHerdr</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>MouseHerdr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign with a local, stable identity so macOS keeps the app's permissions across rebuilds.
KC="$PWD/signing/mouseherdr.keychain-db"
if [ ! -f "$KC" ]; then
  mkdir -p signing && pushd signing >/dev/null
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem \
    -subj "/CN=MouseHerdr Local Signing" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:mouseherdr \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
  security create-keychain -p mouseherdr "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p mouseherdr "$KC"
  security import id.p12 -k "$KC" -P mouseherdr -A >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k mouseherdr "$KC" >/dev/null 2>&1
  rm -f key.pem id.p12
  popd >/dev/null
fi
security list-keychains -d user | grep -q "$KC" || \
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
security unlock-keychain -p mouseherdr "$KC"
# Sign by the certificate's fingerprint, so another copy of this project on the same Mac can't be confused with it.
CERT=$(security find-certificate -Z "$KC" | awk '/SHA-1 hash:/ {print $NF; exit}')
codesign --force --keychain "$KC" --sign "$CERT" --identifier "$BUNDLE_ID" "$APP"
echo "built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x MouseHerdr 2>/dev/null || true
  while pgrep -x MouseHerdr >/dev/null; do sleep 0.2; done
  rm -rf /Applications/MouseHerdr.app
  ditto "$APP" /Applications/MouseHerdr.app
  open /Applications/MouseHerdr.app
  echo "installed and started /Applications/MouseHerdr.app"
fi
