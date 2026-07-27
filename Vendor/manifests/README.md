# Pinned upstream manifests

`signal-ios.json` is the compatibility baseline used by this snapshot. Do not
change one dependency independently: Signal-iOS, libsignal, RingRTC, SQLCipher,
and generated protocol code must move as a tested set.

The archive deliberately does not duplicate the roughly multi-gigabyte
Signal-iOS Git repository. Use `Scripts/vendor-signal-ios.sh` for a local
reference checkout, or `Scripts/bootstrap-direct-fork.sh` to install this code
inside a direct fork while preserving upstream history and submodules.
