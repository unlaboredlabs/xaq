#!/bin/sh
set -eu

fail() {
    printf 'version_test: %s\n' "$*" >&2
    exit 1
}

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-version-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

base_version=$(awk -F'"' '/^[[:space:]]*\.version = "/ { print $2; exit }' "$repo/build.zig.zon")
[ -n "$base_version" ] || fail 'could not read the package version'
zig build --build-file "$repo/build.zig" --prefix "$scratch/base"
reported=$("$scratch/base/bin/xaq" --version)
[ "$reported" = "xaq $base_version" ] || fail "default binary reported $reported"

version="$base_version-edge.42"
git_sha=0123456789abcdef0123456789abcdef01234567
zig build --build-file "$repo/build.zig" -Dversion="$version" -Dgit-sha="$git_sha" --prefix "$scratch/install"
reported=$("$scratch/install/bin/xaq" --version)
[ "$reported" = "xaq $version" ] || fail "binary reported $reported"
