#!/bin/sh
set -eu

fail() {
    printf 'publish_edge_test: %s\n' "$*" >&2
    exit 1
}

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-publish-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

remote="$scratch/remote.git"
work="$scratch/work"
store="$scratch/release"
mock_bin="$scratch/bin"
mkdir -p "$work/tools" "$store/assets" "$mock_bin"
git init --bare --quiet "$remote"
git -C "$work" init --quiet
git -C "$work" remote add origin "$remote"
cp "$repo/tools/publish-edge.sh" "$repo/tools/validate-edge-manifest.sh" "$work/tools/"

cat > "$mock_bin/gh" <<'EOF'
#!/bin/sh
set -eu

case "$1/$2" in
    release/view)
        [ -f "$RELEASE_STORE/exists" ]
        ;;
    release/create)
        : > "$RELEASE_STORE/exists"
        ;;
    release/edit)
        ;;
    release/download)
        shift 2
        pattern=
        destination=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --pattern) pattern=$2; shift 2 ;;
                --dir) destination=$2; shift 2 ;;
                --repo) shift 2 ;;
                *) shift ;;
            esac
        done
        [ -f "$RELEASE_STORE/assets/$pattern" ] || exit 1
        cp "$RELEASE_STORE/assets/$pattern" "$destination/$pattern"
        ;;
    release/upload)
        asset=$4
        name=${asset##*/}
        [ "${GH_FAIL_NAME:-}" != "$name" ] || exit 1
        cp "$asset" "$RELEASE_STORE/assets/$name"
        ;;
    api/*)
        ;;
    *)
        printf 'unexpected gh command: %s %s\n' "$1" "$2" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$mock_bin/gh"

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

make_dist() {
    destination=$1
    git_sha=$2
    mkdir -p "$destination"
    manifest="$destination/edge-manifest-$git_sha"
    printf 'xaq-edge-v1 %s\n' "$git_sha" > "$manifest"
    for platform in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64; do
        base="xaq-$platform"
        binary="$destination/$base-$git_sha"
        archive="$binary.tar.gz"
        printf 'binary %s %s\n' "$platform" "$git_sha" > "$binary"
        printf 'archive %s %s\n' "$platform" "$git_sha" > "$archive"
        printf '%s %s %s\n' "$base" "$base-$git_sha" "$(digest_file "$binary")" >> "$manifest"
        printf '%s %s %s\n' "$base.tar.gz" "$base-$git_sha.tar.gz" "$(digest_file "$archive")" >> "$manifest"
    done
}

old_sha=0123456789abcdef0123456789abcdef01234567
new_sha=89abcdef0123456789abcdef0123456789abcdef
make_dist "$work/old-dist" "$old_sha"
(
    cd "$work"
    PATH="$mock_bin:$PATH" RELEASE_STORE="$store" \
        tools/publish-edge.sh old-dist example/xaq "$old_sha" >/dev/null
)
old_ref=$(git --git-dir="$remote" rev-parse refs/heads/edge-channel)
git --git-dir="$remote" show "$old_ref:manifest" > "$scratch/active-manifest"
grep -Fx "xaq-edge-v1 $old_sha" "$scratch/active-manifest" >/dev/null || fail 'first promotion chose the wrong build'

make_dist "$work/new-dist" "$new_sha"
if (
    cd "$work"
    PATH="$mock_bin:$PATH" RELEASE_STORE="$store" GH_FAIL_NAME="xaq-macos-x86_64-$new_sha" \
        tools/publish-edge.sh new-dist example/xaq "$new_sha" >/dev/null 2>&1
); then
    fail 'publication succeeded after a staged upload failure'
fi

[ "$(git --git-dir="$remote" rev-parse refs/heads/edge-channel)" = "$old_ref" ] || \
    fail 'failed publication moved the channel manifest'
awk 'NR > 1 { print $2 }' "$scratch/active-manifest" | while IFS= read -r name; do
    [ -f "$store/assets/$name" ] || fail "failed publication removed active asset $name"
done
