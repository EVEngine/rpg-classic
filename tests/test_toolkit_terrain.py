import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.terrain import autotile_map, validate_rules


def rules():
    return {'format': 'rpgc.terrain-rules', 'version': 1,
            'terrainGids': list(range(1, 17)), 'masks': {str(i): i + 1 for i in range(16)}}


def tilemap(width=5, height=5):
    return {'schema': 'eve.rpgc.map', 'id': 'brush.test', 'width': width, 'height': height,
            'layers': [{'id': 'ground', 'name': 'Terrain', 'type': 'tilelayer', 'data': [0] * (width * height)},
                       {'id': 'props', 'type': 'objectgroup', 'objects': [{'name': 'npc', 'x': 0, 'y': 0}]}]}


class TerrainTests(unittest.TestCase):
    def test_all_sixteen_masks_have_explicit_nesw_order(self):
        directions = ((2, 1, 1), (3, 2, 2), (2, 3, 4), (1, 2, 8))
        for mask in range(16):
            with self.subTest(mask=mask):
                cells = [[2, 2]] + [[x, y] for x, y, bit in directions if mask & bit]
                result = autotile_map(tilemap(), 'ground', cells, rules())
                self.assertEqual(result['layers'][0]['data'][12], mask + 1)

    def test_paint_reconnects_existing_neighbors_without_filling_empty(self):
        doc = tilemap()
        doc['layers'][0]['data'][11] = 1
        doc['layers'][0]['data'][13] = 99
        original = copy.deepcopy(doc)
        rule = rules(); original_rules = copy.deepcopy(rule)
        result = autotile_map(doc, 'Terrain', [[2, 2]], rule)
        data = result['layers'][0]['data']
        self.assertEqual(data[11], 3)  # existing left tile now connects east
        self.assertEqual(data[12], 9)  # new tile connects west
        self.assertEqual(data[13], 99)
        self.assertEqual(data[7], 0)
        self.assertEqual(data[17], 0)
        self.assertEqual(doc, original)
        self.assertEqual(rule, original_rules)
        result['layers'][1]['objects'][0]['name'] = 'other'
        self.assertEqual(doc['layers'][1]['objects'][0]['name'], 'npc')

    def test_erase_disconnects_neighbors_and_leaves_empty_cells_empty(self):
        painted = autotile_map(tilemap(), 'ground', [[1, 2], [2, 2], [3, 2]], rules())
        result = autotile_map(painted, 'ground', [[2, 2]], rules(), erase=True)
        self.assertEqual(result['layers'][0]['data'][11:14], [1, 0, 1])
        self.assertNotEqual(painted['layers'][0]['data'][12], 0)
        self.assertEqual(autotile_map(result, 'ground', [[0, 0]], rules(), erase=True), result)

    def test_edges_do_not_wrap_rows_and_duplicate_cells_are_idempotent(self):
        result = autotile_map(tilemap(2, 2), 'ground', [[1, 0], [0, 1], [1, 0]], rules())
        self.assertEqual(result['layers'][0]['data'], [0, 1, 1, 0])
        self.assertEqual(autotile_map(result, 'ground', [], rules()), result)

    def test_foreign_selected_tiles_refuse_the_entire_operation(self):
        doc = tilemap(); doc['layers'][0]['data'][1] = 99
        before = copy.deepcopy(doc)
        for erase in (False, True):
            with self.subTest(erase=erase), self.assertRaisesRegex(ValueError, 'foreign GID'):
                autotile_map(doc, 'ground', [[0, 0], [1, 0]], rules(), erase=erase)
        self.assertEqual(doc, before)

    def test_boundaries_and_bool_integers_are_rejected(self):
        for cells in ([[5, 0]], [[-1, 0]], [[True, 0]], [[1.0, 0]], [[0]], None):
            with self.subTest(cells=cells), self.assertRaises(ValueError):
                autotile_map(tilemap(), 'ground', cells, rules())
        for keyword in ({'seed': True}, {'seed': -1}, {'erase': 1}):
            with self.subTest(keyword=keyword), self.assertRaises(ValueError):
                autotile_map(tilemap(), 'ground', [[0, 0]], rules(), **keyword)
        with self.assertRaises(ValueError):
            autotile_map(tilemap(), 'props', [[0, 0]], rules())

    def test_rules_are_complete_strict_and_normalized_independently(self):
        valid = rules()
        normalized = validate_rules(valid)
        self.assertEqual(normalized['masks']['0'], [1])
        normalized['terrainGids'].append(99)
        self.assertNotIn(99, valid['terrainGids'])
        bad_rules = []
        bad = rules(); bad['masks'].pop('15'); bad_rules.append(bad)
        bad = rules(); bad['masks']['00'] = 1; bad_rules.append(bad)
        bad = rules(); bad['masks']['0'] = []; bad_rules.append(bad)
        bad = rules(); bad['masks']['0'] = [1, 1]; bad_rules.append(bad)
        bad = rules(); bad['masks']['0'] = 99; bad_rules.append(bad)
        bad = rules(); bad['masks']['0'] = True; bad_rules.append(bad)
        bad = rules(); bad['terrainGids'][0] = True; bad_rules.append(bad)
        bad = rules(); bad['terrainGids'].append(1); bad_rules.append(bad)
        bad = rules(); bad['version'] = True; bad_rules.append(bad)
        bad = rules(); bad['unknown'] = 1; bad_rules.append(bad)
        for bad in bad_rules:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                validate_rules(bad)

    def test_seeded_variants_are_reproducible_and_order_independent(self):
        rule = rules()
        rule['terrainGids'] += list(range(101, 117))
        rule['masks'] = {str(i): [i+1, i+101] for i in range(16)}
        cells = [[x, y] for y in range(5) for x in range(5)]
        first = autotile_map(tilemap(), 'ground', cells, rule, seed=123)
        self.assertEqual(first, autotile_map(tilemap(), 'ground', list(reversed(cells)), rule, seed=123))
        self.assertEqual(first, autotile_map(first, 'ground', cells, rule, seed=123))
        self.assertNotEqual(first, autotile_map(tilemap(), 'ground', cells, rule, seed=124))
        script = ('import json,sys;sys.path.insert(0,sys.argv[1]);'
                  'from rpgc_toolkit.terrain import autotile_map;'
                  'a=json.loads(sys.argv[2]);print(json.dumps(autotile_map(*a,seed=123),sort_keys=True))')
        output = subprocess.check_output([sys.executable, '-c', script, str(ROOT/'tools'),
            json.dumps([tilemap(), 'ground', cells, rule])], text=True)
        self.assertEqual(json.loads(output), first)

    def test_real_map_preserves_other_layers_and_references(self):
        doc = json.loads((ROOT/'content/maps/village-outskirts.json').read_text())
        layer = next(layer for layer in doc['layers'] if layer.get('type', 'tilelayer') == 'tilelayer')
        gid = layer['data'][0]
        if gid == 0:
            gid = 1
        rule = {'format': 'rpgc.terrain-rules', 'version': 1, 'terrainGids': [gid],
                'masks': {str(i): gid for i in range(16)}}
        result = autotile_map(doc, layer['id'], [[0, 0]], rule)
        self.assertEqual(result['tilesets'], doc['tilesets'])
        for before, after in zip(doc['layers'], result['layers']):
            if before['id'] != layer['id']:
                self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
