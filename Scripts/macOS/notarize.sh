#!/usr/bin/env bash
set -euo pipefail

ARTIFACT="${1:?Usage: notarize.sh /path/to/Vela.dmg}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE created with xcrun notarytool store-credentials}"

xcrun notarytool submit "$ARTIFACT" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
spctl --assess --type open --context context:primary-signature --verbose=4 "$ARTIFACT"
