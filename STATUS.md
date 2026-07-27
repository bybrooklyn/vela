# Implementation Status

See [`docs/IMPLEMENTATION_MATRIX.md`](docs/IMPLEMENTATION_MATRIX.md) for the
feature-by-feature inventory and [`docs/verification/VERIFICATION_REPORT.md`](docs/verification/VERIFICATION_REPORT.md)
for the exact archive gate.

## Verified locally on macOS

| Area | Result |
|---|---|
| Swift package debug build | Pass |
| Swift 6 strict-concurrency compilation | Pass for portable modules |
| Debug test suite | Pass — 147 tests across 25 suites, 0 failures |
| Domain invariants and redaction | Pass |
| Development crypto misuse guards | Pass |
| In-memory storage tests | Pass |
| SQLite migration/round-trip tests | Pass |
| SQLCipher fail-closed policy | Pass against ordinary SQLite |
| Local-data deletion/plaintext cleanup | Pass |
| Persistent outbox completion and control envelopes | Pass |
| Retryable outbox retention and immediate manual retry | Pass |
| Failed optimistic-mutation rollback | Pass |
| Duplicate incoming-envelope and reaction suppression | Pass |
| Disappearing-message expiration cleanup | Pass |
| Read sync, timer updates, and reaction removal | Pass |
| Atomic contact snapshot replacement | Pass |
| Bounded attachment download and retry retention | Pass |
| Reset purge and recovery-state transitions | Pass |
| User-journey regression contracts | Pass — 6 focused scenarios |
| Development linked-device simulation | Pass |
| End-to-end send/receive pipeline | Pass |
| Retry after injected transport failure | Pass |
| Unavailable production bridge | Pass — fails closed |
| CLI demonstration | Pass |
| macOS Swift source parse | Pass |
| Swift formatting | Pass |
| Sensitive logging static check | Pass |
| Conditional-compilation budget | Pass |
| JSON/plist/YAML and repository hygiene | Pass |
| Source manifest | Pass — 204 files |
| Clean extracted source ZIP debug/release retest | Pass — 147 tests across 25 suites, 0 failures in each configuration |
| Source ZIP SHA-256 | Pass — recorded in the adjacent `build/vela-0.1.2-development-source.zip.sha256` sidecar (generated after this tree is verified) |

The AddressSanitizer and ThreadSanitizer suites are separate release gates and
were not rerun for this snapshot. Current results and environment boundaries
are in the verification report; historical 18-test counts do not describe this
tree.

## Requires a macOS environment

| Area | Status |
|---|---|
| Xcode-free app build | Pass locally; requires macOS 26 + current Command Line Tools to reproduce |
| Optional XcodeGen project generation | Project definition included; full Xcode path remains optional |
| SwiftUI/AppKit type checking | Source syntax parsed; requires macOS SDK for full type check |
| Native app launch/UI automation | Launch and UI automation remain manual; requires macOS 26+ |
| App Sandbox runtime | Requires signed or locally built macOS app |
| Local database key | Implemented in owner-only `0600` file; production Keychain/rekey design remains |
| Notification Center | Implemented; requires macOS runtime permission |
| Touch ID/password lock | Implemented; requires LocalAuthentication |
| Launch at login | Implemented; requires ServiceManagement runtime |
| Notarization | Script included; requires Apple credentials |

Per-conversation draft/staging behavior, onboarding QR scanning,
LocalAuthentication success/cancel paths, notification banners, VoiceOver, and
other visual behavior still require Mac runtime or human qualification. macOS
notification authorization is controlled by TCC; a denied bundle identifier
must be re-enabled in System Settings and cannot be re-prompted by the app.

## Live Signal service route

Vela can use an embedded signal-cli backend compiled ahead of time with GraalVM
native-image. Generated backend artifacts are local/vendor output and are not
included in this source tree. Results below are prior manual development
evidence unless marked otherwise; current automated verification does not use a
live account.

| Area | Result |
|---|---|
| Linked-device provisioning (QR) | Previously exercised manually against a real account |
| Contact and profile sync | Previously exercised manually; names and avatars reported |
| Group listing | Implemented; no current live-account evidence |
| Send and receive, 1:1 | Send previously exercised manually; current live receive evidence not recorded |
| Quotes, receipts, typing | Implemented; no current live-account evidence |
| Attachments | Implemented; no current live-account evidence |
| Local databases | Vela store uses SQLCipher/CommonCrypto; embedded signal-cli database remains unencrypted |

End-to-end encryption is performed by libsignal inside signal-cli. Vela applies
none of its own; its envelope type is a local container, and it reports
`EnvelopeProtection.signalCLIBridge` rather than claiming libsignal protection.

## Native Signal-iOS/libsignal route

| Area | Status |
|---|---|
| Official libsignal adapter | Fail-closed boundary included |
| Signal linked-device provisioning | Fail-closed boundary included |
| Signal service transport | Fail-closed boundary included |
| Signal recipient-device routing | Fail-closed boundary included |
| Attachments | Contract included; native-bridge transfer implementation pending |
| Initial history transfer | Contract included; implementation pending upstream bridge |
| RingRTC calls | Contract included; native port pending |
| Stories | Feature gate only |

The native libsignal bridge remains fail-closed. Live interoperability today
runs through the embedded signal-cli backend, not through that bridge. This is an
unofficial client and is not affiliated with or endorsed by Signal.
