# M1: Alpine → host over virtserialport

**Latest local i9: 158.52–164.89 MiB/s** verified full-frame throughput over three measured rounds (Core i9-9980HK, macOS 14.8.9, QEMU 11.1.3/HVF; see [local M1 acceptance](m1-memory.md#local-m1-acceptance)). The earlier i5 run reached 11.34–18.94 MiB/s. Both fell short of the 474.61 MiB/s byte budget for raw 1080p60 BGRA.

On the i5, 256×256 damage tiles reached 25.61–28.59 MiB/s (60 tiles/s requires 15 MiB/s), but p99 host completion intervals exceeded 45 ms in every measured round.

## Reproduce

```sh
python3 docs/sclereid/m1/sclereid-m1-serial.py --probe-only
python3 docs/sclereid/m1/sclereid-m1-serial.py
```

From the repository root on an Intel Mac with HVF, `qemu-system-x86_64`, `curl`, and `bsdtar`. Both commands accept `--iso PATH` to skip the download and check the pinned Alpine virt 3.22.2 x86_64 digest. The probe verifies a 24-byte guest-to-host nonce; the benchmark repeats the check before timing.

## Earlier i5 results

Intel i5-3210M, QEMU 11.1.2/HVF. All expected frames and replies verified. Round 0 is warmup; rounds 1–3 are measured.

```text
PASS guest->host nonce
idle 0 0.802/3.245/5.325 hostCPU_s=0.018
idle 1 0.684/2.923/4.509 hostCPU_s=0.017
idle 2 0.749/3.141/6.360 hostCPU_s=0.018
idle 3 0.872/4.391/7.031 hostCPU_s=0.017
loaded 0 2.164/10.587/31.255 n=3150 bulk=10.15 hostCPU_s=1.498
loaded 1 1.868/11.909/38.334 n=4556 bulk=6.18 hostCPU_s=1.715
loaded 2 1.467/5.149/13.671 n=5466 bulk=9.39 hostCPU_s=1.865
loaded 3 1.558/11.863/72.489 n=4605 bulk=6.05 hostCPU_s=1.723
full 0 10.67 684.370/1251.491/1756.922 hostCPU_s=2.297
full 1 11.34 588.267/1386.790/1438.530 hostCPU_s=2.450
full 2 16.78 479.386/590.333/808.678 hostCPU_s=2.612
full 3 18.94 352.104/701.728/800.978 hostCPU_s=2.635
damage 0 23.95 8.845/21.019/36.805 hostCPU_s=0.261
damage 1 25.61 7.252/15.925/51.981 hostCPU_s=0.264
damage 2 26.41 5.961/26.490/45.823 hostCPU_s=0.240
damage 3 28.59 6.118/16.387/66.082 hostCPU_s=0.229
```

## Setup and measurement

The VM boots directly from the kernel/initramfs with the Alpine ISO, using q35/HVF, host CPU, one vCPU, 512 MiB RAM, and no NIC or display. The legacy console handles login and setup. Virtio-serial port 1 carries probe/echo and port 2 carries bulk data; each uses a separate Unix stream with a host listener created before boot.

Full rounds send 32 × 8,294,400 bytes (1920×1080×4); damage rounds send 128 × 262,144 bytes (256×256×4). Guest `cat` sends alternating prebuilt buffers without pacing; the host checks every byte and eight-byte sequence header. Frame rows report payload MiB/s (excluding headers), then host verification completion intervals. The first interval starts at reception start.

Idle RTT uses 200 sequential numbered nine-byte request/echo pairs. Loaded RTT spans the bulk job (16 full frames on port 2, including startup and drain) and also reports echo count `n` and concurrent throughput `bulk` in MiB/s. RTT includes guest shell scheduling. All timing triples are nearest-rank p50/p95/p99 in milliseconds on the host monotonic clock; full-frame p99 is the maximum of 32 samples. `hostCPU_s` covers the Python host process, including its receiver thread.
