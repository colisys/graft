#!/usr/bin/env python3
"""Intel macOS/HVF, pinned M0 ISO. Map ONLY the dedicated pmem file."""
import argparse
import ctypes
import math
import re
import queue
import socket
from concurrent.futures import ThreadPoolExecutor
import resource
import secrets
import hashlib
import mmap
import os
from pathlib import Path
import selectors
import statistics
import subprocess as sp
import tempfile
import time

SIZE = 1920 * 1080 * 4
ISO_HASH = 'b6c45d69829b1b0416ada798353805099d57b8bef9093b85a8319fe5373595d5'


def run(work, iso, args):
    digest = hashlib.sha256(iso.read_bytes()).hexdigest()
    flavor = {ISO_HASH:'virt', 'f6a265f0696d328c8f87814a0d6bfa362d1434e500cb80a48796b1c9d204cee0':'lts'}[digest]
    if args.ring:
        args.paced = True
    fs = args.fs or args.paced
    if args.paced and flavor != 'lts':
        raise ValueError('--paced requires the pinned standard ISO')
    for name in ('vmlinuz', 'initramfs'):
        with (work / name).open('wb') as out:
            sp.run(['bsdtar', '-xOf', iso, 'boot/' + name + '-' + flavor], stdout=out, check=True)
    if fs:
        src = Path(__file__).with_name('sclereid-m1-map.c').resolve()
        sp.run(['zig','cc','-target','x86_64-linux-musl','-static','-Os','-s',src,'-o','map'],cwd=work,check=True)
    with (work / 'region').open('xb+') as f:
        f.truncate(32 << 20)
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as region:
            cmd = ['qemu-system-x86_64', '-machine', 'q35,accel=hvf', '-cpu', 'host',
                   '-m', '512M,slots=1,maxmem=1G', '-nic', 'none', '-display', 'none',
                   '-monitor', 'none', '-serial', 'stdio', '-no-reboot', '-kernel', 'vmlinuz',
                   '-initrd', 'initramfs', '-cdrom', str(iso), '-append',
                   'console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod', '-object',
                   'memory-backend-file,id=r,size=32M,mem-path=region,share=on',
                   '-device', 'virtio-pmem-pci,memdev=r']
            if args.trace_vcpus == 2:
                cmd += ['-smp', '2,sockets=1,cores=2,threads=1']
            if args.ring:
                cmd += ['-device', 'virtio-serial-pci,id=v', '-chardev',
                        'socket,id=c,path=control,server=on,wait=off', '-device',
                        'virtserialport,bus=v.0,nr=1,chardev=c,name=control']
            if args.frame_port:
                cmd += ['-chardev', 'socket,id=f,path=frames,server=on,wait=off', '-device',
                        'virtserialport,bus=v.0,nr=2,chardev=f,name=frames']
            if fs:
                cmd += ['-fw_cfg','name=opt/sclereid/map,file=map']
            with sp.Popen(cmd, cwd=work, stdin=sp.PIPE, stdout=sp.PIPE, bufsize=0) as vm:
                try:
                    measure(vm, region, fs, args, work)
                finally:
                    vm.kill()
                    vm.wait()


def measure(vm, region, fs, args, vm_dir):
    with selectors.DefaultSelector() as sel:
        sel.register(vm.stdout, selectors.EVENT_READ)

        def until(marker, timeout=20):
            buf = b''
            end = time.monotonic() + timeout
            while marker not in buf:
                if not sel.select(max(0, end-time.monotonic())):
                    raise TimeoutError(buf[-1500:])
                chunk = os.read(vm.stdout.fileno(), 65536)
                if not chunk:
                    raise EOFError(buf[-1500:])
                buf = (buf + chunk)[-65536:]

            return buf

        until(b'localhost login:', 90)
        vm.stdin.write(b'root\n'); until(b'localhost:~# ')
        if fs:
            launch = b"modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && apk add --no-network e2fsprogs && mkfs.ext4 -F -b 4096 /dev/pmem0 && (mount -t ext4 -o dax=always /dev/pmem0 /mnt || mount -t ext4 /dev/pmem0 /mnt) && mount | grep /mnt && modprobe qemu_fw_cfg && cp /sys/firmware/qemu_fw_cfg/by_name/opt/sclereid/map/raw /tmp/map && chmod +x /tmp/map && "+ (b"stty -echo && /tmp/map paced\n" if args.paced else b"/tmp/map\n")
            if args.ring:
                launch = launch.replace(b"/tmp/map paced", b"(modprobe virtio_console && { mdev -s; ls /sys/class/virtio-ports/; set -- /dev/vport*p1; test -c $1 || exit 1; exec 3<>$1; (while read -r x <&3; do echo $x >&3; done) & /tmp/map ring; })")
            if args.ring:
                control = socket.socket(socket.AF_UNIX)
                control.settimeout(5)
                cwd = os.getcwd()
                try:
                    os.chdir(vm_dir)
                    control.connect("control")
                    if args.frame_port:
                        frames = socket.socket(socket.AF_UNIX)
                        frames.settimeout(10)
                        frames.connect('frames')
                        launch = launch.replace(b'/tmp/map ring;', b'set -- /dev/vport*p2; test -c "$1" || exit 1; exec 4<>"$1"; /tmp/map ring <&4 >&4;')
                finally:
                    os.chdir(cwd)
            if args.trace_ticks:
                launch = launch.replace(b"/tmp/map ring", b"mount -t tracefs tracefs /sys/kernel/tracing && TRACE_TICKS=1 /tmp/map ring")
            vm.stdin.write(launch)
            if args.frame_port:
                with frames, frames.makefile('rb', buffering=0) as stream:
                    ready = stream.readline(256)
                    if not ready.startswith(b'DAX=1 mask=1 ') or stream.readline(32) != b'READY\n':
                        raise ValueError(f'frame port setup failed: {ready!r}')
                    print(ready.decode().strip(), flush=True)
                    with selectors.DefaultSelector() as port_sel:
                        port_sel.register(frames, selectors.EVENT_READ)
                        paced(vm, region, port_sel, args, control, frames)
                return
            ready = until(b'\nREADY\r\n',60)
            print(ready.decode(errors='replace'),flush=True)
            if args.paced:
                if b'\nDAX=1 mask=1 ' not in ready:
                    raise ValueError('paced mode requires statx-confirmed inode DAX')
                paced(vm, region, sel, args, control if args.ring else None)
                return
            offset = None
            for flush in (1,0):
                durations = []
                for j in range(11):
                    i = j + (0 if flush else 11)
                    tag = secrets.token_bytes(8)
                    expected = tag + bytes([1+i])*(SIZE-8)
                    start = time.monotonic()
                    vm.stdin.write(f'{i} {flush} {int.from_bytes(tag,"little")}\n'.encode())
                    until(f'\nFRAME:{i}\r'.encode())
                    if offset is None:
                        offset = region.find(expected)
                        if offset < 0 or region.find(expected,offset+1)>=0:
                            raise ValueError('no unique contiguous frame extent')
                    if region[offset:offset+SIZE] != expected:
                        if flush: raise ValueError('flushed frame mismatch')
                        print(f'no-flush seq={i}: not visible at reply'); return
                    elapsed=time.monotonic()-start
                    if j: durations.append(elapsed)
                print(f'msync={flush} offset={offset} verified=11 timed=10 median_ms={statistics.median(durations)*1000:.2f} max_ms={max(durations)*1000:.2f} MiB/s={10*SIZE/(1<<20)/sum(durations):.2f}',flush=True)
            return
        # Two different whole-frame patterns in tmpfs; no disk/network payload channel.
        vm.stdin.write(b"modprobe virtio_pmem; modprobe nd_pmem; test -b /dev/pmem0 && "
                       b"dd if=/dev/zero of=/tmp/a bs=8294400 count=1 2>/dev/null && "
                       b"tr '\\000' '\\377' </tmp/a >/tmp/b && echo SET:OK\n")
        until(b'\nSET:OK')
        for i in range(31):
            val, src = (255, 'b') if i % 2 == 0 else (0, 'a')
            # Sequence command doubles as ACK of previous frame. No slot reuse before verify.
            command = f'dd if=/tmp/{src} of=/dev/pmem0 bs=8294400 count=1 conv=fsync 2>/dev/null && echo FRAME:{i}\n'
            if i % 10 == 1:
                durations = []
            start = time.monotonic()
            vm.stdin.write(command.encode()); until(f'\nFRAME:{i}\r'.encode())
            if region[:SIZE].count(val) != SIZE:
                raise ValueError(f'frame {i} corrupted')
            elapsed = time.monotonic()-start
            if i:
                durations.append(elapsed)
                if i % 10 == 0:
                    print(f'round={i//10} verified=10 MiB/s={10*SIZE/(1<<20)/sum(durations):.2f} median_ms={1000*statistics.median(durations):.2f} max_ms={1000*max(durations):.2f}', flush=True)


def paced(vm, region, sel, args, control, frames=None):
    pending = bytearray()

    def send(command):
        data = command.encode()
        if frames is not None:
            frames.sendall(data)
        elif vm.stdin.write(data) != len(data):
            raise OSError('short control write')

    def reply(prefix):
        deadline = time.monotonic() + 10
        while b'\n' not in pending:
            left = deadline - time.monotonic()
            if left <= 0 or not sel.select(left):
                raise TimeoutError(bytes(pending))
            data = frames.recv(4096) if frames is not None else os.read(vm.stdout.fileno(), 4096)
            if not data:
                raise EOFError(bytes(pending))
            pending.extend(data)
        line, _, tail = pending.partition(b'\n')
        pending[:] = tail
        line = line.rstrip(b'\r')
        if not line.startswith(prefix):
            raise ValueError(f'expected {prefix!r}, received {line!r}')
        return line[len(prefix):]

    def cpu():
        send('CPU\n')
        guest = int(reply(b'CPU:')) / 1e9
        qemu = sp.check_output(['ps', '-p', str(vm.pid), '-o', 'time='], text=True).strip()
        seconds = 0.0
        for field in qemu.split(':'):
            seconds = seconds * 60 + float(field)
        host = resource.getrusage(resource.RUSAGE_SELF)
        return host.ru_utime + host.ru_stime, seconds, guest

    def stats(samples):
        if not samples:
            return '-'
        ordered = sorted(samples)
        return '/'.join(f'{ordered[math.ceil(len(ordered)*q)-1]*1000:.3f}'
                        for q in (.50, .95, .99))

    if args.ring:
        with control:
            ring(region, args, send, reply, cpu, stats, control)
        return

    seq = 0
    base = None
    shadow = bytearray(SIZE)

    def frame(offset, length, ping):
        nonlocal seq, base
        seq += 1
        tag = secrets.randbits(64)
        expected = tag.to_bytes(8, 'little') + bytes([1 + seq % 255]) * (length - 8)
        command = f'W {seq} {offset} {length} {tag}\n'
        if ping:
            command += f'P {seq}\n'
        start = time.monotonic()
        send(command)
        if int(reply(b'FRAME:')) != seq:
            raise ValueError('out-of-order frame')
        rtt = None
        if ping:
            if int(reply(b'PONG:')) != seq:
                raise ValueError('out-of-order pong')
            rtt = time.monotonic() - start
        if base is None:
            base = region.find(expected)
            if base < 0 or base + SIZE > len(region) or region.find(expected, base + 1) >= 0:
                raise ValueError('no unique bounded contiguous frame extent')
        if region[base + offset:base + offset + length] != expected:
            raise ValueError(f'stale or corrupt mapped bytes at seq={seq}, offset={offset}')
        if length != SIZE:
            shadow[offset:offset + length] = expected
        end = time.monotonic()
        return start, end, rtt, expected

    def idle_ping(i, *_):
        start = time.monotonic()
        send(f'P {i}\n')
        if int(reply(b'PONG:')) != i:
            raise ValueError('out-of-order idle pong')
        return start, time.monotonic(), None, None

    frame(0, SIZE, False)
    print(f'paced: offset={base} rate=60Hz seconds={args.seconds} rounds={args.rounds} '
          'damage=256x256 BGRA packed; ms=p50/p95/p99; cpu=probe/qemu/guest seconds', flush=True)
    period = 1/60
    for name, length in [('idle', 0), ('full', SIZE), ('damage', 256*256*4)]:
        if length and length != SIZE:
            shadow[:] = frame(0, SIZE, False)[3]
        slots = args.seconds * 60
        for round_no in range(1, args.rounds + 1):
            for i in range(60):
                if length:
                    frame(0, length, i % 6 == 0)
                else:
                    idle_ping(i)
                time.sleep(period)
            before = cpu()
            origin = time.monotonic()
            service, from_tick, control, intervals = [], [], [], []
            previous = None
            skipped = late = 0
            for i in range(slots):
                tick = origin + i*period
                remaining = tick - time.monotonic()
                if remaining > 0:
                    time.sleep(remaining)
                if time.monotonic() >= tick + period:
                    skipped += 1
                    continue
                if length:
                    offset = (i % (SIZE // length)) * length
                    start, end, rtt, _ = frame(offset, length, i % 6 == 0)
                else:
                    start, end, rtt, _ = idle_ping(i)
                service.append(end - start)
                from_tick.append(end - tick)
                if rtt is not None:
                    control.append(rtt)
                if previous is not None:
                    intervals.append(end - previous)
                previous = end
                late += end > tick + period
            remaining = origin + slots*period - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
            elapsed = time.monotonic() - origin
            after = cpu()
            if 0 < length < SIZE and region[base:base + SIZE] != shadow:
                raise ValueError('damage modified bytes outside the expected ranges')
            count = len(service)
            cpu_s = '/'.join(f'{b-a:.3f}' for a,b in zip(before,after))
            print(f'{name} round={round_no} wall_s={elapsed:.3f} slots={slots} '
                  f'completed={count} skipped={skipped} late={late} bytes={count*length} '
                  f'MiB/s={count*length/elapsed/(1<<20):.2f} '
                  f'service_ms={stats(service)} tick_to_done_ms={stats(from_tick)} '
                  f'interval_ms={stats(intervals)} control_n={len(control) if length else count} '
                  f'control_ms={stats(control if length else service)} cpu_s={cpu_s}', flush=True)


def classify(rows, misses, size, r):
    retained = re.search(r'entries-in-buffer/entries-written:\s*(\d+)/(\d+)', '\n'.join(rows[:12]))
    complete = retained and retained[1] == retained[2]
    events = []
    for row in rows:
        m = re.search(r'-(\d+)\s+\[\d+\].*? (\d+)\.(\d+): (\w+): (.*)', row)
        if m:
            events.append((int(m[2])*10**9 + int(m[3].ljust(9,'0')), m[4], m[5], int(m[1])))
    for pid, i, tick, arm, observed in misses:
        end = tick + ((i+1)*10**9//60-i*10**9//60)
        if not (pid > 0 and 0 <= i < 600 and observed >= max(end, arm)):
            raise ValueError('inconsistent guest miss timing')
        chain = []
        addr = None
        for t, event, body, emitter in events:
            if not arm-1000 <= t <= observed+1000:
                continue
            timer = re.search(r'hrtimer=([^ ]+)', body)
            if event == 'hrtimer_start' and emitter == pid and timer and 'timerfd_tmrproc' in body and f'expires={tick} ' in body:
                addr = timer[1]; chain = [t]
            elif len(chain) == 1 and event == 'hrtimer_expire_entry' and timer and addr == timer[1] and 'timerfd_tmrproc' in body:
                chain.append(t)
            elif len(chain) == 2 and event == 'sched_wakeup' and re.search(fr' pid={pid} ', body):
                chain.append(t)
            elif len(chain) == 3 and event == 'sched_switch' and re.search(fr' next_pid={pid} ', body):
                chain.append(t)
        label = 'unknown'
        if arm >= end:
            label = 'already-expired-before-arm'
        elif complete and len(chain) >= 2 and chain[0]+1000 < end < chain[1]-1000:
            label = 'expiry-after-deadline'
        elif complete and len(chain) == 4 and chain[2]+1000 < end < chain[3]-1000:
            label = 'runnable-at-deadline'
        print(f'trace size={size} round={r} pid={pid} tick={i} timer={addr} class={label} target={tick} arm={arm} chain={chain} observed={observed}')


def ring(region, args, send, reply, cpu, stats, control):
    bases, shadows = [], []
    seq = 0

    native = not args.copy_verify
    blocks = [bytes([v])*args.verify_block for v in range(256)] if native else []
    if native:
        lib = ctypes.CDLL(None, use_errno=True)
        lib.mmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong)
        lib.mmap.restype = ctypes.c_void_p
        lib.memcmp.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t)
        lib.munmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t)
        with (args.region_path).open('rb') as backing:
            ptr = lib.mmap(None, len(region), mmap.PROT_READ, mmap.MAP_SHARED, backing.fileno(), 0)
        if ptr == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_errno(), 'mmap verifier')

    def materialize(tag, n, length):
        return tag + bytes([1 + n % 255]) * (length - 8)

    stream_fill = False

    def grant(slot, offset, length):
        nonlocal seq
        seq += 1
        tag = secrets.token_bytes(8)
        expected = tag if native else materialize(tag, seq, length)
        sent = time.monotonic()
        op = 'S' if stream_fill else 'W'
        send(f'{op} {seq} {slot*SIZE+offset} {length} {int.from_bytes(tag,"little")}\n')
        return seq, expected, sent

    def ack(n):
        sequence, ns = map(int, reply(b'FRAME:').split())
        if sequence != n or ns < 0:
            raise ValueError('wrong frame sequence')
        return ns / 1e9

    for slot in range(2):
        n, data, _ = grant(slot, 0, SIZE)
        ack(n)
        if native:
            data = materialize(data, n, SIZE)
        base = region.find(data)
        if base < 0 or region.find(data, base+1) >= 0 or any(abs(base-b)<SIZE for b in bases):
            raise ValueError('missing or overlapping contiguous slot')
        bases.append(base)
        shadows.append(bytearray(data))

    if args.mach_wait:
        mach = ctypes.CDLL(None)
        clock = mach.mach_absolute_time
        clock.restype = ctypes.c_uint64
        wait = mach.mach_wait_until
        wait.argtypes = [ctypes.c_uint64]
        scale = (ctypes.c_uint32 * 2)()
        if mach.mach_timebase_info(scale) != 0:
            raise RuntimeError('mach_timebase_info failed')

    def pings(origin, seconds):
        samples = []
        for i in range(seconds*10):
            time.sleep(max(0, origin+(i+0.5)/10-time.monotonic()))
            token = secrets.token_hex(4).encode() + b"\n"
            start = time.monotonic()
            control.sendall(token)
            if control.recv(len(token), socket.MSG_WAITALL) != token:
                raise ValueError('wrong control echo')
            samples.append(time.monotonic()-start)
        return samples

    try:
        with ThreadPoolExecutor(2) as pool:
            for size in (0, SIZE, 256*256*4):
                if native and 0 < size < SIZE:
                    shadows[:] = [bytearray(materialize(*v, SIZE)) if isinstance(v, tuple) else v for v in shadows]
                arms = (False, True) if ((args.compare_producers or args.compare_guest_wait or args.compare_guest_slack) and size) or ((args.compare_stream or args.compare_qos) and size == SIZE) else (False,)
                schedule = [(r, arm) for r in range(args.rounds+1)
                            for arm in (arms if r % 2 else tuple(reversed(arms)))]
                for r, arm in schedule:
                    stream_fill = size == SIZE if args.compare_qos or args.compare_producers else arm
                    if args.compare_qos:
                        qos = ctypes.CDLL(None).pthread_set_qos_class_self_np
                        if qos(0x21 if arm else 0x15, 0):
                            raise RuntimeError('setting issuer QoS failed')
                    seconds = args.seconds if r else 1
                    if size and (args.autonomous or (args.compare_producers and arm)):
                        before = cpu()
                        origin = time.monotonic()
                        echoes = pool.submit(pings, origin, seconds)
                        count = seconds*60
                        lead_us = args.compare_guest_wait if arm and args.compare_guest_wait else 0
                        send(f'G {count} {size} {seq+1} {lead_us} {int(bool(arm and args.compare_guest_slack))}\n')
                        stages_by_seq = {}
                        late_parts = []
                        outstanding = {}
                        ages = []
                        verifies, wakes, writes = [], [], []
                        edges = {}
                        misses = []
                        last_tick = -1
                        while True:
                            kind, fields = reply(b'').split(b':')
                            values = list(map(int, fields.split()))
                            if kind == b'X' and args.trace_ticks:
                                misses.append(values)
                                continue
                            if kind == b'D':
                                sent, expired, blocked, slack_ns = values
                                if min(values) < 0 or outstanding or sent != len(ages) or sent+expired+blocked != count:
                                    raise ValueError('guest tick accounting')
                                break
                            if kind == b'E':
                                n, ns, handled = values
                                if ns < 0 or outstanding.pop(n, None) is None:
                                    raise ValueError('unexpected credit receipt')
                                edges[n].append(handled)
                                parts = stages_by_seq.pop(n)
                                if ns/1e9 > 1/60:
                                    late_parts.append((*parts, ns/1e9-sum(parts)))
                                ages.append(ns/1e9)
                                continue
                            n, tick, slot, wake_ns, write_ns, published = values
                            received = time.monotonic()
                            wakes.append(wake_ns/1e9)
                            writes.append(write_ns/1e9)
                            if kind != b'F' or n != seq+1 or not last_tick < tick < count or slot not in (0,1) or slot in outstanding.values():
                                raise ValueError('invalid guest publication')
                            seq, last_tick = n, tick
                            offset = tick % (SIZE//size)*size
                            base = bases[slot]+offset
                            tag = n.to_bytes(8,'little')
                            block = blocks[1+n%255]
                            if lib.memcmp(ptr+base, tag, 8) or any(lib.memcmp(ptr+base+j, block, min(len(block),size-j)) for j in range(8,size,len(block))):
                                raise ValueError('guest publication mismatch')
                            outstanding[n] = slot
                            if size == SIZE:
                                shadows[slot] = (tag,n)
                            else:
                                shadows[slot][offset:offset+size] = materialize(tag,n,size)
                            verifies.append(time.monotonic()-received)
                            stages_by_seq[n] = (wakes[-1], writes[-1], verifies[-1])
                            edges[n] = [published, received, time.monotonic()]
                            send(f'K {slot} {n}\n')
                        ctrl = echoes.result()
                        time.sleep(max(0, origin+seconds-time.monotonic()))
                        wall = time.monotonic()-origin
                        after = cpu()
                        if any(region[b:b+SIZE] != (materialize(*v,SIZE) if isinstance(v,tuple) else v) for b,v in zip(bases,shadows)):
                            raise ValueError('guest slot shadow mismatch')
                        if args.trace_ticks:
                            if len(misses) != expired or len({x[1] for x in misses}) != expired:
                                raise ValueError('missing expired tick observations')
                            send('TRACE\n')
                            rows = []
                            while (row := reply(b'')) != b'END':
                                rows.append(row.decode())
                            if args.trace_output:
                                dest = args.trace_output / f'{size}-{r}.trace'
                                with dest.open('x') as out:
                                    out.write('\n'.join(rows)+'\n')
                            classify(rows, misses, size, r)
                        if r:
                            notice_lo, notice_hi, credit_lo, credit_hi = [], [], [], []
                            rows = [(p/1e9,h,k,g/1e9) for p,h,k,g in edges.values()]
                            for p,h,k,g in rows:
                                def bounds(t):
                                    return (max(c-d-0.001*abs(t-d) for _,_,c,d in rows),
                                            min(b-a+0.001*abs(t-a) for a,b,_,_ in rows))
                                pl, pu = bounds(p)
                                gl, gu = bounds(g)
                                if pl > pu or gl > gu:
                                    raise ValueError('inconsistent relative clock rate bound')
                                notice_lo.append(max(0,h-p-pu)); notice_hi.append(h-p-pl)
                                credit_lo.append(max(0,g+gl-k)); credit_hi.append(g+gu-k)
                            print(' '.join(f'{key}_ms={stats(v)}' for key,v in zip(
                                ('notice_lo','notice_hi','credit_lo','credit_hi'),
                                (notice_lo,notice_hi,credit_lo,credit_hi))), end=' ')
                            print(f'guest slack_ns={slack_ns} lead_us={lead_us} late_dominant=' + '/'.join(str(sum(v.index(max(v)) == j for v in late_parts)) for j in range(4)) + f' size={size} round={r} verified={sent} expired={expired} no_slot={blocked} late={sum(a>1/60 for a in ages)} wake_ms={stats(wakes)} write_ms={stats(writes)} verify_ms={stats(verifies)} tick_to_credit_ms={stats(ages)} control_n={len(ctrl)} control_ms={stats(ctrl)} MiB/s={size*sent/wall/(1<<20):.2f} cpu_s=' + '/'.join(f'{b-a:.3f}' for a,b in zip(before,after)),flush=True)
                        continue
                    free = queue.Queue()
                    jobs = queue.Queue()
                    for slot in range(2):
                        free.put(slot)

                    keys = ('wake', 'prep', 'write', 'verify', 'remaining')
                    stages = [[] for _ in keys]
                    late_stages = [[] for _ in keys]

                    def consume():
                        times = []
                        while True:
                            job = jobs.get()
                            if job is None:
                                return times
                            slot, offset, tick, wake, n, expected, sent = job
                            write = ack(n)
                            received = time.monotonic()
                            base = bases[slot]+offset
                            if native:
                                block = blocks[1+n%255]
                                wrong = lib.memcmp(ptr+base, expected, 8) or any(
                                    lib.memcmp(ptr+base+i, block, min(len(block), size-i))
                                    for i in range(8, size, len(block)))
                            else:
                                wrong = region[base:base+size] != expected
                            if wrong:
                                raise ValueError(f'wrong bytes in slot {slot} frame {n}')
                            if size == SIZE:
                                shadows[slot] = (expected, n) if native else expected
                            else:
                                if isinstance(shadows[slot], bytes):
                                    shadows[slot] = bytearray(shadows[slot])
                                shadows[slot][offset:offset+size] = materialize(expected, n, size) if native else expected
                            done = time.monotonic()
                            times.append(done-tick)
                            for samples, late_samples, dt in zip(stages, late_stages, (wake-tick, sent-wake, write, done-received, received-sent-write)):
                                samples.append(dt)
                                if times[-1] > 1/60:
                                    late_samples.append(dt)
                            free.put(slot)

                    before = cpu()
                    origin = time.monotonic()
                    if args.mach_wait:
                        mach_origin = clock() - round((time.monotonic()-origin)*1e9*scale[1]/scale[0])
                    echoes = pool.submit(pings, origin, seconds)
                    reader = pool.submit(consume)
                    overlap = expired = no_slot = 0
                    try:
                        for i in range(seconds*60):
                            tick = origin+i/60
                            if args.mach_wait:
                                if wait(mach_origin + round(i*1e9*scale[1]/(60*scale[0]))) != 0:
                                    raise RuntimeError('mach_wait_until failed')
                            else:
                                time.sleep(max(0, tick-time.monotonic()))
                            wake = time.monotonic()
                            if not size:
                                continue
                            if wake >= tick+1/60:
                                expired += 1
                                continue
                            try:
                                slot = free.get_nowait()
                            except queue.Empty:
                                no_slot += 1
                                continue
                            overlap += free.empty()
                            offset = (i % (SIZE//size))*size
                            jobs.put((slot, offset, tick, wake, *grant(slot, offset, size)))
                    finally:
                        jobs.put(None)
                    times = reader.result()
                    if len(times) + expired + no_slot != (seconds*60 if size else 0):
                        raise ValueError('unaccounted tick')
                    control_times = echoes.result()
                    time.sleep(max(0, origin+seconds-time.monotonic()))
                    wall = time.monotonic()-origin
                    after = cpu()
                    if any(region[b:b+SIZE] != (materialize(*shadow, SIZE) if isinstance(shadow, tuple) else shadow) for b,shadow in zip(bases,shadows)):
                        raise ValueError('slot shadow mismatch')
                    if r:
                        print(f'ring size={size} fill={"stream" if stream_fill else "baseline"} round={r} issuer={"interactive" if args.compare_qos and arm else "default"} verified={len(times)} overlap={overlap} '
                              f'skipped={seconds*60-len(times) if size else 0} expired_wake={expired} no_slot={no_slot} late={sum(t>1/60 for t in times)} '
                              f'MiB/s={len(times)*size/wall/(1<<20):.2f} tick_ms={stats(times)} ' +
                              ' '.join(f'{key}_ms={stats(vals)}' for key, vals in zip(keys, stages)) +
                              ''.join(f' late_{key}_ms={stats(vals)}' for key, vals in zip(keys, late_stages)) +
                              f' control_n={len(control_times)} control_ms={stats(control_times)} cpu_s=' +
                              '/'.join(f'{b-a:.3f}' for a,b in zip(before,after)), flush=True)
    finally:
        if native:
            lib.munmap(ptr, len(region))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, epilog='Without a mode or experiment flag, run the autonomous DAX profile.')
    parser.add_argument('iso', type=Path, help='pinned Alpine standard ISO for the default profile')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--raw', action='store_true', help='reproduce the original unpaced raw pmem probe')
    modes.add_argument('--ring', action='store_true')
    modes.add_argument('--fs', action='store_true')
    modes.add_argument('--paced', action='store_true')
    parser.add_argument('--autonomous', action='store_true', help='use absolute guest ticks and two post-verification slot credits')
    parser.add_argument('--frame-port', action='store_true', help='use a dedicated virtio-serial port for ring grants and ACKs')
    parser.add_argument('--compare-stream', action='store_true', help='pair full-frame baseline and SSE2 streaming fills within each ring round')
    parser.add_argument('--compare-qos', action='store_true', help='pair default and interactive producer QoS with streaming full frames')
    parser.add_argument('--mach-wait', action='store_true', help='use absolute Mach deadlines for ring producer wakes')
    parser.add_argument('--copy-verify', action='store_true', help='ring allocation/copy baseline')
    parser.add_argument('--seconds', type=int, default=10)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--compare-producers', action='store_true', help='pair host grants and guest ticks for both payloads')
    parser.add_argument('--verify-block', type=int, choices=(65536, 262144), help='exact verifier block size (default profile: 262144; explicit modes: 65536)')
    parser.add_argument('--compare-guest-wait', type=int, metavar='MICROSECONDS', help='pair guest timer-only and bounded-spin waits')
    parser.add_argument('--compare-guest-slack', action='store_true', help='pair inherited and 1 ns guest publisher timer slack')
    parser.add_argument('--trace-vcpus', type=int, choices=(1,2), default=1)
    parser.add_argument('--trace-output', type=Path, help='existing directory for raw per-interval tracefs snapshots')
    parser.add_argument('--trace-ticks', action='store_true')
    args = parser.parse_args()
    default_profile = not (args.raw or args.ring or args.fs or args.paced or args.autonomous
                           or args.frame_port or args.compare_stream or args.compare_qos
                           or args.mach_wait or args.copy_verify or args.compare_producers
                           or args.compare_guest_wait is not None or args.compare_guest_slack
                           or args.trace_ticks)
    if args.verify_block is None:
        args.verify_block = 262144 if default_profile else 65536
    if default_profile:
        args.autonomous = True
    if (args.trace_output or args.trace_vcpus != 1) and not args.trace_ticks:
        parser.error('trace options require --trace-ticks')
    if args.trace_ticks:
        if args.seconds != 10 or args.compare_guest_slack or args.compare_guest_wait or args.compare_producers:
            parser.error('trace requires 600 timer-only ticks')
        args.autonomous = True
    if args.compare_guest_slack:
        if args.compare_guest_wait or args.compare_producers or args.seconds != 10:
            parser.error('slack comparison requires 600 timer-only guest ticks')
        args.autonomous = True
    if args.compare_guest_wait is not None:
        if not 1 <= args.compare_guest_wait <= 4000 or args.compare_producers:
            parser.error('guest wait comparison requires 1..4000 us and guest-only pacing')
        args.autonomous = True
    if args.compare_producers and (args.autonomous or args.seconds != 10):
        parser.error('--compare-producers requires 600 ticks and selects both producers')
    if args.autonomous or args.compare_producers:
        if args.fs or args.paced:
            parser.error('--autonomous requires the ring transport')
        if args.compare_qos or args.compare_stream or args.copy_verify or args.mach_wait:
            parser.error('autonomous uses fixed guest pacing and native verification')
        args.ring = args.frame_port = True
    if args.compare_qos and (not args.ring or args.compare_stream):
        parser.error('--compare-qos requires --ring without --compare-stream')
    if args.compare_stream and not args.ring:
        parser.error('--compare-stream requires --ring')
    if args.mach_wait and not args.ring:
        parser.error('--mach-wait requires --ring')
    if args.frame_port and not args.ring:
        parser.error('--frame-port requires --ring')
    if args.seconds < 1 or args.rounds < 3:
        parser.error('require positive seconds and at least three rounds')
    with tempfile.TemporaryDirectory(dir=os.getenv('COMMANDCODE_SCRATCHPAD')) as d:
        args.region_path = Path(d) / 'region'
        run(Path(d), args.iso.resolve(), args)
