#!/bin/sh
# Build Robo.app: no Dock icon, a microphone usage text, onnxruntime and the resource bundles (math fonts) embedded, code signed.
# Usage: ./bundle.sh [path/to/Robo.app]   (default build/Robo.app)
# Signed ad hoc unless ROBO_SIGN_IDENTITY names a valid code-signing certificate in the keychain
# search list. macOS ties the microphone and Screen Recording permissions to the signature, so an
# ad-hoc build asks again after every rebuild; a stable identity keeps them.
set -e
cd "$(dirname "$0")"
app="${1:-build/Robo.app}"
case "$app" in *.app) ;; *) echo "bundle.sh: '$app' must end in .app (it is deleted first)" >&2; exit 1 ;; esac
swift build -c release --product robo
bin="$(swift build -c release --show-bin-path)"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$bin/robo" "$app/Contents/MacOS/robo"
cp -R "$bin/onnxruntime.framework" "$app/Contents/Frameworks/"
# SwiftPM resource bundles (SwiftMath's math fonts, for the LaTeX in the chat) belong in Contents/Resources: that is where their accessor looks
mkdir -p "$app/Contents/Resources"
for resources in "$bin"/*.bundle; do [ -d "$resources" ] && cp -R "$resources" "$app/Contents/Resources/"; done
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/robo"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ai.robo.app</string>
    <key>CFBundleName</key><string>Robo</string>
    <key>CFBundleExecutable</key><string>robo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Robo listens for its name and your request. Speech is recognised on this Mac; no audio leaves it.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --deep --sign "${ROBO_SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
echo "built $app"
