#!/bin/bash
# Requires a logged-in macOS graphical session; uses only synthetic in-memory data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-navigation.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/RelayNavigationChecks.app/Contents/MacOS"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -D DEBUG -parse-as-library \
  -module-cache-path "${SWIFTPM_MODULECACHE_OVERRIDE:-$WORK/module-cache}" -sdk "$SDK" \
  "$ROOT"/Sources/Relay/Models/*.swift "$ROOT"/Sources/Relay/Persistence/*.swift \
  "$ROOT"/Sources/Relay/Services/*.swift "$ROOT"/Sources/Relay/UI/*.swift \
  "$ROOT/Tests/WindowNavigationContractChecks.swift" -o "$WORK/RelayNavigationChecks.app/Contents/MacOS/relay-navigation-checks"
cat > "$WORK/RelayNavigationChecks.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cloud.dinghao.relay.navigation-checks</string>
<key>CFBundleExecutable</key><string>relay-navigation-checks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$WORK/RelayNavigationChecks.app/Contents/MacOS/relay-navigation-checks"
