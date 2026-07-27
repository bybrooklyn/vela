# Signal-iOS checkout placeholder

This directory is intentionally empty in the portable source archive.

Populate the pinned upstream source and its submodules with:

```bash
./Scripts/vendor-signal-ios.sh
```

The expected commit and dependency versions are recorded in
`Vendor/manifests/signal-ios.json`.

For the long-lived project, prefer creating a direct fork and running:

```bash
SIGNAL_IOS_FORK=git@github.com:YOUR_ACCOUNT/Signal-iOS.git \
  ./Scripts/bootstrap-direct-fork.sh ../Vela-Signal-iOS
```
