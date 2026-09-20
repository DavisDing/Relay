#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

# Only the cleaned ICNS is shipped; the PNG master stays in the source tree.
icon_path="$root_dir/Resources/AppIcon.icns"
if [[ ! -f "$icon_path" ]] || ! file "$icon_path" | grep -q 'Mac OS X icon'; then
    echo "Missing or invalid ICNS app icon: $icon_path" >&2
    exit 1
fi

output_dir="${1:-$root_dir/.build/package}"
scratch_path="${SWIFT_SCRATCH_PATH:-$root_dir/.build/ci-scratch}"
configuration="${SWIFT_CONFIGURATION:-release}"
mkdir -p "$output_dir" "$scratch_path"

version_output="$("$root_dir/scripts/ci-version.sh")"
marketing_version="$(printf '%s\n' "$version_output" | awk -F= '$1 == "marketing_version" { print $2 }')"
build_number="$(printf '%s\n' "$version_output" | awk -F= '$1 == "build_number" { print $2 }')"
commit_sha="$(printf '%s\n' "$version_output" | awk -F= '$1 == "commit_sha" { print $2 }')"

if [[ -z "$marketing_version" || -z "$build_number" ]]; then
    echo "Unable to calculate Relay version" >&2
    exit 1
fi

swift build \
    --configuration "$configuration" \
    --arch arm64 \
    --scratch-path "$scratch_path"

bin_path="$(swift build \
    --configuration "$configuration" \
    --arch arm64 \
    --scratch-path "$scratch_path" \
    --show-bin-path)"
binary="$bin_path/Relay"
if [[ ! -x "$binary" ]]; then
    echo "Built executable not found: $binary" >&2
    exit 1
fi

app_name="Relay.app"
app_dir="$output_dir/$app_name"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary" "$app_dir/Contents/MacOS/Relay"
cp "$icon_path" "$app_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$app_dir/Contents/MacOS/Relay"

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Relay</string>
    <key>CFBundleExecutable</key>
    <string>Relay</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>cloud.dinghao.relay</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Relay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$marketing_version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# The current release plan is GitHub Releases with ad-hoc signing. This keeps
# the archive launchable while avoiding a Developer ID dependency.
codesign --force --deep --sign - --timestamp=none "$app_dir"

archive_name="Relay-${marketing_version}-macos-arm64.zip"
archive_path="$output_dir/$archive_name"
rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"

metadata_name="Relay-${marketing_version}-metadata.txt"
cat > "$output_dir/$metadata_name" <<METADATA
name=Relay
version=$marketing_version
build=$build_number
commit=$commit_sha
platform=macos-arm64
archive=$archive_name
metadata=$metadata_name
METADATA

printf 'Packaged %s (version %s, build %s, commit %s)\n' "$archive_path" "$marketing_version" "$build_number" "$commit_sha"
