#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'next-edge-version: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 3 ]] || fail 'usage: next-edge-version.sh BASE_VERSION REPOSITORY GIT_SHA'
base_version=$1
repository=$2
git_sha=$3

[[ "$base_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
    fail 'BASE_VERSION must be a semantic version without a prerelease suffix'
[[ "$repository" == */* ]] || fail 'REPOSITORY must have owner/name form'
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'GIT_SHA must contain 40 lowercase hexadecimal characters'

prefix="v$base_version-edge."
latest=0
same_commit=0
release_rows=$(gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq '.[] | [.tag_name, .target_commitish] | @tsv') || \
    fail 'could not list existing releases'
while IFS=$'\t' read -r tag target; do
    [[ "$tag" == "$prefix"* ]] || continue
    number=${tag#"$prefix"}
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    ((${#number} <= 18)) || fail 'edge release sequence is too large'
    (( number > latest )) && latest=$number
    if [[ "$target" == "$git_sha" ]] && (( number > same_commit )); then
        same_commit=$number
    fi
done <<< "$release_rows"

if (( same_commit > 0 && same_commit == latest )); then
    next=$same_commit
else
    next=$((latest + 1))
fi
printf '%s-edge.%d\n' "$base_version" "$next"
