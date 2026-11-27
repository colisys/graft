# M1: confined shared-region test on Intel macOS

**Decision:** keep file-backed virtio-pmem as a working transport baseline. The guest can publish a complete frame into a dedicated region visible through a Darwin `mmap`. Reject the measured block-write/flush implementation for 1080p60 full frames. The follow-up below verifies guest userspace DAX mmap on Alpine standard, but not zero-copy presentation or display performance.

## Options and evidence

Tested on macOS 13.7.8 x86_64, MacPorts QEMU 11.1.2, q35/HVF (no TCG fallback), Alpine virt 3.22.2, Linux 6.12.51-0-virt. `qemu-system-x86_64 -device help` lists `virtio-pmem`, `virtio-pmem-pci` and `nvdimm`; neither ivshmem variant nor a vhost-user-fs device appeared.

| Candidate | What upstream requires | Local verdict |
|---|---|---|
| [virtio-pmem](https://www.qemu.org/docs/master/system/devices/virtio-pmem.html) | Separate memory backend, guest physical address space and Linux virtio-pmem/nd drivers. Guest flush requests exist because an ordinary host file is not persistent memory hardware. | `memory-backend-file,share=on` plus `virtio-pmem-pci,memdev=r` worked with ordinary temporary storage; only the 32 MiB payload device is file-backed. Tested below. |
| [NVDIMM](https://www.qemu.org/docs/master/system/devices/nvdimm.html) | ACPI/NFIT machine support (`nvdimm=on`), memory slots/maxmem, backend and guest libnvdimm/pmem stack. Do not claim power-failure persistence for an ordinary file or set `pmem=on` to simulate it. | With `-machine q35,accel=hvf,nvdimm=on -m 512M,slots=2,maxmem=1G`, one nvdimm and one virtio-pmem on **separate** 32 MiB files booted. After `modprobe virtio_pmem; modprobe nd_pmem`, `/dev/pmem0` and `/dev/pmem1`, two nd buses, regions and namespaces appeared. Enumeration alone does not identify their order or validate nvdimm data transfer. |
| [ivshmem](https://www.qemu.org/docs/master/system/devices/ivshmem.html) | Plain PCI shared-memory BAR or server-assisted doorbell/interrupt variant; requires the compiled device and a guest BAR mapping/driver. | Neither `ivshmem-plain` nor `ivshmem-doorbell` available in this binary. A shared file alone cannot add the PCI endpoint. Revisit only with a verified Darwin build. |
| [virtiofs DAX](https://docs.kernel.org/filesystems/virtiofs.html) | A shared directory is not a DAX window: need a frontend with a mapping window, compatible backend servicing mapping requests and guest DAX mount/inode support. Conventional [vhost-user](https://www.qemu.org/docs/master/interop/vhost-user.html) gives the backend mappings of guest memory. | No `vhost-user-fs-pci` here, no `virtiofsd` on PATH. Do not switch main RAM to a shared file to enable a daemon. Ordinary shared-folder I/O or a VZ mount would not validate this QEMU/HVF path. |

## Reproduce and interpret

For the original raw-device control, run `python3 scripts/sclereid-m1-memory.py /path/to/alpine-virt-3.22.2-x86_64.iso --raw` (same ISO URL and SHA-256 as `scripts/sclereid-m0.py`; script checks the digest). Requires Python 3, bsdtar and HVF QEMU. No Colima, guest networking, host folder export, `/dev/mem`, or external daemon. A fresh private temporary directory holds extracted boot files and a disposable region; the host mapping is read-only. One pmem device only; no arbitrary target-device parameter. QEMU is killed and reaped before temporary files are removed.

The guest prepares two 8,294,400-byte frames in tmpfs. For each host serial grant it copies the selected frame to `/dev/pmem0` and completes `dd conv=fsync` **before** sending the sequence number. The host waits for that reply, checks every byte of the mapped prefix against the alternating expected value, then grants the next write. Dirty page cache, a stale previous frame, or an early reply is not accepted as evidence of a new complete frame. Serial conveys control, not pixels. The flush is not a claim about crash durability. Host elapsed time includes serial/shell, guest copy and flush, and host copy/verification.

One warm-up then three rounds of ten, one in flight, all 31 verified:

| Round | Effective MiB/s | Median ms | Maximum ms |
|---|---:|---:|---:|
| 1 | 32.16 | 226.99 | 414.33 |
| 2 | 33.51 | 228.22 | 352.11 |
| 3 | 35.61 | 220.51 | 267.15 |

The target is 474.6 MiB/s (16.7 ms/frame). This measures neither raw HVF memory bandwidth nor a guest DAX mapping. Next test a DAX-capable filesystem on **only** the scratch pmem device, verify `STATX_ATTR_DAX` on the actual file, map it `MAP_SHARED` in the guest, and establish the corresponding bounded host offset rather than assuming filesystem data begins at zero. Validate nonce-tagged patterns and explicit release/acquire ownership across repeated reuse before timing. Separate checksum, flush and control costs; measure idle/loaded RTT, damage-sized writes, CPU and tail percentiles over longer runs before selecting a production channel. No GPU import or presentation was tested.

## Follow-up: ext4 file mmap on the dedicated virtio-pmem device

Run `python3 scripts/sclereid-m1-memory.py /path/to/alpine-standard-3.22.2-x86_64.iso --fs`; substitute the pinned virt ISO for the negative control. Both digests are checked. This mode additionally needs Zig (tested 0.16.0) for a static x86_64 Linux helper, transferred via read-only QEMU fw_cfg, not via the payload file. Both guests loaded `virtio_pmem`, `nd_pmem`, `ext4` and installed e2fsprogs offline from CD. `mkfs.ext4 -F -b 4096 /dev/pmem0` reported 8192 4k blocks and 8192 inodes.

* **virt, 6.12.51-0-virt:** ISO config has `CONFIG_DAX=y` but `# CONFIG_ZONE_DEVICE is not set`, no `CONFIG_FS_DAX=y`. Mount with `dax=always` failed `Invalid argument`; fallback mount reported `rw,relatime`. On the actual frame inode: `DAX=0 mask=1 MAP_SYNC=Not supported`.
* **standard, 6.12.51-0-lts:** ISO config has `CONFIG_ZONE_DEVICE=y`, `CONFIG_FS_DAX=y`. Guest reported `/dev/pmem0 on /mnt type ext4 (rw,relatime,dax=always)` and `DAX=1 mask=1 MAP_SYNC=Not supported`. Thus inode DAX works independently of `MAP_SHARED_VALIDATE|MAP_SYNC` support. Both tests used the ordinary `MAP_SHARED` fallback.

One guest writer waits for each serial grant, fills 8,294,400 bytes with a new sequence-specific value and overwrites the first eight bytes with the grant's random nonce. It fences stores, optionally calls `msync(MS_SYNC)`, and replies with the sequence. Host locates the unique complete warm-up pattern within the read-only scratch region (offset **6,475,776** on both fresh filesystems, not a configured ABI), then checks every byte at that fixed offset before granting reuse. A fragmented or relocated frame would not pass. Timings include grant, guest stores, optional sync, reply and host copy/comparison; expected bytes and nonce prepared before the clock starts.

| Guest / mode | Whole frames verified | Median ms | Max ms | Effective MiB/s |
|---|---:|---:|---:|---:|
| standard DAX / MS_SYNC | 11 | 23.58 | 29.98 | 324.82 |
| standard DAX / no msync | 11 | 11.14 | 14.39 | 679.12 |
| virt buffered / MS_SYNC | 11 | 22.10 | 23.77 | 356.47 |
| virt buffered / no msync | 0 | — | — | — |

Each completed row excludes its first grant from timing. On virt the first unsynced publication (`seq=11`) did not match at reply; no further grant was issued. On standard the ten timed unsynced publications fit the 16.7 ms budget **in this run only**. This is runtime visibility during serialized ownership, not crash persistence, a portable no-flush contract, sustained throughput, or compositor presentation. The synced DAX round missed the full-frame budget. Longer loaded runs and damage-sized updates remain useful before selecting a transport.

## Follow-up: paced DAX ownership and control RTT

```sh
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --paced --seconds 10 --rounds 3
swift test
```

Measured on the Intel i5-3210M/macOS 13.7.8 host with QEMU 11.1.2, q35/HVF, one vCPU (QEMU default), 512 MiB private guest RAM, and a separate 32 MiB file-backed pmem region. Pinned Alpine standard 3.22.2 (`6.12.51-0-lts`), Zig 0.16.0, Python 3.14.7. ext4 mounted `dax=always`; the inode reported `DAX=1 mask=1`, `MAP_SYNC` was unsupported, and the actual path used `MAP_SHARED` without `msync`. The verified offset was 6,475,776. No guest network or Colima.

Each mode ran three 10-second rounds at 60 scheduled ticks/s after 60 warm-up operations per round. Full frames are 8,294,400 bytes; damage is a packed 256×256 BGRA tile (262,144 bytes), cycling through bounded offsets, not a strided compositor surface. Each serial write grant transfers one slot to the guest; the guest fences stores before acknowledging. The host verifies the sequence, fresh 64-bit nonce and every published payload byte before granting reuse. Each damage round also compares the entire extent against an accumulated shadow outside the timed window. No verification or ordering failures occurred. This tests serialized single-slot ownership, not pipelined ring contention or persistence.

`skipped` means the host reached a tick after its deadline and did not issue a grant. `late` counts completed operations that missed their own deadline; it does not include skips. `service` is grant (or idle ping) through completion and byte verification; `tick_to_done` also includes scheduling and expected-byte preparation. `interval` is spacing between completed operations. The loaded ping is sent behind every sixth scheduled write on the same serial connection, so its RTT includes queued guest publication but not host verification; idle pings have no writer. These are host-clock measurements, not one-way latency or presentation. Percentiles below are nearest-rank p50/p95/p99 in ms. CPU seconds are host Python / host QEMU / guest helper across round boundaries; guest CPU is not additive to host QEMU CPU. MiB/s uses verified payload bytes and elapsed wall time.

<details>
<summary>Measured rounds</summary>

```text
idle round=1 wall_s=10.001 slots=600 completed=595 skipped=5 late=3 bytes=0 MiB/s=0.00 service_ms=2.656/4.360/8.728 tick_to_done_ms=4.542/7.410/12.213 interval_ms=16.596/20.197/23.806 control_n=595 control_ms=2.656/4.360/8.728 cpu_s=0.212/1.080/0.007
idle round=2 wall_s=10.000 slots=600 completed=597 skipped=3 late=4 bytes=0 MiB/s=0.00 service_ms=2.667/4.483/8.009 tick_to_done_ms=4.511/7.092/11.872 interval_ms=16.683/19.841/23.960 control_n=597 control_ms=2.667/4.483/8.009 cpu_s=0.210/1.070/0.017
idle round=3 wall_s=10.002 slots=600 completed=600 skipped=0 late=1 bytes=0 MiB/s=0.00 service_ms=2.654/4.216/6.527 tick_to_done_ms=4.765/6.949/8.957 interval_ms=16.711/19.784/21.420 control_n=600 control_ms=2.654/4.216/6.527 cpu_s=0.210/1.320/0.006
full round=1 wall_s=10.001 slots=600 completed=538 skipped=62 late=475 bytes=4462387200 MiB/s=425.51 service_ms=13.295/21.214/28.930 tick_to_done_ms=24.498/36.212/41.512 interval_ms=17.409/26.481/34.266 control_n=90 control_ms=11.093/18.083/20.725 cpu_s=3.631/5.990/0.892
full round=2 wall_s=10.011 slots=600 completed=533 skipped=67 late=506 bytes=4420915200 MiB/s=421.13 service_ms=13.509/21.443/32.424 tick_to_done_ms=25.108/36.973/46.353 interval_ms=17.506/26.248/35.929 control_n=89 control_ms=11.643/19.180/29.361 cpu_s=3.567/6.030/0.857
full round=3 wall_s=10.003 slots=600 completed=539 skipped=61 late=485 bytes=4470681600 MiB/s=426.22 service_ms=13.495/20.758/27.328 tick_to_done_ms=24.267/35.777/43.337 interval_ms=17.426/25.528/33.375 control_n=86 control_ms=11.532/16.311/36.745 cpu_s=3.603/6.180/0.870
damage round=1 wall_s=10.000 slots=600 completed=600 skipped=0 late=11 bytes=157286400 MiB/s=15.00 service_ms=6.165/9.741/17.141 tick_to_done_ms=7.674/12.248/19.232 interval_ms=16.621/21.647/27.194 control_n=100 control_ms=7.055/9.697/13.361 cpu_s=0.414/4.560/0.007
damage round=2 wall_s=10.002 slots=600 completed=591 skipped=9 late=14 bytes=154927104 MiB/s=14.77 service_ms=6.149/10.840/22.487 tick_to_done_ms=7.663/12.959/29.058 interval_ms=16.788/21.971/28.888 control_n=98 control_ms=7.697/11.793/39.227 cpu_s=0.402/4.490/0.007
damage round=3 wall_s=10.003 slots=600 completed=600 skipped=0 late=6 bytes=157286400 MiB/s=15.00 service_ms=6.230/9.841/13.482 tick_to_done_ms=7.642/12.052/16.648 interval_ms=16.629/21.593/25.850 control_n=100 control_ms=7.216/10.814/14.837 cpu_s=0.417/4.520/0.008
```

</details>

Full-frame delivery reached **421.13–426.22 MiB/s** (about 53–54 verified frames/s), below **474.6 MiB/s**. Each round skipped 61–67 ticks and verified another 475–506 frames late. Packed damage reached **14.77–15.00 MiB/s**, but still skipped 0–9 ticks and completed 6–14 updates late per round. Idle control RTT p99 was **6.53–8.73 ms**; full-frame-loaded p99 was **20.73–36.75 ms** and damage-loaded p99 was **13.36–39.23 ms**. Sampling cadence differs between idle and loaded control, and the loaded ping queues behind a write by design. This probe does not isolate raw DAX bandwidth from serial scheduling or host verification. Keep DAX damage as a candidate; neither the sustained full-frame gate nor deadline-clean damage was demonstrated. No compositor, zero-copy presentation, or production transport promotion is supported.

**Streaming codec gap:** no sequential live H.264/AV1 comparison was run. The existing harness waits for a complete clip before publishing and starts decoding afterward; measuring live behavior requires incremental access-unit/IVF framing, bounded publication and acknowledgement, and persistent decoders with per-frame output timestamps. Replaying a completed file would not measure guest encoder buffering or first-frame latency. The batch results below remain throughput evidence only. `swift test`: 89 executed, zero failures.

## Follow-up: Alpine HVF H.264 encode → virtio-pmem → macOS decode

**This is an actual guest encode**, on the same Intel i5-3210M/macOS 13.7.8 host with QEMU 11.1.2 (`q35,accel=hvf`, no fallback), Alpine standard 3.22.2 (`6.12.51-0-lts`, two vCPUs, 1 GiB). It uses the existing confined **block/flush** path, not the ext4 DAX path above. The guest reads and encodes from tmpfs; it copies the resulting elementary stream plus a fresh nonce into the dedicated 32 MiB pmem device and flushes it before replying over serial. For every run, the host checks the nonce and SHA-256 from its read-only mapping before decoding, and checks exactly 120 decoded frames. No guest network, Colima, or system installs.

### Reproduce

Python 3.11+, `bsdtar`, pinned standard ISO (same as DAX follow-up), and two FFmpeg binaries with libx264. Unpack them into scratch space (do not install). The guest binary is supplied as a read-only raw virtio-blk device, copied into guest tmpfs and executed there.

- Host: [imageio-ffmpeg 0.6.0 Intel macOS wheel](https://files.pythonhosted.org/packages/da/58/87ef68ac83f4c7690961bce288fd8e382bc5f1513860fc7f90a9c1c1c6bf/imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl), SHA-256 `9d2baaf867088508d4a3458e61eeb30e945c4ad8016025545f66c4b5aaef0a61`. Extract with `unzip -p host.whl 'imageio_ffmpeg/binaries/ffmpeg-*' > host-ffmpeg` and `chmod +x host-ffmpeg`. This is FFmpeg 7.1.
- Guest: [static Linux amd64 archive](https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz), SHA-256 `abda8d77ce8309141f83ab8edf0596834087c52467f6badf376a6a2a4c87cf67`. Extract with `tar -xOf linux.tar.xz ffmpeg-7.0.2-amd64-static/ffmpeg > linux-ffmpeg`. This is FFmpeg 7.0.2; the extracted SHA-256 is `e7e7fb30477f717e6f55f9180a70386c62677ef8a4d4d1a5d948f4098aa3eb99`. If the rolling URL changes, use a matching cached archive or record the replacement version separately.

```sh
python3 scripts/sclereid-m1-encoder.py --ffmpeg ./host-ffmpeg \
  --guest /path/to/alpine-standard-3.22.2-x86_64.iso ./linux-ffmpeg
# Separate host-only control
python3 scripts/sclereid-m1-encoder.py --ffmpeg ./host-ffmpeg
```

Two deterministic 1920×1080 YUV420p clips, 120 frames each at 60 Hz: synthetic desktop (static UI shapes and blinking caret) and synthetic motion (`testsrc2`). Host and guest raw references matched SHA-256. x264: `ultrafast`, `zerolatency`, two threads, 60-frame GOP, no scene cuts, CRF 18/28. One warm-up plus three timed runs per row. Stage times are medians of elapsed wall time per *clip* divided by 120; the script also prints individual runs. Encode includes process start and input/output; publish includes staging, serial control, `dd`/flush, copying, hashing and staging on macOS; decode is software into a null sink. PSNR and SSIM are from the final run against the source YUV, calculated separately. Bitrate counts H.264 bytes only.

| Mode | Clip | CRF | Encode ms/frame | Publish ms/frame | Decode ms/frame | Total ms/frame | Mbps | PSNR dB | SSIM |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| guest | desktop | 18 | 10.43 | 0.37 | 2.29 | 13.06 | 0.142 | 68.39 | 0.999892 |
| guest | desktop | 28 | 10.75 | 0.38 | 2.27 | 13.40 | 0.094 | 59.28 | 0.999402 |
| guest | motion | 18 | 12.66 | 4.32 | 3.65 | 21.16 | 36.041 | 55.12 | 0.999351 |
| guest | motion | 28 | 12.03 | 2.51 | 3.20 | 18.09 | 19.209 | 45.78 | 0.995912 |
| host | desktop | 18 | 7.58 | — | 2.35 | 9.93 | 0.142 | 68.39 | 0.999892 |
| host | desktop | 28 | 6.67 | — | 2.24 | 9.07 | 0.094 | 59.28 | 0.999402 |
| host | motion | 18 | 9.52 | — | 3.63 | 13.04 | 36.041 | 55.12 | 0.999351 |
| host | motion | 28 | 12.70 | — | 3.92 | 16.59 | 19.209 | 45.78 | 0.995912 |

Total is the median of paired stage sums (reconstructed from rounded run output). The desktop clip fits the 16.67 ms/frame **amortized** budget in this run; neither motion setting does. CRF 28 cuts motion bitrate by about 47%, with lower PSNR/SSIM. Desktop results are unusually favorable because the fixture is mostly static; the metrics also exclude RGB-to-YUV conversion and do not establish text legibility. Host-only uses a different FFmpeg build and scratch filesystem rather than guest tmpfs, so the difference is not an isolated HVF penalty.

The host cannot decode until the whole two-second clip has been published. This is a batch throughput measurement, not individual frame latency, frame pacing, an end-to-end compositor test, or evidence of 60 Hz presentation. Next measure per-access-unit publication, decode and tail latency with live desktop damage and real motion.

<details>
<summary>Run evidence (reference hashes and individual timings)</summary>

```text
guest:
desktop reference_sha256=8ca24af81835371491de39b9a7106717ad48bf6867e4db4915a531be910963c0
desktop crf=18 bytes=35402 Mbps=0.142 encode_ms/frame=10.43 decode_ms/frame=2.29 encode_runs=10.43,9.92,11.69 decode_runs=2.29,2.29,2.16 publish_ms/frame=0.37 publish_runs=0.34,0.37,0.38 PSNR_dB=68.386685 SSIM=0.999892
desktop crf=28 bytes=23446 Mbps=0.094 encode_ms/frame=10.75 decode_ms/frame=2.27 encode_runs=10.08,10.75,10.94 decode_runs=2.14,2.27,2.43 publish_ms/frame=0.38 publish_runs=0.33,0.38,0.38 PSNR_dB=59.276629 SSIM=0.999402
motion reference_sha256=dded51242d208681a44cea34b03a18e516d5d322ff516a766676b3900c41363e
motion crf=18 bytes=9010249 Mbps=36.041 encode_ms/frame=12.66 decode_ms/frame=3.65 encode_runs=12.66,13.40,12.59 decode_runs=3.65,3.67,3.53 publish_ms/frame=4.32 publish_runs=4.85,4.23,4.32 PSNR_dB=55.118609 SSIM=0.999351
motion crf=28 bytes=4802327 Mbps=19.209 encode_ms/frame=12.03 decode_ms/frame=3.20 encode_runs=11.46,14.19,12.03 decode_runs=3.03,3.20,3.22 publish_ms/frame=2.51 publish_runs=2.49,2.51,2.84 PSNR_dB=45.784925 SSIM=0.995912
host:
desktop reference_sha256=8ca24af81835371491de39b9a7106717ad48bf6867e4db4915a531be910963c0
desktop crf=18 bytes=35403 Mbps=0.142 encode_ms/frame=7.58 decode_ms/frame=2.35 encode_runs=7.02,7.58,7.73 decode_runs=2.13,2.35,2.62 PSNR_dB=68.386685 SSIM=0.999892
desktop crf=28 bytes=23447 Mbps=0.094 encode_ms/frame=6.67 decode_ms/frame=2.24 encode_runs=6.83,6.63,6.67 decode_runs=2.24,2.16,2.90 PSNR_dB=59.276629 SSIM=0.999402
motion reference_sha256=dded51242d208681a44cea34b03a18e516d5d322ff516a766676b3900c41363e
motion crf=18 bytes=9010250 Mbps=36.041 encode_ms/frame=9.52 decode_ms/frame=3.63 encode_runs=9.52,9.41,20.13 decode_runs=3.50,3.63,10.90 PSNR_dB=55.118609 SSIM=0.999351
motion crf=28 bytes=4802328 Mbps=19.209 encode_ms/frame=12.70 decode_ms/frame=3.92 encode_runs=12.70,13.03,10.76 decode_runs=3.89,4.26,3.92 PSNR_dB=45.784925 SSIM=0.995912
```

</details>

## AV1 versus H.264: same guest inputs, host software decode

The pinned Linux FFmpeg lacks SVT-AV1 and the pinned macOS FFmpeg lacks dav1d. To test the preferred pair rather than silently substituting libaom, supply Alpine's standalone SVT encoder and shared library on a second read-only disk and use the existing macOS `dav1d` 1.5.4 executable. Nothing is installed into either system. The original FFmpeg builds still generate the references, run x264, and score decoded samples. For the historical H.264 reproduction commands above, append `--av1 libaom-av1 --av1-decoder libaom-av1` when using those FFmpeg builds without the standalone tools.

From the repository root, with the pinned binaries and ISO described above in scratch:

```sh
s=$COMMANDCODE_SCRATCHPAD
(
  set -e
  cd "$s"
  mkdir -p svt
  for pkg in svt-av1 libSvtAv1Enc; do
    curl -fLsS "https://dl-cdn.alpinelinux.org/alpine/v3.22/community/x86_64/$pkg-2.3.0-r0.apk" -o "$pkg.apk"
  done
  printf '%s\n' 'b13a8e1520e563cf88b781eb799b6f0a29bbceb010e7a83ee616171b92c15e4c  svt-av1.apk' '7083d492af650d7c04b8bdd7970b71e649e2d0fe48d4d13c4fd7e1fbc4e71086  libSvtAv1Enc.apk' | shasum -a 256 -c -
  for pkg in svt-av1 libSvtAv1Enc; do bsdtar -xf "$pkg.apk" -C svt; done
  tar -cf svt.tar -C svt usr
)
python3 scripts/sclereid-m1-encoder.py --ffmpeg "$s/encoder-ffmpeg" \
  --guest "$s/std.iso" "$s/encoder-linux" --guest-svt-tar "$s/svt.tar" \
  --av1-decoder dav1d --av1-crfs 20 32 --repeats 2
swift test
```

Both codecs used one warm-up plus two measured whole clips per point. H.264 uses the preceding ultrafast/zerolatency settings; SVT 2.3.0 requests preset 12 (SVT maps it to 11), `--lp 2 --keyint 60`, default prediction structure, not a tuned live profile. The two vCPUs constrain guest execution. Size is the actual published media file (IVF framing included for AV1), excluding the integrity nonce. Decode is into a null sink with two decoder threads; dav1d writes frame times for the 120-frame count check. A separate dav1d raw decode supplies the samples for FFmpeg PSNR and SSIM. Timings include CLI startup and I/O; they are not codec-kernel timings.

The first SVT encode in the original 1 GiB guest was killed (exit 137). The standalone-SVT comparison therefore boots with **3 GiB for both codecs**, still with two vCPUs and a 512 MiB source/output tmpfs. Do not compare its speeds to the earlier 1 GiB table as an isolated codec effect.

On the desktop card, SVT 32 versus x264 18 used 8,104 versus 35,402 bytes (77.1% less) **with higher**, not exactly matched, PSNR and SSIM. Encode took 38.45 versus 15.92 ms/frame. This is a mostly static synthetic fixture, not a representative sample of all desktop workloads.

Motion follow-up: CRF 20 undershot the x264 28 quality target, so measure CRF 15 against the same reference rather than equating CRF numbers:

```sh
python3 scripts/sclereid-m1-encoder.py --ffmpeg "$s/encoder-ffmpeg" \
  --guest "$s/std.iso" "$s/encoder-linux" --guest-svt-tar "$s/svt.tar" \
  --av1-decoder dav1d --av1-crfs 15 --clips motion --av1-only --repeats 2
```

Measured output (stage times in ms/frame):

```text
desktop reference_sha256=8ca24af81835371491de39b9a7106717ad48bf6867e4db4915a531be910963c0
desktop encoder=libx264 decoder=h264 crf=18 bytes=35402 Mbps=0.142 encode_ms/frame=15.92 decode_ms/frame=3.63 encode_runs=18.59,13.26 decode_runs=4.37,2.89 publish_ms/frame=0.45 publish_runs=0.50,0.40 PSNR_dB=68.386685 SSIM=0.999892
desktop encoder=libx264 decoder=h264 crf=28 bytes=23446 Mbps=0.094 encode_ms/frame=14.14 decode_ms/frame=3.24 encode_runs=13.23,15.06 decode_runs=2.98,3.49 publish_ms/frame=0.39 publish_runs=0.45,0.34 PSNR_dB=59.276629 SSIM=0.999402
desktop encoder=SvtAv1EncApp decoder=dav1d crf=20 bytes=8722 Mbps=0.035 encode_ms/frame=38.02 decode_ms/frame=3.40 encode_runs=39.89,36.14 decode_runs=3.38,3.43 publish_ms/frame=0.42 publish_runs=0.48,0.35 PSNR_dB=91.004216 SSIM=0.999999
desktop encoder=SvtAv1EncApp decoder=dav1d crf=32 bytes=8104 Mbps=0.032 encode_ms/frame=38.45 decode_ms/frame=3.45 encode_runs=36.54,40.36 decode_runs=3.11,3.80 publish_ms/frame=0.40 publish_runs=0.41,0.39 PSNR_dB=70.865741 SSIM=0.999954
motion reference_sha256=dded51242d208681a44cea34b03a18e516d5d322ff516a766676b3900c41363e
motion encoder=libx264 decoder=h264 crf=18 bytes=9010249 Mbps=36.041 encode_ms/frame=17.76 decode_ms/frame=4.93 encode_runs=17.03,18.49 decode_runs=5.20,4.66 publish_ms/frame=6.31 publish_runs=7.21,5.40 PSNR_dB=55.118609 SSIM=0.999351
motion encoder=libx264 decoder=h264 crf=28 bytes=4802327 Mbps=19.209 encode_ms/frame=17.13 decode_ms/frame=4.08 encode_runs=17.26,17.01 decode_runs=4.08,4.09 publish_ms/frame=3.38 publish_runs=3.81,2.95 PSNR_dB=45.784925 SSIM=0.995912
motion encoder=SvtAv1EncApp decoder=dav1d crf=20 bytes=7299893 Mbps=29.200 encode_ms/frame=69.09 decode_ms/frame=8.46 encode_runs=70.39,67.80 decode_runs=7.93,8.99 publish_ms/frame=5.18 publish_runs=4.79,5.57 PSNR_dB=43.305144 SSIM=0.995138
motion encoder=SvtAv1EncApp decoder=dav1d crf=32 bytes=4249100 Mbps=16.996 encode_ms/frame=67.12 decode_ms/frame=7.55 encode_runs=66.33,67.91 decode_runs=7.63,7.46 publish_ms/frame=2.81 publish_runs=2.54,3.09 PSNR_dB=41.418052 SSIM=0.990910
motion encoder=SvtAv1EncApp decoder=dav1d crf=15 bytes=8612604 Mbps=34.450 encode_ms/frame=70.50 decode_ms/frame=8.92 encode_runs=71.33,69.67 decode_runs=8.80,9.04 publish_ms/frame=5.01 publish_runs=5.15,4.86 PSNR_dB=44.575983 SSIM=0.996144
```

On motion, SVT 15 approached x264 28 in SSIM (0.996144 vs 0.995912), but PSNR was 1.21 dB lower. It needed 34.450 vs 19.209 Mbps and 70.50 vs 17.13 ms/frame to encode. This is an approximate SSIM match, not equal visual quality. Even the cheapest SVT encode alone exceeded the 16.67 ms/frame throughput budget. Publication waits for all 120 frames: no live capture, first-frame latency, frame pacing or presentation was measured. These results favor x264 for speed on this machine, not a universal codec ranking. `swift test`: 89 executed, zero failures.

## Two-slot DAX pipeline and independent control

Run `python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --seconds 10 --rounds 3` from `exp-wayland` with the same pinned standard ISO and HVF/pmem configuration as the paced test. Both full-sized slots were discovered as distinct contiguous extents. Inode DAX was confirmed; MAP_SYNC was unsupported. A 60 Hz issuer takes a free slot without waiting for the other slot's acknowledgment; the consumer returns it only after ordered FRAME acknowledgment and fresh nonce/payload verification. Both entire slots matched their shadows after every round. `overlap` counts reservations made while the other slot was still reserved, not simultaneous guest writes. One second of unreported warm-up per mode precedes the three measured rounds.

A separate host worker sent 10 nonce echoes/s via virtio-serial to a separate guest shell responder. RTT starts at send, not the scheduled tick; separate channel does not mean separate CPU. CPU seconds are probe/QEMU/guest writer (excluding guest echo process from the last figure). `tick_ms` is scheduled grant through verified completion; it includes host scheduling and preparation. Percentiles are p50/p95/p99. Verified bytes = verified count × size.

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- control_n=100 control_ms=0.755/1.603/2.721 cpu_s=0.057/0.320/0.000
ring size=0 round=2 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- control_n=100 control_ms=0.729/1.426/2.813 cpu_s=0.056/0.300/0.000
ring size=0 round=3 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- control_n=100 control_ms=0.695/1.805/2.343 cpu_s=0.054/0.530/0.000
ring size=8294400 round=1 verified=568 overlap=342 skipped=32 late=564 MiB/s=448.93 tick_ms=25.275/42.346/64.501 control_n=100 control_ms=4.915/11.725/15.102 cpu_s=4.613/7.400/2.098
ring size=8294400 round=2 verified=570 overlap=305 skipped=30 late=570 MiB/s=450.75 tick_ms=24.009/41.605/54.392 control_n=100 control_ms=4.956/11.002/17.799 cpu_s=4.658/7.420/1.690
ring size=8294400 round=3 verified=572 overlap=334 skipped=28 late=570 MiB/s=452.08 tick_ms=24.974/41.278/55.448 control_n=100 control_ms=4.438/10.459/13.080 cpu_s=4.724/7.560/1.857
ring size=262144 round=1 verified=595 overlap=7 skipped=5 late=13 MiB/s=14.87 tick_ms=8.408/13.740/28.036 control_n=100 control_ms=4.347/6.836/8.898 cpu_s=0.478/5.030/0.014
ring size=262144 round=2 verified=596 overlap=16 skipped=4 late=20 MiB/s=14.90 tick_ms=8.896/15.423/38.337 control_n=100 control_ms=4.821/8.136/10.553 cpu_s=0.484/5.000/0.048
ring size=262144 round=3 verified=596 overlap=4 skipped=4 late=10 MiB/s=14.90 tick_ms=8.757/13.058/19.555 control_n=100 control_ms=4.391/6.390/15.685 cpu_s=0.478/5.070/0.007
```

Compared with the earlier single-slot full-frame run, throughput rose from 421–426 to 449–452 MiB/s and skipped ticks fell from 61–67 to 28–32 per 600. But 564–570 completions per round missed their own 16.67 ms deadline: buffering admitted more work without delivering it on time. Damage was similar in bandwidth (14.87–14.90 vs 14.77–15.00 MiB/s), with 10–20 late completions vs 6–14. Independent control p99 was 2.34–2.81 ms idle, 13.08–17.80 ms full and 8.90–15.69 ms damage. The earlier queued ping used a different transport and timing point: these are observed configurations, not an isolated slot-count or control-channel A/B. No presentation or persistence test; M1 remains open.

## Ring latency breakdown

On the same Intel HVF configuration, run the copy baseline first, then the native comparison in a fresh VM:

```sh
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --copy-verify --seconds 10 --rounds 3
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --seconds 10 --rounds 3
```

For issued frames, `wake` is scheduled tick to issuer wake; `prep` runs from wake to just before sending the grant. `write` is elapsed guest CLOCK_MONOTONIC time around fill, nonce store and fence, not thread CPU time. `verify` starts after parsing the ordered ACK and includes the byte check and shadow update. `remaining` is host send-to-parsed-ACK **duration** less guest write **duration** for that frame. It includes serial I/O, dispatch, queueing and reader scheduling, not just wire latency. No host timestamp is subtracted from a guest timestamp. These stages sum to tick-to-done per frame, not at each percentile. Skipped slots have no stage sample.

Full-frame baseline medians exposed 3.53–3.69 ms in preparation and 4.66–4.78 ms in verification. Only the host verifier/fixture changed: compare the nonce and every payload byte in place against reusable 64 KiB uniform blocks on a second read-only mapping of the dedicated file. Keep a compact full-slot expectation until the untimed shadow audit; damage still updates its packed range and the audit checks unchanged bytes too. No guest write, pacing or control-channel optimization. Full-frame prep and verify medians fell to about 0.06 and 1.54–1.58 ms; damage verification did not improve. The runs were sequential, not randomized.

<details>
<summary>Three measured rounds per mode; p50/p95/p99 in milliseconds</summary>

Copy baseline:

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.749/2.050/5.525 cpu_s=0.058/0.310/0.000
ring size=0 round=2 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.774/3.753/9.460 cpu_s=0.053/0.310/0.000
ring size=0 round=3 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.695/1.533/2.548 cpu_s=0.054/0.640/0.000
ring size=8294400 round=1 verified=575 overlap=314 skipped=25 late=574 MiB/s=454.22 tick_ms=24.309/38.868/54.916 wake_ms=2.557/7.202/10.358 prep_ms=3.653/6.379/9.905 write_ms=4.707/12.521/17.099 verify_ms=4.655/7.581/10.484 remaining_ms=7.366/15.702/23.385 control_n=100 control_ms=4.626/9.849/15.056 cpu_s=4.770/7.390/1.550
ring size=8294400 round=2 verified=572 overlap=325 skipped=28 late=569 MiB/s=452.26 tick_ms=24.945/41.187/52.390 wake_ms=2.453/7.544/11.147 prep_ms=3.687/5.858/8.684 write_ms=4.797/13.565/17.185 verify_ms=4.784/8.041/11.197 remaining_ms=7.573/16.457/20.559 control_n=100 control_ms=4.826/12.608/17.441 cpu_s=4.778/7.430/1.717
ring size=8294400 round=3 verified=579 overlap=302 skipped=21 late=575 MiB/s=457.83 tick_ms=24.002/37.211/47.543 wake_ms=2.300/6.686/10.754 prep_ms=3.527/5.613/8.215 write_ms=4.610/11.376/14.772 verify_ms=4.754/6.982/10.633 remaining_ms=7.326/15.793/21.847 control_n=100 control_ms=4.653/8.766/16.969 cpu_s=4.782/7.460/1.489
ring size=262144 round=1 verified=599 overlap=8 skipped=1 late=13 MiB/s=14.97 tick_ms=8.402/12.095/25.407 wake_ms=2.267/3.798/6.941 prep_ms=0.150/0.334/0.726 write_ms=0.102/0.270/0.711 verify_ms=0.152/0.315/0.716 remaining_ms=5.514/8.777/16.815 control_n=100 control_ms=4.468/8.110/12.072 cpu_s=0.551/5.120/0.018
ring size=262144 round=2 verified=594 overlap=6 skipped=6 late=11 MiB/s=14.85 tick_ms=8.590/13.572/19.854 wake_ms=2.332/3.833/5.312 prep_ms=0.144/0.547/1.017 write_ms=0.102/0.263/0.413 verify_ms=0.152/0.349/0.495 remaining_ms=5.725/9.733/17.521 control_n=100 control_ms=4.501/7.080/15.162 cpu_s=0.558/5.090/0.010
ring size=262144 round=3 verified=600 overlap=1 skipped=0 late=6 MiB/s=15.00 tick_ms=8.573/12.654/16.252 wake_ms=2.372/3.756/4.405 prep_ms=0.155/0.418/0.671 write_ms=0.103/0.266/0.738 verify_ms=0.155/0.355/0.654 remaining_ms=5.724/9.345/12.715 control_n=100 control_ms=4.205/6.572/7.378 cpu_s=0.568/5.120/0.016
```

Native comparison:

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.741/1.562/1.816 cpu_s=0.059/0.320/0.000
ring size=0 round=2 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.690/1.279/1.903 cpu_s=0.057/0.300/0.000
ring size=0 round=3 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.720/1.941/3.369 cpu_s=0.055/0.500/0.000
ring size=8294400 round=1 verified=590 overlap=69 skipped=10 late=125 MiB/s=466.69 tick_ms=14.255/25.903/43.211 wake_ms=2.270/3.951/6.164 prep_ms=0.061/0.180/0.590 write_ms=4.504/9.315/12.442 verify_ms=1.535/3.439/6.926 remaining_ms=5.602/11.165/28.285 control_n=100 control_ms=3.985/6.648/7.774 cpu_s=1.385/7.260/1.044
ring size=8294400 round=2 verified=596 overlap=62 skipped=4 late=126 MiB/s=471.43 tick_ms=14.090/25.871/38.093 wake_ms=2.303/3.890/5.559 prep_ms=0.062/0.376/0.589 write_ms=4.314/8.075/13.324 verify_ms=1.577/3.228/5.541 remaining_ms=5.615/11.529/20.452 control_n=100 control_ms=3.813/6.746/10.415 cpu_s=1.397/7.450/0.946
ring size=8294400 round=3 verified=592 overlap=45 skipped=8 late=94 MiB/s=467.90 tick_ms=14.105/23.701/33.528 wake_ms=2.345/3.886/5.625 prep_ms=0.061/0.173/0.604 write_ms=4.330/7.161/13.196 verify_ms=1.573/3.104/5.358 remaining_ms=5.653/9.182/14.545 control_n=100 control_ms=4.175/7.275/10.923 cpu_s=1.378/7.350/0.803
ring size=262144 round=1 verified=600 overlap=1 skipped=0 late=2 MiB/s=15.00 tick_ms=8.456/12.092/14.893 wake_ms=2.307/3.909/4.982 prep_ms=0.062/0.157/0.531 write_ms=0.102/0.245/0.505 verify_ms=0.245/0.602/0.913 remaining_ms=5.615/8.411/10.393 control_n=100 control_ms=4.296/6.322/7.154 cpu_s=0.570/5.160/0.003
ring size=262144 round=2 verified=593 overlap=7 skipped=7 late=12 MiB/s=14.82 tick_ms=8.512/12.677/31.988 wake_ms=2.222/3.772/4.783 prep_ms=0.062/0.166/0.523 write_ms=0.102/0.268/0.601 verify_ms=0.243/0.498/0.814 remaining_ms=5.670/9.156/19.462 control_n=100 control_ms=4.135/7.080/15.081 cpu_s=0.556/5.110/0.020
ring size=262144 round=3 verified=599 overlap=5 skipped=1 late=11 MiB/s=14.97 tick_ms=8.766/12.555/18.198 wake_ms=2.389/3.934/5.097 prep_ms=0.063/0.357/0.664 write_ms=0.103/0.250/0.754 verify_ms=0.245/0.521/0.907 remaining_ms=5.795/8.599/13.345 control_n=100 control_ms=4.369/6.641/10.453 cpu_s=0.570/5.150/0.014
```

</details>

**Gates:** Ordered sequence, fresh nonce, every payload byte and both end-of-round shadows passed. For sustained 1080p60 require ~474.6 MiB/s and all 600 grants verified by their own 16.67 ms deadlines in each round. Native comparison reached 466.69–471.43 MiB/s with 4–10 skipped and 94–126 late: fail. For packed 256×256 BGRA require 15 MiB/s with the same pacing gate; 14.82–15.00 MiB/s with 2–12 late: fail even in the no-skip round. The largest remaining median stage under either load is the send/ACK remainder; distinguish guest dispatch from host ACK handling before changing transport. No presentation timestamps. Keep M1 open pending deadline-clean delivery and live H.264/AV1 access-unit publication, continuous decode, first-frame and tail measurements. Swift regression: 89 tests, zero failures.

## Dedicated grant and ACK port

`--ring --frame-port` moves the same host-issued grants and guest ACKs off the emulated console to a second virtio-serial port. Port 1 still carries only independent control echoes; pixels still travel through the two DAX slots. Slot reuse still waits for ordered ACK, nonce and exact byte verification; both final shadows matched every round. No guest helper or clock-domain change.

Run in the order measured, in fresh VMs (sequential, not randomized):

```sh
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --frame-port --seconds 10 --rounds 3
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --seconds 10 --rounds 3
```

The full-frame median send/ACK remainder fell from 5.68–5.83 to 0.77–0.78 ms; late completions fell from 253–269 to 16–25 per round. Damage misses fell from 16–34 late to 2–3 late. The host wake delay now exceeds the dispatch remainder: about 4 ms median and 7 ms p95 for both loads. Full-frame write p95 adds 6.5–7.1 ms. These percentiles are not additive or proof of what caused individual misses. Next separate expired wakes from credit starvation on skipped ticks and capture stages for individual late frames before changing pacing. Neither load passed all 600 deadlines in any round. Control p99 under full load still reached 20.92 ms. These are verified deliveries, not presentations. Swift regression: 89 passed.

<details><summary>Fresh rounds, same units and warm-up as above</summary>

Dedicated port:

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.751/1.511/2.532 cpu_s=0.056/0.300/0.005
ring size=0 round=2 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.793/2.429/12.817 cpu_s=0.056/0.290/0.005
ring size=0 round=3 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.763/1.829/3.536 cpu_s=0.054/0.440/0.005
ring size=8294400 round=1 verified=594 overlap=12 skipped=6 late=25 MiB/s=469.72 tick_ms=11.023/16.069/27.545 wake_ms=4.045/6.818/8.195 prep_ms=0.061/0.246/0.630 write_ms=4.123/6.652/11.218 verify_ms=1.522/3.343/5.972 remaining_ms=0.778/1.834/5.192 control_n=100 control_ms=0.651/2.006/11.247 cpu_s=1.220/3.840/2.623
ring size=8294400 round=2 verified=600 overlap=7 skipped=0 late=16 MiB/s=474.59 tick_ms=10.863/15.457/20.042 wake_ms=4.045/6.849/7.938 prep_ms=0.062/0.243/0.649 write_ms=3.974/6.506/8.738 verify_ms=1.461/3.119/5.804 remaining_ms=0.774/1.578/3.263 control_n=100 control_ms=0.615/1.873/3.179 cpu_s=1.213/3.850/2.570
ring size=8294400 round=3 verified=588 overlap=12 skipped=12 late=23 MiB/s=465.11 tick_ms=10.917/16.028/36.804 wake_ms=4.132/7.233/8.801 prep_ms=0.062/0.196/0.590 write_ms=4.042/7.127/10.471 verify_ms=1.510/3.226/5.194 remaining_ms=0.782/1.714/7.235 control_n=100 control_ms=0.636/2.849/20.920 cpu_s=1.210/3.780/2.662
ring size=262144 round=1 verified=594 overlap=1 skipped=6 late=2 MiB/s=14.85 tick_ms=5.370/8.616/11.347 wake_ms=4.037/7.218/8.644 prep_ms=0.063/0.324/0.632 write_ms=0.103/0.255/0.401 verify_ms=0.245/0.478/0.775 remaining_ms=0.704/1.582/2.953 control_n=100 control_ms=0.643/1.217/4.411 cpu_s=0.417/1.610/0.151
ring size=262144 round=2 verified=600 overlap=0 skipped=0 late=3 MiB/s=15.00 tick_ms=5.246/8.486/10.812 wake_ms=3.960/7.118/8.252 prep_ms=0.062/0.240/0.640 write_ms=0.102/0.217/0.400 verify_ms=0.239/0.498/0.870 remaining_ms=0.657/1.542/3.110 control_n=100 control_ms=0.630/1.392/2.056 cpu_s=0.415/1.630/0.150
ring size=262144 round=3 verified=595 overlap=1 skipped=5 late=2 MiB/s=14.87 tick_ms=5.379/9.052/10.928 wake_ms=4.025/7.008/8.101 prep_ms=0.063/0.225/0.558 write_ms=0.103/0.242/0.337 verify_ms=0.249/0.477/0.737 remaining_ms=0.685/1.762/4.607 control_n=100 control_ms=0.683/2.387/4.990 cpu_s=0.418/1.620/0.169
```

Console baseline:

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.837/2.047/6.085 cpu_s=0.058/0.310/0.000
ring size=0 round=2 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.731/1.680/2.658 cpu_s=0.055/0.310/0.000
ring size=0 round=3 verified=0 overlap=0 skipped=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- control_n=100 control_ms=0.770/2.487/5.292 cpu_s=0.056/0.480/0.000
ring size=8294400 round=1 verified=589 overlap=101 skipped=11 late=262 MiB/s=465.69 tick_ms=16.100/29.604/47.879 wake_ms=4.239/7.223/8.631 prep_ms=0.061/0.239/0.696 write_ms=3.962/9.006/16.744 verify_ms=1.534/3.813/5.067 remaining_ms=5.682/11.206/25.424 control_n=100 control_ms=3.131/6.260/7.832 cpu_s=1.386/7.000/0.967
ring size=8294400 round=2 verified=578 overlap=93 skipped=22 late=269 MiB/s=457.04 tick_ms=16.401/34.397/61.598 wake_ms=4.259/7.356/11.356 prep_ms=0.062/0.218/0.594 write_ms=3.977/9.902/14.305 verify_ms=1.554/3.625/6.168 remaining_ms=5.831/15.451/30.650 control_n=100 control_ms=2.586/6.288/21.598 cpu_s=1.346/6.880/0.940
ring size=8294400 round=3 verified=595 overlap=93 skipped=5 late=253 MiB/s=470.64 tick_ms=16.177/27.556/42.509 wake_ms=4.079/6.738/8.389 prep_ms=0.066/0.280/0.805 write_ms=3.882/8.834/14.309 verify_ms=1.560/3.355/5.799 remaining_ms=5.788/11.017/17.850 control_n=100 control_ms=3.519/5.744/6.627 cpu_s=1.395/7.140/0.874
ring size=262144 round=1 verified=593 overlap=6 skipped=7 late=16 MiB/s=14.82 tick_ms=11.068/15.760/22.351 wake_ms=4.310/7.387/9.391 prep_ms=0.063/0.206/0.661 write_ms=0.102/0.239/0.365 verify_ms=0.234/0.587/1.695 remaining_ms=5.865/9.491/14.042 control_n=100 control_ms=3.394/6.063/13.205 cpu_s=0.552/5.050/0.003
ring size=262144 round=2 verified=597 overlap=13 skipped=3 late=26 MiB/s=14.92 tick_ms=10.511/16.174/29.215 wake_ms=4.046/7.078/8.447 prep_ms=0.064/0.197/0.497 write_ms=0.103/0.267/1.194 verify_ms=0.240/0.575/1.369 remaining_ms=5.867/10.842/22.827 control_n=100 control_ms=2.421/6.084/10.839 cpu_s=0.566/4.960/0.018
ring size=262144 round=3 verified=595 overlap=18 skipped=5 late=34 MiB/s=14.87 tick_ms=10.806/17.093/29.607 wake_ms=3.923/7.258/9.663 prep_ms=0.061/0.211/0.689 write_ms=0.113/0.308/1.179 verify_ms=0.247/0.532/1.779 remaining_ms=6.013/10.960/21.037 control_n=100 control_ms=3.020/6.192/7.841 cpu_s=0.569/5.030/0.016
```

</details>

## Host tick wait experiment

Fresh dedicated-port runs on Intel HVF, baseline first, then a fresh VM with `--mach-wait` added to the dedicated-port command above. Same warm-up, three 10-second rounds per load, 60 Hz origin and deadline, two slots, independent control, and all ACK, byte and shadow checks. `expired_wake` counts producer wakes already at or past the deadline; `no_slot` counts only unexpired attempts that found neither slot free. Idle has no frame attempts. `late_*_ms` reports stage p50/p95/p99 only for verified completions over budget; `-` means none.

Baseline damage skips were mostly expired wakes (6 of 7), motivating an absolute Mach wait on the producer only, without spinning or early grants. Full-frame skips were mostly no-slot (29 of 33); guest write was the largest late-frame median stage in all three rounds (7.82–12.69 ms). The wait experiment did not consistently improve wake latency. Full-frame late counts fell in aggregate but varied from 202 to 6 within baseline alone; sequential runs do not isolate a scheduler win. Damage was deadline-clean in one baseline and two Mach rounds, not all three. Keep the default. Next isolate full-frame write stalls and damage send/ACK tails rather than tuning the tick period. Delivery only, not presentation; M1 remains open. Swift: 89 passed.

<details><summary>Baseline: measured rounds</summary>

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.787/1.742/2.689 cpu_s=0.058/0.310/0.006
ring size=0 round=2 verified=0 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.860/2.824/8.761 cpu_s=0.057/0.310/0.005
ring size=0 round=3 verified=0 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.829/5.096/22.570 cpu_s=0.054/0.410/0.011
ring size=8294400 round=1 verified=576 overlap=156 skipped=24 expired_wake=0 no_slot=24 late=202 MiB/s=455.55 tick_ms=11.961/33.472/53.820 wake_ms=2.304/4.748/9.479 prep_ms=0.063/0.198/0.908 write_ms=5.660/18.351/31.849 verify_ms=2.102/9.012/12.889 remaining_ms=1.023/10.568/19.613 late_wake_ms=2.618/8.859/12.255 late_prep_ms=0.064/0.357/1.453 late_write_ms=12.688/25.578/48.160 late_verify_ms=3.497/10.995/14.107 late_remaining_ms=3.162/17.898/31.243 control_n=100 control_ms=0.911/12.025/13.917 cpu_s=1.394/4.230/4.296
ring size=8294400 round=2 verified=591 overlap=30 skipped=9 expired_wake=4 no_slot=5 late=38 MiB/s=467.44 tick_ms=9.569/20.082/37.193 wake_ms=2.270/3.840/6.053 prep_ms=0.062/0.193/0.507 write_ms=4.298/9.390/15.878 verify_ms=1.611/3.778/11.156 remaining_ms=0.811/2.923/8.972 late_wake_ms=2.522/7.720/12.838 late_prep_ms=0.061/0.251/0.270 late_write_ms=11.678/22.965/28.889 late_verify_ms=3.916/20.730/25.342 late_remaining_ms=4.015/19.839/30.154 control_n=100 control_ms=0.622/2.252/12.311 cpu_s=1.274/4.140/2.903
ring size=8294400 round=3 verified=600 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=6 MiB/s=474.55 tick_ms=9.439/13.237/16.182 wake_ms=2.630/3.667/4.770 prep_ms=0.061/0.195/0.547 write_ms=4.225/6.497/8.184 verify_ms=1.500/2.617/3.809 remaining_ms=0.781/1.564/2.351 late_wake_ms=2.822/7.150/7.150 late_prep_ms=0.067/0.575/0.575 late_write_ms=7.820/13.126/13.126 late_verify_ms=2.263/6.172/6.172 late_remaining_ms=0.916/6.523/6.523 control_n=100 control_ms=0.618/1.908/2.891 cpu_s=1.218/4.100/2.592
ring size=262144 round=1 verified=596 overlap=1 skipped=4 expired_wake=4 no_slot=0 late=1 MiB/s=14.90 tick_ms=3.833/5.844/7.193 wake_ms=2.536/3.822/4.762 prep_ms=0.061/0.245/0.518 write_ms=0.118/0.309/0.500 verify_ms=0.243/0.519/0.825 remaining_ms=0.688/1.608/3.376 late_wake_ms=3.409/3.409/3.409 late_prep_ms=0.043/0.043/0.043 late_write_ms=0.151/0.151/0.151 late_verify_ms=0.195/0.195/0.195 late_remaining_ms=32.276/32.276/32.276 control_n=100 control_ms=0.671/1.760/3.697 cpu_s=0.415/1.790/0.175
ring size=262144 round=2 verified=600 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=15.00 tick_ms=3.436/5.284/6.899 wake_ms=2.196/3.725/4.424 prep_ms=0.062/0.192/0.471 write_ms=0.113/0.271/0.460 verify_ms=0.232/0.485/0.995 remaining_ms=0.628/1.454/2.302 late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.636/1.290/1.820 cpu_s=0.407/1.790/0.162
ring size=262144 round=3 verified=597 overlap=4 skipped=3 expired_wake=2 no_slot=1 late=6 MiB/s=14.92 tick_ms=3.776/8.144/17.018 wake_ms=2.422/4.156/6.787 prep_ms=0.062/0.162/0.600 write_ms=0.118/0.337/0.674 verify_ms=0.253/0.732/2.418 remaining_ms=0.695/3.397/11.606 late_wake_ms=4.475/12.601/12.601 late_prep_ms=0.062/0.079/0.079 late_write_ms=0.135/1.072/1.072 late_verify_ms=0.243/1.841/1.841 late_remaining_ms=18.195/28.297/28.297 control_n=100 control_ms=0.721/3.047/13.410 cpu_s=0.425/1.730/0.233
```

</details>

<details><summary>Absolute Mach wait: measured rounds</summary>

```text
ring size=0 round=1 verified=0 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.760/2.364/6.675 cpu_s=0.072/0.330/0.008
ring size=0 round=2 verified=0 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.901/2.062/2.823 cpu_s=0.072/0.370/0.015
ring size=0 round=3 verified=0 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=0.00 tick_ms=- wake_ms=- prep_ms=- write_ms=- verify_ms=- remaining_ms=- late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.913/2.131/2.398 cpu_s=0.070/0.660/0.017
ring size=8294400 round=1 verified=598 overlap=9 skipped=2 expired_wake=0 no_slot=2 late=21 MiB/s=473.02 tick_ms=10.291/15.582/23.367 wake_ms=2.390/3.839/5.435 prep_ms=0.060/0.174/0.608 write_ms=4.886/7.769/10.595 verify_ms=1.696/3.494/5.582 remaining_ms=1.012/2.231/3.867 late_wake_ms=3.220/9.273/10.751 late_prep_ms=0.064/0.077/0.206 late_write_ms=7.933/23.908/41.907 late_verify_ms=3.164/10.875/14.917 late_remaining_ms=2.227/5.376/36.882 control_n=100 control_ms=0.787/2.601/4.096 cpu_s=1.328/4.760/3.316
ring size=8294400 round=2 verified=598 overlap=15 skipped=2 expired_wake=1 no_slot=1 late=30 MiB/s=472.97 tick_ms=10.425/16.682/30.090 wake_ms=2.439/3.940/6.288 prep_ms=0.060/0.173/0.638 write_ms=4.965/8.414/12.213 verify_ms=1.709/3.569/5.035 remaining_ms=1.011/2.805/9.092 late_wake_ms=3.255/12.199/13.849 late_prep_ms=0.057/0.231/0.838 late_write_ms=8.472/17.579/22.767 late_verify_ms=3.576/8.451/8.661 late_remaining_ms=4.227/18.582/19.317 control_n=100 control_ms=0.774/2.490/4.631 cpu_s=1.323/4.700/3.384
ring size=8294400 round=3 verified=594 overlap=18 skipped=6 expired_wake=6 no_slot=0 late=28 MiB/s=469.84 tick_ms=10.489/16.385/22.345 wake_ms=2.254/3.912/6.147 prep_ms=0.060/0.176/0.496 write_ms=4.988/8.532/11.192 verify_ms=1.722/3.570/6.489 remaining_ms=1.000/2.295/4.060 late_wake_ms=3.061/13.200/16.267 late_prep_ms=0.057/0.107/0.130 late_write_ms=8.420/11.792/12.195 late_verify_ms=3.625/9.068/123.337 late_remaining_ms=2.009/8.978/10.888 control_n=100 control_ms=0.806/3.664/7.186 cpu_s=1.324/4.660/3.358
ring size=262144 round=1 verified=600 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=15.00 tick_ms=4.072/6.379/8.797 wake_ms=2.489/3.939/5.333 prep_ms=0.059/0.176/0.524 write_ms=0.136/0.422/0.740 verify_ms=0.255/0.654/0.993 remaining_ms=0.918/2.223/3.820 late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.927/2.604/4.034 cpu_s=0.450/2.040/0.336
ring size=262144 round=2 verified=596 overlap=1 skipped=4 expired_wake=4 no_slot=0 late=3 MiB/s=14.90 tick_ms=3.784/6.269/10.851 wake_ms=2.278/3.814/4.795 prep_ms=0.059/0.137/0.459 write_ms=0.133/0.428/0.958 verify_ms=0.248/0.570/0.992 remaining_ms=0.904/2.163/5.380 late_wake_ms=4.795/15.975/15.975 late_prep_ms=0.053/0.062/0.062 late_write_ms=0.131/0.362/0.362 late_verify_ms=0.457/0.632/0.632 late_remaining_ms=12.387/96.291/96.291 control_n=100 control_ms=0.830/2.852/5.255 cpu_s=0.439/2.010/0.331
ring size=262144 round=3 verified=600 overlap=0 skipped=0 expired_wake=0 no_slot=0 late=0 MiB/s=15.00 tick_ms=3.938/6.397/9.102 wake_ms=2.386/3.774/4.537 prep_ms=0.059/0.165/0.511 write_ms=0.150/0.398/0.772 verify_ms=0.251/0.574/1.034 remaining_ms=0.924/2.265/4.702 late_wake_ms=- late_prep_ms=- late_write_ms=- late_verify_ms=- late_remaining_ms=- control_n=100 control_ms=0.992/2.060/4.220 cpu_s=0.448/2.040/0.349
```

</details>

## Guest streaming fill

Both slot-discovery grants already write every page before timing. Rather than prefault them again, `--compare-stream` tests aligned SSE2 non-temporal stores against the existing memset on the synthetic full-frame producer. The guest orders streaming stores before writing the random tag and retains the publication fence before ACK. This measures a fill, not a compositor buffer copy.

Run `python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --frame-port --compare-stream --seconds 10 --rounds 3`. The table uses the standalone rerun, excluding two earlier launches that overlapped. One pinned Intel HVF guest, DAX confirmed (`MAP_SYNC` unsupported), default host sleep, one second warm-up per arm, 600 ticks and 100 independent echoes per measured arm. Rows are in execution order. All completed frames passed sequence and full-byte verification before slot release; both final shadows matched after every interval.

| Round | Fill | Verified | Expired wake | No slot | Late | Guest write p50/p95/p99 ms | Tick to verified p99 ms | Grant/ACK residual p99 ms |
|---:|---|---:|---:|---:|---:|---|---:|---:|
| 1 | baseline | 600 | 0 | 0 | 12 | 4.206/7.170/9.253 | 19.564 | 2.644 |
| 1 | stream | 592 | 8 | 0 | 3 | 0.647/1.432/2.115 | 14.207 | 3.908 |
| 2 | stream | 600 | 0 | 0 | 3 | 0.622/1.449/2.427 | 15.009 | 2.834 |
| 2 | baseline | 595 | 5 | 0 | 17 | 4.265/7.018/11.884 | 23.912 | 5.035 |
| 3 | baseline | 600 | 0 | 0 | 4 | 4.313/6.985/8.994 | 15.604 | 2.255 |
| 3 | stream | 594 | 6 | 0 | 7 | 0.629/1.513/1.992 | 26.287 | 6.538 |

Guest write p99 improved in every pair, but streaming skipped 14 ticks versus 5 for memset. In round 3 the end-to-end p99 regressed even as write p99 improved. Damage (unchanged) verified 600/597/600, with 0/1/0 late. Keep this as an opt-in experiment: neither the zero-skip/zero-late gate nor display presentation was established. Next split the grant/ACK residual into guest receive-to-write and post-write ACK delivery before changing polling.

## Host issuer QoS

`python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/alpine.iso" --ring --frame-port --compare-qos --seconds 10 --rounds 3` compares default and user-interactive pthread QoS on the host grant issuer. Guest pacing would change the grant protocol and require mapping guest ticks to host verification deadlines; this narrower test keeps the host timer and both arms use streaming fills for full frames. Deadlines and verification timestamps use host monotonic time. Guest write time is an elapsed duration only; the host grant-to-ACK interval minus this duration is a residual, not one-way latency. Wake percentiles cover issued frames, not expired ticks.

Live DAX full-frame results in execution order (600 scheduled ticks per row; milliseconds):

|Round|Issuer|Verified|Expired|No slot|Late verified|Wake p99|Tick to verified p99|Control RTT p99|
|---:|---|---:|---:|---:|---:|---:|---:|---:|
|1|Default|594|6|0|17|7.950|26.950|8.793|
|1|Interactive|600|0|0|11|5.939|19.748|9.149|
|2|Interactive|600|0|0|2|4.483|14.082|2.702|
|2|Default|595|5|0|5|6.109|16.138|8.072|
|3|Default|600|0|0|8|6.237|19.761|4.683|
|3|Interactive|593|6|1|10|8.312|29.129|4.755|

All trials completed sequence, full-byte and final slot-shadow checks; no slot was released before verification. Every interval returned 100 independent control echoes. Idle control p99 was 3.748/4.036/2.148 ms. Default-QoS damage verified 600/594/599, with 3/4/3 late and control p99 3.612/2.949/6.043 ms. Interactive QoS reduced misses in two pairs but regressed in the third; even its best interval missed two deadlines despite a sub-budget p99. Keep the optimization opt-in. Neither workload passed, and no presentation endpoint was measured.

## Guest autonomous publication

```sh
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --autonomous --seconds 10 --rounds 3
```

After two host-directed discovery writes, one start message specifies the tick count, payload size and initial sequence. The guest polls a `CLOCK_MONOTONIC` timerfd armed to absolute `origin + floor(i × 10⁹ / 60)` deadlines alongside the credit port. It skips expired ticks and ticks without a free slot rather than blocking the clock on verification. Full frames use streaming stores; 256 KiB damage uses memset. The host derives the expected tag, payload and offset, compares every published byte in its read-only mapping, then returns that slot and sequence. Both endpoints check reuse; the host also checks both final slot images and reconciles verified sequences, skipped ticks and return receipts. Control echoes run at 10 Hz on a separate virtio-serial port.

**Age endpoint differs from the host-issued baseline.** `tick_to_credit_ms` starts at the scheduled guest tick and ends when the guest reads the matching post-verification credit. Both timestamps are guest monotonic; the interval includes return transit and guest scheduling. A late credit does not prove that host verification itself was late. The earlier `tick_ms` ends at host verification and uses a host tick. Neither endpoint measures presentation.

For a historical, not interleaved, comparison, use the default-QoS host-issued streaming arm above: full frames verified 594/595/600 and damage 600/594/599 out of 600. Those host-side verification deadlines missed 17/5/8 and 3/4/3 times respectively, excluding skips. Compare accounted ticks and exact-byte completions directly, not the two latency endpoints as if they were identical.

Live HVF, inode DAX confirmed, MAP_SYNC unsupported. Three 10-second rounds per workload after warm-up. Idle independent RTT p99: 3.212/2.862/2.873 ms. Each loaded round returned 100/100 echoes.

|Payload|Round|Verified / 600|Expired|No credit|Late credit|Tick to credit p50/p95/p99 ms|Control RTT p99 ms|
|---|---:|---:|---:|---:|---:|---|---:|
|Full|1|589|10|1|12|4.281/9.624/23.684|8.768|
|Full|2|600|0|0|6|4.283/8.819/16.451|6.162|
|Full|3|596|4|0|3|4.278/8.162/13.204|10.542|
|Damage|1|600|0|0|0|2.131/4.514/7.807|3.855|
|Damage|2|600|0|0|1|2.123/4.425/6.539|4.199|
|Damage|3|594|6|0|0|2.010/4.309/7.733|5.969|

No byte or sequence mismatch. The zero-skip, zero-late gate was not met; M1 remains open.

## Same-session producer comparison

```sh
for block in 65536 262144; do
  python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --compare-producers --verify-block "$block" --seconds 10 --rounds 3 || exit 1
done
swift test && git diff --check
```

Each verifier block size ran in a fresh Intel HVF VM (inode DAX confirmed, MAP_SYNC unsupported). Within each VM both producers used the same mappings, two slots, frame port, independent 10 Hz echo port, exact checks, full streaming stores and damage memset. Each payload had one second of warm-up per arm. Rows follow execution order. Each loaded row accounts for 600 ticks; throughput counts only verified payload over host elapsed time including drain, at least 10 seconds. All idle and loaded intervals returned 100/100 echoes. Final slot shadows matched throughout.

H = host-paced grant to guest writer; G = guest-paced autonomous writer. Age starts at scheduled tick on the issuer's clock. H ends at host verification; G ends at guest credit receipt, *after* host verification, so a late G credit need not mean a late verification. No cross-clock subtraction. Verify is comparable host monotonic time from parsed frame notice/ACK through byte compare and shadow update, before slot release; it excludes transport and notification queueing. Wake and write are issuer wake delay and guest fill duration, respectively. Stage p99s cover completed frames only and are not additive. Times below are p99 milliseconds.

**64 KiB verifier blocks**. Idle control RTT p99 by round: 7.768/7.086/6.321 ms.

|Round|Payload|Arm|Verified|Expired|No slot|Late|MiB/s|Wake|Write|Verify|Age|Control RTT|
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|1|full|H|595|4|1|13|470.54|7.834|4.656|5.297|23.068|17.846|
|1|full|G|600|0|0|0|474.44|3.779|2.510|5.438|11.140|4.648|
|2|full|G|595|5|0|5|470.64|4.624|3.608|5.014|16.521|3.991|
|2|full|H|600|0|0|2|474.47|6.151|3.685|4.928|13.029|4.095|
|3|full|H|600|0|0|1|474.53|6.245|3.150|6.077|14.180|3.325|
|3|full|G|595|5|0|6|470.58|9.845|3.497|5.818|17.314|6.990|
|1|damage|H|600|0|0|1|15.00|6.500|0.673|1.655|9.373|3.421|
|1|damage|G|592|8|0|0|14.80|3.498|0.624|2.206|7.076|3.431|
|2|damage|G|600|0|0|0|15.00|3.932|0.898|0.785|7.693|3.939|
|2|damage|H|600|0|0|2|15.00|6.885|0.639|1.193|9.521|2.172|
|3|damage|H|596|4|0|0|14.90|6.100|0.754|1.138|10.324|4.961|
|3|damage|G|591|9|0|0|14.77|4.163|0.930|0.991|8.099|14.591|

**256 KiB verifier blocks**. Idle control RTT p99 by round: 4.437/7.631/2.628 ms.

|Round|Payload|Arm|Verified|Expired|No slot|Late|MiB/s|Wake|Write|Verify|Age|Control RTT|
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|1|full|H|594|5|1|4|469.75|6.618|2.289|3.418|15.049|4.981|
|1|full|G|600|0|0|0|474.58|3.573|2.223|3.797|8.979|2.231|
|2|full|G|600|0|0|2|474.44|3.629|2.217|3.369|10.947|2.737|
|2|full|H|595|5|0|3|470.61|5.338|2.094|3.442|13.372|4.946|
|3|full|H|600|0|0|1|474.58|4.369|1.768|3.234|10.530|5.280|
|3|full|G|594|6|0|3|469.69|4.858|2.598|3.875|13.856|6.426|
|1|damage|H|600|0|0|3|15.00|8.139|0.547|0.829|11.567|4.354|
|1|damage|G|600|0|0|3|14.96|5.575|0.603|0.998|9.026|4.751|
|2|damage|G|595|5|0|2|14.87|4.367|0.569|0.751|9.941|4.274|
|2|damage|H|600|0|0|2|14.99|7.851|0.437|0.802|10.037|2.334|
|3|damage|H|600|0|0|1|15.00|8.001|0.469|0.831|10.316|3.881|
|3|damage|G|595|5|0|1|14.87|6.765|0.488|1.246|9.226|5.838|

At 64 KiB, 35 of 36 skipped ticks were already expired at wake; only one lacked a slot. Adding slots would not recover those expired ticks. Guest damage had no late receipts but skipped 17 ticks: latency percentiles alone hide lost work. For full frames, host verification p99 was roughly 5–6 ms on either path. The targeted 256 KiB variant makes about one quarter as many ctypes memcmp calls without sampling or changing the checked bytes (64 MiB rather than 16 MiB of cached comparison patterns). Full verification p99 fell to 3.2–3.9 ms in every arm, but expired wakes and late completions persisted. Block sizes were sequential sessions, not randomized pairs; idle RTT also changed. The explicit comparison retains 64 KiB unless overridden; see the default probe profile below. Neither producer demonstrated repeatable zero skips and zero late completions, and neither measures presentation. Next trace scheduler stalls on expired ticks rather than tuning credit depth from completed-frame percentiles.

## Guest hybrid wait

`python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --compare-guest-wait 2000 --verify-block 262144`

Same Intel HVF VM, inode DAX, two slots. Timer-only and 2 ms early absolute timer plus bounded pause loop use identical 60 Hz deadlines, expiry and post-verification credits. Each payload had a one-second warm-up per arm. Rows are in execution order, 600 ticks each. All published frames passed exact validation and both final slot shadows matched. All idle and loaded intervals returned 100/100 echoes; idle control p99 was 6.579/1.617/4.759 ms and idle guest/QEMU CPU seconds were 0.002/1.080, 0.002/1.070, 0.001/1.090. CPU columns are process seconds per ten-second interval, not additive. Wake p99 excludes skipped ticks.

|Payload|Round|Lead µs|Verified|Expired|Late credits|MiB/s|Wake p99 ms|Control p99 ms|Guest CPU s|QEMU CPU s|
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|full|1|0|600|0|1|474.45|4.631|3.653|0.624|2.340|
|full|1|2000|595|5|2|470.52|3.617|2.815|1.197|2.820|
|full|2|2000|600|0|1|474.46|1.893|3.156|1.179|2.870|
|full|2|0|597|3|2|472.18|6.094|4.031|0.657|2.380|
|full|3|0|600|0|3|474.39|5.444|5.440|0.620|2.370|
|full|3|2000|595|5|4|470.42|3.744|2.848|1.157|2.840|
|damage|1|0|600|0|0|15.00|7.426|5.279|0.289|2.020|
|damage|1|2000|596|4|7|14.90|7.824|13.705|0.990|2.470|
|damage|2|2000|597|3|1|14.92|4.256|8.425|0.819|2.540|
|damage|2|0|599|1|0|14.97|4.443|1.881|0.246|2.090|
|damage|3|0|600|0|0|15.00|4.735|2.572|0.604|2.290|
|damage|3|2000|595|5|0|14.87|2.380|4.202|1.299|2.840|

Hybrid reduced median completed-frame wake delay from 1.04–1.22 ms to at most 0.012 ms, but lost 22 ticks to expired wakes versus four for timer-only. Neither arm lost a tick for lack of a slot. Hybrid used more publisher and QEMU CPU in every pair. Keep timer-only as default.

For each late credit, the benchmark compares wake, write, host verification and residual time on that same frame. Of seven late hybrid full frames, wake was largest on three, write on one, verification on one and residual on two. Of eight late hybrid damage frames, residual was largest on seven and wake on one. Residual is guest tick-to-credit duration minus the three measured durations, not a subtraction of cross-machine timestamps. It includes notice delivery, queueing, credit return and scheduling until credit handling. This localizes most late damage receipts outside fill and verification, not specifically to the transport. Next separate notice and credit handling stalls; a larger spin window is not justified by these trials. M1 remains open.

## Publication notice versus credit return

`python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --autonomous --verify-block 262144`

Timer-only, two slots, three 600-tick rounds per payload. Guest stamps publication after the memory fence and credit handling after parsing; host stamps notice after parsing and credit just before sending, after exact verification and shadow update. These endpoints include scheduling and protocol handling, not just device latency. For guest stamps P/G and host stamps H/K respectively, causality bounds host-minus-guest clock offset from above by H−P at P and below by K−G at G. Intersect all such bounds in the round, widening each by 1 ms per second of guest time from its stamp. Results are conditional on that relative clock-rate limit (1000 ppm, not an independently certified HVF guarantee) and no clock steps. No symmetry assumption. Reported intervals are p99 of per-frame lower and upper bounds, not confidence intervals. Analysis is outside the timed interval.

|Payload/round|Verified|Expired/no slot|Late|MiB/s|Notice p99 ms|Credit p99 ms|Independent RTT p99 ms|CPU s host/QEMU/guest|
|---|---:|---:|---:|---:|---:|---:|---:|---|
|full 1|592|7/1|5|468.17|2.160–2.788|1.455–2.150|4.390|0.999/2.440/0.637|
|full 2|600|0/0|1|474.60|1.280–1.963|1.700–2.400|3.149|0.991/2.430/0.594|
|full 3|596|4/0|2|471.33|1.612–2.378|2.367–3.061|3.522|0.998/2.410/0.589|
|damage 1|600|0/0|0|15.00|0.862–1.437|1.034–1.578|2.748|0.356/2.080/0.240|
|damage 2|600|0/0|0|15.00|1.093–1.672|1.344–1.867|2.511|0.361/2.060/0.232|
|damage 3|592|8/0|0|14.80|2.053–2.576|1.106–1.654|5.041|0.351/2.040/0.240|

All exact checks and final shadows passed; 100/100 independent echoes per measured interval. Idle RTT p99 was 4.345/3.521/6.628 ms. Neither leg consistently has the longer tail; the p99 frames need not be the late frames. Of 20 missed ticks, 19 expired before publication. No notice- or credit-path fix justified by these rounds. Keep timer-only, exact verification and existing gates; next investigate scheduling across the missing ticks. No presentation measurement.

## Guest publisher timer slack

`python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --compare-guest-slack --verify-block 262144`

One Intel HVF session, inode DAX, two slots, one-second arm warm-ups. Guest readback confirmed inherited 50,000 ns versus 1 ns; the publisher restored and checked its original setting after each intervention. Both arms waited on the same absolute 60 Hz timerfd schedule with no spin. Timer slack can affect a poll timeout, but this poll normally wakes on timerfd readiness, not its ten-second timeout; reducing slack does not directly advance that expiry.

Each row covers 600 ticks, in execution order. Every published update and both final slot shadows passed exact verification. All idle and loaded intervals returned 100/100 independent echoes. Wake p99 is for published frames only; CPU is host/QEMU/guest process seconds, not additive. Idle control RTT p99: 4.233/9.131/3.446 ms; idle CPU: 0.051/1.140/0.003, 0.051/1.080/0.003, 0.052/1.190/0.008.

|Payload|Round|Slack ns|Verified|Expired|No slot|Late credits|MiB/s|Wake p99 ms|RTT p99 ms|CPU s|
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
|full|1|50000|595|5|0|1|470.60|4.445|6.461|1.006/2.470/0.649|
|full|1|1|594|5|1|5|469.73|5.833|4.610|1.059/2.510/0.720|
|full|2|1|600|0|0|2|474.53|5.731|4.897|1.052/2.500/0.686|
|full|2|50000|594|6|0|4|469.82|4.289|4.366|1.012/2.450/0.639|
|full|3|50000|593|7|0|3|468.99|4.484|4.722|1.041/2.490/0.690|
|full|3|1|594|6|0|5|469.76|5.536|12.195|1.047/2.490/0.689|
|damage|1|50000|600|0|0|1|15.00|3.910|5.454|0.373/2.110/0.261|
|damage|1|1|596|4|0|1|14.90|4.998|2.524|0.365/2.080/0.253|
|damage|2|1|595|5|0|1|14.87|5.555|8.325|0.380/2.090/0.273|
|damage|2|50000|600|0|0|0|15.00|4.237|3.484|0.370/2.100/0.256|
|damage|3|50000|594|6|0|0|14.84|6.093|4.502|0.384/2.090/0.277|
|damage|3|1|595|5|0|0|14.87|5.009|3.932|0.379/2.090/0.282|

The 1 ns arm missed 26 ticks and had 14 late credits versus 24 and 9 at inherited slack. It failed the zero-miss, zero-late gate in every round for both payloads. Keep inherited slack; no fresh confirmation or timing/publishing split is warranted. Next distinguish late timer delivery from a runnable publisher waiting for guest CPU on expired ticks. M1 remains open; no presentation measurement.

## Guest kernel trace of expired ticks

Run `python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --trace-ticks --verify-block 262144`. Add `--trace-output DIR` for raw per-interval tracefs snapshots in an existing empty directory; `--trace-vcpus 2` selects two cores instead of QEMU's default one. These are separate boots, not interleaved arms.

The guest uses the `mono` trace clock and absolute CLOCK_MONOTONIC timerfd targets. Each expired observation records tick index, target, time just before the **last** arm (a credit can cause a rearm), and time after reading the timer. An arm already past the next tick means the deadline had passed before that arm, not necessarily that a new interrupt was late. For kernel attribution, match the publisher-filtered timer start, exact expiry target, timer identity and timerfd callback; match scheduler records by publisher PID. Compare event times to the **next** tick boundary, allowing 1 µs for trace formatting. A wake without a matched switch is not evidence of run-queue delay. Missing or ambiguous evidence stays unknown. Guest callback timing cannot distinguish host descheduling from late virtual interrupt service. Tracing has overhead; trace export runs after interval accounting and final shadow verification.

One-vCPU example: full round 1 tick 90, PID 2094, timer `000000000fe114e8`: target 48539224137 ns, next deadline 48555890803 ns, final arm 48527315418 ns. Trace start/expiry/wakeup/switch were 48527321000 / 48556921000 / 48556942000 / 48557071000 ns; userspace observed 48557091797 ns. The callback was already 1.03 ms past the deadline; the following 0.13 ms runnable wait did not cause that crossing. Across six measured intervals, 28/35 skips were already expired before the final arm, six crossed before callback entry and one remained unknown. None demonstrated a runnable publisher spanning the deadline. This favors testing vCPU topology over raising the publisher's scheduling priority. The Swift suite also ran during baseline damage testing, so between-boot differences are not an isolated estimate of topology cost.

|vCPUs|Payload|Round|Verified|Expired|No slot|Late credits|MiB/s|RTT p99 ms|CPU s (host/QEMU/guest)|
|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
|1|full|1|585|15|0|3|462.61|7.640|0.967/2.360/0.742|
|1|full|2|595|5|0|7|470.44|11.809|1.001/2.370/0.665|
|1|full|3|594|6|0|1|469.85|7.059|0.966/2.380/0.611|
|1|damage|1|600|0|0|2|15.00|2.496|0.360/2.010/0.255|
|1|damage|2|595|5|0|1|14.87|10.805|0.357/2.030/0.301|
|1|damage|3|596|4|0|1|14.90|2.879|0.358/2.040/0.236|
|2|full|1|593|7|0|6|468.70|4.966|1.022/2.710/0.697|
|2|full|2|600|0|0|2|474.44|6.605|1.029/2.840/0.665|
|2|full|3|595|5|0|1|470.44|4.400|1.012/2.810/0.644|
|2|damage|1|600|0|0|0|14.99|2.365|0.403/2.380/0.275|
|2|damage|2|595|5|0|4|14.87|2.379|0.414/2.570/0.288|
|2|damage|3|595|5|0|6|14.87|29.833|0.409/2.310/0.314|

Two-vCPU expired ticks: 18 already-expired-before-arm, 4 expiry-after-deadline. The two-core boot still missed the zero-miss, zero-late gate. Retain the default topology. All intervals passed exact update and both final-shadow checks; all idle and loaded measured intervals returned 100/100 echoes. M1 remains open.

## Default probe profile

```sh
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso"
python3 scripts/sclereid-m1-memory.py "$COMMANDCODE_SCRATCHPAD/std.iso" --autonomous --verify-block 262144 --seconds 10 --rounds 3
```

These commands select the same profile: one HVF vCPU, guest absolute timerfd pacing at 60 Hz, inherited timer slack, no spin or trace, two ext4 DAX slots, streaming full-frame fills and memset damage, separate frame/credit and control ports, and exact 256 KiB verification blocks before credit return. Explicit legacy modes keep their previous settings (including the 64 KiB verifier default); `--raw` restores the original unpaced device control.

The selection is the best observed single full-frame result, not a claim of repeatability. In `pair-262144.log`, the guest-paced arm of round 1 verified 600/600 at 474.58 MiB/s with zero expired ticks, unavailable slots or late credits. Tick-to-credit p50/p95/p99 was 4.012/6.552/8.979 ms; independent control RTT p99 was 2.231 ms (100/100 echoes). Sequence, payload bytes and both final shadows passed. The other full rounds had 2 and 9 misses (skips plus late credits); damage rounds had 3/7/6. The 64 KiB guest arm also had one clean full round, but its full-frame p99 was 11.140 ms and the other rounds missed 10 and 11. The same 256 KiB timer-only profile in the hybrid comparison missed 1/5/3 full deadlines versus 7/1/9 with spin. These are guest credit deadlines, not presentation or the host arm's verification deadlines. The observed variance does not establish hardware noise as the cause. This is a probe default only: M1 and the production frame choice remain open; M2 and G1 can proceed independently.

Fresh no-mode run (`default-profile.log`, Intel i5-3210M, QEMU 11.1.2/HVF): inode DAX confirmed, MAP_SYNC unsupported. Swift ran after the probe. Every interval returned 100/100 control echoes; sequence, full-byte and both final-shadow checks passed. The selection run's zero-miss full round did not repeat.

| Payload | Verified out of 600 (rounds 1/2/3) | Expired | No slot | Late credits | MiB/s |
|---|---|---|---|---|---|
| Full | 595/595/600 | 4/5/0 | 1/0/0 | 11/1/1 | 470.58/470.60/474.55 |
| Damage | 600/595/600 | 0/5/0 | 0/0/0 | 1/3/1 | 14.99/14.87/15.00 |
