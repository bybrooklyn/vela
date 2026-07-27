# Vela

Vela is an **unofficial native macOS linked-device client architecture** written in Swift. It is designed to be installed into a direct fork of Signal-iOS, with the unstable SignalServiceKit/libsignal/service APIs isolated behind `VelaSignalBridge`.

This is a development repository, not an official Signal distribution. The
source tree contains synthetic fixtures only; generated build output, vendored
native artifacts, local databases, logs, credentials, and editor/agent state
are intentionally excluded by `.gitignore`.

> **Current status:** the local development path works end to end. A separately
> vendored signal-cli backend provides the current live-service route; its
> generated binary is not included in the source archive. The native
> Signal-iOS/libsignal bridge remains deliberately fail-closed. This repository
> does not fake Signal Protocol or send development plaintext to Signal services.

Vela is not affiliated with or endorsed by Signal Technology Foundation. “Signal” is used only to describe compatibility targets and upstream source integration.

## What is included

- Swift 6 domain, storage, transport, cryptography-boundary, and application-core modules.
- Actor-isolated message pipeline.
- Durable SQLite database with a SQLCipher-required release mode.
- Crash-resistant outbox state and bounded exponential retry.
- Indefinite retention of retryable sends, immediate user-requested retry, and
  optimistic-mutation rollback after permanent failure.
- Idempotent incoming-envelope ledger.
- Linked-device provisioning state machine and development simulator.
- Fail-closed native `libsignal` adapter boundary; the future bridge must match
  the manifest-pinned v0.97.3 API.
- Version-pinned Signal service/provisioning bridge boundary.
- Native SwiftUI macOS shell.
- AppKit `NSTextView` composer where Return sends and Shift-Return or
  Option-Return inserts a newline.
- Conversation sidebar, search, timeline, unread state, pin/archive operations, replies, edits, reactions, delete controls, and diagnostics.
- Per-conversation drafts and attachment staging, stale-timeline loading guards,
  read/expiry synchronization, and reaction removal.
- Notification Center integration with privacy-safe generic notification text.
- SQLCipher database key generated with `SecRandomCopyBytes` and stored in an
  owner-only app-container file, with legacy Keychain-key migration.
- Minimal App Sandbox entitlements, Touch ID/password app lock, sleep locking, and launch at login.
- Feature contracts for attachments, history transfer, and RingRTC calls.
- XcodeGen project definition, native app icon, privacy manifest, bundled legal notices, CI, release scripts, security documentation, ADRs, and upstream-porting ledger.
- SwiftPM core tests and an end-to-end CLI demonstration.
- A detailed implementation matrix, handoff guide, and verification report.

## What is intentionally not claimed

This archive is **not yet a production-compatible Signal client**. Live compatibility requires code from a pinned Signal-iOS fork and its exact `libsignal`, SignalServiceKit, protobuf, database, and service implementations. Those APIs change and cannot be responsibly guessed from a blank repository.

The following production bridges currently fail closed:

- Real QR provisioning with a primary Signal phone.
- Authenticated Signal service WebSocket/REST transport.
- Official libsignal session and identity-store operations.
- Recipient-device fan-out and group-send resolution.
- Signal attachment encryption/upload/download.
- Initial linked-device history transfer.
- Native RingRTC calls.

The local development build is plainly labeled and uses `DevelopmentPlaintextCryptoEngine`, which performs **no encryption whatsoever**. It exists only to exercise the application pipeline without pretending to be Signal Protocol.

## Quick verification

Requirements:

- macOS 26 or newer with a current macOS SDK.
- Swift 6.1 or newer.

SQLCipher is compiled from its included amalgamation with CommonCrypto; no
Homebrew SQLite package is used.

```bash
./Scripts/verify.sh
```

Or run the steps directly:

```bash
swift test
swift run vela-demo
```

The current suite contains **147 active tests across 25 suites** covering domain invariants,
crypto-boundary misuse, SQLite/SQLCipher durability and deletion, outbox retry
and concurrency, signal-cli translation/transport, end-to-end local messaging,
generic Signal record persistence, pre-v4 privacy migration, contact snapshot
replacement, reset/recovery, user-journey regressions, and fail-closed
native-bridge behavior.

Expected demo output includes:

```text
Vela development pipeline verified
  state: ready
  conversations: 1
  messages: 2
  pending outbox: 0
  seen envelopes: 1
  mutations: edit + reaction
  outbound envelopes: 3
```

## Run the native macOS application without Xcode

Requirements:

- macOS 26 or newer.
- Apple Command Line Tools (`xcode-select --install`).
- Swift 6.1 or newer, preferably installed with Swiftly.
- `just`.

Full Xcode and XcodeGen are **not required**.

Repository scripts use `VELA_SWIFT_BIN` when set, otherwise Swiftly's selected
toolchain when available, then `swift` from `PATH`. They clean stale SwiftPM
artifacts when the selected compiler changes and use an isolated
`.build/vela-selected` scratch path. If running raw `swift` commands instead,
run `swift package clean` after changing compilers.

```bash
just bootstrap
just run
```

Or build and open it separately:

```bash
just build
open build/Vela.app
```

The app starts in an explicitly marked local-development mode:

1. Enter a Mac device name.
2. Generate the development QR code.
3. Press **Complete local link**.
4. Create a direct, group, or Note to Self conversation.
5. Send a message.
6. Use **Simulate Incoming Reply** to exercise the complete receive pipeline.

## Turn it into a direct Signal-iOS fork

The recommended end state is a direct Signal-iOS fork preserving upstream history. This archive is an overlay because the build environment used to generate it could not clone GitHub repositories.

```bash
SIGNAL_IOS_FORK='git@github.com:YOUR_ACCOUNT/Signal-iOS.git' \
  ./Scripts/bootstrap-direct-fork.sh ../Vela-Signal-iOS
```

That script:

1. Clones your fork with submodules.
2. Adds `signalapp/Signal-iOS` as `upstream`.
3. Copies the Vela modules, Mac client, tests, docs, and scripts into the fork root.
4. Records the exact upstream commit.
5. Leaves upstream iOS targets untouched.

Then implement the version-pinned bridge described in [`docs/porting/SIGNAL_BRIDGE.md`](docs/porting/SIGNAL_BRIDGE.md).

## Repository layout

```text
Sources/
  VelaDomain/          Stable value types and state machines
  VelaCrypto/          Crypto boundary; dev codec and libsignal adapter
  VelaStorage/         SQLite/SQLCipher-aware persistence and in-memory tests
  VelaTransport/       Service/provisioning contracts and loopback transport
  VelaCore/            Client actor, receiver, sender, outbox, feature contracts
  VelaSignalBridge/    Fail-closed upstream integration boundary
  VelaDemo/            End-to-end command-line verification

MacClient/
  Sources/App/         Composition root and observable app model
  Sources/Platform/    Local key management, notifications, app lock, login item, sleep/wake
  Sources/UI/          Native macOS interface
  Configuration/       Info.plist and sandbox entitlements
  project.yml          XcodeGen project definition

Tests/                 Domain, storage, and end-to-end core tests
docs/                  Architecture, threat model, ADRs, porting, releases
Scripts/               Verification, upstream bootstrap, build, and release tools
Upstream/               Placeholder or vendored Signal-iOS fork
```

## Security posture

- Production cryptography must use official `libsignal`; there is no home-grown Signal cryptography here.
- Release builds request SQLCipher and fail if ordinary SQLite is linked.
- The database key is generated with `SecRandomCopyBytes` and stored in an
  owner-only `0600` file beside the database. This does not protect against an
  attacker who can read the whole app container; see `SECURITY.md`.
- Incoming envelopes are validated, deduplicated, and committed before UI notification.
- Outgoing messages are durable before transmission.
- Retryable sends remain durable across repeated failures; reconnect-driven
  manual retry bypasses the existing backoff delay.
- Diagnostic events contain categories and counts, not message content or recipient identifiers.
- The app does not submit message contents to Spotlight.
- The application uses App Sandbox and Hardened Runtime settings.
- Update signing/notarization scripts are present, but signing credentials are never embedded.

Read [`SECURITY.md`](SECURITY.md) and [`docs/security/THREAT_MODEL.md`](docs/security/THREAT_MODEL.md) before enabling live service traffic. The precise feature state is recorded in [`docs/IMPLEMENTATION_MATRIX.md`](docs/IMPLEMENTATION_MATRIX.md), and [`docs/HANDOFF.md`](docs/HANDOFF.md) gives the direct-fork integration sequence.

## Verification record

The machine handoff includes [`docs/verification/VERIFICATION_REPORT.md`](docs/verification/VERIFICATION_REPORT.md)
and [`BUILD_MANIFEST.json`](BUILD_MANIFEST.json). They separate current local
macOS checks from work requiring full Xcode, live Signal accounts, upstream
artifact rebuilds, or Apple distribution credentials.

## License

AGPL-3.0-only. A distributed modified binary must be accompanied by corresponding source and practical build instructions. Preserve upstream notices when this code is installed into Signal-iOS.
