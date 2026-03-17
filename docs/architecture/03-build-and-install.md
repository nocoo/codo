# 03 - Build and Install

> Build pipeline, app bundle assembly, and installation procedure.

## Build Targets

| Mode | Build | Output | Use Case |
|------|-------|--------|----------|
| Debug | `swift build` | `.build/debug/Codo` | Development, bare binary |
| Release | `swift build -c release` | `.build/release/Codo` | Optimized bare binary |
| App Bundle | `./scripts/build.sh` | `.build/Codo.app` | Full app with notifications + login item |

### Why App Bundle?

Bare SPM binary lacks:
- `Bundle.main.bundleIdentifier` → **`UNUserNotificationCenter` crashes** (Owl lesson)
- `Info.plist` with `LSUIElement` → cannot hide Dock icon properly
- Stable code signature → **TCC permissions lost on rebuild** (Gecko lesson)
- `SMAppService` support → cannot register login item

**App bundle is required for production use.** Bare binary works for socket/CLI development only.

## App Bundle Structure

```
Codo.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── Codo              ← SPM-compiled binary
│   └── Resources/
│       └── (reserved for future assets)
```

## Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.nocoo.codo</string>
    <key>CFBundleName</key>
    <string>Codo</string>
    <key>CFBundleDisplayName</key>
    <string>Codo</string>
    <key>CFBundleExecutable</key>
    <string>Codo</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
```

Key entries:
- `LSUIElement = true` — no Dock icon, no app menu
- `CFBundleIdentifier = dev.nocoo.codo` — required for `UNUserNotificationCenter`

## scripts/build.sh

Procedure (mirroring Owl's proven pipeline):

```
1. swift build -c release
2. rm -rf .build/Codo.app
3. mkdir -p .build/Codo.app/Contents/{MacOS,Resources}
4. cp .build/release/Codo .build/Codo.app/Contents/MacOS/
5. cp Resources/Info.plist .build/Codo.app/Contents/
6. codesign --force --options runtime --sign "Apple Development" .build/Codo.app
```

## Installation (Manual, v1)

### App (daemon mode)

```bash
# Build
./scripts/build.sh

# Install
cp -r .build/Codo.app /Applications/Codo.app
```

### CLI (client mode)

```bash
# Symlink into PATH — points to the same binary inside the app bundle
ln -sf /Applications/Codo.app/Contents/MacOS/Codo /usr/local/bin/codo
```

This ensures the CLI binary has access to the app's bundle identifier when running in daemon mode, while also being callable as `codo` from any terminal.

### Verify

```bash
# CLI mode
echo '{"title":"Hello"}' | codo

# Daemon mode (launches menubar app)
open /Applications/Codo.app
```

## Code Signing

| Setting | Value | Reason |
|---------|-------|--------|
| Identity | `Apple Development` | Stable across rebuilds (Gecko lesson: ad-hoc loses TCC) |
| Options | `--options runtime` | Required for notarization (future) |
| Sandbox | **No** | Unix Domain Socket needs filesystem access |

## Version Management

Single source of truth in `Sources/CodoCore/CodoInfo.swift`:

```swift
public enum CodoInfo {
    public static let version = "0.1.0"
}
```

`Info.plist` `CFBundleShortVersionString` must match. `build.sh` can optionally sync this.

## Atomic Commits Plan

| # | Commit | Content |
|---|--------|---------|
| 1 | `chore: init spm project` | Package.swift, .gitignore, empty targets |
| 2 | `feat: add message types and codec` | CodoCore — CodoMessage, CodoResponse, JSON coding |
| 3 | `feat: add socket server` | CodoCore — SocketServer actor, bind/accept/read/respond |
| 4 | `feat: add cli client` | CodoCore — CLIClient, stdin read, socket connect/send |
| 5 | `feat: add notification service` | CodoCore — NotificationService, bundleIdentifier guard |
| 6 | `feat: add menubar daemon` | Codo — AppDelegate, NSStatusItem, SF Symbol icon |
| 7 | `feat: add mode router` | Codo — main.swift, stdin/flag detection, dispatch |
| 8 | `feat: add app bundle pipeline` | Resources/Info.plist, scripts/build.sh |
| 9 | `test: add core unit tests` | CodoTests — message codec, socket roundtrip, CLI client |
| 10 | `docs: add project documentation` | README.md, docs/ |
