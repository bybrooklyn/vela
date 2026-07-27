#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/swift-toolchain.sh"
vela_select_swift
vela_prepare_swift_build "$ROOT"
cd "$ROOT"

# LeakSanitizer can report allocations retained by Linux Swift test/runtime
# shutdown. Address instrumentation remains active; only that final leak sweep
# is disabled by default on Linux. An explicit ASAN_OPTIONS always wins.
if [[ "$(uname -s)" == "Linux" ]]; then
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" \
        "$VELA_SWIFT_BIN" test --scratch-path "$VELA_SCRATCH_PATH" --sanitize=address -c debug --no-parallel
else
    "$VELA_SWIFT_BIN" test --scratch-path "$VELA_SCRATCH_PATH" --sanitize=address -c debug --no-parallel
fi
"$VELA_SWIFT_BIN" test --scratch-path "$VELA_SCRATCH_PATH" --sanitize=thread -c debug --no-parallel
