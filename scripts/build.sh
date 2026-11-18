#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Replacing a running ad-hoc signed app leaves TCC tracking an obsolete hash.
if pgrep -x Dockpin >/dev/null; then
    echo "Dockpin is running. Quit it before rebuilding; a new ad-hoc build requires renewed Accessibility approval." >&2
    exit 1
fi
./scripts/compile-core.sh
BIN_DIR="$PWD/.build/native"
xcrun swiftc -O -target arm64-apple-macosx13.0 -I "$BIN_DIR" Sources/Dockpin/*.swift "$BIN_DIR/DockpinCore.o" -o "$BIN_DIR/Dockpin"
APP="$PWD/build/Dockpin.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Dockpin" "$APP/Contents/MacOS/Dockpin"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dockpin</string>
<key>CFBundleIdentifier</key><string>app.dockpin.mac</string>
<key>CFBundleName</key><string>Dockpin</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>NSAppleEventsUsageDescription</key><string>잠자기 전 Dock 크기와 확대 설정을 기억하고 복원합니다.</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
