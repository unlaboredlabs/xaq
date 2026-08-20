#!/bin/sh
set -eu

fail() {
    printf 'install_test: %s\n' "$*" >&2
    exit 1
}

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-install-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

mock_bin="$scratch/bin"
fixture="$scratch/fixture"
install_dir="$scratch/install"
mkdir -p "$mock_bin" "$fixture" "$install_dir"

cat > "$mock_bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) exit 1 ;;
esac
EOF
cat > "$mock_bin/curl" <<'EOF'
#!/bin/sh
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output=$2; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ] || exit 2
printf '%s\n' "$url" >> "$REQUEST_LOG"
case "$url" in
    */manifest) cp "$FIXTURE_DIR/manifest" "$output" ;;
    */xaq-linux-x86_64-*) cp "$FIXTURE_DIR/binary" "$output" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$mock_bin/uname" "$mock_bin/curl"

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

digest_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{ print $1 }'
    else
        printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
    fi
}

git_sha=0123456789abcdef0123456789abcdef01234567
asset="xaq-linux-x86_64-$git_sha"
version=0.1.0-edge.7
printf '#!/bin/sh\nprintf "new binary\\n"\n' > "$fixture/binary"
digest=$(digest_file "$fixture/binary")
version_digest=$(digest_text "$version")
printf 'xaq-edge-v1 %s\nversion %s %s\nxaq-linux-x86_64 %s %s\n' \
    "$git_sha" "$version" "$version_digest" "$asset" "$digest" > "$fixture/manifest"
request_log="$scratch/requests"

install_output=$(PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture" REQUEST_LOG="$request_log" \
    XAQ_INSTALL_DIR="$install_dir" sh "$repo/install.sh")
cmp "$fixture/binary" "$install_dir/xaq" >/dev/null || fail 'installer wrote the wrong binary'
printf '%s\n' "$install_output" | grep -Fx "installed xaq $version to $install_dir/xaq" >/dev/null || \
    fail 'installer did not report the numbered edge version'
grep -Fx "https://github.com/unlaboredlabs/xaq/releases/download/edge/$asset" "$request_log" >/dev/null || \
    fail 'installer did not request the immutable asset'

printf 'old binary\n' > "$install_dir/xaq"
cp "$install_dir/xaq" "$scratch/expected-old"
other_sha=89abcdef0123456789abcdef0123456789abcdef
printf 'xaq-edge-v1 %s\nxaq-linux-x86_64 xaq-linux-x86_64-%s %s\n' \
    "$git_sha" "$other_sha" "$digest" > "$fixture/manifest"
if PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture" REQUEST_LOG="$request_log" \
    XAQ_INSTALL_DIR="$install_dir" sh "$repo/install.sh" >/dev/null 2>&1; then
    fail 'installer accepted an asset from a different manifest generation'
fi
cmp "$scratch/expected-old" "$install_dir/xaq" >/dev/null || fail 'failed install replaced the existing executable'

printf 'xaq-edge-v1 %s\nxaq-linux-x86_64 %s %064d\n' "$git_sha" "$asset" 0 > "$fixture/manifest"
if PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture" REQUEST_LOG="$request_log" \
    XAQ_INSTALL_DIR="$install_dir" sh "$repo/install.sh" >/dev/null 2>&1; then
    fail 'installer accepted a checksum mismatch'
fi
cmp "$scratch/expected-old" "$install_dir/xaq" >/dev/null || fail 'checksum failure replaced the existing executable'

printf 'xaq-edge-v1 %s\nversion %s %064d\nxaq-linux-x86_64 %s %s\n' \
    "$git_sha" "$version" 0 "$asset" "$digest" > "$fixture/manifest"
if PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture" REQUEST_LOG="$request_log" \
    XAQ_INSTALL_DIR="$install_dir" sh "$repo/install.sh" >/dev/null 2>&1; then
    fail 'installer accepted a malformed version digest'
fi
cmp "$scratch/expected-old" "$install_dir/xaq" >/dev/null || fail 'version failure replaced the existing executable'
