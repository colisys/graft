#!/usr/bin/env python3
"""Run concurrent animation clients in one Alpine VM; reuse the VM across all loads."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import mmap
import os
from pathlib import Path
import runpy
import socket
import statistics
import subprocess as sp
import tempfile
import time

M2 = runpy.run_path(str(Path(__file__).with_name('sclereid-m2.py')))
Reader = M2['Reader']


def snapshot(roles):
    start = time.monotonic()
    text = sp.check_output(['ps', '-p', ','.join(map(str, roles)), '-o', 'pid=,rss=,time='], text=True)
    rows = {}
    for line in text.splitlines():
        pid, rss, cpu = line.split()
        seconds = 0.
        for part in cpu.split(':'):
            seconds = seconds * 60 + float(part)
        rows[int(pid)] = (int(rss) / 1024, seconds)
    if rows.keys() != roles.keys():
        raise RuntimeError('process exited during sampling')
    return (start + time.monotonic()) / 2, rows


def measure(work, stack, vm, console, region, ports, n, seconds, slots):
    def send(command):
        vm.stdin.write(command.encode() + b'\n')

    roles = {os.getpid(): 'Python', vm.pid: 'QEMU'}
    ws = sp.run(['pgrep', '-x', 'WindowServer'], capture_output=True, text=True)
    for pid in ws.stdout.split():
        roles[int(pid)] = 'WindowServer'
    futures = []
    windows = []
    pool = stack.enter_context(ThreadPoolExecutor(max_workers=n))
    for i, port in enumerate(ports[:n]):
        window = stack.enter_context(M2['child']([work / 'window', '--animate'], work))
        roles[window.pid] = 'AppKit'
        report = Reader(window.stdout.fileno())
        windows.append((window, report))
        futures.append(pool.submit(M2['play_animation'], port, Reader(port.fileno()), region,
                                   window, report, slots, seconds, i))
    # Distinct DAX files and port/Wayland sockets; no extra VM or guest RAM per client.
    send(f'export M2_ANIMATE=1 M2_SLOTS={slots} M2_SECONDS={seconds} LD_LIBRARY_PATH=/tmp/bridge XDG_RUNTIME_DIR=/tmp/m2; '
         f'rm -f /tmp/go; for i in $(seq 1 {n}); do '
         'test -e /mnt/frame$((i-1)) || dd if=/dev/zero of=/mnt/frame$((i-1)) bs=1M count=4 2>/dev/null || exit 1; '
         '(export M2_INSTANCE=$i WAYLAND_DISPLAY=w$i; set -- /dev/vport*p$i; test -c "$1" || exit 1; exec 3<>"$1"; '
         '/tmp/bridge/bridge server <&3 >&3 & s=$!; '
         'while ! test -e /tmp/go; do sleep 0.01; done; '
         '/tmp/bridge/bridge client >/tmp/stats$i && wait $s && test ! -e /tmp/m2/w$i && echo OK >>/tmp/stats$i) & done; '
         f'for i in $(seq 1 {n}); do while ! test -S /tmp/m2/w$i; do sleep 0.02; done; done; echo LANES_READY')
    console.until(b'LANES_READY\r\n', 18)
    send('touch /tmp/go')
    start = time.monotonic()
    samples = []
    for tick in range(2, seconds - 1):
        time.sleep(max(0, start + tick - time.monotonic()))
        samples.append(snapshot(roles))
    counts = [f.result(timeout=30) for f in futures]
    send(f'wait; echo STATS_BEGIN; for i in $(seq 1 {n}); do cat /tmp/stats$i; done; echo STATS_END')
    console.until(b'STATS_BEGIN\r\n', 10)
    stats = console.until(b'STATS_END\r\n', 10).decode().splitlines()
    rows = [line.split()[1:] for line in stats if line.startswith('ANIM_STATS ')]
    if len(rows) != n or stats.count('OK') != n:
        raise RuntimeError(stats)
    for count, row in zip(counts, rows):
        sent, expired, no_slot, late, peak = map(int, row)
        if count != sent or sent + expired + no_slot != seconds * 60 or late > sent or not 1 <= peak <= slots:
            raise RuntimeError(row)
    for window, report in windows:
        window.stdin.close()
        if report.until(b'\n', 10) != b'CLEANUP_OK' or window.wait(timeout=10):
            raise RuntimeError('window cleanup failed')
    print(f'RESULT n={n} submitted={counts} fps_avg={sum(counts)/n/seconds:.2f}', flush=True)
    t0, first = samples[0]
    t1, last = samples[-1]
    for role in ['QEMU', 'Python', 'AppKit', 'Total', 'WindowServer']:
        ids = [p for p, r in roles.items() if r == role or (role == 'Total' and r != 'WindowServer')]
        if not ids:
            continue
        cpu = 100 * sum(last[p][1] - first[p][1] for p in ids) / (t1 - t0)
        rss = [sum(sample[p][0] for p in ids) for _, sample in samples]
        print(f'{role}: cpu={cpu:.1f}% rss_median={statistics.median(rss):.1f} rss_peak={max(rss):.1f} MiB', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso', type=Path)
    parser.add_argument('--apks', type=Path)
    parser.add_argument('--instances', type=int, nargs='+', choices=(1, 2, 4, 8), default=[1, 2, 4, 8])
    parser.add_argument('--seconds', type=int, default=12, choices=range(8, 31))
    parser.add_argument('--slots', type=int, default=2, choices=range(1, 5))
    args = parser.parse_args()
    iso = args.iso.resolve(strict=True)
    M2['verify'](iso, M2['ISO_SHA'])
    with tempfile.TemporaryDirectory(prefix='scl-scale-', dir='/tmp') as tmp, ExitStack() as stack:
        work = Path(tmp)
        M2['build'](work, args.apks, False)
        k = max(args.instances)
        cmd = M2['vm_command'](work, iso, k)
        idx = cmd.index('-object') + 1
        cmd[idx] = cmd[idx].replace('size=32M', 'size=64M')
        file = stack.enter_context((work / 'region').open('xb+'))
        file.truncate(64 << 20)
        region = stack.enter_context(mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ))
        vm = stack.enter_context(M2['child'](cmd, work))
        console = Reader(vm.stdout.fileno())
        console.until(b'localhost login:', 90)
        vm.stdin.write(b'root\n')
        console.until(b'localhost:~# ', 10)
        vm.stdin.write(b'stty -echo\n')
        console.until(b'localhost:~# ', 10)
        ports = []
        for i in range(k):
            port = stack.enter_context(socket.socket(socket.AF_UNIX))
            port.settimeout(15)
            port.connect(str(work / ('frames' if not i else f'frames{i}')))
            ports.append(port)
        vm.stdin.write(b'modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && modprobe virtio_console && modprobe qemu_fw_cfg && mdev -s && apk add --no-network e2fsprogs && mkfs.ext4 -F -b 4096 /dev/pmem0 && mount -t ext4 -o dax=always /dev/pmem0 /mnt && mkdir -m 700 /tmp/bridge /tmp/m2 && tar -xf /sys/firmware/qemu_fw_cfg/by_name/opt/sclereid/m2/raw -C /tmp/bridge && echo GUEST_READY\n')
        console.until(b'GUEST_READY\r\n', 60)
        for n in args.instances:
            with ExitStack() as group:
                measure(work, group, vm, console, region, ports, n, args.seconds, args.slots)
        vm.stdin.write(b'poweroff\n')
        if vm.wait(timeout=20) or any(port.recv(1) for port in ports):
            raise RuntimeError('unclean VM or serial shutdown')
        print('MULTI_OK', flush=True)


if __name__ == '__main__':
    main()
