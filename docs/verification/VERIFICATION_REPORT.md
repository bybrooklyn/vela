# Verification Report

**Snapshot:** `0.1.2-development`  
**Report date:** 2026-07-26  
**Verification platform:** macOS arm64  
**Selected Swift toolchain:** Swift 6.3.3 via Swiftly

## Completed checks

| Check | Result |
|---|---|
| Swift package manifest | Pass |
| Swift debug tests | Pass — 147 tests across 25 suites, 0 failures |
| End-to-end development demo | Pass |
| macOS application target compile | Pass |
| Xcode-free local app bundle | Pass in separate isolated build; current gate skipped replacement because Vela was running |
| macOS app-test syntax parse | Pass |
| Swift format strict lint | Pass |
| Shell syntax and executable-bit checks | Pass |
| JSON/plist/project/icon/legal validation | Pass |
| Sensitive logging scan | Pass |
| Portable-source conditional-compilation budget | Pass |
| Private-key/signing-material scan | Pass |
| Swift release build and tests | Pass — 147 tests across 25 suites, 0 failures |
| Source manifest | Pass — 204 files |
| Clean extracted source ZIP debug and release retest | Pass — 147 tests across 25 suites, 0 failures in each configuration |
| Source ZIP SHA-256 | Pass — recorded in the adjacent `build/vela-0.1.2-development-source.zip.sha256` sidecar (generated after this tree is verified) |

Commands:

```bash
./Scripts/verify.sh
./Scripts/verify-release.sh
./Scripts/verify-source-manifest.sh --source-tree .
./Scripts/verify-archive.sh build/vela-0.1.2-development-source.zip
```

Repository scripts selected Swiftly's active toolchain instead of `/usr/bin/swift`.
The gate detected `.build` artifacts produced by a different compiler and
cleaned them before compiling. Scripted checks now use an isolated
`.build/vela-selected` scratch path so raw builds cannot contaminate later steps.

## Test coverage represented by the suite

- Domain identifiers, relative-time behavior, message clustering, and redaction.
- Explicit opt-in and destination/version guards for development crypto.
- In-memory and SQLite/SQLCipher persistence, migration, deletion, wrong-key
  behavior, and generic Signal record storage.
- Version-3 privacy migration fixture validation and atomic rollback.
- Durable outbox retry, concurrency, mutation, direction, and read-sync behavior.
- Indefinite retryable-outbox retention, manual backoff bypass, permanent
  mutation rollback, and attachment retention.
- signal-cli JSON-RPC, provisioning, identity mapping, contacts, text styles,
  receipts, quotes, sync messages, and service transport.
- Atomic contact replacement, phone-sync wrapper decoding, expiry updates,
  reaction removal, and stale daemon/socket disconnect handling.
- Reset purge, startup recovery, and six focused user-journey regression
  contracts.
- Complete local provisioning/send/receive pipeline.
- Unavailable native Signal bridge failing closed.

## Verified development demonstration

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

This proves the local development pipeline, not live Signal interoperability.
Development crypto is intentionally plaintext and requires explicit insecure opt-in.

## Not established by these checks

- Apple Developer ID signing, notarization, Gatekeeper distribution, or App Store review.
- UI automation, accessibility qualification, or behavior on other Mac hardware.
- Direct automated UI coverage for per-conversation draft/attachment staging,
  Settings lock gating, onboarding QR scanning, and LocalAuthentication flows.
- Notification delivery under the current macOS TCC authorization state; a
  denied bundle identifier requires manual re-enabling in System Settings.
- Live Signal provisioning, messaging, groups, attachments, calls, or protocol compatibility.
- Rebuilding the optional signal-cli/GraalVM artifact from its upstream sources.
- Native Signal-iOS/libsignal bridge interoperability; that route remains fail-closed.

Prior manual development reported live provisioning and one-to-one send through
the embedded signal-cli route. That report was not rerun by this verification
gate and is not a production-readiness claim.
