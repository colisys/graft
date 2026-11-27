#!/usr/bin/env python3
"""Software H.264 live and H.264/AV1 batch benchmark with optional Alpine/HVF guest. Requires FFmpeg with libx264."""
import argparse
import base64
from contextlib import ExitStack
import secrets
import hashlib
import mmap
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import socket
import statistics
import subprocess
import tempfile
import threading
import time

WIDTH, HEIGHT, FPS, FRAMES = 1920, 1080, 60, 120
SIZE = f'{WIDTH}x{HEIGHT}'
FRAME_BYTES = WIDTH * HEIGHT * 3 // 2
# Static UI-like test card plus a moving caret; synthetic motion stress case.
CLIPS = {
    'desktop': f'color=c=0x22354a:size={SIZE}:rate={FPS},format=yuv420p,'
               'drawgrid=w=240:h=90:c=0x33485f:t=1,'
               'drawbox=x=100:y=100:w=720:h=500:c=0x17212e:t=fill,'
               'drawbox=x=100:y=100:w=720:h=28:c=0x58738d:t=fill,'
               'drawbox=x=140:y=150:w=500:h=3:c=white:t=fill,'
               'drawbox=x=140:y=170:w=410:h=3:c=white:t=fill,'
               "drawbox=x=140:y=190:w=3:h=18:c=white:t=fill:enable='lt(mod(n,60),30)'",
    'motion': f'testsrc2=size={SIZE}:rate={FPS},format=yuv420p',
}


REGION = 32 << 20
ISO_SHA = 'f6a265f0696d328c8f87814a0d6bfa362d1434e500cb80a48796b1c9d204cee0'


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


class Guest:
    def __init__(self, stack, work, iso, binary, svt=None, live_port=None):
        if sha(iso) != ISO_SHA:
            raise ValueError('expected pinned Alpine standard 3.22.2 x86_64 ISO')
        for name in ('vmlinuz-lts', 'initramfs-lts'):
            with (work / name).open('wb') as out:
                subprocess.run(['bsdtar', '-xOf', iso, 'boot/' + name], stdout=out, check=True)
        shutil.copyfile(binary, work / 'linux-ffmpeg')
        f = stack.enter_context((work / 'region').open('xb+'))
        f.truncate(REGION)
        self.region = stack.enter_context(mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ))
        self.vm = subprocess.Popen([
            'qemu-system-x86_64', '-machine', 'q35,accel=hvf', '-cpu', 'host',
            '-smp', '2', '-m', '3072M,slots=1,maxmem=4G' if svt else '1024M,slots=1,maxmem=2G', *(['-netdev', f'user,id=n,restrict=on,ipv6=off,hostfwd=tcp:127.0.0.1:{live_port}-10.0.2.15:9000',
               '-device', 'virtio-net-pci,netdev=n'] if live_port else ['-nic', 'none']),
            '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-no-reboot',
            '-kernel', 'vmlinuz-lts', '-initrd', 'initramfs-lts', '-cdrom', str(iso),
            '-append', 'console=ttyS0,115200 modules=loop,squashfs,sd-mod,sr-mod',
            '-object', 'memory-backend-file,id=r,size=32M,mem-path=region,share=on',
            '-device', 'virtio-pmem-pci,memdev=r',
            '-drive', 'if=none,id=tool,file=linux-ffmpeg,format=raw,readonly=on',
            '-device', 'virtio-blk-pci,drive=tool',
            *(['-drive', f'if=none,id=svt,file={svt.resolve()},format=raw,readonly=on',
               '-device', 'virtio-blk-pci,drive=svt'] if svt else []),
        ], cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        stack.callback(self.close)
        self.sel = stack.enter_context(selectors.DefaultSelector())
        self.sel.register(self.vm.stdout, selectors.EVENT_READ)
        self.until(b'localhost login:')
        self.vm.stdin.write(b'root\n')
        self.until(b'localhost:~# ')
        print(self.command('stty -echo && uname -r && modprobe virtio_pmem && modprobe nd_pmem '
                           '&& modprobe virtio_blk && test -b /dev/pmem0 && test -b /dev/vda '
                           '&& mkdir /bench && mount -t tmpfs -o size=512m tmpfs /bench '
                           '&& cd /bench && cp /dev/vda ffmpeg && chmod +x ffmpeg '
                           '&& ./ffmpeg -version'), flush=True)

        if live_port:
            self.command('modprobe virtio_net && ip link set eth0 up && ip addr add 10.0.2.15/24 dev eth0')

        if svt:
            self.command('tar xf /dev/vdb && LD_LIBRARY_PATH=./usr/lib ./usr/bin/SvtAv1EncApp --version')

    def close(self):
        self.vm.kill()
        self.vm.wait()
        self.vm.stdin.close()
        self.vm.stdout.close()

    def until(self, marker):
        end, data = time.monotonic() + 120, b''
        while marker not in data:
            if not self.sel.select(max(0, end - time.monotonic())):
                raise TimeoutError(data[-2000:].decode(errors='replace'))
            chunk = os.read(self.vm.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError(data[-2000:].decode(errors='replace'))
            data = (data + chunk)[-65536:]
        return data.decode(errors='replace')

    def command(self, line):
        self.vm.stdin.write(f'{{ {line}; }}; echo BENCH_STATUS:$?\n'.encode())
        out = self.until(b'localhost:/bench# ')
        if not re.search(r'(?:^|\n)BENCH_STATUS:0\r?\n', out):
            raise RuntimeError(out)
        return out

    def run(self, *args):
        return self.command(shlex.join(['./ffmpeg', '-nostdin', '-loglevel', 'error',
                                        '-y', '-xerror', '-filter_threads', '1', *args]))

    def publish(self, work, nonce):
        # Nonce detects a stale publication even when the encode is byte-identical.
        out = self.command(f'(printf %s {nonce}; cat clip.bin) > payload && '
                           f'test $(wc -c < payload) -le {REGION} && '
                           'dd if=payload of=/dev/pmem0 bs=1M conv=fsync && '
                           'wc -c < payload && sha256sum payload')
        size, digest = re.search(r'\n\s*(\d+)\r?\n([a-f0-9]{64})  payload', out).groups()
        payload = self.region[:int(size)]
        if not payload.startswith(nonce.encode()) or hashlib.sha256(payload).hexdigest() != digest:
            raise ValueError('stale or corrupt pmem payload')
        (work / 'clip.bin').write_bytes(payload[len(nonce):])


def live_h264(ffmpeg, repeats, work, guest, port, clips):
    decode = [ffmpeg, '-nostdin', '-loglevel', 'error', '-xerror', '-threads', '1',
              '-nofind_stream_info', '-f', 'nut', '-i', 'pipe:0',
              '-map', '0:v:0', '-fps_mode', 'passthrough', '-enc_time_base', f'1:{FPS}', '-c:v', 'rawvideo', '-threads', '1', '-flush_packets', '1',
              '-f', 'framecrc', 'pipe:1']

    def connect():
        end = time.monotonic() + 10
        while time.monotonic() < end:
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=2) as sock:
                    if sock.recv(1) == b'!':
                        return sock.dup()
            except OSError:
                pass
            time.sleep(0.02)
        raise TimeoutError('guest encoder listener did not send readiness marker')

    def percentiles(values):
        ordered = sorted(values)
        return '/'.join(f'{ordered[(len(ordered) * p + 99) // 100 - 1]:.2f}' for p in (50, 95, 99, 100))

    print(f'LIVE H264 | {"ALPINE HVF / VIRTIO-NET TCP" if guest else "HOST PIPE"} | '
          f'{SIZE} {FPS} fps {FRAMES} frames | gap_ms=p50/p95/p99/max', flush=True)
    for clip in clips:
        encode = ['-nostdin', '-loglevel', 'error', '-xerror', '-filter_threads', '1',
                  '-f', 'lavfi', '-i', CLIPS[clip], '-vf', 'realtime', '-frames:v', str(FRAMES),
                  '-an', '-c:v', 'libx264', '-threads', '2', '-preset', 'ultrafast', '-tune', 'zerolatency',
                  '-sc_threshold', '0', '-g', str(FPS), '-crf', '28', '-f', 'nut', '-flush_packets', '1', 'pipe:1']
        if guest:
            wrapper = '#!/bin/sh\nprintf "!"\nexec ' + shlex.join(['./ffmpeg', *encode]) + ' 2>encode.err\n'
            guest.command(f'echo {base64.b64encode(wrapper.encode()).decode()} | base64 -d > live-encode && chmod +x live-encode')
        for run in range(1, repeats + 1):
            with ExitStack() as stack, (work / 'live.nut').open('wb') as capture:
                def process(args, **kwargs):
                    proc = subprocess.Popen(args, cwd=work, **kwargs)
                    stack.callback(proc.__exit__, None, None, None)
                    stack.callback(proc.kill)
                    return proc

                decoder = process(decode, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                if guest:
                    guest.vm.stdin.write(b'nc -l -p 9000 -e ./live-encode; echo LIVE_STATUS:$?\n')
                    sock = stack.enter_context(connect())
                    receive = sock.recv
                else:
                    encoder = process([ffmpeg, *encode], stdout=subprocess.PIPE, bufsize=0)
                    receive = encoder.stdout.read
                start = time.perf_counter()
                ingress, errors = {}, []

                def relay():
                    try:
                        with decoder.stdin:
                            while data := receive(65536):
                                ingress.setdefault('first', time.perf_counter())
                                decoder.stdin.write(data)
                                decoder.stdin.flush()
                                capture.write(data)
                            ingress['eof'] = time.perf_counter()
                    except OSError as exc:
                        errors.append(exc)

                feeder = threading.Thread(target=relay, daemon=True)
                feeder.start()
                frames, timestamps = [], []
                with selectors.DefaultSelector() as sel:
                    sel.register(decoder.stdout, selectors.EVENT_READ)
                    end = start + 30
                    pending = b''
                    while sel.select(max(0, end - time.perf_counter())):
                        data = os.read(decoder.stdout.fileno(), 65536)
                        now = time.perf_counter()
                        if not data:
                            break
                        *lines, pending = (pending + data).split(b'\n')
                        for line in lines:
                            if line and not line.startswith(b'#'):
                                frames.append(line)
                                timestamps.append(now)
                    else:
                        raise TimeoutError('live decoder did not finish')
                feeder.join(timeout=5)
                if feeder.is_alive() or errors or pending or decoder.wait(timeout=5):
                    raise RuntimeError(f'incomplete live decode: relay={errors}, trailing={pending!r}')
                if guest:
                    status = guest.until(b'localhost:/bench# ')
                    if 'LIVE_STATUS:0' not in status:
                        raise RuntimeError(status)
                    guest.command('test ! -s encode.err || { cat encode.err; false; }')
                elif encoder.wait(timeout=5):
                    raise RuntimeError('host encoder failed')
            offline = subprocess.check_output(decode, input=(work / 'live.nut').read_bytes())
            pts = [int(line.split(b',')[2]) for line in frames]
            if (not pts or pts != list(range(pts[0], pts[0] + FRAMES)) or frames != [line for line in offline.splitlines()
                    if line and not line.startswith(b'#')]):
                raise ValueError(f'live frame order/count/checksum mismatch ({len(frames)} frames, PTS {pts[:8]})')
            gaps = [(b - a) * 1000 for a, b in zip(timestamps, timestamps[1:])]
            before_eof = sum(t < ingress['eof'] for t in timestamps)
            if not before_eof:
                raise ValueError(f'no frames before EOF: first bytes={ingress["first"]-start:.3f}s EOF={ingress["eof"]-start:.3f}s first frame={timestamps[0]-start:.3f}s bytes={(work / "live.nut").stat().st_size}')
            print(f'{clip} run={run} frames={len(frames)} pre_eof={before_eof} '
                  f'bytes={(work / "live.nut").stat().st_size} '
                  f'first_bytes_ms={(ingress["first"] - start) * 1000:.2f} '
                  f'first_frame_ms={(timestamps[0] - start) * 1000:.2f} '
                  f'last_frame_ms={(timestamps[-1] - start) * 1000:.2f} '
                  f'eof_ms={(ingress["eof"] - start) * 1000:.2f} '
                  f'eof_to_last_ms={(timestamps[-1] - ingress["eof"]) * 1000:.2f} '
                  f'gap_ms={percentiles(gaps)} gaps_over_tick={sum(g > 1000 / FPS for g in gaps)}', flush=True)


def benchmark(ffmpeg, repeats, work, guest=None, av1="libsvtav1", decoder="libdav1d", av1_crfs=("28", "38"), clips=CLIPS, av1_only=False):
    def run(*args):
        return subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-nostats',
                               '-y', '-xerror', '-filter_threads', '1', *args],
                              cwd=work, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, text=True, check=True).stderr

    raw = ('-f', 'rawvideo', '-pixel_format', 'yuv420p', '-video_size', SIZE,
           '-framerate', str(FPS))
    mode = 'ALPINE HVF + VIRTIO-PMEM BLOCK/FLUSH' if guest else 'HOST ONLY'
    print(f'{mode} | {SIZE} {FPS} fps {FRAMES} frames | {repeats} timed runs', flush=True)
    subprocess.run([ffmpeg, '-version'], check=True)
    if av1 == 'libsvtav1':
        av1_options = ('-preset', '12', '-svtav1-params', 'lp=2')
    elif av1 == 'libaom-av1':
        av1_options = ('-usage', 'realtime', '-cpu-used', '8', '-lag-in-frames', '0', '-b:v', '0')
    else:
        av1_options = ()
    profiles = [('libx264', 'h264', 'h264', ('-preset', 'ultrafast', '-tune', 'zerolatency', '-sc_threshold', '0'), ('18', '28')),
                (av1, 'ivf', decoder, av1_options, av1_crfs)]
    if av1_only:
        profiles = profiles[1:]
    for name in clips:
        source = CLIPS[name]
        run('-f', 'lavfi', '-i', source, '-frames:v', str(FRAMES), '-f', 'rawvideo', 'ref.yuv')
        if (work / 'ref.yuv').stat().st_size != FRAME_BYTES * FRAMES:
            raise ValueError('wrong reference length')
        digest = sha(work / 'ref.yuv')
        if guest:
            guest.run('-f', 'lavfi', '-i', source, '-frames:v', str(FRAMES), '-f', 'rawvideo', 'ref.yuv')
            if digest not in guest.command('sha256sum ref.yuv'):
                raise ValueError('host and guest references differ')
        print(f'{name} reference_sha256={digest}', flush=True)
        cases = [(codec, fmt, dec, opts, crf) for codec, fmt, dec, opts, crfs in profiles for crf in crfs]
        for codec, fmt, dec_name, options, crf in cases:
            enc, transfer, dec, sizes = [], [], [], []
            for i in range(repeats + 1):
                start = time.perf_counter()
                if codec == 'SvtAv1EncApp':
                    guest.command(shlex.join(['env', 'LD_LIBRARY_PATH=./usr/lib', './usr/bin/SvtAv1EncApp',
                        '-i', 'ref.yuv', '-b', 'clip.bin', '-w', str(WIDTH), '-h', str(HEIGHT), '--fps', str(FPS),
                        '-n', str(FRAMES), '--preset', '12', '--lp', '2', '--keyint', '60', '--crf', crf]))
                else:
                    (guest.run if guest else run)(*raw, '-i', 'ref.yuv', '-an', '-c:v', codec, '-threads', '2',
                        *options, '-g', str(FPS), '-crf', crf, '-f', fmt, 'clip.bin')
                encoded = time.perf_counter()
                if guest:
                    guest.publish(work, secrets.token_hex(8))
                received = time.perf_counter()
                # Decode every frame and emit raw video to the null muxer, not a disk file.
                if dec_name == 'dav1d':
                    decode = ['dav1d', '-q', '--threads', '2', '-i', 'clip.bin']
                    subprocess.run([*decode, '--frametimes', 'times', '--muxer', 'null', '-o', '/dev/null'], cwd=work, check=True)
                    decoded = time.perf_counter()
                    if len((work / 'times').read_text().splitlines()) != FRAMES:
                        raise ValueError('wrong dav1d frame count')
                else:
                    log = run('-threads', '2', '-hwaccel', 'none', '-c:v', dec_name, '-f', fmt, '-i', 'clip.bin',
                              '-an', '-c:v', 'rawvideo', '-threads', '1', '-f', 'null', '-')
                    decoded = time.perf_counter()
                    count = re.findall(r'frame=\s*(\d+)', log)
                    if count != [str(FRAMES)]:
                        raise ValueError(f'expected {FRAMES} decoded frames, got {count}')
                if i:
                    enc.append((encoded - start) * 1000 / FRAMES)
                    transfer.append((received - encoded) * 1000 / FRAMES)
                    dec.append((decoded - received) * 1000 / FRAMES)
                    sizes.append((work / 'clip.bin').stat().st_size)
            if len(set(sizes)) != 1:
                raise ValueError(f'nonrepeatable coded sizes: {sizes}')
            quality_input = ('-c:v', dec_name, '-f', fmt, '-i', 'clip.bin')
            if dec_name == 'dav1d':
                subprocess.run([*decode, '--muxer', 'yuv', '-o', 'decoded.yuv'], cwd=work, check=True)
                if (work / 'decoded.yuv').stat().st_size != FRAMES * FRAME_BYTES:
                    raise ValueError('wrong dav1d output length')
                quality_input = (*raw, '-i', 'decoded.yuv')
            quality = run('-filter_complex_threads', '1', '-threads', '2', '-hwaccel', 'none',
                          *quality_input, *raw, '-i', 'ref.yuv',
                          '-filter_complex', f'[0:v]setpts=N/({FPS}*TB),split[a][b];'
                          f'[1:v]setpts=N/({FPS}*TB),split[c][d];'
                          '[a][c]psnr=shortest=1[p];[b][d]ssim=shortest=1[s]',
                          '-map', '[p]', '-map', '[s]', '-f', 'null', '-')
            psnr = re.search(r'average:([\d.]+|inf)', quality)[1]
            ssim = re.search(r'All:([\d.]+)', quality)[1]
            transport = (f'publish_ms/frame={statistics.median(transfer):.2f} '
                         f'publish_runs={",".join(f"{v:.2f}" for v in transfer)} ') if guest else ''
            print(f'{name} encoder={codec} decoder={dec_name} crf={crf} bytes={sizes[0]} Mbps={sizes[0]*8*FPS/FRAMES/1e6:.3f} '
                  f'encode_ms/frame={statistics.median(enc):.2f} '
                  f'decode_ms/frame={statistics.median(dec):.2f} '
                  f'encode_runs={",".join(f"{v:.2f}" for v in enc)} '
                  f'decode_runs={",".join(f"{v:.2f}" for v in dec)} '
                  f'{transport}'
                  f'PSNR_dB={psnr} SSIM={ssim}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', default='ffmpeg', help='FFmpeg executable with libx264')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--guest', nargs=2, type=Path, metavar=('ALPINE_ISO', 'STATIC_LINUX_FFMPEG'))
    parser.add_argument('--av1', choices=('libsvtav1', 'libaom-av1'), default='libsvtav1')
    parser.add_argument('--av1-decoder', choices=('libdav1d', 'libaom-av1', 'dav1d'), default='libdav1d')
    parser.add_argument('--av1-crfs', nargs='+', default=['28', '38'])
    parser.add_argument('--guest-svt-tar', type=Path, help='trusted tar with Alpine usr/bin/SvtAv1EncApp and usr/lib dependencies; overrides --av1')
    parser.add_argument('--clips', nargs='+', choices=CLIPS, default=CLIPS)
    parser.add_argument('--av1-only', action='store_true')
    parser.add_argument('--live-h264', action='store_true')
    args = parser.parse_args()
    if args.live_h264 and (args.av1_only or args.guest_svt_tar):
        parser.error('--live-h264 cannot be combined with AV1-only or guest SVT')
    if args.guest_svt_tar and not args.guest:
        parser.error('--guest-svt-tar requires --guest')
    if args.repeats < 1:
        parser.error('--repeats must be positive')
    ffmpeg = str(Path(args.ffmpeg).resolve()) if os.sep in args.ffmpeg else args.ffmpeg
    with ExitStack() as stack:
        tmp = Path(stack.enter_context(tempfile.TemporaryDirectory(dir=os.getenv('COMMANDCODE_SCRATCHPAD'))))
        try:
            port = None
            if args.live_h264 and args.guest:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
            guest = Guest(stack, tmp, args.guest[0].resolve(), args.guest[1], args.guest_svt_tar, port) if args.guest else None
            if args.live_h264:
                live_h264(ffmpeg, args.repeats, tmp, guest, port, args.clips)
            else:
                benchmark(ffmpeg, args.repeats, tmp, guest, "SvtAv1EncApp" if args.guest_svt_tar else args.av1, args.av1_decoder, args.av1_crfs, args.clips, args.av1_only)
        except subprocess.CalledProcessError as exc:
            raise SystemExit(exc.stderr or str(exc)) from exc
