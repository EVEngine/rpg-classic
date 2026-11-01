"""Real native QA failure paths and portal landing connectivity."""
import json
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.changes import candidate_workspace
from rpgc_toolkit.map_qa import qa_source
from rpgc_toolkit.runtime import run_headless


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'requires actual native map VM')
class MapQAEdgeTests(unittest.TestCase):
    def run_qa(self, workspace, selected='village-outskirts'):
        return run_headless(os.environ['RPGC_TEST_EVE'], workspace, qa_source(selected))

    def test_all_shipped_landings_connect_without_cross_map_handle_reuse(self):
        report = self.run_qa(ROOT, '')
        self.assertTrue(report['ok'], report['diagnostics'])
        portals = [obj for row in report['value']['maps'] for obj in row['objects'] if obj['type'] == 'portal']
        self.assertEqual(len(portals), 26)
        self.assertTrue(all(obj['landingConnectedToSpawn'] for obj in portals))
        self.assertTrue(all(edge['usable'] for edge in report['value']['graph']['edges']))

    def test_semantic_gate_failure_is_structured_not_native_report_shape(self):
        with candidate_workspace(ROOT, []) as workspace:
            path = workspace / 'content/maps/village-outskirts.json'
            document = json.loads(path.read_text())
            document['tilesets'][0]['firstgid'] = 2
            path.write_text(json.dumps(document))
            report = self.run_qa(workspace)
            self.assertFalse(report['ok'])
            self.assertTrue(any(row['code'] == 'map.atlas-firstgid' for row in report['diagnostics']))
            self.assertEqual(report['value']['maps'], [])

    def test_walkable_isolated_portal_landing_is_not_graph_edge(self):
        with candidate_workspace(ROOT, []) as workspace:
            baseline = self.run_qa(workspace, 'mist-forest')
            self.assertTrue(baseline['value']['maps'])
            forest = baseline['value']['maps'][0]
            spawn = forest['spawn']
            objects = {(row['x'], row['y']) for row in forest['objects']}
            x, y = next((x, y) for y in range(2, forest['height'] - 2)
                        for x in range(2, forest['width'] - 2)
                        if forest['walkable'][y][x]
                        and max(abs(x-spawn['x']), abs(y-spawn['y'])) > 3
                        and all(max(abs(x-ox), abs(y-oy)) > 2 for ox, oy in objects))
            path = workspace / 'content/maps/mist-forest.json'
            document = json.loads(path.read_text())
            data = document['layers'][0]['data']
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                data[(y+dy)*forest['width']+x+dx] = 0
            path.write_text(json.dumps(document))
            path = workspace / 'content/maps/village-outskirts.json'
            document = json.loads(path.read_text())
            portal_name = None
            for layer in document['layers']:
                for obj in layer.get('objects', []):
                    properties = {row['name']: row for row in obj.get('properties', [])}
                    if properties.get('targetMap', {}).get('value') == 'mist-forest':
                        properties['targetX']['value'] = str(x)
                        properties['targetY']['value'] = str(y)
                        portal_name = obj['name']
            self.assertIsNotNone(portal_name)
            path.write_text(json.dumps(document))
            report = self.run_qa(workspace)
            self.assertFalse(report['ok'])
            self.assertTrue(any(row['code'] == 'map-qa.portal-isolated' for row in report['diagnostics']), report['diagnostics'])
            portal = next(row for row in report['value']['maps'][0]['objects'] if row['name'] == portal_name)
            self.assertTrue(portal['landingWalkable'])
            self.assertFalse(portal['landingConnectedToSpawn'])
            edge = next(row for row in report['value']['graph']['edges']
                        if row['source'] == 'village-outskirts' and row['target'] == 'mist-forest')
            self.assertFalse(edge['usable'])
            self.assertIn('mist-forest', report['value']['graph']['unreachable'])
