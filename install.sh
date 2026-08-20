#!/bin/sh
set -eu

manifest_url=https://raw.githubusercontent.com/unlaboredlabs/xaq/edge-channel/manifest
release_url=https://github.com/unlaboredlabs/xaq/releases/download/edge

fail() {
    printf 'xaq: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        fail 'sha256sum or shasum is required'
    fi
}

digest_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
    else
        fail 'sha256sum or shasum is required'
    fi
}

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

version_record=$(awk '
    $1 == "version" {
        if (NF != 3 || found) bad = 1
        found = 1
        value = $2 "\t" $3
    }
    END {
        if (bad) exit 1
        if (found) print value
    }
' "$download_dir/manifest") || fail 'edge manifest version is malformed'
release_version=edge
if [ -n "$version_record" ]; then
    tab=$(printf '\t')
    release_version=${version_record%%"$tab"*}
    version_digest=${version_record#*"$tab"}
    printf '%s\n' "$release_version" | awk '/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-edge\.[1-9][0-9]*$/ { found = 1 } END { exit !found }' || \
        fail 'edge manifest version is malformed'
    [ "$version_digest" = "$(digest_text "$release_version")" ] || fail 'edge manifest version digest is malformed'
fi

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

actual=$(digest_file "$download_dir/$filename")
[ "$actual" = "$expected" ] || fail 'downloaded edge binary failed checksum verification'

mkdir -p "$install_dir"
install_tmp=$(mktemp "$install_dir/.xaq.XXXXXX")
install -m 755 "$download_dir/$filename" "$install_tmp"
mv -f "$install_tmp" "$install_dir/xaq"
install_tmp=

printf 'installed xaq %s to %s/xaq\n' "$release_version" "$install_dir"
case ":${PATH:-}:" in
    *:"$install_dir":*) ;;
    *) printf 'add %s to PATH to run xaq\n' "$install_dir" ;;
esac
