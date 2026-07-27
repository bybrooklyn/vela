# Architecture Overview

```text
Mac SwiftUI/AppKit UI
        │
        ▼
AppModel (@MainActor)
        │
        ▼
VelaClient actor
 ├── ProvisioningCoordinator
 ├── MessageSender
 ├── OutboxProcessor
 ├── MessageReceiver
 ├── ClientEventHub
 └── DiagnosticsRecorder
        │
        ├──────── ClientStore ─────── SQLiteStore / InMemoryStore
        ├──────── CryptoEngine ────── LibSignalCryptoEngine / explicit dev codec
        ├──────── ServiceTransport ─ Signal bridge / loopback
        ├──────── Provisioning ───── Signal bridge / development simulator
        └──────── RecipientRouter ── Signal device stores / development route
```

## Boundary rule

The only module permitted to know unstable Signal-iOS/libsignal APIs is the
version-pinned implementation behind `VelaSignalBridge`. No view, app model,
storage module, or general application actor imports SignalServiceKit directly.

## Durable outbound path

```text
MessageDraft
→ validate
→ create ChatMessage(.queued)
→ create WireMessage
→ one local transaction: conversation + message + outbox
→ update UI
→ seal through CryptoEngine
→ submit through ServiceTransport
→ one local transaction: delete outbox + mark sent
```

A process crash between persistence and transmission leaves a retryable outbox
record. A crash after service acceptance but before local completion can cause a
retry, so the production service adapter must preserve upstream idempotency and
message identifiers.

## Idempotent inbound path

```text
EncryptedEnvelope
→ destination/protection validation
→ libsignal decrypt
→ wire decode and bounds checks
→ one local transaction:
   - reject already-seen envelope
   - upsert conversation
   - insert/update message
   - record envelope ID
→ publish ID-only UI event
→ privacy-safe notification
```

## UI rule

SwiftUI owns application composition and ordinary screens. AppKit is used where
macOS behavior matters more than cross-platform convenience. The current code
uses `NSTextView` for the composer; the timeline can later move to
`NSCollectionView` without changing core APIs.
