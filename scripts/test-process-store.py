#!/usr/bin/env python3
"""Actual process contention and death on both sides of the SQLite commit boundary."""
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

subprocess.run(['swift', 'build', '--package-path', 'Packages/QuietCore', '--product', 'QuietProbe'], check=True)
binary_path = subprocess.check_output(['swift', 'build', '--package-path', 'Packages/QuietCore', '--show-bin-path'], text=True).strip()
probe = str(Path(binary_path) / 'QuietProbe')
with tempfile.TemporaryDirectory(prefix='quiet-store-') as directory:
    workers = [subprocess.Popen([probe, 'increment', directory, '100']) for _ in range(4)]
    assert all(worker.wait() == 0 for worker in workers)
    def state():
        with sqlite3.connect(str(Path(directory) / 'control.sqlite')) as db:
            return json.loads(db.execute('SELECT payload FROM control WHERE singleton=1').fetchone()[0])
    assert state()['revision'] == 400, 'lost a process commit'
    assert subprocess.run([probe, 'crash-before-commit', directory]).returncode == 71
    assert state()['revision'] == 400 and not state()['setupComplete'], 'rollback failed after death'
    assert subprocess.run([probe, 'crash-after-commit', directory]).returncode == 72
    assert state()['revision'] == 401 and state()['monitorFailed'], 'durable projection intent lost'
    assert subprocess.run([probe, 'increment', directory, '1']).returncode == 0
    assert state()['revision'] == 402, 'writer lock was not released on death'
print('PASS: four independent writers, 400 commits, pre-commit death rollback, post-commit replay, process-death lock release')
