#!/bin/sh
set -eu

fail() {
    printf 'update_test: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail 'usage: update_test.sh BINARY GIT_SHA'
binary=$1
current_sha=$2
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xaq-update-test.XXXXXX")
cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM
mkdir "$scratch/bin"

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) asset=xaq-linux-x86_64 ;;
    Linux/aarch64) asset=xaq-linux-aarch64 ;;
    Darwin/x86_64) asset=xaq-macos-x86_64 ;;
    Darwin/arm64) asset=xaq-macos-aarch64 ;;
    *) fail 'unsupported test platform' ;;
esac

cat > "$scratch/bin/curl" <<'EOF'
#!/bin/sh
set -eu
for argument do url=$argument; done
printf '%s\n' "$url" >> "$UPDATE_FIXTURE/requests"
case "$url" in
    */manifest)
        [ "$UPDATE_MODE" != remove_early ] || rm "$UPDATE_FIXTURE/xaq"
        cat "$UPDATE_FIXTURE/manifest"
        ;;
    *)
        case "$UPDATE_MODE" in
            replace) mv "$UPDATE_FIXTURE/competing" "$UPDATE_FIXTURE/xaq" ;;
            remove) rm "$UPDATE_FIXTURE/xaq" ;;
            failure) printf partial; exit 22 ;;
        esac
        cat "$UPDATE_FIXTURE/payload"
        ;;
esac
EOF
chmod +x "$scratch/bin/curl"

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

next_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for mode in current success symlink checksum failure replace remove remove_early; do
    fixture="$scratch/$mode"
    mkdir "$fixture"
    cp "$binary" "$fixture/xaq"
    chmod +x "$fixture/xaq"
    printf '#!/bin/sh\nprintf "updated fixture\\n"\n' > "$fixture/payload"
    digest=$(digest_file "$fixture/payload")
    release_sha=$next_sha
    [ "$mode" != current ] || release_sha=$current_sha
    [ "$mode" != checksum ] || digest=$(printf '%064d' 0)
    printf 'xaq-edge-v1 %s\n%s %s-%s %s\n' \
        "$release_sha" "$asset" "$asset" "$release_sha" "$digest" > "$fixture/manifest"
    printf 'installed by another updater\n' > "$fixture/competing"
    cp "$fixture/competing" "$fixture/expected-competing"
    command_path="$fixture/xaq"
    if [ "$mode" = symlink ]; then
        ln -s xaq "$fixture/launch"
        command_path="$fixture/launch"
    fi
    result=0
    PATH="$scratch/bin:$PATH" UPDATE_FIXTURE="$fixture" UPDATE_MODE="$mode" \
        "$command_path" update > "$fixture/output" 2>&1 || result=$?
    case "$mode" in
        current)
            [ "$result" -eq 0 ] || fail 'current release check failed'
            cmp "$binary" "$fixture/xaq" >/dev/null || fail 'current release replaced the executable'
            [ "$(wc -l < "$fixture/requests" | tr -d ' ')" -eq 1 ] || fail 'current release downloaded a binary'
            ;;
        success|symlink)
            [ "$result" -eq 0 ] || fail "$mode update failed"
            cmp "$fixture/payload" "$fixture/xaq" >/dev/null || fail "$mode update installed the wrong bytes"
            [ "$("$command_path")" = 'updated fixture' ] || fail 'updated file is not executable'
            [ "$mode" != symlink ] || [ -L "$fixture/launch" ] || fail 'update replaced the launcher symlink'
            ;;
        checksum|failure)
            [ "$result" -ne 0 ] || fail "$mode update reported success"
            cmp "$binary" "$fixture/xaq" >/dev/null || fail "$mode update changed the executable"
            ;;
        replace|remove|remove_early)
            [ "$result" -ne 0 ] || fail 'update reported success after its destination changed during download'
            grep -F 'the executable changed during download' "$fixture/output" >/dev/null || \
                fail 'update did not explain the changed executable'
            if [ "$mode" = replace ]; then
                cmp "$fixture/expected-competing" "$fixture/xaq" >/dev/null || fail 'update overwrote a competing replacement'
            else
                [ ! -e "$fixture/xaq" ] || fail 'update recreated a removed executable'
            fi
            [ ! -e "$fixture/xaq (deleted)" ] || fail 'update created a deleted-path artifact'
            ;;
    esac
    [ -z "$(find "$fixture" -name '*.update-*' -print -quit)" ] || fail "$mode update left its temporary file"
done
