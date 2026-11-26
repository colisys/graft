#!/bin/bash
# Install a previously built dist/Graft.app into INSTALL_DIR.
#
# Default: ~/Applications (no administrator privileges required).
# For a system-wide install:
#   sudo make install INSTALL_DIR=/Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/Graft.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
TARGET="$INSTALL_DIR/Graft.app"

if [ ! -d "$SOURCE_APP" ]; then
    echo "error: $SOURCE_APP not found. Run 'make app' first." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
if [ ! -w "$INSTALL_DIR" ]; then
    echo "error: $INSTALL_DIR is not writable." >&2
    echo "       Try: sudo make install INSTALL_DIR=/Applications" >&2
    exit 1
fi

# Stop a running instance before replacing the bundle.
if pgrep -x Graft >/dev/null 2>&1; then
    osascript -e 'tell application "Graft" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x Graft >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -x Graft >/dev/null 2>&1 || true
    sleep 0.3
fi

rm -rf "$TARGET"
ditto "$SOURCE_APP" "$TARGET"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
fi

echo "Installed: $TARGET"
echo "Open:      open \"$TARGET\""
