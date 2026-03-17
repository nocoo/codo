# 03 - Build and Install

> Build pipeline, app bundle assembly, installation, and verification procedure.

## Build Modes

| Mode | Command | Output | Use For |
|------|---------|--------|---------|
| Debug | `swift build` | `.build/debug/Codo` | Unit tests, socket/codec development |
| Release | `swift build -c release` | `.build/release/Codo` | Performance testing (still bare binary) |
| **App Bundle** | `./scripts/build.sh` | `.build/Codo.app` | **Production — the only supported install target** |

### Bare Binary vs App Bundle

| Capability | Bare Binary | App Bundle |
|------------|-------------|------------|
| Unit tests (L1) | ✅ | N/A |
| SwiftLint (L2) | ✅ | N/A |
| Socket IPC | ✅ | ✅ |
| CLI mode | ✅ | ✅ |
| `UNUserNotificationCenter` | ❌ crash (no bundleIdentifier) | ✅ |
| `LSUIElement` (hide Dock icon) | ❌ | ✅ |
| `SMAppService` (login item) | ❌ | ✅ |
| Stable code signature | ❌ | ✅ |

**Bare binary is for development and testing only.** It cannot display notifications. Production use requires the `.app` bundle.

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

## Installation

**Only one install method** — `.app` bundle + PATH symlink:

```bash
# 1. Build app bundle
./scripts/build.sh

# 2. Install app
cp -r .build/Codo.app /Applications/Codo.app

# 3. Create CLI symlink (same binary, accessible from PATH)
ln -sf /Applications/Codo.app/Contents/MacOS/Codo /usr/local/bin/codo
```

### Verify (order matters)

```bash
# Step 1: Start daemon FIRST
open /Applications/Codo.app
# → Confirm: bell icon appears in menubar
# → Confirm: macOS prompts for notification permission (first launch)
# → Grant permission

# Step 2: Send test notification via CLI
echo '{"title":"Hello Codo","body":"Installation verified"}' | codo
# → Confirm: macOS toast notification appears
# → Confirm: CLI exits with code 0

# Step 3: Verify error handling
echo '{"bad json' | codo
# → Confirm: stderr shows error, exit code 1
```

## Code Signing

| Setting | Value | Reason |
|---------|-------|--------|
| Identity | `Apple Development` | Stable across rebuilds (Gecko lesson: ad-hoc `"-"` loses TCC permissions) |
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
