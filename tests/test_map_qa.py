"""Native navigation regressions; mutations live only in disposable copies."""
import copy
import json
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.changes import candidate_workspace
from rpgc_toolkit.map_qa import inspect_maps, map_id, input_manifest
from rpgc_toolkit.map_preview import preview_source
from rpgc_toolkit.project import read_json, fingerprint


class MapInputTests(unittest.TestCase):
    def test_identifiers_and_preview_scope(self):
        for bad in ('../escape', 'x";throw 1;', 'a/b', 9, True):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                map_id(bad)
        with self.assertRaises(ValueError):
            preview_source('')
        self.assertIn('RpgcNavigation.load("village-outskirts")', preview_source('village-outskirts'))


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for native map QA')
class NativeMapTests(unittest.TestCase):
    def test_all_shipped_maps_use_native_navigation_and_picking(self):
        report = inspect_maps(os.environ['RPGC_TEST_EVE'], ROOT)
        self.assertTrue(report['ok'], report['diagnostics'])
        maps = report['value']['maps']
        self.assertEqual(len(maps), len(list((ROOT / 'content/maps').glob('*.json'))))
        self.assertEqual(sum(row['projectionChecks'] for row in maps), 8024)
        self.assertTrue(all(row['pickMismatches'] == 0 for row in maps))
        self.assertFalse(report['rendered'])
        self.assertFalse(report['value']['capabilities']['stateConditions'])
        self.assertEqual(report['value']['graph']['unreachable'], [])
        self.assertTrue(all(edge['usable'] for edge in report['value']['graph']['edges']))
        self.assertEqual(report['inputs'], input_manifest(ROOT))

    def test_native_blocking_detected_without_changing_source(self):
        path = 'content/maps/village-outskirts.json'
        before = (ROOT / path).read_bytes()
        document = read_json(ROOT / path)
        # Authored spawn is (11,8). GID zero blocks in the actual shared adapter.
        document['layers'][0]['data'][8 * document['width'] + 11] = 0
        with candidate_workspace(ROOT, [{'path':path,'document':document,'delete':False}]) as workspace:
            report = inspect_maps(os.environ['RPGC_TEST_EVE'], workspace, 'village-outskirts')
        self.assertFalse(report['ok'])
        self.assertIn('map-qa.spawn-blocked', {d['code'] for d in report['diagnostics']})
        self.assertEqual((ROOT / path).read_bytes(), before)

    def test_bad_portal_has_exact_document_and_object_path(self):
        path = 'content/maps/village-outskirts.json'
        doc = read_json(ROOT / path)
        original = copy.deepcopy(doc)
        for group in doc['layers']:
            for obj in group.get('objects', []):
                if obj['name'] == 'forest_gate':
                    for prop in obj['properties']:
                        if prop['name'] in ('targetX', 'targetY'):
                            prop['value'] = '0'
        change = {'format':'rpgc.change-set','version':1,'changes':[
            {'path':path,'expect':fingerprint(original),'document':doc}],'deletions':[]}
        report = inspect_maps(os.environ['RPGC_TEST_EVE'], ROOT, 'village-outskirts', changes=change)
        self.assertTrue(report['gate']['ok'])
        self.assertFalse(report['ok'])
        bad = [d for d in report['diagnostics'] if d['code'] == 'map-qa.portal-landing']
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0]['document'], path)
        self.assertEqual(bad[0]['path'], '/layers/2/objects/3/properties')
        self.assertEqual(read_json(ROOT / path), original)

    def test_unknown_map_and_invalid_candidate_are_not_passes(self):
        result = inspect_maps(os.environ['RPGC_TEST_EVE'], ROOT, 'missing-map')
        self.assertFalse(result['ok'])
        doc = read_json(ROOT / 'content/maps/village-outskirts.json')
        doc['unexpectedField'] = True
        change = {'format':'rpgc.change-set','version':1,'changes':[
            {'path':'content/maps/village-outskirts.json','document':doc}],'deletions':[]}
        result = inspect_maps(os.environ['RPGC_TEST_EVE'], ROOT, changes=change)
        self.assertFalse(result['ok'])
        self.assertFalse(result['gate']['ok'])
        self.assertFalse(result['applied'])


if __name__ == '__main__':
    unittest.main()
