#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'check-edge-current: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 2 ]] || fail 'usage: check-edge-current.sh REPOSITORY GIT_SHA'
repository=$1
git_sha=$2

[[ "$repository" == */* ]] || fail 'REPOSITORY must have owner/name form'
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'GIT_SHA must contain 40 lowercase hexadecimal characters'

main_sha=$(gh api "repos/$repository/git/ref/heads/main" --jq .object.sha) || \
    fail 'could not read the current main ref'
[[ "$main_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'main ref returned an invalid commit'

if [[ "$main_sha" == "$git_sha" ]]; then
    printf 'true\n'
else
    printf 'false\n'
fi
