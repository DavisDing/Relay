#!/usr/bin/env bash
# Focused offline checks for the production account-order transaction.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-account-ordering.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
cat > "$WORK/Main.swift" <<'SWIFT'
import Foundation
@main struct AccountOrderingMain {
    @MainActor static func main() throws { try AccountOrderingChecks.run() }
}
SWIFT
swiftc -swift-version 5 -D DEBUG -parse-as-library \
    -module-cache-path "${SWIFTPM_MODULECACHE_OVERRIDE:-$WORK/module-cache}" -sdk "$SDK" \
    "$ROOT"/Sources/Relay/Models/*.swift "$ROOT"/Sources/Relay/Persistence/*.swift \
    "$ROOT"/Sources/Relay/Services/*.swift \
    "$ROOT/Sources/Relay/UI/RelayNumberFormatter.swift" \
    "$ROOT/Tests/AccountOrderingChecks.swift" "$WORK/Main.swift" -o "$WORK/account-ordering"
"$WORK/account-ordering"
