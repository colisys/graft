#!/bin/bash
# Build Graft.app (menu bar application bundle).
#
# By default this builds a universal binary (arm64 + x86_64). Set
# GRAFT_UNIVERSAL=0 to build only the host architecture, or GRAFT_ARCHS to
# override the architecture list.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"

cd "$ROOT"

if [ "${GRAFT_UNIVERSAL:-1}" = "1" ]; then
    ARCHS="${GRAFT_ARCHS:-arm64 x86_64}"
    ARCH_FLAGS=()
    for arch in $ARCHS; do
        ARCH_FLAGS+=(--arch "$arch")
    done
    echo "Building universal binary ($ARCHS)…"
    if ! swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"; then
        echo "Universal build failed; falling back to the host architecture." >&2
        swift build -c "$CONFIG"
        ARCH_FLAGS=()
    fi
else
    ARCH_FLAGS=()
    swift build -c "$CONFIG"
fi

BIN_PATH="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path 2>/dev/null || true)"
if [ -z "$BIN_PATH" ] || [ ! -x "$BIN_PATH/Graft" ]; then
    BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
fi

APP="$ROOT/dist/Graft.app"
STAGE="$ROOT/dist/.Graft.app.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN_PATH/Graft" "$STAGE/Contents/MacOS/Graft"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/LICENSE" "$STAGE/Contents/Resources/LICENSE"

# Linux XRandR refresh shim (Graft-owned, GPL). Rootless XQuartz reports a
# hard-coded 1 Hz mode; the shim presents the selected macOS refresh rate to
# X11 clients inside the container.
mkdir -p "$STAGE/Contents/Resources/Shims"
if compgen -G "$ROOT/Resources/Shims/*.so" >/dev/null; then
    cp "$ROOT/Resources/Shims/"*.so "$STAGE/Contents/Resources/Shims/"
else
    echo "warning: no XRandR shim binaries found; capped refresh rate will fall back." >&2
fi

# Native launcher embedded into generated .app wrappers. It makes LaunchServices
# see a real AppKit executable instead of a shell script, so the Dock icon
# stops bouncing after the app finishes launching.
if [ -x "$BIN_PATH/GraftLauncher" ]; then
    cp "$BIN_PATH/GraftLauncher" "$STAGE/Contents/Resources/GraftLauncher"
    chmod 0755 "$STAGE/Contents/Resources/GraftLauncher"
else
    echo "warning: GraftLauncher was not built; generated apps will use shell launchers." >&2
fi

# Copy any SwiftPM resource bundles produced for GraftCore.
for bundle in "$BIN_PATH"/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$STAGE/Contents/Resources/"
    fi
done

# Ad-hoc signing keeps macOS happy on the local machine. Distribution builds
# should use a Developer ID certificate and notarization.
codesign --force --deep --sign - "$STAGE" >/dev/null 2>&1 || true

rm -rf "$APP"
mv "$STAGE" "$APP"

echo "Built: $APP"
echo "Architecture: $(lipo -archs "$APP/Contents/MacOS/Graft" 2>/dev/null || file -b "$APP/Contents/MacOS/Graft")"
echo "Run: open \"$APP\""
