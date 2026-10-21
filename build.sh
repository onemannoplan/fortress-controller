#!/usr/bin/env bash

# Build "Fortress Controller.app" into ./build (no admin rights needed).

set -euo pipefail
cd "$(dirname "$0")"

APP="build/Fortress Controller.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
	-framework Cocoa -framework WebKit -framework UserNotifications \
	-o "$APP/Contents/MacOS/FortressController" FortressController.swift

cp dashboard.html "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.fortress-controller</string>
	<key>CFBundleName</key><string>Fortress Controller</string>
	<key>CFBundleDisplayName</key><string>Fortress Controller</string>
	<key>CFBundleExecutable</key><string>FortressController</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
