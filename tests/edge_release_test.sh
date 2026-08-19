#!/bin/sh
set -eu

fail() {
    printf 'edge_release_test: %s\n' "$*" >&2
    exit 1
}

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-edge-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

git_sha=0123456789abcdef0123456789abcdef01234567
dist="$scratch/dist"
mkdir -p "$dist"
for platform in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64; do
    asset="xaq-$platform-$git_sha"
    package="$scratch/$asset"
    mkdir -p "$package"
    printf 'binary for %s\n' "$platform" > "$dist/$asset"
    cp "$dist/$asset" "$package/xaq"
    cp "$repo/README.md" "$repo/LICENSE" "$package/"
    tar -czf "$dist/$asset.tar.gz" -C "$scratch" "$asset"
done

[ "$(find "$dist" -mindepth 1 -maxdepth 1 -type f -name 'xaq-*' | wc -l | tr -d ' ')" -eq 8 ] || \
    fail 'xaq-* did not select all eight non-archived artifacts'
workflow="$repo/.github/workflows/ci.yml"
[ "$(grep -Fc 'archive: false' "$workflow")" -eq 2 ] || fail 'workflow must have two single-file uploads'
[ "$(grep -Ec '^[[:space:]]+path: dist/xaq-.*matrix\.platform.*github\.sha' "$workflow")" -eq 2 ] || \
    fail 'workflow upload paths changed'
grep -Eq '^[[:space:]]+path: dist/xaq-.*github\.sha.*\.tar\.gz$' "$workflow" || \
    fail 'workflow archive upload path changed'
grep -Fq 'pattern: xaq-*' "$workflow" || fail 'download pattern does not match archive:false artifact names'
if grep -Fq 'name: edge-' "$workflow"; then
    fail 'workflow relies on a custom archive:false artifact name'
fi

"$repo/tools/prepare-edge.sh" "$dist" "$git_sha"
manifest="$dist/edge-manifest-$git_sha"
"$repo/tools/validate-edge-manifest.sh" "$manifest"
grep -Fx "xaq-edge-v1 $git_sha" "$manifest" >/dev/null || fail 'manifest header differs'
grep -F "xaq-linux-aarch64-$git_sha" "$manifest" >/dev/null || fail 'manifest lacks Linux aarch64'
grep -F "xaq-macos-x86_64-$git_sha" "$manifest" >/dev/null || fail 'manifest lacks macOS x86_64'

cp "$manifest" "$scratch/bad-manifest"
printf 'xaq-linux-x86_64 xaq-linux-x86_64-%s %064d\n' "$git_sha" 0 >> "$scratch/bad-manifest"
if "$repo/tools/validate-edge-manifest.sh" "$scratch/bad-manifest" >/dev/null 2>&1; then
    fail 'validator accepted a duplicate asset'
fi

printf 'not a tar archive\n' > "$dist/xaq-linux-x86_64-$git_sha.tar.gz"
rm -f "$manifest"
if "$repo/tools/prepare-edge.sh" "$dist" "$git_sha" >/dev/null 2>&1; then
    fail 'preparation accepted a corrupt archive'
fi
