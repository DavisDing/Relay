#!/bin/bash
# Offline macOS checks: injected HTTP/shortcut fakes and temporary sync fixtures.
# Each contract has its own @main, so compile and execute it independently.
# No GUI session, real credentials, iCloud account, package download or network is required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 (runs all offline contracts)" >&2
  exit 64
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "UNSUPPORTED: offline contracts require the macOS SDK, but no GUI session." >&2
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-contracts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/module-cache" "$WORK/clang-cache"
# Do not inherit credentials, proxy settings or user preferences into test processes.
RUN_ENV=(env -i "PATH=$PATH" "HOME=$WORK/home" "CFFIXED_USER_HOME=$WORK/home"
  "TMPDIR=$WORK/tmp/" "TZ=UTC" "LANG=en_US.UTF-8")
COMPILE=(-swift-version 5 -D DEBUG -parse-as-library -sdk "$SDK"
  -module-cache-path "$WORK/module-cache")
# Explicit production dependencies: do not link the application/store, UI, update
# client, production provider registry or refresh scheduler into offline contracts.
COMMON_SOURCES=("$ROOT"/Sources/Relay/Models/*.swift "$ROOT"/Sources/Relay/Persistence/*.swift)
for source in AccountService CredentialStore ProviderAdapter ProviderError RateService SyncMerge SyncConflictService FileSyncService SyncFileWorker HTTPClient DeepSeekUsageService; do
  COMMON_SOURCES+=("$ROOT/Sources/Relay/Services/$source.swift")
done
SUITES=(DeepSeekUsageContractTests GlobalShortcutContractTests SyncConflictContractTests)
for suite in "${SUITES[@]}"; do
  case "$suite" in
    DeepSeekUsageContractTests)
      SOURCES=("${COMMON_SOURCES[@]}" "$ROOT/Sources/Relay/Services/DeepSeekAdapter.swift") ;;
    GlobalShortcutContractTests)
      SOURCES=("$ROOT/Sources/Relay/Services/GlobalShortcutService.swift") ;;
    SyncConflictContractTests) SOURCES=("${COMMON_SOURCES[@]}") ;;
  esac
  echo "BUILD: $suite"
  CLANG_MODULE_CACHE_PATH="$WORK/clang-cache" swiftc "${COMPILE[@]}" "${SOURCES[@]}" \
    "$ROOT/Tests/$suite.swift" -o "$WORK/$suite"
  echo "RUN: $suite (offline, isolated fixtures)"
  "${RUN_ENV[@]}" "$WORK/$suite"
done
# The GUI prerequisite guard is also testable headlessly using dictionary fixtures.
CLANG_MODULE_CACHE_PATH="$WORK/clang-cache" swiftc "${COMPILE[@]}" -D RELAY_GUI_SESSION_PROBE \
  "$ROOT/Tests/GUIVerificationSession.swift" -o "$WORK/gui-session-probe"
"${RUN_ENV[@]}" "$WORK/gui-session-probe" --self-test
echo "PASSED: all 3 offline contract suites and GUI-session guard fixtures; GUI navigation and real doubleMac were not run."
