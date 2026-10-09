#!/usr/bin/env python3
"""Capture only test-requested native simulator screens. Never installs or accesses a phone."""
import argparse
import json
from pathlib import Path
import subprocess
import time


import plistlib
project_root = Path(__file__).resolve().parents[1]
project_objects = plistlib.loads((project_root / 'Quiet.xcodeproj/project.pbxproj').read_bytes())['objects']
def bundle_for(target_name):
    target = next(v for v in project_objects.values()
                  if v.get('isa') == 'PBXNativeTarget' and v['name'] == target_name)
    configuration = project_objects[target['buildConfigurationList']]['buildConfigurations'][0]
    return project_objects[configuration]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
started = time.time()
seen = set()
receipts = []
while time.time() - started < 240:
    container = subprocess.run(['xcrun', 'simctl', 'get_app_container', args.simulator,
                                bundle_for('Quiet'), 'data'], capture_output=True, text=True)
    if container.returncode == 0:
        events = Path(container.stdout.strip()) / 'Documents' / 'NativeScreenCapture'
        for ready in sorted(events.glob('*/calm-*.ready')):
            if ready.stat().st_mtime < started or str(ready) in seen:
                continue
            name = ready.stem
            if not name.startswith('calm-') or not all(c.isalnum() or c in '-_' for c in name):
                raise RuntimeError('Invalid test screenshot name')
            destination = output / (name + '.png')
            subprocess.run(['xcrun', 'simctl', 'io', args.simulator, 'screenshot', str(destination)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # Attach the compositor image to the same XCTest result that requested it.
            (ready.parent / (name + '.png')).write_bytes(destination.read_bytes())
            (ready.parent / (name + '.ack')).write_text('captured\n')
            seen.add(str(ready))
            receipts.append({'name': name, 'file': destination.name, 'request': json.loads(ready.read_text())})
            (output / 'capture-manifest.json').write_text(json.dumps(receipts, indent=2))
        if any(p.stat().st_mtime >= started for p in events.glob('*/complete')):
            print(f'Captured {len(receipts)} native compositor screenshots', flush=True)
            raise SystemExit(0 if receipts else 1)
    time.sleep(0.15)
raise SystemExit('Native screenshot requests did not complete within 240 seconds')
