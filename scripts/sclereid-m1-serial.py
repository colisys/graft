#!/usr/bin/env python3
"""M0 Alpine/HVF boot recipe plus two isolated virtio serial streams."""
import argparse
from contextlib import ExitStack
import hashlib
import math
import os
from pathlib import Path
import runpy
import secrets
import socket
import subprocess as sp
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

M0 = runpy.run_path(str(Path(__file__).with_name('sclereid-m0.py')))
clock = time.perf_counter


def exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        b = s.recv(min(n-len(buf), 262144))
        if not b:
            raise EOFError('port closed')
        buf.extend(b)
    return buf


def until(s, marker):
    buf = b''
    end = clock()+90
    while marker not in buf and clock()<end:
        b = s.recv(8192)
        if not b:
            break
        buf = (buf+b)[-32768:]
    if marker not in buf:
        raise RuntimeError(buf[-2000:])


def dist(xs):
    a = sorted(xs)
    return '/'.join('%.3f'%a[math.ceil(p*len(a))-1] for p in (.50,.95,.99))


def test(console, ping, data, only):
    def cmd(line):
        console.sendall(line.encode()+b'\n')
    until(console,b'localhost login:'); cmd('root'); until(console,b'localhost:~# ')
    token = secrets.token_hex(12)
    cmd('modprobe virtio_console; P=/dev/vport0p1; D=/dev/vport0p2; printf %s '+token+' >$P')
    if exact(ping,len(token)) != token.encode():
        raise ValueError('probe mismatch')
    print('PASS guest->host nonce',flush=True)
    if only:
        return
    cmd('exec 3<>$P 4>$D; (while read -r x <&3; do echo "$x" >&3; done) &')
    # Alternating deterministic BGRA pixel buffers; prepare outside timing.
    cmd("for n in 8294400 262144; do for c in A B; do head -c $n /dev/zero | tr '\\000' $c >/tmp/$n$c; done; done; printf R >&4")
    if exact(data,1)!=b'R': raise ValueError('setup')
    def rtt(i):
        msg=('%08d\n'%i).encode(); t=clock(); ping.sendall(msg)
        if exact(ping,len(msg))!=msg: raise ValueError('echo')
        return (clock()-t)*1000
    def frames(n,count):
        expected=[bytes([c])*n for c in (65,66)]
        cmd(f'i=0; while [ $i -lt {count} ]; do c=A; [ $((i%2)) = 1 ] && c=B; printf "%08d" $i >&4; cat /tmp/{n}$c >&4; i=$((i+1)); done')
        start=prev=clock(); dt=[]
        for i in range(count):
            if int(exact(data,8))!=i or exact(data,n)!=expected[i%2]: raise ValueError(f'frame {i}')
            now=clock(); dt.append((now-prev)*1000); prev=now
        return n*count/(2**20*(prev-start)),dist(dt)
    with ThreadPoolExecutor(1) as pool:
        for mode in ('idle','loaded','full','damage'):
            for roundno in range(4):
                cpu=time.process_time()
                if mode=='idle': result=dist([rtt(i) for i in range(200)])
                elif mode=='loaded':
                    job=pool.submit(frames,8294400,16); samples=[]
                    while not job.done(): samples.append(rtt(len(samples)))
                    rate,_=job.result(); result=f'{dist(samples)} n={len(samples)} bulk={rate:.2f}'
                else:
                    rate,interval=frames(8294400 if mode=='full' else 262144,32 if mode=='full' else 128)
                    result=f'{rate:.2f} {interval}'
                print(mode,roundno,result,'hostCPU_s=%.3f'%(time.process_time()-cpu),flush=True)


def run(work,args):
    image=args.iso or work/M0['IMAGE']
    if not args.iso: sp.run(['curl','-fLsS','--max-time','180',M0['URL'],'-o',image],check=True)
    if hashlib.sha256(image.read_bytes()).hexdigest()!=M0['SHA256']: raise ValueError('ISO hash')
    for name in ('vmlinuz-virt','initramfs-virt'):
        with (work/name).open('wb') as f: sp.run(['bsdtar','-xOf',image,'boot/'+name],stdout=f,check=True)
    opts=['qemu-system-x86_64','-machine','q35,accel=hvf','-cpu','host','-m','512','-nic','none','-display','none','-monitor','none','-serial','unix:c','-no-reboot','-kernel','vmlinuz-virt','-initrd','initramfs-virt','-append','console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod','-cdrom',str(image),'-device','virtio-serial-pci,id=v']
    with ExitStack() as stack:
        listeners=[]
        for i,name in enumerate('cpd'):
            s=stack.enter_context(socket.socket(socket.AF_UNIX)); os.chdir(work); s.bind(name); s.listen(); s.settimeout(12); listeners.append(s)
            if i: opts+=['-chardev',f'socket,id={name},path={name}','-device',f'virtserialport,bus=v.0,nr={i},chardev={name},name={name}']
        vm=sp.Popen(opts,cwd=work)
        try:
            peers=[stack.enter_context(s.accept()[0]) for s in listeners]
            for s in peers: s.settimeout(90)
            test(*peers,args.probe_only)
        finally:
            vm.terminate()
            try: vm.wait(5)
            except sp.TimeoutExpired: vm.kill(); vm.wait(5)


if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--iso',type=lambda x:Path(x).resolve()); p.add_argument('--probe-only',action='store_true'); args=p.parse_args()
    with tempfile.TemporaryDirectory(dir=os.getenv('COMMANDCODE_SCRATCHPAD')) as d: run(Path(d).resolve(),args)
