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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Graft" "$APP/Contents/MacOS/Graft"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

# Native launcher embedded into generated .app wrappers. It makes LaunchServices
# see a real AppKit executable instead of a shell script, so the Dock icon
# stops bouncing after the app finishes launching.
if [ -x "$BIN_PATH/GraftLauncher" ]; then
    cp "$BIN_PATH/GraftLauncher" "$APP/Contents/Resources/GraftLauncher"
    chmod 0755 "$APP/Contents/Resources/GraftLauncher"
else
    echo "warning: GraftLauncher was not built; generated apps will use shell launchers." >&2
fi

# Copy any SwiftPM resource bundles produced for GraftCore.
for bundle in "$BIN_PATH"/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP/Contents/Resources/"
    fi
done

# Ad-hoc signing keeps macOS happy on the local machine. Distribution builds
# should use a Developer ID certificate and notarization.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
echo "Architecture: $(lipo -archs "$APP/Contents/MacOS/Graft" 2>/dev/null || file -b "$APP/Contents/MacOS/Graft")"
echo "Run: open \"$APP\""
