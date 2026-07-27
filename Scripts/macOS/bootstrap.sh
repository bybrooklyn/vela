#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/Scripts/swift-toolchain.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo 'The native app requires macOS.' >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1 && ! command -v swiftly >/dev/null 2>&1; then
    cat >&2 <<'MSG'
Swift is missing. Install the standalone toolchain without Xcode:

  curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg
  installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
  ~/.swiftly/bin/swiftly init --quiet-shell-followup
  source "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/env.sh"
  swiftly install latest
MSG
    exit 1
fi

vela_select_swift
vela_prepare_swift_build "$ROOT"

if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 && \
   [[ ! -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]]; then
    echo 'Apple Command Line Tools are missing. Install the small package with:' >&2
    echo '  xcode-select --install' >&2
    echo 'Full Xcode is not required.' >&2
    exit 1
fi

printf 'Swift: %s\n' "$("$VELA_SWIFT_BIN" --version | head -n 1)"
printf 'SDK:   %s\n' "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"

cd "$ROOT"
"$VELA_SWIFT_BIN" build --scratch-path "$VELA_SCRATCH_PATH" -c debug
"$VELA_SWIFT_BIN" test --scratch-path "$VELA_SCRATCH_PATH" -c debug --no-parallel
SWIFT_BIN="$VELA_SWIFT_BIN" "$ROOT/Scripts/macOS/build.sh"

echo
printf 'Bootstrap complete. Launch with:\n  open %q\n' "$ROOT/build/Vela.app"
