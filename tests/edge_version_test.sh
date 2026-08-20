#!/bin/sh
set -eu

fail() {
    printf 'edge_version_test: %s\n' "$*" >&2
    exit 1
}

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-edge-version-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

mock_bin="$scratch/bin"
fixture="$scratch/releases"
mkdir -p "$mock_bin"
: > "$fixture"
cat > "$mock_bin/gh" <<'EOF'
#!/bin/sh
set -eu
[ "$1/$2" = api/--paginate ] || exit 2
[ "${GH_API_FAIL:-0}" -eq 0 ] || exit 1
cat "$RELEASE_FIXTURE"
EOF
chmod +x "$mock_bin/gh"

git_sha=0123456789abcdef0123456789abcdef01234567
version=$(PATH="$mock_bin:$PATH" RELEASE_FIXTURE="$fixture" \
    "$repo/tools/next-edge-version.sh" 0.1.0 example/xaq "$git_sha")
[ "$version" = 0.1.0-edge.1 ] || fail "first version was $version"

cat > "$fixture" <<EOF
edge	main
v0.1.0-edge.1	89abcdef0123456789abcdef0123456789abcdef
v0.1.0-edge.2	$git_sha
v0.1.0-edge.preview	$git_sha
EOF
version=$(PATH="$mock_bin:$PATH" RELEASE_FIXTURE="$fixture" \
    "$repo/tools/next-edge-version.sh" 0.1.0 example/xaq "$git_sha")
[ "$version" = 0.1.0-edge.2 ] || fail "retry version was $version"

printf 'v0.1.0-edge.3\t89abcdef0123456789abcdef0123456789abcdef\n' >> "$fixture"
version=$(PATH="$mock_bin:$PATH" RELEASE_FIXTURE="$fixture" \
    "$repo/tools/next-edge-version.sh" 0.1.0 example/xaq "$git_sha")
[ "$version" = 0.1.0-edge.4 ] || fail "next version was $version"

if PATH="$mock_bin:$PATH" RELEASE_FIXTURE="$fixture" \
    "$repo/tools/next-edge-version.sh" 0.1 example/xaq "$git_sha" >/dev/null 2>&1; then
    fail 'invalid base version was accepted'
fi

if PATH="$mock_bin:$PATH" RELEASE_FIXTURE="$fixture" GH_API_FAIL=1 \
    "$repo/tools/next-edge-version.sh" 0.1.0 example/xaq "$git_sha" >/dev/null 2>&1; then
    fail 'release API failure was ignored'
fi
