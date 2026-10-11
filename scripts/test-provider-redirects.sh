#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-provider-redirect.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -parse-as-library -sdk "$SDK" -module-cache-path "$WORK/cache" \
  "$ROOT/Sources/Relay/Services/HTTPClient.swift" "$ROOT/Sources/Relay/Services/ProviderError.swift" \
  "$ROOT/Tests/ProviderRedirectIntegrationChecks.swift" -o "$WORK/checks"
python3 "$ROOT/Tests/Fixtures/provider_redirect_server.py" "$WORK/addresses.json" &
SERVER_PID=$!
# Wait at most five seconds for the loopback fixture; no external traffic.
for attempt in {1..50}; do
  if [[ -s "$WORK/addresses.json" ]]; then break; fi
  kill -0 "$SERVER_PID"
  sleep 0.1
done
read -r FIRST SECOND < <(python3 -c 'import json,sys; print(*json.load(open(sys.argv[1])))' "$WORK/addresses.json")
"$WORK/checks" "$FIRST" "$SECOND"
