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

Run `python3 scripts/sclereid-m1-memory.py /path/to/alpine-virt-3.22.2-x86_64.iso` (same ISO URL and SHA-256 as `scripts/sclereid-m0.py`; script checks the digest). Requires Python 3, bsdtar and HVF QEMU. No Colima, guest networking, host folder export, `/dev/mem`, or external daemon. A fresh private temporary directory holds extracted boot files and a disposable region; the host mapping is read-only. One pmem device only; no arbitrary target-device parameter. QEMU is killed and reaped before temporary files are removed.

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
