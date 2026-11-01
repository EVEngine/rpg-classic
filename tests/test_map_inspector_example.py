"""Example artifacts must be actual native-validated, reproducible candidates."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('map_inspector_example', ROOT / 'examples/map-inspector/generate.py')
example = importlib.util.module_from_spec(spec); spec.loader.exec_module(example)
from rpgc_toolkit.project import fingerprint, read_json
from rpgc_toolkit.terrain import validate_rules


class MapInspectorExampleTests(unittest.TestCase):
    def test_existing_and_content_destinations_refused_before_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / 'existing'; existing.mkdir()
            (existing / 'keep').write_text('unchanged')
            with patch.object(example, 'run_headless') as sdk:
                for output in (existing, ROOT / 'content/maps/new-demo-output'):
                    with self.subTest(output=output), self.assertRaises(ValueError):
                        example.generate('unused', ROOT, output)
                sdk.assert_not_called()
            self.assertEqual((existing / 'keep').read_text(), 'unchanged')

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'requires actual engine metadata, map gate and QA')
    def test_good_bad_reproducible_candidates_and_source_immutability(self):
        binary = os.environ['RPGC_TEST_EVE']
        sources = {path: path.read_bytes() for path in
                   [ROOT / example.MAP_PATH, ROOT / 'content/tilesets/sbs-overworld.json', ROOT / 'content/tilesets/sbs-overworld.png']}
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / 'first', Path(directory) / 'second'
            first = example.generate(binary, ROOT, a)
            second = example.generate(binary, ROOT, b)
            self.assertTrue(first['good']['gate']); self.assertTrue(first['good']['qa'])
            self.assertTrue(first['bad']['gate']); self.assertFalse(first['bad']['qa'])
            self.assertEqual([d['code'] for d in first['bad']['diagnostics']], ['map-qa.portal-landing'])
            self.assertTrue(first['sandWalkable']); self.assertEqual(first['sandGid'], 54)
            self.assertEqual(first['sourceFingerprint'], fingerprint(read_json(ROOT / example.MAP_PATH)))
            self.assertEqual(first['sourceFingerprint'], second['sourceFingerprint'])
            self.assertEqual(sorted(p.name for p in a.iterdir()), sorted(p.name for p in b.iterdir()))
            for path in a.iterdir():
                self.assertEqual(path.read_bytes(), (b / path.name).read_bytes(), path.name)
            rules = read_json(a / 'terrain.rules.json')
            self.assertEqual(validate_rules(rules)['version'], 2)
            self.assertEqual(rules['mode'], 'transition8')
            good = read_json(a / 'good.change-set.json'); bad = read_json(a / 'bad-landing.change-set.json')
            self.assertEqual(good['changes'][0]['expect'], first['sourceFingerprint'])
            original = read_json(ROOT / example.MAP_PATH)
            edited = good['changes'][0]['document']
            base_layer = next(x for x in original['layers'] if x['id'] == 'terrain')
            paint_layer = next(x for x in edited['layers'] if x['id'] == 'terrain')
            self.assertGreaterEqual(sum(x != y for x, y in zip(base_layer['data'], paint_layer['data'])), 9)
            objects = next(x for x in edited['layers'] if x['id'] == 'actors')['objects']
            portal = next(x for x in objects if x['name'] == 'inspector_portal')
            self.assertEqual([portal['x'], portal['y']], first['nativeObjectWorld'])
            bad_portal = next(x for layer in bad['changes'][0]['document']['layers'] for x in layer.get('objects', []) if x['name'] == 'inspector_portal')
            self.assertEqual(bad_portal['x'], portal['x']); self.assertEqual(bad_portal['y'], portal['y'])
            self.assertEqual(read_json(a / 'object.source.json')['instanceId'], 'inspector.portal.demo')
            self.assertEqual(read_json(a / 'object.template.json')['coordinateSpace'], 'world')
        for path, content in sources.items():
            self.assertEqual(path.read_bytes(), content, str(path))


if __name__ == '__main__': unittest.main()
