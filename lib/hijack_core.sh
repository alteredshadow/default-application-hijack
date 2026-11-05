#!/bin/sh
# Sourced POSIX shell primitives. The caller configures the four public paths.

_hijack_error() {
    printf 'hijack lab: %s\n' "$1" >&2
    return 1
}

require_known_state() {
    [ "$#" -eq 1 ] || { _hijack_error 'one marker state is required'; return 1; }
    case "$1" in
        cloned|registered|payload-installed) return 0 ;;
        *) _hijack_error "unknown marker state: $1" ;;
    esac
}

require_outside_application_trees() {
    case "$1" in
        /Applications|/Applications/*|/System/Applications|/System/Applications/*)
            _hijack_error 'test path is inside a protected application tree'; return 1 ;;
    esac
}

real_applications_directory() (
    case "${USER_APPLICATIONS:-0}" in
        0) printf '/Applications\n' ;;
        1)
            case "${HOME:-}" in /*) ;; *) _hijack_error 'HOME must be absolute'; return 1 ;; esac
            case "$HOME" in /|*/|*/.|*/..|*/./*|*/../*|*//*)
                _hijack_error 'unsafe HOME path'; return 1 ;;
            esac
            physical_home=$(CDPATH= cd -P -- "$HOME" && pwd -P) || return 1
            [ "$physical_home" = "$HOME" ] || { _hijack_error 'HOME contains a symlink'; return 1; }
            applications="$HOME/Applications"
            [ -d "$applications" ] && [ ! -L "$applications" ] || {
                _hijack_error 'user Applications must be an existing directory, not a symlink'; return 1;
            }
            printf '%s\n' "$applications"
            ;;
        *) _hijack_error 'invalid application scope'; return 1 ;;
    esac
)

require_safe_destination() (
    case "${DEST_BUNDLE:-}" in
        /*) ;;
        *) _hijack_error 'destination must be absolute'; return 1 ;;
    esac
    case "$DEST_BUNDLE" in
        /|/Applications|/System/Applications/*|*/|*/.|*/..|*/./*|*/../*|*//*)
            _hijack_error 'unsafe destination path'; return 1 ;;
    esac
    [ ! -L "$DEST_BUNDLE" ] || { _hijack_error 'destination is a symlink'; return 1; }
    if [ -e "$DEST_BUNDLE" ] && [ ! -d "$DEST_BUNDLE" ]; then
        _hijack_error 'destination is not a directory'; return 1
    fi

    parent=${DEST_BUNDLE%/*}
    [ -n "$parent" ] || parent=/
    canonical_parent=$(CDPATH= cd -P -- "$parent" && pwd -P) || return 1
    case "${HIJACK_LAB_TESTING:-0}" in
        1)
            require_outside_application_trees "$DEST_BUNDLE" || return 1
            require_outside_application_trees "$canonical_parent" || return 1
            canonical_temp=$(CDPATH= cd -P -- "${TMPDIR:-/tmp}" && pwd -P) || return 1
            [ "$canonical_temp" != / ] || { _hijack_error 'temporary root must not be /'; return 1; }
            case "$canonical_parent" in
                "$canonical_temp"/*) ;;
                *) _hijack_error 'test destination parent must be under the temporary root'; return 1 ;;
            esac
            ;;
        0)
            applications=$(real_applications_directory) || return 1
            case "$DEST_BUNDLE" in
                "$applications"/*.app) ;;
                *) _hijack_error "real destination must be under $applications: $DEST_BUNDLE"; return 1 ;;
            esac
            [ "$canonical_parent" = "$applications" ] || {
                _hijack_error 'real destination parent has changed'; return 1;
            }
            ;;
        *) _hijack_error 'HIJACK_LAB_TESTING must be 0 or 1'; return 1 ;;
    esac
)

# Validate both lexical containment and physical containment before marker I/O.
_hijack_require_marker_location() (
    case "${MARKER_FILE:-}" in
        "$DEST_BUNDLE"/Contents/Resources/*) ;;
        *) _hijack_error 'marker must be under destination Contents/Resources'; return 1 ;;
    esac
    case "$MARKER_FILE" in
        */|*/.|*/..|*/./*|*/../*|*//*) _hijack_error 'unsafe marker path'; return 1 ;;
    esac
    [ -d "$DEST_BUNDLE" ] && [ ! -L "$DEST_BUNDLE/Contents" ] &&
        [ ! -L "$DEST_BUNDLE/Contents/Resources" ] || {
            _hijack_error 'marker bundle directories must not be symlinks'; return 1;
        }
    canonical_bundle=$(CDPATH= cd -P -- "$DEST_BUNDLE" && pwd -P) || return 1
    canonical_resources=$(CDPATH= cd -P -- "$DEST_BUNDLE/Contents/Resources" && pwd -P) || return 1
    [ "$canonical_resources" = "$canonical_bundle/Contents/Resources" ] || {
        _hijack_error 'marker resources escape the destination'; return 1;
    }
    marker_parent=${MARKER_FILE%/*}
    canonical_marker_parent=$(CDPATH= cd -P -- "$marker_parent" && pwd -P) || return 1
    case "$canonical_marker_parent" in
        "$canonical_resources"|"$canonical_resources"/*) ;;
        *) _hijack_error 'marker parent escapes Resources'; return 1 ;;
    esac
)

write_marker_state() (
    [ "$#" -eq 1 ] || { _hijack_error 'one marker state is required'; return 1; }
    require_known_state "$1" || return 1
    require_safe_destination || return 1
    _hijack_require_marker_location || return 1
    marker_name=${MARKER_FILE##*/}
    # Pin the validated directory for the temporary file, cleanup, and rename.
    CDPATH= cd -P -- "${MARKER_FILE%/*}" || return 1
    [ ! -L "./$marker_name" ] || { _hijack_error 'marker is a symlink'; return 1; }
    if [ -e "./$marker_name" ] && [ ! -f "./$marker_name" ]; then
        _hijack_error 'marker is not a regular file'; return 1
    fi
    marker_tmp=$(/usr/bin/mktemp "./.$marker_name.tmp.XXXXXX") || return 1
    trap '/bin/rm -f -- "$marker_tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    /bin/chmod 600 "$marker_tmp" || return 1
    printf 'identifier=default-application-hijack-lab\nschema=1\nstate=%s\n' "$1" >"$marker_tmp" || return 1
    [ ! -L "./$marker_name" ] || { _hijack_error 'marker became a symlink'; return 1; }
    if [ -e "./$marker_name" ] && [ ! -f "./$marker_name" ]; then
        _hijack_error 'marker became a nonregular file'; return 1
    fi
    /bin/mv -f -h -- "$marker_tmp" "./$marker_name"
)

read_marker_state() (
    require_safe_destination || return 1
    _hijack_require_marker_location || return 1
    [ -f "$MARKER_FILE" ] && [ ! -L "$MARKER_FILE" ] || {
        _hijack_error 'marker must be a regular file and not a symlink'; return 1;
    }
    # cmp checks every byte, including the single final newline.
    for state in cloned registered payload-installed; do
        if printf 'identifier=default-application-hijack-lab\nschema=1\nstate=%s\n' "$state" |
            /usr/bin/cmp -s "$MARKER_FILE" -; then
            printf '%s\n' "$state"
            return 0
        fi
    done
    _hijack_error 'marker document is invalid'
)

remove_marked_clone() (
    [ -n "${DEST_BUNDLE:-}" ] || { _hijack_error 'destination is required'; return 1; }
    # A dangling symlink is present and must still pass the rejection guard.
    if [ ! -e "$DEST_BUNDLE" ] && [ ! -L "$DEST_BUNDLE" ]; then return 0; fi
    require_safe_destination || return 1
    destination_identity=$(/usr/bin/stat -f '%d:%i' "$DEST_BUNDLE") || return 1
    canonical_parent=$(CDPATH= cd -P -- "${DEST_BUNDLE%/*}" && pwd -P) || return 1
    state=$(read_marker_state) || return 1
    require_known_state "$state" || return 1
    require_safe_destination || return 1
    current_parent=$(CDPATH= cd -P -- "${DEST_BUNDLE%/*}" && pwd -P) || return 1
    [ "$canonical_parent" = "$current_parent" ] || {
        _hijack_error 'destination parent changed during marker validation'; return 1;
    }
    [ "$destination_identity" = "$(/usr/bin/stat -f '%d:%i' "$DEST_BUNDLE")" ] || {
        _hijack_error 'destination identity changed during marker validation'; return 1;
    }
    [ ! -L "$DEST_BUNDLE" ] || { _hijack_error 'destination became a symlink'; return 1; }
    # POSIX shell cannot make pathname checks and recursive deletion one atomic
    # operation. Run this lab only in its private, nonconcurrently modified tree.
    /bin/rm -rf -- "$DEST_BUNDLE"
)

