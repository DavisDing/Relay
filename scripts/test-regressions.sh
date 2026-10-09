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
  "$ROOT/Sources/Relay/UI/RelayNumberFormatter.swift" \
  "$ROOT/Sources/Relay/UI/MenuBarStatusPresentation.swift" \
  "$ROOT/Tests/MenuBarPresentationChecks.swift" \
  "$ROOT/Tests/AccountFeedbackChecks.swift" \
  "$ROOT/Tests/AccountDetailRefreshChecks.swift" \
  "$ROOT/Tests/PipioDashboardContractChecks.swift" \
  "$ROOT/Tests/WorkBuddy2APIContractChecks.swift" \
  "$ROOT/Tests/RefreshSchedulingChecks.swift" \
  "$ROOT/Tests/UpdateIntegrityChecks.swift" \
  "$ROOT/Tests/RepositoryPerformanceChecks.swift" \
  "$ROOT/Tests/RegressionChecks.swift" -o "$WORK/relay-regressions"
"$WORK/relay-regressions"

# A separate @main checks Swift Charts selection/annotation helpers without creating windows.
swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "${SWIFTPM_MODULECACHE_OVERRIDE:-$WORK/module-cache}" -sdk "$SDK" \
  "$ROOT"/Sources/Relay/Models/*.swift \
  "$ROOT"/Sources/Relay/Persistence/*.swift \
  "$ROOT"/Sources/Relay/Services/*.swift \
  "$ROOT/Sources/Relay/UI/AdaptiveLineChart.swift" \
  "$ROOT/Sources/Relay/UI/RelayNumberFormatter.swift" \
  "$ROOT/Sources/Relay/UI/MenuBarStatusPresentation.swift" \
  "$ROOT/Tests/AdaptiveLineChartChecks.swift" -o "$WORK/chart-checks"
"$WORK/chart-checks"
