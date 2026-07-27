#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/swift-toolchain.sh"
vela_select_swift
vela_prepare_swift_build "$ROOT"
cd "$ROOT"

"$VELA_SWIFT_BIN" build --scratch-path "$VELA_SCRATCH_PATH" -c release
"$VELA_SWIFT_BIN" test --scratch-path "$VELA_SCRATCH_PATH" -c release --no-parallel
