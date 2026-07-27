#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# This is intentionally conservative. Add narrowly reviewed exclusions rather
# than weakening the patterns globally.
PATTERN='(print|debugPrint|NSLog|os_log|Logger\.)\([^\n]*(message\.content|plaintext|ciphertext|identityHandle|serviceIdentifier|recipientID|attachment.*fileName)'

if command -v rg >/dev/null 2>&1; then
    if rg -n --glob '*.swift' --glob '!Sources/VelaDemo/**' "$PATTERN" Sources MacClient/Sources; then
        echo 'Potential sensitive logging found.' >&2
        exit 1
    fi
else
    if grep -RInE --include='*.swift' "$PATTERN" Sources MacClient/Sources --exclude-dir=VelaDemo; then
        echo 'Potential sensitive logging found.' >&2
        exit 1
    fi
fi

echo 'Sensitive logging scan passed.'
