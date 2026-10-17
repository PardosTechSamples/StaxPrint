#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) StaxPrint.app, ad-hoc signed, into build/, and zips it.
#   ./scripts/make-app.sh [version]  && open build/StaxPrint.app
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"

swift build -c release --product StaxPrint --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/StaxPrint"
APP=build/StaxPrint.app
ZIP="build/StaxPrint-$VERSION-macOS-universal.zip"

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
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>StaxPrint talks to your Instax SHARE printer over its Wi-Fi network.</string>
</dict>
</plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/StaxPrint"))"
echo "Zipped $ZIP  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
