#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
test_uuid=$(/usr/bin/uuidgen)
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/HijackCoreTests-$test_uuid.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap '/bin/rm -rf -- "$test_root"' EXIT
trap 'exit 1' HUP INT TERM

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected <$1>, got <$2>)"; }
expect_failure() {
    if "$@" >"$test_root/failure.stdout" 2>"$test_root/failure.stderr"; then
        fail "unexpected success: $*"
    fi
}
new_destination() {
    DEST_BUNDLE="$test_root/$1/Preview.app"
    MARKER_FILE="$DEST_BUNDLE/Contents/Resources/lab.marker"
    /bin/mkdir -p "$DEST_BUNDLE/Contents/Resources"
}
literal_marker() {
    printf 'identifier=default-application-hijack-lab\nschema=1\nstate=%s\n' "$1" >"$MARKER_FILE"
}

# A missing implementation must be the first RED failure.
[ -f "$script_dir/../lib/hijack_core.sh" ] || fail 'lib/hijack_core.sh does not exist'
. "$script_dir/../lib/hijack_core.sh"
HIJACK_LAB_TESTING=1

review_failed=0
HANDLER_QUERY="$test_root/timeout-query"
FIXTURE_FILE="$test_root/timeout-fixture.pdf"
printf 'fixture\n' >"$FIXTURE_FILE"
cat >"$HANDLER_QUERY" <<'STUB'
#!/bin/sh
printf '/wrong/Preview.app\n'
STUB
/bin/chmod 755 "$HANDLER_QUERY"
expect_failure wait_for_handler '/expected/Preview.app' 08
if /usr/bin/grep -F 'canonical decimal' "$test_root/failure.stderr" >/dev/null &&
    ! /usr/bin/grep -Ei 'arithmetic|illegal number' "$test_root/failure.stderr" >/dev/null; then
    pass noncanonical_leading_zero_timeout_has_ordinary_diagnostic
else printf 'FAIL: leading_zero_timeout_has_arithmetic_error_or_no_validation_diagnostic\n' >&2; review_failed=1; fi

# Candidate validation only: never create anything under these real trees.
for protected_tree in /Applications /System/Applications; do
    DEST_BUNDLE="$protected_tree/Utilities/HijackCoreCandidate-$test_uuid.app"
    if ( TMPDIR="$protected_tree" require_safe_destination ) >"$test_root/failure.stdout" 2>"$test_root/failure.stderr"; then
        printf 'FAIL: test_destination_under_%s_accepted_with_caller_TMPDIR\n' "$protected_tree" >&2
        review_failed=1
    elif /usr/bin/grep -F 'protected application tree' "$test_root/failure.stderr" >/dev/null; then
        pass "test_destination_under_${protected_tree}_rejected_independently_of_TMPDIR"
    else printf 'FAIL: protected_tree_validation_diagnostic_missing\n' >&2; review_failed=1; fi
done
[ "$review_failed" -eq 0 ] || exit 1

for protected_tree in /Applications /System/Applications; do
    case "$protected_tree" in /Applications) protected_label=user ;; *) protected_label=system ;; esac
    protected_alias="$test_root/protected-alias-$protected_label"
    /bin/ln -s "$protected_tree" "$protected_alias"
    DEST_BUNDLE="$protected_alias/Utilities/HijackCoreCandidate-$test_uuid.app"
    if ( TMPDIR="$protected_tree" require_safe_destination ) >"$test_root/failure.stdout" 2>"$test_root/failure.stderr"; then
        fail 'canonical protected destination accepted with caller TMPDIR'
    fi
    /usr/bin/grep -F 'protected application tree' "$test_root/failure.stderr" >/dev/null || fail 'canonical protected destination guard missing'
    pass "canonical_test_destination_under_${protected_tree}_rejected_independently_of_TMPDIR"
done

new_destination unmarked
require_safe_destination || fail 'unmarked directory has safe path identity'
expect_failure remove_marked_clone
[ -d "$DEST_BUNDLE" ] || fail 'unmarked destination was removed'
pass 'unmarked directory validates identity but cannot be removed'

new_destination symlink-target
target_bundle=$DEST_BUNDLE
printf 'keep\n' >"$target_bundle/keep"
DEST_BUNDLE="$test_root/destination-symlink.app"
MARKER_FILE="$DEST_BUNDLE/Contents/Resources/lab.marker"
/bin/ln -s "$target_bundle" "$DEST_BUNDLE"
expect_failure require_safe_destination
expect_failure remove_marked_clone
[ -L "$DEST_BUNDLE" ] && [ -f "$target_bundle/keep" ] || fail 'symlink destination or target changed'
pass 'destination symlink is rejected without touching target'

for state in cloned registered payload-installed; do
    new_destination "round-trip-$state"
    write_marker_state "$state" || fail "write $state"
    assert_eq "$state" "$(read_marker_state)" "round-trip $state"
    printf 'identifier=default-application-hijack-lab\nschema=1\nstate=%s\n' "$state" >"$test_root/expected.marker"
    /usr/bin/cmp -s "$test_root/expected.marker" "$MARKER_FILE" || fail 'marker exact bytes'
    assert_eq '600' "$(/usr/bin/stat -f '%Lp' "$MARKER_FILE")" 'marker mode'
    pass "exact $state marker round-trip and mode 0600"
done

new_destination rewrite
write_marker_state cloned
write_marker_state registered
assert_eq registered "$(read_marker_state)" 'marker replacement'
expect_failure write_marker_state unknown
assert_eq registered "$(read_marker_state)" 'rejected state preserved marker'
expect_failure require_known_state unknown
for state in cloned registered payload-installed; do
    require_known_state "$state" || fail "known state $state"
done
pass 'known states validate and invalid writes preserve existing marker'

new_destination absent-marker
expect_failure read_marker_state
expect_failure remove_marked_clone
[ -d "$DEST_BUNDLE" ] || fail 'missing marker allowed removal'
pass 'absent marker prevents removal'

for bad_marker in malformed schema-2 unknown-state wrong-identifier extra-line blank-line missing-newline; do
    new_destination "$bad_marker"
    case "$bad_marker" in
        malformed) printf 'not a marker\n' >"$MARKER_FILE" ;;
        schema-2) printf 'identifier=default-application-hijack-lab\nschema=2\nstate=cloned\n' >"$MARKER_FILE" ;;
        unknown-state) literal_marker unknown ;;
        wrong-identifier) printf 'identifier=other-lab\nschema=1\nstate=cloned\n' >"$MARKER_FILE" ;;
        extra-line) literal_marker cloned; printf 'extra=value\n' >>"$MARKER_FILE" ;;
        blank-line) literal_marker cloned; printf '\n' >>"$MARKER_FILE" ;;
        missing-newline) printf 'identifier=default-application-hijack-lab\nschema=1\nstate=cloned' >"$MARKER_FILE" ;;
    esac
    expect_failure read_marker_state
    expect_failure remove_marked_clone
    [ -d "$DEST_BUNDLE" ] || fail "$bad_marker allowed removal"
    pass "$bad_marker marker prevents removal"
done

new_destination marker-symlink
outside_marker="$test_root/outside.marker"
printf 'identifier=default-application-hijack-lab\nschema=1\nstate=cloned\n' >"$outside_marker"
/bin/ln -s "$outside_marker" "$MARKER_FILE"
expect_failure read_marker_state
expect_failure write_marker_state registered
expect_failure remove_marked_clone
[ -d "$DEST_BUNDLE" ] && [ -L "$MARKER_FILE" ] && [ -f "$outside_marker" ] || fail 'marker symlink paths changed'
pass 'marker symlink cannot authorize removal or writes; outside marker survives'

new_destination external-marker
MARKER_FILE=$outside_marker
expect_failure write_marker_state cloned
expect_failure remove_marked_clone
[ -d "$DEST_BUNDLE" ] && [ -f "$outside_marker" ] || fail 'external marker paths changed'
pass 'external regular marker cannot authorize removal or writes'

new_destination marker-parent-symlink
/bin/mkdir -p "$test_root/external-resources"
/bin/rmdir "$DEST_BUNDLE/Contents/Resources"
/bin/ln -s "$test_root/external-resources" "$DEST_BUNDLE/Contents/Resources"
literal_marker cloned
expect_failure write_marker_state registered
expect_failure remove_marked_clone
[ -d "$DEST_BUNDLE" ] && [ -f "$MARKER_FILE" ] || fail 'symlinked resource paths changed'
pass 'symlinked Resources cannot authorize writes or removal'

new_destination marker-traversal
MARKER_FILE="$DEST_BUNDLE/Contents/Resources/../../../outside.marker"
expect_failure write_marker_state registered
expect_failure remove_marked_clone
[ -d "$DEST_BUNDLE" ] && [ -f "$outside_marker" ] || fail 'marker traversal paths changed'
pass 'marker traversal cannot authorize writes or removal'

new_destination directory-marker
/bin/mkdir "$MARKER_FILE"
expect_failure read_marker_state
expect_failure write_marker_state cloned
expect_failure remove_marked_clone
[ -d "$MARKER_FILE" ] || fail 'directory marker was changed'
pass 'directory marker is rejected'

new_destination marked-removal
literal_marker payload-installed
printf 'keep\n' >"$test_root/sibling"
remove_marked_clone || fail 'valid marked removal'
[ ! -e "$DEST_BUNDLE" ] && [ -f "$test_root/sibling" ] && [ -f "$outside_marker" ] || fail 'removal scope'
remove_marked_clone || fail 'absent removal is idempotent'
pass 'valid marker removes only exact clone and absent removal succeeds'

# These substitutions model changes during marker validation, without timing races.
(
    new_destination changed-to-symlink
    literal_marker cloned
    race_saved="$test_root/saved-race-clone.app"
    race_target=$target_bundle
    read_marker_state() {
        /bin/mv "$DEST_BUNDLE" "$race_saved"
        /bin/ln -s "$race_target" "$DEST_BUNDLE"
        printf 'cloned\n'
    }
    expect_failure remove_marked_clone
    [ -L "$DEST_BUNDLE" ] && [ -d "$race_saved" ] && [ -f "$race_target/keep" ] || fail 'late symlink swap changed paths'
)
pass 'late destination symlink swap is rejected'

(
    new_destination changed-directory
    literal_marker cloned
    race_saved="$test_root/saved-race-directory.app"
    read_marker_state() {
        /bin/mv "$DEST_BUNDLE" "$race_saved"
        /bin/mkdir -p "$DEST_BUNDLE/Contents/Resources"
        literal_marker cloned
        printf 'cloned\n'
    }
    expect_failure remove_marked_clone
    [ -d "$DEST_BUNDLE" ] && [ -d "$race_saved" ] || fail 'late directory swap changed paths'
)
pass 'destination identity change during marker validation is rejected'

for unsafe in / /Applications /System/Applications/Preview.app relative/Preview.app "$test_root/marked-removal/Preview.app/.." "$test_root/marked-removal/Preview.app/"; do
    DEST_BUNDLE=$unsafe
    expect_failure require_safe_destination
done
pass 'protected, relative, traversal, and trailing-slash destinations are rejected'

DEST_BUNDLE="$test_root/plain-file.app"
printf 'keep\n' >"$DEST_BUNDLE"
expect_failure require_safe_destination
pass 'existing regular file is not a bundle directory'

new_destination real-mode-rejection
HIJACK_LAB_TESTING=0
expect_failure require_safe_destination
HIJACK_LAB_TESTING=2
expect_failure require_safe_destination
HIJACK_LAB_TESTING=1
pass 'temporary destinations require explicit test mode 1'

new_destination temporary-containment
saved_tmpdir=${TMPDIR:-/tmp}
TMPDIR="$test_root/narrow-temp"
/bin/mkdir "$TMPDIR" "$test_root/narrow-temp-other"
DEST_BUNDLE="$test_root/narrow-temp-other/Preview.app"
expect_failure require_safe_destination
/bin/mkdir "$TMPDIR/inside"
/bin/ln -s "$test_root/narrow-temp-other" "$TMPDIR/outside-link"
DEST_BUNDLE="$TMPDIR/outside-link/Preview.app"
expect_failure require_safe_destination
DEST_BUNDLE="$TMPDIR/inside/Preview.app"
require_safe_destination || fail 'canonical parent inside TMPDIR'
TMPDIR=$saved_tmpdir
pass 'canonical parent containment rejects prefix collision and escaping symlink'

FIXTURE_FILE="$test_root/fixture with spaces.pdf"
printf 'fixture\n' >"$FIXTURE_FILE"
HANDLER_QUERY="$test_root/query stub"
export QUERY_STATE="$test_root/query.state" QUERY_EXPECTED="$test_root/expected handler.app" QUERY_FIXTURE="$FIXTURE_FILE"
cat >"$HANDLER_QUERY" <<'STUB'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = "$QUERY_FIXTURE" ] || exit 64
count=0
if [ -f "$QUERY_STATE" ]; then read -r count <"$QUERY_STATE"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$QUERY_STATE"
if [ "$count" -lt 3 ]; then printf '/wrong/Preview.app\n'; else printf '%s\n' "$QUERY_EXPECTED"; fi
STUB
/bin/chmod 700 "$HANDLER_QUERY"
wait_for_handler "$QUERY_EXPECTED" 3 || fail 'delayed handler convergence'
assert_eq 3 "$(cat "$QUERY_STATE")" 'query attempts before convergence'
pass 'handler polling succeeds after two wrong paths'

QUERY_EXPECTED='/last observed/Other.app'
printf '0\n' >"$QUERY_STATE"
expect_failure wait_for_handler '/expected/Preview.app' 3
/usr/bin/grep -F 'expected handler: /expected/Preview.app' "$test_root/failure.stderr" >/dev/null || fail 'timeout expected diagnostic'
/usr/bin/grep -F 'last observed handler: /last observed/Other.app' "$test_root/failure.stderr" >/dev/null || fail 'timeout last observed diagnostic'
assert_eq 4 "$(cat "$QUERY_STATE")" 'bounded immediate query plus three retries'
pass 'handler polling times out with expected and last observed paths'

expect_failure wait_for_handler '/expected/Preview.app' -1
expect_failure wait_for_handler '/expected/Preview.app' invalid
pass 'handler timeout must be a nonnegative integer'

printf 'HijackCoreTests: PASS\n'
