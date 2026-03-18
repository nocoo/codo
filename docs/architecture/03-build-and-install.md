# 03 - Build and Install

> Build, bundle, and install procedures for both layers.

## Swift Daemon

### Build Modes

| Mode | Command | Output | Use For |
|------|---------|--------|---------|
| Debug | `swift build` | `.build/debug/Codo` | Tests, socket development |
| Release | `swift build -c release` | `.build/release/Codo` | Performance testing |
| **App Bundle** | `./scripts/build.sh` | `.build/release/Codo.app` | **Production install** |

Bare binary cannot show notifications (no bundleIdentifier). Production requires `.app` bundle.

### App Bundle Structure

```
Codo.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── Codo
│   └── Resources/
│       ├── AppIcon.icns        ← App icon (legacy fallback)
│       ├── Assets.car          ← Compiled Asset Catalog (notification banner icon)
│       ├── menubar.png         ← Menubar template image (18×18)
│       └── menubar@2x.png     ← Menubar template image (36×36, Retina)
```

### Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ai.hexly.codo.01</string>
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSUserNotificationUsageDescription</key>
    <string>Codo displays notifications from Claude Code hooks.</string>
</dict>
</plist>
```

**Note**: `CFBundleIconName` is required for notification banners to display the app icon on `LSUIElement` menubar apps. `CFBundleIconFile` (`.icns`) alone is not sufficient — macOS notification system reads icons from the compiled Asset Catalog (`.car`).

### scripts/build.sh

```bash
swift build -c release
rm -rf .build/release/Codo.app
mkdir -p .build/release/Codo.app/Contents/{MacOS,Resources}
cp .build/release/Codo .build/release/Codo.app/Contents/MacOS/
cp Resources/Info.plist .build/release/Codo.app/Contents/
cp Resources/AppIcon.icns .build/release/Codo.app/Contents/Resources/

# Compile Asset Catalog (provides CFBundleIconName for notification banners)
xcrun actool Resources/Assets.xcassets \
  --compile .build/release/Codo.app/Contents/Resources \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist /dev/null

# Copy menubar template images
cp Resources/menubar.png .build/release/Codo.app/Contents/Resources/
cp Resources/menubar@2x.png .build/release/Codo.app/Contents/Resources/

codesign --force --options runtime \
  --sign "Apple Development" --team-id "93WWLTN9XU" \
  .build/release/Codo.app
```

### Code Signing

| Setting | Value | Reason |
|---------|-------|--------|
| Identity | `Apple Development` | Stable across rebuilds (ad-hoc loses TCC) |
| Sandbox | No | UDS needs filesystem access |

## TypeScript CLI

No build step. Single `.ts` file with Bun shebang.

```
cli/
├── codo.ts          ← #!/usr/bin/env bun
├── codo.test.ts     ← bun test
└── package.json     ← metadata only
```

## Installation

Both `.app` and CLI are installed to stable paths. No dependency on the source repo after install.

### scripts/install.sh

```bash
#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.codo"

# Build Swift daemon
./scripts/build.sh

# Install .app
cp -r .build/Codo.app /Applications/Codo.app

# Install CLI to stable path
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"
cp cli/codo.ts "$INSTALL_DIR/codo.ts"
chmod +x "$INSTALL_DIR/codo.ts"
ln -sf "$INSTALL_DIR/codo.ts" /usr/local/bin/codo
```

After install, the repo can be moved or deleted. The CLI lives at `~/.codo/codo.ts`, symlinked from `/usr/local/bin/codo`.

### Verify (order matters)

```bash
# 1. Start daemon
open /Applications/Codo.app
# → bell icon in menubar
# → grant notification permission on first launch

# 2. Test CLI
codo "Hello Codo" "Installation verified"
# → macOS toast appears, exit code 0

# 3. Test error handling
codo
# → usage help, exit code 1
```

### Prerequisites

- **Bun** — `curl -fsSL https://bun.sh/install | bash`
- **Xcode Command Line Tools** — `xcode-select --install` (for `swift build`)

## Version Management

Swift: `Sources/CodoCore/CodoInfo.swift`:
```swift
public enum CodoInfo {
    public static let version = "0.1.0"
}
```

CLI: `cli/package.json` `version` field. Must match.

`Info.plist` `CFBundleShortVersionString` must also match.
