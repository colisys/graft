---
name: protocol-diagnostics
description: Add nonblocking structured diagnostics to a protocol bridge or low-level event loop. Collect events via Unix pipes or FIFOs, inspect them over loopback HTTP, and decide separately whether a request should be ignored, cancelled, or fatal.
---

# Protocol diagnostics

1. Find where the request is decoded and where its state is applied. Emit a diagnostic at the decision point, not as a substitute for handling the request.
2. For a valid but unsupported operation, prefer a protocol-defined cancel, no-op, or unavailable response. Keep the session alive when its state remains valid. Do not report success for an operation that did not happen. Reject malformed framing or unsafe state transitions when continuation would desynchronize the protocol; isolate the smallest affected scope. Record the actual action taken. Never let the collector decide whether to terminate the target.
3. Use one sanitized NDJSON record per event. Required fields: `level` (`info`, `warning`, `error`, `fatal`), `source`, `event`, `message`. Optional: `file` (basename), `line` (one-based), `action`. Use stable event names and messages; exclude text input, clipboard contents, credentials, and unreviewed payloads. A log's severity does not change protocol behavior.
4. Send via an inherited pipe or open a named FIFO with `O_WRONLY | O_NONBLOCK | O_CLOEXEC`. For C/C++, use `__FILE__`/`__LINE__` at the call site, normalize the filename, and bound or escape the record. Write the complete line in one `write`, no larger than the smaller of `_PC_PIPE_BUF` and 4096 bytes, including newline. Handle `SIGPIPE`/`EPIPE`, missing reader (`ENXIO`), and backpressure (`EAGAIN`) without blocking the event loop; drop and count losses if possible. Do not blindly change a library host's global signal policy.
5. Verify both directions: logs are queryable and the protocol still progresses with the collector disabled, full, or gone. Check recoverable operations and fatal isolation independently.

## Bundled collector

`sidecar.py` uses only Python's standard library. From the repository root:

```sh
mkdir -m 700 /tmp/sclereid-diag-demo
python3 .agents/skills/protocol-diagnostics/sidecar.py --port 8765 --fifo /tmp/sclereid-diag-demo/events
```

From another terminal, after the collector prints its URL:

```sh
printf '%s\n' '{"level":"warning","source":"guest","event":"data_device.start_drag","message":"Drag unsupported","file":"bridge.c","line":42,"action":"cancelled"}' > /tmp/sclereid-diag-demo/events
curl 'http://localhost:8765/events?level=warning&after=0'
```

FIFO mode accepts successive writers until stopped with Ctrl+C; use a private directory and a new FIFO path. The shell example is for diagnosis only; shell redirection can block without a reader. Without `--fifo`, the collector reads stdin and stays queryable for 600 seconds after EOF by default. HTTP is read-only and loopback-only. The ring retains the latest 2,048 events in memory and reports overwritten/invalid counts; those counts do not include events dropped by producers.

For Sclereid M2, the smoke driver can launch the stdin mode with `--sidecar-port PORT`; the driver forwards allowlisted events and diagnostic summaries, while raw transcripts remain local.
