#!/bin/bash
# Optional AppKit integration check. Default execution opens/focuses synthetic windows.
# Keep separate from headless contracts; unavailable GUI prerequisites exit 77, not PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---run}"
if [[ $# -gt 1 ]]; then MODE=invalid; fi
case "$MODE" in
  --run|--build-only|--check-session) ;;
  --help|-h)
    echo "Usage: $0 [--run | --build-only | --check-session]"
    echo "  --run           Open/focus test windows in a logged-in GUI session (default)."
    echo "  --build-only    Compile integration checks without probing or manipulating GUI."
    echo "  --check-session Read-only session probe; no windows, no navigation test."
    echo "Exit: 0 = requested action completed; 77 = no usable GUI session; other = failure."
    exit 0 ;;
  *) echo "Usage: $0 [--run | --build-only | --check-session]" >&2; exit 64 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIPPED: GUI navigation requires macOS and a logged-in graphical session. No GUI tests ran." >&2
  exit 77
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-navigation.XXXXXX")"
TEST_PID=""
WATCHDOG_PID=""
cleanup() {
  if [[ -n "$WATCHDOG_PID" ]]; then kill "$WATCHDOG_PID" 2>/dev/null || true; fi
  if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/module-cache" "$WORK/clang-cache"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
COMPILE=(-swift-version 5 -D DEBUG -parse-as-library -sdk "$SDK"
  -module-cache-path "$WORK/module-cache")
export CLANG_MODULE_CACHE_PATH="$WORK/clang-cache"
if [[ "$MODE" != --build-only ]]; then
  swiftc "${COMPILE[@]}" -D RELAY_GUI_SESSION_PROBE \
    "$ROOT/Tests/GUIVerificationSession.swift" -o "$WORK/gui-session-probe"
  "$WORK/gui-session-probe"
  if [[ "$MODE" == --check-session ]]; then exit 0; fi
fi
# Compile a temporary source snapshot: parallel editors must not invalidate files
# while Swift is reading them. All production code remains unchanged in the checkout.
SNAPSHOT="$WORK/source"
mkdir -p "$SNAPSHOT/Tests"
cp -R "$ROOT/Sources" "$SNAPSHOT/Sources"
cp "$ROOT/Tests/AccountDetailRefreshChecks.swift" "$ROOT/Tests/GUIVerificationSession.swift" \
  "$ROOT/Tests/WindowNavigationContractChecks.swift" "$SNAPSHOT/Tests/"
mkdir -p "$WORK/RelayNavigationChecks.app/Contents/MacOS"
BINARY="$WORK/RelayNavigationChecks.app/Contents/MacOS/relay-navigation-checks"
swiftc "${COMPILE[@]}" \
  "$SNAPSHOT"/Sources/Relay/Models/*.swift "$SNAPSHOT"/Sources/Relay/Persistence/*.swift \
  "$SNAPSHOT"/Sources/Relay/Services/*.swift "$SNAPSHOT"/Sources/Relay/UI/*.swift \
  "$SNAPSHOT/Tests/AccountDetailRefreshChecks.swift" \
  "$SNAPSHOT/Tests/GUIVerificationSession.swift" \
  "$SNAPSHOT/Tests/WindowNavigationContractChecks.swift" -o "$BINARY"
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
if [[ "$MODE" == --build-only ]]; then
  echo "BUILT: GUI navigation checks compile successfully. GUI navigation was NOT run."
  exit 0
fi
TIMEOUT="${RELAY_NAVIGATION_TIMEOUT_SECONDS:-120}"
if [[ ! "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAILED: RELAY_NAVIGATION_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 64
fi
echo "RUN: GUI navigation (offline fixtures; may open/focus windows; timeout ${TIMEOUT}s)"
# Preserve the caller's WindowServer session, but isolate preferences and omit credentials.
env -i "PATH=$PATH" "HOME=$WORK/home" "CFFIXED_USER_HOME=$WORK/home" \
  "TMPDIR=$WORK/tmp/" "LANG=en_US.UTF-8" "$BINARY" &
TEST_PID=$!
(
  # Reap the timer when tests finish early; do not leave a background sleep behind.
  SLEEP_PID=""
  trap 'if [[ -n "$SLEEP_PID" ]]; then kill "$SLEEP_PID" 2>/dev/null || true; wait "$SLEEP_PID" 2>/dev/null || true; fi; exit 0' TERM INT
  sleep "$TIMEOUT" &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
  SLEEP_PID=""
  if kill -0 "$TEST_PID" 2>/dev/null; then
    echo "FAILED: GUI navigation timed out after ${TIMEOUT}s." >&2
    kill "$TEST_PID" 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!
RESULT=0
wait "$TEST_PID" || RESULT=$?
TEST_PID=""
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=""
exit "$RESULT"
