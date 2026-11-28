"""Loopback viewer for a single run's sanitized NDJSON diagnostic stream."""
import argparse
from collections import deque
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

LEVELS = ('info', 'warning', 'error', 'fatal')
MAX_LINE = 4096


@contextmanager
def input_stream(fifo):
    if fifo is None:
        yield sys.stdin.buffer
        return
    # Create rather than trust a pre-existing path. Use a private parent directory.
    os.mkfifo(fifo, 0o600)
    try:
        # A buffered reader could hold its lock in readline() during shutdown.
        with open(os.open(fifo, os.O_RDONLY | os.O_NONBLOCK), 'rb', buffering=0) as reader:
            # Prevent EOF between independent writers, without blocking startup.
            writer = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
            try:
                os.set_blocking(reader.fileno(), True)
                yield reader
            finally:
                os.close(writer)
    finally:
        fifo.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--fifo', type=Path, help='create and read a Unix FIFO instead of stdin')
    parser.add_argument('--retain-seconds', type=int, default=600, help='retention after stdin closes')
    args = parser.parse_args()
    if not 0 <= args.port <= 65535 or not 1 <= args.retain_seconds <= 86400:
        parser.error('invalid port or retention')
    events = deque(maxlen=2048)
    lock = threading.Lock()
    stats = dict(received=0, invalid=0, overwritten=0, eof=False)

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(2)
            super().setup()

        def do_GET(self):
            url = urlsplit(self.path)
            if url.path not in ('/', '/events'):
                self.send_error(404)
                return
            try:
                q = parse_qs(url.query, strict_parsing=True)
                level = q.get('level', [None])[0]
                after = int(q.get('after', ['0'])[0])
                if set(q) - {'level', 'after'} or (level and level not in LEVELS) or after < 0:
                    raise ValueError
            except ValueError:
                self.send_error(400)
                return
            with lock:
                snapshot = dict(stats, events=[e for e in events if e['seq'] > after and (not level or e['level'] == level)])
            body = json.dumps(snapshot).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    with HTTPServer(('localhost', args.port), Handler) as server, input_stream(args.fifo) as stream:
        def ingest():
            while line := stream.readline(MAX_LINE + 1):
                try:
                    if len(line) > MAX_LINE:
                        while line and not line.endswith(b'\n'):
                            line = stream.readline(MAX_LINE + 1)
                        raise ValueError
                    obj = json.loads(line)
                    if not isinstance(obj, dict) or obj.get('level') not in LEVELS:
                        raise ValueError
                    record = {}
                    for key in ('level', 'source', 'event', 'message', 'action', 'file'):
                        val = obj.get(key)
                        if val is None and key in ('action', 'file'):
                            continue
                        if not isinstance(val, str):
                            raise ValueError
                        record[key] = val[:512]
                    n = obj.get('line')
                    if type(n) is int and n > 0:
                        record['line'] = n
                    with lock:
                        stats['received'] += 1
                        stats['overwritten'] += len(events) == events.maxlen
                        events.append(dict(record, seq=stats['received'], time=time.time()))
                except (UnicodeError, ValueError, RecursionError):
                    with lock:
                        stats['invalid'] += 1
            with lock:
                stats['eof'] = True
            time.sleep(args.retain_seconds)
            server.shutdown()

        threading.Thread(target=ingest, daemon=True).start()
        print(f'http://localhost:{server.server_port}/events', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
