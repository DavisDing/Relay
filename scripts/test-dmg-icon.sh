#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/relay-dmg-icon-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/source"
printf 'Relay disk image icon fixture\n' > "$work/source/fixture.txt"
bash "$root_dir/scripts/create-dmg.sh" \
    "$work/source" 'Relay icon check' "$work/original.dmg" >/dev/null
swift -module-cache-path "$work/module-cache" "$root_dir/scripts/set-dmg-icon.swift" \
    "$root_dir/Resources/AppIcon.icns" "$work/original.dmg"

# Reproduce an upload/download: copy data bytes only, without Finder metadata.
cat "$work/original.dmg" > "$work/downloaded.dmg"
hdiutil udifderez -xml "$work/downloaded.dmg" > "$work/resources.plist"
[[ "$(plutil -extract icns.0.ID raw "$work/resources.plist")" == '-16455' ]]
plutil -extract icns.0.Data raw "$work/resources.plist" | base64 -D > "$work/embedded.icns"
cmp "$root_dir/Resources/AppIcon.icns" "$work/embedded.icns"
hdiutil verify "$work/downloaded.dmg" >/dev/null

# Reject bad input before modifying a valid image.
shasum -a 256 "$work/downloaded.dmg" > "$work/before.sha"
printf 'invalid icon\n' > "$work/invalid.icns"
if swift -module-cache-path "$work/module-cache" "$root_dir/scripts/set-dmg-icon.swift" \
    "$work/invalid.icns" "$work/downloaded.dmg" > "$work/rejected.log" 2>&1; then
    echo 'FAILED: invalid ICNS was accepted' >&2
    exit 1
fi
shasum -a 256 --check "$work/before.sha" >/dev/null
echo 'PASSED: DMG icon survives a data-only download, image checksums remain valid, invalid icons leave the image intact. Finder display was NOT tested.'
