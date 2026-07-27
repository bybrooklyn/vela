#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/Vendor/manifests/signal-ios.json"
REPO="${SIGNAL_IOS_REPO:-https://github.com/signalapp/Signal-iOS.git}"
DEFAULT_REF="$(python3 - "$MANIFEST" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text()).get("resolved_commit", "main") if path.exists() else "main")
PY
)"
REF="${SIGNAL_IOS_REF:-$DEFAULT_REF}"
DEST="$ROOT/Upstream/Signal-iOS"

if [[ -d "$DEST/.git" ]]; then
    git -C "$DEST" fetch --tags origin
else
    rm -rf "$DEST"
    git clone --recurse-submodules "$REPO" "$DEST"
fi

git -C "$DEST" checkout --detach "$REF"
git -C "$DEST" submodule update --init --recursive

COMMIT="$(git -C "$DEST" rev-parse HEAD)"
mkdir -p "$ROOT/Vendor/manifests"
python3 - "$MANIFEST" "$REPO" "$REF" "$COMMIT" "$DEST/Podfile" <<'PY'
import datetime
import json
import pathlib
import re
import sys

path, repo, ref, commit, podfile_path = sys.argv[1:]
podfile = pathlib.Path(podfile_path).read_text()

def capture(pattern: str):
    match = re.search(pattern, podfile)
    return match.group(1) if match else None

data = {
    "repository": repo,
    "requested_ref": ref,
    "resolved_commit": commit,
    "recorded_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "libsignal": {
        "tag": capture(r"pod 'LibSignalClient'.*?tag: '([^']+)'") ,
        "prebuild_checksum": capture(r"LIBSIGNAL_FFI_PREBUILD_CHECKSUM'\] = '([^']+)'")
    },
    "ringrtc": {
        "tag": capture(r"pod 'SignalRingRTC'.*?tag: '([^']+)'") ,
        "prebuild_checksum": capture(r"RINGRTC_PREBUILD_CHECKSUM'\] = '([^']+)'")
    },
    "sqlcipher": {
        "tag": capture(r"pod 'SQLCipher'.*?tag: '([^']+)'")
    },
    "swift_protobuf": capture(r"pod 'SwiftProtobuf', \"([^\"]+)\""),
    "source_included_in_this_checkout": True
}
pathlib.Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

echo "Vendored Signal-iOS at $COMMIT"
echo 'Next: run its documented dependency setup and implement VelaSignalBridge against this exact revision.'
