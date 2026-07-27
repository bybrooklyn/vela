# Message Pipeline Invariants

1. A user-visible send is durable before network activity begins.
2. Every outgoing message has a stable message ID reused across retries.
3. Retry state survives restart.
4. Incoming envelope processing is idempotent by envelope ID.
5. A malformed envelope cannot stop later envelopes from being processed.
6. UI events contain identifiers and state, not plaintext content.
7. Notification generation occurs after local commit.
8. Production encryption is delegated to official libsignal.
9. Unsupported future content is represented explicitly, not silently dropped.
10. All database calls are asynchronous from the UI's perspective.

## Retry policy

The default portable policy starts at one second, doubles, caps at five minutes,
and permanently fails after twelve attempts. The live adapter should distinguish
permanent authentication/protocol failures from transient network/service errors
and add jitter to avoid synchronized reconnect storms.
