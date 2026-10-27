#!/usr/bin/env bash
# Shared by release packaging and the DMG icon integration check.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo 'Usage: create-dmg.sh <source-directory> <volume-name> <output.dmg>' >&2
    exit 64
fi
source_dir="$1"
volume_name="$2"
output_path="$3"
if [[ ! -d "$source_dir" || "$output_path" != *.dmg ]]; then
    echo 'DMG creation requires a source directory and a .dmg output path.' >&2
    exit 64
fi
if [[ -e "$output_path" || -L "$output_path" ]]; then
    echo "Refusing to overwrite existing DMG: $output_path" >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/relay-create-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
max_attempts=5
for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    # A failed create can leave a partial file; each retry gets a fresh path.
    image="$work/attempt-$attempt.dmg"
    if LC_ALL=C hdiutil create -volname "$volume_name" -srcfolder "$source_dir" \
        -format UDZO "$image" > "$work/create.log" 2>&1; then
        cat "$work/create.log"
        mv -n "$image" "$output_path"
        if [[ -e "$image" ]]; then
            echo "Refusing to overwrite existing DMG: $output_path" >&2
            exit 1
        fi
        exit 0
    else
        result=$?
    fi
    cat "$work/create.log" >&2
    # hdiutil create can report EBUSY with exit code 1, so match its diagnostic.
    # Permission, input and format errors must still fail immediately.
    if ! grep -Fq 'hdiutil: create failed - Resource busy' "$work/create.log" || \
        [[ "$attempt" -eq "$max_attempts" ]]; then
        exit "$result"
    fi
    delay=$((attempt * 2))
    echo "DMG resource busy (attempt $attempt/$max_attempts); retrying in ${delay}s." >&2
    sleep "$delay"
done
