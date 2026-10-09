#!/usr/bin/env python3
"""Static product membership and entitlement checks. Signed checks are a separate attended lane."""
import plistlib
from pathlib import Path
import re
import sys

objects = plistlib.loads(Path('Quiet.xcodeproj/project.pbxproj').read_bytes())['objects']
targets = [v for v in objects.values() if v.get('isa') == 'PBXNativeTarget']
production = [v for v in targets if v['productType'] in ['com.apple.product-type.application', 'com.apple.product-type.app-extension']]
assert {v['name'] for v in production} == {'Quiet', 'QuietMonitor', 'QuietShieldConfig', 'QuietShieldAction', 'QuietWidget'}
assert not any('Mac' in v['name'] or 'Filter' in v['name'] for v in targets)
if sys.argv[1] == 'signing':
    app = next(v for v in production if v['name'] == 'Quiet')
    app_configs = objects[app['buildConfigurationList']]['buildConfigurations']
    bundle = objects[app_configs[0]]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']
    group = plistlib.loads(Path('Quiet/Quiet.entitlements').read_bytes())['com.apple.security.application-groups']
    assert len(group) == 1 and group[0].startswith('group.')
    assert f'"{group[0]}"' in Path('QuietShared/SharedContainer.swift').read_text()
    for target in production:
        name = target['name']
        entitlement = plistlib.loads(Path(f'{name}/{name}.entitlements').read_bytes())
        assert entitlement['com.apple.security.application-groups'] == group
        allowed = {'com.apple.security.application-groups', 'com.apple.developer.family-controls'}
        if name == 'Quiet':
            from_host = re.search(r'public static let host = "([^"]+)"',
                                 Path('Packages/QuietCore/Sources/QuietCore/RemoteUnlock.swift').read_text())
            assert from_host, 'Remote link host missing'
            domains = entitlement['com.apple.developer.associated-domains']
            assert domains == ['applinks:' + from_host[1], 'applinks:' + from_host[1] + '?mode=developer']
            allowed.add('com.apple.developer.associated-domains')
        assert set(entitlement) <= allowed
        source_files = []
        for phase_id in target['buildPhases']:
            phase = objects[phase_id]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                source_files += [objects[objects[f]['fileRef']]['path'] for f in phase['files']]
        enforcing = any(re.search(r'ManagedSettingsStore\(|DeviceActivityCenter\(|ApplePolicy\.', Path(f).read_text())
                        for f in source_files if f.endswith('.swift'))
        if enforcing or name in {'QuietShieldConfig', 'QuietShieldAction'}:
            assert entitlement.get('com.apple.developer.family-controls') is True, f'{name}: Family Controls required'
        for config in objects[target['buildConfigurationList']]['buildConfigurations']:
            settings = objects[config]['buildSettings']
            product_bundle = settings['PRODUCT_BUNDLE_IDENTIFIER']
            assert product_bundle == bundle if name == 'Quiet' else product_bundle.startswith(bundle + '.')
            assert not settings.get('DEVELOPMENT_TEAM') and not settings.get('PROVISIONING_PROFILE_SPECIFIER')
            assert settings['CODE_SIGN_ENTITLEMENTS'] == f'{name}/{name}.entitlements'
    config = Path('Config/Base.xcconfig').read_text()
    assert 'IPHONEOS_DEPLOYMENT_TARGET = 18.5' in config and 'TARGETED_DEVICE_FAMILY = 1' in config
    print('PASS: five iPhone products, consistent bundle IDs/App Group, iOS18.5, Family Controls on enforcing targets, app-only associated domains, no saved team/profiles or extra capabilities. Signed products NOT checked.')
else:
    folders = ['Quiet', 'QuietShared', 'QuietMonitor', 'QuietWidget', 'QuietShieldConfig', 'QuietShieldAction']
    sources = {str(f): f.read_text() for folder in folders for f in Path(folder).rglob('*.swift')}
    prohibited = r'clearAllSettings|revokeAuthorization|softUnblock|emergencyUnblock|toggleSession|foqos://|foqos\.app|photos-redirect|camera://|LSApplicationWorkspace|performSelector'
    for path, source in sources.items():
        assert not re.search(prohibited, source), path
        if 'ManagedSettingsStore(' in source:
            assert path == 'QuietShared/ApplePolicy.swift', path
    action = sources['QuietShieldAction/ShieldActionExtension.swift']
    assert action.count('completionHandler(.close)') == 3
    assert 'QuietCore' not in action and 'SharedContainer' not in action
    widget = sources['QuietWidget/QuietWidget.swift']
    assert '.grant(' not in widget and '.install(' not in widget
    assert 'LockNowIntent' in widget and 'StaticConfiguration' in widget
    assert len([f for f in Path('Quiet').rglob('*.swift') if 'coordinator.grant(' in f.read_text()]) == 1
    assert 'quiet.today' in widget and 'quiet.apps' in widget
    assert 'Widget removed' in widget and 'Open Calm Phone' in widget
    assert widget.count('Link(') == 1 and 'quiet://open/status' in widget
    info = plistlib.loads(Path('Quiet/Info.plist').read_bytes())
    assert 'LSApplicationQueriesSchemes' not in info
    assert info['CFBundleDisplayName'] == 'Calm Phone' and info['UIUserInterfaceStyle'] == 'Dark'
    for path, source in sources.items():
        assert not re.search(r'canOpenURL|UIApplication.shared.open|AppOpening|coMapsURL|func launch\(', source), path
    routes = Path('Packages/QuietCore/Sources/QuietCore/Routing.swift').read_text()
    assert 'AppDestination' not in routes and 'func destination' not in routes
    assert 'primaryButtonLabel: .init(text: "Close"' in sources['QuietShieldConfig/ShieldConfigurationExtension.swift']
    print('PASS: central shield writer; shields close every variant; retained widget kinds show retirement; cached lock only restricts; no launch adapters/queried schemes; Calm Phone dark identity. Signed products NOT checked.')
