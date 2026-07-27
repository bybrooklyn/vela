# Handoff Guide

## 1. Verify the extracted archive

```bash
./Scripts/verify.sh
./Scripts/verify-release.sh
```

The package needs macOS 26+, Swift 6.1+, and a current macOS SDK. SQLCipher is
compiled from the included amalgamation with CommonCrypto. The archive contains
no generated `.build` directory, embedded signal-cli/GraalVM output, or signing
material. The active verification baseline is 147 tests across 25 suites,
including generic Signal record persistence, pre-v4 privacy migration, and
user-journey regression coverage.

## 2. Run the native development app

The primary build path needs macOS 26+, Apple Command Line Tools, Swift 6.1+,
and `just`; full Xcode is not required:

```bash
just bootstrap
just run
```

If an embedded signal-cli backend is present, the app uses that live-service
route. A source-only checkout does not include the generated backend artifact;
Debug then falls back to the labeled local provisioning simulator, loopback
transport, plaintext test codec, and development database.

The optional Xcode path needs Xcode 26+ and XcodeGen:

```bash
just project
open MacClient/VelaMac.xcodeproj
```

## 3. Install the code into a direct Signal-iOS fork

```bash
SIGNAL_IOS_FORK='git@github.com:YOUR_ACCOUNT/Signal-iOS.git' \
  ./Scripts/bootstrap-direct-fork.sh ../Vela-Signal-iOS
```

The installer checks out the exact baseline recorded in
`Vendor/manifests/signal-ios.json`, preserves the original Signal-iOS README,
and copies the Vela overlay without rewriting upstream iOS targets.

## 4. Implement the production bridge in this order

1. Build the manifest-pinned libsignal v0.97.3 Swift/Rust artifact for macOS.
2. Port or adapt SignalServiceKit storage and migrations.
3. Adapt the upstream linked-device provisioning coordinator.
4. Wrap authenticated receive/send transport.
5. Map official decrypted content into the stable Vela domain model.
6. Replace development recipient routing with upstream multi-device fan-out.
7. Run the iOS/Android/Mac interoperability matrix.
8. Add attachment and initial-history transfer adapters.
9. Port RingRTC only after messaging and migration safety are stable.

Detailed contracts and exit tests are in `docs/porting/SIGNAL_BRIDGE.md`.

## 5. Production release gate

Do not remove the fail-closed production bridge merely to get a green build.
A release is allowed only after:

- SQLCipher is truly linked and `PRAGMA cipher_version` succeeds.
- The database key is moved from the adjacent owner-only container file into a
  production-grade Keychain design backed by a stable signing identity.
- Any embedded signal-cli database is encrypted at rest or the signal-cli route
  is excluded from the release.
- Official libsignal test vectors pass on macOS.
- Real provisioning survives restart and relinking.
- Official iOS and Android clients exchange messages in both directions.
- Database migration fixtures pass from every shipped version.
- No message body, recipient identifier, key material, or decrypted envelope is
  present in logs or exported diagnostics.
- The app is signed, notarized, and its matching AGPL source is published.
