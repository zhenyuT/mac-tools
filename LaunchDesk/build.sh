#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/LaunchDesk.app"
BUILD_DIR="$PROJECT_DIR/.build"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR"
/usr/bin/swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework SwiftUI -framework AppKit \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP_DIR/Contents/MacOS/LaunchDesk"
/usr/bin/swift -module-cache-path "$BUILD_DIR/module-cache" "$PROJECT_DIR/Icon.swift" "$BUILD_DIR/AppIcon.iconset"
/usr/bin/iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/python3 - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({
        'CFBundleIdentifier': 'local.launchdesk.app',
        'CFBundleExecutable': 'LaunchDesk',
        'CFBundleName': 'LaunchDesk',
        'CFBundleDisplayName': 'LaunchDesk · 定时管家',
        'CFBundleVersion': '3',
        'CFBundleShortVersionString': '1.1.0',
        'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '14.0',
        'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication',
        'CFBundleIconFile': 'AppIcon',
    }, f)
PY
/usr/bin/codesign --force --sign - "$APP_DIR"
printf '%s\n' "$APP_DIR"
