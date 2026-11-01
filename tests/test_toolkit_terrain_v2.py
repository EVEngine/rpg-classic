"""Blob topology and closed two-material transition candidates."""
import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.terrain import (BLOB_MASKS, EIGHT_DIRECTIONS, autotile_map,
                                  normalize_blob_mask, validate_rules)


def terrain(start=1):
    return {'terrainGids': list(range(start, start + 47)),
            'masks': {str(mask): start + i for i, mask in enumerate(BLOB_MASKS)}}


def blob():
    return {'format': 'rpgc.terrain-rules', 'version': 2, 'mode': 'blob8', **terrain()}


def transition():
    return {'format': 'rpgc.terrain-rules', 'version': 2, 'mode': 'transition8',
            'terrains': {'water': terrain(), 'land': terrain(101)},
            'priority': ['land', 'water']}


def tilemap(fill=0):
    return {'schema': 'eve.rpgc.map', 'id': 'blob.test', 'width': 7, 'height': 7,
            'layers': [{'id': 'ground', 'type': 'tilelayer', 'data': [fill] * 49}],
            'metadata': {'keep': ['unchanged']}}


class TerrainV2Tests(unittest.TestCase):
    def test_all_256_neighborhoods_normalize_to_exact_47(self):
        self.assertEqual(len(BLOB_MASKS), 47)
        rules = blob()
        for mask in range(256):
            cells = [[3, 3]] + [[3 + dx, 3 + dy] for dx, dy, bit in EIGHT_DIRECTIONS if mask & bit]
            result = autotile_map(tilemap(), 'ground', cells, rules)
            self.assertEqual(result['layers'][0]['data'][24], rules['masks'][str(normalize_blob_mask(mask))])
        self.assertEqual(normalize_blob_mask(16 | 128), 0)
        self.assertEqual(normalize_blob_mask(1 | 2 | 16), 19)
        for invalid in (-1, 256, True, 1.0):
            with self.assertRaises(ValueError):
                normalize_blob_mask(invalid)

    def test_diagonal_frontier_updates_and_erase_removes_inner_corner(self):
        rules = blob()
        doc = autotile_map(tilemap(), 'ground', [[3, 3], [4, 3], [3, 4]], rules)
        before = copy.deepcopy(doc)
        result = autotile_map(doc, 'ground', [[4, 4]], rules)
        self.assertEqual(result['layers'][0]['data'][24], rules['masks']['38'])
        erased = autotile_map(result, 'ground', [[4, 4]], rules, erase=True)
        self.assertEqual(erased['layers'][0]['data'][24], rules['masks']['6'])
        self.assertEqual(doc, before)
        self.assertEqual(erased['layers'][0]['data'][32], 0)

    def test_transition_updates_both_owners_and_preserves_inputs(self):
        rules = transition(); original_rules = copy.deepcopy(rules)
        doc = tilemap(1); before = copy.deepcopy(doc)
        result = autotile_map(doc, 'ground', [[3, 3]], rules, terrain_id='land')
        data = result['layers'][0]['data']
        self.assertEqual(data[24], rules['terrains']['land']['masks']['0'])
        # West water loses its east connection and both eastern diagonals.
        self.assertEqual(data[23], rules['terrains']['water']['masks'][str(255 & ~2 & ~16 & ~32)])
        self.assertEqual(doc, before); self.assertEqual(rules, original_rules)
        restored = autotile_map(result, 'ground', [[3, 3]], rules, terrain_id='land', erase=True)
        self.assertEqual(restored['layers'][0]['data'][24], rules['terrains']['water']['masks']['255'])
        self.assertNotIn(0, restored['layers'][0]['data'])

    def test_priority_foreign_and_void_conflicts_are_atomic(self):
        rules = transition()
        doc = autotile_map(tilemap(1), 'ground', [[3, 3]], rules, terrain_id='land')
        before = copy.deepcopy(doc)
        for erase in (False, True):
            with self.assertRaisesRegex(ValueError, 'conflicts'):
                autotile_map(doc, 'ground', [[3, 3]], rules, terrain_id='water', erase=erase)
        self.assertEqual(doc, before)
        for gid in (0, 999, True):
            doc = tilemap(1); doc['layers'][0]['data'][22] = gid
            before = copy.deepcopy(doc)
            with self.assertRaisesRegex(ValueError, 'neighborhood'):
                autotile_map(doc, 'ground', [[3, 3]], rules, terrain_id='land')
            self.assertEqual(doc, before)
        # A third material outside the edited/read neighborhood is untouched.
        doc = tilemap(1); doc['layers'][0]['data'][0] = 999
        self.assertEqual(autotile_map(doc, 'ground', [[4, 4]], rules, terrain_id='land')['layers'][0]['data'][0], 999)

    def test_map_edge_is_extended_material_for_transition_only(self):
        rules = transition()
        result = autotile_map(tilemap(1), 'ground', [[0, 0]], rules, terrain_id='water')
        self.assertEqual(result['layers'][0]['data'][0], rules['terrains']['water']['masks']['255'])
        result = autotile_map(tilemap(), 'ground', [[0, 0]], blob())
        self.assertEqual(result['layers'][0]['data'][0], blob()['masks']['0'])

    def test_masks_ownership_and_unknown_fields_are_strict(self):
        bads = []
        bad = blob(); bad['masks'].pop('255'); bads.append(bad)
        bad = blob(); bad['masks']['16'] = 1; bads.append(bad)
        bad = blob(); bad['masks']['0'] = 999; bads.append(bad)
        bad = blob(); bad['masks']['0'] = [1, 1]; bads.append(bad)
        bad = blob(); bad['version'] = True; bads.append(bad)
        bad = blob(); bad['extra'] = True; bads.append(bad)
        bad = transition(); bad['terrains']['land'] = terrain(); bads.append(bad)
        bad = transition(); bad['terrains']['third'] = terrain(201); bads.append(bad)
        bad = transition(); bad['priority'] = ['water', 'water']; bads.append(bad)
        bad = transition(); bad['priority'] = ['water', []]; bads.append(bad)
        for bad in bads:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                validate_rules(bad)
        for terrain_id in (None, 'missing', True):
            with self.assertRaises(ValueError):
                autotile_map(tilemap(1), 'ground', [[3, 3]], transition(), terrain_id=terrain_id)

    def test_variants_seed_order_and_repaint_are_stable(self):
        rules = blob()
        rules['terrainGids'] += list(range(101, 148))
        rules['masks'] = {key: [gid, gid + 100] for key, gid in rules['masks'].items()}
        cells = [[x, y] for x in range(7) for y in range(7)]
        result = autotile_map(tilemap(), 'ground', cells, rules, seed=90)
        self.assertEqual(result, autotile_map(tilemap(), 'ground', cells[::-1], rules, seed=90))
        self.assertEqual(result, autotile_map(result, 'ground', cells, rules, seed=90))
        self.assertNotEqual(result, autotile_map(tilemap(), 'ground', cells, rules, seed=91))

    def test_examples_validate(self):
        for name in ('terrain.blob8.json', 'terrain.transition8.json'):
            validate_rules(json.loads((ROOT / 'examples/toolkit' / name).read_text()))
