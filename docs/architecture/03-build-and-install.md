# 03 - Build and Install

> Build, bundle, and install procedures for both layers.

## Swift Daemon

### Build Modes

| Mode | Command | Output | Use For |
|------|---------|--------|---------|
| Debug | `swift build` | `.build/debug/Codo` | Tests, socket development |
| Release | `swift build -c release` | `.build/release/Codo` | Performance testing |
| **App Bundle** | `./scripts/build.sh` | `.build/Codo.app` | **Production install** |

Bare binary cannot show notifications (no bundleIdentifier). Production requires `.app` bundle.

### App Bundle Structure

```
Codo.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── Codo
│   └── Resources/
```

### Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.nocoo.codo</string>
    <key>CFBundleName</key>
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

### scripts/build.sh

```bash
swift build -c release
rm -rf .build/Codo.app
mkdir -p .build/Codo.app/Contents/{MacOS,Resources}
cp .build/release/Codo .build/Codo.app/Contents/MacOS/
cp Resources/Info.plist .build/Codo.app/Contents/
codesign --force --options runtime --sign "Apple Development" .build/Codo.app
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

### scripts/install.sh

```bash
#!/bin/bash
set -euo pipefail

# Build Swift daemon
./scripts/build.sh

# Install .app
cp -r .build/Codo.app /Applications/Codo.app

# Install CLI (symlink Bun script into PATH)
chmod +x cli/codo.ts
ln -sf "$(cd cli && pwd)/codo.ts" /usr/local/bin/codo
```

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
