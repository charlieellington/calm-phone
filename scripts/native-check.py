#!/usr/bin/env python3
"""Repeatable unsigned native checks. Never provisions, exports or installs on a phone."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
os.chdir(root)
lane = sys.argv[1]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
result_path = f'.build/{lane}-{stamp}.xcresult'
command = ['xcodebuild', '-project', 'Quiet.xcodeproj', '-scheme', 'Quiet',
           '-configuration', 'Release' if lane == 'release' else 'Debug',
           '-derivedDataPath', '.build/DerivedData', '-resultBundlePath', result_path,
           'CODE_SIGNING_ALLOWED=NO']
if lane == 'test':
    identifier = os.environ.get('QUIET_SIMULATOR_ID')
    if not identifier:
        devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
        candidates = [d for values in devices['devices'].values() for d in values if d['name'] == 'iPhone 17 Pro']
        if not candidates:
            sys.exit('No installed iPhone 17 Pro simulator. Host tests and generic-device builds remain available.')
        identifier = candidates[0]['udid']
    command += ['-destination', f'platform=iOS Simulator,id={identifier}', 'test']
elif lane == 'debug':
    command += ['-destination', 'generic/platform=iOS', 'build']
elif lane == 'release':
    command += ['-destination', 'generic/platform=iOS', '-archivePath', '.build/Quiet-unsigned.xcarchive', 'archive']
else:
    sys.exit('Expected test, debug, or release')

def sanitize(text):
    text = text.replace(str(root), '<repo>').replace(str(Path.home()), '<home>')
    return re.sub(r'\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b', '<identifier>', text)

evidence_dir = root / os.environ.get('QUIET_NATIVE_EVIDENCE_DIR', '.build/evidence')
evidence_dir.mkdir(parents=True, exist_ok=True)
log = evidence_dir / f'{lane}-{stamp}.log'
capture_process = None
capture_log = None
if lane == 'test':
    capture_log = (evidence_dir / f'screens-{stamp}.log').open('w')
    capture_process = subprocess.Popen([
        'python3', 'scripts/capture-native-screens.py', '--simulator', identifier,
        '--output', str(evidence_dir / f'screenshots-{stamp}')
    ], stdout=capture_log, stderr=subprocess.STDOUT)
with log.open('w') as output:
    output.write(f'Candidate source HEAD: {sha}\nCommand: {sanitize(" ".join(command))}\n')
    output.flush()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        output.write(sanitize(line))
        if re.search(r'\.swift:\d+:\d+: error:', line) or '** ' in line:
            print(sanitize(line).rstrip(), flush=True)
    code = process.wait()
    output.write(f'\nExit code: {code}\n')
if capture_process:
    if code == 0:
        try:
            capture_code = capture_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            capture_process.terminate()
            capture_code = capture_process.wait()
        if capture_code != 0:
            print('Native screenshot helper did not complete successfully', flush=True)
            code = 1
    else:
        capture_process.terminate()
        capture_process.wait()
    capture_log.close()
receipt = {'lane': lane, 'source_head': sha, 'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'])),
           'command': sanitize(' '.join(command)), 'exit_code': code, 'log': str(log.relative_to(root)),
           'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest(), 'xcresult': result_path,
           'unsigned': True, 'physical_device_check': False}
(evidence_dir / f'{lane}-{stamp}.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(f'{lane}: exit {code}; {log.relative_to(root)}; {result_path}', flush=True)
sys.exit(code)
