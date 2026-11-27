#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import socket
import subprocess
import tempfile
import time


IMAGE = 'alpine-virt-3.22.2-x86_64.iso'
URL = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/' + IMAGE
SHA256 = 'b6c45d69829b1b0416ada798353805099d57b8bef9093b85a8319fe5373595d5'


def run(work):
    image = work / IMAGE
    subprocess.run(['curl', '-fLsS', '--max-time', '180', URL, '-o', image], check=True)
    with image.open('rb') as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != SHA256:
        raise RuntimeError('Alpine ISO checksum mismatch')
    for name in ('vmlinuz-virt', 'initramfs-virt'):
        with (work / name).open('wb') as out:
            subprocess.run(['bsdtar', '-xOf', image, 'boot/' + name], stdout=out, check=True)

    version = subprocess.check_output(['qemu-system-x86_64', '--version'], text=True)
    print(version.splitlines()[0], flush=True)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind('serial.sock')
        listener.listen(1)
        listener.settimeout(10)
        with subprocess.Popen([
            'qemu-system-x86_64', '-machine', 'q35,accel=hvf', '-cpu', 'host',
            '-m', '512', '-nic', 'none', '-display', 'none', '-monitor', 'none',
            '-qmp', 'stdio', '-serial', 'unix:serial.sock', '-no-reboot',
            '-kernel', 'vmlinuz-virt', '-initrd', 'initramfs-virt',
            '-append', 'console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod',
            '-cdrom', IMAGE,
        ], cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as vm:
            try:
                console, _ = listener.accept()
                with console, selectors.DefaultSelector() as ready:
                    probe(vm, console, ready)
            finally:
                if vm.poll() is None:
                    vm.terminate()
                    try:
                        vm.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        vm.kill()
                        vm.wait()


def probe(vm, console, ready):
    ready.register(vm.stdout, selectors.EVENT_READ, 'qmp')
    ready.register(console, selectors.EVENT_READ, 'serial')
    token = secrets.token_hex(16)
    marker = re.compile(rb'(?m)^SCLEREID_GUEST_READY ' + token.encode() + rb' (Linux \S+ x86_64)\r?$')
    serial = b''
    pending = b''
    state = 'greeting'
    guest = 'login'

    def qmp(command):
        vm.stdin.write(json.dumps({'execute': command}).encode() + b'\n')
        vm.stdin.flush()

    deadline = time.monotonic() + 90
    try:
        while time.monotonic() < deadline:
            for key, _ in ready.select(0.25):
                if key.data == 'serial':
                    block = console.recv(65536)
                    if not block:
                        ready.unregister(console)
                        if state != 'quit':
                            raise RuntimeError('Guest serial disconnected')
                        continue
                    serial = (serial + block)[-65536:]
                    if guest == 'login' and b'localhost login:' in serial:
                        console.sendall(b'root\n')
                        guest = 'shell'
                    if guest == 'shell' and b'localhost:~# ' in serial:
                        command = f"printf 'SCLEREID_GUEST_READY %s %s\\n' '{token}' \"$(uname -srm)\"\n"
                        console.sendall(command.encode())
                        guest = 'marker'
                    continue
                block = os.read(vm.stdout.fileno(), 65536)
                if not block:
                    raise RuntimeError('QMP disconnected before quit acknowledgement')
                pending += block
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    message = json.loads(line)
                    if 'error' in message:
                        raise RuntimeError(message)
                    if state == 'greeting' and 'QMP' in message:
                        qmp('qmp_capabilities')
                        state = 'capabilities'
                    elif state == 'capabilities' and 'return' in message:
                        qmp('query-status')
                        state = 'status'
                    elif state == 'status' and 'return' in message:
                        if message['return']['status'] != 'running':
                            raise RuntimeError(message)
                        state = 'running'
                    elif state == 'quit' and 'return' in message:
                        if vm.wait(timeout=5) != 0:
                            raise RuntimeError('QEMU failed to exit cleanly')
                        print('SCLEREID_M0_OK: HVF, guest reply verified, QMP quit, exit=0')
                        return
            if state == 'running' and guest == 'marker' and (match := marker.search(serial)):
                print(f'Verified guest: {match[1].decode()}')
                qmp('quit')
                state = 'quit'
        raise RuntimeError(f'Guest probe timed out: QMP={state}, guest={guest}')
    except Exception:
        print(serial[-3000:].decode(errors='replace'), flush=True)
        raise


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='sclereid-m0-', dir=os.getenv('COMMANDCODE_SCRATCHPAD')) as directory:
        previous = Path.cwd()
        work = Path(directory).resolve()
        os.chdir(work)
        try:
            run(work)
        finally:
            os.chdir(previous)
