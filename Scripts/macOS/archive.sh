#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/Vela.xcarchive}"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple Developer team ID}"

"$ROOT/Scripts/macOS/generate-project.sh"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project "$ROOT/MacClient/VelaMac.xcodeproj" \
  -scheme Vela \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  archive

echo "Archive created at $ARCHIVE_PATH"
