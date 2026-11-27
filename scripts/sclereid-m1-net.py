#!/usr/bin/env python3
"""Intel macOS / Alpine virtio-net TCP control. Optional argument: cached ISO."""

import hashlib
import os
import re
import select
import socket
import statistics
import subprocess as sp
import sys
import tempfile
import time
from pathlib import Path

IMAGE = "alpine-virt-3.22.2-x86_64.iso"
SHA = "b6c45d69829b1b0416ada798353805099d57b8bef9093b85a8319fe5373595d5"


def bench(vm, port):
    def until(marker):
        data = b""
        end = time.monotonic() + 120
        while marker not in data:
            if not select.select([vm.stdout], [], [], max(0, end - time.monotonic()))[
                0
            ]:
                raise RuntimeError(data[-2000:])
            block = os.read(vm.stdout.fileno(), 8192)
            if not block:
                raise RuntimeError(data[-2000:])
            data = (data + block)[-65536:]
        return data

    def cmd(line):
        vm.stdin.write((line + "\n").encode())
        vm.stdin.flush()

    def connect():
        for _ in range(200):
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=10)
                # Hostfwd may accept before the guest listener exists.
                if s.recv(1) == b"!":
                    return s
                s.close()
            except OSError:
                pass
            time.sleep(0.05)
        raise RuntimeError("guest listener unavailable")

    until(b"localhost login:")
    cmd("root")
    until(b"localhost:~# ")
    cmd(
        "modprobe virtio_net; ip link set eth0 up; ip addr add 10.0.2.15/24 dev eth0; cd /tmp; head -c 8294400 /dev/urandom >full; head -c 262144 full >damage; sha256sum full damage"
    )
    output = until(b"localhost:/tmp# ")
    hashes = {
        name.decode(): digest.decode()
        for digest, name in re.findall(rb"([0-9a-f]{64})  (full|damage)", output)
    }
    for r in range(4):
        for name, size, count in [("full", 8294400, 8), ("damage", 262144, 64)]:
            n = count if r else 1
            cmd(
                f'(printf "!"; for i in $(seq {n}); do cat {name}; done) | nc -l -p 9000 >/dev/null'
            )
            with connect() as s:
                frames = []
                start = time.perf_counter()
                f = s.makefile("rb")
                for _ in range(n):
                    frame = f.read(size)
                    if len(frame) != size:
                        raise RuntimeError("short frame")
                    frames.append(frame)
                elapsed = time.perf_counter() - start
                f.close()
            until(b"localhost:/tmp# ")
            if any(hashlib.sha256(x).hexdigest() != hashes[name] for x in frames):
                raise RuntimeError("payload mismatch")
            print(
                r,
                name,
                round(n * size / 2**20 / elapsed, 2),
                "MiB/s verified",
                flush=True,
            )
        if r:
            cmd(
                "printf '#!/bin/sh\\nprintf !\\nexec cat\\n' >/tmp/echoer; chmod +x /tmp/echoer; nc -l -p 9000 -e /tmp/echoer"
            )
            with connect() as s:
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                times = []
                for i in range(101):
                    b = bytes([i])
                    start = time.perf_counter_ns()
                    s.sendall(b)
                    if s.recv(1) != b:
                        raise RuntimeError("bad echo")
                    if i:
                        times.append((time.perf_counter_ns() - start) / 1e6)
                print(
                    r,
                    "RTT ms p50/p95/p99",
                    statistics.median(times),
                    sorted(times)[94],
                    sorted(times)[98],
                    flush=True,
                )
            until(b"localhost:/tmp# ")


def main(work):
    image = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else work / IMAGE
    if len(sys.argv) == 1:
        sp.run(
            [
                "curl",
                "-fLsS",
                "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/" + IMAGE,
                "-o",
                image,
            ],
            check=True,
        )
    if hashlib.sha256(image.read_bytes()).hexdigest() != SHA:
        raise ValueError("wrong ISO")
    for name in ("vmlinuz-virt", "initramfs-virt"):
        with (work / name).open("wb") as f:
            sp.run(["bsdtar", "-xOf", image, "boot/" + name], stdout=f, check=True)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with sp.Popen(
        [
            "qemu-system-x86_64",
            "-machine",
            "q35,accel=hvf",
            "-cpu",
            "host",
            "-m",
            "512",
            "-display",
            "none",
            "-monitor",
            "none",
            "-serial",
            "stdio",
            "-no-reboot",
            "-netdev",
            f"user,id=n,restrict=on,ipv6=off,hostfwd=tcp:127.0.0.1:{port}-10.0.2.15:9000",
            "-device",
            "virtio-net-pci,netdev=n",
            "-kernel",
            "vmlinuz-virt",
            "-initrd",
            "initramfs-virt",
            "-append",
            "console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod",
            "-cdrom",
            image,
        ],
        cwd=work,
        stdin=sp.PIPE,
        stdout=sp.PIPE,
    ) as vm:
        try:
            bench(vm, port)
        finally:
            vm.kill()
            vm.wait()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(dir=os.getenv("COMMANDCODE_SCRATCHPAD")) as d:
        main(Path(d))
