#!/usr/bin/env python3
"""Regress the actual native state encoding and the decision-to-setter wiring."""
import copy
from pathlib import Path
import plistlib
import unittest

import colour_shortcuts as build


class ColourShortcutsTests(unittest.TestCase):
    def testUsesTheBuildersBundleIdentifier(self):
        bundle = 'org.example.calmphone'
        payload = build.workflows('TESTTEAM00', bundle)['Calm Phone Colour']
        for index in (0, 6):
            item = payload['WFWorkflowActions'][index]
            self.assertTrue(item['WFWorkflowActionIdentifier'].startswith(bundle + '.'))
            self.assertEqual(item['WFWorkflowActionParameters']['AppIntentDescriptor']['BundleIdentifier'], bundle)
        build.validate(payload, 'TESTTEAM00', bundle)

    def testNativeExportUsesBooleanState(self):
        native = plistlib.loads((Path(__file__).parent / 'fixtures/native-colour-setters.plist').read_bytes())
        for state, key in [(True, 'on'), (False, 'off')]:
            generated = build.setter(state, 'fixture')['WFWorkflowActionParameters'].copy()
            generated.pop('UUID')
            self.assertEqual(generated, native[key])
            # Equality alone permits 1 == True; native saved type is significant.
            self.assertIs(type(plistlib.loads(plistlib.dumps(generated))['state']), bool)

    def testRejectsThePreviouslyFailingEnumStringAndIntegerStates(self):
        for invalid in ('on', 'off', 1, 0, None):
            with self.assertRaises(ValueError):
                build.setter(invalid, 'bad')

    def testRejectsWrongBranchOrStaleDecisionReferences(self):
        main = build.workflows('TESTTEAM00')['Calm Phone Colour']
        for index, field, wrong in [(2, 'state', False), (4, 'state', True),
                                    (3, 'GroupingIdentifier', 'other')]:
            damaged = copy.deepcopy(main)
            damaged['WFWorkflowActions'][index]['WFWorkflowActionParameters'][field] = wrong
            with self.assertRaises(ValueError):
                build.validate(damaged, 'TESTTEAM00')
        damaged = copy.deepcopy(main)
        damaged['WFWorkflowActions'][1]['WFWorkflowActionParameters']['WFInput']['Variable']['Value']['OutputUUID'] = 'stale'
        with self.assertRaises(ValueError):
            build.validate(damaged, 'TESTTEAM00')

    def testRequiresTheAppIdentityAndRejectsStringStateInSavedPayload(self):
        main = build.workflows('TESTTEAM00')['Calm Phone Colour']
        main['WFWorkflowActions'][2]['WFWorkflowActionParameters']['state'] = 'on'
        with self.assertRaises(ValueError):
            build.validate(main, 'TESTTEAM00')
        with self.assertRaises(ValueError):
            build.workflows('')


if __name__ == '__main__':
    unittest.main()
