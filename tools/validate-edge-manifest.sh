#!/bin/sh
set -eu

fail() {
    printf 'validate-edge-manifest: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail 'usage: validate-edge-manifest.sh MANIFEST'
manifest=$1
[ -f "$manifest" ] || fail "missing manifest: $manifest"

git_sha=$(awk 'NR == 1 && NF == 2 && $1 == "xaq-edge-v1" { print $2 }' "$manifest")
[ "${#git_sha}" -eq 40 ] || fail 'invalid manifest header'
case "$git_sha" in
    *[!0-9a-f]*) fail 'invalid manifest commit' ;;
esac
[ "$(wc -l < "$manifest" | tr -d ' ')" -eq 9 ] || fail 'manifest must contain eight assets'

validate_entry() {
    logical=$1
    expected_name=$2
    record=$(awk -v logical="$logical" '
        $1 == logical {
            if (NF != 3 || found) bad = 1
            found = 1
            value = $2 " " $3
        }
        END {
            if (bad || !found) exit 1
            print value
        }
    ' "$manifest") || fail "invalid entry for $logical"
    filename=${record%% *}
    digest=${record#* }
    [ "$filename" = "$expected_name" ] || fail "unexpected filename for $logical"
    [ "${#digest}" -eq 64 ] || fail "invalid checksum for $logical"
    case "$digest" in
        *[!0-9a-f]*) fail "invalid checksum for $logical" ;;
    esac
}

for platform in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64; do
    base="xaq-$platform"
    validate_entry "$base" "$base-$git_sha"
    validate_entry "$base.tar.gz" "$base-$git_sha.tar.gz"
done
