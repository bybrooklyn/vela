# Threat Model

## Assets

- Linked-device credentials.
- libsignal identity/session/sender-key state.
- Database key.
- Message and attachment plaintext while the app is unlocked.
- Encrypted local database and attachments.
- Update signing private key.
- Release signing identity.

## Adversaries

| Adversary | Representative risk | Primary controls |
|---|---|---|
| Casual local user | Reads chats on unlocked Mac | App lock, sleep lock, notification privacy |
| Stolen powered-off Mac | Copies local files | FileVault expectation, SQLCipher, Keychain key |
| Same-user malware | Reads process memory or UI | Out of scope for full prevention; minimize plaintext lifetime and entitlements |
| Malicious contact | Sends malformed content/media | Bounds checks, idempotent receiver, out-of-process media worker target |
| Network attacker | Alters or observes traffic | Official libsignal plus upstream TLS/service behavior |
| Compromised download host | Replaces app update | Sparkle EdDSA plus Apple code signing and notarization |
| Supply-chain attacker | Alters dependency/build | Pin commits/checksums, clean CI build, SBOM, provenance |
| Corrupt disk/process crash | Loses message state | Transactions, WAL, durable outbox, migration recovery |
| Diagnostic leak | Exposes content | Category-only diagnostics and preview before export |

## Explicit limitations

- App lock does not protect against malware executing as the logged-in user.
- SQLCipher does not protect data already decrypted in process memory.
- Development mode provides no encryption.
- A third-party client cannot claim parity with Signal's security posture without
  independent review and continuous upstream tracking.

## Future attachment worker

Untrusted image/video/document inspection should move into a sandboxed XPC
service with no network entitlement. Pass file descriptors, apply size/time
limits, and return sanitized metadata/thumbnails. A decoder crash must not crash
the messaging process.
