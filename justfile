set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Verify prerequisites and build the app without Xcode.
bootstrap:
    ./Scripts/macOS/bootstrap.sh

# Build and test the core Swift package.
core:
    ./Scripts/verify.sh

# Build and test the core package with release optimization.
release-core:
    ./Scripts/verify-release.sh

# Run AddressSanitizer and ThreadSanitizer over the core test suite.
sanitizers:
    ./Scripts/verify-sanitizers.sh

# Run every verification available on the current machine.
verify:
    ./Scripts/verify.sh

# Build build/Vela.app with SwiftPM and Command Line Tools. Full Xcode is not required.
build:
    bash -c 'source ./Scripts/swift-toolchain.sh; vela_select_swift; SWIFT_BIN="$VELA_SWIFT_BIN" ./Scripts/macOS/build.sh'

# Build and immediately launch Vela.app. Full Xcode is not required.
run:
    ./Scripts/macOS/run.sh

# Generate the optional Xcode project. This is not needed for normal builds.
project:
    ./Scripts/macOS/generate-project.sh

# Build through Xcode instead of SwiftPM, for contributors who have Xcode.
build-xcode:
    ./Scripts/macOS/build-xcode.sh

# Test the optional Xcode project and portable package.
test-xcode:
    ./Scripts/macOS/test.sh

# Run the end-to-end terminal loopback client.
demo:
    bash -c 'source ./Scripts/swift-toolchain.sh; vela_select_swift; vela_prepare_swift_build "$PWD"; "$VELA_SWIFT_BIN" run --scratch-path "$VELA_SCRATCH_PATH" vela-demo'

# Fetch the pinned Signal-iOS baseline and all submodules.
vendor-signal:
    ./Scripts/vendor-signal-ios.sh

# Create a clean source ZIP. Usage: just source-archive 0.1.2
source-archive version="development":
    ./Scripts/source-archive.sh "{{ version }}"

# Extract, checksum, and rebuild/test a source ZIP.
verify-archive archive:
    ./Scripts/verify-archive.sh "{{ archive }}"

# Create a signed Xcode archive. DEVELOPMENT_TEAM must be set.
archive:
    ./Scripts/macOS/archive.sh
