# M1 control: Alpine guest → macOS over virtio-net TCP

This TCP path did not meet 1080p60 full-frame bandwidth on the test host. A 256×256 damage update was much cheaper, but also fell short of 60 updates/s in the run tabulated below.

## Reproduce

Run `python3 scripts/sclereid-m1-net.py` on an Intel Mac with HVF, `qemu-system-x86_64`, `curl` and `bsdtar`. Alternatively pass the local Alpine virt 3.22.2 x86_64 ISO as the sole argument. The script checks its pinned SHA-256 before boot. No guest packages, Colima, root privileges or existing VM are needed.

Option checks: the installed x86 QEMU's `-accel help` listed `hvf`, `-netdev help` listed `user`, and `-help` documented `restrict` and `hostfwd`. Use `q35,accel=hvf` (no TCG fallback), host CPU, one vCPU, 512 MiB and `virtio-net-pci`. Restricted user networking with IPv6 off and a single TCP forward bound to IPv4 loopback avoids bridging the guest or granting it internet access. The host initiates connections; bulk data flows **guest to host**. Serial is for setup and reference hashes only.

## Measured results

Intel i5-3210M, macOS 13.7.8, QEMU 11.1.2. Guest generated random bytes once. Before round 1, host received one payload of each size and checked length and SHA-256 against the guest. Each measured transfer also passed both checks. Full = 1920×1080×4 bytes, eight copies per connection; damage = 256×256×4 bytes, 64 copies. Timer starts after a one-byte ready marker and stops after the last exact-length read; hashing is outside the timer. Echo RTT uses a separate established TCP connection, one outstanding one-byte request, host TCP_NODELAY, one warmup and 100 checked replies per round.

| Round | Full MiB/s | Damage MiB/s | Echo p50 ms | p95 ms | p99 ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 14.35 | 13.66 | 0.667 | 2.162 | 3.763 |
| 2 | 11.77 | 5.49 | 0.869 | 2.187 | 6.050 |
| 3 | 6.70 | 3.33 | 1.183 | 9.769 | 17.414 |

Full frames need 474.6 MiB/s at 60 Hz; the best round equates to 1.81 full frames/s. One damage tile per refresh needs 15 MiB/s, above even the best damage round. These are byte-budget comparisons, not measured display rates.

## Limits

Single boot, shared host with uncontrolled load, short bursts, one stream. Results include guest shell/`cat`/BusyBox `nc`, QEMU user-mode networking and Python allocation/copy costs; they are not the virtio device ceiling. The sender may buffer bytes before timing starts. Repeated identical payloads verify integrity but cannot detect permutation of identical frames. No damage extraction, encoding, compositor, presentation deadlines, CPU accounting or display-drop measurement. Idle echo is not input-to-photon latency or latency under bulk traffic.
