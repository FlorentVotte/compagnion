#!/bin/zsh
# Build a release binary and wrap it in a minimal Compagnion.app bundle.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=Compagnion.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/Compagnion "$APP/Contents/MacOS/Compagnion"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Compagnion</string>
    <key>CFBundleIdentifier</key>
    <string>dev.florent.compagnion</string>
    <key>CFBundleName</key>
    <string>Compagnion</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

echo "Built $PWD/$APP"
echo "Run it:            open $APP"
echo "Start at login:    System Settings → General → Login Items → add $APP"
