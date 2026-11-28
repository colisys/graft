#!/usr/bin/env python3
"""One-shot Intel HVF → Wayland SHM → ext4 DAX → AppKit smoke test."""
import argparse
from collections import Counter
from collections.abc import Iterator
from contextlib import ExitStack, contextmanager, suppress
import hashlib
import json
import mmap
import os
from pathlib import Path
from select import PIPE_BUF
import selectors
import shutil
import socket
import struct
import threading
import math
import re
import subprocess as sp
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
SIDECAR = HERE.parents[2] / '.agents/skills/protocol-diagnostics/sidecar.py'
ISO_SHA = 'f6a265f0696d328c8f87814a0d6bfa362d1434e500cb80a48796b1c9d204cee0'
APK_BASE = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/'
PACKAGES = {
    'libxkbcommon-dev-1.8.1-r2.apk': '568648d7f0a85203a1e963e3351d9d044e4b2a1ed38d2e4d1e48fc2a69a26782',
    'libxkbcommon-1.8.1-r2.apk': '8b7424f706e47e9e1123acb625323816191499334fcfc2ecae2d1a03805866b7',
    'wayland-dev-1.23.1-r3.apk': 'f1c36a2b5293f9cfac82e43b7f8379b26bec3261b97b34796e35be82832d45a0',
    'wayland-libs-client-1.23.1-r3.apk': '1772469c9f58e9ae06c03905a42844fb87cc060c16555c6182c4015fd19c46fa',
    'wayland-libs-server-1.23.1-r3.apk': '4e799eaec00a74f5a268e36b8985353fbb6be17442d5fecf825b2e7fb0ac2e4a',
    'libffi-3.8.1-r0.apk': '331f557dc1836cd92b1874d49c0f02b2ba24573e75e1d56a758a7d2bfc7ac9dc',
}
MARKER = b'SCLEREID-M2-DAX-FRAME-REGION-V1!'
FRAME_BYTES = 64 * 48 * 4
REGION_BYTES = 32 << 20


def verify(path, expected):
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(f'SHA-256 mismatch: {path}')


def build(work, packages, weston, gtk=False):
    headers = work / 'deps'
    headers.mkdir()

    def fetch(name, digest, repo='main'):
        apk = packages / name if packages else work / name
        if not packages:
            sp.run(['curl', '-fLsS', '--retry', '2', '--retry-all-errors',
                    '--retry-max-time', '90', '--max-time', '60',
                    f'{APK_BASE}{repo}/x86_64/{name}', '-o', apk], check=True, timeout=155)
        verify(apk, digest)
        return apk

    for name, digest in PACKAGES.items():
        sp.run(['bsdtar', '-xf', fetch(name, digest), '-C', headers], check=True)
    lib = headers / 'usr/lib'
    # Alpine's Wayland static archives contain GCC LTO objects, not usable by Zig/LLD.
    bundle = work / 'bundle'
    bundle.mkdir()
    libs = [lib / name for name in ('libwayland-client.so.0', 'libwayland-server.so.0', 'libffi.so.8', 'libxkbcommon.so.0')]
    sp.run(['zig', 'cc', '-target', 'x86_64-linux-musl', '-dynamic', '-std=c11', '-O2',
            '-Wall', '-Wextra', '-Werror', '-I', headers / 'usr/include',
            HERE / 'sclereid-m2-guest.c', *libs, '-o', bundle / 'bridge'],
           cwd=work, check=True, timeout=120)
    for library in libs:
        (bundle / library.name).write_bytes(library.read_bytes())
    if weston:
        from sclereid_m2_west import stage
        stage(bundle, fetch)
    sp.run(['bsdtar', '-czf', work / 'guest.tar', '--format', 'ustar', '-C', bundle, '.'], check=True)
    if gtk:
        runtime = work / 'gtk'
        runtime.mkdir()
        for entry in (HERE / 'sclereid-m2-gtk.lock').read_text().splitlines():
            digest, repo, name = entry.split()
            sp.run(['bsdtar', '-xf', fetch(name, digest, repo), '-C', runtime], check=True)
        shutil.copytree(runtime / 'usr/share/X11/xkb', bundle / 'xkb')
        for library in (runtime / 'usr/lib').glob('*.so.*'):
            if library.is_file() and not (bundle / library.name).exists():
                (bundle / library.name).write_bytes(library.read_bytes())
        sp.run(['zig', 'cc', '-target', 'x86_64-linux-musl', '-dynamic', '-O2', '-s',
                HERE / 'sclereid-m2-gtk.c', '-o', bundle / 'gtk-client'], cwd=work, check=True, timeout=120)
        sp.run(['bsdtar', '-czf', work / 'gtk.tar', '--format', 'ustar', '-C', bundle, '.'], check=True)
    sp.run(['swiftc', '-O', HERE / 'sclereid-m2-window.swift', '-o', work / 'window'],
           cwd=work, check=True, timeout=90)


class Diagnostics:
    def __init__(self):
        self.pipe = None
        self.issues = Counter()

    @contextmanager
    def collect(self, port):
        if port is not None:
            try:
                if not SIDECAR.is_file():
                    raise FileNotFoundError(SIDECAR)
                # No Popen context manager: it would wait for the query server.
                proc = sp.Popen(['python3', SIDECAR, '--port', str(port)], stdin=sp.PIPE,
                                stdout=sp.DEVNULL, stderr=sp.DEVNULL,
                                bufsize=0, start_new_session=True)
                self.pipe = proc.stdin
                os.set_blocking(self.pipe.fileno(), False)
            except (OSError, ValueError):
                self.close()
                with suppress(OSError):
                    print(f'M2 diagnostics unavailable: could not start {SIDECAR}', file=sys.stderr)
            else:
                with suppress(OSError):
                    print(f'M2 diagnostics URL: http://localhost:{port}/', file=sys.stderr, flush=True)
        try:
            yield self
        finally:
            for (source, level, event), count in self.issues.items():
                self.emit(level, source, event, f'{count} matching diagnostic lines',
                          action='inspect_local_diagnostics')
            self.issues.clear()
            self.close()

    def close(self):
        if self.pipe is not None:
            with suppress(OSError):
                self.pipe.close()
            self.pipe = None

    def emit(self, level, source, event, message, *, file='sclereid-m2.py', line=None, action=None):
        if self.pipe is None:
            return
        record = (json.dumps(dict(level=level, source=source, event=event, message=message,
                                  file=file, line=line, action=action)) + '\n').encode()
        # With O_NONBLOCK, writes no larger than PIPE_BUF are all-or-nothing.
        if len(record) <= PIPE_BUF:
            try:
                os.write(self.pipe.fileno(), record)
            except BlockingIOError:
                pass
            except (OSError, ValueError):
                self.close()

    def failure(self, phase, error):
        if self.pipe is None:
            return
        line = None
        tb = error.__traceback__
        while tb is not None:
            if tb.tb_frame.f_code.co_filename == __file__:
                line = tb.tb_lineno
            tb = tb.tb_next
        level = 'warning' if isinstance(error, KeyboardInterrupt) else 'fatal'
        # Exception arguments and notes may contain serial tails or host input.
        self.emit(level, 'driver', phase, f'{phase}: {type(error).__name__}',
                  line=line, action='inspect_local_diagnostics')


SERIAL_EVENTS = set(b'''
    M2_MODULES_READY M2_FORMATTED M2_MOUNTED GUEST_READY BETWEEN_SESSIONS
    GTK_WAYLAND_CONNECTED GTK_MENU_CLIENT_EXIT_OK GTK_MENU_GUEST_CLEAN GTK_CLEAN
    FIXTURE_REPAINT_QUEUED FIXTURE_POPUP_DONE FIXTURE_TEARDOWN_QUEUED
    FIXTURE_PARENT_FIRST_DONE ABRUPT_CLEAN SHARED_CLEAN POPUP_GUEST_CLEAN
    GUEST_CLEANUP_OK ANIM_STATS GTK_MENU GTK_MENU_EDGE GTK_GRAB
'''.split())
HOST_EVENTS = set(b'''
    WINDOW_OK RETINA_OK LAYER_OK FRAME_OK GEOMETRY REMAPPED POPUP_ORIGIN
    PARENT_OK POPUP_OK MOVE_OK EDGE_OK TREE_POPUP_OK TREE_FRAME_OK
    CLOSE_OK TREE_CLOSE_OK COMMAND_OK WORKAREA CLEANUP_OK
'''.split())


DATA_DIAG = re.compile(rb'((?:[A-Za-z]:)?[^:\r\n]+):([1-9][0-9]{0,8}) event=(\S+) disposition=(\S+)(?:[ \t].*)?')
WAYLAND_TRACE = re.compile(rb'^\[\s*[0-9]+\.[0-9]+\]')
DATA_DISPOSITIONS = {
    b'wl_data_device_manager.create_data_source': {b'inert-source'},
    b'wl_data_device.set_selection': {b'cancelled', b'already-empty'},
    b'wl_data_device.start_drag': {b'cancelled', b'ignored-no-source', b'discard-icon', b'rejected-icon-role'},
}
DIAGNOSTIC_KINDS = (
    ('fatal', 'fatal_diagnostic', re.compile(rb'\bfatal\b|\bkernel panic\b', re.I)),
    ('error', 'protocol_error', re.compile(rb'\binvalid shared request\b|\bprotocol error\b', re.I)),
    ('error', 'resource_error', re.compile(rb'\b(?:out of memory|no space left on device|permission denied)\b', re.I)),
    ('error', 'error_diagnostic', re.compile(rb'\b(?:error|failed|failure|critical)\b', re.I)),
    ('warning', 'warning_diagnostic', re.compile(rb'\b(?:warning|warn)\b', re.I)),
)


def observe_line(diagnostics, source, line):
    # Only allowlisted fields and fixed diagnostic categories leave the driver.
    line = line.rstrip(b'\r')
    token, _, _ = line.partition(b' ')
    if source == 'guest_serial':
        if match := DATA_DIAG.fullmatch(line):
            path, number, event, action = match.groups()
            basename = path.replace(b'\\', b'/').rsplit(b'/', 1)[-1]
            if (action in DATA_DISPOSITIONS.get(event, ())
                    and re.fullmatch(rb'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', basename)):
                level = ('error' if action == b'rejected-icon-role' else
                                         'warning' if action in (b'cancelled', b'ignored-no-source') else 'info')
                diagnostics.emit(level, source, event.decode('ascii'), 'Wayland data-device request',
                                 file=basename.decode('ascii'), line=int(number), action=action.decode('ascii'))
            return
        if token in (b'GTK_EVENT', b'GTK_INPUT', b'GTK_HOVER', b'INPUT') or WAYLAND_TRACE.match(line):
            return
        if token in (b'GTK_GRAB_REJECT', b'GTK_WAYLAND_INIT_FAILED'):
            diagnostics.emit('error', source, token.decode('ascii'), 'Guest reported a failure',
                             action='inspect_local_diagnostics')

        elif token in (b'SHARED_STALE_ACK', b'SHARED_STALE_INPUT', b'SHARED_HOST_LOST'):
            diagnostics.emit('warning', source, token.decode('ascii'), 'Guest detected a stale request or host loss')
        elif token in SERIAL_EVENTS:
            diagnostics.emit('info', source, token.decode('ascii'), 'Guest serial milestone')
        else:
            summarize_diagnostic(diagnostics, source, line)
    elif token in HOST_EVENTS:
        diagnostics.emit('info', source, token.decode('ascii'), 'AppKit host milestone')
    elif token not in (b'INPUT', b'TREE_KEY_OK', b'TREE_CLICK_OK', b'CLICK_OK'):
        summarize_diagnostic(diagnostics, source, line)


def summarize_diagnostic(diagnostics, source, line):
    for level, event, pattern in DIAGNOSTIC_KINDS:
        if pattern.search(line):
            diagnostics.issues[source, level, event] += 1
            break


@contextmanager
def child(cmd, work, *, host_diagnostics=None, **kwargs) -> Iterator[sp.Popen[bytes]]:
    with sp.Popen[bytes](cmd, cwd=work, stdin=sp.PIPE, stdout=sp.PIPE, bufsize=0, text=False, **kwargs) as proc:
        try:
            yield proc
        finally:
            status = proc.poll()
            if status is None:
                proc.kill()
            elif status and host_diagnostics is not None:
                host_diagnostics.emit('error', 'host', 'nonzero_exit', f'AppKit host exited with status {status}',
                                      action='inspect_local_diagnostics')
            proc.wait(timeout=10)


@contextmanager
def menu_host(cmd, work, diagnostics=None) -> Iterator[sp.Popen[bytes]]:
    with child(cmd, work, host_diagnostics=diagnostics) as win:
        assert win.stdin is not None
        try:
            yield win
        finally:
            if win.poll() is None and not win.stdin.closed:
                # EOF tells AppKit to detach mapped popups before closing the root.
                # Keep child()'s kill fallback for an unresponsive host.
                win.stdin.close()
                try:
                    win.wait(timeout=10)
                except sp.TimeoutExpired:
                    pass


class Reader:
    def __init__(self, fd, diagnostics=None, source=None):
        self.fd = fd
        self.buffer = b''
        self.diagnostics = diagnostics
        self.source = source
        self.log_tail = b''
        self.log_overlong = False

    def read(self):
        chunk = os.read(self.fd, 8192)
        if chunk and self.diagnostics is not None and self.diagnostics.pipe is not None:
            # Keep framing independent of until() markers and its control buffer.
            lines = (self.log_tail + chunk).split(b'\n')
            tail = lines.pop()
            for line in lines:
                if not self.log_overlong and len(line) <= 4096:
                    observe_line(self.diagnostics, self.source, line)
                self.log_overlong = False
            self.log_overlong |= len(tail) > 4096
            self.log_tail = b'' if self.log_overlong else tail
        return chunk

    def until(self, marker, timeout):
        end = time.monotonic() + timeout
        with selectors.DefaultSelector() as sel:
            sel.register(self.fd, selectors.EVENT_READ)
            while marker not in self.buffer:
                if not sel.select(max(0, end - time.monotonic())):
                    raise TimeoutError(f'waiting for {marker!r}: {self.buffer[-3000:]!r}')
                chunk = self.read()
                if not chunk:
                    raise EOFError(f'waiting for {marker!r}: {self.buffer[-3000:]!r}')
                self.buffer = (self.buffer + chunk)[-65536:]
        before, self.buffer = self.buffer.split(marker, 1)
        return before


def extract(region):
    offset = region.find(MARKER)
    if offset < 0 or offset % 4096 or offset + (16 << 10) > len(region) or region.find(MARKER, offset + 1) >= 0:
        raise ValueError('expected exactly one aligned DAX frame region')
    start = offset + len(MARKER)
    frame = region[start:start + FRAME_BYTES]
    colors = (bytes.fromhex('0000ffff'), bytes.fromhex('00ff00ff'),
              bytes.fromhex('ff0000ff'), bytes.fromhex('ffffffff'))
    top = (colors[0] * 32 + colors[1] * 32) * 24
    bottom = (colors[2] * 32 + colors[3] * 32) * 24
    if frame != top + bottom or any(region[start + FRAME_BYTES:offset + (16 << 10)]):
        raise ValueError('DAX frame bytes do not match the SHM fixture')
    return frame


def play_animation(port, stream, region, window, report, slots, seconds, lane=0):
    last_tick = -1
    start = None
    previous = None
    offsets = {}
    samples = {key: [] for key in ('interval', 'notice_to_layer', 'verify', 'image', 'apply')}
    size = 640 * 360 * 4
    red, blue = bytes.fromhex('0000ffff'), bytes.fromhex('ff0000ff')
    count = 0
    while True:
        line = stream.until(b'\n', 20)
        now = time.monotonic()
        if line == b'DONE':
            break
        match = re.fullmatch(rb'FRAME 640 360 ([0-9]{1,4}) ([0-3])', line)
        if not match:
            raise ValueError(f'invalid animation frame: {line!r}')
        tick, slot = map(int, match.groups())
        if not (last_tick < tick < seconds * 60 and slot < slots):
            raise ValueError(f'out-of-range animation frame: {line!r}')
        last_tick = tick
        marker = MARKER[:-1] + bytes([MARKER[-1] + 4 * lane + slot])
        if slot not in offsets:
            offset = region.find(marker)
            end = offset + len(marker) + size
            if (offset < 0 or offset % 4096 or end > len(region)
                    or region.find(marker, offset + 1) >= 0
                    or any(abs(other - offset) < len(marker) + size for other in offsets.values())):
                raise ValueError('expected distinct aligned animation regions')
            offsets[slot] = offset
        offset = offsets[slot]
        if region[offset:offset + len(marker)] != marker:
            raise ValueError('animation region marker changed')
        base = offset + len(MARKER)
        frame = region[base:base + size]
        split = (tick * 7 + lane * 31) % 640
        row = red * split + blue * (640 - split)
        tag = (0xff000000 | tick).to_bytes(4, 'little') + (0xff000000 | slot).to_bytes(4, 'little')
        if frame != tag + row[8:] + row * 359:
            raise ValueError(f'animation pixels mismatch at tick {tick}')
        verified = time.monotonic()
        remaining = memoryview(frame)
        while remaining:
            n = window.stdin.write(remaining)
            if not n:
                raise OSError('window pipe made no progress')
            remaining = remaining[n:]
        result = report.until(b'\n', 15).split()
        submitted = time.monotonic()
        if len(result) != 3 or result[0] != b'FRAME_OK':
            raise ValueError(f'invalid animation window response: {result!r}')
        image, apply = map(float, result[1:])
        if not all(math.isfinite(v) and v >= 0 for v in (image, apply)):
            raise ValueError('invalid animation timing')
        if previous is not None:
            samples['interval'].append((submitted - previous) * 1000)
        if start is None:
            start = now
        previous = submitted
        for key, value in (('notice_to_layer', (submitted - now) * 1000),
                           ('verify', (verified - now) * 1000), ('image', image), ('apply', apply)):
            samples[key].append(value)
        count += 1
        port.sendall(f'ACK {tick} {slot}\n'.encode('ascii'))
    if start is None:
        raise ValueError('animation did not submit any frames')
    print(f'ANIMATION_OK slots={slots} submitted={count}/{seconds * 60} '
          f'elapsed_ms={(now - start) * 1000:.2f} effective_fps={count / seconds:.2f}', flush=True)
    for key, values in samples.items():
        if values:
            ordered = sorted(values)
            triple = '/'.join(f'{ordered[math.ceil(p * len(values)) - 1]:.3f}' for p in (.5, .95, .99))
            print(f'{key}_ms p50/p95/p99={triple}', flush=True)
    return count


def play_weston(port, stream, region, window, report, abort_vm=None):
    offset = None
    frames = set()
    resized = False

    def command(code):
        window.stdin.write(struct.pack('<HH', 0, code))
        events = []
        while (event := report.until(b'\n', 10)) != b'COMMAND_OK':
            events.append(event)
        return events

    for tick in range(12):
        line = stream.until(b'\n', 15)
        if line == b'XDG_GONE':
            raise ConnectionError('Wayland client disconnected before close')
        match = re.fullmatch(rb'XDG_FRAME ([0-9]{1,3}) ([0-9]{1,3}) ([0-9]{1,4})', line)
        if not match:
            raise ValueError(f'unexpected Weston frame: {line!r}')
        width, height, sequence = map(int, match.groups())
        if not (1 <= width <= 640 and 1 <= height <= 480 and sequence == tick):
            raise ValueError(f'invalid Weston frame: {line!r}')
        resized |= (width, height) == (320, 280) and tick > 0
        size = width * height * 4
        if offset is None:
            offset = region.find(MARKER)
            if (offset < 0 or offset % 4096 or offset + len(MARKER) + size > len(region)
                    or region.find(MARKER, offset + 1) >= 0):
                raise ValueError('expected one aligned Weston frame region')
        if (region[offset:offset + len(MARKER)] != MARKER
                or offset + len(MARKER) + size > len(region)):
            raise ValueError('invalid Weston DAX frame range')
        base = offset + len(MARKER)
        frame = region[base:base + size]
        alpha = frame[slice(3, None, 4)]
        if alpha != b'\xff' * (size // 4) or not any(any(frame[slice(channel, None, 4)]) for channel in range(3)):
            raise ValueError('expected opaque nonblank Weston pixels')
        frames.add(hashlib.sha256(frame).digest())
        remaining = memoryview(struct.pack('<HH', width, height) + frame)
        while remaining:
            written = window.stdin.write(remaining)
            if not written:
                raise OSError('window pipe made no progress')
            remaining = remaining[written:]
        while not (event := report.until(b'\n', 15)).startswith(b'FRAME_OK '):
            if event == b'CLOSE':
                port.sendall(b'XDG_CLOSE\n')
                port.sendall(f'XDG_ACK {tick}\n'.encode('ascii'))
                if stream.until(b'\n', 15) != b'DONE':
                    raise ValueError('expected client exit after close request')
                return
            if re.fullmatch(rb'SIZE [0-9]{1,3} [0-9]{1,3}', event):
                port.sendall(b'XDG_' + event + b'\n')
            else:
                raise ValueError(f'unexpected AppKit event: {event!r}')
        if tick == 0 and abort_vm is not None:
            abort_vm()
            try:
                stream.until(b'\n', 10)
            except (EOFError, ConnectionResetError):
                return
            raise RuntimeError('expected frame-port EOF after VM exit')
        if tick == 0:
            if b'SIZE 320 280' not in command(1):
                raise ValueError('native resize did not emit a size event')
            port.sendall(b'XDG_SIZE 320 280\n')
        if tick == 11:
            if b'CLOSE' not in command(2):
                raise ValueError('native close did not emit a close request')
            port.sendall(b'XDG_CLOSE\n')
        port.sendall(f'XDG_ACK {tick}\n'.encode('ascii'))
    if not resized:
        raise ValueError('client did not submit a 320×280 frame after resize')
    if len(frames) < 2 or stream.until(b'\n', 15) != b'DONE':
        raise ValueError('expected changing Weston frames and clean XDG close')
    print(f'WESTON_OK: 12 frames, {len(frames)} distinct, native resize and xdg_toplevel.close completed', flush=True)


def shared_smoke(work, vm, port, region, console, override, poweroff=True, session=1, abrupt=False, previous_frames=None, gtk=False):
    stream = Reader(port.fileno())
    def line():
        return stream.until(b'\n', 20).decode().split()
    native = int(sp.check_output([work / 'window', '--backing-scale'], timeout=10))
    if native not in (1, 2): raise ValueError(native)
    advertised = override or native
    source = "override" if override is not None else "backing"
    print(f'OUTPUT_SCALE native={native} advertised={advertised} source={source}', flush=True)
    env = f'export M2_OUTPUT_SCALE={advertised} XDG_RUNTIME_DIR=/tmp/m2 WAYLAND_DISPLAY=m2 LD_LIBRARY_PATH=/tmp/bridge M2_SHARED=1 M2_SESSION={session}; '.encode()
    if gtk: env += b'export XKB_CONFIG_ROOT=/tmp/bridge/xkb M2_GTK_RESIZE_TRACE=1; '
    menu = gtk and os.environ.get('M2_MENU') == '1'
    if menu: env += b'export M2_MENU=1; '
    gtk_client = (b'/tmp/bridge/gtk-client' if abrupt else b'(/tmp/bridge/gtk-client && touch /tmp/gtk-ok)')
    vm.stdin.write(env + b'rm -f /tmp/server-ok /tmp/client-ok /tmp/gtk-ok; set -- /dev/vport*p1; exec 3<>"$1"; (/tmp/bridge/bridge server <&3 >&3 && touch /tmp/server-ok) & server=$!; '
                   b'for i in 1 2 3 4 5; do test -S /tmp/m2/m2 && break; sleep 1; done; ' +
                   (gtk_client + b' 3>&- & victim=$!\n' if gtk else
                    b'M2_VICTIM=1 /tmp/bridge/bridge client & victim=$!\n'))
    with ExitStack() as stack:
        windows, frames = {}, {}
        dropping = threading.Event()
        def opened(popup=None):
            if popup is None:
                op, sid = line()
                if op != 'OPEN': raise ValueError((op, sid))
                extra_env = {}
            else:
                sid, x, y = popup
                extra_env = {'M2_POPUP_ORIGIN': f'{x} {y}'}
            if sid in windows: raise ValueError(sid)
            rx, tx = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            stack.enter_context(rx)
            thread = None
            def join_forwarder():
                if thread is not None:
                    thread.join(10)
            stack.callback(join_forwarder)
            with tx:
                win = stack.enter_context(child([work / 'window', '--weston'], work,
                    host_diagnostics=console.diagnostics, env={**os.environ, 'M2_INPUT_FD': str(tx.fileno()),
                         'M2_VERIFY_PIXELS': '0' if gtk else '1', **extra_env}, pass_fds=(tx.fileno(),)))
            def forward():
                with rx.makefile('rb') as events:
                    for event in events:
                        if dropping.is_set():
                            return
                        try:
                            port.sendall(b'I ' + sid.encode() + b' ' + event)
                        except OSError:
                            if dropping.is_set():
                                return
                            raise
            thread = threading.Thread(target=forward, daemon=True)
            thread.start()
            assert win.stdout is not None
            windows[sid] = win, Reader(win.stdout.fileno(), console.diagnostics, 'host')
            return sid
        def pixels(expected, seq, width=64, height=48, remap=False, origin=None, overlay=None, expected_scale=advertised):
            packet = line()
            if len(packet) != 7: raise ValueError(packet)
            op, sid, n, slot, w, h, scale = packet
            if int(scale) != expected_scale: raise ValueError((sid,scale))
            if (op,sid,n,w,h) != ('PIXELS',expected,str(seq),str(width),str(height)): raise ValueError((op,sid,n,w,h))
            if not 0 <= int(slot) < 8: raise ValueError(slot)
            if sid in frames and frames[sid][0] != slot: raise ValueError('slot changed')
            if any(other != sid and old_slot == slot for other, (old_slot, _) in frames.items()):
                raise ValueError('shared DAX slot')
            marker = MARKER[:-1] + bytes([MARKER[-1]+int(slot)])
            off = region.find(marker)
            if off < 0 or off % 4096 or region.find(marker,off+1)>=0: raise ValueError('invalid shared marker')
            frames[sid] = slot, off
            start = off+len(marker)
            frame = region[start:start + width*height*4]
            colors = (bytes.fromhex('0000ffff'), bytes.fromhex('00ff00ff'),
                      bytes.fromhex('ff0000ff'), bytes.fromhex('ffffffff'))
            left, top = width//2, height//2
            expected_frame = ((colors[0]*left + colors[1]*(width-left))*top +
                              (colors[2]*left + colors[3]*(width-left))*(height-top))
            if overlay is not None:
                expected_frame = bytearray(expected_frame)
                ox, oy, cw, ch = overlay
                for y in range(ch):
                    for x in range(cw):
                        for dy in range(int(scale)):
                            for dx in range(int(scale)):
                                px, py = (ox+x)*int(scale)+dx, (oy+y)*int(scale)+dy
                                if 0 <= px < width and 0 <= py < height:
                                    pos = (py*width+px)*4
                                    expected_frame[pos:pos+4] = colors[2*(y >= ch//2)+(x >= cw//2)]
            if frame != expected_frame: raise ValueError('shared DAX frame bytes')
            win, report = windows[sid]
            data = memoryview(struct.pack('<HHH',width,height,int(scale))+frame)
            while data:
                n = win.stdin.write(data)
                if not n: raise EOFError('window pipe')
                data = data[n:]
            if remap and report.until(b'\n',15) != b'REMAPPED': raise ValueError('window remap')
            if origin is not None and report.until(b'\n',15) != f'POPUP_ORIGIN {origin[0]} {origin[1]}'.encode():
                raise ValueError('native popup origin')
            geometry = report.until(b'\n',15).decode().split()
            lw, lh = width//int(scale), height//int(scale)
            if geometry != ['GEOMETRY', str(lw), str(lh), 'backing', str(lw*native), str(lh*native)]:
                raise ValueError(geometry)
            print('surface',sid,*geometry)
            checks = (f'LAYER_OK contents_scale={native} buffer_scale={scale} filter=nearest',
                      f'OFFSCREEN_2X_OK {2*lw}x{2*lh} exact_pixels={4*lw*lh} repeat={2//int(scale)}')
            for expected_line in checks:
                observed = report.until(b'\n',15).decode()
                if observed != expected_line: raise ValueError(observed)
                print('surface', sid, observed, flush=True)
            if not report.until(b'\n',15).startswith(b'FRAME_OK '): raise ValueError('window submit')
        def close_window(sid):
            win, report = windows[sid]
            win.stdin.close()
            if report.until(b'\n',10) != b'CLEANUP_OK' or win.wait(timeout=10):
                raise ValueError('window cleanup')

        def closed(ids):
            for _ in range(len(ids)):
                op,sid=line()
                if op!='CLOSED' or sid not in ids: raise ValueError((op,sid))
                ids.remove(sid)
                close_window(sid)
        if gtk:
            console.until(b'GTK_WAYLAND_CONNECTED\r\n', 15)
            ids = set()
            by_size = {}
            seq = {}
            def gtk_command(sid, code):
                win, report = windows[sid]
                win.stdin.write(struct.pack('<HH', 0, code))
                if report.until(b'\n', 10) != b'COMMAND_OK': raise ValueError(('GTK command', sid, code))

            def gtk_ack(sid):
                port.sendall(f'ACK {sid} {seq[sid]}\n'.encode())

            def burst_trace(expected):
                console.until(b'GTK_BURST ', 10)
                actual = console.until(b'\r\n', 10).decode()
                if actual != expected: raise ValueError(('GTK burst', expected, actual))
                print(f'GTK_BURST {actual}', flush=True)

            def gtk_frame(expected=None, target=None):
                while True:
                    packet = line()
                    if packet[0] == 'OPEN' and len(packet) == 2:
                        stream.buffer = (' '.join(packet) + '\n').encode() + stream.buffer
                        opened()
                        continue
                    op,sid,n,slot,w,h,scale = packet
                    w,h,scale = map(int,(w,h,scale))
                    if (op != 'PIXELS' or int(n) != seq.get(sid, 0) + 1 or sid not in windows or
                                                (expected is not None and sid != expected) or scale != advertised):
                        raise ValueError(packet)
                    logical = w // scale, h // scale
                    if w % scale or h % scale: raise ValueError(packet)
                    if target is None:
                        if sid in ids or logical not in {(128, 96), (160, 96)} or logical in by_size:
                            raise ValueError(packet)
                    elif logical != target:
                        raise ValueError((packet, target))
                    slot = int(slot)
                    if not 0 <= slot < 8 or any(slot == used[0] for other, used in frames.items() if other != sid):
                        raise ValueError(packet)
                    marker = MARKER[:-1] + bytes([MARKER[-1] + slot])
                    off = region.find(marker)
                    if off < 0 or off % 4096 or region.find(marker, off + 1) >= 0:
                        raise ValueError(packet)
                    if sid in frames and frames[sid] != (slot, off): raise ValueError('GTK slot changed')
                    frames[sid] = slot, off
                    start = off + len(marker)
                    frame = region[start:start+w*h*4]
                    if len(frame) != w*h*4 or not any(frame[0::4] + frame[1::4] + frame[2::4]):
                        raise ValueError('empty GTK frame')
                    win, report = windows[sid]
                    data = memoryview(struct.pack('<HHH',w,h,scale)+frame)
                    while data:
                        written = win.stdin.write(data)
                        if not written: raise EOFError('window pipe')
                        data = data[written:]
                    geometry = report.until(b'\n',15)
                    lw, lh = logical
                    if geometry != f'GEOMETRY {lw} {lh} backing {lw*native} {lh*native}'.encode() or not report.until(b'\n',15).startswith(b'FRAME_OK '):
                        raise ValueError(geometry)
                    ids.add(sid)
                    seq[sid] = int(n)
                    if target is None: by_size[logical] = sid
                    print(f'GTK_FRAME surface={sid} seq={n} slot={slot} {geometry.decode()} buffer={w}x{h} scale={scale} sha256={hashlib.sha256(frame).hexdigest()}', flush=True)
                    return start, frame
            try:
                while len(by_size) < 2: gtk_frame()
                if set(windows) != ids: raise ValueError('unexpected GTK toplevels')
                a, b = by_size[128, 96], by_size[160, 96]

                def gtk_input(sid, label):
                    gtk_command(sid, 6)
                    for typ, value, shift in ((4,1,0),(7,1,0),(4,3,0),(7,3,0),(31,0,0),
                                              (8,65505,0),(8,65,1),(9,65,1),(9,65505,1)):
                        console.until(b'GTK_EVENT ', 10)
                        actual = console.until(b'\r\n', 10).decode()
                        if actual != f'{label} {typ} {value} {shift}': raise ValueError(actual)
                    print('GTK_INPUT_OK', label, sid, flush=True)

                def gtk_popup(parent):
                    port.sendall(f'I {parent} M 11 8\nI {parent} B 1 1\n'.encode())
                    console.until(b'M2_MENU_GRAB ', 10)
                    sid = console.until(b'\r\n', 10).decode()
                    op, popup, owner, x, y, dx, dy = line()
                    if (op, popup, owner) != ('POPUP', sid, parent): raise ValueError((op, popup, owner))
                    op, owner, n, slot, pw, ph, scale = line()
                    slot, pw, ph, scale = map(int, (slot, pw, ph, scale))
                    if (op, owner, n) != ('PIXELS', sid, '1') or scale not in (1, 2) or pw % scale or ph % scale:
                        raise ValueError((op, owner, n, scale))
                    if not 0 <= slot < 8 or any(slot == used[0] for used in frames.values()):
                        raise ValueError('menu slot')
                    marker = MARKER[:-1] + bytes([MARKER[-1] + slot])
                    off = region.find(marker)
                    if off < 0 or off % 4096 or region.find(marker, off + 1) >= 0:
                        raise ValueError('menu marker')
                    start = off + len(marker)
                    frame = region[start:start + pw*ph*4]
                    if len(frame) != pw*ph*4 or not any(frame): raise ValueError('empty menu')
                    win, report = windows[parent]
                    win.stdin.write(struct.pack('<HH', 0, 8))
                    label, left, top = report.until(b'\n', 10).decode().split()
                    if label != 'CONTENT_ORIGIN' or report.until(b'\n', 10) != b'COMMAND_OK': raise ValueError(label)
                    lw, lh = pw // scale, ph // scale
                    origin = (int(left) + int(x) + int(dx), int(top) - int(y) - int(dy) - lh)
                    opened((sid, *origin))
                    win, report = windows[sid]
                    data = memoryview(struct.pack('<HHH', pw, ph, scale) + frame)
                    while data:
                        written = win.stdin.write(data)
                        if not written: raise EOFError('menu window pipe')
                        data = data[written:]
                    for expected in (f'POPUP_ORIGIN {origin[0]} {origin[1]}',
                                     f'GEOMETRY {lw} {lh} backing {lw*native} {lh*native}'):
                        actual = report.until(b'\n', 10).decode()
                        if actual != expected: raise ValueError(actual)
                    if not report.until(b'\n', 10).startswith(b'FRAME_OK '): raise ValueError('menu submission')
                    port.sendall(f'I {parent} B 0 1\nI {parent} M 2 2\nI {parent} B 1 0\nI {parent} B 0 0\n'.encode())
                    closed({sid})
                    console.until(b'GTK_MENU_HIDDEN\r\n', 10)
                    port.sendall(f'ACK {sid} 1\n'.encode())
                    print('GTK_MENU_DONE', sid, pw, ph, flush=True)

                if menu:
                    gtk_popup(a)
                else:
                    gtk_input(a, 'A')
                gtk_input(b, 'B')
                for code, target in ((5, (160, 120)), (1, (320, min(280, 480 // advertised))), (5, (160, 120))):
                    gtk_command(a, code)
                    gtk_ack(a)
                    old_a = gtk_frame(a, target)
                print('GTK_RESIZE_OK: three programmatic resizes submitted', flush=True)

                # Prime a fresh B frame so both slots hold an unacked GTK buffer.
                gtk_command(b, 5)
                gtk_ack(b)
                old_b = gtk_frame(b, (160, 120))
                burst = ((a, 176, 128), (b, 192, 136), (a, 208, 144),
                         (b, 224, 152), (a, 240, 160), (b, 256, 168))
                # Clear trace from the sequential resize baseline before sending the burst.
                vm.stdin.write(b'echo GTK_BURST_BEGIN\n')
                console.until(b'GTK_BURST_BEGIN\r\n', 10)
                for sid, w, h in burst:
                    # Command 6 is input injection in --weston; send the same R
                    # record that native resize forwards rather than overloading it.
                    port.sendall(f'I {sid} R {w} {h}\n'.encode())
                    burst_trace(f'resize {sid} {seq[sid]} {w} {h} busy=1')

                def held(snapshot):
                    start, frame = snapshot
                    if region[start:start + len(frame)] != frame:
                        raise ValueError('GTK unacked DAX frame overwritten')

                held(old_a)
                held(old_b)
                for sid, w, h in burst[-2:]:
                    gtk_ack(sid)
                    burst_trace(f'release {sid} {seq[sid]} callback=1')
                    burst_trace(f'configure {sid} {seq[sid]} {w} {h}')
                    gtk_frame(sid, (w, h))
                    if sid == a: held(old_b)
                print('GTK_PROGRAMMATIC_RESIZE_BURST_OK: 6 interleaved wire requests before ACK; '
                      'old frames preserved and released; only final sizes submitted', flush=True)

                def advance(sid, target, label):
                    gtk_ack(sid)
                    _, frame = gtk_frame(sid, target)
                    w, h = (size * advertised for size in target)
                    pos = ((h // 2) * w + w // 2) * 4
                    if frame[pos:pos+3:2] != (b'\x00\xff' if label == 'A' else b'\xff\x00'):
                        raise ValueError(('wrong GTK frame', label))
                    return hashlib.sha256(frame).hexdigest()

                def native_close(sid, label):
                    gtk_command(sid, 2)
                    console.until(b'GTK_DELETE ', 10)
                    if console.until(b'\r\n', 10).decode() != label: raise ValueError('wrong GTK close')
                    closed({sid})
                    gtk_ack(sid)
                    print('GTK_CLOSE_OK', label, sid, flush=True)

                if abrupt:
                    vm.stdin.write(b'kill -0 "$victim" && echo GTK_ALIVE; kill -TERM "$victim"; wait "$victim"\n')
                    console.until(b'GTK_ALIVE\r\n', 10)
                    closed(ids.copy())
                    for sid in ids:
                        gtk_ack(sid)
                else:
                    for sid, target, label in ((a, (240, 160), 'A'), (b, (256, 168), 'B')):
                        if len({advance(sid, target, label) for _ in range(3)}) != 3:
                            raise ValueError('static GTK window')
                    native_close(a, 'A')
                    hashes = [advance(b, (256, 168), 'B') for _ in range(5)]
                    if len(set(hashes)) != 5: raise ValueError('static survivor')
                    print('GTK_SURVIVOR_OK', b, *hashes, flush=True)
                    gtk_input(b, 'B')
                    native_close(b, 'B')
                    vm.stdin.write(b'wait "$victim"; test -f /tmp/gtk-ok && echo GTK_EXIT_OK\n')
                    console.until(b'GTK_EXIT_OK\r\n', 10)
                port.sendall(b'STOP\n')
                if line() != ['DONE']: raise ValueError('GTK server exit')
                vm.stdin.write(b'wait "$server"; test -f /tmp/server-ok && test ! -e /tmp/m2/m2 && test ! -e /tmp/m2/m2.lock && echo GTK_CLEAN\n')
                console.until(b'GTK_CLEAN\r\n', 10)
                vm.stdin.write(b'exec 3>&-; poweroff\n')
                if port.recv(1) or vm.wait(timeout=20): raise ValueError('VM cleanup')
            except (TimeoutError, EOFError, ValueError) as error:
                vm.stdin.write(b'echo GTK_DIAGNOSTICS\n')
                error.add_note(console.until(b'GTK_DIAGNOSTICS\r\n', 5)[-6000:].decode(errors='replace'))
                raise
            print('GTK_OK: one live GTK client, two AppKit toplevels; guest and host cleanup verified')
            return
        a,b = opened(),opened()
        pixels(a,1); pixels(b,1,expected_scale=1)
        vm.stdin.write(b'(/tmp/bridge/bridge client && touch /tmp/client-ok) & survivor=$!\n')
        c=opened(); pixels(c,1)
        def inject(sid, target):
            win, report = windows[sid]
            win.stdin.write(struct.pack('<HH',0,3))
            if report.until(b'\n',10)!=b'COMMAND_OK': raise ValueError('input command')
            for event in ('motion 11 8','button 272 1','button 272 0','key 42 1','key 30 1','key 30 0','key 42 0'):
                prefix = console.until(b'INPUT ',10)
                actual = console.until(b'\r\n',10).decode()
                if actual != f'{target} {event}': raise ValueError((prefix,actual,target,event))
        if previous_frames is not None:
            if set(frames) & set(previous_frames) or set(frames.values()) != set(previous_frames.values()):
                raise ValueError('fresh session did not reuse the same DAX slots and offsets with fresh IDs')
            for sid in previous_frames:
                port.sendall(f'ACK {sid} 1\nI {sid} M 11 8\n'.encode())
                console.until(f'SHARED_STALE_ACK {sid}\r\n'.encode(), 10)
                console.until(f'SHARED_STALE_INPUT {sid}\r\n'.encode(), 10)
            print('STALE_OK: rejected 3 old ACKs and 3 old input messages on reused slots')
        for sid,target in ((a,'V0'),(c,'S0'),(b,'V1')): inject(sid,target)
        if abrupt:
            dropping.set()
            port.shutdown(socket.SHUT_RDWR)
            port.close()
            for sid in windows:
                close_window(sid)
            vm.stdin.write(b'wait "$server"; wait "$victim"; wait "$survivor"; '
                           b'exec 3>&-; '
                           b'! kill -0 "$server" 2>/dev/null && ! kill -0 "$victim" 2>/dev/null && ! kill -0 "$survivor" 2>/dev/null && '
                           b'test ! -e /tmp/m2/m2 && test ! -e /tmp/m2/m2.lock && echo ABRUPT_CLEAN\n')
            console.until(b'SHARED_HOST_LOST abandoned=3\r\n', 15)
            console.until(b'ABRUPT_CLEAN\r\n', 15)
            for slot, off in frames.values():
                if any(region[off:off + len(MARKER) + FRAME_BYTES]):
                    raise ValueError(f'abandoned DAX slot {slot} still contains frame bytes')
            print('ABRUPT_OK: frame port lost with 3 unacked slots; 3 windows closed; guest resources cleared')
            return frames
        vm.stdin.write(b'kill -KILL "$victim"; wait "$victim"\n')
        closed({a,b})
        inject(c,"S0")
        print("SEAT_OK: V0 -> S0 -> V1 -> survivor S0")
        for sid in (a,b,c): port.sendall(f'ACK {sid} 1\n'.encode())
        del frames[a], frames[b]
        pixels(c,2); port.sendall(f'ACK {c} 2\n'.encode())
        def command(code):
            win, report = windows[c]
            win.stdin.write(struct.pack('<HH', 0, code))
            if report.until(b'\n', 10) != b'COMMAND_OK': raise ValueError(f'window command {code}')
        command(5)
        pixels(c,3,160*advertised,120*advertised)
        print(f'RESIZE_OK: surface {c} logical=160x120 buffer={160*advertised}x{120*advertised}')
        command(7)
        for w, h in ((170, 130), (180, 140), (192, 144)):
            console.until(f'M2_RESIZE_PENDING {c} {w} {h}\r\n'.encode(), 10)
        port.sendall(f'ACK {c} 3\n'.encode())
        pixels(c,4,192*advertised,144*advertised)
        print(f'RESIZE_BURST_OK: surface {c} coalesced 3 events to 192x144', flush=True)
        port.sendall(f'ACK {c} 4\n'.encode())
        def held_slot(frame_bytes):
            _, off = frames[c]
            return region[off:off + len(MARKER) + frame_bytes]

        pixels(c,5,192*advertised,144*advertised,overlay=(3,5,8,6))
        repaint_bytes = 192*144*advertised**2*4
        held = held_slot(repaint_bytes)
        console.until(b'FIXTURE_REPAINT_QUEUED\r\n',10)
        if held_slot(repaint_bytes) != held: raise ValueError('retained repaint modified unacknowledged DAX slot')
        port.sendall(f'ACK {c} 5\n'.encode())
        pixels(c,6,192*advertised,144*advertised,overlay=(-2,8,6,4))
        port.sendall(f'ACK {c} 6\n'.encode())
        pixels(c,7,192*advertised,144*advertised)
        port.sendall(f'ACK {c} 7\n'.encode())
        print('SUBSURFACE_OK: held slot unchanged; two commits coalesced; unlatched child state excluded; removal exact', flush=True)
        packet = line()
        if len(packet) != 7 or packet[0] != 'POPUP' or packet[2:] != [c, '9', '7', '2', '3']:
            raise ValueError(packet)
        parent, report = windows[c]
        parent.stdin.write(struct.pack('<HH', 0, 8))
        label, left, top = report.until(b'\n', 10).decode().split()
        if label != 'CONTENT_ORIGIN' or report.until(b'\n', 10) != b'COMMAND_OK':
            raise ValueError('parent native origin')
        origin = (int(left) + 11, int(top) - 22)
        popup = opened((packet[1], *origin))
        pixels(popup, 1, 16*advertised, 12*advertised, origin=origin)
        command(2)
        closed({popup})
        port.sendall(f'ACK {popup} 1\n'.encode())
        console.until(b'FIXTURE_POPUP_DONE\r\n', 10)
        print(f'POPUP_OK: {popup} parent={c} relative=9,7 size=16x12 native_origin={origin}; parent unmap dismissed unacked popup', flush=True)
        if line() != ['UNMAP', c]: raise ValueError('expected explicit unmap')
        command(4)
        print(f'UNMAP_OK: surface {c} gone from WindowServer')
        pixels(c,8,remap=True)
        held = held_slot(FRAME_BYTES)
        console.until(b'FIXTURE_TEARDOWN_QUEUED\r\n',10)
        inject(c,'S0')
        print(f'REMAP_OK: surface {c} reused slot {frames[c][0]} and accepted input')
        command(2)
        closed({c})
        console.until(b'FIXTURE_PARENT_FIRST_DONE\r\n',10)
        if held_slot(FRAME_BYTES) != held: raise ValueError('parent teardown modified unacknowledged DAX slot')
        port.sendall(f'ACK {c} 8\n'.encode())
        print('PARENT_FIRST_OK: live subsurface outlived parent; deferred repaint cancelled before ACK', flush=True)
        print(f'CLOSE_OK: AppKit performClose -> xdg_toplevel.close -> client destroyed surface {c}')
        port.sendall(b'STOP\n')
        if line()!=['DONE']: raise ValueError('shared server exit')
        vm.stdin.write(b'wait "$server"; wait "$survivor"; test -f /tmp/server-ok && test -f /tmp/client-ok && test ! -e /tmp/m2/m2 && echo SHARED_CLEAN\n')
        console.until(b'SHARED_CLEAN\r\n',10)
        vm.stdin.write(b'exec 3>&-\n')
        if poweroff:
            vm.stdin.write(b'poweroff\n')
            if port.recv(1) or vm.wait(timeout=20): raise ValueError('VM cleanup')
        print('SHARED_OK: 2 clients, 3 AppKit toplevels; SIGKILL with 2 unacked slots; survivor submitted again')


def popup_smoke(work, vm, port, region, console):
    stream = Reader(port.fileno())

    def event():
        packet = stream.until(b'\n', 20).decode('ascii').split()
        print('guest:', *packet, flush=True)
        return packet

    def send(command):
        port.sendall((command + '\n').encode('ascii'))

    vm.stdin.write(
        b'(export M2_OUTPUT_SCALE=1 XDG_RUNTIME_DIR=/tmp/m2 WAYLAND_DISPLAY=m2 LD_LIBRARY_PATH=/tmp/bridge; '
        b'set -- /dev/vport*p1; exec 3<>"$1"; /tmp/bridge/bridge shared-popup <&3 >&3 & server=$!; '
        b'for i in 1 2 3 4 5; do test -S /tmp/m2/m2 && break; sleep 1; done; '
        b'/tmp/bridge/bridge client-popup 3>&- && wait "$server" && test ! -e /tmp/m2/m2 && echo POPUP_GUEST_CLEAN)\n')
    with child([work / 'window', '--popup-host'], work, host_diagnostics=console.diagnostics) as win:
        report = Reader(win.stdout.fileno(), console.diagnostics, 'host')
        slots = set()

        def expect(pattern):
            reply = report.until(b'\n', 15).decode('ascii')
            if not re.fullmatch(pattern, reply):
                raise ValueError(f'expected {pattern}, host reported {reply!r}')
            print('host:', reply, flush=True)

        def submit(sid, header, width, height, reply):
            op, owner, seq, slot, w, h, scale = event()
            if (op, owner, seq, int(w), int(h), scale) != ('PIXELS', sid, '1', width, height, '1'):
                raise ValueError(f'invalid PIXELS for {header} surface {sid}')
            slot = int(slot)
            if not 0 <= slot < 8 or slot in slots:
                raise ValueError(f'invalid or reused popup slot {slot}')
            slots.add(slot)
            marker = MARKER[:-1] + bytes([MARKER[-1] + slot])
            offset = region.find(marker)
            if offset < 0 or offset % 4096 or region.find(marker, offset + 1) >= 0:
                raise ValueError(f'invalid DAX marker for slot {slot}')
            start = offset + len(marker)
            frame = region[start:start + width * height * 4]
            red, green, blue, white = map(bytes.fromhex, ('0000ffff', '00ff00ff', 'ff0000ff', 'ffffffff'))
            x, y = width // 2, height // 2
            if frame != ((red*x + green*(width-x))*y + (blue*x + white*(width-x))*(height-y)):
                raise ValueError(f'DAX pattern mismatch for surface {sid}')
            data = memoryview(f'{header} {width} {height}\n'.encode('ascii') + frame)
            while data:
                written = win.stdin.write(data)
                if not written: raise EOFError('popup-host stdin')
                data = data[written:]
            expect(reply)
            send(f'ACK {sid} {seq}')

        op, parent = event()
        if op != 'OPEN' or not parent.isdecimal() or not int(parent):
            raise ValueError((op, parent))
        submit(parent, 'PARENT', 64, 48, 'PARENT_OK')
        op, sid, owner, x, y, w, h = event()
        if (op, owner) != ('POPUP', parent) or not sid.isdecimal() or int(sid) in (0, int(parent)):
            raise ValueError((op, sid, owner))
        if not (0 < int(w) <= 2048 and 0 < int(h) <= 2048):
            raise ValueError((w, h))
        submit(sid, f'POPUP {int(x)} {int(y)}', int(w), int(h), r'POPUP_OK outside=[1-9]\d*')
        win.stdin.write(b'MOVE 12 8\n')
        expect(r'MOVE_OK outside=[1-9]\d*')
        win.stdin.write(b'CLOSE\n')
        expect('CLOSE_OK')
        for surface in (sid, parent):
            send(f'I {surface} C 0 0')
            if event() != ['CLOSED', surface]: raise ValueError(f'expected CLOSED {surface}')
        send('STOP')
        if event() != ['DONE']: raise ValueError('expected DONE')
        win.stdin.close()
        expect('CLEANUP_OK')
        if win.wait(timeout=10): raise ValueError('popup-host exit status')
    console.until(b'POPUP_GUEST_CLEAN\r\n', 15)
    vm.stdin.write(b'poweroff\n')
    if stream.buffer or port.recv(1) or vm.wait(timeout=20): raise ValueError('popup VM cleanup')
    print('POPUP_SMOKE_OK: scale=1 DAX patterns verified, guest socket removed, VM exited', flush=True)


def gtk_menu_smoke(work, vm, port, region, console, edge=False, tree=False, hover=False, menu_input=False, manual=False, menu_depth=2, hover_from=None, wayland_trace=False):
    stream = Reader(port.fileno())
    left_hover_reopen = menu_input and not manual and menu_depth == 7 and hover_from == 2
    client_trace = b'WAYLAND_DEBUG=client ' if wayland_trace or left_hover_reopen else b''
    move_probe = menu_input and manual and os.environ.get('M2_GTK_MOVE') == '1'
    vm.stdin.write(
        b'(export ' + (f'M2_GTK_KEYBOARD=1 M2_GTK_MENU_DEPTH={menu_depth} '.encode() if menu_input else b'') + (b'M2_GTK_MENU_TREE=1 ' if tree else b'') + (b'M2_GTK_MENU_HOVER=1 ' if hover or hover_from is not None else b'') +
        (b'M2_GTK_MOVE=1 ' if move_probe else b'') +
        b'M2_GTK_MENU=1 M2_OUTPUT_SCALE=1 XDG_RUNTIME_DIR=/tmp/m2 WAYLAND_DISPLAY=m2 '
        b'LD_LIBRARY_PATH=/tmp/bridge XKB_CONFIG_ROOT=/tmp/bridge/xkb; '
        b'set -- /dev/vport*p1; test -c "$1" || exit 1; exec 3<>"$1"; '
        b'/tmp/bridge/bridge shared-popup <&3 >&3 & server=$!; '
        b'for i in 1 2 3 4 5; do test -S /tmp/m2/m2 && break; sleep 1; done; '
        + client_trace + b'/tmp/bridge/gtk-client 3>&- && echo GTK_MENU_CLIENT_EXIT_OK && wait "$server" && '
        b'test ! -e /tmp/m2/m2 && test ! -e /tmp/m2/m2.lock && echo GTK_MENU_GUEST_CLEAN)\n')

    def event():
        packet = stream.until(b'\n', 20).decode('ascii').split()
        print('guest:', *packet, flush=True)
        return packet

    def send(*commands):
        port.sendall(('\n'.join(commands) + '\n').encode('ascii'))

    host_mode = '--menu-input-host' if menu_input else '--menu-tree-host' if tree else '--menu-host'
    with menu_host([work / 'window', host_mode], work, console.diagnostics) as win:
        report = Reader(win.stdout.fileno(), console.diagnostics, 'host')

        def host_line(timeout):
            actual = report.until(b'\n', timeout).decode('ascii')
            print('host:', actual, flush=True)
            if menu_input and actual.startswith('INPUT '):
                match = re.fullmatch(r'INPUT (0|[1-9]\d*) ([FLKMBDUPS]) (-?\d+) (-?\d+)', actual)
                if not match:
                    raise ValueError(f'malformed host input: {actual}')
                sid, op, x, y = match.groups()
                sid = parent if sid == '0' else sid
                if sid in geometry:  # Late events from tearing down a window are not new input.
                    args = '' if op == 'F' else ' 0' if op == 'L' else f' {x} {y}'
                    send(f'I {sid} {op}{args}')
                return None
            return actual

        def host(command, reply, frame=b''):
            if command is not None:
                data = memoryview(command.encode('ascii') + b'\n' + frame)
                while data:
                    written = win.stdin.write(data)
                    if not written:
                        raise EOFError('menu-host stdin')
                    data = data[written:]
            deadline = time.monotonic() + 15
            while (actual := host_line(max(0, deadline - time.monotonic()))) is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f'waiting for host {reply}')
            if not re.fullmatch(reply, actual):
                raise ValueError(f'expected {reply}, menu-host reported {actual!r}')
            return actual

        def click(target, button, x, y):
            fields = f'{target} {button} {x} {y}'
            op = 'TREE_CLICK' if tree else 'CLICK'
            host(op + ' ' + fields, op + '_OK ' + fields)

        def surface_id(sid):
            return re.fullmatch(r'[1-9][0-9]*', sid) is not None

        op, parent = event()
        if op != 'OPEN' or not surface_id(parent):
            raise ValueError((op, parent))
        parent_size = (128, 96)
        geometry = {parent: (0, 0, *parent_size)}
        owners = {}

        def host_sid(sid):
            return '0' if sid == parent else sid
        frames = {}

        def submit(packet):
            op, sid, seq, slot, w, h, scale = packet
            x, y, width, height = geometry[sid]
            prev_seq, prev_slot, prev_offset = frames.get(sid, (0, None, None))
            seq, slot, w, h, scale = map(int, (seq, slot, w, h, scale))
            if (op != 'PIXELS' or seq != prev_seq + 1 or scale != 1 or (w, h) != (width, height)
                    or not 0 <= slot < 8 or (prev_slot is not None and slot != prev_slot)
                    or any(other != sid and slot == used[1] for other, used in frames.items())):
                raise ValueError(f'invalid menu frame: {packet}')
            marker = MARKER[:-1] + bytes([MARKER[-1] + slot])
            offset = region.find(marker)
            if (offset < 0 or offset % 4096 or region.find(marker, offset + 1) >= 0
                    or (prev_offset is not None and offset != prev_offset)):
                raise ValueError(f'invalid DAX marker for slot {slot}: {offset}')
            start = offset + len(marker)
            frame = region[start:start + w*h*4]
            if len(frame) != w*h*4 or not any(frame[3::4]):
                raise ValueError(f'truncated or transparent menu frame: {packet}')
            if menu_input and prev_seq:
                target = host_sid(sid)
                host(f'TREE_FRAME {target} {w} {h}', f'TREE_FRAME_OK {target}', frame)
            elif tree and prev_seq:
                pass  # The non-input tree fixture only displays initial frames.
            elif sid == parent:
                host(f'PARENT {w} {h}', 'PARENT_OK', frame)
            elif tree:
                host(f'TREE_POPUP {sid} {host_sid(owners[sid])} {x} {y} {w} {h}', f'TREE_POPUP_OK {sid}', frame)
            else:
                outside = r'[0-9]+' if edge else r'[1-9][0-9]*'
                host(f'POPUP {x} {y} {w} {h}', 'POPUP_OK outside=' + outside, frame)
                if edge:
                    host('CHECK_EDGE', 'EDGE_OK')
            frames[sid] = seq, slot, offset
            send(f'ACK {sid} {seq}')
            return frame

        def wait_for(op, sid):
            while True:
                packet = event()
                if packet == [op, sid]:
                    return
                if packet[:1] != ['PIXELS']:
                    raise ValueError(f'expected {op} {sid}, got {packet}')
                submit(packet)

        def open_menu():
            x = parent_size[0] - 8
            y = parent_size[1] - 8 if edge else parent_size[1] // 2
            click('0' if tree else 'PARENT', 'RIGHT', x, y)
            send(f'I {parent} D {x} {y}', f'I {parent} U {x} {y}')
            return receive_popup(parent)

        def receive_popup(expected_owner):
            packet = event()
            while packet[:1] == ['PIXELS']:
                submit(packet)
                packet = event()
            sid = announce_popup(packet, expected_owner)
            while True:
                packet = event()
                if packet[:1] != ['PIXELS']:
                    raise ValueError(f'expected popup pixels, got {packet}')
                frame = submit(packet)
                if packet[1] == sid:
                    return sid, frame

        def announce_popup(packet, expected_owner):
            op, sid, owner, x, y, w, h = packet
            if op != 'POPUP' or owner != expected_owner or not surface_id(sid) or sid in seen:
                raise ValueError(f'invalid popup announcement: {packet}')
            x, y, w, h = map(int, (x, y, w, h))
            if tree:
                if not (0 < w <= 640 and 0 < h <= 480):
                    raise ValueError(f'invalid tree popup size: {packet}')
                owners[sid] = owner
            elif edge:
                if not (wx <= x < x + w <= wx + ww and wy <= y < y + h <= wy + wh):
                    raise ValueError(f'popup outside {workarea}: {packet}')
                placements[sid] = x, y, w, h
            elif not (0 < w <= 640 and 0 < h <= 480 and 0 <= x < parent_size[0] < x + w
                    and 0 <= y < parent_size[1]):
                raise ValueError(f'expected popup straddling the parent’s right edge: {packet}')
            seen.add(sid)
            geometry[sid] = x, y, w, h
            return sid

        def move(sid, x, y):
            click(host_sid(sid), 'MOVE', x, y)
            send(f'I {sid} M {x} {y}')

        def left(target, sid, x, y):
            click(target, 'LEFT', x, y)
            send(f'I {sid} M {x} {y}', f'I {sid} B 1 0', f'I {sid} B 0 0')

        def close_popup(sid):
            wait_for('CLOSED', sid)
            remove_popup(sid)

        closed_before_frame = []

        def remove_popup(sid):
            if tree:
                if sid in owners.values():
                    raise ValueError(f'popup {sid} closed before its child: {owners}')
                del owners[sid]
            del geometry[sid]
            # POPUP registers the guest role; only the first PIXELS maps an AppKit window.
            if sid not in frames:
                closed_before_frame.append(sid)
                return
            del frames[sid]
            if tree:
                alive = ','.join(['0', *sorted(owners.keys() & frames.keys(), key=int)])
                host(f'TREE_CLOSE {sid}', f'TREE_CLOSE_OK {sid} closed={sid} alive={alive}')
            else:
                host('CLOSE', 'CLOSE_OK')

        hover_log = []

        def wait_hover(pattern):
            # A GTK event is the barrier, not elapsed time. Service frame ACKs
            # while waiting so repaints cannot stall GTK; any lifecycle packet
            # (in particular CLOSED) is unexpected during this phase.
            deadline = time.monotonic() + 15
            with selectors.DefaultSelector() as sel:
                sel.register(console.fd, selectors.EVENT_READ, console)
                sel.register(stream.fd, selectors.EVENT_READ, stream)
                start = len(hover_log)
                while (remaining := deadline - time.monotonic()) > 0:
                    buffered = b'\n' in stream.buffer or b'\n' in console.buffer
                    for key, _ in sel.select(0 if buffered else remaining):
                        reader = key.data
                        chunk = reader.read()
                        if not chunk:
                            raise EOFError(f'GTK hover waiting for {pattern!r}: fd {reader.fd} closed')
                        reader.buffer += chunk
                    if b'\n' in stream.buffer:
                        packet = event()
                        if packet[:1] != ['PIXELS']:
                            raise ValueError(f'unexpected frame-port event during hover: {packet}')
                        submit(packet)
                    if b'\n' in console.buffer:
                        raw = console.until(b'\n', remaining) + b'\n'
                        hover_log.append(raw)
                        line = raw.decode('ascii', errors='replace').rstrip('\r\n')
                        if line.startswith(('GTK_MENU ACTION', 'GTK_MENU ROOT HIDE', 'GTK_MENU SUBMENU HIDE',
                                            'GTK_GRAB popup_done', 'GTK_INPUT A button ')):
                            raise ValueError(f'unexpected GTK event during hover: {line}')
                        if re.fullmatch(pattern, line):
                            return b''.join(hover_log[start:]).decode('ascii', errors='replace').splitlines()
            raise TimeoutError(f'waiting for GTK hover {pattern!r}: {b"".join(hover_log)[-3000:]!r}')

        def expect_motion(x):
            # GTK may retarget the widget under its grab. Use the distinctive
            # x to correlate motion, not the widget label (or widget-local y).
            return wait_hover(fr'GTK_HOVER (ROOT|LEAF) MOVE {x} -?\d+(?:\.\d+)?')

        def cross(sid, x, y):
            move(sid, x, y)
            # GDK may fold the first motion into the enter at the same point.
            trace = wait_hover(fr'GTK_HOVER (ROOT|LEAF) ENTER {x} {y}')
            if not any(re.match(r'GTK_HOVER (ROOT|LEAF) LEAVE ', line) for line in trace):
                raise ValueError(f'expected GTK leave before enter at {x},{y}: {trace}')
            print(f'GTK_HOVER_CHECK crossing: target={sid} at {x},{y}, GTK leave then enter', flush=True)

        seen = {parent}
        submit(event())
        if menu_input:
            def serial_line(timeout):
                line = console.until(b'\n', timeout).decode('ascii', 'replace').rstrip('\r')
                print('serial:', line, flush=True)
                if line.startswith('GTK_GRAB_REJECT ') or any(text in line.lower() for text in (
                        'invalid shared request', 'protocol error')):
                    raise ValueError(f'guest protocol error: {line}')
                return line

            def expect_serial(expected):
                deadline = time.monotonic() + 15
                while (remaining := deadline - time.monotonic()) > 0:
                    if serial_line(remaining) == expected:
                        return
                raise TimeoutError(expected)

            # Keep serial evidence off the frame port. Each wait drains all three
            # sources, including complete records already in the readers' buffers.
            def pump(predicate, description, timeout=15):
                deadline = time.monotonic() + timeout
                with selectors.DefaultSelector() as sel:
                    readers = (report, stream, console)
                    for reader in readers:
                        sel.register(reader.fd, selectors.EVENT_READ, reader)
                    while (remaining := deadline - time.monotonic()) > 0:
                        buffered = any(b'\n' in r.buffer for r in readers)
                        for key, _ in sel.select(0 if buffered else remaining):
                            reader = key.data
                            chunk = reader.read()
                            if not chunk:
                                raise EOFError(f'{description}: fd {reader.fd} closed')
                            reader.buffer += chunk
                        if b'\n' in report.buffer:
                            if (reply := host_line(0)) is not None:
                                raise ValueError(f'unexpected host reply: {reply}')
                        if b'\n' in stream.buffer:
                            packet = event()
                            if packet[:1] == ['PIXELS']:
                                submit(packet)
                            elif packet[:1] == ['POPUP'] and len(packet) == 7 and packet[2] in geometry:
                                announce_popup(packet, packet[2])
                            elif packet[:1] == ['CLOSED'] and len(packet) == 2 and packet[1] in owners:
                                remove_popup(packet[1])
                            elif packet[:2] == ['MOVE', parent] and len(packet) == 3 and surface_id(packet[2]):
                                host(f'TREE_BEGIN_MOVE {packet[2]}', f'TREE_BEGIN_MOVE_OK {packet[2]}')
                            else:
                                raise ValueError(f'unexpected frame-port event: {packet}')
                        line = serial_line(0) if b'\n' in console.buffer else None
                        if predicate(line):
                            return
                raise TimeoutError(description)

            def expect(line):
                pump(lambda record: record == line, line)

            def key(code, *states):
                for state in states or (1, 0):
                    host(f'TREE_KEY {code} {state}', f'TREE_KEY_OK {code} {state}')

            if manual:
                if move_probe:
                    print('Drag the bottom strip of the GTK content (not the macOS title bar), then release.', flush=True)
                print('Click the root; try Tab / Shift-Tab. Right-click and press Down once. '
                      f'Press Right {menu_depth - 1} time(s), waiting for each submenu to appear. '
                      'Press Return on the leaf action to finish.', flush=True)
                pump(lambda line: line == 'GTK_MENU ACTION', 'manual submenu activation', 600)
            else:
                click('0', 'LEFT', 10, 10)
                key(48)  # AppKit virtual Tab, not evdev.
                expect('GTK_FOCUS SECOND')
                key(56, 1)
                key(48)
                key(56, 0)
                expect('GTK_FOCUS FIRST')
                key(56, 1)
                expect(f'GTK_KEY_INPUT {parent} 42 1')
                host('TREE_BLUR', 'TREE_BLUR_OK')
                expect(f'GTK_KEY_INPUT {parent} 42 0')

                def mapped_child(owner):
                    if not any(owners.get(sid) == owner for sid in frames):
                        pump(lambda _: any(owners.get(sid) == owner for sid in frames),
                             f'menu frame under {owner}')
                    sid, = (sid for sid in frames if owners.get(sid) == owner)
                    return sid

                def hover_branch(sid, level):
                    _, _, w, h = geometry[sid]
                    y = h * 3 // 4 if level == 1 else h // 2
                    for x in (w // 2 - 4, w // 2, w // 2 + 4):
                        click(sid, 'MOVE', x, y)  # Forwarded by host_line, no injected button.

                def expand(click_branch=False, keyboard_only=False):
                    click('0', 'RIGHT', 120, 48)
                    chain = [mapped_child(parent)]
                    if keyboard_only or hover_from != 1:
                        key(125)  # Down past the initially selected first row.
                        expect('GTK_MENU SELECT ' + ('BRANCH' if menu_depth > 1 else 'ACTION'))
                    while len(chain) < menu_depth:
                        # On the reopened run, enter the hover phase through a
                        # branch click so GTK can reuse that ancestor's press.
                        if click_branch and len(chain) == hover_from - 1:
                            sid = chain[-1]
                            _, _, w, h = geometry[sid]
                            click(sid, 'LEFT', w // 2, h // 2)
                        elif not keyboard_only and hover_from is not None and len(chain) >= hover_from:
                            hover_branch(chain[-1], len(chain))
                        else:
                            key(124)  # Right opens and selects the first item of the next menu.
                        chain.append(mapped_child(chain[-1]))
                    return chain

                chain = expand()
                click('0', 'LEFT', 11, 8)
                for sid in reversed(chain):
                    expect(f'GTK_GRAB popup_done {sid} outside {parent}')
                expect(f'GTK_GRAB swallowed up {parent}')
                if owners:
                    pump(lambda _: not owners, 'cancelled menu windows to close')
                chain = expand(click_branch=hover_from is not None and hover_from >= 3)
                if menu_depth == 7 and hover_from is None:
                    before = len(closed_before_frame)
                    # The first Left deselects the leaf. Subsequent Lefts
                    # deselect the parent item, closing its submenu.
                    key(123)
                    for sid in reversed(chain[3:]):
                        key(123)
                        pump(lambda _: sid not in owners, f'Left to close popup {sid}')
                    if set(owners) != set(chain[:3]):
                        raise ValueError(f'expected three surviving menu levels: {owners}')

                    # After CLOSED confirms the retreat, send the entire burst
                    # before servicing frames or waiting for a popup to map.
                    for _ in range(4):
                        key(124)
                    reopened = chain[:3]
                    # The first Right reselects the branch; the next three open 4–6.
                    for _ in range(3):
                        reopened.append(mapped_child(reopened[-1]))
                    key(124)
                    reopened.append(mapped_child(reopened[-1]))
                    if set(reopened[3:]) & set(chain[3:]) or set(owners) != set(reopened):
                        raise ValueError(f'expected a fresh branch under level 3: {owners}')
                    print('GTK_MENU_REOPEN_OK: 7 -> 3 -> 7, closed before first frame:',
                          ','.join(closed_before_frame[before:]) or 'none observed', flush=True)
                if hover_from is None:
                    key(36)   # Return: activate leaf
                else:
                    _, _, w, h = geometry[chain[-1]]
                    click(chain[-1], 'LEFT', w // 2, h // 2)
                expect('GTK_MENU ACTION')
                if hover_from is not None:
                    print(f'GTK_MENU_DEEP_HOVER_OK: hover from {hover_from} to {menu_depth}', flush=True)
                if left_hover_reopen:
                    if owners:
                        pump(lambda _: not owners, 'initial mixed menu windows to close')
                    print('GTK_MENU_LEFT_HOVER_BEGIN: 7 -> 2 -> 7', flush=True)
                    chain = expand(keyboard_only=True)
                    key(123)  # Deselect the leaf before closing submenus with Left.
                    for sid in reversed(chain[2:]):
                        key(123)
                        pump(lambda _: sid not in owners, f'Left to close popup {sid}')
                    reopened = chain[:2]
                    if set(owners) != set(reopened):
                        raise ValueError(f'expected two surviving menu levels: {owners}')
                    print(f'GTK_MENU_LEFT_HOVER_RETREAT: surviving level 2 sid={reopened[-1]}', flush=True)

                    # Let GTK process the crossing before sending motion within
                    # the row, so GDK cannot fold the whole sequence into enter.
                    # No key or click between the retreat and the hover-opened chain.
                    sid = reopened[-1]
                    _, _, _, h = geometry[sid]
                    click(sid, 'MOVE', 29, h // 2)
                    pump(lambda line: bool(line and line.startswith('GTK_HOVER LEVEL2 ENTER ')),
                         f'pointer enter on surviving level 2 popup {sid}')
                    click(sid, 'MOVE', 30, h // 2)
                    click(sid, 'MOVE', 31, h // 2)
                    reopened.append(mapped_child(sid))
                    while len(reopened) < menu_depth:
                        hover_branch(reopened[-1], len(reopened))
                        reopened.append(mapped_child(reopened[-1]))
                    if set(owners) != set(reopened):
                        raise ValueError(f'expected only the reopened menu chain: {owners}')
                    _, _, w, h = geometry[reopened[-1]]
                    click(reopened[-1], 'LEFT', w // 2, h // 2)
                    expect('GTK_MENU ACTION')
                    print('GTK_MENU_LEFT_HOVER_OK: 7 -> 2 -> 7, leaf selected', flush=True)
            if owners:
                pump(lambda _: not owners, 'menu windows to close')
            send(f'I {parent} C 0 0')
            wait_for('CLOSED', parent)
            del geometry[parent]
            expect_serial('GTK_MENU_CLIENT_EXIT_OK')
            send('STOP')
            if event() != ['DONE']:
                raise ValueError('expected input server DONE')
            win.stdin.close()
            host(None, 'CLEANUP_OK')
            expect_serial('GTK_MENU_GUEST_CLEAN')
            vm.stdin.write(b'poweroff\n')
            if win.wait(timeout=10) or stream.buffer or port.recv(1) or vm.wait(timeout=20):
                raise ValueError('input session cleanup')
            print('GTK_MENU_INPUT_OK:', 'manual' if manual else 'synthetic', flush=True)
            return
        if edge:
            workarea = host('EDGE', r'WORKAREA -?\d+ -?\d+ [1-9]\d* [1-9]\d*').split()[1:]
            wx, wy, ww, wh = map(int, workarea)
            send(f'W {parent} ' + ' '.join(workarea))
            placements = {}
        rounds = []
        for select in (True, False):
            root, frame = open_menu()
            x, _, w, h = geometry[root]
            if tree:
                cx, cy = w // 2, h // 2
                if select:
                    move(root, cx, cy)
                else:
                    left(root, root, cx, cy)
                leaf, _ = receive_popup(root)
                rounds.append((root, leaf))
                if select:
                    _, _, lw, lh = geometry[leaf]
                    lx, ly = lw // 2, lh // 2
                    if hover:
                        # The first MOVE is left alone until the leaf maps;
                        # the grab trace confirms hover (not a click) opened it.
                        wait_hover(fr'GTK_GRAB SUBMENU begin {leaf} parent {root} serial [1-9]\d*')
                        print('GTK_HOVER_CHECK dwell: submenu mapped without a button', flush=True)
                        move(parent, 11, 8)
                        move(root, cx + 2, cy)
                        trace = expect_motion(cx + 2)
                        if any(line.startswith('GTK_HOVER PARENT ') or re.match(r'GTK_HOVER \S+ MOVE 11 ', line)
                               for line in trace):
                            raise ValueError(f'outside motion escaped the GTK grab: {trace}')
                        print('GTK_HOVER_CHECK parent-target MOVE: grab retained, root-target motion received', flush=True)
                        cross(leaf, lx, ly)
                        cross(root, cx - 2, cy)
                        cross(leaf, lx + 2, ly)
                        move(leaf, lx + 4, ly)
                        expect_motion(lx + 4)
                        print('GTK_HOVER_CHECK leaf motion delivered without activation; now select', flush=True)
                    left(leaf, leaf, lx, ly)
                else:
                    left('0', parent, 11, 8)
                close_popup(leaf)
            else:
                rounds.append((root, None))
                if select:
                    # Normal mode hits the center row beyond the parent's right edge.
                    cx, cy = w // 2 if edge else max(w // 2, parent_size[0] - x), h // 2
                    if cx >= w or frame[(cy*w + cx)*4 + 3] != 255:
                        raise ValueError(f'no opaque menu item center at {cx},{cy}')
                    left('POPUP_EDGE' if edge else 'POPUP', root, cx, cy)
                else:
                    left('PARENT', parent, 11, 8)
            close_popup(root)
        (first, _), (second, second_leaf) = rounds

        send(f'I {parent} C 0 0')
        wait_for('CLOSED', parent)
        client_log = console.until(b'GTK_MENU_CLIENT_EXIT_OK\r\n', 15)
        send('STOP')
        try:
            if event() != ['DONE']:
                raise ValueError('expected GTK menu server DONE')
        except (TimeoutError, EOFError) as error:
            error.add_note(f'GTK serial before STOP: {client_log[-3000:]!r}')
            try:
                tail = console.until(b'localhost:~# ', 2)
                error.add_note(f'GTK serial after STOP: {tail[-3000:]!r}')
            except (TimeoutError, EOFError) as serial_error:
                error.add_note(str(serial_error))
            raise
        win.stdin.close()
        host(None, 'CLEANUP_OK')
        if win.wait(timeout=10):
            raise ValueError('menu-host exit status')

    # The shell marker follows both process exits, so absence checks cover the
    # complete session (including late GTK events), without a sleep window.
    log = b''.join(hover_log) + client_log + console.until(b'GTK_MENU_GUEST_CLEAN\r\n', 15)
    lines = log.decode('ascii', errors='replace').splitlines()
    prefixes = ('GTK_MENU ', 'GTK_GRAB ', 'GTK_INPUT A button ')
    evidence = [line for line in lines if line.startswith(prefixes)]
    if hover:
        prefixes += ('GTK_HOVER ',)
    for line in lines:
        if line.startswith(prefixes):
            print('serial:', line, flush=True)
    cycle = (['GTK_MENU OPEN', 'GTK_MENU ROOT SHOW', 'GTK_MENU SUBMENU SHOW',
              'GTK_MENU SUBMENU HIDE', 'GTK_MENU ROOT HIDE'] if tree else ['GTK_MENU OPEN', 'GTK_MENU DISMISS'])
    if [line for line in evidence if line.startswith('GTK_MENU ')] != cycle + ['GTK_MENU ACTION'] + cycle:
        raise ValueError('unexpected GTK menu signal order/count')
    if any(line.startswith('GTK_INPUT A button ') for line in evidence):
        raise ValueError('GTK parent received a button event')
    if edge:
        traces = [line for line in lines if line.startswith('GTK_MENU_EDGE ')]
        if len(traces) != 2:
            raise ValueError(f'expected two GTK menu placement traces: {traces}')
        for sid, trace in zip((first, second), traces):
            print('serial:', trace, flush=True)
            x, y, w, h = placements[sid]
            match = re.fullmatch(fr'GTK_MENU_EDGE parent={parent} popup={sid} raw=(-?\d+),(-?\d+) '
                                 fr'adjusted={x},{y} size={w},{h} work={wx},{wy},{ww},{wh} flags=\d+', trace)
            if not match:
                raise ValueError(f'placement trace disagrees with host/guest geometry: {trace}')
            raw_x, raw_y = map(int, match.groups())
            if raw_x + w <= wx + ww or raw_y + h <= wy + wh:
                raise ValueError(f'raw popup did not overflow both right and bottom: {trace}')
    grabs = [line for line in evidence if line.startswith('GTK_GRAB ')]
    if tree:
        expected = []
        for root, leaf in rounds:
            expected.append(fr'GTK_GRAB ROOT begin {root} parent {parent} serial [1-9]\d*')
            expected.append(fr'GTK_GRAB SUBMENU begin {leaf} parent {root} serial [1-9]\d*')
        expected.extend([f'GTK_GRAB popup_done {second_leaf} outside {parent}',
                         f'GTK_GRAB popup_done {second} outside {parent}', f'GTK_GRAB swallowed up {parent}'])
        if len(grabs) != len(expected) or not all(re.fullmatch(p, g) for p, g in zip(expected, grabs)):
            raise ValueError(f'unexpected GTK tree grab trace: {grabs}')
    elif (len(grabs) != 4 or not re.fullmatch(fr'GTK_GRAB begin {first} [1-9][0-9]*', grabs[0])
            or not re.fullmatch(fr'GTK_GRAB begin {second} [1-9][0-9]*', grabs[1])
            or grabs[2:] != [f'GTK_GRAB popup_done {second} outside {parent}', f'GTK_GRAB swallowed up {parent}']):
        raise ValueError('unexpected GTK popup grab trace')

    vm.stdin.write(b'poweroff\n')
    if stream.buffer or port.recv(1) or vm.wait(timeout=20):
        raise ValueError('GTK menu VM cleanup')
    selection = ('GTK_MENU_TREE_HOVER_SMOKE_OK: hover without activation, then selected submenu action' if hover else
                 'GTK_MENU_TREE_SMOKE_OK: selected submenu action' if tree else
                 'GTK_MENU_EDGE_SMOKE_OK: selected adjusted popup' if edge else
                 'GTK_MENU_SMOKE_OK: selected outside parent')
    print(selection + ', dismissed on parent click without click-through; guest socket removed, VM exited', flush=True)


def vm_command(work, iso, ports=1, *, block_payload=False):
    for kind in ('vmlinuz', 'initramfs'):
        with (work / kind).open('wb') as out:
            sp.run(['bsdtar', '-xOf', iso, f'boot/{kind}-lts'], stdout=out, check=True)
    cmd = ['qemu-system-x86_64', '-machine', 'q35,accel=hvf', '-cpu', 'host',
           '-m', '512M,slots=1,maxmem=1G', '-nic', 'none', '-display', 'none',
           '-monitor', 'none', '-serial', 'stdio', '-no-reboot', '-kernel', 'vmlinuz',
           '-initrd', 'initramfs', '-cdrom', str(iso), '-append',
           'console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod',
           '-object', 'memory-backend-file,id=r,size=32M,mem-path=region,share=on',
           '-device', 'virtio-pmem-pci,memdev=r', '-device', 'virtio-serial-pci,id=v']
    if not block_payload:
        cmd += ['-fw_cfg', 'name=opt/sclereid/m2,file=guest.tar']
    for i in range(ports):
        name = 'frames' if not i else f'frames{i}'
        cmd.extend(['-chardev', f'socket,id=f{i},path=./{name},server=on,wait=off',
                    '-device', f'virtserialport,bus=v.0,nr={i+1},chardev=f{i},name={name}'])
    return cmd


def run(work, iso, animate, slots, seconds, weston, disconnect=False, retina=False, shared=False, reconnect=False, output_scale=None, gtk=False, popup=False, gtk_menu=False, gtk_menu_edge=False, gtk_menu_tree=False, gtk_menu_tree_hover=False, gtk_menu_input=False, manual=False, menu_depth=2, hover_from=None, wayland_trace=False, *, diagnostics=None):
    tree = gtk_menu_tree or gtk_menu_tree_hover or gtk_menu_input
    menu = gtk_menu or gtk_menu_edge or tree
    cmd = vm_command(work, iso, block_payload=True)
    payload = 'gtk.tar' if gtk or menu else 'guest.tar'
    with (work / payload).open('ab') as archive:
        archive.write(bytes(-archive.tell() % 512))
    cmd += ['-drive', f'if=virtio,format=raw,readonly=on,file={payload}']
    with (work / 'region').open('xb+') as file:
        file.truncate(REGION_BYTES)
        with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as region, child(cmd, work) as vm:
            assert vm.stdin is not None and vm.stdout is not None
            console = Reader(vm.stdout.fileno(), diagnostics, 'guest_serial')
            console.until(b'localhost login:', 90)
            vm.stdin.write(b'root\n')
            console.until(b'localhost:~# ', 10)
            vm.stdin.write(b'stty -echo\n')
            console.until(b'localhost:~# ', 10)
            with socket.socket(socket.AF_UNIX) as port:
                port.settimeout(10)
                previous = os.getcwd()
                try:
                    os.chdir(work)
                    port.connect('frames')
                finally:
                    os.chdir(previous)
                guest_input = vm.stdin

                def setup_step(command: bytes, marker: bytes, timeout: int):
                    guest_input.write(command + b' && echo ' + marker + b'\n')
                    console.until(marker + b'\r\n', timeout)
                    console.until(b'localhost:~# ', 10)
                    print(marker.decode(), flush=True)

                setup_step(b'modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && '
                           b'modprobe virtio_console && mdev -s && apk add --no-network e2fsprogs',
                           b'M2_MODULES_READY', 45)
                setup_step(b'mkfs.ext4 -F -b 4096 /dev/pmem0', b'M2_FORMATTED', 45)
                setup_step(b'mount -t ext4 -o dax=always /dev/pmem0 /mnt', b'M2_MOUNTED', 45)
                setup_step(b'modprobe virtio_blk && mdev -s && mkdir -m 700 /tmp/bridge /tmp/m2 && '
                           b'tar -xzf /dev/vda -C /tmp/bridge', b'GUEST_READY', 45)

                if menu:
                    return gtk_menu_smoke(work, vm, port, region, console, edge=gtk_menu_edge,
                                          tree=tree, hover=gtk_menu_tree_hover, menu_input=gtk_menu_input, manual=manual, menu_depth=menu_depth,
                                                                                    hover_from=hover_from, wayland_trace=wayland_trace)
                if popup:
                    return popup_smoke(work, vm, port, region, console)
                if shared or gtk:
                    previous_frames = shared_smoke(work, vm, port, region, console,
                                                   output_scale, not (reconnect or disconnect), abrupt=disconnect, gtk=gtk)
                    if shared and (reconnect or disconnect):
                        port.close()
                        vm.stdin.write(b'echo BETWEEN_SESSIONS\n')
                        console.until(b'BETWEEN_SESSIONS\r\n',10)
                        with socket.socket(socket.AF_UNIX) as replacement:
                            replacement.settimeout(10)
                            os.chdir(work)
                            try:
                                replacement.connect('frames')
                            finally:
                                os.chdir(previous)
                            shared_smoke(work, vm, replacement, region, console, output_scale, session=2,
                                         previous_frames=previous_frames)
                        print('RECONNECT_OK: fresh shared session on the same live VM')
                    return
                client = b'/tmp/bridge/weston-simple-shm' if weston else b'/tmp/bridge/bridge client'
                vm.stdin.write(
                    b'(export XDG_RUNTIME_DIR=/tmp/m2 WAYLAND_DISPLAY=m2 LD_LIBRARY_PATH=/tmp/bridge; '
                    + (f'export M2_ANIMATE=1 M2_SLOTS={slots} M2_SECONDS={seconds}; '.encode('ascii')
                       if animate else b'export M2_XDG=1; ' if weston else b'export M2_RETINA=1; ' if retina else b'') +
                    b'set -- /dev/vport*p1; test -c "$1" || exit 1; exec 3<>"$1"; '
                    b'/tmp/bridge/bridge server <&3 >&3 & server=$!; '
                    b'for i in 1 2 3 4 5; do test -S /tmp/m2/m2 && break; sleep 1; done; '
                    + client + b' && wait "$server" && test ! -e /tmp/m2/m2 && '
                    b'echo GUEST_CLEANUP_OK)\n')
                frame_port = Reader(port.fileno())
                window_args = ['--animate'] if animate else ['--weston'] if weston else ['--retina'] if retina else []
                with child([work / 'window', *window_args], work, host_diagnostics=diagnostics) as window:
                    assert window.stdin is not None and window.stdout is not None
                    report = Reader(window.stdout.fileno(), diagnostics, 'host')
                    if weston:
                        try:
                            play_weston(port, frame_port, region, window, report,
                                        vm.kill if disconnect else None)
                        except (EOFError, OSError, ValueError) as error:
                            try:
                                window.stdin.close()
                                if report.until(b'\n', 10) != b'CLEANUP_OK' or window.wait(timeout=10):
                                    error.add_note('AppKit cleanup acknowledgement missing')
                            except (EOFError, OSError, sp.TimeoutExpired) as cleanup_error:
                                error.add_note(f'AppKit cleanup failed: {cleanup_error}')
                            raise
                        if disconnect:
                            vm.wait(timeout=10)
                            window.stdin.close()
                            if report.until(b'\n', 10) != b'CLEANUP_OK' or window.wait(timeout=10):
                                raise RuntimeError('window cleanup failed after VM loss')
                            print('DISCONNECT_OK: VM lost with frame in flight; window closed', flush=True)
                            return
                    elif animate:
                        count = play_animation(port, frame_port, region, window, report, slots, seconds)
                        console.until(b'ANIM_STATS ', 10)
                        stats = console.until(b'\r\n', 10)
                        if not re.fullmatch(rb'[0-9]+( [0-9]+){4}', stats):
                            raise ValueError(f'invalid guest statistics: {stats!r}')
                        sent, expired, no_slot, late, peak = map(int, stats.split())
                        if (sent != count or sent + expired + no_slot != seconds * 60
                                or not 0 <= late <= sent or not 1 <= peak <= slots):
                            raise ValueError(f'inconsistent guest statistics: {stats!r}')
                        print(f'GUEST_STATS expired={expired} no_slot={no_slot} late={late} peak={peak}', flush=True)
                    else:
                        if frame_port.until(b'\n', 20) != (b'FRAME 64 48 2' if retina else b'FRAME 64 48 1'):
                            raise ValueError('invalid frame notification')
                        frame = extract(region)
                        print('DAX_FRAME_OK: 12288 bytes verified', flush=True)
                        window.stdin.write(frame)
                        if retina:
                            evidence = report.until(b'\n', 15)
                            if not re.fullmatch(rb'RETINA_OK logical=32x24 backing=(32x24|64x48) buffer=64x48', evidence):
                                raise ValueError(evidence)
                            print(evidence.decode(), flush=True)
                        if report.until(b'\n', 15) != b'WINDOW_OK':
                            raise ValueError('unexpected window response')
                        print('WINDOW_OK', flush=True)
                        port.sendall(b'ACK\n')
                    console.until(b'GUEST_CLEANUP_OK\r\n', 10)
                    vm.stdin.write(b'poweroff\n')
                    if port.recv(1) != b'':
                        raise ValueError('expected frame-port EOF')
                    vm_status = vm.wait(timeout=15)
                    window.stdin.close()
                    if report.until(b'\n', 10) != b'CLEANUP_OK' or window.wait(timeout=10):
                        raise RuntimeError('window cleanup failed')
                    if vm_status:
                        raise RuntimeError(f'QEMU exited with status {vm_status}')
                    print('CLEANUP_OK: guest socket removed, VM exited, window closed after EOF', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso', type=Path, help='pinned Alpine standard 3.22.2 x86_64 ISO')
    parser.add_argument('--apks', type=Path, help='use predownloaded, pinned build APKs instead of fetching')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--popup', action='store_true', help='verify a scale-1 XDG popup with an AppKit child window')
    modes.add_argument('--gtk', action='store_true', help='run two GTK 3 toplevels on the shared compositor')
    modes.add_argument('--gtk-menu', action='store_true', help='verify a scale-1 GTK 3 menu in an AppKit child window')
    modes.add_argument('--gtk-menu-input', action='store_true', help='verify AppKit input forwarding to GTK menus')
    parser.add_argument('--menu-depth', type=int, choices=range(1, 8), help='with --gtk-menu-input, number of menu levels including root (default: 2)')
    parser.add_argument('--hover-from', type=int, help='with --gtk-menu-input, open children from this level by motion; depth 7 / level 2 also traces and checks hover reopening after Left')
    parser.add_argument('--wayland-trace', action='store_true', help='with --gtk-menu-input, print GTK client Wayland requests and events')
    parser.add_argument('--manual', action='store_true', help='with --gtk-menu-input, use real window input; activate the submenu action to finish')
    modes.add_argument('--gtk-menu-tree', action='store_true', help='select and dismiss nested GTK 3 menus')
    modes.add_argument('--gtk-menu-tree-hover', action='store_true', help='verify button-free hover across nested GTK 3 menus, then select and dismiss')
    modes.add_argument('--gtk-menu-edge', action='store_true', help='verify GTK menu placement at the bottom-right work area edge')
    modes.add_argument('--shared', action='store_true', help='exercise shared XDG compositor and client crash isolation')
    modes.add_argument('--retina', action='store_true', help='verify a scale-2 SHM commit on a Retina display')
    modes.add_argument('--weston', action='store_true', help='run the stock weston-simple-shm XDG client')
    modes.add_argument('--animate', action='store_true', help='benchmark 640x360 window updates at 60 Hz')
    parser.add_argument('--slots', type=int, choices=range(1, 5), default=1, help='animation pipeline depth (default: 1)')
    parser.add_argument('--seconds', type=int, default=3, help='animation duration, 1–30 seconds (default: 3)')
    parser.add_argument('--disconnect', action='store_true', help='with --weston, stop QEMU; with --shared, drop the frame port and reconnect; with --gtk, terminate the client with frames pending')
    parser.add_argument('--output-scale', type=int, choices=(1, 2), help='override shared output advertisement (default: AppKit backing)')
    parser.add_argument('--reconnect', action='store_true', help='with --shared, reconnect after draining the session')
    parser.add_argument('--sidecar-port', type=int, metavar='PORT',
                        help='start the optional protocol diagnostics sidecar on PORT')
    args = parser.parse_args()
    if args.sidecar_port is not None and not 1 <= args.sidecar_port <= 65535:
        parser.error('--sidecar-port requires a port in 1–65535')
    if args.menu_depth is not None and not args.gtk_menu_input: parser.error('--menu-depth requires --gtk-menu-input')
    if args.hover_from is not None and (not args.gtk_menu_input or args.manual or not 1 <= args.hover_from < (args.menu_depth or 2)):
        parser.error('--hover-from requires synthetic --gtk-menu-input and a level before the leaf')
    if args.wayland_trace and not args.gtk_menu_input: parser.error('--wayland-trace requires --gtk-menu-input')
    if args.manual and not args.gtk_menu_input: parser.error('--manual requires --gtk-menu-input')
    if args.output_scale and not (args.shared or args.gtk):
        parser.error('--output-scale requires --shared or --gtk')
    if args.reconnect and not args.shared: parser.error('--reconnect requires --shared')
    if args.disconnect and not (args.weston or args.shared or args.gtk):
        parser.error('--disconnect requires --weston, --shared, or --gtk')
    if not 1 <= args.seconds <= 30 or (not args.animate and (args.slots != 1 or args.seconds != 3)):
        parser.error('--slots and --seconds are animation options; require 1–30 seconds')
    with Diagnostics().collect(args.sidecar_port) as diagnostics:
        phase = 'verify_iso'
        try:
            iso = args.iso.resolve(strict=True)
            verify(iso, ISO_SHA)
            phase = 'build'
            # Short directory keeps the virtio-serial Unix socket under macOS sun_path limits.
            with tempfile.TemporaryDirectory(prefix='scl-m2-', dir=os.environ.get('COMMANDCODE_SCRATCHPAD', '/tmp')) as directory:
                work = Path(directory)
                build(work, args.apks, args.weston,
                      args.gtk or args.gtk_menu or args.gtk_menu_edge or args.gtk_menu_tree or args.gtk_menu_tree_hover or args.gtk_menu_input)
                phase = 'run'
                run(work, iso, args.animate, args.slots, args.seconds, args.weston, args.disconnect, args.retina,
                    args.shared, args.reconnect, args.output_scale, args.gtk, args.popup, gtk_menu=args.gtk_menu, gtk_menu_edge=args.gtk_menu_edge,
                    gtk_menu_tree=args.gtk_menu_tree, gtk_menu_tree_hover=args.gtk_menu_tree_hover, gtk_menu_input=args.gtk_menu_input, manual=args.manual, menu_depth=args.menu_depth or 2,
                    hover_from=args.hover_from, wayland_trace=args.wayland_trace, diagnostics=diagnostics)
            print('SCLEREID_M2_OK', flush=True)
            diagnostics.emit('info', 'driver', 'SCLEREID_M2_OK', 'Smoke test completed')
        except (Exception, KeyboardInterrupt) as error:
            diagnostics.failure(phase, error)
            raise


if __name__ == '__main__':
    main()
