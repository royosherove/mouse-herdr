#!/bin/bash
# Builds MouseHerdr.app and (with "install") copies it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  echo "Usage: ./build.sh [install]"
  echo "Builds dist/MouseHerdr.app. With install, copies it to /Applications and starts it."
  echo "Set SIGNING=adhoc for a disposable test build that does not create a keychain."
}

if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
case "${1:-}" in
  ""|install) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$(uname -s)" != Darwin ]; then
  echo "MouseHerdr requires macOS." >&2
  exit 1
fi

# The app's identifier. macOS ties permissions and settings to it, so keep it stable once chosen.
# Put BUNDLE_ID=your.own.id in local.env (not committed) to use your own.
# shellcheck source=/dev/null
[ -f local.env ] && source local.env
BUNDLE_ID="${BUNDLE_ID:-dev.mouseherdr.app}"
SIGNING="${SIGNING:-local}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "BUNDLE_ID must be a reverse-domain identifier, such as dev.mouseherdr.app." >&2
  exit 2
fi
case "$SIGNING" in
  local|adhoc) ;;
  *) echo "SIGNING must be local or adhoc." >&2; exit 2 ;;
esac

APP="dist/MouseHerdr.app"
# Keep the compiler's exit status and diagnostics. A previous binary may still exist after failure.
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MouseHerdr"
[ -x "$BIN" ] || { echo "Build did not produce MouseHerdr." >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MouseHerdr"

# Icon
ICONSET="dist/AppIcon.iconset"
rm -rf "$ICONSET"
rm -f dist/icon.png
mkdir -p "$ICONSET"
"$BIN" --icon dist/icon.png
[ -s dist/icon.png ] || { echo "Could not render the app icon." >&2; exit 1; }
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

plutil -lint "$APP/Contents/Info.plist"

if [ "$SIGNING" = adhoc ]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
  # Keep a stable local identity so macOS keeps permissions across rebuilds.
  # This is a development identity, not an Apple Developer ID distribution certificate.
  KC="$PWD/signing/mouseherdr.keychain-db"
  mkdir -p signing
  chmod 700 signing
  if [ ! -f "$KC" ]; then
    (
      umask 077
      cd signing
      trap 'rm -f key.pem id.p12' EXIT
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem \
        -subj "/CN=MouseHerdr Local Signing" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
      openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:mouseherdr \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
      security create-keychain -p mouseherdr "$KC"
      security set-keychain-settings "$KC"
      security unlock-keychain -p mouseherdr "$KC"
      security import id.p12 -k "$KC" -P mouseherdr -T /usr/bin/codesign >/dev/null
      security set-key-partition-list -S apple-tool:,apple: -s -k mouseherdr "$KC" >/dev/null
    )
  fi

  # Keep each existing path intact, including keychains in directories containing spaces.
  KEYCHAINS=()
  KEYCHAIN_PRESENT=false
  KEYCHAIN_LIST="$(security list-keychains -d user)"
  while IFS= read -r line; do
    keychain="${line#*\"}"
    keychain="${keychain%\"*}"
    [ -n "$keychain" ] || continue
    KEYCHAINS+=("$keychain")
    if [ "$keychain" = "$KC" ]; then KEYCHAIN_PRESENT=true; fi
  done <<< "$KEYCHAIN_LIST"
  if [ "$KEYCHAIN_PRESENT" = false ]; then
    KEYCHAINS+=("$KC")
    security list-keychains -d user -s "${KEYCHAINS[@]}"
  fi
  security unlock-keychain -p mouseherdr "$KC"
  # Use the fingerprint so another checkout's certificate with the same name cannot be chosen.
  CERT=$(security find-certificate -Z "$KC" | awk '/SHA-1 hash:/ {print $NF; exit}')
  if [[ ! "$CERT" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "No signing certificate found in $KC. See README.md for signing troubleshooting." >&2
    exit 1
  fi
  codesign --force --keychain "$KC" --sign "$CERT" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
echo "built $APP"

if [ "${1:-}" = "install" ]; then
  if [ ! -w /Applications ]; then
    echo "Cannot write to /Applications. Copy $APP there with Finder, then open it." >&2
    exit 1
  fi
  pkill -x MouseHerdr 2>/dev/null || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! pgrep -x MouseHerdr >/dev/null; then break; fi
    sleep 0.2
  done
  if pgrep -x MouseHerdr >/dev/null; then
    echo "MouseHerdr has not quit. Quit it manually, then run ./build.sh install again." >&2
    exit 1
  fi
  rm -rf /Applications/MouseHerdr.app
  ditto "$APP" /Applications/MouseHerdr.app
  open /Applications/MouseHerdr.app
  echo "installed and started /Applications/MouseHerdr.app"
fi
