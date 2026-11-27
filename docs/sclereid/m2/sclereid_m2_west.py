"""Stage the stock Alpine 3.22 x86_64 client beside M2's existing libraries."""

from pathlib import Path
import subprocess


def stage(bundle, fetch):
    apk = fetch('weston-clients-14.0.2-r1.apk',
                '66df46f087e2d0a6ec1b7463b97bdc7d463cb9ff49f729e306b0c262255505ba',
                repo='community')
    client = Path(bundle) / 'weston-simple-shm'
    client.write_bytes(subprocess.check_output(['bsdtar', '-xOf', apk, 'usr/bin/weston-simple-shm']))
    client.chmod(0o755)
