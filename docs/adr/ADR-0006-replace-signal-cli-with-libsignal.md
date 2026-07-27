# ADR-0006: Replace signal-cli with libsignal's Swift package

Status: accepted, implementation in progress
Date: 2026-07-26

## Context

Vela talks to Signal through an embedded, GraalVM-compiled `signal-cli` speaking
JSON-RPC over a Unix socket. That works, but it costs us:

- ~100 MB of embedded JVM-derived binary in the bundle, and three nested Mach-O
  objects that each have to be signed inside-out or Gatekeeper calls the app
  malware.
- A second process, its own SQLite account store, and a socket handshake that has
  to be kept alive and restarted.
- Whatever signal-cli chooses to expose. Per-reader group read receipts, for
  one, may simply not be reportable through it.
- Patched-in workarounds such as `-XX:-EnableSignalHandling` and the rewritten
  `Shutdown.installHandler`, which exist purely because a JVM is running inside
  an App Sandbox.

Replacing it was previously scoped as "months: libsignal from Rust, provisioning,
websocket transport, sealed sender, prekeys, groups and attachments". That
estimate is now wrong, and this ADR records why.

## Exploratory verification

Against `signalapp/libsignal` at v0.99.1 and `signalapp/Signal-iOS`, both cloned
for reference and **not** vendored into the tree:

- `swift/build_ffi.sh -d` builds `libsignal_ffi.a` on this machine. It needs the
  nightly toolchain the repo pins in `rust-toolchain`; the already-installed
  `nightly-aarch64-apple-darwin` is accepted via `RUSTUP_TOOLCHAIN`.
- `swift build` of the `LibSignalClient` package then compiles clean.

That experiment did **not** establish a shippable dependency. Vela's
authoritative Signal-iOS commit currently pins libsignal v0.97.3, while the
experiment used v0.99.1. Some objects in the prototype release archive also
declared macOS 26.2 even though Vela supports macOS 26.0. The prototype archive,
Swift wrapper and adapter were therefore removed rather than presented as a
compatible connector.

`LibSignalClient` turned out to cover far more than protocol crypto:

| Piece | Where it already exists |
|---|---|
| Double Ratchet, prekeys, Kyber | `Protocol.swift`, `Kem.swift` |
| Sealed sender | `SealedSender.swift` |
| Groups (zkgroup credentials) | `zkgroup/` |
| Contact discovery | `Cds2.swift`, `CdsTypes.swift` |
| **Authenticated websocket to the service** | `ChatConnection.swift` |
| **Device linking / provisioning** | `ProvisioningConnection.swift` |
| Store interfaces to implement | `DataStoreProtocols.swift` |

`AuthenticatedChatConnection.send(Request) -> Response` is the important one:
Signal's REST API rides over that socket, so libsignal owns transport, TLS
pinning, retry and proxying. We build requests and parse responses, and never
write network code.

## Decision

Replace signal-cli with `LibSignalClient` plus a thin Swift service layer, using
Signal-iOS as the reference for the parts libsignal does not own.

Scope that remains ours:

1. Build `libsignal_ffi.a` for arm64 in release and vendor it, with the Rust
   build reproducible from `Scripts/`.
2. Implement `IdentityKeyStore`, `SessionStore`, `PreKeyStore`,
   `SignedPreKeyStore`, `KyberPreKeyStore` and `SenderKeyStore` over the existing
   SQLCipher database.
3. Provisioning: drive `ProvisioningConnection`, following
   `Signal-iOS/Signal/Provisioning/` and `SignalServiceKit/Devices/`.
4. Envelope send and receive, sync messages, receipts and typing, from the
   `.proto` specifications in `SignalServiceKit/Protos/Specifications/`.
5. Attachments (CDN), profiles and avatars.
6. Groups v2 operations.

## Implementation status

As of 2026-07-26, the persistence foundation has landed, but no upstream bridge
has:

- `LibSignalRecordPersistence` defines synchronous load, atomic replace and
  atomic insert-if-absent operations with account, namespace and structured-key
  partitioning.
- `SQLiteLibSignalRecordPersistence` implements that contract in the existing
  SQLCipher database. Schema version 5 adds `libsignal_records`; account reset
  deletes those rows before WAL truncation and vacuum.

There is no vendored libsignal archive or Swift wrapper, no package target, and
no `IdentityKeyStore`, `SessionStore`, `PreKeyStore`, `SignedPreKeyStore`,
`KyberPreKeyStore` or `SenderKeyStore` conformance in the shipping tree. Future
work must start from the exact v0.97.3 pin recorded for the current Signal-iOS
commit, produce an arm64 archive whose every object supports macOS 26.0, and
then pass interoperability tests before Package wiring is enabled. Until then,
the native bridge stays fail-closed and signal-cli remains the live backend.

Signal-iOS and libsignal are both AGPL-3.0-only, which is Vela's licence, so
reading and adapting them is compatible. Attribution belongs in `NOTICE`.

## Blocked on this, until it lands

Two things users reasonably expect are not reachable through signal-cli 0.14.6,
and were verified against its full command list rather than assumed:

- **Read state from Vela to the phone.** Reading a conversation in Vela sends a
  read receipt to the sender (`sendReceipt`), but Signal clears your *own* other
  devices via a separate `SyncMessage.Read`, and no command emits one. The
  reverse direction works: `syncMessage.readMessages` arrives and Vela now acts
  on it, so Vela follows the phone but the phone does not follow Vela.
- **Message history backfill.** There is no history, import, backfill or transfer
  verb. Signal's "transfer message history when linking" is a provisioning-time
  exchange between the phone and the new device, not something a linked client
  can request afterwards — which is exactly why it becomes possible here:
  `ProvisioningConnection` puts the link-time handshake under our control.

## Consequences

- When the native connector is enabled, the bundle loses the JVM, the second
  process, the socket, and the signing gymnastics around nested Mach-O objects.
- That future connector adds a Rust toolchain as a build dependency. Final-link
  dead-stripped bundle impact remains unmeasured and must beat the current
  embedded backend.
- Sequencing: this lands after the UI work, and behind the existing client
  protocol so the two connectors can be swapped rather than forked.
- Until then signal-cli stays, and its limits stay with it.
