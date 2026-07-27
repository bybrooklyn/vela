#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:?Usage: SIGNAL_IOS_FORK=git@github.com:you/Signal-iOS.git bootstrap-direct-fork.sh /path/to/destination}"
: "${SIGNAL_IOS_FORK:?Set SIGNAL_IOS_FORK to your direct Signal-iOS fork URL}"
MANIFEST="$ROOT/Vendor/manifests/signal-ios.json"
BASELINE="${SIGNAL_IOS_REF:-$(python3 - "$MANIFEST" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text())["resolved_commit"])
PY
)}"
BRANCH="${VELA_BRANCH:-vela-macos}"

if [[ -e "$DEST" ]]; then
    echo "Destination already exists: $DEST" >&2
    exit 1
fi

git clone --recurse-submodules "$SIGNAL_IOS_FORK" "$DEST"
if ! git -C "$DEST" remote get-url upstream >/dev/null 2>&1; then
    git -C "$DEST" remote add upstream https://github.com/signalapp/Signal-iOS.git
fi

git -C "$DEST" fetch upstream --tags
git -C "$DEST" checkout -b "$BRANCH" "$BASELINE"
git -C "$DEST" submodule update --init --recursive

mkdir -p "$DEST/docs/upstream"
if [[ -f "$DEST/README.md" ]]; then
    cp "$DEST/README.md" "$DEST/docs/upstream/Signal-iOS-README.md"
fi

for path in Package.swift Sources Tests MacClient docs Scripts Vendor .github README.md STATUS.md SECURITY.md CONTRIBUTING.md NOTICE UPSTREAM.md LICENSE CHANGELOG.md BUILD_MANIFEST.json SOURCE_MANIFEST.sha256 VERSION justfile .gitignore .editorconfig .swift-format .swiftformat; do
    if [[ -e "$ROOT/$path" ]]; then
        parent="$DEST/$(dirname "$path")"
        mkdir -p "$parent"
        rsync -a "$ROOT/$path" "$parent/"
    fi
done

mkdir -p "$DEST/Vendor/manifests"
printf '%s\n' "$BASELINE" > "$DEST/Vendor/manifests/signal-ios-baseline-commit.txt"

cat <<MSG
Vela overlay installed into direct fork at $DEST
Branch: $BRANCH
Signal-iOS baseline: $BASELINE

Next commands:
  cd "$DEST"
  make dependencies
  ./Scripts/verify.sh
  ./Scripts/macOS/bootstrap.sh
MSG
