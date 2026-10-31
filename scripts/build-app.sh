#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/android-analyxer-clang-cache"
swift build -c release --disable-sandbox --product AndroidAnalyxer
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
APP="$PWD/dist/Android Analyxer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AndroidAnalyxer" "$APP/Contents/MacOS/AndroidAnalyxer"
cp "$PWD/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$APP/Contents/Resources/"*.lproj
cp -R "$PWD/Resources/Localization/"*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AndroidAnalyxer</string>
<key>CFBundleIdentifier</key><string>at.reitboeck.android-analyxer</string>
<key>CFBundleName</key><string>Android Analyxer</string>
<key>CFBundleDisplayName</key><string>Android Analyxer</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.2</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
INSTALLED="/Applications/Android Analyxer.app"
STAGE="/Applications/.Android Analyxer.app.installing"
rm -rf "$STAGE"
ditto "$APP" "$STAGE"
rm -rf "$INSTALLED"
mv "$STAGE" "$INSTALLED"
printf 'Installed: %s\n' "$INSTALLED"
if pgrep -xq AndroidAnalyxer; then printf 'Note: Android Analyxer is still running; the new version takes effect after restarting the app.\n'; fi
