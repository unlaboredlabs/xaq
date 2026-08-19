#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'publish-edge: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 3 ]] || fail 'usage: publish-edge.sh DIST_DIR REPOSITORY GIT_SHA'
dist=$1
repository=$2
git_sha=$3
channel_branch=edge-channel
release_tag=edge
manifest="$dist/edge-manifest-$git_sha"

[[ "$repository" == */* ]] || fail 'REPOSITORY must have owner/name form'
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'GIT_SHA must contain 40 lowercase hexadecimal characters'
tools/validate-edge-manifest.sh "$manifest"

scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xaq-edge-publish.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

assets=()
for platform in linux-x86_64 linux-aarch64 macos-x86_64 macos-aarch64; do
    assets+=("xaq-$platform-$git_sha" "xaq-$platform-$git_sha.tar.gz")
done
assets+=("edge-manifest-$git_sha")

if ! gh release view "$release_tag" --repo "$repository" >/dev/null 2>&1; then
    gh release create "$release_tag" --repo "$repository" --target "$git_sha" \
        --title 'xaq edge' --prerelease \
        --notes 'Rolling build channel. The active build is selected by the edge-channel manifest.'
fi

remote_dir="$scratch/remote"
mkdir -p "$remote_dir"
for name in "${assets[@]}"; do
    local_asset="$dist/$name"
    [[ -f "$local_asset" ]] || fail "missing release asset: $local_asset"
    if gh release download "$release_tag" --repo "$repository" --pattern "$name" \
        --dir "$remote_dir" >/dev/null 2>&1; then
        cmp "$local_asset" "$remote_dir/$name" >/dev/null || \
            fail "release already contains different bytes for $name"
    else
        gh release upload "$release_tag" "$local_asset" --repo "$repository"
        gh release download "$release_tag" --repo "$repository" --pattern "$name" \
            --dir "$remote_dir" >/dev/null
        cmp "$local_asset" "$remote_dir/$name" >/dev/null || \
            fail "remote verification failed for $name"
    fi
done

old_ref=$(git ls-remote --refs origin "refs/heads/$channel_branch" | awk 'NR == 1 { print $1 }')
keep="$scratch/keep-assets"
printf '%s\n' "${assets[@]}" > "$keep"

cleanup_release_assets() {
    local release_id asset_id name
    release_id=$(gh api "repos/$repository/releases/tags/$release_tag" --jq .id)
    while IFS=$'\t' read -r asset_id name; do
        if ! grep -Fqx -- "$name" "$keep"; then
            gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
        fi
    done < <(gh api --paginate "repos/$repository/releases/$release_id/assets?per_page=100" \
        --jq '.[] | [.id, .name] | @tsv')
}

if [[ -n "$old_ref" ]]; then
    git fetch --quiet --no-tags origin "refs/heads/$channel_branch"
    previous_manifest="$scratch/previous-manifest"
    git show "FETCH_HEAD:manifest" > "$previous_manifest"
    tools/validate-edge-manifest.sh "$previous_manifest"

    awk 'NR > 1 { print $2 }' "$previous_manifest" >> "$keep"
    previous_sha=$(awk 'NR == 1 { print $2 }' "$previous_manifest")
    printf 'edge-manifest-%s\n' "$previous_sha" >> "$keep"

    cleanup_release_assets
fi

blob=$(git hash-object -w "$manifest")
tree=$(printf '100644 blob %s\tmanifest\n' "$blob" | git mktree)
export GIT_AUTHOR_NAME='github-actions[bot]'
export GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
if [[ -n "$old_ref" ]]; then
    channel_commit=$(printf 'Promote xaq edge %s\n' "$git_sha" | git commit-tree "$tree" -p "$old_ref")
else
    channel_commit=$(printf 'Promote xaq edge %s\n' "$git_sha" | git commit-tree "$tree")
fi

gh api --method PATCH "repos/$repository/git/refs/tags/$release_tag" \
    -f sha="$git_sha" -F force=true >/dev/null
notes="Rolling build from main at $git_sha. Clients select this complete asset set through the edge-channel manifest."
gh release edit "$release_tag" --repo "$repository" --title 'xaq edge' --prerelease --notes "$notes"

if [[ -n "$old_ref" ]]; then
    lease="--force-with-lease=refs/heads/$channel_branch:$old_ref"
else
    lease="--force-with-lease=refs/heads/$channel_branch:"
fi
git push "$lease" origin "$channel_commit:refs/heads/$channel_branch"

# Before the first channel manifest exists, legacy assets are the only usable
# release. Remove them only after the new channel is active.
if [[ -z "$old_ref" ]]; then
    cleanup_release_assets
fi
