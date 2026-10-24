#!/bin/bash
# Compile an isolated, offline app that hosts the actual production UI in both appearances.
# Default is build-only; opening the app requires a logged-in macOS graphical session.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---build-only}"
case "$MODE" in
  --build-only|--run) ;;
  *) echo "Usage: $0 [--build-only | --run]" >&2; exit 64 ;;
esac
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
APP="$ROOT/.build/ui-preview/RelayPreview.app"
mkdir -p "$APP/Contents/MacOS" "$ROOT/.build/ui-preview/module-cache"
swiftc -swift-version 5 -D DEBUG -parse-as-library -sdk "$SDK" \
  -module-cache-path "$ROOT/.build/ui-preview/module-cache" \
  "$ROOT"/Sources/Relay/Models/*.swift "$ROOT"/Sources/Relay/Persistence/*.swift \
  "$ROOT"/Sources/Relay/Services/*.swift "$ROOT"/Sources/Relay/UI/*.swift \
  "$ROOT/Tests/RelayVisualPreview.swift" -o "$APP/Contents/MacOS/RelayPreview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cloud.dinghao.relay.ui-preview</string>
<key>CFBundleName</key><string>Relay UI Preview</string>
<key>CFBundleExecutable</key><string>RelayPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
echo "BUILT: $APP (offline fixtures; production UI; light and dark)"
if [[ "$MODE" == --run ]]; then open "$APP"; fi
