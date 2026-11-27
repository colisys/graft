# M1: Alpine → host over virtserialport

**Full frames missed the 1080p60 target:** 11.34–18.94 MiB/s verified, versus 474.61 MiB/s required for raw BGRA. A synthetic 256×256 damage rectangle reached 25.61–28.59 MiB/s (60/s requires 15 MiB/s), but its p99 host completion interval exceeded 45 ms in every measured round. This supports testing damage aggregation, not claiming smooth presentation.

## Reproduce

From the repository root on the M0 Intel macOS/HVF machine (Python 3, curl, bsdtar, QEMU 11.1.2):

```sh
qemu-system-x86_64 -machine q35 -chardev help
qemu-system-x86_64 -device virtio-serial-pci,help
qemu-system-x86_64 -device virtserialport,help
python3 scripts/sclereid-m1-serial.py --probe-only
python3 scripts/sclereid-m1-serial.py
```

Both commands accept `--iso PATH` instead of downloading; both enforce M0's pinned Alpine virt 3.22.2 x86_64 digest. Local help confirmed socket chardev and port `nr`, `name`, `chardev`. The VM uses the M0 direct kernel/initramfs/CD boot, q35/HVF, host CPU, one default vCPU, 512 MiB, no NIC or display. The legacy console handles login and job setup only. A PCI virtio-serial controller has numbered ports 1 (probe/echo) and 2 (bulk), each backed by a separate Unix stream. Host listeners are created before spawn. Only the spawned VM is terminated (five-second grace then kill); boot files and sockets are temporary. No Colima.

## Measurement and limits

The probe-only boot passed first: the guest wrote a fresh known 24-byte nonce, matched byte-for-byte on the host port. A second boot repeated that check before timing. Round 0 is warm-up; 1–3 are measured. Each idle RTT round has 200 sequential numbered nine-byte request/echo pairs. Loaded RTT overlaps the whole host bulk job (including startup/drain): 16 full frames on the sibling port. RTT includes guest shell scheduling; it is not a device-only latency.

Full uses 32 × 8,294,400 bytes (1920×1080×4); damage uses 128 × 262,144 bytes (256×256×4). Guest `cat` streams alternating prebuilt constant-byte buffers without pacing; host checks every byte and every eight-byte sequence header. All expected frames and replies verified; no missing or out-of-order frame observed. Rates exclude headers. Intervals are between host verification completions (first from start of reception); slash-separated values are nearest-rank p50/p95/p99 milliseconds, all on one host monotonic clock. Full-frame p99 with 32 samples is the maximum. CPU seconds cover the Python host process including its receiver thread, not QEMU or guest CPU. This measures a copying shell/Python implementation, not peak device bandwidth, real application damage, or input-to-display latency.

## Recorded output

RTT rows: latency distribution; loaded also reports echo count and concurrent MiB/s. Frame rows: effective MiB/s then interval distribution.

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
