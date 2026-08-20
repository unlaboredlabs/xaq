#!/bin/sh
set -eu

fail() {
    printf 'package-edge: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 4 ] || fail 'usage: package-edge.sh PLATFORM TARGET GIT_SHA VERSION'
platform=$1
target=$2
git_sha=$3
version=$4

case "$platform/$target" in
    linux-x86_64/x86_64-linux | \
        linux-aarch64/aarch64-linux | \
        macos-x86_64/x86_64-macos | \
        macos-aarch64/aarch64-macos) ;;
    *) fail "unsupported platform and target: $platform/$target" ;;
esac

[ "${#git_sha}" -eq 40 ] || fail 'GIT_SHA must contain 40 lowercase hexadecimal characters'
case "$git_sha" in
    *[!0-9a-f]*) fail 'GIT_SHA must contain 40 lowercase hexadecimal characters' ;;
esac
printf '%s\n' "$version" | awk '/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-edge\.[1-9][0-9]*)?$/ { found = 1 } END { exit !found }' || \
    fail 'VERSION must have semantic version form X.Y.Z or X.Y.Z-edge.N'

scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xaq-edge-package.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

asset="xaq-${platform}-${git_sha}"
package_dir="$scratch/package/$asset"
install_prefix="$scratch/install"
mkdir -p dist "$package_dir"

zig build -Doptimize=ReleaseSmall -Dtarget="$target" -Dversion="$version" -Dgit-sha="$git_sha" --prefix "$install_prefix"
cp "$install_prefix/bin/xaq" "dist/$asset"
cp "$install_prefix/bin/xaq" README.md LICENSE "$package_dir/"
tar -czf "dist/$asset.tar.gz" -C "$scratch/package" "$asset"
