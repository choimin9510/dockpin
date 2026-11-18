#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/compile-core.sh
FIXTURE="$PWD/.build/fixtures/DockpinFixture.app"
mkdir -p "$FIXTURE/Contents/MacOS"
xcrun swiftc -parse-as-library Tests/Integration/Fixture.swift -o "$FIXTURE/Contents/MacOS/DockpinFixture"
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.dockpin.fixture</string>
<key>CFBundleExecutable</key><string>DockpinFixture</string>
<key>CFBundleName</key><string>Dockpin 검증 창</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$FIXTURE"
xcrun swiftc -parse-as-library -I .build/native Sources/Dockpin/Platform.swift Sources/Dockpin/Recovery.swift \
  Tests/Integration/Runner.swift .build/native/DockpinCore.o -o .build/native/DockpinIntegration
.build/native/DockpinIntegration
