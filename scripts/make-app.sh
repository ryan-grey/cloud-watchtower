#!/usr/bin/env bash
# Assemble Watchtower.app from the SwiftPM build product.
#
# There is no Xcode project here on purpose: Command Line Tools ship the macOS SDK including
# SwiftUI, so `swift build` produces the binary and this script wraps it in the bundle that
# MenuBarExtra, LSUIElement and SMAppService all require. Idempotent — safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/Watchtower.app"
BUNDLE_ID="dev.ryangrey.watchtower"
VERSION="1.0.0"

echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Watchtower"
[ -x "$BIN" ] || { echo "!! no binary at $BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Watchtower"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Watchtower</string>
    <key>CFBundleDisplayName</key><string>Cloud Watchtower</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Watchtower</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- NO sandbox entitlement, deliberately. See README "Why the app is not sandboxed". -->
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
# Ad-hoc (-s -) needs no certificate. This is a local build: not notarized, not distributable.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Done: $APP"
echo "    Run:  open \"$APP\""
echo "    Logs: log stream --predicate 'process == \"Watchtower\"' --level debug"
