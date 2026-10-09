#!/usr/bin/env python3
"""Audit tracked public source and flattened screenshot assets without printing suspect contents."""
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root, text=True).split('\0')
for relative in filter(None, paths):
    path = root / relative
    assert not any(part in {'doing', '.context', 'DerivedData', 'xcuserdata', 'docs/build'} for part in path.relative_to(root).parts), relative
    assert not relative.startswith(('docs/plan/', 'docs/studio-handoff/', '.build/')), relative
    assert path.suffix not in {'.mobileprovision', '.p12', '.cer', '.ipa', '.xcresult', '.xcarchive'}, relative
    assert path.name != 'Signing.local.xcconfig', relative
    if path.suffix in {'.swift', '.py', '.md', '.yml', '.xcconfig', '.pbxproj', '.plist', '.json'}:
        content = path.read_text()
        assert not re.search(r'[/]Users[/]|[/]home[/]vercel-sandbox|gh[pousr]_[A-Za-z0-9]{20}|-----BEGIN [A-Z ]*PRIVATE KEY', content), relative
        assert not re.search(r'(?:https://[^\s"\']+#|quiet://(?:connect|unlock)\?t=)c2\.[A-Za-z0-9_-]{22}\.', content), relative
        if path.suffix == '.swift':
            assert not re.search(r'"[0-9]{6}"', content), 'Literal PIN in ' + relative

assets = root / 'docs/images/remote-unlock'
manifest = json.loads((assets / 'manifest.json').read_text())
assert {a['file'] for a in manifest['assets']} == {'add-remote.png', 'unlock-methods.png', 'whatsapp-redacted.png'}
for row in manifest['assets']:
    data = (assets / row['file']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == row['sha256'], row['file']
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', data[16:24]) == (row['width'], row['height'])
    assert data[24:26] == bytes([8, 2]), 'Expected flattened 8-bit RGB'
    offset = 8
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        kind = data[offset+4:offset+8]
        assert kind in {b'IHDR', b'IDAT', b'IEND'}, 'PNG metadata in ' + row['file']
        offset += length + 12
    assert offset == len(data)
print('PASS: tracked publication source audit and three flattened, metadata-free asset hashes. Visual redaction requires separate review.')
