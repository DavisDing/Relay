#!/usr/bin/env bash
set -euo pipefail

# Relay uses the commit count as its monotonically increasing build number.
# For normal branch builds this is also the patch part of the marketing version.
# A semantic-version tag (for example v1.2.3) is preferred for a published release.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

commit_count="$(git rev-list --count HEAD)"
commit_sha="$(git rev-parse --short=12 HEAD)"

if [[ -n "${RELAY_VERSION:-}" ]]; then
    marketing_version="$RELAY_VERSION"
else
    ref="${GITHUB_REF:-}"
    if [[ "$ref" == refs/tags/v* ]]; then
        marketing_version="${ref#refs/tags/v}"
    elif tag="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"; [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        marketing_version="${tag#v}"
    else
        prefix="${RELAY_VERSION_PREFIX:-0.1}"
        if [[ ! "$prefix" =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "RELAY_VERSION_PREFIX must match <major>.<minor>, got: $prefix" >&2
            exit 2
        fi
        marketing_version="${prefix}.${commit_count}"
    fi
fi

if [[ ! "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must match semantic versioning (x.y.z), got: $marketing_version" >&2
    exit 2
fi

# GitHub Actions accepts these lines via $GITHUB_OUTPUT. The same output is also
# intentionally valid shell-free text for local inspection and packaging scripts.
echo "marketing_version=$marketing_version"
echo "build_number=$commit_count"
echo "commit_sha=$commit_sha"
