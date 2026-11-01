import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.authoring import (paint_map, fill_map, resize_map, edit_event,
    analyze_event, extract_strings, apply_strings, clone_document)


def tilemap():
    return {'schema': 'eve.rpgc.map', 'width': 3, 'height': 2,
            'tilewidth': 32, 'tileheight': 16, 'renderSpacing': [2, 2], 'origin': [100, 50],
            'layers': [{'id': 'ground', 'type': 'tilelayer', 'data': [1, 1, 2, 1, 2, 1]},
                       {'id': 'props', 'type': 'objectgroup', 'objects': []}]}


class AuthoringTests(unittest.TestCase):
    def test_paint_is_pure_and_only_changes_selected_layer(self):
        original = tilemap()
        snapshot = copy.deepcopy(original)
        result = paint_map(original, 'ground', [[0, 0], [2, 1]], 7)
        self.assertEqual(result['layers'][0]['data'], [7, 1, 2, 1, 2, 7])
        self.assertEqual(original, snapshot)
        result['layers'][1]['objects'].append({})
        self.assertEqual(original['layers'][1]['objects'], [])

    def test_paint_rejects_partial_out_of_bounds_without_mutation(self):
        original = tilemap()
        with self.assertRaises(ValueError):
            paint_map(original, 'ground', [[0, 0], [3, 1]], 9)
        self.assertEqual(original['layers'][0]['data'][0], 1)
        for gid in (-1, True, 1.2):
            with self.assertRaises(ValueError):
                paint_map(original, 'ground', [[0, 0]], gid)
        with self.assertRaises(ValueError):
            paint_map(original, 'props', [[0, 0]], 1)

    def test_fill_is_four_connected(self):
        original = tilemap()
        result = fill_map(original, 'ground', 0, 0, 8)
        self.assertEqual(result['layers'][0]['data'], [8, 8, 2, 8, 2, 1])
        self.assertEqual(fill_map(original, 'ground', 0, 0, 1), original)

    def test_layer_selects_unique_name_or_id_and_rejects_ambiguity(self):
        original = tilemap()
        original['layers'][0]['name'] = 'Terrain'
        self.assertEqual(paint_map(original, 'Terrain', [[0, 0]], 3)['layers'][0]['data'][0], 3)
        original['layers'].append({'id': 'other', 'name': 'Terrain', 'data': [0] * 6})
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            fill_map(original, 'Terrain', 0, 0, 9)
        original['layers'][2]['name'] = 'ground'
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            paint_map(original, 'ground', [[0, 0]], 1)
        original['layers'][2]['id'] = 42
        self.assertEqual(paint_map(original, '42', [[0, 0]], 7)['layers'][2]['data'][0], 7)

    def test_resize_pads_and_crops_rows(self):
        original = tilemap()
        bigger = resize_map(original, 4, 3, 9)
        self.assertEqual(bigger['layers'][0]['data'], [1, 1, 2, 9, 1, 2, 1, 9, 9, 9, 9, 9])
        self.assertEqual(resize_map(original, 2, 1)['layers'][0]['data'], [1, 1])
        self.assertEqual(original['width'], 3)

    def test_resize_uses_isometric_world_coordinates(self):
        original = tilemap()
        # cell (2, 1) -> world (132, 98) using origin (100,50), pitch (64,32).
        original['layers'][1]['objects'] = [{'name': 'npc', 'x': 132, 'y': 98}]
        self.assertEqual(resize_map(original, 4, 4)['layers'][1], original['layers'][1])
        with self.assertRaisesRegex(ValueError, 'strand object'):
            resize_map(original, 2, 2)

    def test_resize_updates_only_existing_layer_dimensions(self):
        original = tilemap()
        original['layers'][0].update(width=3, height=2)
        resized = resize_map(original, 4, 5)
        self.assertEqual((resized['layers'][0]['width'], resized['layers'][0]['height']), (4, 5))
        self.assertNotIn('width', resized['layers'][1])
        self.assertNotIn('height', resized['layers'][1])
        self.assertEqual(original['layers'][0]['width'], 3)

    def test_invalid_map_shape_and_allocations(self):
        original = tilemap()
        original['layers'][0]['data'].pop()
        with self.assertRaises(ValueError):
            fill_map(original, 'ground', 0, 0, 1)
        with self.assertRaises(ValueError):
            resize_map(tilemap(), 100000, 100000)

    def test_event_edit_and_nested_analysis(self):
        doc = {'schema': 'eve.rpgc.event', 'steps': [
            {'kind': 'wait', 'duration': 1},
            {'kind': 'branch', 'condition': {'kind': 'switch', 'name': 's'},
             'then': [{'kind': 'message', 'reference': 'story.hello'}],
             'else': [{'kind': 'set_variable', 'name': 'gold', 'op': 'add', 'value': 3}]}]}
        moved = edit_event(doc, 'move', 0, destination=1)
        self.assertEqual(moved['steps'][1]['kind'], 'wait')
        self.assertEqual(doc['steps'][0]['kind'], 'wait')
        inserted = edit_event(doc, 'insert', 2, {'kind': 'wait', 'duration': 2})
        self.assertEqual(len(inserted['steps']), 3)
        replaced = edit_event(doc, 'replace', 0, {'kind': 'message', 'reference': 'other'})
        self.assertEqual(replaced['steps'][0]['reference'], 'other')
        self.assertEqual(len(edit_event(doc, 'remove', 0)['steps']), 1)
        report = analyze_event(doc)
        self.assertEqual(report['steps'], 4)
        self.assertEqual(report['maxDepth'], 2)
        self.assertEqual(report['variables'], ['gold', 's'])
        self.assertEqual(report['references'][0]['path'], '/steps/1/then/0/reference')
        with self.assertRaises(ValueError):
            edit_event(doc, 'move', 0, destination=2)
        with self.assertRaises(ValueError):
            edit_event(doc, 'remove', 2)

    def test_localization_preserves_identity_and_references(self):
        doc = {'id': 'hero', 'name': 'internal', 'title': '英雄', 'reference': 'story.a',
               'members': [{'displayName': '侠客', 'description': '故事'}],
               'a/b~c': {'text': 'hello'},
               'objects': [{'properties': [{'name': 'speaker', 'value': '长者'},
                                           {'name': 'dialogue', 'value': 'story.elder'}]}]}
        catalog = extract_strings(doc)
        self.assertEqual(set(catalog), {'/title', '/members/0/displayName', '/members/0/description',
                                      '/a~1b~0c/text', '/objects/0/properties/0/value'})
        translated = apply_strings(doc, {'/title': 'Hero', '/a~1b~0c/text': '你好'}, catalog)
        self.assertEqual(translated['title'], 'Hero')
        self.assertEqual(translated['a/b~c']['text'], '你好')
        self.assertEqual(translated['id'], 'hero')
        self.assertEqual(doc['title'], '英雄')
        for bad in ({'/id': 'renamed'}, {'/title': 123}):
            with self.assertRaises(ValueError):
                apply_strings(doc, bad)
        with self.assertRaisesRegex(ValueError, 'stale'):
            apply_strings(doc, {'/title': 'Hero'}, {'/title': 'old'})
        with self.assertRaisesRegex(ValueError, 'missing source'):
            apply_strings(doc, {'/title': 'Hero'}, {})

    def test_real_content(self):
        event = json.loads((ROOT / 'content/events/mist-forest.arrival.json').read_text())
        self.assertGreater(analyze_event(event)['steps'], len(event['steps']))
        doc = json.loads((ROOT / 'content/maps/village-outskirts.json').read_text())
        self.assertEqual(resize_map(doc, doc['width']+1, doc['height']+1)['width'], doc['width']+1)
        self.assertIn('/title', extract_strings(doc))

    def test_clone_preserves_references_and_input(self):
        original = {'id': 'old', 'title': 'Old', 'effects': ['effect.a']}
        result = clone_document(original, 'new', 'New')
        self.assertEqual(result, {'id': 'new', 'title': 'New', 'effects': ['effect.a']})
        result['effects'].append('effect.b')
        self.assertEqual(original['effects'], ['effect.a'])


if __name__ == '__main__':
    unittest.main()
