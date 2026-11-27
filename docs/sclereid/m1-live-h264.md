# M1 control: live H.264 guest to host

On the Intel i5-3210M, all 120 frames decoded before transport EOF in each of six Alpine guest runs, but neither fixture sustained 1080p60. For a nominal 2-second clip, the final decoded frame arrived at 4.96–5.51 s for desktop and 3.26–3.94 s for motion. The host-only pipe also missed 60 Hz, so the guest result does not isolate TCP cost.

## Reproduce

```sh
s=$COMMANDCODE_SCRATCHPAD
python3 scripts/sclereid-m1-encoder.py --live-h264 --ffmpeg "$s/encoder-ffmpeg" \
  --guest "$s/std.iso" "$s/encoder-linux"
```

Use the pinned Alpine standard ISO and batch-harness FFmpeg binaries (guest 7.0.2, host 7.1). Omit `--guest` for the host pipe control.

## Recorded output

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

## Setup and measurement

Each run uses one persistent encoder and one macOS software decoder. The desktop and motion fixtures feed libx264 (`ultrafast`, `zerolatency`, CRF 28, two threads, GOP 60) with FFmpeg’s `realtime` filter at nominal 1080p60. The Alpine/HVF guest flushes H.264 in NUT over restricted virtio-net TCP forwarded on host loopback; the host flushes received bytes into the decoder pipe.

Host times start at the guest readiness byte (host control: encoder spawn returned). Frame timestamps are taken when decoded CRC records are read; records in one read share a timestamp. `gaps_over_tick` counts inter-frame gaps longer than 1/60 s. `eof_to_last_ms` is last frame time minus transport EOF time. Contiguous frame PTS and CRCs are checked against an untimed replay, not the source. Times cover fixture generation through checksum output, not presentation.
