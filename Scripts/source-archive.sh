#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-development}"
[[ "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    echo "Invalid archive version: $VERSION" >&2
    exit 1
}

DEFAULT_OUTPUT="$ROOT/build/vela-$VERSION-source.zip"
OUTPUT_INPUT="${2:-$DEFAULT_OUTPUT}"
OUTPUT="$(python3 - "$OUTPUT_INPUT" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
)"
CHECKSUM="$OUTPUT.sha256"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$CHECKSUM"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ARCHIVE_ROOT="vela-$VERSION-source"
DEST="$STAGING/$ARCHIVE_ROOT"
mkdir -p "$DEST"

# Verify the release inventory before copying it. Using the manifest as the
# allowlist prevents local caches, editor settings, credentials, or unreviewed
# files from leaking into a source release.
"$ROOT/Scripts/verify-source-manifest.sh" --source-tree "$ROOT"
python3 - "$ROOT" "$DEST" <<'PY'
import pathlib
import shutil
import stat
import sys

root = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
manifest = root / 'SOURCE_MANIFEST.sha256'
for line in manifest.read_text().splitlines():
    relative = line.split('  ', 1)[1]
    source = root / relative
    target = dest / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o755 if source.stat().st_mode & stat.S_IXUSR else 0o644)
shutil.copyfile(manifest, dest / manifest.name)
(dest / manifest.name).chmod(0o644)
PY

# Normalize mtimes so identical content produces stable ZIP bytes.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1784937600}"
python3 - "$DEST" "$SOURCE_DATE_EPOCH" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
epoch = int(sys.argv[2])
if not 315532800 <= epoch <= 4354819199:
    raise SystemExit('SOURCE_DATE_EPOCH must fit the ZIP timestamp range (1980-2107).')
for path in sorted(root.rglob('*'), reverse=True):
    os.utime(path, (epoch, epoch), follow_symlinks=False)
    if path.is_dir():
        path.chmod(0o755)
os.utime(root, (epoch, epoch), follow_symlinks=False)
root.chmod(0o755)
PY

(
    cd "$STAGING"
    TZ=UTC LC_ALL=C find "$ARCHIVE_ROOT" -print | TZ=UTC LC_ALL=C sort | TZ=UTC zip -X -q "$OUTPUT" -@
)

unzip -tq "$OUTPUT" >/dev/null
python3 - "$OUTPUT" "$CHECKSUM" <<'PY'
import hashlib
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
checksum = pathlib.Path(sys.argv[2])
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
checksum.write_text(f"{digest}  {archive.name}\n")
PY

printf '%s\n' "$OUTPUT"
printf '%s\n' "$CHECKSUM"
