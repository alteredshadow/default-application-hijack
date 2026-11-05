#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
test_uuid=$(/usr/bin/uuidgen)
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ExclusiveRenameTests-$test_uuid.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap '/bin/rm -rf -- "$test_root"' EXIT
trap 'exit 1' HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
identity() { /usr/bin/stat -f '%d:%i' "$1"; }
expect_failure() {
    if "$@" >"$test_root/stdout" 2>"$test_root/stderr"; then fail 'exclusive rename unexpectedly succeeded'; fi
}

[ -f "$project_dir/Sources/ExclusiveRename.swift" ] || fail 'Sources/ExclusiveRename.swift does not exist'
sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
/bin/mkdir "$test_root/ModuleCache"
/usr/bin/xcrun swiftc -sdk "$sdk_path" -module-cache-path "$test_root/ModuleCache" \
    "$project_dir/Sources/ExclusiveRename.swift" -o "$test_root/exclusive-rename"
/usr/bin/codesign --force --sign - "$test_root/exclusive-rename" >"$test_root/signing.log" 2>&1
/usr/bin/codesign --verify --strict "$test_root/exclusive-rename"

source="$test_root/success-source.app"
destination="$test_root/success-destination.app"
/bin/mkdir "$source"
printf 'original contents\n' >"$source/keep"
source_identity=$(identity "$source")
"$test_root/exclusive-rename" "$source" "$destination" || fail 'exclusive rename failed'
[ ! -e "$source" ] && [ -f "$destination/keep" ] || fail 'successful rename did not relocate source'
[ "$source_identity" = "$(identity "$destination")" ] || fail 'rename did not preserve device/inode identity'
pass successful_rename_preserves_identity

for kind in empty-directory populated-directory regular-file symlink; do
    source="$test_root/$kind-source.app"
    destination="$test_root/$kind-destination.app"
    /bin/mkdir "$source"
    printf 'source contents\n' >"$source/keep"
    source_identity=$(identity "$source")
    case "$kind" in
        empty-directory) /bin/mkdir "$destination" ;;
        populated-directory) /bin/mkdir "$destination"; printf 'destination contents\n' >"$destination/keep" ;;
        regular-file) printf 'destination contents\n' >"$destination" ;;
        symlink)
            /bin/mkdir "$test_root/symlink-target"
            printf 'target contents\n' >"$test_root/symlink-target/keep"
            /bin/ln -s "$test_root/symlink-target" "$destination"
            ;;
    esac
    destination_identity=$(identity "$destination")
    expect_failure "$test_root/exclusive-rename" "$source" "$destination"
    [ "$source_identity" = "$(identity "$source")" ] && [ -f "$source/keep" ] || fail "$kind collision changed source"
    [ "$destination_identity" = "$(identity "$destination")" ] || fail "$kind collision replaced destination"
    [ ! -e "$destination/${source##*/}" ] || fail "$kind collision nested source"
    case "$kind" in
        populated-directory) [ "$(cat "$destination/keep")" = 'destination contents' ] || fail 'destination contents changed' ;;
        regular-file) [ "$(cat "$destination")" = 'destination contents' ] || fail 'destination file changed' ;;
        symlink) [ -L "$destination" ] && [ "$(cat "$test_root/symlink-target/keep")" = 'target contents' ] || fail 'destination symlink changed' ;;
    esac
    pass "${kind}_collision_preserves_source_and_destination"
done

expect_failure "$test_root/exclusive-rename"
expect_failure "$test_root/exclusive-rename" "$test_root/missing-source.app" "$test_root/missing-destination.app"
[ ! -e "$test_root/missing-destination.app" ] || fail 'missing source created destination'
pass invalid_arguments_and_missing_source_fail
printf 'ExclusiveRenameTests: PASS\n'
