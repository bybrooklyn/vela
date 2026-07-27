# Security Policy

## Reporting

Do not file a public issue for a vulnerability that could expose message data,
keys, linked-device credentials, update signing, or remote code execution.
Configure a private security address before public distribution and publish its
OpenPGP/age recipient in this file.

Until that address exists, this repository is development-only and must not be
presented as a security-audited messenger.

## Supported versions

No public production release is currently supported. Development builds are for
local pipeline work and limited signal-cli integration testing only. Prior
manual live-account results are development evidence, not a supported security
or interoperability claim.

## Current security boundaries

- The native Signal-iOS/libsignal bridge remains fail-closed. Live development
  traffic uses the separate signal-cli route when its generated backend is
  embedded.
- Vela's database uses the included SQLCipher amalgamation with CommonCrypto.
- The database key currently sits beside the database in an owner-only `0600`
  file. This protects a copied database file, but not against an attacker who
  can read the whole app container. A stable signed release needs a reviewed
  Keychain design.
- The embedded signal-cli backend currently keeps its own database unencrypted.
- The local fallback uses explicitly enabled plaintext development crypto and
  must never connect to Signal services.

## Hard requirements before a production release or native-bridge live testing

1. Pin an exact Signal-iOS commit and every submodule.
2. Use official libsignal through a reviewed adapter.
3. Link SQLCipher, verify `PRAGMA cipher_version` at runtime, and protect the
   database key with a production-grade Keychain design.
4. Remove or compile out `DevelopmentPlaintextCryptoEngine` from release schemes.
5. Pass the logging/redaction checks.
6. Threat-model the update channel and isolate signing keys.
7. Run official-client interoperability tests with dedicated accounts.
8. Perform dependency-license and vulnerability review.
9. Review App Sandbox entitlements.
10. Obtain independent security review before broad distribution.
11. Encrypt the embedded signal-cli database at rest or exclude that backend
    from the release.

## Diagnostics

Permitted:

- Version/build identifiers.
- macOS and architecture.
- Database schema number.
- Counts of jobs and rows.
- Redacted error type/category.
- State transitions and durations.

Forbidden:

- Message bodies.
- Phone numbers, usernames, service IDs, or recipient IDs.
- Group titles or membership.
- Attachment names or paths.
- Identity/profile/access keys.
- Decrypted envelopes or protobuf payloads.
- Conversation URLs.
