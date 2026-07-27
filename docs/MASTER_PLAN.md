# Native macOS Signal-Compatible Client

## Master Engineering Plan

**Document version:** 1.0  
**Date:** July 24, 2026  
**Status:** Initial architecture and implementation plan  
**Intended repository:** A direct fork of `signalapp/Signal-iOS`  
**License requirement:** AGPL-3.0-compatible  
**Application model:** Native macOS linked-device client  
**Primary implementation language:** Swift  
**UI:** SwiftUI with targeted AppKit components  
**Cryptography:** Official `libsignal` implementation only  
**Calling:** Native RingRTC integration after messaging is mature  

> Current implementation facts are tracked in `docs/IMPLEMENTATION_MATRIX.md`.
> Where this historical plan named an older platform baseline, the implemented
> product now requires macOS 26.

---

## 1. Executive Summary

The project will create a first-class native macOS client compatible with Signal. It will use Signal-iOS as the upstream codebase and preserve its Git history, cryptographic implementation, storage model, linked-device behavior, protocol logic, synchronization logic, group state, attachment handling, and as much of `SignalServiceKit` as can be made portable.

The project will **not** be a Catalyst port, an Electron wrapper, a web application, a custom Signal server, or an independent primary-device implementation.

The application will operate as a linked device:

```text
Primary Signal phone
        │
        │ QR-code provisioning
        ▼
Native Swift macOS linked device
```

The project’s central engineering strategy is:

```text
Fork Signal-iOS
→ preserve upstream history
→ keep the original iOS targets buildable
→ extract and port the reusable application core
→ introduce explicit Apple-platform abstractions
→ build a new native macOS interface
→ prove linked-device interoperability early
→ add messaging features in vertical slices
→ add media, history transfer, and macOS integration
→ port calls only after messaging is reliable
→ continuously merge and validate upstream changes
```

The first real project milestone is not a polished interface. It is this complete vertical slice:

```text
Clone fork
→ build upstream
→ launch native Mac app
→ show provisioning QR code
→ link from the primary phone
→ create encrypted local storage
→ connect to Signal services
→ receive one text message
→ decrypt and persist it
→ display it
→ send one reply
→ restart the app
→ repeat successfully
```

Until that works reliably across restart, sleep, wake, network changes, and upstream merges, the project is still a prototype.

---

# 2. Product Definition

## 2.1 Product Goal

Create a native macOS Signal-compatible client with:

- A fully native Swift application.
- A SwiftUI application shell.
- AppKit components for performance-sensitive desktop interfaces.
- Native windows, menus, keyboard shortcuts, accessibility, notifications, drag-and-drop, file selection, and lifecycle behavior.
- Signal-compatible linked-device provisioning.
- Encrypted local storage.
- One-to-one messaging.
- Group messaging.
- Attachments and media.
- Reactions, replies, edits, deletes, disappearing messages, and the rest of the current messaging feature set.
- Initial history transfer when supported by the upstream protocol.
- Native macOS audio and video calling in a later phase.
- Continuous compatibility tracking with upstream Signal releases.
- Signed, notarized, directly distributed builds.
- Signed automatic updates.
- No telemetry by default.
- Public corresponding source for every distributed build.

## 2.2 Non-Goals

The application will not initially:

- Register phone numbers.
- Become the primary device for an account.
- Replace the user’s phone.
- Implement a custom Signal-compatible server.
- Reimplement Signal cryptography.
- Use Electron.
- Use Catalyst as the main application architecture.
- Reuse Signal-iOS screens as the final Mac UI.
- Depend on Signal’s production APNs credentials.
- Support calling before reliable messaging and synchronization.
- Target obsolete macOS releases during the initial port.
- Submit message contents to Spotlight.
- Add third-party analytics or advertising SDKs.
- Add AI features to message contents.
- Change the Signal protocol or create a private protocol fork.

## 2.3 Compatibility Definition

“Compatible” means:

- The client interoperates with official Signal clients for a defined upstream release range.
- The project records the exact upstream Signal-iOS commit used for every release.
- The project pins the exact compatible `libsignal`, RingRTC, database, protobuf, and build-tool versions.
- The project maintains an interoperability test matrix against official Signal iOS, Android, and Desktop clients.
- Unsupported future message types are preserved safely and displayed as upgrade-required placeholders rather than silently discarded.

Compatibility is an ongoing maintenance responsibility. `libsignal` and Signal’s internal client APIs are not stable third-party SDK contracts.

## 2.4 Initial Platform Baseline

| Decision | Initial choice |
|---|---|
| Minimum operating system | macOS 26 |
| Initial architecture | Apple silicon |
| Public beta architectures | Apple silicon; Intel after dependency validation |
| New Swift code | Swift 6 strict concurrency where practical |
| UI framework | SwiftUI plus targeted AppKit |
| Storage | GRDB and SQLCipher, aligned with upstream |
| Cryptography | Official `libsignal` |
| Calling | RingRTC port after messaging |
| Distribution | Developer ID direct download |
| Notarization | Required |
| Sandbox | Enabled unless a documented blocker exists |
| Update framework | Sparkle 2 |
| Telemetry | None by default |
| Primary-device support | Never planned unless upstream officially supports it |

---

# 3. Core Engineering Rules

These rules are mandatory and should live in `docs/ENGINEERING_RULES.md`.

1. Never implement Signal cryptography manually.
2. Never replace `libsignal` with an unofficial protocol package.
3. Never put protocol, storage, synchronization, or network logic inside SwiftUI views.
4. Never log message content, recipient identifiers, phone numbers, usernames, profile keys, identity keys, group names, attachment names, decrypted envelopes, or full conversation URLs.
5. Never rewrite upstream database migrations merely to simplify the Mac port.
6. Never silently drop an unsupported incoming message type.
7. Never merge upstream changes directly into a release branch.
8. Never auto-update from an unsigned or unverifiable artifact.
9. Never distribute a binary without publishing the corresponding source state and dependency manifest.
10. Never use Signal’s application name, logo, or visual identity as the project’s own branding.
11. Do not refactor working upstream protocol logic during the first portability pass.
12. Do not make calls a prerequisite for the first usable release.
13. Preserve the original Signal-iOS targets as an upstream regression check.
14. Prefer adapters and new files over invasive edits to upstream-owned files.
15. Every persistent upstream patch must be documented.
16. Every data migration must be crash-tested.
17. Every outbound message must become durable before transmission.
18. Every inbound processing step must be idempotent.
19. Main-thread database access is forbidden.
20. Untrusted attachment decoding must eventually occur outside the main process.
21. The user must be able to inspect diagnostics before exporting them.
22. Release signing and update signing keys must be isolated from normal development systems.
23. The app must behave safely when every optional permission is denied.
24. Unknown server states must fail closed and present a clear recovery path.
25. Feature parity is measured by behavior and interoperability, not by merely showing matching UI controls.

---

# 4. Repository Strategy

## 4.1 Fork Signal-iOS Directly

Use a direct GitHub fork of `signalapp/Signal-iOS`.

Do not begin with a blank wrapper repository containing Signal-iOS as a submodule. A wrapper repository would add another dependency boundary, complicate source publication, and make upstream changes harder to track without providing meaningful architectural isolation.

Preserve:

- Complete upstream Git history.
- Existing submodules.
- Existing iOS targets.
- Existing build scripts.
- Existing tests.
- Existing copyright notices.
- Existing AGPL license.
- Upstream tags and release history.

## 4.2 Recommended Repository Layout

```text
<repository-root>/
├── Signal/                          # Existing upstream iOS application
├── SignalServiceKit/                # Existing shared Signal application core
├── SignalUI/                        # Existing UIKit interface; reference only
├── SignalNSE/
├── SignalShareExtension/
├── Pods/                            # Existing upstream submodule/dependencies
├── Scripts/
├── Signal.xcodeproj/
├── Signal.xcworkspace/
│
├── MacClient/
│   ├── MacClient.xcodeproj/
│   ├── MacClient.xcworkspace/
│   ├── project.yml                  # Generated project definition
│   ├── Podfile
│   ├── Configuration/
│   ├── App/
│   ├── Application/
│   ├── UI/
│   ├── Platform/
│   ├── Resources/
│   ├── Extensions/
│   ├── Tests/
│   └── UITests/
│
├── PlatformKit/
│   ├── Shared/
│   ├── iOS/
│   └── macOS/
│
├── SignalServiceKitMac/
│   ├── Compatibility/
│   ├── Generated/
│   └── Tests/
│
├── RingRTCMac/
│   ├── Bridge/
│   ├── Swift/
│   └── Tests/
│
├── Vendor/
│   ├── artifacts/
│   ├── manifests/
│   └── patches/
│
├── Fixtures/
│   ├── Databases/
│   ├── Messages/
│   ├── Attachments/
│   └── Interop/
│
├── docs/
│   ├── architecture/
│   ├── adr/
│   ├── security/
│   ├── compatibility/
│   ├── porting/
│   ├── testing/
│   └── releases/
│
├── Scripts/
│   └── macOS/
│
├── justfile
├── UPSTREAM.md
├── NOTICE
├── SECURITY.md
└── CONTRIBUTING.md
```

## 4.3 Separate macOS Xcode Project

Initially create a separate `MacClient.xcodeproj` and `MacClient.xcworkspace`.

Do not immediately insert the Mac application into the upstream `Signal.xcodeproj`. A separate project reduces conflicts in:

- `project.pbxproj`
- Existing schemes
- Existing target membership
- CocoaPods integration
- Signing configuration
- CI configuration
- Upstream project-file changes

The Mac project can reference source files from `../SignalServiceKit` without copying them.

Use XcodeGen or another deterministic project generator. Generated Xcode files should be reproducible and verified in CI.

## 4.4 Shared Source Compilation

Create a macOS framework target:

```text
SignalServiceKitMac
```

It should compile portable files directly from the upstream `SignalServiceKit` directory.

Do not manually maintain thousands of target-membership flags. Instead maintain a generated source list and an explicit exclusion manifest:

```text
MacClient/Configuration/SignalServiceKitMac.exclusions.yml
```

Example:

```yaml
- path: SignalServiceKit/Notifications/iOSPushManager.swift
  classification: ios-only
  dependency: UIApplication
  reason: Requires production iOS push behavior
  replacement: PlatformKit/macOS/MacPushRegistrationProvider.swift
  issue: MAC-0142
```

Every exclusion must record:

- Path.
- Classification.
- Platform dependency.
- Reason for exclusion.
- Replacement or stub.
- Tracking issue.
- Test coverage.
- Whether eventual inclusion is expected.

## 4.5 Branch Strategy

```text
main
release/<major>.<minor>
upstream-sync/<date>
feature/<issue>-<description>
fix/<issue>-<description>
security/<private-reference>
experiment/<description>
```

Rules:

- `main` must always build.
- Published `main` must never be rebased.
- Release branches must never be force-pushed.
- Upstream merges enter through `upstream-sync/*`.
- Security work may be private until a coordinated release.
- All release tags must be signed.
- A release branch accepts only approved fixes after stabilization begins.

Enable Git conflict reuse:

```bash
git config rerere.enabled true
git config rerere.autoupdate true
```

## 4.6 Upstream Patch Ledger

Create:

```text
docs/porting/UPSTREAM_PATCHES.md
```

Every persistent change to an upstream-owned file gets an entry:

```markdown
## PATCH-0042 — Abstract push-token registration

- Upstream files:
  - SignalServiceKit/Account/PushRegistrationManager.swift
- Mac requirement:
  - Native linked macOS devices cannot use Signal's production iOS APNs credentials.
- Change:
  - Inject PushRegistrationProvider.
- iOS behavior:
  - Unchanged; IOSPushRegistrationProvider wraps the previous implementation.
- Tests:
  - PushRegistrationProviderTests
  - ProvisioningWithoutPushTests
- First applied:
  - Upstream commit: <commit>
- Tracking issue:
  - MAC-142
```

Create a patch budget. Large-scale edits to upstream-owned files should require architecture review.

---

# 5. Repository Bootstrap

## 5.1 Initial Commands

```bash
# Create the GitHub fork first.
gh repo fork signalapp/Signal-iOS --clone=false

# Clone the fork with all submodules.
git clone --recurse-submodules \
  git@github.com:<YOUR_ACCOUNT>/Signal-iOS.git \
  <PRODUCT_CODENAME>

cd <PRODUCT_CODENAME>

# Add the canonical repository.
git remote add upstream https://github.com/signalapp/Signal-iOS.git
git fetch upstream --tags

# Improve recurring conflict resolution.
git config rerere.enabled true
git config rerere.autoupdate true

# Record the exact initial upstream baseline.
git tag upstream-baseline-2026-07-24 upstream/main

# Install or build upstream dependencies.
make dependencies

# Open and validate the original project.
open Signal.xcworkspace
```

## 5.2 Baseline Validation

Before any Mac-specific changes:

- Build the original Signal iOS application.
- Build all practical upstream frameworks.
- Run all practical upstream unit tests.
- Record known upstream failures.
- Record the exact Xcode version.
- Record the exact macOS version.
- Record the Ruby version.
- Record the Bundler version.
- Record the CocoaPods version.
- Record the Rust toolchain.
- Record the Python version.
- Record every submodule commit.
- Record `Podfile.lock`.
- Record all dependency checksums.
- Record an unsigned build artifact hash.
- Tag the validated baseline.

Third-party Signal builds cannot use Signal’s production push credentials. Treat unavailable production push behavior as a known upstream-development constraint.

## 5.3 First Project-Specific Commit

The first project-specific commit should add only foundational documentation and CI:

```text
docs/PRODUCT.md
docs/ARCHITECTURE.md
docs/ROADMAP.md
docs/ENGINEERING_RULES.md
docs/porting/PORTABILITY_LEDGER.yml
docs/security/THREAT_MODEL.md
docs/adr/
UPSTREAM.md
NOTICE
SECURITY.md
CONTRIBUTING.md
justfile
.github/workflows/upstream-baseline.yml
```

Do not combine documentation, platform abstraction, dependency porting, and UI work into one giant initial commit.

---

# 6. Product Identity, Licensing, and Distribution Rules

## 6.1 Branding

Use an unrelated product name, icon, domain, bundle identifier, repository description, and visual identity.

Do not use names such as:

- Signal Mac
- Signal Native
- Signal Swift
- Signal for macOS

Do not use:

- Signal’s official logo.
- A confusingly similar speech-bubble icon.
- Signal’s exact screenshots as product artwork.
- A domain containing `signal` as the project’s primary domain.
- Language implying endorsement or operation by Signal.

Recommended public description:

> An unofficial native macOS client compatible with Signal. Not affiliated with or endorsed by Signal Technology Foundation.

## 6.2 License

The fork must remain AGPL-3.0-compatible.

Requirements:

- Preserve all upstream copyright notices.
- Preserve the complete AGPL license.
- Add a `NOTICE` file.
- Identify modifications clearly.
- Publish the exact corresponding source for every distributed build.
- Publish build instructions.
- Publish dependency manifests.
- Publish patches to vendored dependencies.
- Expose the source link in the About window and on the download page.
- Review every added dependency for license compatibility.
- Do not attempt to relicense inherited Signal code under MPL, Apache, MIT, or a proprietary license.

## 6.3 Cryptographic Export Review

Before broad distribution:

- Document every cryptographic library.
- Answer Apple’s encryption-export questions accurately.
- Document whether the application qualifies for applicable exemptions.
- Review international distribution requirements.
- Keep release documentation aligned with the actual cryptographic implementation.
- Do not claim that the fork is more secure than Signal without independent evidence.

---

# 7. System Architecture

## 7.1 Module Graph

```text
┌──────────────────────────────────────────────┐
│                   Mac App                    │
│ lifecycle · windows · commands · settings    │
└───────────────────────┬──────────────────────┘
                        │
┌───────────────────────▼──────────────────────┐
│                    Mac UI                    │
│ sidebar · timeline · composer · calls · setup│
└───────────────────────┬──────────────────────┘
                        │
┌───────────────────────▼──────────────────────┐
│              Mac Application Layer           │
│ use cases · snapshots · routing · state      │
└────────────────┬──────────────────┬──────────┘
                 │                  │
┌────────────────▼─────────┐  ┌────▼───────────────┐
│   SignalServiceKitMac    │  │     PlatformKit    │
│ accounts · messages · DB │  │ OS-specific adapters│
│ groups · sync · media    │  │ keychain · lifecycle│
└────────┬────────┬────────┘  └────────────────────┘
         │        │
┌────────▼───┐ ┌──▼───────────────────┐
│ libsignal  │ │ GRDB + SQLCipher     │
│ Rust FFI   │ │ encrypted persistence│
└────────────┘ └──────────────────────┘

Later:

┌────────────────────┐
│     RingRTCMac     │
│ calls · WebRTC     │
└────────────────────┘
```

## 7.2 `MacApp`

Owns:

- `NSApplication` lifecycle.
- SwiftUI scenes.
- Window creation and restoration.
- Menu commands.
- Dock and app activation behavior.
- Application termination.
- Login-item configuration.
- Deep-link routing.
- Dependency composition.
- Update controller.
- Crash-recovery routing.
- Global application state presentation.

It must not directly perform Signal protocol operations.

## 7.3 `MacUI`

Owns:

- Provisioning interface.
- Conversation sidebar.
- Message timeline.
- Composer.
- Search.
- Settings.
- Profile views.
- Group views.
- Media gallery.
- Calls interface.
- Empty states.
- Alerts and sheets.
- Accessibility labels and actions.

It receives immutable view snapshots and invokes application-layer commands.

## 7.4 `MacApplication`

Owns user-facing use cases and coordinates the core:

```swift
protocol LinkDeviceUseCase: Sendable {
    func begin() async throws -> ProvisioningSession
}

protocol SendMessageUseCase: Sendable {
    func send(
        _ draft: MessageDraft,
        to threadID: ThreadID
    ) async throws
}

protocol ConversationQuery: Sendable {
    func observeConversation(
        _ id: ThreadID
    ) -> AsyncStream<ConversationSnapshot>
}
```

This layer prevents SwiftUI from binding directly to mutable database records or internal Signal objects.

## 7.5 `SignalServiceKitMac`

Owns:

- Device identity.
- Linked-account state.
- Signal service networking.
- Envelope receipt and processing.
- Message send pipeline.
- Message receive pipeline.
- Session state.
- Profiles.
- Contacts.
- Groups.
- Sync messages.
- Attachments.
- Receipts.
- Typing indicators.
- Disappearing-message state.
- Database access.
- Database migrations.
- Provisioning.
- Link-and-sync.
- Backup/history-transfer support.
- Remote configuration where required.

## 7.6 `PlatformKit`

Owns every platform-dependent service.

Shared core code must not directly call:

- `UIApplication.shared`
- `NSApplication.shared`
- `UIDevice.current`
- `NSWorkspace.shared`
- Global Keychain wrappers
- Global notification centers for application behavior
- Platform-specific file pickers
- Platform-specific background-task APIs

---

# 8. Platform Abstraction Plan

## 8.1 Required Protocols

Create protocols for:

```text
ApplicationLifecycle
ApplicationState
BackgroundExecution
PushRegistration
LocalNotifications
SecureKeyStore
FileSystemLocations
TemporaryFileStore
DeviceMetadata
ContactAuthorization
ContactProvider
CameraAuthorization
MicrophoneAuthorization
MediaPicker
FilePicker
Clipboard
URLLauncher
LocalAuthentication
PowerState
SleepWakeMonitor
NetworkPathMonitor
AudioDeviceProvider
ScreenCaptureProvider
SharePresenter
AppBadge
SystemAppearance
Clock
Randomness
```

Implement platform-specific modules:

```text
PlatformKit/iOS/
PlatformKit/macOS/
```

The iOS adapters should wrap existing upstream behavior without intentional behavioral changes.

## 8.2 Portability Audit

Run automated source scans:

```bash
rg -n \
  'import UIKit|UIApplication|UIDevice|UIScreen|UIPasteboard|UIImage|UIColor|UIFont|UIBackgroundTask|BGTaskScheduler|AVAudioSession' \
  SignalServiceKit
```

Classify each result:

| Classification | Action |
|---|---|
| Accidental UIKit import | Replace with Foundation/shared type |
| Operating-system service | Move behind `PlatformKit` |
| UI-only feature | Exclude from `SignalServiceKitMac` |
| Portable with a narrow alias | Add a compatibility shim |
| Fundamentally iOS-only | Stub explicitly and document |
| Unknown | Block the subsystem until understood |

Maintain a machine-readable portability ledger:

```yaml
file: SignalServiceKit/Example.swift
status: needs-adapter
dependency: UIApplication
adapter: ApplicationState
issue: MAC-231
tests:
  - ApplicationStateTests
```

## 8.3 Conditional Compilation Policy

Allowed:

```swift
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
```

Only inside:

- Platform adapters.
- Tiny type bridges.
- Framework entry points.
- Unavoidable compatibility shims.

Not allowed throughout protocol and storage logic.

CI must count new uses of:

```text
#if os(macOS)
#if canImport(AppKit)
```

Any increase requires review.

## 8.4 Porting Principle

The order is:

```text
Make it compile
→ make it behave identically
→ add tests
→ improve architecture behind the tests
```

Do not immediately:

- Convert all callbacks to `async/await`.
- Replace every queue with an actor.
- Rewrite dependency injection.
- Eliminate all singletons.
- Rename inherited types.
- Replace GRDB.
- Replace CocoaPods.
- Convert the entire codebase into Swift packages.

Those may become separate projects after interoperability is stable.

---

# 9. Dependency Strategy

## 9.1 Version Alignment

The Mac client must use dependency versions compatible with its Signal-iOS upstream baseline.

Do not independently chase newer releases of:

- `libsignal`
- RingRTC
- GRDB
- SQLCipher
- SwiftProtobuf
- WebRTC
- Supporting Signal libraries

Create:

```text
Vendor/manifests/upstream-compatibility.json
```

Example:

```json
{
  "signal_ios_commit": "<commit>",
  "libsignal_tag": "<tag>",
  "libsignal_checksum": "<checksum>",
  "ringrtc_tag": "<tag>",
  "ringrtc_checksum": "<checksum>",
  "sqlcipher_commit": "<commit>",
  "grdb_version": "<version>",
  "swift_protobuf_version": "<version>",
  "xcode_version": "<version>",
  "rust_toolchain": "<toolchain>"
}
```

Every release includes this manifest.

## 9.2 Package Management

Use:

- The existing CocoaPods setup for the upstream iOS application.
- A Mac-specific dependency graph for `MacClient`.
- Swift Package Manager for isolated new Mac components where practical.
- Deterministically built native artifacts for Rust/C/C++ dependencies.
- Checksums for every prebuilt artifact.

Do not migrate the upstream application from CocoaPods to Swift Package Manager during the initial port.

## 9.3 Native `libsignal`

Use the exact Swift-facing API expected by the chosen Signal-iOS baseline.

Recommended pipeline:

```text
Pinned libsignal source
        │
        ├── build aarch64-apple-darwin
        ├── build x86_64-apple-darwin
        │
        ▼
libsignal_ffi.xcframework
        │
        ▼
LibSignalClientMac Swift target
```

Rules:

- Fork `libsignal` only for build-system or platform-enablement patches.
- Do not change cryptographic implementation code.
- Keep patches minimal and separately documented.
- Run upstream Rust tests.
- Run upstream Swift tests.
- Run supported protocol test vectors.
- Generate checksums for every artifact.
- Never download an unverified binary during an Xcode build.
- Release CI must build from pinned source or retrieve a separately verified artifact.

Early exit criteria:

```text
A native macOS test executable can:
- load the library
- generate required key material
- execute upstream test vectors
- serialize and deserialize supported protocol objects
- pass sanitizer builds where practical
```

## 9.4 RingRTC

Treat RingRTC as a separate project phase.

Do not:

- Block messaging on calling.
- Embed Node or Electron to reuse Signal Desktop calling code.
- Import RingRTC throughout the application.

Create a narrow `CallEngine` protocol immediately and use a fake implementation until the native Mac call stack exists.

---

# 10. Build Tooling

## 10.1 Terminal-First Workflow

Add a `justfile`:

```make
default:
    @just --list

bootstrap:
    ./Scripts/macOS/bootstrap.sh

upstream-build:
    make dependencies
    ./Scripts/macOS/build-upstream-ios.sh

mac-project:
    ./Scripts/macOS/generate-project.sh

build:
    ./Scripts/macOS/build-debug.sh

test:
    ./Scripts/macOS/test-all.sh

test-core:
    ./Scripts/macOS/test-core.sh

test-interop:
    ./Scripts/macOS/test-interop.sh

lint:
    ./Scripts/macOS/lint.sh

archive version:
    ./Scripts/macOS/archive.sh "{{version}}"

notarize artifact:
    ./Scripts/macOS/notarize.sh "{{artifact}}"

release version:
    ./Scripts/macOS/release.sh "{{version}}"

sync-upstream:
    ./Scripts/macOS/sync-upstream.sh
```

## 10.2 Bootstrap Script

`Scripts/macOS/bootstrap.sh` should:

1. Verify the host is macOS.
2. Verify the expected Xcode version.
3. Verify Xcode Command Line Tools.
4. Initialize and update Git submodules.
5. Install the pinned Ruby environment.
6. Install CocoaPods through Bundler.
7. Verify Rust and the pinned toolchain.
8. Verify Python, CMake, Ninja, and other native build tools.
9. Build or retrieve verified native `libsignal`.
10. Install Mac dependencies.
11. Generate the Xcode project.
12. Validate expected generated files.
13. Print exact next commands.

It must be safe to run repeatedly.

## 10.3 Build Configurations

```text
Debug
Debug-Interop
Release-Beta
Release
```

| Configuration | Purpose |
|---|---|
| Debug | Local mocks, fast iteration, assertions |
| Debug-Interop | Real Signal service with dedicated test account |
| Release-Beta | Signed beta channel with redacted diagnostics |
| Release | Stable production channel |

Release builds must not include:

- Mock servers.
- Debug trust overrides.
- Test certificates.
- Verbose protocol dumps.
- Development-only menu actions.
- Unrestricted diagnostics.
- Internal test accounts.

---

# 11. Data Architecture

## 11.1 Reuse the Upstream Schema

Do not create an independent “clean Mac database.”

Reuse the upstream storage model for:

- Threads.
- Messages.
- Reactions.
- Receipts.
- Attachments.
- Identity records.
- Profiles.
- Contact data.
- Group state.
- Device sync state.
- Disappearing-message timers.
- Call records.
- Backup/history-transfer objects.
- Migrations.

A separate schema would force continuous translation of every protocol and storage change.

## 11.2 Filesystem Layout

Use the sandbox application container:

```text
Application Support/<bundle-id>/
├── database/
│   ├── signal.sqlite
│   ├── signal.sqlite-wal
│   └── signal.sqlite-shm
├── attachments/
├── avatars/
├── stickers/
├── drafts/
├── indexes/
├── recovery/
└── diagnostics/
```

Temporary decrypted data belongs only in:

```text
Caches/<bundle-id>/Temporary/
```

Temporary content must be:

- Removed after use.
- Cleared during logout.
- Cleared after a crash on next launch.
- Excluded from diagnostics.
- Protected by sandboxing.
- Created with restrictive permissions.

## 11.3 Key Storage

Store:

- Database master key in Keychain.
- Device credentials according to upstream semantics.
- Local application-lock material in Keychain.
- No secrets in `UserDefaults`.
- No updater private keys in the app or repository.
- No service credentials in crash reports.

On unlink or Delete Data:

1. Revoke or unlink the device where supported.
2. Stop networking.
3. Close the database.
4. Delete Keychain secrets.
5. Delete encrypted database files.
6. Delete attachments.
7. Delete caches.
8. Delete diagnostics.
9. Verify that the old account cannot reopen.

On SSD storage, cryptographic key destruction is more meaningful than pretending ordinary file overwrite guarantees physical erasure.

## 11.4 Migration Policy

Every migration must be:

- Taken from upstream whenever possible.
- Tested from every previously released schema.
- Tested under simulated interruption.
- Followed by integrity validation.
- Wrapped in a recovery strategy.
- Incompatible with unsupported downgrade.

Migration flow:

```text
close active services
→ create encrypted recovery snapshot
→ run migration
→ verify schema and integrity
→ launch account
→ retain recovery snapshot temporarily
→ delete snapshot after stable launch
```

Never edit a historical migration after it has shipped.

---

# 12. Application Lifecycle and Background Behavior

## 12.1 One Main Process Initially

Initially the main application process owns:

- Database.
- Signal service connection.
- Message processing.
- Notifications.
- Windows.
- Background receive behavior while the app is running.

Closing the last window must not quit the application.

A separate XPC database/network owner can be considered later only if a proven requirement exists.

## 12.2 Launch at Login

Offer an explicit user-controlled setting:

```text
Open at login
```

Use `SMAppService` on supported macOS versions.

At login:

- Start without opening the main window when configured.
- Establish the authenticated receive connection.
- Restore unread state.
- Show notifications.
- Keep user-visible settings for Dock and menu-bar presence.

Do not install a hidden daemon without consent.

## 12.3 Push and Connection Behavior

Do not rely on Signal’s production iOS APNs credentials.

Create an explicit Mac implementation:

```swift
struct MacPushRegistrationProvider: PushRegistrationProvider {
    func requestToken() async throws -> PushToken {
        throw PushRegistrationError.pushNotSupported
    }
}
```

Expected behavior:

- While running: receive live messages through the authenticated service connection.
- During network loss: retry with bounded exponential backoff and jitter.
- After sleep: reconnect immediately after wake.
- While quit: messages remain pending and arrive after next launch.
- On rejected credentials: enter a clear relink-required state.
- On unsupported protocol version: enter update-required state.

## 12.4 Account State Machine

Use one explicit state machine:

```swift
enum ClientState {
    case unlinked
    case openingDatabase
    case linking(ProvisioningState)
    case importingHistory(ImportProgress)
    case startingServices
    case ready
    case offline(OfflineReason)
    case locked
    case relinkRequired
    case updateRequired
    case recoveryRequired(RecoveryReason)
    case deletingData
}
```

Do not scatter readiness booleans across view models.

---

# 13. UI Architecture

## 13.1 SwiftUI and AppKit Responsibilities

Use SwiftUI for:

- Application shell.
- Window scenes.
- Navigation split view.
- Settings.
- Provisioning.
- Profiles.
- Group settings.
- Search UI.
- Media gallery.
- Empty states.
- Ordinary forms and sheets.

Use AppKit for:

- Large message timeline.
- Rich text composer.
- Complex text selection.
- High-performance context menus.
- Fine-grained keyboard handling.
- Drag-and-drop.
- Video rendering.
- Components where SwiftUI cannot provide predictable performance.

## 13.2 Main Window

```text
┌──────────────────────┬──────────────────────────────────────────┐
│ Conversation list    │ Conversation header                      │
│                      ├──────────────────────────────────────────┤
│ Search               │                                          │
│ Pinned               │ Message timeline                         │
│ Chats                │                                          │
│ Archived             │                                          │
│                      ├──────────────────────────────────────────┤
│ Profile / Settings   │ Composer                                 │
└──────────────────────┴──────────────────────────────────────────┘
```

Optional inspector:

```text
conversation information
members
shared media
files
links
safety information
```

The interface should feel native to macOS, not like an iPad screen enlarged inside a window.

## 13.3 Conversation Timeline

Recommended foundation:

```text
NSCollectionView
+ diffable data source
+ immutable timeline snapshots
```

Requirements:

- Stable message identifiers.
- Incremental pagination.
- Scroll-position preservation while loading older messages.
- Dynamic cell heights.
- Text selection.
- Context menus.
- Hover actions.
- Reactions.
- Message grouping.
- Date separators.
- Unread divider.
- View-once and disappearing state.
- Media-loading cancellation for offscreen cells.
- No database access during cell drawing.
- No full-history materialization in memory.
- Countdown updates without rebuilding the entire collection.

## 13.4 Composer

Use an `NSTextView`-based component supporting:

- Multiline input.
- Mentions.
- Text formatting.
- Emoji.
- Pasted images and files.
- Drag-and-drop.
- Draft persistence.
- Quote replies.
- Edit mode.
- Attachment previews.
- Voice-note recording.
- Return sends.
- Shift-Return or Option-Return inserts a newline.
- Escape to cancel reply or edit.
- Full accessibility.

## 13.5 Menus and Keyboard Commands

Minimum menus:

```text
File
  New Message
  Close Window
  Export Selected Attachment

Edit
  Undo
  Redo
  Cut
  Copy
  Paste
  Find
  Select All

View
  Show Sidebar
  Show Conversation Details
  Increase Text Size
  Decrease Text Size
  Enter Full Screen

Conversation
  Search
  Mute
  Mark Unread
  Pin
  Archive
  Start Call
  View Safety Number

Message
  Reply
  React
  Edit
  Delete
  Forward
  Copy
  Show Details

Window
  Main Window
  Calls
  Minimize

Help
  Documentation
  Report a Problem
  View Source
```

Every primary action must have a keyboard path.

---

# 14. Implementation Phases

## Phase 0 — Product, Legal, and Repository Foundation

### Work

- Choose a codename and independent public identity.
- Fork Signal-iOS.
- Add the upstream remote.
- Preserve all history and submodules.
- Establish AGPL compliance policy.
- Create branding rules.
- Create architecture decision records.
- Create threat-model skeleton.
- Configure issue tracking.
- Build untouched Signal-iOS.
- Pin baseline toolchains.
- Add upstream-build CI.

### Exit Criteria

- The untouched upstream-equivalent iOS build succeeds.
- The repository has a signed baseline tag.
- Known upstream failures are documented.
- Licensing and branding rules are documented.
- CI distinguishes upstream regressions from Mac-port regressions.

---

## Phase 1 — Native Mac Application Shell

### Work

Create:

- Separate generated Mac project and workspace.
- Sandboxed app target.
- SwiftUI app entry point.
- Main window.
- Settings window.
- Native menu commands.
- App icon placeholder.
- Composition root.
- Structured redacted logging.
- Preferences store.
- Empty account state machine.
- Unit-test target.
- UI-test target.
- Debug and Release configurations.

### Exit Criteria

- App launches on Apple silicon.
- Window restoration works.
- Closing the last window does not quit.
- Quit and relaunch are clean.
- Release configuration signs locally.
- No Signal core is required yet.

---

## Phase 2 — Portability Inventory and Core Compilation

### Work

- Enumerate every file in `SignalServiceKit`.
- Run UIKit and platform API scans.
- Create the portability ledger.
- Create `PlatformKit`.
- Compile foundational utilities.
- Compile serialization and protobuf support.
- Compile database abstractions.
- Compile account and device models.
- Compile message and thread models.
- Compile group models.
- Compile network models.
- Compile sync types.
- Exclude calls and iOS notifications initially.
- Add compile-only tests.

Recommended order:

```text
Utilities
→ dates and identifiers
→ serialization and protobuf
→ database primitives
→ account and device models
→ profiles and contacts
→ identity and session storage
→ threads and interactions
→ groups
→ network requests
→ message processing
→ sync
→ attachments
→ backup/history transfer
→ calls
```

### Exit Criteria

- `SignalServiceKitMac.framework` builds.
- A minimal Mac test target imports it.
- Every excluded source has a documented reason.
- Existing iOS behavior remains green.

---

## Phase 3 — Native `libsignal` Integration

### Work

- Pin the exact upstream-compatible `libsignal`.
- Build the Rust FFI for Apple silicon macOS.
- Build Intel support when practical.
- Package native headers and binaries into an XCFramework.
- Link Swift bindings.
- Run upstream cryptographic tests.
- Add artifact checksums.
- Automate builds in `just bootstrap`.
- Add CI rebuilding from source.

### Exit Criteria

- No cryptographic implementation code is modified.
- Core tests pass on macOS.
- Debug and Release load the framework.
- CI rebuilds the artifact from pinned source.
- Xcode does not download arbitrary unverified binaries.

---

## Phase 4 — Encrypted Database and Local State

### Work

- Build GRDB for macOS.
- Build SQLCipher for macOS.
- Initialize the upstream schema.
- Store database key in Keychain.
- Establish attachment and cache directories.
- Implement database open and close.
- Implement app lock.
- Implement Delete Data.
- Add recovery snapshots.
- Add migration interruption tests.
- Add corruption handling.
- Add safe diagnostic summaries.

### Exit Criteria

- Data persists across restart.
- Ordinary SQLite tools cannot read the database without the key.
- Keychain deletion makes the database inaccessible.
- Delete Data removes recoverable application state.
- Interrupted migration does not silently destroy the account.

---

## Phase 5 — Provisioning Foundation

### Work

- Reuse or port the upstream linked-device provisioning coordinator.
- Port provisioning socket management.
- Generate linked-device key material.
- Generate provisioning URL.
- Render QR code.
- Display device-name entry.
- Receive provisioning payload.
- Decrypt and validate the payload.
- Store linked-device credentials.
- Register the device.
- Handle absence of production push.
- Implement cancel, timeout, retry, and restart.
- Initially support linking without history transfer.

### Exit Criteria

- The primary phone scans the QR.
- The Mac appears in the phone’s linked-device list.
- Restart does not require relinking.
- Interrupted provisioning leaves no half-valid credentials.
- Cancel returns to a clean unlinked state.

---

## Phase 6 — First Authenticated Connection

### Work

- Start authenticated service connection after provisioning.
- Implement connection state reporting.
- Reconnect after network changes.
- Reconnect after sleep and wake.
- Add bounded retry and jitter.
- Detect invalid credentials.
- Detect update-required responses.
- Persist incoming envelopes at the correct durability boundary.
- Deduplicate replayed envelopes.
- Acknowledge only after safe processing.

### Exit Criteria

- The app remains connected during ordinary use.
- Wi-Fi changes do not require relinking.
- Sleep and wake recover automatically.
- Offline state is visible but unobtrusive.
- Invalid credentials enter `relinkRequired`.

---

## Phase 7 — First Complete Messaging Slice

### Inbound Pipeline

```text
authenticated connection
→ encrypted envelope
→ libsignal decryption
→ content parsing
→ database transaction
→ timeline update
→ local notification
```

### Outbound Pipeline

```text
composer draft
→ durable outbox record
→ recipient/device resolution
→ libsignal encryption
→ service submission
→ sent state
→ delivery/read state
```

### Initial Support

- One-to-one text message.
- Basic group text message.
- Unicode text.
- Sent timestamp.
- Received timestamp.
- Delivery state.
- Unread count.

### Exit Criteria

From a fresh install:

1. Launch the app.
2. Scan the QR code.
3. Choose no history transfer.
4. Receive a message from an official client.
5. Reply from the Mac.
6. Confirm receipt on the official client.
7. Restart the Mac application.
8. See the same conversation and messages.
9. Send another reply.
10. Sleep and wake the Mac without breaking connectivity.

Do not build a highly polished sidebar before this passes.

---

## Phase 8 — Daily-Usable Text Client

### Work

- Conversation-list queries.
- Sorting.
- Pinned conversations.
- Unread counts.
- Archiving.
- Timeline pagination.
- Immutable snapshots.
- Native composer.
- Draft persistence.
- Conversation search.
- Global search.
- Note to Self.
- Message requests.
- Profile display.
- Group-member display.
- Local notifications.
- Dock badge.
- Basic preferences.

### Exit Criteria

- Ordinary text conversations are usable.
- Large conversations do not block the main thread.
- New messages append without losing scroll position.
- Read state follows upstream semantics.
- Search is stable and ordered.
- Notification actions open the correct thread.

---

## Phase 9 — Messaging Feature Completeness

Implement in this order:

1. Delivery receipts.
2. Read receipts.
3. Typing indicators.
4. Replies and quote messages.
5. Reactions.
6. Mentions.
7. Text formatting.
8. Message editing.
9. Delete for everyone.
10. Forwarding.
11. Message details.
12. Disappearing messages.
13. View-once state.
14. Pinned chats.
15. Pinned messages.
16. Polls.
17. Group member labels.
18. Message requests and spam behavior.
19. Safety-number change warnings.
20. Unsupported-message upgrade placeholders.

### Exit Criteria

For every supported message type:

- Official iOS to Mac works.
- Mac to official iOS works.
- Official Android to Mac works.
- Mac to official Android works.
- Official Desktop behavior is compared.
- Restart preserves state.
- Duplicate delivery does not duplicate content.
- Edits, deletes, and expiration synchronize correctly.

---

## Phase 10 — Groups, Profiles, Contacts, and Usernames

### Profiles

- Names.
- Avatars.
- About text.
- Profile-key behavior.
- Profile updates.
- Local profile rendering.

### Contacts

- Contact sync.
- Optional macOS Contacts integration.
- Permission handling.
- Address-book matching.
- Name-precedence rules.
- Block list.
- Message requests.

### Usernames and Privacy

- Username display.
- Phone-number privacy.
- Start chat through supported identifiers.
- Profile-sharing state.
- Relevant linked-device settings.

### Groups

- Group-state synchronization.
- Group creation where supported.
- Add and remove members.
- Administrators.
- Membership requests.
- Group links.
- Group avatars.
- Group descriptions.
- Mentions.
- Member labels.
- Leave group.
- Group disappearing timers.
- Revision and conflict handling.

### Exit Criteria

- Group membership converges correctly across devices.
- Out-of-order updates are safe.
- Profile changes propagate.
- Blocked-user behavior remains correct.
- Denying Contacts permission does not break messaging.

---

## Phase 11 — Attachments and Media

### Receiving

- Parse attachment pointers.
- Authenticated download.
- Decryption.
- Integrity verification.
- Size limits.
- MIME validation.
- Thumbnail generation.
- Progressive interface.
- Retry.
- Cleanup.

### Sending

- File picker.
- Drag-and-drop.
- Clipboard images.
- Image preprocessing.
- Video metadata.
- Video thumbnails.
- Voice notes.
- Captions.
- Upload encryption.
- Progress.
- Cancellation.
- Retry-safe outbox integration.

### Media Types

- Images.
- Video.
- Audio.
- Voice notes.
- Documents.
- Animated images.
- Stickers.
- Link previews.
- Contact attachments where supported.
- View-once media.

### Native Mac Behavior

- Quick Look.
- Save As.
- Copy image.
- Drag attachment out.
- Open externally only after explicit action.
- Reveal exported file.

### Attachment Security Worker

Create a sandboxed XPC service:

```text
AttachmentWorker.xpc
```

It should:

- Have no network entitlement.
- Receive file descriptors instead of arbitrary paths.
- Generate thumbnails and metadata.
- Decode untrusted media out of process.
- Return sanitized results.
- Crash independently from the main client.

### Exit Criteria

- Corrupt media cannot crash the main process.
- Downloads retry safely.
- Integrity failures never display as valid content.
- View-once content cannot be casually reopened.
- Temporary decrypted files are cleaned up.

---

## Phase 12 — Initial History Transfer and Synchronization

### Work

- Advertise history-transfer capability during linking.
- Accept transfer metadata.
- Receive encrypted history.
- Verify integrity.
- Import into a staging database.
- Validate the staging database.
- Atomically promote imported state.
- Import media incrementally.
- Display progress.
- Resume interruption where the protocol permits.
- Preserve the no-transfer path.
- Prevent duplicate imports.
- Validate disappearing and view-once state.
- Compare visible state with database counts.

### Exit Criteria

- Fresh linking imports expected conversations.
- Media transfer matches upstream behavior.
- Interrupted import never exposes a partially initialized account as ready.
- Canceling does not damage the primary phone account.
- Expiration state remains correct.
- Imported state survives restart.

---

## Phase 13 — Native macOS Integration

### Work

- Notification Center.
- Inline notification reply where safe.
- Dock badge.
- Launch at login.
- Menu commands.
- Services integration where safe.
- Share extension.
- Drag-and-drop.
- Quick Look.
- Deep links.
- Notification privacy.
- Touch ID app lock.
- Automatic lock after inactivity.
- Sleep/wake handling.
- Camera permission.
- Microphone permission.
- Multiple-window foundation.
- Full-screen call windows.
- Appearance support.
- Reduced motion.
- Increased contrast.
- VoiceOver.
- Right-to-left layout.
- Localization.
- Text-size preferences.
- Keyboard-shortcut reference.

Do not submit message contents to Spotlight by default.

### Exit Criteria

- Every optional permission can be denied safely.
- Window closure and application quitting are distinct.
- Login startup is visible and reversible.
- Notification privacy works on a locked Mac.
- VoiceOver can navigate setup, sidebar, timeline, and composer.
- Every primary operation has a keyboard route.

---

## Phase 14 — Stories and Remaining Desktop Features

### Stories

- Story list.
- Story viewer.
- Text stories.
- Media stories.
- Replies.
- Reactions.
- Mute and hide.
- Group stories.
- Expiration.
- View state.
- Privacy synchronization.
- Posting where linked-device behavior permits.

### Remaining Features

- Chat colors.
- Wallpapers.
- Muted-chat behavior.
- Storage management.
- Proxy configuration.
- Language selection.
- Font size.
- Archived behavior.
- Notification customization.
- Call-history placeholders.
- Secure-backup interface only when compatible upstream support is understood.

---

## Phase 15 — Native Calls

Calling is a project inside the project.

### 15.1 Call Abstraction

```swift
protocol CallEngine: Sendable {
    func startOutgoingCall(
        to recipient: RecipientID,
        media: InitialCallMedia
    ) async throws -> CallSession

    func answer(_ callID: CallID) async throws
    func decline(_ callID: CallID) async
    func hangUp(_ callID: CallID) async
}
```

The rest of the application must not import RingRTC directly.

### 15.2 RingRTC macOS Port

Work sequence:

1. Fork the exact RingRTC version expected by the Signal-iOS baseline.
2. Add native macOS Rust target builds.
3. Add required WebRTC macOS build configuration.
4. Create a C or Objective-C bridge.
5. Create a Swift wrapper.
6. Add signaling simulations.
7. Add audio capture and playback.
8. Add camera capture.
9. Add remote-video rendering.
10. Add group calls.
11. Add screen sharing.
12. Add call links.
13. Add reactions and raise-hand behavior.
14. Add device selection and hot swapping.

### 15.3 Call Milestones

#### C1 — Signaling Only

- Incoming call event.
- Outgoing call offer.
- Ringing state.
- Accept.
- Decline.
- Hang up.
- No media yet.

#### C2 — One-to-One Audio

- Microphone permission.
- Input selection.
- Output selection.
- Mute.
- Echo cancellation.
- Network recovery.
- Bluetooth and headphone changes.

#### C3 — One-to-One Video

- Camera permission.
- Camera selection.
- Local preview.
- Remote rendering.
- Video enable and disable.
- Full-screen behavior.

#### C4 — Group Calls

- Participant grid.
- Active speaker.
- Participant state.
- Join and leave.
- Reactions.
- Raise hand.
- Call history.

#### C5 — Screen Sharing and Call Links

- Screen and window picker.
- ScreenCaptureKit.
- Clear recording indicator.
- Call links.
- Join approval.
- Deep-link routing.

### Exit Criteria

- One-to-one calls interoperate with official clients.
- Group calls interoperate with official clients.
- Audio devices can change during a call.
- Permission denial fails cleanly.
- Screen sharing always has a clear local indicator.
- Sleep, wake, network changes, and device removal have defined behavior.
- Calls cannot corrupt messaging state.

---

# 15. Release Ladder

| Release | Scope |
|---|---|
| `0.0.1` | Native application shell |
| `0.1` | QR link, no history transfer, send and receive text |
| `0.2` | Persistent conversations, groups, receipts, notifications |
| `0.3` | Replies, reactions, typing, edits, deletes, disappearing messages |
| `0.4` | Attachments, stickers, voice notes, view-once |
| `0.5` | Profiles, contacts, usernames, full group behavior |
| `0.6` | Initial history transfer and complete synchronization |
| `0.7` | Native macOS integration, search, accessibility, performance |
| `0.8` | Full current messaging parity |
| `0.9` | Audio, video, group calls, screen sharing, call links |
| `0.10` | Stories, backup features where compatible, final parity work |
| `1.0` | Audited, migration-safe, signed, notarized full application |

Do not label the app `1.0` merely because it can send messages. Data integrity, upgrade safety, interoperability, and security response are part of the product.

---

# 16. Message Reliability Design

## 16.1 Outbox State Machine

Every outgoing message must be durable before transmission:

```swift
enum OutgoingMessageState {
    case preparing
    case waitingForAttachmentUpload
    case ready
    case sending(attempt: Int)
    case sent(serverTimestamp: UInt64)
    case partiallySent
    case failedRetryable
    case failedPermanent(reason: FailureReason)
}
```

Requirements:

- A crash must not lose a message after the user presses Send.
- Retry must not duplicate a message.
- Partial multi-device delivery must be representable.
- Attachment uploads must restart or resume safely.
- UI state must derive from persisted state, not transient tasks.
- Permanent failures must be distinguishable from temporary failures.

## 16.2 Inbound Processing

```text
receive envelope
→ validate bounds
→ deduplicate
→ decrypt
→ parse
→ apply one database transaction
→ schedule attachments
→ publish UI change
→ emit notification
```

Requirements:

- Processing is idempotent.
- Unsupported content does not block later messages.
- Malformed messages cannot poison the receive queue.
- Expiration and delete jobs survive restart.
- Clock anomalies are handled explicitly.
- Notifications derive from committed state.
- Acknowledgement occurs only after the correct durability point.

## 16.3 Backpressure

Bound:

- Simultaneous attachment downloads.
- Simultaneous attachment uploads.
- Thumbnail jobs.
- Envelope-processing concurrency.
- Search work.
- Database-observation frequency.
- Timeline snapshot rebuild rate.
- Background retries.

A burst of messages must not create unbounded Swift tasks.

---

# 17. Security Plan

## 17.1 Threat Model

| Adversary | Examples |
|---|---|
| Local casual access | Another person uses an unlocked Mac |
| Local malware | Same-user malicious process |
| Malicious contact | Sends malformed messages or attachments |
| Network attacker | Intercepts or modifies transport traffic |
| Compromised update host | Replaces metadata or artifacts |
| Supply-chain attacker | Malicious dependency or build artifact |
| Stolen device | Attacker obtains encrypted local files |
| Rogue linked device | Another linked client behaves incorrectly |
| Corrupt state | Disk error, interrupted migration, crash |
| Diagnostic leak | Logs or crash reports reveal private data |

Security documentation must clearly state limits. An application lock and encrypted database do not protect an already-unlocked process from powerful same-user malware.

## 17.2 Mandatory Controls

- Official `libsignal`.
- SQLCipher database.
- Keychain-protected database key.
- App Sandbox.
- Hardened Runtime.
- Minimal entitlements.
- Signed and notarized builds.
- Signed updates.
- Strict parser bounds.
- Out-of-process attachment decoding.
- Redacted logs.
- No telemetry by default.
- No third-party analytics.
- No automatic upload of private crash state.
- Dependency pinning.
- Dependency checksums.
- Release provenance.
- Touch ID lock.
- Notification privacy controls.
- Identity-change warnings.
- Safety-number interface.
- Cryptographic local-data deletion.
- Explicit clipboard behavior.
- Optional clipboard clearing for sensitive copied values.
- Secure update-key separation.
- Secret scanning in CI.
- Fuzz testing for parsers and attachment metadata.

## 17.3 Diagnostics

Allowed diagnostic data:

- App version.
- Upstream commit.
- Dependency versions.
- macOS version.
- CPU architecture.
- Database schema version.
- Counts of pending jobs.
- Connection-state transitions.
- Redacted error categories.
- Performance measurements.
- Memory measurements.

Forbidden diagnostic data:

- Message content.
- Recipient identifiers.
- Phone numbers.
- Usernames.
- Group names.
- Contact names.
- Attachment names.
- Profile keys.
- Identity keys.
- Full service responses.
- Conversation URLs.
- Decrypted protobuf payloads.

The app must show a preview before exporting diagnostics.

## 17.4 Security Response

`SECURITY.md` must define:

- Private reporting address.
- Supported releases.
- Preferred encrypted-reporting method.
- Disclosure coordination.
- Emergency release process.
- Release revocation.
- Critical-update mechanism.
- Source publication for emergency builds.
- Supported response channels.
- Expected response ownership.

---

# 18. Testing Strategy

## 18.1 Unit Tests

Test:

- State machines.
- Database queries.
- Database migrations.
- Message snapshot transformations.
- Outbox retries.
- Expiration calculations.
- Log redaction.
- Platform adapters.
- Search.
- Group-state application.
- Attachment cleanup.
- Permissions.
- Delete Data.
- Recovery behavior.

## 18.2 Component Tests

Test:

- Provisioning coordinator with fake network.
- Envelope receiver with fixtures.
- Message sender with fake service.
- Database plus timeline observation.
- Link-and-sync importer.
- Notification generation.
- Attachment pipeline.
- Connection reconnect logic.
- Unknown-message handling.

## 18.3 Interoperability Tests

Use dedicated test accounts and devices.

| Sender | Receiver |
|---|---|
| Official Signal iOS stable | Mac client |
| Mac client | Official Signal iOS stable |
| Official Signal Android stable | Mac client |
| Mac client | Official Signal Android stable |
| Official Signal Desktop | Mac client account |
| Mac client | Multiple official linked devices |

Repeat release-critical tests against current official beta clients before publishing stable releases.

## 18.4 UI Tests

Test:

- First launch.
- QR provisioning.
- Linking cancellation.
- Conversation opening.
- Message sending.
- Replying.
- Editing.
- Deleting.
- Drag-and-drop attachments.
- Search.
- Settings.
- App lock.
- Delete Data.
- Permission denial.
- Notification routing.
- Window restoration.
- Keyboard navigation.

## 18.5 Migration Tests

Maintain sanitized fixtures for every public release:

```text
Fixtures/Databases/v0.1/
Fixtures/Databases/v0.2/
Fixtures/Databases/v0.3/
...
```

Every new release runs:

```text
old fixture
→ migration
→ integrity check
→ semantic assertions
→ application launch
```

## 18.6 Chaos Tests

Inject failures during:

- Database migration.
- Attachment download.
- Attachment upload.
- History import.
- Message send.
- Envelope processing.
- Keychain access.
- Application termination.
- Sleep and wake.
- Network change.
- Disk-full state.
- Database lock contention.
- XPC attachment-worker crash.
- Update download.

## 18.7 Security Tests

- Fuzz protobuf entry points.
- Fuzz attachment metadata.
- Feed malformed media to the XPC worker.
- Verify logs remain redacted.
- Verify Release entitlements.
- Verify signatures.
- Verify updater rejects modified artifacts.
- Test update-key rotation.
- Scan repository for secrets.
- Scan dependencies for known vulnerabilities.
- Verify dependency license compatibility.
- Verify no debug trust overrides exist in Release.

---

# 19. Performance Budgets

Initial engineering budgets:

| Area | Budget |
|---|---|
| Cold launch to visible shell | At most 1 second on an M1-class Mac |
| Cold launch to usable existing account | At most 1.5 seconds for ordinary history |
| Idle CPU | Effectively 0% outside network work |
| Ordinary idle memory | Target at most 180 MB |
| Local send acknowledgement | At most 100 ms before network completion |
| Open recent conversation | At most 100 ms from local state |
| Search first result | At most 200 ms for ordinary database |
| Timeline scrolling | Sustained 60 fps |
| Main-thread database work | Zero |
| Main-thread thumbnail decoding | Zero |
| Wake reconnect | Immediate attempt with controlled retry |
| Timeline memory | Bounded independently of total history |

Synthetic datasets:

```text
small:
  20 conversations
  2,000 messages

medium:
  200 conversations
  100,000 messages

large:
  2,000 conversations
  1,000,000 messages

media:
  50 GB encrypted attachment corpus
```

Benchmark:

- Launch.
- Conversation-list load.
- Timeline opening.
- Search.
- Scroll performance.
- Migration.
- History import.
- Prolonged memory use.
- Attachment-cache eviction.
- Sleep and wake.
- Large unread backlog processing.

---

# 20. Continuous Integration

## 20.1 Pull Request Gates

Every pull request runs:

```text
license-header-check
format-check
swift-lint
project-generation-check
mac-core-build
mac-app-build
mac-unit-tests
database-migration-tests
log-redaction-tests
dependency-lock-check
secret-scan
upstream-ios-build
```

Untrusted pull-request jobs must never receive signing credentials.

## 20.2 Nightly Gates

Nightly jobs:

- Full unit suite.
- Sanitizer runs.
- Large database tests.
- Sleep/wake testing on self-hosted hardware.
- Interoperability smoke tests where safely automated.
- Dependency vulnerability scan.
- Upstream merge rehearsal.
- Universal build.
- Unsigned reproducibility comparison.
- Attachment fuzz corpus.
- Long-running receive connection.
- Memory-leak checks.
- Search benchmarks.

## 20.3 Release Gates

A signed release tag triggers:

1. Clean checkout.
2. Verify signed Git tag.
3. Verify dependency manifest.
4. Build pinned dependencies.
5. Run release tests.
6. Archive the app.
7. Sign nested frameworks.
8. Sign extensions and XPC services.
9. Sign the application.
10. Verify entitlements.
11. Build the disk image.
12. Notarize.
13. Staple the ticket.
14. Verify Gatekeeper behavior.
15. Generate update signature.
16. Generate SBOM.
17. Publish corresponding source.
18. Publish beta update metadata.
19. Run canary rollout.
20. Promote to stable after validation.

---

# 21. Distribution and Updates

## 21.1 Direct Distribution First

Use Developer ID distribution before considering the Mac App Store.

Reasons:

- Protocol-compatibility updates can ship quickly.
- Beta and stable channels remain under project control.
- Staged rollouts are possible.
- App Store review delay does not block urgent compatibility fixes.
- The application can still use App Sandbox and Hardened Runtime.

## 21.2 Signing and Notarization

Release requirements:

- Developer ID Application certificate.
- Hardened Runtime.
- Timestamped signature.
- Correct signatures for every nested component.
- Minimal entitlements.
- Apple notarization.
- Stapled notarization ticket.
- Gatekeeper verification on a clean Mac.

## 21.3 Sparkle Updates

Use Sparkle 2.

Configure:

- Stable channel.
- Beta channel.
- HTTPS appcast.
- EdDSA update signatures.
- Apple code-signing verification.
- Staged rollout.
- Critical-update flag.
- Minimum-macOS metadata.
- Release notes.
- User-controlled automatic checks.
- Delta updates only after correctness is proven.

Protect the update private key separately from:

- GitHub.
- Public CI.
- Application source.
- Download hosting.
- Appcast hosting.
- Developer laptops used for ordinary work.

A compromised web host must not be enough to deliver a malicious update.

## 21.4 Mac App Store Later

Investigate only after:

- Messaging is stable.
- Background behavior is proven.
- Entitlements are understood.
- Update timing can tolerate review.
- Trademark presentation has been reviewed.
- AGPL obligations are fully documented.

Do not let App Store requirements distort the initial architecture.

---

# 22. Upstream Synchronization

## 22.1 Routine Sync Process

```bash
git fetch upstream --tags
git switch -c upstream-sync/2026-08-01 main
git merge --no-ff upstream/main
```

Then:

1. Resolve mechanical conflicts.
2. Update submodules.
3. Run upstream dependency setup.
4. Build original iOS targets.
5. Update compatibility manifest.
6. Review lockfile changes.
7. Review `libsignal` changes.
8. Review database migrations.
9. Review protobuf changes.
10. Review provisioning changes.
11. Review linked-device changes.
12. Review history-transfer changes.
13. Review group changes.
14. Review attachment changes.
15. Review RingRTC changes.
16. Build Mac targets.
17. Update portability ledger.
18. Run migration tests.
19. Run interop tests.
20. Merge into `main`.

## 22.2 High-Risk Upstream Changes

Immediate review is required for:

- `libsignal` version changes.
- Protocol or protobuf changes.
- Database migrations.
- Provisioning changes.
- Linked-device credential changes.
- Device-transfer changes.
- Group-state changes.
- Attachment format changes.
- Remote-configuration changes.
- Minimum-client-version behavior.
- RingRTC updates.
- Security fixes.
- Dependency checksum changes.

## 22.3 Compatibility Manifest

Every release should expose:

```json
{
  "app_version": "0.8.2",
  "upstream_signal_ios_commit": "abc123",
  "upstream_signal_desktop_reference": "7.x.y",
  "database_schema": 1234,
  "libsignal": "0.x.y",
  "ringrtc": "2.x.y",
  "minimum_macos": "14.0",
  "architectures": [
    "arm64",
    "x86_64"
  ]
}
```

## 22.4 Compatibility Dashboard

| Subsystem | Build | Unit tests | Interop | Notes |
|---|---:|---:|---:|---|
| Provisioning | Pass | Pass | Pass | — |
| Text messaging | Pass | Pass | Pass | — |
| Groups | Pass | Pass | Pass | — |
| Attachments | Pass | Pass | Pending | New format under test |
| History transfer | Pass | Fail | Blocked | Migration changed |
| Calls | Pass | Pass | Pending | RingRTC version bump |

Do not hide compatibility gaps to create a misleading all-green status page.

---

# 23. Project Management

## 23.1 Issue Labels

```text
area:app
area:core
area:database
area:provisioning
area:network
area:messages
area:groups
area:attachments
area:sync
area:calls
area:ui
area:platform
area:security
area:release
area:upstream

type:feature
type:bug
type:refactor
type:test
type:investigation
type:security

priority:critical
priority:high
priority:normal
priority:low

blocked:upstream
blocked:dependency
blocked:design
blocked:interop

risk:data-loss
risk:privacy
risk:compatibility
risk:performance
```

## 23.2 Issue Template

Every implementation issue answers:

```text
What user-visible behavior is required?
Which official client is the behavioral reference?
Which upstream files are involved?
Does the work alter persistent state?
Does the work alter protocol behavior?
Does it alter a security boundary?
What happens after a crash?
What happens after duplicate delivery?
What happens after downgrade?
What tests prove interoperability?
What diagnostic data is safe?
```

## 23.3 Architecture Decision Records

Require an ADR for:

- New persistent dependency.
- New entitlement.
- Schema change not inherited upstream.
- Cryptographic boundary.
- New background process.
- New network endpoint.
- Update-system change.
- Analytics or crash-reporting system.
- Compatibility-breaking decision.
- Intentional user-visible divergence from official Signal Desktop.

Initial ADRs:

```text
ADR-0001 Direct Signal-iOS fork
ADR-0002 Native macOS, no Catalyst
ADR-0003 Linked-device-only account model
ADR-0004 Separate Mac Xcode project
ADR-0005 Port SignalServiceKit, replace SignalUI
ADR-0006 PlatformKit dependency boundary
ADR-0007 Reuse upstream database schema
ADR-0008 Official libsignal only
ADR-0009 Persistent connection without production APNs
ADR-0010 Developer ID direct distribution
ADR-0011 Sparkle signed updates
ADR-0012 RingRTC calls deferred
```

---

# 24. Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| Upstream APIs change without notice | Critical | Pin versions, merge frequently, maintain interop suite |
| SignalServiceKit has hidden UIKit assumptions | High | Portability ledger and platform adapters |
| Native macOS `libsignal` packaging fails | Critical | Prove early before substantial UI work |
| Provisioning works but history transfer fails | High | Maintain no-transfer path |
| No production APNs credentials | Expected | Persistent connection and login startup |
| RingRTC lacks a ready native Mac bridge | High | Separate calls phase |
| Database migrations diverge | Critical | Reuse upstream schema and fixture tests |
| Malformed attachments exploit decoders | Critical | Sandboxed XPC worker |
| Update host is compromised | Critical | Signed updates and isolated keys |
| Trademark confusion | High | Independent identity and disclaimer |
| AGPL obligations are missed | High | Automated source-publication gate |
| Fork accumulates invasive patches | High | Patch budget and adapters |
| Beta update destroys history | Critical | Recovery snapshot and canary rollout |
| Main thread overload | Medium | AppKit timeline and async storage |
| Unknown message disappears | High | Preserve and show upgrade placeholder |
| Project turns into endless rewrite | High | Vertical slices and phase exit criteria |
| Official service rejects unofficial behavior | Critical | Stay aligned with upstream and fail clearly |
| Intel dependency support becomes costly | Medium | Ship Apple silicon first |
| Sandboxing blocks a required integration | Medium | Document and isolate exceptions |
| Update urgency exceeds test capacity | High | Automated release gates and compatibility canaries |

---

# 25. Definition of 1.0

The application is not 1.0 until all of the following are true.

## Account and Provisioning

- Fresh installation links by QR code.
- Optional initial history transfer works.
- Relinking is understandable.
- Unlinking deletes local data.
- Linked-device state survives restart.
- Invalid credentials are handled safely.

## Messaging

- One-to-one messaging.
- Group messaging.
- Delivery receipts.
- Read receipts.
- Typing indicators.
- Replies.
- Reactions.
- Mentions.
- Formatting.
- Edits.
- Deletes.
- Forwarding.
- Disappearing messages.
- View-once media.
- Pinned chats.
- Pinned messages.
- Polls.
- Member labels.
- Stickers.
- Link previews.
- Message requests.
- Safety-number changes.

## Media

- Images.
- Video.
- Audio.
- Voice notes.
- Documents.
- Animated media.
- Captions.
- Upload and download retry.
- Integrity verification.
- Native export.
- Quick Look.
- Safe out-of-process decoding.

## Synchronization

- Profiles.
- Contacts.
- Groups.
- Relevant settings.
- Block list.
- Read state.
- Archive and pin state.
- History import.
- Multi-device convergence.

## Calls

- One-to-one audio.
- One-to-one video.
- Group calls.
- Device selection.
- Screen sharing.
- Call links.
- Call history.
- Network recovery.

## Native Experience

- Native menus.
- Keyboard navigation.
- Notifications.
- Dock badge.
- Launch at login.
- Touch ID lock.
- Drag-and-drop.
- Share extension.
- Accessibility.
- Localization.
- Smooth large timelines.

## Reliability and Security

- Migration from every beta schema.
- Recovery from interrupted migration.
- No known plaintext private storage.
- No sensitive logs.
- Signed and notarized releases.
- Signed automatic updates.
- Matching source published.
- Threat model reviewed.
- Security-reporting process active.
- Performance budgets measured.
- Interoperability suite green against the release target.

---

# 26. First 20 Implementation Commits

1. `chore: record upstream baseline and toolchains`
2. `docs: add product definition and non-goals`
3. `docs: add AGPL attribution and branding policy`
4. `docs: add architecture decision records`
5. `ci: build untouched upstream iOS targets`
6. `build: add terminal-first justfile`
7. `build: create generated MacClient project`
8. `app: add sandboxed native macOS application shell`
9. `app: add lifecycle and account state machine`
10. `platform: introduce shared platform service protocols`
11. `platform: add initial macOS adapters`
12. `port: generate SignalServiceKit portability ledger`
13. `port: add SignalServiceKitMac compile target`
14. `crypto: build native macOS libsignal artifact`
15. `crypto: integrate LibSignalClientMac and upstream tests`
16. `storage: integrate GRDB and SQLCipher`
17. `storage: add Keychain-backed database bootstrap`
18. `provisioning: port provisioning socket and QR generation`
19. `provisioning: complete linked-device registration`
20. `messaging: receive and send one persisted text message`

Commit 20 is the first major viability gate. Before that, polished message bubbles, themes, and elaborate settings are distractions.

---

# 27. Immediate Blank-Repo-to-First-Message Checklist

Although the repository is a fork rather than literally blank, this is the shortest practical path from zero project-specific code to the first interoperable message.

## Step 1 — Fork and Validate Upstream

- Fork Signal-iOS.
- Clone with submodules.
- Add upstream remote.
- Run upstream dependency bootstrap.
- Build the original iOS targets.
- Record baseline versions.
- Tag the baseline.

## Step 2 — Add Project Governance

- Add product specification.
- Add license and attribution policy.
- Add independent branding policy.
- Add threat model.
- Add ADR system.
- Add upstream patch ledger.
- Add portability ledger.
- Add CI.

## Step 3 — Create Native Mac Shell

- Add generated Mac Xcode project.
- Add SwiftUI app.
- Add main window.
- Add settings window.
- Add menus.
- Add logging.
- Add account state machine.
- Add tests.

## Step 4 — Build Shared Core

- Audit `SignalServiceKit`.
- Introduce `PlatformKit`.
- Add macOS adapters.
- Compile portable core files.
- Exclude and document iOS-only files.
- Keep iOS targets passing.

## Step 5 — Build Native Cryptography

- Pin `libsignal`.
- Build macOS Rust FFI.
- Package XCFramework.
- Link Swift wrapper.
- Run tests.
- Add checksums and CI.

## Step 6 — Add Encrypted Storage

- Build GRDB.
- Build SQLCipher.
- Initialize upstream schema.
- Store key in Keychain.
- Add recovery and deletion.
- Add migration tests.

## Step 7 — Link the Device

- Port provisioning coordinator.
- Display QR code.
- Receive provisioning payload.
- Register linked device.
- Persist credentials.
- Reconnect after restart.

## Step 8 — Connect to the Service

- Start authenticated connection.
- Add retry.
- Add sleep/wake recovery.
- Add credential rejection handling.
- Add update-required handling.

## Step 9 — Receive One Message

- Receive envelope.
- Decrypt with `libsignal`.
- Parse content.
- Persist transactionally.
- Display in a minimal timeline.
- Generate a local notification.

## Step 10 — Send One Message

- Persist outbox item.
- Resolve recipient devices.
- Encrypt.
- Send.
- Update state.
- Verify receipt on an official client.

## Step 11 — Prove Durability

- Restart application.
- Confirm messages remain.
- Send another message.
- Test network loss.
- Test sleep and wake.
- Test duplicate envelope.
- Test failed send and retry.

Once all eleven steps pass, the project has a real foundation.

---

# 28. Recommended Team or Agent Workstreams

Even for a solo project using coding agents, separate work into clear ownership areas.

## Workstream A — Upstream and Build

Owns:

- Upstream synchronization.
- Project generation.
- Dependency manifests.
- Native library builds.
- CI.
- Release builds.
- Reproducibility.

## Workstream B — Core Portability

Owns:

- Portability ledger.
- Platform protocols.
- SignalServiceKitMac compilation.
- Removal of accidental UIKit dependencies.
- Shared tests.

## Workstream C — Storage and Reliability

Owns:

- SQLCipher.
- Keychain.
- Migrations.
- Recovery.
- Outbox.
- Inbox durability.
- Data deletion.
- Search indexes.

## Workstream D — Provisioning and Networking

Owns:

- QR linking.
- Device credentials.
- Authenticated service connection.
- Retry behavior.
- Sleep/wake.
- Upgrade-required behavior.

## Workstream E — Native UI

Owns:

- SwiftUI shell.
- AppKit timeline.
- Composer.
- Menus.
- Search.
- Settings.
- Accessibility.
- Notifications.

## Workstream F — Media

Owns:

- Attachment transfers.
- Media processing.
- XPC worker.
- Quick Look.
- Voice notes.
- View-once behavior.

## Workstream G — Calls

Owns:

- RingRTCMac.
- WebRTC.
- Device selection.
- Video rendering.
- Group calls.
- Screen sharing.

## Workstream H — Security and Release

Owns:

- Threat model.
- Diagnostics.
- Signing.
- Notarization.
- Sparkle.
- Vulnerability response.
- Source publication.

---

# 29. Hard Stop Conditions

Pause feature work and fix the foundation if any of these occur:

- Upstream iOS targets stop building because of Mac-port edits.
- Database migration cannot recover safely.
- A message can be lost after the user presses Send.
- Duplicate delivery creates duplicate visible messages.
- Unknown messages are discarded.
- Logs contain message or identity data.
- Release updater accepts an unsigned artifact.
- Provisioning leaves half-valid credentials.
- Delete Data leaves reusable account credentials.
- Attachment decoding can crash the main process.
- Sleep/wake requires relinking.
- A normal upstream merge takes weeks of manual repair.
- A new platform abstraction is bypassed by direct OS calls in core code.
- Calling changes destabilize messaging.

---

# 30. Final Architecture Decision

Use a direct Signal-iOS fork, preserve its history, and keep its iOS application buildable.

Treat the existing iOS UI as reference material, not as the application being ported.

The intended long-term structure is:

```text
Signal-iOS upstream history
        │
        ├── SignalServiceKit
        │       ├── portable shared behavior
        │       └── narrow platform abstractions
        │
        ├── original iOS application
        │       └── kept buildable as an upstream regression check
        │
        └── independent native macOS application
                ├── SwiftUI shell
                ├── AppKit timeline and composer
                ├── macOS PlatformKit
                ├── native libsignal
                ├── encrypted upstream-compatible storage
                ├── persistent linked-device networking
                └── later native RingRTC
```

The project succeeds by minimizing protocol invention, minimizing cryptographic risk, minimizing divergence from upstream storage semantics, and maximizing native macOS quality.

The first objective is brutally specific:

```text
link
→ receive
→ decrypt
→ persist
→ display
→ reply
→ restart
→ repeat
```

Everything else should be built on top of that proven path.
