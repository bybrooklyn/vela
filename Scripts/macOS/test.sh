#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/Scripts/macOS/generate-project.sh"

xcodebuild \
  -project "$ROOT/MacClient/VelaMac.xcodeproj" \
  -scheme Vela \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
