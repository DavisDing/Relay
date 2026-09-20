#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$ROOT/Tests/Fixtures/MultiDeviceSync"
REPORT=""
MODE="deterministic"

usage() {
  cat <<EOF
Usage: $0 [--fixture-dir <path>] [--report <path>] [--mode deterministic|manual]

Runs the iCloud multi-device sync verification baseline without modifying Relay
source code or sync data. A real second Mac is never inferred from fixtures.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture-dir)
      [[ $# -ge 2 ]] || { echo "--fixture-dir requires a path" >&2; exit 1; }
      FIXTURE_DIR="$2"
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || { echo "--report requires a path" >&2; exit 1; }
      REPORT="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || { echo "--mode requires deterministic|manual" >&2; exit 1; }
      MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  deterministic|manual) ;;
  *)
    echo "Invalid --mode: $MODE (expected deterministic or manual)" >&2
    exit 1
    ;;
esac

python3 - "$FIXTURE_DIR" "$REPORT" "$MODE" <<'PY'
import datetime as dt
import json
import os
import sys
import uuid
from pathlib import Path

fixture_dir = Path(sys.argv[1]).expanduser().resolve()
report_path_arg = sys.argv[2]
mode = sys.argv[3]

cases = []
blocking_issues = []


def add_case(case_id, name, status, details):
    cases.append({
        "id": case_id,
        "name": name,
        "status": status,
        "details": details,
    })


def load_json(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_date(value):
    if not isinstance(value, str):
        raise ValueError("date is not a string")
    normalized = value.replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.timestamp()


def require_file(path, label):
    if not path.is_file():
        raise AssertionError(f"missing {label}: {path}")
    return path


def validate_payload(payload, label):
    if not isinstance(payload, dict):
        raise AssertionError(f"{label} must be a JSON object")
    if payload.get("schemaVersion") != 1:
        raise AssertionError(f"{label}.schemaVersion must be 1")
    if not isinstance(payload.get("exportedAt"), str):
        raise AssertionError(f"{label}.exportedAt must be ISO-8601")
    parse_date(payload["exportedAt"])
    if not isinstance(payload.get("accounts"), list):
        raise AssertionError(f"{label}.accounts must be an array")
    if not isinstance(payload.get("snapshots"), list):
        raise AssertionError(f"{label}.snapshots must be an array")
    if not isinstance(payload.get("dailyUsage"), list):
        raise AssertionError(f"{label}.dailyUsage must be an array")
    settings = payload.get("settings")
    if not isinstance(settings, dict) or settings.get("schemaVersion") != 1:
        raise AssertionError(f"{label}.settings.schemaVersion must be 1")
    if not isinstance(payload.get("deletedAccountIDs"), dict):
        raise AssertionError(f"{label}.deletedAccountIDs must be an object")

    account_ids = set()
    for account in payload["accounts"]:
        if not isinstance(account, dict):
            raise AssertionError(f"{label}.accounts contains a non-object")
        for key in ("id", "displayName", "providerKind", "siteOrigin", "credentialReference", "updatedAt"):
            if key not in account:
                raise AssertionError(f"{label}.accounts item missing {key}")
        try:
            account_id = str(uuid.UUID(account["id"]))
        except (ValueError, TypeError, AttributeError):
            raise AssertionError(f"{label}.accounts contains an invalid UUID")
        account_ids.add(account_id)
        parse_date(account["updatedAt"])

    for account_id, deleted_at in payload["deletedAccountIDs"].items():
        try:
            uuid.UUID(account_id)
        except (ValueError, TypeError, AttributeError):
            raise AssertionError(f"{label}.deletedAccountIDs contains an invalid UUID")
        parse_date(deleted_at)

    for snapshot in payload["snapshots"]:
        if not isinstance(snapshot, dict) or "accountID" not in snapshot or "fetchedAt" not in snapshot:
            raise AssertionError(f"{label}.snapshots contains an invalid record")
        parse_date(snapshot["fetchedAt"])

    return account_ids


def walk_values(value, path=()):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk_values(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_values(child, path + (str(index),))


try:
    if not fixture_dir.is_dir():
        raise AssertionError(f"fixture directory does not exist: {fixture_dir}")

    local_path = require_file(fixture_dir / "local" / "relay-sync-v1.json", "local payload")
    remote_path = require_file(fixture_dir / "remote" / "relay-sync-v1.json", "remote payload")
    expected_path = require_file(fixture_dir / "expected" / "merged-relay-sync-v1.json", "expected merged payload")
    local = load_json(local_path)
    remote = load_json(remote_path)
    expected = load_json(expected_path)

    # 1. Secrets must not be present in any sync payload or fixture manifest.
    sensitive_keys = {
        "secret", "pipiouserid", "pipio_user_id", "userid", "user_id", "usertoken",
        "apikey", "api_key", "accesstoken", "refreshtoken", "cookie", "password",
    }
    sensitive_markers = ("sk-", "bearer ", "user_token", "api_key=")
    findings = []
    for path in sorted(fixture_dir.rglob("*.json")):
        payload = load_json(path)
        for key_path, value in walk_values(payload):
            normalized_key = key_path[-1].lower().replace("-", "_") if key_path else ""
            if normalized_key in sensitive_keys:
                findings.append(f"{path.relative_to(fixture_dir)}:{'.'.join(key_path)}")
            if isinstance(value, str) and any(marker in value.lower() for marker in sensitive_markers):
                findings.append(f"{path.relative_to(fixture_dir)}:{'.'.join(key_path)}")
    if findings:
        raise AssertionError("sensitive sync fields found: " + ", ".join(findings))
    add_case("SYNC-001", "credentials-excluded", "passed", "sync payloads contain no credential or secret fields; credentialReference remains opaque")

    # 2. Validate schema and confirm tombstones can suppress an older account record.
    local_ids = validate_payload(local, "local payload")
    remote_ids = validate_payload(remote, "remote payload")
    expected_ids = validate_payload(expected, "expected merged payload")
    all_tombstones = {}
    for payload in (local, remote):
        for account_id, deleted_at in payload["deletedAccountIDs"].items():
            all_tombstones[account_id] = max(all_tombstones.get(account_id, float("-inf")), parse_date(deleted_at))
    expected_tombstones = expected["deletedAccountIDs"]
    for account_id, deleted_at in all_tombstones.items():
        if account_id not in expected_tombstones:
            raise AssertionError(f"tombstone {account_id} was not preserved")
        if account_id in expected_ids:
            raise AssertionError(f"tombstoned account {account_id} remains in merged accounts")
        for payload_name, payload in (("local", local), ("remote", remote)):
            for account in payload["accounts"]:
                if account["id"] == account_id and parse_date(account["updatedAt"]) <= deleted_at:
                    break
    if not all_tombstones:
        raise AssertionError("fixtures do not contain a tombstone")
    add_case("SYNC-002", "tombstone-and-schema", "passed", "schemaVersion=1 is valid and deletion tombstones suppress older account records")

    # 3. Conflict copies must be readable and remain side-by-side.
    conflicts_dir = fixture_dir / "conflicts"
    conflict_files = sorted(path for path in conflicts_dir.glob("*.json") if path.is_file())
    if len(conflict_files) < 2:
        raise AssertionError("expected at least two retained conflict payloads")
    conflict_payloads = []
    for path in conflict_files:
        conflict_payload = load_json(path)
        validate_payload(conflict_payload, f"conflict payload {path.name}")
        conflict_payloads.append(conflict_payload)
    if len({payload["exportedAt"] for payload in conflict_payloads}) < 2:
        raise AssertionError("retained conflict payloads must represent distinct versions")
    add_case("SYNC-003", "conflict-copies-retained", "passed", f"{len(conflict_files)} readable conflict copies remain side-by-side; the verifier does not delete or resolve them")

    # 4. Offline local data must be usable without cloud availability.
    offline_path = require_file(fixture_dir / "offline" / "local-repository.json", "offline local repository fixture")
    offline = load_json(offline_path)
    if offline.get("localDataAvailable") is not True:
        raise AssertionError("offline fixture does not declare local data available")
    if offline.get("cloudDataAvailable") is not False:
        raise AssertionError("offline fixture must explicitly declare cloud data unavailable")
    if not isinstance(offline.get("accounts"), list) or not offline["accounts"]:
        raise AssertionError("offline fixture must retain at least one local account")
    add_case("SYNC-004", "offline-local-availability", "passed", "local account data remains readable while cloud data is unavailable")

    # The script cannot verify a real second Mac. Fixtures are deliberately not
    # evidence of a multi-device run, so this case is never marked passed here.
    second_mac_status = "not_run" if mode == "manual" else "blocked"
    second_mac_details = (
        "manual mode: operator must run the checklist on two Macs outside this script"
        if mode == "manual"
        else "not executed: deterministic fixtures are not evidence of a second physical Mac"
    )
    add_case("SYNC-005", "real-second-mac", second_mac_status, second_mac_details)
    blocking_issues.append("真实第二台 Mac 的多设备验证未在脚本中执行；不能用 fixture 结果代替")

except (OSError, json.JSONDecodeError, AssertionError, ValueError) as error:
    add_case("SYNC-ERR", "fixture-baseline", "failed", str(error))

has_failed = any(case["status"] == "failed" for case in cases)
has_blocked = any(case["status"] in ("blocked", "not_run") for case in cases)
status = "failed" if has_failed else ("blocked" if has_blocked else "passed")
report = {
    "status": status,
    "mode": mode,
    "fixtureDir": str(fixture_dir),
    "cases": cases,
    "blockingIssues": blocking_issues,
    "generatedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
if report_path_arg:
    report_path = Path(report_path_arg).expanduser().resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(encoded, encoding="utf-8")
print(encoded, end="")
if status == "failed":
    sys.exit(1)
if status == "blocked":
    sys.exit(2)
sys.exit(0)
