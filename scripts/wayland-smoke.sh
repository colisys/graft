#!/usr/bin/env bash
# Minimal Linux-side Wayland smoke test for the experimental backend.
#
# This does NOT prove that Graft can display Wayland windows on macOS yet:
# the macOS Wayland compositor is still unimplemented. It proves that the
# container side has a working compositor + client and that the protocol
# surface Graft will need (wl_compositor, xdg_wm_base, wl_shm, output, ...)
# is available. The headless backend does not provide an input seat.
set -euo pipefail

DOCKER="${DOCKER:-docker}"
IMAGE="${WAYLAND_SMOKE_IMAGE:-archlinux:latest}"

exec "$DOCKER" run --rm \
  --name graft-wayland-smoke \
  "$IMAGE" bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
pacman -Sy --noconfirm --needed weston wayland-utils >/tmp/graft-wayland-pacman.log 2>&1 || {
  cat /tmp/graft-wayland-pacman.log
  exit 1
}

export XDG_RUNTIME_DIR=/tmp/graft-wl-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

weston --backend=headless-backend.so --socket=wayland-0 --idle-time=0 >/tmp/graft-weston.log 2>&1 &
WESTON_PID=$!
trap "kill $WESTON_PID 2>/dev/null || true" EXIT

for _ in $(seq 1 40); do
  [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break
  sleep 0.25
done
if [ ! -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
  echo "WESTON_FAILED"
  cat /tmp/graft-weston.log
  exit 1
fi

echo "WESTON_SOCKET_OK"
WAYLAND_DISPLAY=wayland-0 wayland-info | sed -n "1,80p"
echo "WAYLAND_SMOKE_OK"
'