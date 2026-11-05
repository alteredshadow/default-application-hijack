# Default Application Hijack Lab

## Authorized disposable-host lab

Run this lab only on an authorized, disposable Apple Silicon macOS 26 host with an interactive login session. Installation changes the local Launch Services registration and creates `/Applications/Preview.app`. Keep the restore command available before installing, and do not run installation on a daily-use host.

## What this reproduces

The lab clones system Preview from `/System/Applications/Preview.app` to `/Applications/Preview.app`, replaces the clone's executable with a symlink to the trusted system Preview executable, launches the clone to register it with Launch Services, and then swaps only that symlink for a benign payload. Opening `Fixtures/hijack-test.pdf` through its default handler can then select the clone. Launch Services behavior can vary by macOS build, so record the observed paths rather than assuming registration succeeded.

## Safety properties

The payload displays an alert titled `Launch Services Hijack Test` and appends file-open events to a local JSON Lines log. It does not read PDF contents, make network connections, request privacy permissions, or run commands from opened files.

Real bundle paths are fixed in `hijack.sh`. Installation refuses any existing `/Applications/Preview.app`, including a symlink. An internal `build/exclusive-rename` helper atomically moves the marked staging bundle into place without merging into or replacing an existing destination. Restoration removes only `/Applications/Preview.app` after validating its regular, non-symlink marker with the exact lab identifier, schema, and known state. Test path overrides require `HIJACK_LAB_TESTING=1` and a temporary test root. Test roots and destinations inside `/Applications` or `/System/Applications`, including symlink aliases, are rejected regardless of `TMPDIR`.

## Prerequisites

- Apple Silicon (`arm64`) running macOS 26.
- Xcode Command Line Tools with the macOS 26 SDK and `xcrun swiftc`.
- Administrator access to `/Applications` for the real install and restore steps.
- No pre-existing `/Applications/Preview.app`. The installer refuses to replace one.
- An interactive login session in a disposable VM for real handler and alert validation. The shell tests use fake bundles and do not change the real Launch Services database.

## Build and automated tests

From this directory:

```sh
./build.sh
./test.sh
```

The build creates and ad hoc signs `build/Preview`, `build/default-handler`, and the internal safety artifact `build/exclusive-rename`. The latter enforces the no-merge destination move. `./test.sh` compiles Swift unit tests in a temporary UUID directory and runs the shell suites, including `/bin/sh Tests/ExclusiveRenameTests.sh`; that suite compiles, signs, and verifies the rename helper. The test command never registers an app or writes to the real `/Applications` directory.

## Install and immediately restore

On the authorized disposable host, keep these commands together. Run the restore command immediately if installation succeeds and you are not continuing with verification:

```sh
./hijack.sh install
./hijack.sh restore
```

Installation requires the fixture's initial handler to be `/System/Applications/Preview.app`. It refuses an unresolved or different baseline before cloning. If installation fails after creating the marked clone, the harness attempts guarded restoration automatically. Inspect `./hijack.sh status` and follow manual recovery below if that attempt fails.

If the fixture or `build/default-handler` is missing, `restore` still unregisters and removes a valid marked clone and registers system Preview. It returns nonzero because handler verification is unavailable, and prints commands to rebuild the helpers, restore the tracked fixture, inspect status, and manually register system Preview.

## Verify

After a successful installation, use these commands before restoring:

```sh
./hijack.sh status
./hijack.sh verify
```

`verify` opens the fixture through its default handler without naming an application. Confirm the visible alert title is `Launch Services Hijack Test`, dismiss the alert, and check the new event for the fixture's absolute path in `~/Library/Logs/DefaultApplicationHijackLab/events.jsonl`. Verification waits up to 15 seconds for a new matching JSON Lines record and retains the marked clone if it times out. Then run `./hijack.sh restore`.

## Reboot persistence check

First confirm `./hijack.sh restore` is available in this directory and that you can return to the same interactive login session. After an installed state is confirmed, reboot the disposable host, log in, and run:

```sh
./hijack.sh verify
./hijack.sh restore
```

Confirm the alert and a new log event again. After restoration, `./build/default-handler Fixtures/hijack-test.pdf` must print `/System/Applications/Preview.app` on the disposable host.

## Expected status output

On a clean host with system Preview as the PDF handler, `./hijack.sh status` prints:

```text
clone: absent
marker: absent
executable: absent
fixture-handler: /System/Applications/Preview.app
```

After installation:

```text
clone: present
marker: payload-installed
executable: regular-file
fixture-handler: /Applications/Preview.app
```

After restoration:

```text
clone: absent
marker: absent
executable: absent
fixture-handler: /System/Applications/Preview.app
```

A development session with an empty or unavailable Launch Services database can instead show `fixture-handler: unresolved`; do not install there. Perform real handler validation in the disposable interactive-login VM.

## Manual recovery

Use manual recovery only when guarded `./hijack.sh restore` cannot complete. Inspect the exact bundle and marker paths. The marker must be a regular file, not a symlink, at `/Applications/Preview.app/Contents/Resources/.default-application-hijack-lab`, with exactly these three lines and one of the listed states:

```text
identifier=default-application-hijack-lab
schema=1
state=cloned
```

The third line may instead be exactly `state=registered` or `state=payload-installed`. From this project directory, run this single block. It requires real bundle, `Contents`, and `Resources` directories, checks their physical paths and the marker's physical parent, and compares every marker byte. Any mismatch exits before unregistering or removing the clone:

```sh
/bin/sh -eu <<'SH'
bundle=/Applications/Preview.app
contents="$bundle/Contents"
resources="$contents/Resources"
marker="$resources/.default-application-hijack-lab"
[ -d "$bundle" ] && [ ! -L "$bundle" ]
[ -d "$contents" ] && [ ! -L "$contents" ]
[ -d "$resources" ] && [ ! -L "$resources" ]
bundle_physical=$(CDPATH= cd -P -- "$bundle" && pwd -P)
contents_physical=$(CDPATH= cd -P -- "$contents" && pwd -P)
resources_physical=$(CDPATH= cd -P -- "$resources" && pwd -P)
marker_parent_physical=$(CDPATH= cd -P -- "${marker%/*}" && pwd -P)
[ "$bundle_physical" = "$bundle" ]
[ "$contents_physical" = "$bundle_physical/Contents" ]
[ "$resources_physical" = "$contents_physical/Resources" ]
[ "$marker_parent_physical" = "$resources_physical" ]
[ -f "$marker" ] && [ ! -L "$marker" ]
valid=0
for state in cloned registered payload-installed; do
    if printf 'identifier=default-application-hijack-lab\nschema=1\nstate=%s\n' "$state" | /usr/bin/cmp -s - "$marker"; then
        valid=1
        break
    fi
done
[ "$valid" -eq 1 ] || { printf 'Marker mismatch; do not remove the bundle\n' >&2; exit 1; }
printf 'Exact lab marker validated: %s\n' "$state"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/Preview.app
sudo /bin/rm -rf -- /Applications/Preview.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /System/Applications/Preview.app
./build/default-handler Fixtures/hijack-test.pdf
SH
```

The last command must print `/System/Applications/Preview.app`. If this block fails at any point, preserve the evidence and inspect the host's Launch Services state before another install.

## Test record

Record the host build and architecture, then record the handler path before installation, after installation, after reboot verification, and after restoration:

```sh
sw_vers -buildVersion
uname -m
./build/default-handler Fixtures/hijack-test.pdf
```

Also record the alert observation and the matching event path from `~/Library/Logs/DefaultApplicationHijackLab/events.jsonl`. Use the actual macOS 26 build number in the test results.
