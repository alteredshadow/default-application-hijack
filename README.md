# Default Application Hijack

Hijacks macOS default file associations by cloning a system application and registering the clone as the preferred handler. When a user opens a file through Finder, the clone executes a payload, then transparently forwards the file to the real application.

## How it works

1. **Clone** — copies the target system app (default: Preview) to `~/Applications/` or `/Applications/`
2. **Swap executable** — replaces the clone's binary with a reflective loader that downloads and executes a payload dylib from a URL
3. **Set LSHandlerRank=Owner** — marks all document types as Owner rank (higher priority than the system app's Default rank)
4. **Register with LaunchServices** — force-registers the clone via `_LSRegisterURLWithOptions` SPI
5. **Set handler preferences** — uses `NSWorkspace setDefaultApplicationAtURL:toOpenContentType:completionHandler:` to bind each UTI to the clone's path

The clone uses the **same bundle ID** as the system app. The NSWorkspace API accepts a URL (path), not a bundle ID, so two apps with the same ID at different paths can coexist.

## IoC profile

| Artifact | Present? |
|---|---|
| Unique bundle ID in LS database | No — same as system app |
| `com.apple.launchservices.secure.plist` writes | No — NSWorkspace stores associations internally |
| `killall lsd` / process kills | No |
| Finder popups (CoreServicesUIAgent) | No — only claims UTIs already owned by the target bundle ID |
| Clone app on disk | Yes — `~/Applications/Preview.app` or `/Applications/Preview.app` |

## Limitations

- **`/usr/bin/open` from Terminal** does not route through the clone on macOS 26. It uses a different handler resolution path than Finder/NSWorkspace. Only Finder-initiated file opens (double-click, "Open With") are intercepted.
- **macOS Resume** — the clone passes `-F` to `open` when forwarding to the real app, suppressing state restoration of previously-viewed documents.

## Prerequisites

- Apple Silicon (`arm64`) running macOS 26
- Xcode Command Line Tools with macOS 26 SDK
- `~/Applications/` mode requires no privileges; `/Applications/` mode requires admin access

## Build

```sh
./build.sh <payload-url>
```

Options:
- `--warmup` — enables anti-sandbox warmup (randomized delay, chunked XOR decode)
- `--target /path/to/App.app` — target a different system app (default: `/System/Applications/Preview.app`)

Output: `build/ReflectiveLoader` (ad-hoc signed with entitlements) and `build/libpayload.dylib`.

## Install

```sh
# User-scoped (~/Applications, no admin needed)
./hijack.sh --user-applications install

# System-scoped (/Applications, needs admin)
./hijack.sh install

# Target a different app
./hijack.sh --user-applications --target /System/Applications/TextEdit.app install
```

## Verify and restore

```sh
./hijack.sh --user-applications status
./hijack.sh --user-applications verify
./hijack.sh --user-applications restore
```

## Testing

Test by double-clicking a PDF in Finder (not via `open` in Terminal). The clone will:
1. Receive the file-open event
2. Forward the file to the real system app via `open -F -a`
3. Download and execute the payload from the baked-in URL

Automated tests (no real LS changes):
```sh
./test.sh
```

## Loader behavior

On launch, the clone:
1. Forwards opened files to the real app and exits the initial run loop
2. Re-registers itself with LaunchServices (`_LSRegisterURLWithOptions`)
3. Checks for another clone instance by path (not bundle ID, since the real app shares the ID)
4. Downloads the payload dylib from the compiled-in URL
5. Loads it via reflective `dlopen` from memory
6. Re-enters the run loop to handle subsequent file-open events
