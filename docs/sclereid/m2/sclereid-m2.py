#!/usr/bin/env python3
"""One-shot Intel HVF → Wayland SHM → ext4 DAX → AppKit smoke test."""
import argparse
from contextlib import contextmanager
import hashlib
import mmap
import os
from pathlib import Path
import selectors
import socket
import math
import re
import subprocess as sp
import tempfile
import time

HERE = Path(__file__).resolve().parent
ISO_SHA = 'f6a265f0696d328c8f87814a0d6bfa362d1434e500cb80a48796b1c9d204cee0'
APK_BASE = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/'
PACKAGES = {
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


def build(work, packages, weston):
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
    libs = [lib / name for name in ('libwayland-client.so.0', 'libwayland-server.so.0', 'libffi.so.8')]
    sp.run(['zig', 'cc', '-target', 'x86_64-linux-musl', '-dynamic', '-std=c11', '-O2',
            '-Wall', '-Wextra', '-Werror', '-I', headers / 'usr/include',
            HERE / 'sclereid-m2-guest.c', *libs, '-o', bundle / 'bridge'],
           cwd=work, check=True, timeout=120)
    for library in libs:
        (bundle / library.name).write_bytes(library.read_bytes())
    if weston:
        from sclereid_m2_west import stage
        stage(bundle, fetch)
    sp.run(['bsdtar', '-cf', work / 'guest.tar', '--format', 'ustar', '-C', bundle, '.'], check=True)
    sp.run(['swiftc', '-O', HERE / 'sclereid-m2-window.swift', '-o', work / 'window'],
           cwd=work, check=True, timeout=90)


@contextmanager
def child(cmd, work):
    with sp.Popen(cmd, cwd=work, stdin=sp.PIPE, stdout=sp.PIPE, bufsize=0) as proc:
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


def play_weston(port, stream, region, window, report):
    offset = None
    frames = set()
    size = 250 * 250 * 4
    for tick in range(12):
        line = stream.until(b'\n', 15)
        if line != f'XDG_FRAME 250 250 {tick}'.encode('ascii'):
            raise ValueError(f'unexpected Weston frame: {line!r}')
        if offset is None:
            offset = region.find(MARKER)
            if (offset < 0 or offset % 4096 or offset + len(MARKER) + size > len(region)
                    or region.find(MARKER, offset + 1) >= 0):
                raise ValueError('expected one aligned Weston frame region')
        if region[offset:offset + len(MARKER)] != MARKER:
            raise ValueError('Weston frame marker changed')
        base = offset + len(MARKER)
        frame = region[base:base + size]
        alpha = frame[slice(3, None, 4)]
        if alpha != b'\xff' * (size // 4) or not any(any(frame[slice(channel, None, 4)]) for channel in range(3)):
            raise ValueError('expected opaque nonblank Weston pixels')
        frames.add(hashlib.sha256(frame).digest())
        remaining = memoryview(frame)
        while remaining:
            written = window.stdin.write(remaining)
            if not written:
                raise OSError('window pipe made no progress')
            remaining = remaining[written:]
        if not report.until(b'\n', 15).startswith(b'FRAME_OK '):
            raise ValueError('Weston frame was not submitted to AppKit')
        if tick == 11:
            port.sendall(b'XDG_CLOSE\n')
        port.sendall(f'XDG_ACK {tick}\n'.encode('ascii'))
    if len(frames) < 2 or stream.until(b'\n', 15) != b'DONE':
        raise ValueError('expected changing Weston frames and clean XDG close')
    print(f'WESTON_OK: 12 frames, {len(frames)} distinct, xdg_toplevel.close completed', flush=True)


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


def run(work, iso, animate, slots, seconds, weston):
    cmd = vm_command(work, iso)
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
                port.connect(str(work / 'frames'))
                vm.stdin.write(
                    b'modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && '
                    b'modprobe virtio_console && modprobe qemu_fw_cfg && mdev -s && '
                    b'apk add --no-network e2fsprogs && mkfs.ext4 -F -b 4096 /dev/pmem0 && '
                    b'mount -t ext4 -o dax=always /dev/pmem0 /mnt && '
                    b'mkdir -m 700 /tmp/bridge /tmp/m2 && '
                    b'tar -xf /sys/firmware/qemu_fw_cfg/by_name/opt/sclereid/m2/raw -C /tmp/bridge && '
                    b'echo GUEST_READY\n')
                console.until(b'GUEST_READY\r\n', 60)

                client = b'/tmp/bridge/weston-simple-shm' if weston else b'/tmp/bridge/bridge client'
                vm.stdin.write(
                    b'(export XDG_RUNTIME_DIR=/tmp/m2 WAYLAND_DISPLAY=m2 LD_LIBRARY_PATH=/tmp/bridge; '
                    + (f'export M2_ANIMATE=1 M2_SLOTS={slots} M2_SECONDS={seconds}; '.encode('ascii')
                       if animate else b'export M2_XDG=1; ' if weston else b'') +
                    b'set -- /dev/vport*p1; test -c "$1" || exit 1; exec 3<>"$1"; '
                    b'/tmp/bridge/bridge server <&3 >&3 & server=$!; '
                    b'for i in 1 2 3 4 5; do test -S /tmp/m2/m2 && break; sleep 1; done; '
                    + client + b' && wait "$server" && test ! -e /tmp/m2/m2 && '
                    b'echo GUEST_CLEANUP_OK)\n')
                frame_port = Reader(port.fileno())
                window_args = ['--animate'] if animate else ['--weston'] if weston else []
                with child([work / 'window', *window_args], work) as window:
                    report = Reader(window.stdout.fileno())
                    if weston:
                        play_weston(port, frame_port, region, window, report)
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
                        if frame_port.until(b'\n', 20) != b'FRAME 64 48':
                            raise ValueError('invalid frame notification')
                        frame = extract(region)
                        print('DAX_FRAME_OK: 12288 bytes verified', flush=True)
                        window.stdin.write(frame)
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
    modes.add_argument('--weston', action='store_true', help='run the stock weston-simple-shm XDG client')
    modes.add_argument('--animate', action='store_true', help='benchmark 640x360 window updates at 60 Hz')
    parser.add_argument('--slots', type=int, choices=range(1, 5), default=1, help='animation pipeline depth (default: 1)')
    parser.add_argument('--seconds', type=int, default=3, help='animation duration, 1–30 seconds (default: 3)')
    args = parser.parse_args()
    if not 1 <= args.seconds <= 30 or (not args.animate and (args.slots != 1 or args.seconds != 3)):
        parser.error('--slots and --seconds are animation options; require 1–30 seconds')
    iso = args.iso.resolve(strict=True)
    verify(iso, ISO_SHA)
    # Short directory keeps the virtio-serial Unix socket under macOS sun_path limits.
    with tempfile.TemporaryDirectory(prefix='scl-m2-', dir='/tmp') as directory:
        work = Path(directory)
        build(work, args.apks, args.weston)
        run(work, iso, args.animate, args.slots, args.seconds, args.weston)
    print('SCLEREID_M2_OK', flush=True)


if __name__ == '__main__':
    main()
