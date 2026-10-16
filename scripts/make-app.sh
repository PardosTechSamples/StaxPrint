#!/bin/zsh
# Builds StaxPrint.app (release, ad-hoc signed) into build/.
#   ./scripts/make-app.sh && open build/StaxPrint.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product StaxPrint
BIN="$(swift build -c release --show-bin-path)/StaxPrint"
APP=build/StaxPrint.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StaxPrint"
cp assets/AppIcon.icns Sources/StaxPrint/Resources/*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>StaxPrint</string>
    <key>CFBundleDisplayName</key><string>StaxPrint</string>
    <key>CFBundleIdentifier</key><string>com.pardostech.staxprint</string>
    <key>CFBundleExecutable</key><string>StaxPrint</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>StaxPrint talks to your Instax SHARE printer over its Wi-Fi network.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
