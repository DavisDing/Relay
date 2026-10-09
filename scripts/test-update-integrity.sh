#!/usr/bin/env bash
# Focused, offline entry point; no XCTest or credentials/vendor network required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-update-integrity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
cat > "$WORK/Main.swift" <<'SWIFT'
import Foundation
@main struct UpdateIntegrityMain {
    @MainActor static func main() async throws {
        try await UpdateIntegrityChecks.run()
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "${SWIFTPM_MODULECACHE_OVERRIDE:-$WORK/module-cache}" -sdk "$SDK" \
    "$ROOT/Sources/Relay/Services/UpdateService.swift" \
    "$ROOT/Tests/UpdateIntegrityChecks.swift" "$WORK/Main.swift" \
    -o "$WORK/update-integrity"
"$WORK/update-integrity"
