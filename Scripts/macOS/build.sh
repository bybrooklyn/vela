#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/Scripts/swift-toolchain.sh"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_NAME="Vela"
PRODUCT_NAME="VelaMacApp"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"
SWIFTPM_BUILD="$BUILD_ROOT/swiftpm"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
STAGE_BUNDLE="$BUILD_ROOT/.$APP_NAME.app.staging"

case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "CONFIGURATION must be 'debug' or 'release', got: $CONFIGURATION" >&2; exit 1 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The native Vela app can only be built on macOS." >&2
    exit 1
fi

# Keep the older script-local override working while sharing one selector with
# every other build path. VELA_SWIFT_BIN remains the documented authority.
if [[ -n "${SWIFT_BIN:-}" && -z "${VELA_SWIFT_BIN:-}" ]]; then
    VELA_SWIFT_BIN="$SWIFT_BIN"
fi
vela_select_swift
SWIFT_BIN="$VELA_SWIFT_BIN"

if command -v xcrun >/dev/null 2>&1; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
else
    SDKROOT=""
fi
if [[ -z "$SDKROOT" || ! -d "$SDKROOT" ]]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
        if [[ -d "$candidate" ]]; then
            SDKROOT="$candidate"
            break
        fi
    done
fi
if [[ -z "$SDKROOT" || ! -d "$SDKROOT" ]]; then
    echo "The macOS SDK is missing. Install Apple's small Command Line Tools package; full Xcode is not required." >&2
    echo "Run: xcode-select --install" >&2
    exit 1
fi

case "$(uname -m)" in
    arm64) TARGET_TRIPLE="arm64-apple-macosx${DEPLOYMENT_TARGET}" ;;
    x86_64) TARGET_TRIPLE="x86_64-apple-macosx${DEPLOYMENT_TARGET}" ;;
    *) echo "Unsupported Mac architecture: $(uname -m)" >&2; exit 1 ;;
esac

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    echo "VERSION must contain a semantic version, got: $VERSION" >&2
    exit 1
fi
BUILD_VERSION="${BUILD_VERSION:-2}"
if [[ ! "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
    echo "BUILD_VERSION must contain a positive integer, got: $BUILD_VERSION" >&2
    exit 1
fi

# Stage into a scratch bundle and swap it in only after every step succeeds, so a
# failed build leaves the previously working build/Vela.app untouched.
rm -rf "$STAGE_BUNDLE"
mkdir -p "$BUILD_ROOT"
trap 'rm -rf "$STAGE_BUNDLE"' EXIT
vela_prepare_swift_build "$ROOT" "$SWIFTPM_BUILD"

BUILD_ARGS=(
    --package-path "$ROOT"
    --configuration "$CONFIGURATION"
    --product "$PRODUCT_NAME"
    --scratch-path "$SWIFTPM_BUILD"
    --triple "$TARGET_TRIPLE"
    --sdk "$SDKROOT"
)

printf 'Building Vela with %s\n' "$($SWIFT_BIN --version | head -n 1)"
printf 'Using SDK: %s\n' "$SDKROOT"
"$SWIFT_BIN" build "${BUILD_ARGS[@]}"

BIN_PATH="$($SWIFT_BIN build \
    --package-path "$ROOT" \
    --configuration "$CONFIGURATION" \
    --scratch-path "$SWIFTPM_BUILD" \
    --triple "$TARGET_TRIPLE" \
    --sdk "$SDKROOT" \
    --show-bin-path)"
BINARY="$BIN_PATH/$PRODUCT_NAME"
if [[ ! -x "$BINARY" ]]; then
    echo "SwiftPM finished but the app executable was not found at: $BINARY" >&2
    exit 1
fi

CONTENTS="$STAGE_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES"
install -m 755 "$BINARY" "$MACOS/$APP_NAME"

# Embed the signal-cli backend when it has been vendored. Without it the app
# still builds and runs; it just has no live Signal backend to link against.
VENDORED_SIGNAL_CLI="$ROOT/Vendor/Artifacts/signal-cli"
EMBED_BACKEND=0
if [[ -x "$VENDORED_SIGNAL_CLI/signal-cli" ]]; then
    EMBED_BACKEND=1
    printf 'Embedding signal-cli backend\n'
    ditto "$VENDORED_SIGNAL_CLI" "$RESOURCES/signal-cli"
else
    printf 'No vendored backend found; building without a live Signal backend.\n'
    printf 'Run Scripts/macOS/vendor-signal-cli.sh to embed one.\n'
fi

cp "$ROOT/MacClient/Resources/PrivacyInfo.xcprivacy" "$RESOURCES/PrivacyInfo.xcprivacy"
cp "$ROOT/MacClient/Resources/Legal/NOTICE.txt" "$RESOURCES/NOTICE.txt"
cp "$ROOT/MacClient/Resources/Legal/AGPL-3.0.txt" "$RESOURCES/AGPL-3.0.txt"

ICON_FILE=""
if command -v iconutil >/dev/null 2>&1; then
    ICONSET="$BUILD_ROOT/Vela.iconset"
    ASSETS="$ROOT/MacClient/Resources/Assets.xcassets/AppIcon.appiconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    cp "$ASSETS/AppIcon-16x16.png" "$ICONSET/icon_16x16.png"
    cp "$ASSETS/AppIcon-16x16@2x.png" "$ICONSET/icon_16x16@2x.png"
    cp "$ASSETS/AppIcon-32x32.png" "$ICONSET/icon_32x32.png"
    cp "$ASSETS/AppIcon-32x32@2x.png" "$ICONSET/icon_32x32@2x.png"
    cp "$ASSETS/AppIcon-128x128.png" "$ICONSET/icon_128x128.png"
    cp "$ASSETS/AppIcon-128x128@2x.png" "$ICONSET/icon_128x128@2x.png"
    cp "$ASSETS/AppIcon-256x256.png" "$ICONSET/icon_256x256.png"
    cp "$ASSETS/AppIcon-256x256@2x.png" "$ICONSET/icon_256x256@2x.png"
    cp "$ASSETS/AppIcon-512x512.png" "$ICONSET/icon_512x512.png"
    cp "$ASSETS/AppIcon-512x512@2x.png" "$ICONSET/icon_512x512@2x.png"
    if iconutil -c icns "$ICONSET" -o "$RESOURCES/Vela.icns"; then
        ICON_FILE="Vela"
    fi
    rm -rf "$ICONSET"
fi

# Use the same plist as Xcode, replacing build-setting placeholders with the
# concrete values a hand-built bundle needs. One source prevents identity and
# process-lifecycle policy from drifting between build paths.
INFO_PLIST="$CONTENTS/Info.plist"
cp "$ROOT/MacClient/Configuration/Info.plist" "$INFO_PLIST"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -replace CFBundleIdentifier -string "works.deadsignal.vela" "$INFO_PLIST"
plutil -replace CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$INFO_PLIST"
plutil -replace LSMinimumSystemVersion -string "$DEPLOYMENT_TARGET" "$INFO_PLIST"
if [[ -n "$ICON_FILE" ]]; then
    plutil -insert CFBundleIconFile -string "$ICON_FILE" "$INFO_PLIST"
fi
plutil -lint "$INFO_PLIST"

# Ad-hoc signing is enough for a locally-built app. It does not require an Apple Developer account.
if command -v codesign >/dev/null 2>&1; then
    # Nested Mach-O binaries must be signed before the bundle that contains them,
    # or `codesign --verify --deep` rejects the result. The embedded JRE alone
    # carries dozens of dylibs.
    if (( EMBED_BACKEND )); then
        printf 'Signing embedded backend binaries\n'
        NESTED_COUNT=0
        while IFS= read -r -d '' candidate; do
            if file -b "$candidate" | grep -q 'Mach-O'; then
                codesign --force --sign - --timestamp=none "$candidate"
                NESTED_COUNT=$((NESTED_COUNT + 1))
            fi
        done < <(find "$RESOURCES/signal-cli" -type f \
            \( -name '*.dylib' -o -perm -u+x \) -print0)
        printf '  signed %d nested binaries\n' "$NESTED_COUNT"
    fi

    codesign --force --sign - --timestamp=none \
        --entitlements "$ROOT/MacClient/Configuration/Vela.entitlements" \
        "$STAGE_BUNDLE"
    codesign --verify --deep --strict "$STAGE_BUNDLE"
fi

# Fail the build rather than shipping a bundle whose backend cannot start.
if (( EMBED_BACKEND )); then
    printf 'Verifying embedded backend\n'
    EMBEDDED_VERSION="$("$RESOURCES/signal-cli/signal-cli" --version)"
    printf '  %s\n' "$EMBEDDED_VERSION"
fi

# Replacing the bundle underneath a running instance pulls the executable, the
# JRE and the backend out from under it mid-operation. Refuse instead, unless the
# caller explicitly opts in.
if pgrep -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    if [[ "${VELA_REPLACE_RUNNING_APP:-0}" == "1" ]]; then
        printf 'Replacing a running %s as requested.\n' "$APP_NAME"
        pkill -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" || true
        sleep 1
    else
        echo "$APP_NAME is running; refusing to replace it." >&2
        echo "Quit it first, or rerun with VELA_REPLACE_RUNNING_APP=1." >&2
        exit 1
    fi
fi

rm -rf "$APP_BUNDLE"
mv "$STAGE_BUNDLE" "$APP_BUNDLE"

printf '\nBuilt: %s (%s)\n' "$APP_BUNDLE" "$CONFIGURATION"
printf 'Run it with: open %q\n' "$APP_BUNDLE"
