#!/bin/sh
set -eu

fail() {
    printf 'validate-edge-manifest: %s\n' "$*" >&2
    exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'usage: validate-edge-manifest.sh MANIFEST [VERSION]'
manifest=$1
expected_version=${2:-}
[ -f "$manifest" ] || fail "missing manifest: $manifest"

digest_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
    else
        fail 'sha256sum or shasum is required'
    fi
}

git_sha=$(awk 'NR == 1 && NF == 2 && $1 == "xaq-edge-v1" { print $2 }' "$manifest")
[ "${#git_sha}" -eq 40 ] || fail 'invalid manifest header'
case "$git_sha" in
    *[!0-9a-f]*) fail 'invalid manifest commit' ;;
esac
version_record=$(awk 'NR == 2 && NF == 3 && $1 == "version" { print $2 " " $3 }' "$manifest")
if [ -n "$version_record" ]; then
    version=${version_record%% *}
    version_digest=${version_record#* }
    printf '%s\n' "$version" | awk '/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-edge\.[1-9][0-9]*$/ { found = 1 } END { exit !found }' || \
        fail 'invalid manifest version'
    [ "$version_digest" = "$(digest_text "$version")" ] || fail 'invalid manifest version digest'
    [ -z "$expected_version" ] || [ "$version" = "$expected_version" ] || fail 'manifest version differs from release version'
    expected_lines=10
else
    # The active manifest may predate version metadata during the first rollout.
    [ -z "$expected_version" ] || fail 'manifest version is missing'
    expected_lines=9
fi
[ "$(wc -l < "$manifest" | tr -d ' ')" -eq "$expected_lines" ] || fail 'manifest has an unexpected number of records'

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
