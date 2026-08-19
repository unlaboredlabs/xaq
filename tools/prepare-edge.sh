#!/bin/sh
set -eu

fail() {
    printf 'prepare-edge: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail 'usage: prepare-edge.sh DIST_DIR GIT_SHA'
dist=$1
git_sha=$2
[ -d "$dist" ] || fail "missing artifact directory: $dist"
[ "${#git_sha}" -eq 40 ] || fail 'GIT_SHA must contain 40 lowercase hexadecimal characters'
case "$git_sha" in
    *[!0-9a-f]*) fail 'GIT_SHA must contain 40 lowercase hexadecimal characters' ;;
esac

[ "$(find "$dist" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 8 ] || \
    fail 'artifact directory must contain exactly eight files'
[ -z "$(find "$dist" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] || \
    fail 'artifact directory contains an unexpected entry'

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        fail 'sha256sum or shasum is required'
    fi
}

manifest="$dist/edge-manifest-$git_sha"
manifest_tmp=$(mktemp "$dist/.edge-manifest.XXXXXX")
cleanup() {
    rm -f "$manifest_tmp"
}
trap cleanup EXIT HUP INT TERM
printf 'xaq-edge-v1 %s\n' "$git_sha" > "$manifest_tmp"

for platform in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64; do
    base="xaq-$platform"
    asset="$base-$git_sha"
    binary="$dist/$asset"
    archive="$binary.tar.gz"
    [ -s "$binary" ] || fail "missing binary: $binary"
    [ -s "$archive" ] || fail "missing archive: $archive"

    entries=$(tar -tzf "$archive") || fail "could not read archive: $archive"
    for member in xaq README.md LICENSE; do
        printf '%s\n' "$entries" | grep -Fx "$asset/$member" >/dev/null || \
            fail "$archive is missing $asset/$member"
    done
    tar -xOzf "$archive" "$asset/xaq" | cmp - "$binary" >/dev/null || \
        fail "$archive and raw binary differ for $platform"

    printf '%s %s %s\n' "$base" "$asset" "$(digest_file "$binary")" >> "$manifest_tmp"
    printf '%s %s %s\n' "$base.tar.gz" "$asset.tar.gz" "$(digest_file "$archive")" >> "$manifest_tmp"
done

mv "$manifest_tmp" "$manifest"
trap - EXIT HUP INT TERM
"$(dirname "$0")/validate-edge-manifest.sh" "$manifest"
