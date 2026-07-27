# Database Design

The portable implementation uses SQLite through a tiny CSQLite system module.
Release composition requests SQLCipher and verifies `PRAGMA cipher_version`;
ordinary SQLite causes release initialization to fail.

## Tables

- `linked_account`: singleton linked-device metadata. Secret key material should
  remain in upstream/libsignal stores or Keychain; the `identityHandle` is a
  reference, not raw private key bytes.
- `conversations`: encoded conversation snapshots plus indexed sort fields.
- `messages`: encoded message snapshots plus conversation/time/expiry indexes.
- `outbox`: durable plaintext-to-crypto-boundary payload in the encrypted
  database, retry metadata, and due-time index.
- `seen_envelopes`: incoming idempotency ledger.

Complex records are encoded as sorted-key JSON in the development implementation.
When integrated into Signal-iOS, prefer the exact upstream GRDB/SQLCipher schema
and migrations instead of maintaining a parallel production schema.

## Transaction boundaries

- Outgoing message, conversation preview, and outbox are committed together.
- Optimistic edits, reactions, and deletes are committed with a durable control-envelope outbox row.
- Incoming message, conversation unread/preview state, and envelope ledger are
  committed together.
- Incoming message mutations and their replay-ledger entry are committed together.
- Outbox completion and message sent-state are committed together.
- Database deletion removes account, conversations, messages, outbox, and
  idempotency state in one transaction; Keychain deletion is handled by the
  platform composition layer.

## Migration policy

Schema version 2 removes the version-1 outbox foreign key so non-display control envelopes can be durable; a fixture test covers that upgrade. Never edit a released migration. Add a new migration and test every prior public
schema fixture. Before a destructive or long-running migration, create an
encrypted recovery snapshot, validate the result, then retire the snapshot only
after a stable launch.
