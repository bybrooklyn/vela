# Upstream Policy

The target repository is a direct fork of `signalapp/Signal-iOS` with complete
history and submodules. Vela-owned modules should be added beside upstream code;
the existing iOS products remain buildable as regression checks.

## Remotes

```text
origin    your Signal-iOS fork
upstream  https://github.com/signalapp/Signal-iOS.git
```

## Merge process

```bash
git fetch upstream --tags
git switch -c upstream-sync/$(date +%Y-%m-%d) main
git merge --no-ff upstream/main
git submodule update --init --recursive
make dependencies
./Scripts/verify.sh
```

Review these changes manually before merging:

- libsignal pin changes.
- SignalServiceKit database migrations.
- Protobuf or message-content changes.
- Provisioning/link-and-sync changes.
- Linked-device credential changes.
- Group-state revisions.
- Attachment formats.
- Minimum-client-version logic.
- RingRTC updates.
- Security fixes.

Every persistent edit to an upstream-owned file must be recorded in
`docs/porting/UPSTREAM_PATCHES.md`.
