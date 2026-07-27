# Changelog

## 0.1.2-development — 2026-07-25

- Raised the minimum supported operating system to macOS 26 for the Liquid
  Glass UI implementation.
- Added a complete Xcode-free native macOS build path.
- Added a SwiftPM `VelaMacApp` executable target on macOS.
- `just build` now creates `build/Vela.app` using the standalone Swift toolchain and Apple Command Line Tools SDK.
- `just run` builds and opens the app directly.
- Added manual app-bundle packaging, legal/privacy resources, icon generation, and local ad-hoc signing.
- Kept Xcode/XcodeGen support as optional `just build-xcode`, `just project`, and `just test-xcode` recipes.
- Added the optional embedded signal-cli live-service route while retaining the
  local simulator fallback. Generated signal-cli/GraalVM artifacts are not part
  of the source archive.
- Compiled the included SQLCipher amalgamation with CommonCrypto for Vela's
  local database. The embedded signal-cli database remains unencrypted.
- Changed the composer so Return sends and Shift-Return or Option-Return inserts
  a newline.
- Expanded the active automated baseline to 147 tests across 25 suites,
  including generic Signal record persistence, pre-v4 privacy migration, and
  end-to-end user-journey regression coverage.
- Retained retryable outbox rows across repeated failures, capped backoff,
  exposed immediate reconnect-driven retry, and restored optimistic mutations
  after permanent send failure.
- Added bounded inbound-attachment downloads and managed outgoing attachment
  staging; view-once attachments remain intentionally uncached.
- Isolated drafts, attachments, replies, edits, typing state, and send-failure
  recovery per conversation; conversation switches now hide stale timelines
  behind a loading state.
- Fixed phone-sync envelope decoding, atomic contact snapshot replacement,
  read/expiry synchronization, reaction removal, and stale daemon/socket
  disconnect handling.
- Hardened onboarding retry/recovery, Settings lock and alert routing, reset
  cleanup, unavailable-auth behavior, and notification authorization reporting.
- Kept the native Signal-iOS/libsignal production bridge fail-closed; signal-cli
  interoperability does not satisfy that bridge's release gate.
- Added `docs/XCODE_FREE_BUILD.md`.

## 0.1.1-development — 2026-07-25

- Replaced all Swift Package XCTest imports with Swift Testing so `swift test` works with standalone Swift toolchains that do not ship the XCTest module.
- Stopped using Homebrew `sqlite3` through pkg-config on macOS; the package now links the platform SDK `sqlite3` library directly.
- Retested the portable debug suite on Swift 6.2.1.

## 0.1.0-development — 2026-07-25

Initial complete repository snapshot for the native macOS client foundation.

### Included

- Native SwiftUI/AppKit macOS application source and XcodeGen project.
- Durable Swift 6 messaging core with actor isolation.
- SQLite development database and fail-closed SQLCipher release policy.
- Persistent outbox, retries, envelope deduplication, search, unread state,
  pinning, archiving, replies, edits, reactions, deletes, disappearing-message cleanup, and diagnostics.
- Local linked-device provisioning simulator and loopback transport.
- Explicit development-only plaintext wire codec.
- Fail-closed interfaces for official libsignal, SignalServiceKit transport,
  attachment transfer, history transfer, and RingRTC.
- Keychain, app lock, Notification Center, launch-at-login, app sandbox,
  privacy manifest, legal notices, and native app icon.
- CI, release scripts, direct-fork bootstrap scripts, tests, threat model,
  architecture decisions, and upstream compatibility manifest.

### Known boundary

This snapshot does not claim live Signal interoperability. It pins the upstream
revision and dependency versions required for the next integration phase rather
than inventing or imitating unstable production protocol behavior.
