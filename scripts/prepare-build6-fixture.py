#!/usr/bin/env python3
"""Generate old-format synthetic stores from frozen public build-6 schemas; no Git/network needed."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / 'scripts/fixtures/build6'
work = root / '.build/build6-generator'
fixture = root / '.build/Build6Fixture'
provenance = json.loads((source / 'provenance.json').read_text())
for path, expected in provenance['files'].items():
    assert hashlib.sha256((source / path).read_bytes()).hexdigest() == expected, path
for directory in (work, fixture):
    if directory.exists():
        shutil.rmtree(directory)
shutil.copytree(source, work)
generator = root / 'scripts/fixtures/build6-generator.swift'
shutil.copyfile(generator, work / 'Sources/Quiet/Fixture.swift')
subprocess.run(['swift', 'run', '--package-path', str(work), 'Build6Fixture', str(fixture)],
               check=True, cwd=root)
provenance['generator_sha256'] = hashlib.sha256(generator.read_bytes()).hexdigest()
provenance['entity_sha256'] = hashlib.sha256((source / 'Sources/Quiet/UnlockInterval.swift').read_bytes()).hexdigest()
(fixture / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
print('Synthetic build-6 stores generated from frozen public schemas')
