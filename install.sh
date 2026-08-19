#!/bin/sh
set -eu

release_url=https://github.com/unlaboredlabs/xaq/releases/download/edge

fail() {
    printf 'xaq: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64) asset=xaq-linux-x86_64 ;;
    Linux/aarch64|Linux/arm64) asset=xaq-linux-aarch64 ;;
    Darwin/x86_64|Darwin/amd64) asset=xaq-macos-x86_64 ;;
    Darwin/arm64|Darwin/aarch64) asset=xaq-macos-aarch64 ;;
    *) fail "no edge build is available for $(uname -s)/$(uname -m)" ;;
esac

install_dir=${XAQ_INSTALL_DIR:-"${HOME:?HOME is not set}/.local/bin"}
download_dir=$(mktemp -d "${TMPDIR:-/tmp}/xaq-install.XXXXXX")
install_tmp=
cleanup() {
    rm -rf "$download_dir"
    if [ -n "$install_tmp" ]; then rm -f "$install_tmp"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

curl -fsSL "$release_url/SHA256SUMS" -o "$download_dir/SHA256SUMS"
curl -fsSL "$release_url/$asset" -o "$download_dir/$asset"

expected=$(awk -v file="$asset" '$2 == file || $2 == ("*" file) { print $1; exit }' "$download_dir/SHA256SUMS")
[ "${#expected}" -eq 64 ] || fail "SHA256SUMS has no entry for $asset"
case "$expected" in *[!0-9a-fA-F]*) fail 'release checksum is malformed' ;; esac

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$download_dir/$asset" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$download_dir/$asset" | awk '{print $1}')
else
    fail 'sha256sum or shasum is required'
fi
[ "$actual" = "$expected" ] || fail 'downloaded edge binary failed checksum verification'

mkdir -p "$install_dir"
install_tmp=$(mktemp "$install_dir/.xaq.XXXXXX")
install -m 755 "$download_dir/$asset" "$install_tmp"
mv -f "$install_tmp" "$install_dir/xaq"
install_tmp=

printf 'installed xaq edge to %s/xaq\n' "$install_dir"
case ":${PATH:-}:" in
    *:"$install_dir":*) ;;
    *) printf 'add %s to PATH to run xaq\n' "$install_dir" ;;
esac
