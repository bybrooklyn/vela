#!/usr/bin/env bash
set -euo pipefail

MODE="verify"
if [[ "${1:-}" == "--source-tree" || "${1:-}" == "--write" ]]; then
    MODE="${1#--}"
    shift
fi

ROOT_INPUT="${1:-.}"
ROOT="$(cd "$ROOT_INPUT" && pwd)"
MANIFEST="$ROOT/SOURCE_MANIFEST.sha256"
if [[ "$MODE" != "write" && ! -f "$MANIFEST" ]]; then
    echo "Missing source manifest: $MANIFEST" >&2
    exit 1
fi

python3 - "$MODE" "$ROOT" "$MANIFEST" <<'PY'
import hashlib
import pathlib
import re
import sys

mode = sys.argv[1]
root = pathlib.Path(sys.argv[2]).resolve()
manifest = pathlib.Path(sys.argv[3])

def excluded_source_path(path: pathlib.Path) -> bool:
    relative = path.relative_to(root)
    parts = relative.parts
    if {'.git', '.build', '.swiftpm', 'build', '.claude', 'DerivedData',
        'xcuserdata'}.intersection(parts):
        return True
    if len(parts) >= 2 and parts[:2] == ('Vendor', 'Artifacts'):
        return True
    if any(part.endswith(('.xcodeproj', '.xcworkspace', '.xcarchive')) for part in parts):
        return True
    if path.name in {'.DS_Store', 'Package.resolved', '.env'}:
        return True
    if path.name.startswith('.env.') and path.name != '.env.example':
        return True
    if path.suffix.lower() in {'.pem', '.p12', '.cer', '.mobileprovision',
                              '.provisionprofile', '.sqlite', '.sqlite-shm',
                              '.sqlite-wal', '.dmg'}:
        return True
    return False

def source_file(path: pathlib.Path) -> bool:
    return path.is_file() and path.name != manifest.name and not excluded_source_path(path)

def actual_files(source_tree: bool) -> dict[str, pathlib.Path]:
    result = {}
    for path in root.rglob('*'):
        if path.is_symlink():
            if not source_tree or not excluded_source_path(path):
                raise SystemExit(f'Source symlinks are not supported: {path.relative_to(root)}')
            continue
        if path.is_file() and path.name != manifest.name and (not source_tree or source_file(path)):
            result[path.relative_to(root).as_posix()] = path
    return result

if mode == 'write':
    actual = actual_files(source_tree=True)
    lines = [f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}'
             for relative, path in sorted(actual.items())]
    manifest.write_text('\n'.join(lines) + '\n')
    print(f'Source manifest wrote: {len(actual)} files')
    raise SystemExit

expected = {}
pattern = re.compile(r'^([0-9a-f]{64})  (.+)$')
for line_number, line in enumerate(manifest.read_text().splitlines(), 1):
    match = pattern.fullmatch(line)
    if not match:
        raise SystemExit(f'Malformed manifest line {line_number}')
    digest, relative_text = match.groups()
    relative = pathlib.PurePosixPath(relative_text)
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit(f'Unsafe manifest path: {relative_text}')
    if relative_text in expected:
        raise SystemExit(f'Duplicate manifest path: {relative_text}')
    expected[relative_text] = digest

actual = actual_files(source_tree=(mode == 'source-tree'))
missing = sorted(set(expected) - set(actual))
unlisted = sorted(set(actual) - set(expected))
if missing:
    raise SystemExit('Missing files: ' + ', '.join(missing[:10]))
if unlisted:
    raise SystemExit('Unlisted files: ' + ', '.join(unlisted[:10]))

for relative_text, digest in expected.items():
    computed = hashlib.sha256(actual[relative_text].read_bytes()).hexdigest()
    if computed != digest:
        raise SystemExit(f'Checksum mismatch: {relative_text}')

print(f'Source manifest verified: {len(expected)} files')
PY
