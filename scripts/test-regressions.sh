#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-regressions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -D DEBUG -parse-as-library \
  -module-cache-path "${SWIFTPM_MODULECACHE_OVERRIDE:-$WORK/module-cache}" -sdk "$SDK" \
  "$ROOT"/Sources/Relay/Models/*.swift \
  "$ROOT"/Sources/Relay/Persistence/*.swift \
  "$ROOT"/Sources/Relay/Services/*.swift \
  "$ROOT/Tests/RegressionChecks.swift" -o "$WORK/relay-regressions"
"$WORK/relay-regressions"
