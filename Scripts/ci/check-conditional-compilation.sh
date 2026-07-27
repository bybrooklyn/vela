#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Platform checks are expected in MacClient and platform boundaries, but should
# not spread through portable business logic.
COUNT=$( { grep -RhoE '#if (os\(macOS\)|canImport\(AppKit\))' Sources --include='*.swift' || true; } | wc -l | tr -d ' ' )
BUDGET=0
if (( COUNT > BUDGET )); then
    echo "Portable Sources contain $COUNT macOS conditional(s); budget is $BUDGET." >&2
    exit 1
fi

echo "Conditional-compilation budget passed ($COUNT/$BUDGET)."
