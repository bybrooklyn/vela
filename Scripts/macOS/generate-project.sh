#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/MacClient"

command -v xcodegen >/dev/null 2>&1 || {
    echo 'XcodeGen is required.' >&2
    exit 1
}

xcodegen generate --spec project.yml
xcodebuild -project VelaMac.xcodeproj -list
