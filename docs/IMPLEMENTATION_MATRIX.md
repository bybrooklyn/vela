# Implementation Matrix

This matrix distinguishes code that is present and locally executable from code
that must be adapted from the pinned Signal-iOS source tree. “Implemented” never
means “verified against the live Signal service” unless the row says so.

## Repository and build system

| Capability | State | Verification |
|---|---|---|
| Swift 6 package graph | Implemented | Debug and release builds |
| Xcode-free native macOS app | Implemented | SwiftPM app target and locally packaged `.app` build on macOS 26 |
| Native macOS XcodeGen project | Implemented | Optional Xcode 26 project generation and CI build/test lane |
| Direct Signal-iOS fork installer | Implemented | Shell/static validation |
| Exact upstream compatibility manifest | Implemented | Pinned commit and dependency versions |
| macOS 26 CI | Implemented | Xcode-free, optional XcodeGen/Xcode, release, and sanitizer lanes |
| Linux CI | Not supported | Product and vendored SQLCipher package target macOS 26 |
| Automated test baseline | Implemented | 123 active tests, including generic Signal record persistence and pre-v4 privacy migration |
| Source release ZIP and checksum | Implemented | Archive is extracted and retested before handoff |
| AGPL license and legal notices | Implemented | Full license, About UI, bundled legal text |

## Portable application core

| Capability | State | Notes |
|---|---|---|
| Explicit client state machine | Implemented | Unlinked, linking, ready, offline, locked, recovery, update required |
| Actor-isolated client orchestration | Implemented | `VelaClient` owns lifecycle and subsystem boundaries |
| Durable outgoing message creation | Implemented | Message and outbox item committed together |
| Persistent outbox | Implemented | Retry state survives process restart |
| Bounded exponential retry | Implemented | Injectable clock/backoff policy |
| Incoming envelope processing | Implemented | Validation, decode, persistence, event publication |
| Envelope replay suppression | Implemented | Durable envelope-ID ledger |
| Conversation persistence | Implemented | Direct, group metadata, and Note to Self model |
| Message persistence | Implemented | Text, replies, edits, reactions, deletes, and attachment model fields |
| Search | Implemented | Escaped local body-text search |
| Unread state | Implemented | Increment and mark-read paths |
| Pin/archive | Implemented | Persisted conversation state |
| Disappearing-message cleanup | Implemented | Expiry timestamps and transactional removal |
| Redacted diagnostics | Implemented | Category/count-only diagnostic recorder |
| Attachments | Implemented via signal-cli | Send, receive, inline images, 100 MB cap; no current live-account evidence |
| Message reactions, edits, and deletes | Implemented for local runtime | Durable control outbox, incoming application, replay suppression, and native UI |
| Initial history transfer | Contract only | Requires upstream link-and-sync implementation |
| Calls | Contract only | Requires native RingRTC integration |
| Stories | Feature gate only | No synchronization or UI |

## Development runtime

| Capability | State | Notes |
|---|---|---|
| Linked-device setup simulation | Implemented | Offline fallback; an embedded signal-cli artifact enables the separate live-service route |
| Loopback service transport | Implemented | Async connection and incoming-envelope streams |
| Development wire codec | Implemented | Versioned JSON test envelope |
| Development crypto boundary | Implemented, insecure by design | Constructor requires explicit plaintext opt-in |
| End-to-end send/receive demonstration | Implemented | Link, send, receive, persist, deduplicate, and inspect statistics |
| Injected transport failure/retry test | Implemented | Confirms durable retry transition |

## Native macOS application

| Capability | State | Verification boundary |
|---|---|---|
| SwiftUI app/window lifecycle | Implemented | App target compiled and `.app` packaged locally on macOS 26 |
| Native split-view conversation UI | Implemented | Source complete |
| AppKit text composer | Implemented | Return sends; Shift-Return or Option-Return inserts a newline |
| Provisioning/QR onboarding | Implemented via signal-cli | Real `sgnl://linkdevice` QR; prior manual account linking, not current automated evidence |
| Conversation creation | Implemented for local runtime | Direct, group, and Note to Self drafts |
| Message timeline | Implemented | Date grouping, delivery state, copy action |
| Sidebar search | Implemented | Conversation title and last-message filtering |
| Settings and diagnostics | Implemented | Account, privacy, storage, legal notices |
| Notification Center | Implemented | Generic content only; no message preview |
| Dock unread badge | Implemented | Driven by client snapshot |
| Local database key | Implemented with known limitation | SQLCipher key is in an owner-only `0600` container file; legacy Keychain keys migrate to it |
| Touch ID/password app lock | Implemented | LocalAuthentication path requires macOS runtime |
| Sleep/wake handling | Implemented | Lock on sleep; flush outbox on wake |
| Launch at login | Implemented | `SMAppService.mainApp` |
| App Sandbox | Implemented | Minimal network-client entitlement |
| Privacy manifest | Implemented | No tracking or declared collection |
| Native icon | Implemented | Complete macOS icon rendition set |
| Signed/notarized release | Scripts only | Requires developer credentials and macOS |

## Native Signal-iOS/libsignal production compatibility

The embedded signal-cli backend is a separate development integration route.
It does not make the native Signal-iOS/libsignal bridge production-ready.

| Capability | State | Required upstream work |
|---|---|---|
| Official libsignal identity/session stores | Fail-closed boundary | Implement adapter against manifest-pinned libsignal v0.97.3/SignalServiceKit APIs |
| Real linked-device provisioning | Fail-closed boundary | Adapt upstream provisioning coordinator |
| Authenticated service connection | Fail-closed boundary | Wrap upstream receive/send service APIs |
| Multi-device recipient fan-out | Fail-closed boundary | Use upstream recipient/device resolution |
| Group sender-key behavior | Fail-closed boundary | Use upstream group and sender-key implementation |
| Signal database/migrations | Integration decision documented | Prefer direct SignalServiceKit storage adapter |
| Attachment service | Fail-closed boundary | Upstream pointer/encryption/integrity pipeline |
| Initial chat/media transfer | Fail-closed boundary | Upstream link-and-sync/backup path |
| RingRTC calls | Fail-closed boundary | Native macOS RingRTC/WebRTC bridge |
| Official-client interoperability matrix | Not run | Requires live dedicated accounts and macOS builds |

## Meaning of this snapshot

The repository is a working local messaging foundation with an optional
signal-cli live-service route, not a production-ready native Signal
implementation. The native security-critical upstream seam is explicit,
version-pinned, tested to fail closed, and documented for direct-fork
development.
