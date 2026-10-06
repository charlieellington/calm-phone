#!/usr/bin/env python3
"""Build native Shortcuts payloads with the phone-verified Boolean filter setter."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import uuid

SETTER = 'com.apple.AccessibilityUtilities.AXSettingsShortcuts.AXToggleColorFiltersIntent'
BUNDLE = 'design.ellington.quiet'
# Shortcuts If condition codes: 4 = text "is"; 0 = numeric "is less than" (needs a number,
# so iOS stops with "Please choose a value for each parameter").
TEXT_IS = 4
NAMESPACE = uuid.UUID('1ade5a92-506c-4e71-baf0-d88d1e1e53da')


def identifier(label):
    return str(uuid.uuid5(NAMESPACE, label)).upper()


def action(name, parameters):
    return {'WFWorkflowActionIdentifier': name, 'WFWorkflowActionParameters': parameters}


def setter(state, label):
    if type(state) is not bool:
        raise ValueError('Native Colour Filters state must be a Boolean, never an enum string')
    return action(SETTER, {'UUID': identifier(label), 'operation': 'turn', 'state': state})


def app_intent(name, team, bundle):
    return action(bundle + '.' + name, {
        'UUID': identifier(name),
        'AppIntentDescriptor': {'AppIntentIdentifier': name, 'BundleIdentifier': bundle,
                                'Name': 'Calm Phone', 'TeamIdentifier': team}})


def workflow(name, actions):
    return {'WFWorkflowName': name, 'WFWorkflowActions': actions,
            'WFWorkflowClientVersion': '3612.0.2.1', 'WFWorkflowMinimumClientVersion': 900,
            'WFWorkflowMinimumClientVersionString': '900', 'WFWorkflowTypes': [],
            'WFWorkflowInputContentItemClasses': [],
            'WFWorkflowIcon': {'WFWorkflowIconStartColor': 4278190080,
                               'WFWorkflowIconGlyphNumber': 59511}}


def workflows(team, bundle=BUNDLE):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Pass the app signing team identifier')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        raise ValueError('Pass the app bundle identifier')
    get = app_intent('ColourFiltersRequiredIntent', team, bundle)
    group = identifier('colour-if')
    main = [get, action('is.workflow.actions.conditional', {
        'GroupingIdentifier': group, 'WFControlFlowMode': 0, 'WFCondition': TEXT_IS,
        # iOS 26 shows an empty "If Condition" unless the input is wrapped as a Variable.
        'WFConditionalActionString': 'on', 'WFInput': {'Type': 'Variable', 'Variable': {
            'Value': {'OutputName': 'Colour setting',
                      'OutputUUID': get['WFWorkflowActionParameters']['UUID'], 'Type': 'ActionOutput'},
            'WFSerializationType': 'WFTextTokenAttachment'}}}),
        setter(True, 'main-on'),
        action('is.workflow.actions.conditional', {'GroupingIdentifier': group, 'WFControlFlowMode': 1}),
        setter(False, 'main-off'),
        action('is.workflow.actions.conditional', {'GroupingIdentifier': group, 'WFControlFlowMode': 2}),
        app_intent('CheckColourApplicationIntent', team, bundle)]
    result = {name: workflow(name, actions) for name, actions in [
        ('Calm Phone Colour', main),
        ('Calm Phone Set Grayscale', [setter(True, 'standalone-on')]),
        ('Calm Phone Set Colour', [setter(False, 'standalone-off')])]}
    for payload in result.values():
        validate(payload, team, bundle)
    return result


def validate(payload, team, bundle=BUNDLE):
    actions = payload['WFWorkflowActions']
    for item in actions:
        params = item['WFWorkflowActionParameters']
        if item['WFWorkflowActionIdentifier'] == SETTER:
            if params.get('operation') != 'turn' or type(params.get('state')) is not bool:
                raise ValueError('Invalid native Boolean Colour Filters setter')
    if payload['WFWorkflowName'] != 'Calm Phone Colour':
        return
    if len(actions) != 7:
        raise ValueError('Main workflow must read, branch, set and check')
    for index, name in [(0, 'ColourFiltersRequiredIntent'), (6, 'CheckColourApplicationIntent')]:
        descriptor = actions[index]['WFWorkflowActionParameters']['AppIntentDescriptor']
        if descriptor != {'AppIntentIdentifier': name, 'BundleIdentifier': bundle,
                          'Name': 'Calm Phone', 'TeamIdentifier': team}:
            raise ValueError('App Intent descriptor does not match the app')
    branches = [actions[index]['WFWorkflowActionParameters'] for index in (1, 3, 5)]
    if [branch['WFControlFlowMode'] for branch in branches] != [0, 1, 2]:
        raise ValueError('Invalid If / Otherwise / End If')
    if len({branch['GroupingIdentifier'] for branch in branches}) != 1:
        raise ValueError('Conditional branches must share a group')
    first = branches[0]
    if first['WFInput']['Variable']['Value']['OutputUUID'] != actions[0]['WFWorkflowActionParameters']['UUID']:
        raise ValueError('Conditional must read the current app decision')
    if first['WFCondition'] != TEXT_IS or first['WFConditionalActionString'] != 'on':
        raise ValueError('Conditional must compare the returned string with on')
    if actions[2]['WFWorkflowActionParameters']['state'] is not True:
        raise ValueError('On branch must enable filters')
    if actions[4]['WFWorkflowActionParameters']['state'] is not False:
        raise ValueError('Otherwise branch must disable filters')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signed-app', type=Path, required=True,
                        help='Existing signed Calm Phone app; used only to read its team identifier')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sign', action='store_true', help='Use native shortcuts sign for import files')
    args = parser.parse_args()
    signed = subprocess.run(['codesign', '-dv', str(args.signed_app)],
                            capture_output=True, text=True, check=True)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signed.stderr, re.M)
    if not match:
        parser.error('App does not have a signing team')
    info = plistlib.loads((args.signed_app / 'Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    args.output.mkdir(parents=True, exist_ok=True)
    for name, payload in workflows(match[1], bundle).items():
        source = args.output / (name + '.unsigned.shortcut')
        source.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_BINARY, sort_keys=True))
        if args.sign:
            subprocess.run(['shortcuts', 'sign', '--mode', 'anyone', '--input', str(source),
                            '--output', str(args.output / (name + '.shortcut'))], check=True,
                           capture_output=True)
    print('Built three colour workflows with native Boolean setters; phone automation acceptance is separate.')


if __name__ == '__main__':
    main()
