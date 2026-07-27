# Contributing

## Ground rules

- Use macOS 26+, a current macOS SDK, and Swift 6.1+ for supported builds.
- Preserve AGPL notices.
- Do not introduce custom Signal cryptography.
- Do not add analytics or advertising SDKs.
- Do not log sensitive content.
- Keep protocol, database, and network logic out of SwiftUI views.
- Add tests for every state transition and migration.
- Record upstream-file patches.
- Keep the original Signal-iOS targets buildable after integration.
- Keep the native Signal-iOS/libsignal bridge fail-closed until its pinned
  adapter passes the documented interoperability gate.
- Treat signal-cli as a separate integration route; do not describe its local
  envelopes as native libsignal-bridge protection.

## Before opening a pull request

```bash
./Scripts/verify.sh
./Scripts/verify-release.sh
```

A change that touches storage must include migration and interruption tests. A
change that touches protocol behavior must include an interoperability plan. A
change that adds an entitlement, persistent dependency, background process, or
network endpoint requires an ADR.
