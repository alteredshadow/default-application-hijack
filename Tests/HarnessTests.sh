#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
harness="$project_dir/hijack.sh"
test_uuid=$(/usr/bin/uuidgen)
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/HarnessTests-$test_uuid.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap '/bin/rm -rf -- "$test_root"' EXIT
trap 'exit 1' HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected <$1>, got <$2>)"; }
assert_log() { /usr/bin/grep -F -- "$1" "$case_root/commands.log" >/dev/null || fail "missing command: $1"; }
assert_no_mutations() {
    if /usr/bin/grep -E '^(ditto|open|killall|lsregister|exclusive-rename)\|' "$case_root/commands.log" >/dev/null; then
        fail 'preflight or diagnostic command mutated state'
    fi
    [ ! -e "$case_root/Applications/.Preview.app.default-application-hijack-lab."* ] || fail 'unexpected staging bundle'
}
run_harness() {
    /bin/sh "$harness" "$@" >"$case_root/stdout" 2>"$case_root/stderr"
}
expect_failure() {
    if run_harness "$@"; then fail "unexpected success: $*"; else failure_status=$?; fi
}
literal_marker() {
    printf 'identifier=default-application-hijack-lab\nschema=1\nstate=%s\n' "$1" >"$marker"
}
prepare_clone() {
    /bin/cp -R "$system_bundle" "$destination"
    literal_marker "$1"
    printf '%s\n' "$destination" >"$case_root/handler-state"
}
setup_case() {
    case_root="$test_root/$1"
    system_bundle="$case_root/System/Applications/Preview.app"
    destination="$case_root/Applications/Preview.app"
    marker="$destination/Contents/Resources/.default-application-hijack-lab"
    fixture="$case_root/Fixtures/hijack-test.pdf"
    payload="$case_root/build/Preview"
    /bin/mkdir -p "$system_bundle/Contents/MacOS" "$system_bundle/Contents/Resources" \
        "$case_root/Applications" "$case_root/Fixtures" "$case_root/build" "$case_root/commands" "$case_root/Logs"
    printf 'fake trusted Preview\n' >"$system_bundle/Contents/MacOS/Preview"
    /usr/bin/plutil -create xml1 "$system_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string com.apple.Preview "$system_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string Preview "$system_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleDocumentTypes -array "$system_bundle/Contents/Info.plist"
    printf 'fake benign payload\n' >"$payload"
    printf 'fake PDF fixture\n' >"$fixture"
    /bin/chmod 755 "$system_bundle/Contents/MacOS/Preview" "$payload"
    printf '%s\n' "$system_bundle" >"$case_root/handler-state"
    printf 'normal\n' >"$case_root/mode"
    printf 'arm64\n' >"$case_root/architecture"
    printf '26.0\n' >"$case_root/version"
    printf '0\n' >"$case_root/query-count"
    : >"$case_root/commands.log"
    cat >"$case_root/commands/dispatch" <<'STUB'
#!/bin/sh
set -eu
root=$HIJACK_LAB_TEST_ROOT
name=${0##*/}
{
    printf '%s' "$name"
    for argument do printf '|%s' "$argument"; done
    printf '\n'
} >>"$root/commands.log"
read -r mode <"$root/mode"
system="$root/System/Applications/Preview.app"
destination="$root/Applications/Preview.app"
case "$name" in
    uname) [ "$#" -eq 1 ] && [ "$1" = -m ] || exit 64; cat "$root/architecture" ;;
    sw_vers) [ "$#" -eq 1 ] && [ "$1" = -productVersion ] || exit 64; cat "$root/version" ;;
    exclusive-rename)
        [ "$#" -eq 2 ] && [ "$2" = "$destination" ] || exit 64
        case "$1" in "$root/Applications/.Preview.app.default-application-hijack-lab."[0-9]*) ;; *) exit 64 ;; esac
        if [ "$mode" = rename-collision ]; then
            /bin/mkdir "$destination"
            printf 'keep unowned destination\n' >"$destination/keep"
            /usr/bin/stat -f '%d:%i' "$destination" >"$root/collision-identity"
        fi
        if [ -e "$destination" ] || [ -L "$destination" ]; then exit 1; fi
        /bin/mv -h -- "$1" "$destination"
        case "$mode" in rename-signal-*) kill "-${mode#rename-signal-}" "$PPID" ;; esac
        ;;
    ditto)
        [ "$#" -eq 2 ] && [ "$1" = "$system" ] || exit 64
        case "$2" in "$root/Applications/.Preview.app.default-application-hijack-lab."[0-9]*) ;; *) exit 64 ;; esac
        /bin/cp -R "$1" "$2"
        [ "$mode" != clone-failure ] || exit 23
        if [ "$mode" = destination-appears ]; then
            /bin/cp -R "$system" "$destination"
            printf 'identifier=default-application-hijack-lab\nschema=1\nstate=payload-installed\n' >"$destination/Contents/Resources/.default-application-hijack-lab"
            printf 'keep\n' >"$destination/keep"
        fi
        ;;
    killall) [ "$#" -eq 1 ] && [ "$1" = Preview ] || exit 64; exit 1 ;;
    open)
        if [ "$#" -eq 2 ] && [ "$1" = -a ] && [ "$2" = "$destination" ]; then
            [ -L "$destination/Contents/MacOS/Preview" ] || exit 64
            [ "$(/usr/bin/readlink "$destination/Contents/MacOS/Preview")" = "$system/Contents/MacOS/Preview" ] || exit 64
            printf 'open-symlink-launch\n' >>"$root/commands.log"
            : >"$root/launched"
            case "$mode" in
                timeout|delayed) ;;
                open-failure) exit 24 ;;
                signal) kill -TERM "$PPID" ;;
                payload-failure) /bin/rm "$root/build/Preview"; printf '%s\n' "$destination" >"$root/handler-state" ;;
                *) printf '%s\n' "$destination" >"$root/handler-state" ;;
            esac
        elif [ "$#" -eq 1 ] && [ "$1" = "$root/Fixtures/hijack-test.pdf" ]; then
            case "$mode" in
                verify-event)
                    printf '{"paths":["%s/other.pdf"]}\n' "$root" >>"$root/Logs/events.jsonl"
                    # JSONEncoder may escape the slashes in file paths.
                    escaped=$(printf '%s' "$1" | /usr/bin/sed 's,/,\\/,g')
                    printf '{"eventType":"open-files","paths":["%s"],"processID":123,"timestamp":"2026-10-14T00:00:00Z"}\n' "$escaped" >>"$root/Logs/events.jsonl"
                    ;;
                verify-old) printf '{"paths":["%s/other.pdf"]}\n' "$root" >>"$root/Logs/events.jsonl" ;;
                *) exit 64 ;;
            esac
        else exit 64; fi
        ;;
    default-handler)
        [ "$#" -eq 1 ] && [ "$1" = "$root/Fixtures/hijack-test.pdf" ] || exit 64
        read -r count <"$root/query-count"
        count=$((count + 1))
        printf '%s\n' "$count" >"$root/query-count"
        [ "$mode" != unavailable ] || exit 69
        if [ "$mode" = delayed ] && [ -f "$root/launched" ] && [ "$count" -ge 3 ]; then
            printf '%s\n' "$destination" >"$root/handler-state"
        fi
        cat "$root/handler-state"
        ;;
    lsregister)
        [ "$#" -eq 2 ] || exit 64
        case "$1" in
            -u)
                case "$2" in
                    "$destination")
                        [ -d "$destination" ] || exit 64
                        printf 'unregister-before-removal\n' >>"$root/commands.log"
                        [ "$mode" != unregister-failure ] || exit 25
                        ;;
                    "$system") ;;
                    *) exit 64 ;;
                esac
                ;;
            -f)
                case "$2" in
                    "$system")
                        [ ! -e "$destination" ] || exit 64
                        printf 'system-register-after-removal\n' >>"$root/commands.log"
                        [ "$mode" != register-failure ] || exit 26
                        printf '%s\n' "$system" >"$root/handler-state"
                        ;;
                    "$destination")
                        printf '%s\n' "$destination" >"$root/handler-state"
                        ;;
                    *) exit 64 ;;
                esac
                ;;
            *) exit 64 ;;
        esac
        ;;
    plutil)
        case "$1" in
            -remove|-replace) exit 0 ;;
            -convert) exit 0 ;;
        esac
        if [ "$1" = -insert ] && [ "$2" != event ]; then exit 0; fi
        input=$(cat)
        if [ "$1" = -insert ]; then
            [ "$#" -eq 8 ] && [ "$2" = event ] && [ "$3" = -json ] || exit 64
            case "$4" in \{*'"paths":['*']'*\}) ;; *) exit 1 ;; esac
            printf '{"event":%s}\n' "$4"
            exit 0
        fi
        [ "$#" -eq 9 ] && [ "$1" = -extract ] && [ "$4" = -expect ] || exit 64
        paths=$(printf '%s\n' "$input" | /usr/bin/sed 's/.*"paths":\(\[[^]]*\]\).*/\1/')
        case "$paths" in '["'*'"]') ;; *) exit 1 ;; esac
        case "$2:$3" in
            event.paths:raw)
                [ "$5" = array ] || exit 64
                printf '1\n'
                ;;
            event.paths.0:raw)
                [ "$5" = string ] || exit 64
                printf '%s\n' "$paths" | /usr/bin/sed 's/^\["//; s/"\]$//; s,\\/,/,g'
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 64 ;;
esac
STUB
    for command in ditto open killall lsregister default-handler uname sw_vers plutil exclusive-rename; do
        /bin/cp "$case_root/commands/dispatch" "$case_root/commands/$command"
        /bin/chmod 755 "$case_root/commands/$command"
    done
    export HIJACK_LAB_TESTING=1 HIJACK_LAB_TEST_ROOT="$case_root" HIJACK_LAB_TEST_COMMANDS="$case_root/commands"
}

# The first RED failure must identify the missing public harness.
[ -f "$harness" ] || fail 'hijack.sh does not exist'

# Load production functions without running its public command dispatcher.
# $0 remains the original harness path so project resolution is unchanged.
definitions="$test_root/harness-functions.sh"
/usr/bin/sed '1s/^/_HIJACK_SOURCED=1\n/' "$harness" >"$definitions"
cat >>"$definitions" <<'DRIVER'
test_staging_marker() { STAGING_BUNDLE=$1; write_staging_marker; }
test_real_event_parser() { PLUTIL=/usr/bin/plutil; FIXTURE_FILE=$1; new_matching_event 0; }
DRIVER
run_private() {
    /bin/sh -c '. "$1"; shift; "$@"' "$harness" "$definitions" "$@" >"$case_root/stdout" 2>"$case_root/stderr"
}

review_failed=0
for missing in fixture handler; do
    setup_case "restore_missing_$missing"
    prepare_clone payload-installed
    case "$missing" in fixture) /bin/rm "$fixture" ;; handler) /bin/rm "$case_root/commands/default-handler" ;; esac
    run_harness restore || fail "restore_missing_$missing failed"
    [ ! -e "$destination" ] || fail "restore_missing_$missing left clone"
    assert_log "lsregister|-u|$destination"
    assert_log "lsregister|-f|$system_bundle"
    if /usr/bin/grep '^default-handler|' "$case_root/commands.log" >/dev/null; then fail 'missing verification artifacts still triggered a handler query'; fi
    pass "restore_missing_${missing}_tears_down_without_handler_verification"
done

# Configuration checks use candidate roots only and mutate only the UUID tree.
for protected_tree in /Applications /System/Applications; do
    setup_case "protected_root_${protected_tree##*/}"
    ( TMPDIR="$protected_tree" HIJACK_LAB_TEST_ROOT="$protected_tree/Utilities" expect_failure status )
    if /usr/bin/grep -F 'protected application tree' "$case_root/stderr" >/dev/null; then
        pass "test_root_under_${protected_tree}_rejected_independently_of_TMPDIR"
    else printf 'FAIL: protected_test_root_guard_missing_for_%s\n' "$protected_tree" >&2; review_failed=1; fi
    assert_no_mutations
done

for protected_tree in /Applications /System/Applications; do
    case "$protected_tree" in /Applications) protected_label=user ;; *) protected_label=system ;; esac
    setup_case "protected_alias_$protected_label"
    /bin/ln -s "$protected_tree" "$case_root/protected-alias"
    ( TMPDIR="$protected_tree" HIJACK_LAB_TEST_ROOT="$case_root/protected-alias/Utilities" expect_failure status )
    /usr/bin/grep -F 'protected application tree' "$case_root/stderr" >/dev/null || fail 'canonical test root protected-tree guard missing'
    assert_no_mutations
    pass "canonical_test_root_under_${protected_tree}_rejected_independently_of_TMPDIR"
done

setup_case real_event_parser
for parser_case in xml object_paths nonstring_array openstep valid_json escaped_slash spaces unicode_literal unicode_escape; do
    expected_fixture=$fixture
    expected_match=no
    case "$parser_case" in
        xml) event="<plist version=\"1.0\"><dict><key>paths</key><array><string>$fixture</string></array></dict></plist>" ;;
        object_paths) event="{\"paths\":{\"0\":\"$fixture\"}}" ;;
        nonstring_array) event="{\"paths\":[\"$fixture\",42]}" ;;
        openstep) event="{ paths = (\"$fixture\"); }" ;;
        valid_json) event="{\"paths\":[\"/unrelated.pdf\",\"$fixture\"]}"; expected_match=yes ;;
        escaped_slash)
            escaped=$(printf '%s' "$fixture" | /usr/bin/sed 's,/,\\/,g')
            event="{\"paths\":[\"$escaped\"]}"; expected_match=yes
            ;;
        spaces) expected_fixture="$case_root/Fixtures/file with spaces.pdf"; event="{\"paths\":[\"$expected_fixture\"]}"; expected_match=yes ;;
        unicode_literal) expected_fixture="$case_root/Fixtures/試験-🧪.pdf"; event="{\"paths\":[\"$expected_fixture\"]}"; expected_match=yes ;;
        unicode_escape) expected_fixture="$case_root/Fixtures/試験-🧪.pdf"; event="{\"paths\":[\"$case_root/Fixtures/\u8a66\u9a13-\ud83e\uddea.pdf\"]}"; expected_match=yes ;;
    esac
    printf '%s\n' "$event" >"$case_root/Logs/events.jsonl"
    run_private test_real_event_parser "$expected_fixture" || { cat "$case_root/stderr" >&2; fail "real parser driver failed for $parser_case"; }
    if [ "$expected_match" = yes ]; then
        if [ "$(cat "$case_root/stdout")" = "$event" ]; then pass "real_plutil_accepts_$parser_case"
        else printf 'FAIL: real_plutil_valid_%s_rejected\n' "$parser_case" >&2; review_failed=1; fi
    else
        if [ ! -s "$case_root/stdout" ]; then pass "real_plutil_rejects_$parser_case"
        else printf 'FAIL: real_plutil_invalid_%s_accepted\n' "$parser_case" >&2; review_failed=1; fi
    fi
done
[ "$review_failed" -eq 0 ] || exit 1

boundary_failed=0
for signal in HUP INT TERM; do
    setup_case "rename_boundary_$signal"
    printf 'rename-signal-%s\n' "$signal" >"$case_root/mode"
    if run_harness install; then fail 'rename-boundary signal did not fail installation'; else failure_status=$?; fi
    case "$signal" in HUP) expected_status=129 ;; INT) expected_status=130 ;; TERM) expected_status=143 ;; esac
    assert_eq "$expected_status" "$failure_status" 'rename-boundary signal status'
    [ ! -e "$case_root/Applications/.Preview.app.default-application-hijack-lab."* ] || fail 'rename-boundary signal left staging'
    if [ -e "$destination" ]; then
        printf 'FAIL: rename_boundary_%s_left_final_clone\n' "$signal" >&2
        boundary_failed=1
    else
        assert_log "lsregister|-f|$system_bundle"
        pass "rename_boundary_${signal}_restores_identical_clone"
    fi
done
setup_case rename_boundary_collision
printf 'rename-collision\n' >"$case_root/mode"
if run_harness install; then fail 'rename-boundary collision succeeded'; fi
[ -f "$destination/keep" ] && [ "$(cat "$destination/keep")" = 'keep unowned destination' ] || fail 'move-boundary collision changed unowned destination'
assert_eq "$(cat "$case_root/collision-identity")" "$(/usr/bin/stat -f '%d:%i' "$destination")" 'collision destination identity'
if [ -e "$destination/.Preview.app.default-application-hijack-lab."* ]; then
    printf 'FAIL: rename_boundary_collision_nested_staging\n' >&2
    boundary_failed=1
else pass rename_boundary_collision_preserves_unowned_destination_without_nesting; fi
if /usr/bin/grep '^lsregister|' "$case_root/commands.log" >/dev/null; then fail 'move-boundary collision changed unowned registration'; fi
[ ! -e "$case_root/Applications/.Preview.app.default-application-hijack-lab."* ] || fail 'move-boundary collision left tracked staging'
[ "$boundary_failed" -eq 0 ] || exit 1

setup_case staging_marker_guards
stage="$case_root/Applications/.Preview.app.default-application-hijack-lab.12345"
/bin/cp -R "$system_bundle" "$stage"
run_private test_staging_marker "$stage" || fail 'valid tracked staging marker failed'
printf 'identifier=default-application-hijack-lab\nschema=1\nstate=cloned\n' >"$case_root/expected-marker"
/usr/bin/cmp -s "$case_root/expected-marker" "$stage/Contents/Resources/.default-application-hijack-lab" || fail 'staging marker bytes'
for unsafe_stage in "$case_root/Applications/Other.app" "$case_root/Applications/.Preview.app.default-application-hijack-lab.not-a-pid" "$case_root/outside/.Preview.app.default-application-hijack-lab.12345" "$case_root/Applications/../Applications/.Preview.app.default-application-hijack-lab.12345"; do
    # Existing directories ensure rejection is caused by the path policy.
    /bin/mkdir -p "$unsafe_stage/Contents/Resources"
    if run_private test_staging_marker "$unsafe_stage"; then fail 'unsafe staging path accepted'; fi
done
/bin/mkdir -p "$case_root/outside/Contents/Resources"
/bin/ln -s "$case_root/outside" "$case_root/Applications/.Preview.app.default-application-hijack-lab.98765"
if run_private test_staging_marker "$case_root/Applications/.Preview.app.default-application-hijack-lab.98765"; then fail 'staging symlink accepted'; fi
[ ! -e "$case_root/outside/Contents/Resources/.default-application-hijack-lab" ] || fail 'staging guard wrote outside tracked bundle'
resource_stage="$case_root/Applications/.Preview.app.default-application-hijack-lab.24680"
/bin/mkdir -p "$resource_stage/Contents"
/bin/ln -s "$case_root/outside/Contents/Resources" "$resource_stage/Contents/Resources"
if run_private test_staging_marker "$resource_stage"; then fail 'staging Resources escape accepted'; fi
[ ! -e "$case_root/outside/Contents/Resources/.default-application-hijack-lab" ] || fail 'staging Resources escape wrote outside bundle'
pass staging_marker_rejects_malformed_and_escaping_paths

setup_case final_marker_validation
prepare_clone cloned
run_private validate_final_clone || fail 'valid final cloned marker rejected'
printf 'extra=line\n' >>"$marker"
if run_private validate_final_clone; then fail 'final marker byte drift was accepted'; fi
[ -f "$destination/Contents/MacOS/Preview" ] && [ ! -L "$destination/Contents/MacOS/Preview" ] || fail 'failed final validation changed executable'
assert_no_mutations
pass final_marker_validation_fails_closed_on_byte_drift

setup_case install_success
run_harness install || fail 'install failed'
printf 'identifier=default-application-hijack-lab\nschema=1\nstate=payload-installed\n' >"$case_root/expected-marker"
/usr/bin/cmp -s "$case_root/expected-marker" "$marker" || fail 'final payload-installed marker'
[ -f "$destination/Contents/MacOS/Preview" ] && [ ! -L "$destination/Contents/MacOS/Preview" ] || fail 'payload is not a regular file'
/usr/bin/cmp -s "$payload" "$destination/Contents/MacOS/Preview" || fail 'wrong payload'
assert_eq 755 "$(/usr/bin/stat -f '%Lp' "$destination/Contents/MacOS/Preview")" 'payload mode'
assert_log "ditto|$system_bundle|$case_root/Applications/.Preview.app.default-application-hijack-lab."
assert_log 'open-symlink-launch'
assert_log "default-handler|$fixture"
assert_log 'killall|Preview'
/usr/bin/awk -F '|' '$1 == "default-handler" && !cloned { baseline=1 } $1 == "ditto" { if (!baseline) exit 1; cloned=1 } END { if (!cloned) exit 1 }' "$case_root/commands.log" || fail 'baseline handler was not checked before cloning'
/usr/bin/grep -F "'$harness' verify" "$case_root/stdout" >/dev/null || fail 'exact verify command missing'
/usr/bin/grep -F "'$harness' restore" "$case_root/stdout" >/dev/null || fail 'exact restore command missing'
pass install_success

setup_case existing_destination_directory_is_untouched
/bin/mkdir "$destination"
printf 'keep\n' >"$destination/keep"
expect_failure install
[ -f "$destination/keep" ] || fail 'existing directory changed'
assert_no_mutations
pass existing_destination_directory_is_untouched

setup_case existing_destination_symlink_is_untouched
/bin/ln -s "$system_bundle" "$destination"
expect_failure install
[ -L "$destination" ] && [ -f "$system_bundle/Contents/MacOS/Preview" ] || fail 'existing symlink changed'
assert_no_mutations
pass existing_destination_symlink_is_untouched

for baseline in unexpected unavailable; do
    setup_case "baseline_$baseline"
    case "$baseline" in
        unexpected) printf '%s\n' "$case_root/Other.app" >"$case_root/handler-state" ;;
        unavailable) printf 'unavailable\n' >"$case_root/mode" ;;
    esac
    expect_failure install
    [ ! -e "$destination" ] || fail 'baseline failure left a clone'
    assert_log "default-handler|$fixture"
    assert_no_mutations
    pass "initial_handler_${baseline}_stops_before_mutations"
done

for prerequisite in architecture version payload fixture; do
    setup_case "preflight_$prerequisite"
    case "$prerequisite" in
        architecture) printf 'x86_64\n' >"$case_root/architecture" ;;
        version) printf '25.6\n' >"$case_root/version" ;;
        payload) /bin/rm "$payload" ;;
        fixture) /bin/rm "$fixture" ;;
    esac
    expect_failure install
    assert_no_mutations
    [ ! -e "$destination" ] || fail 'failed preflight created destination'
    pass "preflight_rejects_$prerequisite"
done

setup_case destination_appears_during_clone
printf 'destination-appears\n' >"$case_root/mode"
expect_failure install
[ -f "$destination/keep" ] || fail 'cleanup removed a destination that this invocation did not install'
[ ! -e "$case_root/Applications/.Preview.app.default-application-hijack-lab."* ] || fail 'destination conflict left tracked staging bundle'
if /usr/bin/grep '^lsregister|' "$case_root/commands.log" >/dev/null; then fail 'cleanup changed registration for a destination it did not install'; fi
pass cleanup_does_not_remove_a_destination_that_appears_during_clone

setup_case registration_timeout_restores
printf 'timeout\n' >"$case_root/mode"
expect_failure install
[ ! -e "$destination" ] || fail 'registration timeout left clone'
assert_log 'open-symlink-launch'
assert_log "lsregister|-u|$destination"
assert_log "lsregister|-f|$system_bundle"
pass registration_timeout_restores

setup_case delayed_registration_succeeds
printf 'delayed\n' >"$case_root/mode"
run_harness install || fail 'delayed install failed'
# One initial baseline, two polling queries, then the diagnostic status query.
assert_eq 4 "$(cat "$case_root/query-count")" 'delayed query count'
/usr/bin/cmp -s "$payload" "$destination/Contents/MacOS/Preview" || fail 'delayed registration did not install payload'
pass delayed_registration_succeeds

for injected in clone-failure open-failure payload-failure signal; do
    setup_case "$injected"
    printf '%s\n' "$injected" >"$case_root/mode"
    expect_failure install
    [ ! -e "$destination" ] || fail "$injected left destination"
    [ ! -e "$case_root/Applications/.Preview.app.default-application-hijack-lab."* ] || fail "$injected left staging"
    case "$injected" in
        clone-failure) assert_eq 23 "$failure_status" 'clone failure status survived cleanup' ;;
        open-failure) assert_eq 24 "$failure_status" 'launch failure status survived cleanup' ;;
        signal) assert_eq 143 "$failure_status" 'signal failure status survived cleanup' ;;
    esac
    if [ "$injected" != clone-failure ]; then assert_log "lsregister|-f|$system_bundle"; fi
    pass "$injected cleanup_preserves_failure"
done

setup_case verify_requires_payload_installed_state
prepare_clone registered
expect_failure verify
if /usr/bin/grep '^open|' "$case_root/commands.log" >/dev/null; then fail 'verify launched an incomplete clone'; fi
[ -d "$destination" ] || fail 'verification removed clone'
pass verify_requires_payload_installed_state

setup_case verify_requires_clone_handler
prepare_clone payload-installed
printf '%s\n' "$system_bundle" >"$case_root/handler-state"
expect_failure verify
if /usr/bin/grep '^open|' "$case_root/commands.log" >/dev/null; then fail 'verify opened fixture with wrong handler'; fi
pass verify_requires_clone_handler

setup_case 'verify new matching event with spaces'
prepare_clone payload-installed
printf '{"paths":["%s"]}\n' "$fixture" >"$case_root/Logs/events.jsonl"
printf 'verify-event\n' >"$case_root/mode"
run_harness verify || fail 'new matching event was not accepted'
assert_log "open|$fixture"
/usr/bin/grep -F '"processID":123' "$case_root/stdout" >/dev/null || fail 'new matching event was not reported'
if /usr/bin/grep 'other.pdf' "$case_root/stdout" >/dev/null; then fail 'unrelated event was printed'; fi
pass verify_opens_fixture_and_observes_only_a_new_matching_log_line

setup_case verify_ignores_old_matching_event
prepare_clone payload-installed
printf '{"paths":["%s"]}\n' "$fixture" >"$case_root/Logs/events.jsonl"
printf 'verify-old\n' >"$case_root/mode"
expect_failure verify
[ -d "$destination" ] || fail 'verification timeout removed clone'
/usr/bin/grep -F 'status' "$case_root/stderr" >/dev/null || fail 'verification failure lacks status recovery'
/usr/bin/grep -F 'restore' "$case_root/stderr" >/dev/null || fail 'verification failure lacks restore recovery'
pass verify_ignores_old_matching_event_and_retains_clone

setup_case restore_valid_clone
prepare_clone payload-installed
run_harness restore || fail 'valid restore failed'
[ ! -e "$destination" ] || fail 'restore left clone'
assert_eq "$system_bundle" "$(cat "$case_root/handler-state")" 'restored handler'
assert_log 'unregister-before-removal'
assert_log 'system-register-after-removal'
/usr/bin/awk '/unregister-before-removal/ { unregistered=1 } /system-register-after-removal/ { if (!unregistered) exit 1; registered=1 } END { if (!registered) exit 1 }' "$case_root/commands.log" || fail 'restoration order'
pass restore_valid_clone

setup_case restore_invalid_marker_refuses_removal
prepare_clone payload-installed
printf 'invalid marker\n' >"$marker"
expect_failure restore
[ -d "$destination" ] && [ -f "$marker" ] || fail 'invalid marker allowed removal'
assert_no_mutations
pass restore_invalid_marker_refuses_removal

setup_case restore_absent_destination_is_idempotent
run_harness restore || fail 'absent restore failed'
run_harness restore || fail 'second absent restore failed'
assert_log "lsregister|-f|$system_bundle"
if /usr/bin/grep '^lsregister|-u|' "$case_root/commands.log" >/dev/null; then fail 'absent clone was unregistered'; fi
pass restore_absent_destination_is_idempotent

setup_case restore_unregister_failure_still_registers_system
prepare_clone payload-installed
printf 'unregister-failure\n' >"$case_root/mode"
expect_failure restore
[ ! -e "$destination" ] || fail 'unregister failure prevented guarded removal'
assert_log 'system-register-after-removal'
pass restore_unregister_failure_still_registers_system

setup_case restore_register_failure_reports_recovery
prepare_clone payload-installed
printf 'register-failure\n' >"$case_root/mode"
expect_failure restore
[ ! -e "$destination" ] || fail 'system registration failure prevented removal'
/usr/bin/grep -F 'lsregister' "$case_root/stderr" >/dev/null || fail 'manual recovery command missing'
pass restore_register_failure_reports_recovery

setup_case status_is_read_only
prepare_clone payload-installed
run_harness status || fail 'status failed'
/usr/bin/grep -Fx 'clone: present' "$case_root/stdout" >/dev/null || fail 'clone status'
/usr/bin/grep -Fx 'marker: payload-installed' "$case_root/stdout" >/dev/null || fail 'marker status'
/usr/bin/grep -Fx 'executable: regular-file' "$case_root/stdout" >/dev/null || fail 'executable status'
assert_no_mutations
printf 'unavailable\n' >"$case_root/mode"
run_harness status || fail 'unresolved diagnostic status failed'
/usr/bin/grep -Fx 'fixture-handler: unresolved' "$case_root/stdout" >/dev/null || fail 'unresolved status'
assert_no_mutations
pass status_is_read_only_and_reports_unresolved_handler

setup_case test_configuration_guards
( HIJACK_LAB_TESTING=0 expect_failure status )
assert_no_mutations
( HIJACK_LAB_TESTING=2 expect_failure status )
( HIJACK_LAB_TEST_ROOT=/Applications expect_failure install )
( HIJACK_LAB_TEST_ROOT= expect_failure install )
/bin/chmod 644 "$case_root/commands/exclusive-rename"
expect_failure install
/bin/chmod 755 "$case_root/commands/exclusive-rename"
/bin/chmod 644 "$case_root/commands/open"
expect_failure install
/bin/chmod 755 "$case_root/commands/open"
/bin/rm "$case_root/commands/open"
/bin/ln -s /usr/bin/open "$case_root/commands/open"
expect_failure install
assert_no_mutations
pass test_configuration_rejects_real_paths_disabled_mode_and_untrusted_commands

printf 'HarnessTests: PASS\n'
