#!/usr/bin/env python3
"""Intel macOS/HVF, pinned M0 ISO. Map ONLY the dedicated pmem file."""
import secrets
import hashlib
import mmap
import os
from pathlib import Path
import selectors
import statistics
import subprocess as sp
import sys
import tempfile
import time

SIZE = 1920 * 1080 * 4
ISO_HASH = 'b6c45d69829b1b0416ada798353805099d57b8bef9093b85a8319fe5373595d5'


def run(work, iso):
    digest = hashlib.sha256(iso.read_bytes()).hexdigest()
    flavor = {ISO_HASH:'virt', 'f6a265f0696d328c8f87814a0d6bfa362d1434e500cb80a48796b1c9d204cee0':'lts'}[digest]
    fs = sys.argv[2:] == ['--fs']
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
            if fs:
                cmd += ['-fw_cfg','name=opt/sclereid/map,file=map']
            with sp.Popen(cmd, cwd=work, stdin=sp.PIPE, stdout=sp.PIPE, bufsize=0) as vm:
                try:
                    measure(vm, region, fs)
                finally:
                    vm.kill()
                    vm.wait()


def measure(vm, region, fs):
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
            vm.stdin.write(b"modprobe virtio_pmem && modprobe nd_pmem && modprobe ext4 && apk add --no-network e2fsprogs && mkfs.ext4 -F -b 4096 /dev/pmem0 && (mount -t ext4 -o dax=always /dev/pmem0 /mnt || mount -t ext4 /dev/pmem0 /mnt) && mount | grep /mnt && modprobe qemu_fw_cfg && cp /sys/firmware/qemu_fw_cfg/by_name/opt/sclereid/map/raw /tmp/map && chmod +x /tmp/map && /tmp/map\n")
            print(until(b'\nREADY\r',60).decode(errors='replace'),flush=True)
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


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(dir=os.getenv('COMMANDCODE_SCRATCHPAD')) as d:
        run(Path(d), Path(sys.argv[1]).resolve())
