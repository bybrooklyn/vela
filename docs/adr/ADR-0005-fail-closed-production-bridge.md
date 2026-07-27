# ADR-0005: Fail-Closed Production Bridge

**Status:** Accepted

When Signal-iOS/libsignal adapters are absent, production provisioning, service
transport, encryption, recipient routing, attachments, history transfer, and
calls throw explicit integration-required errors. The app never substitutes a
home-grown or plaintext production implementation.
