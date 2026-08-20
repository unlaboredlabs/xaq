#!/bin/sh
set -eu

fail() {
    printf 'edge_freshness_test: %s\n' "$*" >&2
    exit 1
}

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-edge-freshness-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

mock_bin="$scratch/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/gh" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = api ] || exit 2
[ "$2" = repos/example/xaq/git/ref/heads/main ] || exit 2
[ "$3" = --jq ] || exit 2
[ "$4" = .object.sha ] || exit 2
[ "${GH_API_FAIL:-0}" -eq 0 ] || exit 1
printf '%s\n' "$MAIN_SHA"
EOF
chmod +x "$mock_bin/gh"

current_sha=0123456789abcdef0123456789abcdef01234567
older_sha=89abcdef0123456789abcdef0123456789abcdef

status=$(PATH="$mock_bin:$PATH" MAIN_SHA="$current_sha" \
    "$repo/tools/check-edge-current.sh" example/xaq "$current_sha")
[ "$status" = true ] || fail "current main commit returned $status"

status=$(PATH="$mock_bin:$PATH" MAIN_SHA="$current_sha" \
    "$repo/tools/check-edge-current.sh" example/xaq "$older_sha")
[ "$status" = false ] || fail "stale main commit returned $status"

if PATH="$mock_bin:$PATH" MAIN_SHA=invalid \
    "$repo/tools/check-edge-current.sh" example/xaq "$current_sha" >/dev/null 2>&1; then
    fail 'invalid main ref response was accepted'
fi

if PATH="$mock_bin:$PATH" MAIN_SHA="$current_sha" GH_API_FAIL=1 \
    "$repo/tools/check-edge-current.sh" example/xaq "$current_sha" >/dev/null 2>&1; then
    fail 'main ref API failure was ignored'
fi
