#!/usr/bin/env bash
# Exercise retry/error handling without creating or mounting real disk images.
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/relay-dmg-creation-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/source with spaces" "$work/tmp"
printf 'source preserved\n' > "$work/source with spaces/fixture.txt"
cat > "$work/bin/hdiutil" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$RELAY_DMG_FIXTURE/count" ]]; then
    count="$(cat "$RELAY_DMG_FIXTURE/count")"
fi
count=$((count + 1))
echo "$count" > "$RELAY_DMG_FIXTURE/count"
image="${!#}"
[[ ! -e "$image" ]] || { echo 'Fixture received a partial image from an earlier attempt' >&2; exit 99; }
printf 'partial image\n' > "$image"
case "$RELAY_DMG_FIXTURE_MODE" in
    success) ;;
    recover) if [[ "$count" -lt 3 ]]; then
        echo 'hdiutil: create failed - Resource busy' >&2; exit 1
    fi ;;
    busy) echo 'hdiutil: create failed - Resource busy' >&2; exit 1 ;;
    denied) echo 'hdiutil: create failed - Permission denied' >&2; exit 17 ;;
    *) exit 98 ;;
esac
printf 'complete image\n' > "$image"
FIXTURE
cat > "$work/bin/sleep" <<'FIXTURE'
#!/usr/bin/env bash
echo "$1" >> "$RELAY_DMG_FIXTURE/sleeps"
FIXTURE
chmod +x "$work/bin/hdiutil" "$work/bin/sleep"

run_case() {
    local mode="$1" expected_result="$2" expected_calls="$3" expected_sleeps="$4"
    local case_dir="$work/$mode" result=0
    mkdir -p "$case_dir"
    env PATH="$work/bin:$PATH" TMPDIR="$work/tmp/" RELAY_DMG_FIXTURE="$case_dir" \
        RELAY_DMG_FIXTURE_MODE="$mode" \
        bash "$root_dir/scripts/create-dmg.sh" "$work/source with spaces" 'Relay fixture' \
        "$case_dir/output with spaces.dmg" > "$case_dir/log" 2>&1 || result=$?
    [[ "$result" -eq "$expected_result" ]]
    [[ "$(cat "$case_dir/count")" -eq "$expected_calls" ]]
    local sleeps=0
    if [[ -f "$case_dir/sleeps" ]]; then sleeps="$(wc -l < "$case_dir/sleeps")"; fi
    [[ "$sleeps" -eq "$expected_sleeps" ]]
    if [[ "$result" -eq 0 ]]; then
        [[ "$(cat "$case_dir/output with spaces.dmg")" == 'complete image' ]]
    else
        [[ ! -e "$case_dir/output with spaces.dmg" ]]
    fi
    [[ -z "$(ls -A "$work/tmp")" ]]
}
run_case success 0 1 0
run_case recover 0 3 2
run_case busy 1 5 4
run_case denied 17 1 0

# Existing caller files are never removed or overwritten, even on success.
result=0
env PATH="$work/bin:$PATH" RELAY_DMG_FIXTURE="$work/success" RELAY_DMG_FIXTURE_MODE=success \
    bash "$root_dir/scripts/create-dmg.sh" "$work/source with spaces" 'Relay fixture' \
    "$work/success/output with spaces.dmg" > "$work/existing.log" 2>&1 || result=$?
[[ "$result" -ne 0 && "$(cat "$work/success/count")" -eq 1 ]]
[[ "$(cat "$work/success/output with spaces.dmg")" == 'complete image' ]]
[[ "$(cat "$work/source with spaces/fixture.txt")" == 'source preserved' ]]
echo 'PASSED: DMG busy recovery, bounded retries, immediate other-error failure, partial cleanup and existing-file preservation.'
