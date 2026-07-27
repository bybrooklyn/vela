#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_INPUT="${1:?Usage: verify-archive.sh /path/to/source.zip}"
ARCHIVE="$(python3 - "$ARCHIVE_INPUT" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
)"
[[ -f "$ARCHIVE" ]] || {
    echo "Archive does not exist: $ARCHIVE" >&2
    exit 1
}

CHECKSUM="$ARCHIVE.sha256"
if [[ -f "$CHECKSUM" ]]; then
    python3 - "$ARCHIVE" "$CHECKSUM" <<'PY'
import hashlib
import pathlib
import re
import sys

archive = pathlib.Path(sys.argv[1])
checksum = pathlib.Path(sys.argv[2])
match = re.fullmatch(r'([0-9a-f]{64})  ([^/\n]+)\n?', checksum.read_text())
if not match or match.group(2) != archive.name:
    raise SystemExit(f'Malformed checksum sidecar: {checksum}')
actual = hashlib.sha256(archive.read_bytes()).hexdigest()
if actual != match.group(1):
    raise SystemExit(f'Archive checksum mismatch: {archive}')
print('Archive checksum verified')
PY
fi

# Reject ambiguous or unsafe members before any extraction. Source archives
# contain regular files and directories only: no absolute paths, traversal,
# duplicate names, backslash aliases, or symlinks.
ARCHIVE_ROOT="$(python3 - "$ARCHIVE" <<'PY'
import pathlib
import stat
import sys
import unicodedata
import zipfile

archive = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(archive) as handle:
    names = []
    seen = set()
    portable_seen = set()
    roots = set()
    for info in handle.infolist():
        name = info.filename
        path = pathlib.PurePosixPath(name)
        raw_parts = name.rstrip('/').split('/')
        if (not name or '\\' in name or path.is_absolute() or
                any(part in {'', '.', '..'} for part in raw_parts)):
            raise SystemExit(f'Unsafe archive member: {name!r}')
        normalized = path.as_posix().rstrip('/')
        if normalized in seen:
            raise SystemExit(f'Duplicate archive member: {name}')
        seen.add(normalized)
        portable = unicodedata.normalize('NFC', normalized).casefold()
        if portable in portable_seen:
            raise SystemExit(f'Archive has a case/Unicode-colliding member: {name}')
        portable_seen.add(portable)
        if not path.parts:
            raise SystemExit(f'Invalid archive member: {name!r}')
        roots.add(path.parts[0])
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise SystemExit(f'Archive symlink is not allowed: {name}')
        kind = stat.S_IFMT(mode)
        if kind and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise SystemExit(f'Archive member is not a regular file or directory: {name}')
        names.append(name)
    if len(roots) != 1:
        raise SystemExit('Archive must contain exactly one top-level directory.')
    root = next(iter(roots))
    if root in {'', '.', '..'}:
        raise SystemExit('Archive has an invalid top-level directory.')
    print(root)
PY
)"

unzip -tq "$ARCHIVE" >/dev/null
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
unzip -q "$ARCHIVE" -d "$TEMP"
ROOT="$TEMP/$ARCHIVE_ROOT"
[[ -d "$ROOT" ]] || {
    echo "Archive root is not a directory: $ARCHIVE_ROOT" >&2
    exit 1
}

"$ROOT/Scripts/verify-source-manifest.sh" "$ROOT"

if find "$ROOT" -type d \( -name .git -o -name .build -o -name build -o -name '*.xcodeproj' \) -print | grep -q .; then
    echo 'Archive contains generated or repository-private directories.' >&2
    exit 1
fi
if find "$ROOT" -type f \( -name '*.pem' -o -name '*.p12' -o -name '*.mobileprovision' \) -print | grep -q .; then
    echo 'Archive contains signing material.' >&2
    exit 1
fi

(
    cd "$ROOT"
    ./Scripts/verify.sh
    ./Scripts/verify-release.sh
)

echo "Archive verification passed: $ARCHIVE"
