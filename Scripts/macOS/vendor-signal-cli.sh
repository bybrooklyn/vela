#!/usr/bin/env bash
set -euo pipefail

# Vendors the signal-cli backend that Vela.app embeds.
#
#   Vendor/Artifacts/signal-cli/signal-cli          single native executable
#   Vendor/Artifacts/signal-cli/lib/native/*.dylib  code-signed JNI libraries
#
# signal-cli is compiled ahead of time with GraalVM native-image, so the app
# ships one binary instead of a Java runtime plus ~70 jars. That removes the JIT
# and unsigned-executable-memory entitlements a JVM would require.
#
# The two JNI libraries cannot be compiled into the image. They are lifted out of
# their jars so `build.sh` can code-sign them: left inside, their loaders extract
# unsigned copies into a temp directory at runtime, which Gatekeeper blocks.
#
# The first run downloads GraalVM and compiles for several minutes. Everything is
# cached, so later runs are fast.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/Vendor/manifests/signal-cli.json"
ARTIFACTS="$ROOT/Vendor/Artifacts"
CACHE="$ARTIFACTS/cache"
DEST="$ARTIFACTS/signal-cli"
SOURCE_DIR="$ARTIFACTS/signal-cli-src"
GRAALVM_DIR="$ARTIFACTS/graalvm"

NATIVE_LIB="libsignal_jni_aarch64.dylib"
LOADED_LIB="libsignal_jni.dylib"
SQLITE_LIB_PATH="org/sqlite/native/Mac/aarch64/libsqlitejdbc.dylib"
SQLITE_LIB="libsqlitejdbc.dylib"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The embedded backend is built for macOS." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This script targets arm64. Update the manifest to build elsewhere." >&2
    exit 1
fi
[[ -f "$MANIFEST" ]] || { echo "Missing manifest: $MANIFEST" >&2; exit 1; }

read -r VERSION ARCHIVE SHA256 TAG REPO GRAALVM_URL < <(python3 - "$MANIFEST" <<'PY'
import json, pathlib, sys
m = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(m["version"], m["archive"], m["archive_sha256"], m["release_tag"],
      m["repository"], m["graalvm"]["url"])
PY
)

mkdir -p "$CACHE"

# --- GraalVM toolchain -------------------------------------------------------
if [[ ! -x "$GRAALVM_DIR/Contents/Home/bin/native-image" ]]; then
    GRAALVM_ARCHIVE="$CACHE/graalvm.tar.gz"
    if [[ ! -f "$GRAALVM_ARCHIVE" ]]; then
        printf 'Downloading GraalVM\n'
        curl --fail --location --progress-bar --output "$GRAALVM_ARCHIVE" "$GRAALVM_URL"
    fi
    printf 'Extracting GraalVM\n'
    rm -rf "$GRAALVM_DIR"
    mkdir -p "$GRAALVM_DIR"
    tar xzf "$GRAALVM_ARCHIVE" -C "$GRAALVM_DIR" --strip-components=1
fi
export GRAALVM_HOME="$GRAALVM_DIR/Contents/Home"
export JAVA_HOME="$GRAALVM_HOME"

# --- JNI libraries from the released jars ------------------------------------
ARCHIVE_PATH="$CACHE/$ARCHIVE"
verify_checksum() {
    [[ "$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')" == "$SHA256" ]]
}
if [[ -f "$ARCHIVE_PATH" ]] && verify_checksum; then
    printf 'Using cached %s\n' "$ARCHIVE"
else
    printf 'Downloading %s\n' "$ARCHIVE"
    curl --fail --location --progress-bar --output "$ARCHIVE_PATH" \
        "$REPO/releases/download/$TAG/$ARCHIVE"
    verify_checksum || {
        echo "Checksum mismatch for $ARCHIVE (expected $SHA256)." >&2
        rm -f "$ARCHIVE_PATH"
        exit 1
    }
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$ARCHIVE_PATH" -C "$STAGE"
SRC="$STAGE/signal-cli-$VERSION"
[[ -d "$SRC" ]] || { echo "Unexpected archive layout: $SRC missing" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/lib/native"

printf 'Extracting JNI libraries for code signing\n'
LIBSIGNAL_JAR="$(find "$SRC/lib" -name 'libsignal-client-*.jar' -print -quit)"
[[ -n "$LIBSIGNAL_JAR" ]] || { echo "libsignal-client jar not found" >&2; exit 1; }
unzip -q -o -j "$LIBSIGNAL_JAR" "$NATIVE_LIB" -d "$DEST/lib/native"
# The jar resource is architecture-suffixed, but the System.loadLibrary fallback
# asks for the plain name.
mv "$DEST/lib/native/$NATIVE_LIB" "$DEST/lib/native/$LOADED_LIB"

SQLITE_JAR="$(find "$SRC/lib" -name 'sqlite-jdbc-*.jar' -print -quit)"
[[ -n "$SQLITE_JAR" ]] || { echo "sqlite-jdbc jar not found" >&2; exit 1; }
unzip -q -o -j "$SQLITE_JAR" "$SQLITE_LIB_PATH" -d "$DEST/lib/native"

# --- Native image ------------------------------------------------------------
if [[ -d "$SOURCE_DIR/.git" ]]; then
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$TAG" >/dev/null 2>&1 || true
    git -C "$SOURCE_DIR" checkout --force --detach FETCH_HEAD >/dev/null 2>&1 \
        || git -C "$SOURCE_DIR" checkout --force "$TAG" >/dev/null 2>&1
else
    printf 'Cloning signal-cli %s\n' "$TAG"
    rm -rf "$SOURCE_DIR"
    git clone --depth 1 --branch "$TAG" "$REPO.git" "$SOURCE_DIR" 2>&1 | tail -1
fi

# Injected rather than kept as a patch file so it survives upstream edits to the
# surrounding build script. Idempotent: the marker guards re-application.
BUILD_FILE="$SOURCE_DIR/build.gradle.kts"
if ! grep -q 'VELA-BUILD-ARGS' "$BUILD_FILE"; then
    printf 'Applying Vela native-image build arguments\n'
    python3 - "$BUILD_FILE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor = 'buildArgs.add("--enable-native-access=ALL-UNNAMED")'
if anchor not in text:
    raise SystemExit("Could not find the native-image buildArgs block to extend.")
addition = anchor + "\n" + "\n".join([
    '            // VELA-BUILD-ARGS',
    '            buildArgs.add("-Os")',
    '            buildArgs.add("-H:ExcludeResources=.*libsignal_jni.*\\\\.dylib")',
    '            buildArgs.add("-H:ExcludeResources=.*org/sqlite/native/.*")',
])
path.write_text(text.replace(anchor, addition, 1))
PY
fi

# See Vendor/patches/0001-tolerate-disabled-signal-handling.patch for why.
SHUTDOWN_FILE="$SOURCE_DIR/src/main/java/org/asamk/signal/Shutdown.java"
if ! grep -q 'VELA-SIGNAL-PATCH' "$SHUTDOWN_FILE"; then
    printf 'Patching Shutdown.installHandler for sandboxed native images\n'
    python3 - "$SHUTDOWN_FILE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
original = """        Signal.handle(new Signal("INT"), Shutdown::handleSignal);
        Signal.handle(new Signal("TERM"), Shutdown::handleSignal);"""
if original not in text:
    raise SystemExit("Could not find the signal handler registration to patch.")
replacement = """        // VELA-SIGNAL-PATCH: signal handling is unavailable in a sandboxed
        // GraalVM native image. The shutdown hook below still runs.
        try {
            Signal.handle(new Signal("INT"), Shutdown::handleSignal);
            Signal.handle(new Signal("TERM"), Shutdown::handleSignal);
        } catch (IllegalArgumentException | UnsupportedOperationException e) {
            logger.debug("Signal handlers unavailable; relying on the shutdown hook.", e);
        }"""
path.write_text(text.replace(original, replacement, 1))
PY
fi

printf 'Compiling signal-cli with GraalVM native-image (several minutes)\n'
(cd "$SOURCE_DIR" && ./gradlew nativeCompile --no-daemon --quiet)

BINARY="$SOURCE_DIR/build/native/nativeCompile/signal-cli"
[[ -x "$BINARY" ]] || { echo "native-image did not produce $BINARY" >&2; exit 1; }
install -m 755 "$BINARY" "$DEST/signal-cli"

# --- Verification ------------------------------------------------------------
printf 'Verifying the vendored backend\n'
for lib in "$LOADED_LIB" "$SQLITE_LIB"; do
    path="$DEST/lib/native/$lib"
    [[ -f "$path" ]] || { echo "Missing $path." >&2; exit 1; }
    file -b "$path" | grep -q 'Mach-O.*arm64' || {
        echo "$path is not an arm64 Mach-O library." >&2
        exit 1
    }
done

ACTUAL_VERSION="$("$DEST/signal-cli" --version)"
[[ "$ACTUAL_VERSION" == "signal-cli $VERSION" ]] || {
    echo "Expected 'signal-cli $VERSION', got '$ACTUAL_VERSION'." >&2
    exit 1
}

# The image must not carry a copy of the JNI libraries, or its loader would
# extract an unsigned one at runtime in preference to the signed file.
if strings -a "$DEST/signal-cli" | grep -q 'libsignal_jni_aarch64.dylib'; then
    echo "The native image still embeds libsignal; the unsigned copy would win." >&2
    exit 1
fi

printf '\nVendored:\n'
printf '  %s (%s)\n' "$DEST/signal-cli" "$(du -h "$DEST/signal-cli" | awk '{print $1}')"
printf '  %s JNI libraries\n' "$(find "$DEST/lib/native" -name '*.dylib' | wc -l | tr -d ' ')"
