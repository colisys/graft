#!/usr/bin/env python3
"""One-shot Intel HVF → Wayland SHM → ext4 DAX → AppKit smoke test."""
import argparse
from contextlib import ExitStack, contextmanager
import hashlib
import mmap
import os
from pathlib import Path
import selectors
import shutil
import socket
import struct
import threading
import math
import re
import subprocess as sp
import tempfile
import time

HERE = Path(__file__).resolve().parent
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


@contextmanager
def child(cmd, work, **kwargs):
    with sp.Popen(cmd, cwd=work, stdin=sp.PIPE, stdout=sp.PIPE, bufsize=0, **kwargs) as proc:
        try:
            yield proc
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=10)


class Reader:
    def __init__(self, fd):
        self.fd = fd
        self.buffer = b''

    def until(self, marker, timeout):
        end = time.monotonic() + timeout
        with selectors.DefaultSelector() as sel:
            sel.register(self.fd, selectors.EVENT_READ)
            while marker not in self.buffer:
                if not sel.select(max(0, end - time.monotonic())):
                    raise TimeoutError(f'waiting for {marker!r}: {self.buffer[-3000:]!r}')
                chunk = os.read(self.fd, 8192)
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
    if not count:
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
    vm.stdin.write(env + b'rm -f /tmp/server-ok /tmp/client-ok; set -- /dev/vport*p1; exec 3<>"$1"; (/tmp/bridge/bridge server <&3 >&3 && touch /tmp/server-ok) & server=$!; '
                   b'for i in 1 2 3 4 5; do test -S /tmp/m2/m2 && break; sleep 1; done; ' +
                   (b'XKB_CONFIG_ROOT=/tmp/bridge/xkb WAYLAND_DEBUG=client /tmp/bridge/gtk-client 3>&- & victim=$!\n' if gtk else
                    b'M2_VICTIM=1 /tmp/bridge/bridge client & victim=$!\n'))
    with ExitStack() as stack:
        windows, frames = {}, {}
        dropping = threading.Event()
        def opened():
            op, sid = line()
            if op != 'OPEN' or sid in windows: raise ValueError((op, sid))
            rx, tx = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            stack.enter_context(rx)
            thread = None
            def join_forwarder():
                if thread is not None:
                    thread.join(10)
            stack.callback(join_forwarder)
            with tx:
                win = stack.enter_context(child([work / 'window', '--weston'], work,
                    env={**os.environ, 'M2_INPUT_FD': str(tx.fileno())}, pass_fds=(tx.fileno(),)))
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
            windows[sid] = win, Reader(win.stdout.fileno())
            return sid
        def pixels(expected, seq, width=64, height=48, remap=False):
            packet = line()
            if len(packet) != 7: raise ValueError(packet)
            op, sid, n, slot, w, h, scale = packet
            if int(scale) != (1 if sid == b else advertised): raise ValueError((sid,scale))
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
            if frame != expected_frame: raise ValueError('shared DAX frame bytes')
            win, report = windows[sid]
            data = memoryview(struct.pack('<HHH',width,height,int(scale))+frame)
            while data:
                n = win.stdin.write(data)
                if not n: raise EOFError('window pipe')
                data = data[n:]
            if remap and report.until(b'\n',15) != b'REMAPPED': raise ValueError('window remap')
            geometry = report.until(b'\n',15).decode().split()
            lw, lh = width//int(scale), height//int(scale)
            if geometry != ['GEOMETRY', str(lw), str(lh), 'backing', str(lw*native), str(lh*native)]:
                raise ValueError(geometry)
            print('surface',sid,*geometry)
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
            sizes = set()
            try:
                while len(sizes) < 2:
                    packet = line()
                    if packet[0] == 'OPEN' and len(packet) == 2:
                        stream.buffer = (' '.join(packet) + '\n').encode() + stream.buffer
                        opened()
                        continue
                    op,sid,n,slot,w,h,scale = packet
                    w,h,scale = map(int,(w,h,scale))
                    if op != 'PIXELS' or n != '1' or sid not in windows or sid in ids or scale != 1 or (w,h) not in {(128,96),(160,96)}:
                        raise ValueError(packet)
                    marker = MARKER[:-1] + bytes([MARKER[-1]+int(slot)])
                    off = region.find(marker)
                    if not 0 <= int(slot) < 8 or off < 0 or off % 4096 or off in frames.values():
                        raise ValueError(packet)
                    frames[sid] = off
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
                    if geometry != f'GEOMETRY {w} {h} backing {w*native} {h*native}'.encode() or not report.until(b'\n',15).startswith(b'FRAME_OK '):
                        raise ValueError(geometry)
                    ids.add(sid)
                    sizes.add((w,h))
                    print(f'GTK_FRAME surface={sid} slot={slot} {geometry.decode()} sha256={hashlib.sha256(frame).hexdigest()}', flush=True)
                if set(windows) != ids: raise ValueError('unexpected GTK toplevels')
                vm.stdin.write(b'kill -0 "$victim" && echo GTK_ALIVE; kill -TERM "$victim"; wait "$victim"\n')
                console.until(b'GTK_ALIVE\r\n', 10)
                closed(ids.copy())
                for sid in ids:
                    port.sendall(f'ACK {sid} 1\n'.encode())
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
        pixels(a,1); pixels(b,1)
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
        pixels(c,2); port.sendall(f'ACK {c} 2\n'.encode())
        def command(code):
            win, report = windows[c]
            win.stdin.write(struct.pack('<HH', 0, code))
            if report.until(b'\n', 10) != b'COMMAND_OK': raise ValueError(f'window command {code}')
        command(5)
        pixels(c,3,160*advertised,120*advertised)
        print(f'RESIZE_OK: surface {c} logical=160x120 buffer={160*advertised}x{120*advertised}')
        port.sendall(f'ACK {c} 3\n'.encode())
        if line() != ['UNMAP', c]: raise ValueError('expected explicit unmap')
        command(4)
        print(f'UNMAP_OK: surface {c} gone from WindowServer')
        pixels(c,4,remap=True)
        inject(c,'S0')
        port.sendall(f'ACK {c} 4\n'.encode())
        print(f'REMAP_OK: surface {c} reused slot {frames[c][0]} and accepted input')
        command(2)
        closed({c})
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


def vm_command(work, iso, ports=1):
    for kind in ('vmlinuz', 'initramfs'):
        with (work / kind).open('wb') as out:
            sp.run(['bsdtar', '-xOf', iso, f'boot/{kind}-lts'], stdout=out, check=True)
    cmd = ['qemu-system-x86_64', '-machine', 'q35,accel=hvf', '-cpu', 'host',
           '-m', '512M,slots=1,maxmem=1G', '-nic', 'none', '-display', 'none',
           '-monitor', 'none', '-serial', 'stdio', '-no-reboot', '-kernel', 'vmlinuz',
           '-initrd', 'initramfs', '-cdrom', str(iso), '-append',
           'console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod',
           '-object', 'memory-backend-file,id=r,size=32M,mem-path=region,share=on',
           '-device', 'virtio-pmem-pci,memdev=r', '-device', 'virtio-serial-pci,id=v',
           '-fw_cfg', 'name=opt/sclereid/m2,file=guest.tar']
    for i in range(ports):
        name = 'frames' if not i else f'frames{i}'
        cmd.extend(['-chardev', f'socket,id=f{i},path=./{name},server=on,wait=off',
                    '-device', f'virtserialport,bus=v.0,nr={i+1},chardev=f{i},name={name}'])
    return cmd


def run(work, iso, animate, slots, seconds, weston, disconnect=False, retina=False, shared=False, reconnect=False, output_scale=None, gtk=False):
    cmd = vm_command(work, iso)
    if gtk:
        with (work / 'gtk.tar').open('ab') as archive:
            archive.write(bytes(-archive.tell() % 512))
        cmd += ['-drive', 'if=virtio,format=raw,readonly=on,file=gtk.tar']
    with (work / 'region').open('xb+') as file:
        file.truncate(REGION_BYTES)
        with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as region, child(cmd, work) as vm:
            console = Reader(vm.stdout.fileno())
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
                if not gtk:
                    vm.stdin.write(
                        b'modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && '
                        b'modprobe virtio_console && modprobe qemu_fw_cfg && mdev -s && '
                        b'apk add --no-network e2fsprogs && mkfs.ext4 -F -b 4096 /dev/pmem0 && '
                        b'mount -t ext4 -o dax=always /dev/pmem0 /mnt && '
                        b'mkdir -m 700 /tmp/bridge /tmp/m2 && '
                        b'tar -xzf /sys/firmware/qemu_fw_cfg/by_name/opt/sclereid/m2/raw -C /tmp/bridge && '
                        b'echo GUEST_READY\n')
                    console.until(b'GUEST_READY\r\n', 180)
                else:
                    vm.stdin.write(
                        b'modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && '
                        b'modprobe virtio_console && modprobe qemu_fw_cfg && mdev -s && '
                        b'apk add --no-network e2fsprogs && mkfs.ext4 -F -b 4096 /dev/pmem0 && echo M2_FORMATTED\n')
                    console.until(b'M2_FORMATTED\r\n', 45)
                    vm.stdin.write(b'mount -t ext4 -o dax=always /dev/pmem0 /mnt && echo M2_MOUNTED\n')
                    console.until(b'M2_MOUNTED\r\n', 45)
                    console.until(b'localhost:~# ', 10)
                    setup = (b'modprobe virtio_blk && mdev -s && tar -xzf /dev/vda -C /tmp/bridge' if gtk else
                             b'tar -xzf /sys/firmware/qemu_fw_cfg/by_name/opt/sclereid/m2/raw -C /tmp/bridge')
                    vm.stdin.write(b'mkdir -m 700 /tmp/bridge /tmp/m2 && ' + setup + b' && echo GUEST_READY\n')
                    console.until(b'GUEST_READY\r\n', 25)

                if shared or gtk:
                    previous_frames = shared_smoke(work, vm, port, region, console,
                                                   output_scale, not (reconnect or disconnect), abrupt=disconnect, gtk=gtk)
                    if reconnect or disconnect:
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
                with child([work / 'window', *window_args], work) as window:
                    report = Reader(window.stdout.fileno())
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
    modes.add_argument('--gtk', action='store_true', help='run two GTK 3 toplevels on the shared compositor')
    modes.add_argument('--shared', action='store_true', help='exercise shared XDG compositor and client crash isolation')
    modes.add_argument('--retina', action='store_true', help='verify a scale-2 SHM commit on a Retina display')
    modes.add_argument('--weston', action='store_true', help='run the stock weston-simple-shm XDG client')
    modes.add_argument('--animate', action='store_true', help='benchmark 640x360 window updates at 60 Hz')
    parser.add_argument('--slots', type=int, choices=range(1, 5), default=1, help='animation pipeline depth (default: 1)')
    parser.add_argument('--seconds', type=int, default=3, help='animation duration, 1–30 seconds (default: 3)')
    parser.add_argument('--disconnect', action='store_true', help='with --weston, stop QEMU; with --shared, drop the frame port and reconnect')
    parser.add_argument('--output-scale', type=int, choices=(1, 2), help='override shared output advertisement (default: AppKit backing)')
    parser.add_argument('--reconnect', action='store_true', help='with --shared, reconnect after draining the session')
    args = parser.parse_args()
    if args.output_scale and not args.shared: parser.error('--output-scale requires --shared')
    if args.reconnect and not args.shared: parser.error('--reconnect requires --shared')
    if args.disconnect and not (args.weston or args.shared):
        parser.error('--disconnect requires --weston or --shared')
    if not 1 <= args.seconds <= 30 or (not args.animate and (args.slots != 1 or args.seconds != 3)):
        parser.error('--slots and --seconds are animation options; require 1–30 seconds')
    iso = args.iso.resolve(strict=True)
    verify(iso, ISO_SHA)
    # Short directory keeps the virtio-serial Unix socket under macOS sun_path limits.
    with tempfile.TemporaryDirectory(prefix='scl-m2-', dir=os.environ.get('COMMANDCODE_SCRATCHPAD', '/tmp')) as directory:
        work = Path(directory)
        build(work, args.apks, args.weston, args.gtk)
        run(work, iso, args.animate, args.slots, args.seconds, args.weston, args.disconnect, args.retina, args.shared, args.reconnect, args.output_scale, args.gtk)
    print('SCLEREID_M2_OK', flush=True)


if __name__ == '__main__':
    main()
