#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/Scripts/swift-toolchain.sh"
vela_select_swift
SWIFT_BIN="$VELA_SWIFT_BIN" "$ROOT/Scripts/macOS/build.sh"
open "$ROOT/build/Vela.app"
