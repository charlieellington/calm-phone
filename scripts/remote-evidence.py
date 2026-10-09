#!/usr/bin/env python3
"""Evidence for one candidate: capture source BEFORE tests, inspect newly built five products AFTER."""
import hashlib, json, pathlib, plistlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
out = root / '.build/evidence'
out.mkdir(parents=True, exist_ok=True)
def run(*args): return subprocess.check_output(args, cwd=root, text=True).strip()
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
if sys.argv[1] == 'source':
    paths = run('git', 'ls-files', '-z').split('\0')
    manifest = {p: digest(root / p) for p in paths if p and (root / p).is_file()}
    dirty = run('git', 'status', '--porcelain')
    assert not dirty, 'Native verification requires a clean candidate: ' + dirty
    (out / 'source.json').write_text(json.dumps({'head': run('git', 'rev-parse', 'HEAD'),
      'tree': run('git', 'rev-parse', 'HEAD^{tree}'), 'dirty_before': False, 'files': manifest,
      'xcode': run('xcodebuild', '-version'), 'swift': run('swift', '--version'), 'macos': run('sw_vers')}, indent=2))
else:
    source = json.loads((out / 'source.json').read_text())
    for path, sha in source['files'].items(): assert digest(root / path) == sha, 'Source changed: ' + path
    objects = plistlib.loads((root / 'Quiet.xcodeproj/project.pbxproj').read_bytes())['objects']
    production = [v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and
                  v['productType'] in ['com.apple.product-type.application', 'com.apple.product-type.app-extension']]
    expected = {objects[v['buildConfigurationList']]['buildConfigurations'][0] for v in production}
    expected = {objects[c]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] for c in expected}
    inspections = {}
    for lane, app in [('Debug', root / '.build/DerivedData/Build/Products/Debug-iphoneos/Quiet.app'),
                      ('Release', root / '.build/Quiet-unsigned.xcarchive/Products/Applications/Quiet.app')]:
        products = [app] + sorted((app / 'PlugIns').glob('*.appex'))
        rows = []
        for product in products:
            info = plistlib.loads((product / 'Info.plist').read_bytes())
            signature = subprocess.run(['codesign', '-d', str(product)], capture_output=True, text=True)
            assert signature.returncode != 0, 'Unexpected signed product ' + str(product)
            assert info['UIDeviceFamily'] == [1]
            assert info['MinimumOSVersion'] == '18.5'
            assert info['CFBundleVersion'] == '7'
            rows.append({'bundle': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
              'build': info['CFBundleVersion'], 'device_family': info['UIDeviceFamily'], 'minimum_os': info['MinimumOSVersion'],
              'binary_sha256': digest(product / info['CFBundleExecutable']), 'info_sha256': digest(product / 'Info.plist'),
              'unsigned': True, 'codesign_diagnostic': signature.stderr.strip()})
        assert {r['bundle'] for r in rows} == expected
        inspections[lane] = rows
    entitlements = {p.as_posix(): plistlib.loads(p.read_bytes()) for p in pathlib.Path('.').glob('Quiet*/*.entitlements')}
    (out / 'archive-inspection.json').write_text(json.dumps({'source_head': source['head'], 'source_unchanged': True,
      'products': inspections, 'source_entitlements': entitlements, 'physical_device_check': False}, indent=2))
    screenshots = []
    for p in sorted(out.rglob('*.png')): screenshots.append({'file':str(p.relative_to(out)), 'sha256':digest(p)})
    for lane in ['test', 'ui']:
        manifest = out / f'{lane}-attachments/manifest.json'
        if manifest.exists():
            for test in json.loads(manifest.read_text()):
                for a in test['attachments']:
                    for row in screenshots:
                        if row['file'] == f"{lane}-attachments/{a['exportedFileName']}":
                            row.update({'name':a['suggestedHumanReadableName'], 'test':test['testIdentifier'],
                                        'device':a['deviceName'], 'failure':a['isAssociatedWithFailure']})
    requests = []
    for p in out.rglob('capture-manifest.json'):
        requests.extend(json.loads(p.read_text()))
    for r in requests: assert any(pathlib.Path(p['file']).name == r['file'] for p in screenshots), r
    ui_expected = sorted(set(re.findall(r'capture\(app,\s*"([a-z0-9-]+)"\)',
        (root / 'QuietUITests/QuietUITests.swift').read_text())) |
        {prefix + name for prefix in ['ui-url-from-', 'ui-used-from-']
         for name in ['settings', 'unlock-methods', 'pin', 'add-remote', 'duration', 'connected']} |
        {'ui-link-error-' + name for name in ['invalid', 'expired', 'unknown']})
    ui_inventory = {}
    for lane in ['test', 'ui']:
        names = [row.get('name', '') for row in screenshots if row['file'].startswith(lane + '-attachments/')]
        missing = [name for name in ui_expected if not any(n.startswith(name + '_') for n in names)]
        ui_inventory[lane] = {'requested':ui_expected, 'produced':len(ui_expected) - len(missing), 'missing':missing}
    (out / 'screenshots.json').write_text(json.dumps({'source_head':source['head'], 'requested_compositor':len(requests),
      'ui':ui_inventory, 'produced_files':len(screenshots), 'screenshots':screenshots}, indent=2))
    hashes = {str(p.relative_to(out)):digest(p) for p in sorted(out.rglob('*')) if p.is_file() and p.name != 'hashes.json'}
    (out / 'hashes.json').write_text(json.dumps(hashes, indent=2))
    assert all(not lane['missing'] for lane in ui_inventory.values()), 'UI screenshot inventory incomplete'
    print('Verified unchanged source and five unsigned products in both configurations; screenshots:',len(screenshots))
