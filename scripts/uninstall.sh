#!/bin/bash
# Remove an installed Graft.app.
#
#   make uninstall                 # keep app data and generated wrappers
#   make uninstall PURGE=1         # also remove ~/Library/Application Support/Graft
#
# Generated macOS shortcuts in ~/Applications/AquaLinux Apps are never removed
# automatically; they are user data.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
PURGE="${PURGE:-0}"
TARGET="$INSTALL_DIR/Graft.app"

if pgrep -x Graft >/dev/null 2>&1; then
    osascript -e 'tell application "Graft" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x Graft >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -x Graft >/dev/null 2>&1 || true
    sleep 0.3
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ] && [ -d "$TARGET" ]; then
    "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
fi

rm -rf "$TARGET"
echo "Removed: $TARGET"

if [ "$PURGE" = "1" ]; then
    rm -rf "$HOME/Library/Application Support/Graft"
    rm -rf "$HOME/Library/Logs/Graft"
    defaults delete app.graft.menubar >/dev/null 2>&1 || true
    echo "Purged app data and preferences."
fi

echo "Generated shortcuts in ~/Applications/AquaLinux Apps were kept."
