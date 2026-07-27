#!/usr/bin/env bash

# Shared Swift toolchain selection for repository scripts.
#
# Precedence:
#   1. VELA_SWIFT_BIN, when explicitly set.
#   2. Swiftly's selected toolchain, when Swiftly and a toolchain are available.
#   3. `swift` from PATH.

vela_select_swift() {
    if [[ -n "${VELA_SWIFT_BIN:-}" ]]; then
        [[ -x "$VELA_SWIFT_BIN" ]] || {
            echo "VELA_SWIFT_BIN is not executable: $VELA_SWIFT_BIN" >&2
            return 1
        }
    elif command -v swiftly >/dev/null 2>&1; then
        local swiftly_toolchain
        swiftly_toolchain="$(swiftly use --print-location 2>/dev/null || true)"
        if [[ -x "$swiftly_toolchain/usr/bin/swift" ]]; then
            VELA_SWIFT_BIN="$swiftly_toolchain/usr/bin/swift"
        fi
    fi

    if [[ -z "${VELA_SWIFT_BIN:-}" ]]; then
        VELA_SWIFT_BIN="$(command -v swift || true)"
    fi
    [[ -n "$VELA_SWIFT_BIN" && -x "$VELA_SWIFT_BIN" ]] || {
        echo 'Swift is missing. Install Swift 6.1 or newer, then rerun this command.' >&2
        return 1
    }

    VELA_SWIFTC_BIN="${VELA_SWIFTC_BIN:-$(dirname "$VELA_SWIFT_BIN")/swiftc}"
    [[ -x "$VELA_SWIFTC_BIN" ]] || VELA_SWIFTC_BIN="$(command -v swiftc || true)"
    [[ -n "$VELA_SWIFTC_BIN" && -x "$VELA_SWIFTC_BIN" ]] || {
        echo "swiftc is missing beside selected Swift executable: $VELA_SWIFT_BIN" >&2
        return 1
    }

    local version_output
    local version_major
    local version_minor
    version_output="$("$VELA_SWIFT_BIN" --version | head -n 1)"
    if [[ "$version_output" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
        version_major="${BASH_REMATCH[1]}"
        version_minor="${BASH_REMATCH[2]}"
    else
        echo "Cannot parse selected Swift version: $version_output" >&2
        return 1
    fi
    if (( version_major < 6 || (version_major == 6 && version_minor < 1) )); then
        echo "Swift 6.1 or newer is required; selected toolchain reports: $version_output" >&2
        return 1
    fi
    export VELA_SWIFT_BIN VELA_SWIFTC_BIN
}

vela_prepare_swift_build() {
    local package_root="${1:?package root required}"
    local scratch_path="${2:-$package_root/.build/vela-selected}"
    local marker="$scratch_path/.vela-toolchain"
    local fingerprint
    local swift_version
    local package_fingerprint
    local stale=0

    swift_version="$("$VELA_SWIFT_BIN" --version)"
    if command -v shasum >/dev/null 2>&1; then
        package_fingerprint="$(shasum -a 256 "$package_root/Package.swift")"
        if [[ -f "$package_root/Package.resolved" ]]; then
            package_fingerprint+="|$(shasum -a 256 "$package_root/Package.resolved")"
        else
            package_fingerprint+='|Package.resolved: absent'
        fi
    elif command -v sha256sum >/dev/null 2>&1; then
        package_fingerprint="$(sha256sum "$package_root/Package.swift")"
        if [[ -f "$package_root/Package.resolved" ]]; then
            package_fingerprint+="|$(sha256sum "$package_root/Package.resolved")"
        else
            package_fingerprint+='|Package.resolved: absent'
        fi
    else
        echo 'A SHA-256 tool (shasum or sha256sum) is required.' >&2
        return 1
    fi
    fingerprint="$({ printf '%s\n' "$swift_version"; printf 'executable: %s\n' "$VELA_SWIFT_BIN"; printf 'package: %s\n' "$package_fingerprint"; } | tr '\n' '|')"
    if [[ -d "$scratch_path" && -n "$(find "$scratch_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        if [[ ! -f "$marker" || "$(cat "$marker")" != "$fingerprint" ]]; then
            stale=1
        else
            # Direct `swift build` calls do not update our marker. SwiftPM does
            # record compiler identity in these files, so reject any artifact
            # set containing output from another compiler.
            while IFS= read -r -d '' version_file; do
                if [[ "$(cat "$version_file")" != "$swift_version" ]]; then
                    stale=1
                    break
                fi
            done < <(find "$scratch_path" -type f -name 'swift-version--*.txt' -print0)
        fi
        if (( stale )); then
            printf 'Swift toolchain changed; cleaning stale SwiftPM artifacts in %s\n' "$scratch_path"
            "$VELA_SWIFT_BIN" package --package-path "$package_root" --scratch-path "$scratch_path" clean
        fi
    fi
    mkdir -p "$scratch_path"
    printf '%s\n' "$fingerprint" > "$marker"
    VELA_SCRATCH_PATH="$scratch_path"
    export VELA_SCRATCH_PATH
}
