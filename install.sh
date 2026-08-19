#!/bin/sh
set -eu

manifest_url=https://raw.githubusercontent.com/unlaboredlabs/xaq/edge-channel/manifest
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

curl -fsSL "$manifest_url" -o "$download_dir/manifest"
release_sha=$(awk 'NR == 1 && NF == 2 && $1 == "xaq-edge-v1" { print $2 }' "$download_dir/manifest")
[ "${#release_sha}" -eq 40 ] || fail 'edge manifest header is malformed'
case "$release_sha" in *[!0-9a-f]*) fail 'edge manifest commit is malformed' ;; esac

record=$(awk -v logical="$asset" '
    NR > 1 && $1 == logical {
        if (NF != 3 || found) bad = 1
        found = 1
        value = $2 "\t" $3
    }
    END {
        if (bad || !found) exit 1
        print value
    }
' "$download_dir/manifest") || fail "edge manifest has no unique entry for $asset"
tab=$(printf '\t')
filename=${record%%"$tab"*}
expected=${record#*"$tab"}
[ "$filename" = "$asset-$release_sha" ] || fail 'edge manifest mixes release generations'
[ "${#expected}" -eq 64 ] || fail 'edge manifest checksum is malformed'
case "$expected" in *[!0-9a-f]*) fail 'edge manifest checksum is malformed' ;; esac

curl -fsSL "$release_url/$filename" -o "$download_dir/$filename"

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$download_dir/$filename" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$download_dir/$filename" | awk '{print $1}')
else
    fail 'sha256sum or shasum is required'
fi
[ "$actual" = "$expected" ] || fail 'downloaded edge binary failed checksum verification'

mkdir -p "$install_dir"
install_tmp=$(mktemp "$install_dir/.xaq.XXXXXX")
install -m 755 "$download_dir/$filename" "$install_tmp"
mv -f "$install_tmp" "$install_dir/xaq"
install_tmp=

printf 'installed xaq edge to %s/xaq\n' "$install_dir"
case ":${PATH:-}:" in
    *:"$install_dir":*) ;;
    *) printf 'add %s to PATH to run xaq\n' "$install_dir" ;;
esac
