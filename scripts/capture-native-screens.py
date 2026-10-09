#!/usr/bin/env python3
"""Capture only test-requested native simulator screens. Never installs or accesses a phone."""
import argparse
import json
from pathlib import Path
import subprocess
import time


from simulator_test_support import app_container, bundle_for
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
started = time.time()
startup_deadline = time.monotonic() + 1800
capture_deadline = None
seen = set()
receipts = []
events = None
# A fresh public clone may spend several minutes building and launching the
# simulator before XCTest requests its first capture. Budget the capture phase
# from that request, while keeping a separate bounded startup wait.
while time.monotonic() < (capture_deadline or startup_deadline):
    if events is None or not events.parent.exists():
        container = app_container(args.simulator, bundle_for('Quiet'))
        if container is not None:
            events = container / 'Documents' / 'NativeScreenCapture'
    if events is not None:
        for ready in sorted(events.glob('*/calm-*.ready')):
            if ready.stat().st_mtime < started or str(ready) in seen:
                continue
            name = ready.stem
            if not name.startswith('calm-') or not all(c.isalnum() or c in '-_' for c in name):
                raise RuntimeError('Invalid test screenshot name')
            if capture_deadline is None:
                capture_deadline = time.monotonic() + 240
            destination = output / (name + '.png')
            capture_started = time.monotonic()
            print(f'{name}: capture started at {time.time():.3f}', flush=True)
            subprocess.run(['xcrun', 'simctl', 'io', args.simulator, 'screenshot', str(destination)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=45)
            # Attach the compositor image to the same XCTest result that requested it.
            (ready.parent / (name + '.png')).write_bytes(destination.read_bytes())
            (ready.parent / (name + '.ack')).write_text('captured\n')
            seen.add(str(ready))
            elapsed = time.monotonic() - capture_started
            receipts.append({'name': name, 'file': destination.name,
                             'capture_seconds': elapsed, 'request': json.loads(ready.read_text())})
            print(f'{name}: acknowledged after {elapsed:.3f}s', flush=True)
            (output / 'capture-manifest.json').write_text(json.dumps(receipts, indent=2))
        if any(p.stat().st_mtime >= started for p in events.glob('*/complete')):
            print(f'Captured {len(receipts)} native compositor screenshots', flush=True)
            raise SystemExit(0 if receipts else 1)
    time.sleep(0.15)
if capture_deadline is None:
    raise SystemExit('Native screenshot requests did not start within 1800 seconds')
raise SystemExit('Native screenshot requests did not complete within 240 seconds of the first request')
