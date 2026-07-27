# Xcode-free macOS build

Vela can be built and launched without installing full Xcode.

## Requirements

- macOS 26 or newer
- Apple Command Line Tools (`xcode-select --install`)
- Swift 6.1 or newer, preferably installed with Swiftly
- `just`

The Command Line Tools provide the macOS SDK. The standalone Swift toolchain provides the compiler and Swift Testing.

Scripts use `VELA_SWIFT_BIN` when explicitly set. Otherwise they prefer
Swiftly's selected toolchain and fall back to `swift` from `PATH`. Example:

```bash
VELA_SWIFT_BIN=/path/to/toolchain/usr/bin/swift just build
```

Verification scripts use `.build/vela-selected` and clean that isolated scratch
directory when compiler identity or package graph changes. Raw `swift` commands
keep using SwiftPM's default `.build` location and cannot contaminate scripted
checks. The app bundler uses its separate `build/swiftpm` scratch directory.

## Build and run

```bash
just build
just run
```

`just build` creates:

```text
build/Vela.app
```

The script packages the SwiftPM executable into a standard application bundle,
copies legal/privacy resources, creates the icon, and ad-hoc signs the app for
local use. An Apple Developer account is not required for this local build.
Distribution and notarization still require Apple credentials.

## First launch

This source release runs in local development mode. It does not connect to the live Signal service. Complete the simulated linking screen, create a conversation, and use the simulated incoming-reply control.

## Optional Xcode route

Contributors with Xcode can still run:

```bash
just project
just build-xcode
just test-xcode
```
