#!/bin/zsh
# Build a release binary and wrap it in a minimal Compagnion.app bundle.
#
#   ./make-app.sh                 ad-hoc signed, host architecture only
#   UNIVERSAL=1 ./make-app.sh     arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" ./make-app.sh
#
# release.sh drives the last form; run this one directly for local builds.
set -e
cd "$(dirname "$0")"

VERSION=${VERSION:-0.2.0}
BUILD=${BUILD:-2}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
UNIVERSAL=${UNIVERSAL:-0}

build_flags=(-c release)
if [ "$UNIVERSAL" = "1" ]; then
    build_flags+=(--arch arm64 --arch x86_64)
fi

swift build "${build_flags[@]}"
# A multi-arch build lands somewhere other than .build/release, so ask SwiftPM
# rather than guessing.
BIN_DIR=$(swift build "${build_flags[@]}" --show-bin-path)

APP=Compagnion.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Compagnion" "$APP/Contents/MacOS/Compagnion"

# Notification banners and the Dock (settings window switches the app to
# .regular) both read the bundle icon; without it they fall back to the
# generic placeholder.
[ -f Resources/Compagnion.icns ] || swift Resources/make-icon.swift
cp Resources/Compagnion.icns "$APP/Contents/Resources/Compagnion.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Compagnion</string>
    <key>CFBundleIconFile</key>
    <string>Compagnion</string>
    <key>CFBundleIconName</key>
    <string>Compagnion</string>
    <key>CFBundleIdentifier</key>
    <string>dev.florent.compagnion</string>
    <key>CFBundleName</key>
    <string>Compagnion</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <!-- Tab-level focus in Terminal/iTerm2 is driven by AppleScript. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Compagnion focuses the terminal tab running the Claude Code session you clicked.</string>
</dict>
</plist>
EOF

# UNUserNotificationCenter refuses to register for an unsigned bundle, and
# signatures only stick when the bundle is signed as a whole, last.
#
# The hardened runtime is applied even to ad-hoc builds so local runs exercise
# the same Apple Events restrictions notarized builds will hit. There is no
# nested code, so no --deep.
sign_flags=(--force --options runtime --entitlements Resources/Compagnion.entitlements)
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signatures cannot carry a secure timestamp; asking for one just
    # adds a network round-trip that fails.
    sign_flags+=(--timestamp=none)
else
    # Notarization rejects anything without a secure timestamp.
    sign_flags+=(--timestamp)
fi

codesign "${sign_flags[@]}" --sign "$SIGN_IDENTITY" "$APP"

echo "Built $PWD/$APP ($VERSION build $BUILD, $(lipo -archs "$APP/Contents/MacOS/Compagnion"))"
echo "Run it:            open $APP"
echo "Start at login:    System Settings → General → Login Items → add $APP"
