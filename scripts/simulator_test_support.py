"""Read test simulator identities without polling CoreSimulator during app installation."""
from pathlib import Path
import plistlib

project_root = Path(__file__).resolve().parents[1]
project_objects = plistlib.loads((project_root / 'Quiet.xcodeproj/project.pbxproj').read_bytes())['objects']


def bundle_for(target_name):
    target = next(v for v in project_objects.values()
                  if v.get('isa') == 'PBXNativeTarget' and v['name'] == target_name)
    configuration = project_objects[target['buildConfigurationList']]['buildConfigurations'][0]
    return project_objects[configuration]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']


def app_container(simulator, bundle):
    # The app-hosted XCTest bundle and the UI runner each write their requests
    # in their own Documents directory. Read only the selected simulator and
    # exact bundle identity; a not-yet-installed app simply has no container.
    base = Path.home() / 'Library/Developer/CoreSimulator/Devices' / simulator / 'data/Containers/Data/Application'
    for metadata in base.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
        try:
            value = plistlib.loads(metadata.read_bytes())
        except (OSError, plistlib.InvalidFileException):
            continue
        if isinstance(value, dict) and value.get('MCMMetadataIdentifier') == bundle:
            return metadata.parent
    return None
