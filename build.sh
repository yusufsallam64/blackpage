#!/bin/bash
# Builds build/Blackpage.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Blackpage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Blackpage "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
