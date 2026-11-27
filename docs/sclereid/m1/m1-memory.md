# M1: confined shared-region test on Intel macOS

**Local transport decision:** Use ext4 DAX over dedicated file-backed virtio-pmem for M2 frame payloads. Separate virtio-serial ports carry frame notices/credits and control. Two i9 boots delivered 474.51–474.58 MiB/s for 1080p BGRA and 15.00 MiB/s for packed 256×256 damage. For window submission, see [M2](../m2/m2-smoke.md).

## Default probe profile

From the repository root, use Python 3, `bsdtar`, Zig (tested 0.16.0), and `qemu-system-x86_64` with HVF and `virtio-pmem-pci` on PATH. Set `iso` to your local copy of the pinned standard image:

```sh
iso=/path/to/alpine-standard-3.22.2-x86_64.iso
python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso"
# Equivalent explicit profile
python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso" --autonomous --verify-block 262144 --seconds 10 --rounds 3
```

| Pinned ISO | Kernel | SHA-256 (checked by the script) |
|---|---|---|
| [Alpine standard 3.22.2 x86_64](https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-standard-3.22.2-x86_64.iso) | `6.12.51-0-lts` | `f6a265f0696d328c8f87814a0d6bfa362d1434e500cb80a48796b1c9d204cee0` |
| [Alpine virt 3.22.2 x86_64](https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-virt-3.22.2-x86_64.iso) (raw and filesystem controls) | `6.12.51-0-virt` | `b6c45d69829b1b0416ada798353805099d57b8bef9093b85a8319fe5373595d5` |

- **Confinement:** q35/HVF only (no TCG fallback), one vCPU, 512 MiB private guest RAM, no NIC. Only the disposable 32 MiB pmem region is file-backed and mapped read-only by the host. No host directory export, arbitrary device target, `/dev/mem`, Colima or external daemon. The static x86_64 Linux helper is passed through read-only QEMU fw_cfg. QEMU is killed and reaped before scratch cleanup; `COMMANDCODE_SCRATCHPAD` optionally selects the temporary-directory parent.
- **Mapping:** ext4 `dax=always` on the dedicated pmem device; confirm `STATX_ATTR_DAX` on the actual inode (`DAX=1 mask=1`). `MAP_SYNC` was unsupported; the timed path uses `MAP_SHARED` without `msync`. Discover two distinct contiguous slots by their complete calibration patterns rather than hard-coding filesystem offsets.
- **Ownership and pacing:** Guest absolute `CLOCK_MONOTONIC` timerfd ticks at `origin + floor(i × 10⁹ / 60)` ns, inherited timer slack, no spin or tracing. The guest uses SSE2 streaming stores for full frames and memset for packed damage. It fences stores before publishing; the host checks ordered sequence, fresh tag and every payload byte in place before returning the matching slot credit. Both endpoints enforce reuse; the host audits both final slot shadows. Independent control sends 10 echoes/s. Explicit legacy modes default to 64 KiB comparison blocks; the no-mode profile uses 256 KiB. `--raw` selects the unpaced block/flush control.

## Local M1 acceptance

Two separate boots on Intel Core i9-9980HK, macOS 14.8.9 (23J631), QEMU 11.1.3/HVF and Zig 0.16.0 used the default profile. Both confirmed inode DAX and unsupported `MAP_SYNC`. Each boot ran three 10-second measured intervals per load (including idle). **Every loaded round verified 600/600 ordered updates and both final shadows, with zero expired ticks, unavailable slots or late credits. Every interval returned 100/100 control echoes.**

| Payload | Bytes/update | Verified bytes/round | Nominal 60 Hz rate |
|---|---:|---:|---:|
| 1920×1080 BGRA full frame | 8,294,400 | 4,976,640,000 | 474.609 MiB/s |
| Packed 256×256 BGRA damage (not a strided surface) | 262,144 | 157,286,400 | 15 MiB/s |

**Measurement:** Verify payload bytes, sequence, slot ownership and final slot contents. For the 60 Hz benchmark, count skipped ticks and credits received after the next tick as separate performance metrics, not pass/fail thresholds. Tick-to-credit uses the guest monotonic clock and ends at credit receipt. Throughput divides verified bytes by host elapsed time including drain. Latency triples are p50/p95/p99 in ms; CPU columns give host Python/QEMU/guest helper process seconds.

| Boot | Load | Round | MiB/s | Tick-to-credit ms | Control RTT ms | CPU s |
|---:|---|---:|---:|---|---|---|
| 1 | idle | 1 | — | — | 0.629/1.026/1.102 | 0.046/0.250/0.004 |
| 1 | idle | 2 | — | — | 0.543/0.954/1.038 | 0.047/0.240/0.003 |
| 1 | idle | 3 | — | — | 0.658/1.113/1.313 | 0.049/0.260/0.004 |
| 1 | full | 1 | 474.57 | 3.335/5.936/6.941 | 0.515/1.480/1.906 | 0.852/1.520/0.421 |
| 1 | full | 2 | 474.51 | 3.255/4.088/4.367 | 0.532/1.314/1.700 | 0.918/1.820/0.451 |
| 1 | full | 3 | 474.55 | 3.180/4.110/4.440 | 0.530/1.575/1.914 | 0.910/1.770/0.437 |
| 1 | damage | 1 | 15.00 | 2.082/3.187/3.581 | 0.513/1.115/1.615 | 0.375/1.770/0.291 |
| 1 | damage | 2 | 15.00 | 2.241/3.246/3.794 | 0.630/1.525/1.698 | 0.405/2.030/0.330 |
| 1 | damage | 3 | 15.00 | 2.271/3.371/3.738 | 0.595/1.242/1.585 | 0.409/2.010/0.324 |
| 2 | idle | 1 | — | — | 0.859/1.142/1.436 | 0.055/0.340/0.005 |
| 2 | idle | 2 | — | — | 0.849/1.099/1.182 | 0.054/0.320/0.005 |
| 2 | idle | 3 | — | — | 0.851/1.128/1.196 | 0.056/0.320/0.006 |
| 2 | full | 1 | 474.57 | 3.732/6.580/7.357 | 0.679/1.611/1.926 | 0.956/1.760/0.493 |
| 2 | full | 2 | 474.57 | 3.204/4.000/4.378 | 0.510/1.229/1.773 | 0.929/1.700/0.422 |
| 2 | full | 3 | 474.58 | 3.218/4.122/4.448 | 0.549/1.169/1.828 | 0.923/1.690/0.421 |
| 2 | damage | 1 | 15.00 | 2.227/3.230/3.934 | 0.689/1.301/1.735 | 0.407/1.930/0.315 |
| 2 | damage | 2 | 15.00 | 2.217/3.377/3.701 | 0.673/1.669/2.341 | 0.432/1.810/0.296 |
| 2 | damage | 3 | 15.00 | 2.293/3.331/3.734 | 0.621/1.506/1.813 | 0.428/1.800/0.294 |

Same-host controls (`python3 docs/sclereid/m1/sclereid-m1-serial.py` and `python3 docs/sclereid/m1/sclereid-m1-net.py`) verified payloads but reached 158.52–164.89 and 63.45–66.34 MiB/s respectively for full frames over three rounds. Their copy and timing paths differ; these are not device bandwidth limits.

## Historical transport runs

Unless noted, these runs used Intel i5-3210M, macOS 13.7.8, MacPorts QEMU 11.1.2/q35/HVF and the same scratch-region confinement. Use the `iso` variable above for the pinned standard image and set `virt_iso` to the local pinned virt image. Where only flags are shown, append them to `python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso"`. Paced experiments use three 10-second rounds (600 ticks each) per load unless noted. A skip is an unissued or unpublished tick; a late completion excludes skips. `expired_wake` means the deadline passed before the issuer could start; `no_slot` counts unexpired attempts without a free slot. Host-paced age ends at host verification; guest-paced age ends at guest credit receipt and includes the return leg. Stage percentiles cover completed work and are not additive.

### Options and evidence

| Transport | Local result and requirements |
|---|---|
| [virtio-pmem](https://www.qemu.org/docs/master/system/devices/virtio-pmem.html) | `memory-backend-file,share=on` and `virtio-pmem-pci,memdev=r` worked with ordinary temporary storage and Linux `virtio_pmem`/`nd_pmem`. Flush completion does not imply power-failure durability. |
| [NVDIMM](https://www.qemu.org/docs/master/system/devices/nvdimm.html) | `-machine q35,accel=hvf,nvdimm=on -m 512M,slots=2,maxmem=1G` booted with NVDIMM and virtio-pmem on separate 32 MiB files. Two devices, buses, regions and namespaces enumerated; neither mapping order nor NVDIMM data transfer was verified. Do not set `pmem=on` for ordinary files to simulate persistence. |
| [ivshmem](https://www.qemu.org/docs/master/system/devices/ivshmem.html) | Neither `ivshmem-plain` nor `ivshmem-doorbell` appeared in `-device help`; a shared file does not supply the PCI endpoint. |
| [virtiofs DAX](https://docs.kernel.org/filesystems/virtiofs.html) | No `vhost-user-fs-pci` or `virtiofsd`. DAX needs a frontend window, backend mapping support and guest mount/inode support. Conventional vhost-user shares guest memory with the backend; do not share main RAM to enable it. |

### Reproduce and interpret

```sh
python3 docs/sclereid/m1/sclereid-m1-memory.py "$virt_iso" --raw
```

One warm-up plus three rounds of ten: all 31 full frames verified. The guest alternates tmpfs patterns, completes `dd conv=fsync` to `/dev/pmem0` before its serial reply, and waits for the next grant. Host checks the entire mapped prefix. Including control, copy, flush and verification, rounds delivered 32.16/33.51/35.61 MiB/s, median 226.99/228.22/220.51 ms and max 414.33/352.11/267.15 ms. This rules out the measured block/flush path for full frames at 60 Hz.

### Follow-up: ext4 file mmap on the dedicated virtio-pmem device

```sh
python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso" --fs
python3 docs/sclereid/m1/sclereid-m1-memory.py "$virt_iso" --fs
```

Load `virtio_pmem`, `nd_pmem`, `ext4`; install e2fsprogs offline from the ISO. The probe formats only scratch `/dev/pmem0` (`mkfs.ext4 -F -b 4096`). Standard has `CONFIG_ZONE_DEVICE=y` and `CONFIG_FS_DAX=y` and mounted `dax=always`; virt has `CONFIG_DAX=y` but lacked both options, rejected `dax=always` with `Invalid argument`, and reported `DAX=0 mask=1` on fallback. Neither supported `MAP_SYNC`. The host found the nonce-tagged warm-up frame at byte 6,475,776 in both fresh filesystems and verified every byte there before reuse; the offset is not an ABI.

| Guest / `MAP_SHARED` mode | Verified incl. warm-up | Median / max ms | MiB/s |
|---|---:|---:|---:|
| standard DAX / `MS_SYNC` | 11 | 23.58 / 29.98 | 324.82 |
| standard DAX / no `msync` | 11 | 11.14 / 14.39 | 679.12 |
| virt buffered / `MS_SYNC` | 11 | 22.10 / 23.77 | 356.47 |
| virt buffered / no `msync` | 0 | — | — |

The first buffered unsynced reply (`seq=11`) failed the byte check. The DAX unsynced burst fit the frame budget, but the paced test below did not.

### Follow-up: paced DAX ownership and control RTT

`python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso" --paced --seconds 10 --rounds 3`

Single slot, 60 warm-up operations per round, full frames or packed damage cycling through bounded offsets. A serial grant starts each write; the guest fences and ACKs, and the host verifies the nonce and payload before reuse. The loaded ping queues behind every sixth scheduled write on the same connection (excludes host verification); idle pings have no writer.

| Load | MiB/s | Skips / round | Late / round | Control RTT p99 ms |
|---|---:|---:|---:|---:|
| Idle | — | 0–5 | 1–4 | 6.53–8.73 |
| Full | 421.13–426.22 | 61–67 | 475–506 | 20.73–36.75 |
| Damage | 14.77–15.00 | 0–9 | 6–14 | 13.36–39.23 |

### Two-slot DAX pipeline and independent control

`python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso" --ring --seconds 10 --rounds 3`

One second of warm-up per mode. The host can reserve a second slot before the first ACK is verified; `overlap` counts concurrent reservations, not concurrent writes. Separate 10 Hz nonce echoes measure host send-to-reply RTT. Full frames reached 448.93–452.08 MiB/s with 28–32 skips and 564–570 late per round. Damage reached 14.87–14.90 MiB/s with 4–5 skips and 10–20 late. Control p99 was 2.34–2.81 ms idle, 13.08–17.80 ms full, and 8.90–15.69 ms damage; the queued single-slot ping uses a different endpoint.

### Ring latency breakdown

Compare `--ring --copy-verify` with `--ring` in fresh VMs, copy first. Native verification checks bytes in place against reusable uniform blocks on a second read-only mapping, with a compact full-slot expectation for the final audit. It reduced full-frame preparation/verification medians from 3.53–3.69/4.66–4.78 ms to ~0.06/1.54–1.58 ms. Full frames reached 466.69–471.43 MiB/s (4–10 skips, 94–126 late); damage reached 14.82–15.00 MiB/s (0–7 skips, 2–12 late).

For ring timing, wake is tick to issuer wake, prep ends just before grant send, write is the guest elapsed fill/tag/fence time, and verify is parsed ACK through byte check and shadow update. `remaining` is host send-to-parsed-ACK duration minus guest write duration: dispatch, queueing, transport and scheduling, not one-way latency.

### Dedicated grant and ACK port

Compare `--ring --frame-port` with `--ring` in fresh VMs, dedicated port first. Port 1 remains independent control; port 2 replaces the emulated console for grants/ACKs. The full-frame median send/ACK remainder fell from 5.68–5.83 to 0.77–0.78 ms; late counts fell from 253–269 to 16–25 per round (damage: 16–34 to 2–3). Dedicated-port full load still skipped 0–12 ticks and control p99 reached 20.92 ms.

### Host tick wait experiment

Compare `--ring --frame-port` with the same command plus `--mach-wait`, baseline first, separate VMs. The intervention changes only the issuer's wait to absolute Mach time, without spinning or granting early. Baseline full skips were mostly no-slot (29/33); damage skips were mostly expired wakes (6/7). Full late counts were 202/38/6 at baseline versus 21/30/28 with Mach wait; damage was 1/0/6 versus 0/3/0. Wake latency did not consistently improve; keep the default host wait.

### Guest streaming fill

Use `--ring --frame-port --compare-stream`. Discovery writes already touch every slot page. The paired full-frame arms compare memset with aligned SSE2 non-temporal stores, ordered before the tag store and publication fence. Write p99 fell from 8.994–11.884 to 1.992–2.427 ms, but skips rose from 5 to 14 total and round 3 tick-to-verified p99 rose from 15.604 to 26.287 ms. Streaming is used by the current guest-paced default, not by plain `--ring`.

### Host issuer QoS

Use `--ring --frame-port --compare-qos`. Both full-frame arms stream; only host grant issuer pthread QoS changes. Default skipped 6/5/0 with 17/5/8 late; user-interactive skipped 0/0/7 with 11/2/10 late. Interactive QoS regressed in round 3 and stays opt-in.

### Guest autonomous publication

Use `--autonomous` alone for the original 64 KiB verifier run. Full frames verified 589/600/596 with 11/0/4 skips and 12/6/3 late credits. Damage verified 600/600/594 with 0/0/6 skips and 0/1/0 late credits. All loaded rounds returned 100/100 control echoes. Compare counts with host-paced runs, not their different latency endpoints.

### Same-session producer comparison

```sh
for block in 65536 262144; do
  python3 docs/sclereid/m1/sclereid-m1-memory.py "$iso" --compare-producers --verify-block "$block" --seconds 10 --rounds 3 || exit 1
done
```

Host and guest pacing alternate within each VM with the same slots, ports, fills and exact verifier; block sizes ran in separate VMs. At 64 KiB, 35/36 skips were expired wakes. The 256 KiB verifier uses about one quarter as many `memcmp` calls for full frames, with 64 rather than 16 MiB of cached comparison patterns. Full verification p99 fell from ~5–6 to 3.2–3.9 ms. The 256 KiB guest arm's one clean full round (474.58 MiB/s; tick-to-credit 4.012/6.552/8.979 ms; control p99 2.231 ms) selected the default profile. Its other full rounds missed 2/9 ticks or credits; damage missed 3/7/6. The 64 KiB guest arm also had one clean full round (age p99 11.140 ms).

A fresh no-mode run on the i5 did not reproduce the clean full round:

| Load | Verified / 600 | Expired | No slot | Late credits | MiB/s (rounds 1/2/3) |
|---|---|---|---|---|---|
| Full | 595/595/600 | 4/5/0 | 1/0/0 | 11/1/1 | 470.58/470.60/474.55 |
| Damage | 600/595/600 | 0/5/0 | 0/0/0 | 1/3/1 | 14.99/14.87/15.00 |

### Guest hybrid wait

Use `--compare-guest-wait 2000 --verify-block 262144` to pair timer-only with a 2 ms early timer and bounded pause loop. Median completed-frame wake fell from 1.04–1.22 ms to ≤0.012 ms, but expired ticks rose from 4 to 22, without any no-slot skips. Guest and QEMU CPU increased in every pair. For 7/8 late hybrid damage credits, the largest stage was the residual (guest age minus wake, write and host verification durations), which includes both notice and credit handling. Keep timer-only.

### Publication notice versus credit return

Use `--autonomous --verify-block 262144`. The probe stamps guest publication after the fence and credit receipt after parsing; host stamps notice after parsing and credit before send, after verification. Causality bounds host-minus-guest offset above by host notice minus guest publication, and below by host credit minus guest receipt. Bounds are intersected across the round with widening of 1 ms/s from each stamp (conditional on ≤1000 ppm relative drift and no clock steps). Reported p99 intervals are percentiles of per-frame bounds, not confidence intervals or device-only latency. Neither leg consistently had the longer tail; 19 of 20 skips were expired wakes.

### Guest publisher timer slack

Use `--compare-guest-slack --verify-block 262144`. The guest checks inherited 50,000 ns versus 1 ns slack and restores the original setting. The absolute timerfd schedule is unchanged; poll normally wakes on timerfd readiness, not its timeout. The 1 ns arm had 26 skips and 14 late credits versus 24 and 9 at inherited slack. Keep inherited slack.

### Guest kernel trace of expired ticks

Use `--trace-ticks --verify-block 262144`; add `--trace-output DIR` for snapshots in an existing empty directory, or `--trace-vcpus 2` for a separate two-core boot. Trace uses `mono`; match the final timer arm (credits may rearm it), target, timer identity and callback, plus scheduler events by publisher PID. Compare with the **next** tick boundary, allowing 1 µs for trace formatting. A wake without a matching switch does not establish runnable delay. Guest callbacks cannot distinguish host descheduling from virtual interrupt delay; tracing adds overhead and export runs after accounting and shadow verification.

| vCPUs | Expired ticks | Already expired at final arm | Callback crossed deadline | Unknown | Late credits (full; damage) |
|---:|---:|---:|---:|---:|---|
| 1 | 35 | 28 | 6 | 1 | 3/7/1; 2/1/1 |
| 2 | 22 | 18 | 4 | 0 | 6/2/1; 0/4/6 |

No one-vCPU skip showed a runnable publisher spanning the deadline. The Swift suite overlapped one-vCPU damage testing, and the two-vCPU boot still missed deadlines. Keep one vCPU as the default.

## Follow-up: Alpine HVF H.264 encode → virtio-pmem → macOS decode

This batch control encodes in the guest (two vCPUs, 1 GiB), stages the stream in tmpfs, then publishes the whole clip through the pmem block/flush path. The host verifies a fresh nonce and SHA-256 before software decode to a null sink and checks all 120 frames. Two synthetic 1080p60 YUV420p clips (static desktop and `testsrc2` motion), x264 ultrafast/zerolatency, two threads, GOP 60, no scene cuts, CRF 18/28. One warm-up and three timed runs per row. These are clip wall times divided by 120; for incremental H.264 over TCP, see the [live control](m1-live-h264.md). No live AV1 comparison was run.

### Reproduce

Use Python 3.11+, `bsdtar`, the pinned standard ISO and the following FFmpeg binaries in scratch; no install is needed. The harness copies the guest binary from a read-only virtio-blk device to guest tmpfs and runs it there.

- Host FFmpeg 7.1: [imageio-ffmpeg 0.6.0 Intel macOS wheel](https://files.pythonhosted.org/packages/da/58/87ef68ac83f4c7690961bce288fd8e382bc5f1513860fc7f90a9c1c1c6bf/imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl), SHA-256 `9d2baaf867088508d4a3458e61eeb30e945c4ad8016025545f66c4b5aaef0a61`. Extract with `unzip -p host.whl 'imageio_ffmpeg/binaries/ffmpeg-*' > host-ffmpeg` and `chmod +x host-ffmpeg`.
- Guest FFmpeg 7.0.2: [static Linux amd64 archive](https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz), SHA-256 `abda8d77ce8309141f83ab8edf0596834087c52467f6badf376a6a2a4c87cf67`. Extract with `tar -xOf linux.tar.xz ffmpeg-7.0.2-amd64-static/ffmpeg > linux-ffmpeg`; binary SHA-256 `e7e7fb30477f717e6f55f9180a70386c62677ef8a4d4d1a5d948f4098aa3eb99`. Use a matching cached archive if the rolling URL changes.

```sh
python3 docs/sclereid/m1/sclereid-m1-encoder.py --ffmpeg ./host-ffmpeg \
  --guest "$iso" ./linux-ffmpeg --av1 libaom-av1 --av1-decoder libaom-av1
# Separate host-only control
python3 docs/sclereid/m1/sclereid-m1-encoder.py --ffmpeg ./host-ffmpeg \
  --av1 libaom-av1 --av1-decoder libaom-av1
```

| Clip / CRF | Guest encode / publish / decode ms/frame | Guest total ms/frame | Host total ms/frame | Mbps | PSNR dB / SSIM |
|---|---|---:|---:|---:|---|
| Desktop 18 | 10.43 / 0.37 / 2.29 | 13.06 | 9.93 | 0.142 | 68.39 / 0.999892 |
| Desktop 28 | 10.75 / 0.38 / 2.27 | 13.40 | 9.07 | 0.094 | 59.28 / 0.999402 |
| Motion 18 | 12.66 / 4.32 / 3.65 | 21.16 | 13.04 | 36.041 | 55.12 / 0.999351 |
| Motion 28 | 12.03 / 2.51 / 3.20 | 18.09 | 16.59 | 19.209 | 45.78 / 0.995912 |

Total is the median of paired stage sums, not the sum of stage medians. Desktop fit the amortized budget; motion did not. Quality scores compare against the source YUV, excluding RGB conversion. Host-only uses a different build and scratch filesystem, so the timing difference is not an isolated HVF cost.

## AV1 versus H.264: same guest inputs, host software decode

The pinned Linux FFmpeg lacks SVT-AV1 and the macOS build lacks dav1d. Use standalone SVT 2.3.0 from a second read-only disk and host `dav1d` 1.5.4 on PATH. Supply a trusted archive; the commands below assume the extracted FFmpeg binaries are in the working directory.

```sh
(
  set -e
  repo=$PWD
  cd "${COMMANDCODE_SCRATCHPAD:?set an existing scratch directory}"
  mkdir svt
  for pkg in svt-av1 libSvtAv1Enc; do
    curl -fLsS "https://dl-cdn.alpinelinux.org/alpine/v3.22/community/x86_64/$pkg-2.3.0-r0.apk" -o "$pkg.apk"
  done
  printf '%s\n' \
    'b13a8e1520e563cf88b781eb799b6f0a29bbceb010e7a83ee616171b92c15e4c  svt-av1.apk' \
    '7083d492af650d7c04b8bdd7970b71e649e2d0fe48d4d13c4fd7e1fbc4e71086  libSvtAv1Enc.apk' | shasum -a 256 -c -
  for pkg in svt-av1 libSvtAv1Enc; do bsdtar -xf "$pkg.apk" -C svt; done
  svt_tar=$PWD/svt.tar
  tar -cf "$svt_tar" -C svt usr
  cd "$repo"
  python3 docs/sclereid/m1/sclereid-m1-encoder.py --ffmpeg ./host-ffmpeg \
    --guest "$iso" ./linux-ffmpeg --guest-svt-tar "$svt_tar" \
    --av1-decoder dav1d --av1-crfs 20 32 --repeats 2
  # For the motion quality control, replace the CRF options with:
  # --av1-crfs 15 --clips motion --av1-only
)
```

Both arms used 3 GiB (SVT exited 137 at 1 GiB), two vCPUs, a 512 MiB source/output tmpfs, one warm-up and two timed clips per point. SVT preset 12 mapped to 11, with `--lp 2 --keyint 60` and default prediction structure. Decode used two threads; AV1 byte counts include IVF framing. Selected comparisons:

| Clip | Codec / CRF | Bytes | Encode / publish / decode ms/frame | PSNR dB / SSIM |
|---|---|---:|---|---|
| Desktop | x264 18 | 35,402 | 15.92 / 0.45 / 3.63 | 68.386609 / 0.999892 |
| Desktop | SVT 32 | 8,104 | 38.45 / 0.40 / 3.45 | 70.865741 / 0.999954 |
| Motion | x264 28 | 4,802,327 | 17.13 / 3.38 / 4.08 | 45.784925 / 0.995912 |
| Motion | SVT 20 | 7,299,893 | 69.09 / 5.18 / 8.46 | 43.305144 / 0.995138 |
| Motion | SVT 15 | 8,612,604 | 70.50 / 5.01 / 8.92 | 44.575983 / 0.996144 |

SVT 32 saved 77.1% of desktop bytes at higher measured quality. On motion, SVT 15 approached x264 28 in SSIM but lost 1.21 dB PSNR and used 34.450 vs 19.209 Mbps. Even the fastest SVT encode exceeded the 16.67 ms/frame budget on this host.
