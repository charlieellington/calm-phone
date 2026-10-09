#!/usr/bin/env python3
"""Deliver synthetic UI-test URLs to a running simulator app, without XCTest relaunching it."""
import argparse, json, pathlib, subprocess, time

from simulator_test_support import app_container, bundle_for
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
out = pathlib.Path(args.output)
out.mkdir(parents=True, exist_ok=True)
started = time.time()
receipts = []
seen = set()
def container(bundle):
    return app_container(args.simulator, bundle)
while time.time() - started < 3000:
    runner = container(bundle_for('QuietUITests') + '.xctrunner')
    if runner:
        for request in sorted((runner / 'Documents/CalmUITestURLs').glob('*.json')):
            if request.stat().st_mtime < started or request.name in seen:
                continue
            url = json.loads(request.read_text())['url']
            assert url.startswith(('quiet://connect?t=', 'quiet://unlock?t=')), 'Test URL only'
            app = container(bundle_for('Quiet'))
            marker = app / 'Documents/CalmUITestProcess.json'
            before = json.loads(marker.read_text())
            subprocess.run(['xcrun', 'simctl', 'openurl', args.simulator, url], check=True)
            request.with_suffix('.ack').write_text('openurl submitted; accept system prompt\n')
            deadline = time.time() + 30
            while not request.with_suffix('.confirmed').exists() and time.time() < deadline:
                time.sleep(0.1)
            assert request.with_suffix('.confirmed').exists(), 'UI test did not confirm system interaction'
            time.sleep(0.4)
            after = json.loads(marker.read_text())
            assert before == after, 'Warm delivery unexpectedly restarted the app'
            receipts.append({'request':request.stem, 'route':url.split('?')[0], 'process':before, 'same_process':True,
                             'system_prompt_handled':True})
            (out / 'deliveries.json').write_text(json.dumps(receipts, indent=2))
            request.with_suffix('.done').write_text('delivered to same process\n')
            seen.add(request.name)
    time.sleep(0.15)
raise SystemExit('UI URL helper exceeded test time budget')
