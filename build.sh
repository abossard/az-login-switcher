#!/bin/bash
set -e

echo "Generating app icon..."
python3 scripts/make_icon.py

echo "Building AzLoginSwitcher..."
swift build -c release

echo "Creating .app bundle..."
APP_DIR="build/AzLoginSwitcher.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Writing Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AzLoginSwitcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.az-login-switcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleName</key>
    <string>AzLoginSwitcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo "Copying binary..."
cp .build/release/AzLoginSwitcher "$MACOS_DIR/"

echo "Copying app icon..."
cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

echo "Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "✅ Build complete: $APP_DIR"
