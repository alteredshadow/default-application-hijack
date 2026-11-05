#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
cd "$project_dir"

test_uuid=$(/usr/bin/uuidgen)
test_build=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/DefaultApplicationHijackLabTests-$test_uuid.XXXXXX")
trap '/bin/rm -rf -- "$test_build"' EXIT
trap 'exit 1' HUP INT TERM

/bin/mkdir "$test_build/ModuleCache"
xcrun swiftc -module-cache-path "$test_build/ModuleCache" \
  Sources/EventLog.swift Tests/EventLogTests.swift -o "$test_build/EventLogTests"
"$test_build/EventLogTests"
xcrun swiftc -module-cache-path "$test_build/ModuleCache" \
  Sources/HandlerResolver.swift Tests/HandlerResolverTests.swift \
  -framework AppKit -o "$test_build/HandlerResolverTests"
"$test_build/HandlerResolverTests"
/bin/sh Tests/HijackCoreTests.sh
/bin/sh Tests/HarnessTests.sh
/bin/sh Tests/ExclusiveRenameTests.sh
/bin/sh -n build.sh
/bin/sh -n hijack.sh
/bin/sh -n lib/hijack_core.sh
/bin/sh -n test.sh

printf '%s\n' 'All automated tests passed; real Launch Services was not modified.'
