#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'publish-edge: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 4 ]] || fail 'usage: publish-edge.sh DIST_DIR REPOSITORY GIT_SHA VERSION'
dist=$1
repository=$2
git_sha=$3
version=$4
channel_branch=edge-channel
release_tag=edge
version_tag="v$version"
manifest="$dist/edge-manifest-$git_sha"

[[ "$repository" == */* ]] || fail 'REPOSITORY must have owner/name form'
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'GIT_SHA must contain 40 lowercase hexadecimal characters'
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-edge\.[1-9][0-9]*$ ]] || \
    fail 'VERSION must have semantic version form X.Y.Z-edge.N'
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

version_notes="Edge build from main at $git_sha. The floating edge channel points to the newest promoted build."
if version_draft=$(gh release view "$version_tag" --repo "$repository" \
    --json isDraft --jq .isDraft 2>/dev/null); then
    [[ "$version_draft" == true || "$version_draft" == false ]] || \
        fail "could not determine release state for $version_tag"
else
    gh release create "$version_tag" --repo "$repository" --target "$git_sha" \
        --title "xaq $version" --draft --prerelease --notes "$version_notes"
    version_draft=true
fi

if ! gh release view "$release_tag" --repo "$repository" >/dev/null 2>&1; then
    gh release create "$release_tag" --repo "$repository" --target "$git_sha" \
        --title 'xaq edge' --prerelease \
        --notes 'Rolling build channel. The active build is selected by the edge-channel manifest.'
fi

upload_and_verify() {
    local tag=$1
    local remote_dir=$2
    local name local_asset
    mkdir -p "$remote_dir"
    for name in "${assets[@]}"; do
        local_asset="$dist/$name"
        [[ -f "$local_asset" ]] || fail "missing release asset: $local_asset"
        if gh release download "$tag" --repo "$repository" --pattern "$name" \
            --dir "$remote_dir" >/dev/null 2>&1; then
            cmp "$local_asset" "$remote_dir/$name" >/dev/null || \
                fail "$tag already contains different bytes for $name"
        else
            gh release upload "$tag" "$local_asset" --repo "$repository"
            gh release download "$tag" --repo "$repository" --pattern "$name" \
                --dir "$remote_dir" >/dev/null
            cmp "$local_asset" "$remote_dir/$name" >/dev/null || \
                fail "remote verification failed for $tag asset $name"
        fi
    done
}

upload_and_verify "$version_tag" "$scratch/versioned"
upload_and_verify "$release_tag" "$scratch/rolling"
if [[ "$version_draft" == true ]]; then
    gh release edit "$version_tag" --repo "$repository" --title "xaq $version" \
        --draft=false --prerelease --notes "$version_notes"
fi

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
notes="Rolling build $version from main at $git_sha. Clients select this complete asset set through the edge-channel manifest."
gh release edit "$release_tag" --repo "$repository" --title "xaq edge ($version)" --prerelease --notes "$notes"

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
