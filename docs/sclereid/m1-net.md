# M1 control: Alpine guest → macOS over virtio-net TCP

**Latest local i9: 63.45–66.34 MiB/s** verified full-frame throughput over three measured rounds (Core i9-9980HK, macOS 14.8.9, QEMU 11.1.3/HVF; see [local M1 acceptance](m1-memory.md#local-m1-acceptance)). The earlier i5 run reached 6.70–14.35 MiB/s. Both fell short of the 474.61 MiB/s byte budget for raw 1080p60; i5 damage throughput also fell short of the 15 MiB/s needed for 60 tiles/s.

## Reproduce

```sh
python3 scripts/sclereid-m1-net.py
```

From the repository root on an Intel Mac with HVF, `qemu-system-x86_64`, `curl`, and `bsdtar`. Pass a local Alpine virt 3.22.2 x86_64 ISO as the sole argument to skip the download. The script checks the pinned SHA-256 before boot.

## Earlier i5 results

Intel i5-3210M, macOS 13.7.8, QEMU 11.1.2/HVF. All transfers passed length and SHA-256 checks.

| Round | Full MiB/s | Damage MiB/s | Echo p50 ms | p95 ms | p99 ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 14.35 | 13.66 | 0.667 | 2.162 | 3.763 |
| 2 | 11.77 | 5.49 | 0.869 | 2.187 | 6.050 |
| 3 | 6.70 | 3.33 | 1.183 | 9.769 | 17.414 |

## Setup and measurement

QEMU uses `q35,accel=hvf`, host CPU, one vCPU, 512 MiB RAM, and `virtio-net-pci`. Restricted user networking disables IPv6 and forwards one TCP port on IPv4 loopback. The host opens connections; bulk bytes flow guest to host. Serial carries setup and reference hashes.

Each bulk connection sends eight copies of a 1920×1080×4-byte frame or 64 copies of a 256×256×4-byte damage tile. The host checks length and SHA-256 once per payload size before timing and again for every measured transfer. Timing runs from the one-byte ready marker to the last exact-length read and excludes hashing; the sender may already have buffered bytes. Rates include the guest shell/`cat`/BusyBox `nc`, QEMU user networking, and host Python copies.

Idle echo RTT uses a separate established connection with host `TCP_NODELAY`, one outstanding one-byte request, one warmup, and 100 checked replies per round.
