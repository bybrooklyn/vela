#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/swift-toolchain.sh"
vela_select_swift
vela_prepare_swift_build "$ROOT"
cd "$ROOT"

printf '\n==> Swift version\n'
"$VELA_SWIFT_BIN" --version

printf '\n==> Swift package manifest\n'
"$VELA_SWIFT_BIN" package --scratch-path "$VELA_SCRATCH_PATH" dump-package >/dev/null

printf '\n==> Portable package build and tests\n'
# Serial: these tests start real threads, UNIX sockets and long-lived actor
# loops. Run concurrently they starve each other and time out, which is a
# property of the harness rather than of the code under test.
"$VELA_SWIFT_BIN" test --scratch-path "$VELA_SCRATCH_PATH" -c debug --no-parallel

printf '\n==> End-to-end development pipeline\n'
DEMO_OUTPUT="$("$VELA_SWIFT_BIN" run --scratch-path "$VELA_SCRATCH_PATH" vela-demo)"
printf '%s\n' "$DEMO_OUTPUT"
grep -Fqx 'Vela development pipeline verified' <<<"$DEMO_OUTPUT"
grep -Fqx '  messages: 2' <<<"$DEMO_OUTPUT"
grep -Fqx '  pending outbox: 0' <<<"$DEMO_OUTPUT"
grep -Fqx '  mutations: edit + reaction' <<<"$DEMO_OUTPUT"
grep -Fqx '  outbound envelopes: 3' <<<"$DEMO_OUTPUT"

if [[ "$(uname -s)" == "Darwin" ]]; then
    # A full compile of the app target. `swiftc -parse` only checks syntax, so it
    # accepts type errors and lets a broken app pass verification.
    printf '\n==> Compile macOS app target\n'
    "$VELA_SWIFT_BIN" build --scratch-path "$VELA_SCRATCH_PATH" -c debug --product VelaMacApp

    printf '\n==> Xcode-free app bundle\n'
    # Building replaces build/Vela.app, which would pull the executable and the
    # backend out from under a running instance. Skip rather than break someone
    # mid-test; the compile check above already covers the code.
    if pgrep -f 'build/Vela.app/Contents/MacOS/Vela' >/dev/null 2>&1; then
        echo 'Vela is running; skipping the bundle build.'
    else
        SWIFT_BIN="$VELA_SWIFT_BIN" ./Scripts/macOS/build.sh >/dev/null
        test -x build/Vela.app/Contents/MacOS/Vela
    fi

    # Not a SwiftPM target; it only builds inside the optional Xcode project.
    printf '\n==> Parse macOS app tests\n'
    while IFS= read -r -d '' source; do
        "$VELA_SWIFTC_BIN" -parse "$source"
    done < <(find MacClient/Tests -name '*.swift' -print0)
else
    printf '\n==> Parse macOS Swift sources (no macOS SDK; syntax only)\n'
    while IFS= read -r -d '' source; do
        "$VELA_SWIFTC_BIN" -parse "$source"
    done < <(find MacClient/Sources MacClient/Tests -name '*.swift' -print0)
fi

SWIFT_FORMAT_BIN="$(dirname "$VELA_SWIFT_BIN")/swift-format"
if [[ -x "$SWIFT_FORMAT_BIN" ]]; then
    printf '\n==> Swift formatting\n'
    "$SWIFT_FORMAT_BIN" lint --configuration .swift-format --strict --recursive Sources Tests MacClient/Sources MacClient/Tests
else
    printf '\n==> Swift formatting (skipped: selected toolchain has no swift-format)\n'
fi

printf '\n==> Shell syntax and executable bits\n'
while IFS= read -r -d '' script; do
    bash -n "$script"
    if [[ ! -x "$script" ]]; then
        echo "Script is not executable: $script" >&2
        exit 1
    fi
done < <(find Scripts -type f -name '*.sh' -print0)

printf '\n==> Configuration and asset files\n'
python3 - <<'PY'
import json
import pathlib
import plistlib
import struct

root = pathlib.Path('.')
# Vendor/Artifacts holds the gitignored signal-cli + JRE trees, like .build.
skip = {'.build', 'Artifacts'}
for path in root.rglob('*.json'):
    if not skip.intersection(path.parts):
        json.loads(path.read_text())

for path in [
    root / 'MacClient/Configuration/Info.plist',
    root / 'MacClient/Configuration/Vela.entitlements',
    root / 'MacClient/Resources/PrivacyInfo.xcprivacy',
]:
    with path.open('rb') as handle:
        plistlib.load(handle)

project = (root / 'MacClient/project.yml').read_text()
for required in [
    'name: VelaMac',
    'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon',
    'ENABLE_APP_SANDBOX: YES',
    'SWIFT_STRICT_CONCURRENCY: complete',
]:
    assert required in project, f'Missing XcodeGen setting: {required}'

iconset = root / 'MacClient/Resources/Assets.xcassets/AppIcon.appiconset'
contents = json.loads((iconset / 'Contents.json').read_text())
assert len(contents['images']) == 10, 'The macOS app icon must contain 10 renditions.'
for image in contents['images']:
    path = iconset / image['filename']
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'Invalid PNG: {path}'
    width, height = struct.unpack('>II', data[16:24])
    points = int(image['size'].split('x')[0])
    scale = int(image['scale'][0])
    expected = points * scale
    assert (width, height) == (expected, expected), f'Wrong icon dimensions: {path}'

assert (root / 'LICENSE').stat().st_size > 30_000, 'Full AGPL text is missing.'
assert (root / 'MacClient/Resources/Legal/AGPL-3.0.txt').read_bytes() == (root / 'LICENSE').read_bytes()
assert (root / 'MacClient/Resources/Legal/NOTICE.txt').read_bytes() == (root / 'NOTICE').read_bytes()
assert (root / 'VERSION').read_text().strip(), 'VERSION is empty.'
manifest = json.loads((root / 'BUILD_MANIFEST.json').read_text())
assert manifest['production_mode']['status'].startswith('fail-closed')
assert manifest['minimum_macos'] == '26.0'
PY

printf '\n==> Sensitive logging scan\n'
"$ROOT/Scripts/ci/check-sensitive-logging.sh"

printf '\n==> Conditional-compilation budget\n'
"$ROOT/Scripts/ci/check-conditional-compilation.sh"

printf '\n==> Repository hygiene\n'
if find . -path './.build' -prune -o -path './Vendor/Artifacts' -prune -o \
    -type f \( -name '*.pem' -o -name '*.p12' -o -name '*.mobileprovision' \) -print | grep -q .; then
    echo 'Signing material must not be committed.' >&2
    exit 1
fi
python3 - <<'PY'
import pathlib

root = pathlib.Path('.')
excluded = {'.build', 'build', 'Artifacts'}
needles = (b'BEGIN PRIVATE KEY', b'BEGIN RSA PRIVATE KEY',
           b'BEGIN EC PRIVATE KEY', b'BEGIN OPENSSH PRIVATE KEY')
for path in root.rglob('*'):
    if not path.is_file() or excluded.intersection(path.parts):
        continue
    if path.as_posix() == 'Scripts/verify.sh':
        continue
    data = path.read_bytes()
    if any(needle in data for needle in needles):
        raise SystemExit(f'Potential private key material is present: {path}')
PY

printf '\nVerification passed.\n'
