# M1 control: live H.264 guest to host

One persistent Alpine/HVF FFmpeg encoder and one persistent macOS software FFmpeg decoder per 120-frame run on the Intel i5-3210M test host. The existing desktop and motion fixtures feed libx264 (ultrafast, zerolatency, CRF 28, two threads, GOP 60) through the `realtime` filter with a nominal 1080p60 clock. Flushed NUT packets carrying H.264 cross restricted virtio-net TCP, forwarded only on host loopback. The host immediately flushes received bytes into the decoder pipe. No DAX transport is measured here.

```sh
s=$COMMANDCODE_SCRATCHPAD
python3 scripts/sclereid-m1-encoder.py --live-h264 --ffmpeg "$s/encoder-ffmpeg" \
  --guest "$s/std.iso" "$s/encoder-linux"
```

Use the pinned Alpine standard ISO and the same FFmpeg binaries as the batch harness (guest 7.0.2, host 7.1). Omit `--guest` for the host pipe control. Host timestamps are relative to receipt of the guest readiness byte (host control: encoder spawn returned). Frame times are observed when decoded-frame CRC records are read; records in the same read share a timestamp. The harness verifies contiguous frame PTS and checksums against an untimed replay of the captured stream. This checks streaming against replay, not decoded quality against the source. A negative EOF-to-last value means the final decoded record was seen before transport EOF.

```text
LIVE H264 | ALPINE HVF / VIRTIO-NET TCP | 1920x1080 60 fps 120 frames | gap_ms=p50/p95/p99/max
desktop run=1 frames=120 pre_eof=120 bytes=23972 first_bytes_ms=157.77 first_frame_ms=266.31 last_frame_ms=5427.76 eof_ms=5469.11 eof_to_last_ms=-41.36 gap_ms=37.84/75.57/99.23/118.93 gaps_over_tick=119
desktop run=2 frames=120 pre_eof=120 bytes=23972 first_bytes_ms=70.21 first_frame_ms=111.97 last_frame_ms=4955.12 eof_ms=4977.60 eof_to_last_ms=-22.48 gap_ms=37.81/60.51/68.33/69.24 gaps_over_tick=119
desktop run=3 frames=120 pre_eof=120 bytes=23972 first_bytes_ms=73.84 first_frame_ms=106.88 last_frame_ms=5506.19 eof_ms=5525.87 eof_to_last_ms=-19.68 gap_ms=42.02/76.24/97.40/100.89 gaps_over_tick=119
motion run=1 frames=120 pre_eof=120 bytes=4805790 first_bytes_ms=34.86 first_frame_ms=95.89 last_frame_ms=3464.64 eof_ms=3485.02 eof_to_last_ms=-20.39 gap_ms=25.47/51.80/67.74/69.83 gaps_over_tick=117
motion run=2 frames=120 pre_eof=120 bytes=4805790 first_bytes_ms=38.06 first_frame_ms=121.58 last_frame_ms=3942.41 eof_ms=3956.79 eof_to_last_ms=-14.38 gap_ms=28.65/60.08/69.47/133.28 gaps_over_tick=116
motion run=3 frames=120 pre_eof=120 bytes=4805790 first_bytes_ms=33.81 first_frame_ms=94.54 last_frame_ms=3263.19 eof_ms=3275.62 eof_to_last_ms=-12.43 gap_ms=24.58/46.69/54.78/55.33 gaps_over_tick=114
LIVE H264 | HOST PIPE | 1920x1080 60 fps 120 frames | gap_ms=p50/p95/p99/max
desktop run=1 frames=120 pre_eof=120 bytes=23974 first_bytes_ms=187.19 first_frame_ms=226.75 last_frame_ms=4847.84 eof_ms=4875.83 eof_to_last_ms=-27.99 gap_ms=37.16/53.68/68.52/78.94 gaps_over_tick=119
motion run=1 frames=120 pre_eof=120 bytes=4805792 first_bytes_ms=139.58 first_frame_ms=191.31 last_frame_ms=2213.89 eof_ms=2228.55 eof_to_last_ms=-14.66 gap_ms=14.61/28.26/43.03/141.25 gaps_over_tick=38
```

All guest frames decoded before EOF in all six runs, proving incremental delivery. Neither fixture sustained 60 Hz: the guest desktop took about 5 seconds and motion over 3 seconds for a nominal 2-second clip. Timing includes fixture generation, pacing, encoding, TCP, relay, decoding and checksum output; it does not isolate their costs or measure source-frame deadlines or presentation. The host pipe control also missed 60 Hz, so the guest result cannot be attributed to TCP alone. Live AV1 was not run; M1 remains open.
