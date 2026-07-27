# Implementing the Signal Upstream Bridge

The production bridge conforms to `SignalUpstreamBridge`, which combines:

- `LibSignalClientAdapter`
- `ServiceTransport`
- `ProvisioningTransport`

It should live in a target that can import the exact vendored SignalServiceKit and
LibSignalClient builds selected by the current Signal-iOS commit.

## Required work

### 1. Manifest

Generate a `SignalBridgeManifest` containing:

- Signal-iOS Git commit.
- libsignal version/commit.
- RingRTC version/commit.
- database schema version.
- build timestamp.

The application should expose this in diagnostics and release metadata.

### 2. Provisioning

Adapt the upstream linked-device provisioning coordinator rather than recreating
its protocol. Map upstream state into `ProvisioningEvent`. Persist only after the
upstream coordinator has produced a complete, valid linked-device payload.

### 3. Crypto

Implement `LibSignalClientAdapter` by delegating to upstream stores and official
libsignal types. Do not expose libsignal session records or private keys to UI or
generic transport code. Preserve upstream locking and transaction requirements.

### 4. Service transport

Wrap the upstream authenticated receive connection and message submission APIs.
Map service frames to `EncryptedEnvelope` without logging payloads. Preserve
acknowledgement timing: do not acknowledge an envelope before the application has
reached the same durable point as upstream.

### 5. Recipient routing

Replace `DevelopmentRecipientRouter` with upstream recipient/device lookup and
fan-out. A direct recipient can have multiple devices. Groups require sender-key
and group-state behavior from upstream; selecting one arbitrary member is never
valid in production.

### 6. Storage

The portable SQLite store exists for testability and UI development. The preferred
production integration is an adapter over SignalServiceKit's exact GRDB/SQLCipher
storage model and migrations. Do not translate every upstream row into a second
parallel database unless there is a documented, tested reason.

## Exit test

A clean Mac must:

1. Generate a real linked-device QR code.
2. Be approved by an official phone.
3. Restart without relinking.
4. Receive/decrypt/persist/display a text from official iOS and Android.
5. Send a text received by official iOS and Android.
6. Recover after sleep, network switch, and process termination.
7. Deduplicate replayed envelopes.
8. Merge the next upstream Signal-iOS release without data loss.
