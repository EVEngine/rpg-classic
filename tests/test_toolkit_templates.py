import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.templates import expand_template, resolve_template, plan_instances, update_instances, check_templates, instantiate_object_group
from rpgc_toolkit.project import read_json
from rpgc_toolkit.changes import check_changes


def template():
    return {'format': 'rpgc.template', 'version': 1, 'id': 'potion', 'revision': 1,
            'document': {'schema': 'eve.rpgc.item', 'version': 1, 'id': 'unused', 'title': 'Potion',
                         'value': 10, 'weight': .2, 'use': {'effects': ['heal']}, 'description': 'base'},
            'parameters': {'title': {'type': 'string', 'default': 'Potion', 'pointers': ['/title']}},
            'allowedOverrides': ['/value', '/description'], 'referencePointers': ['/use/effects/0']}


class TemplateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); (self.root / 'items').mkdir()
        (self.root / 'workflow.json').write_text(json.dumps({'kinds': {'item': {'directory': 'items'}}}))
        self.templates = [template()]

    def instance(self, identifier='custom', overrides=None):
        result = expand_template(self.templates, 'potion', identifier, {'title': '原创'}, overrides)
        result['path'] = 'items/' + identifier + '.json'
        result['sidecar']['path'] = result['path']
        (self.root / result['path']).write_text(json.dumps(result['document']))
        return result

    def records(self, *instances):
        return [{'path': i['path'], 'sidecar': i['sidecar']} for i in instances]

    def test_expand_typed_parameters_explicit_references_no_mutation(self):
        before = copy.deepcopy(self.templates)
        result = expand_template(self.templates, 'potion', 'custom', {'title': '原创'}, {'/value': 9},
                                 {'/use/effects/0': {'from': 'heal', 'to': 'regenerate'}})
        self.assertEqual(result['document']['id'], 'custom')
        self.assertEqual(result['document']['value'], 9)
        self.assertEqual(result['sidecar']['expandedBase']['value'], 10)
        self.assertEqual(result['document']['use']['effects'], ['regenerate'])
        self.assertEqual(self.templates, before)
        for kwargs in ({'parameters': {'unknown': 1}}, {'parameters': {'title': 3}},
                       {'overrides': {'/weight': 1}}, {'overrides': {'/id': 'x'}},
                       {'references': {'/title': {'from': 'heal', 'to': 'x'}}},
                       {'references': {'/use/effects/0': {'from': 'stale', 'to': 'x'}}}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                expand_template(self.templates, 'potion', 'custom', **kwargs)

    def test_typed_bool_is_not_integer_and_nonfinite_rejected(self):
        self.templates[0]['parameters'] = {'value': {'type': 'integer', 'pointers': ['/value']}}
        for value in (True, 1.2, float('nan'), '1'):
            with self.assertRaises(ValueError):
                expand_template(self.templates, 'potion', 'custom', {'value': value})
        with self.assertRaises(ValueError): expand_template(self.templates, 'potion', 'custom')
        self.assertEqual(expand_template(self.templates, 'potion', 'custom', {'value': 7})['document']['value'], 7)

    def test_inheritance_cycles_duplicates_unknown_fields_and_scope(self):
        child = {'format': 'rpgc.template', 'version': 1, 'id': 'child', 'revision': 1, 'base': 'potion', 'document': {'weight': .5}}
        self.templates.append(child)
        self.assertEqual(expand_template(self.templates, 'child', 'custom')['document']['weight'], .5)
        for bad in ([*self.templates, copy.deepcopy(child)],
                    [dict(template(), base='child'), child],
                    [dict(template(), base='missing')],
                    [dict(template(), shell='danger')],
                    [dict(template(), document={'schema': 'eve.rpgc.map'})]):
            with self.assertRaises(ValueError): resolve_template(bad, 'potion')
        changed = copy.deepcopy(child); changed['parameters'] = {'title': {'type': 'integer', 'pointers': ['/title']}}
        with self.assertRaises(ValueError): resolve_template([template(), changed], 'child')

    def test_update_all_affected_preserves_override_and_reveals_conflict(self):
        a, b = self.instance('a', {'/description': 'manual'}), self.instance('b', {'/value': 25})
        before = {p.name: p.read_bytes() for p in (self.root / 'items').iterdir()}
        self.templates[0]['revision'] = 2
        self.templates[0]['document']['weight'] = .3
        self.templates[0]['document']['value'] = 12
        report = update_instances(self.root, self.templates, self.records(a, b))
        self.assertFalse(report['ok'])
        self.assertEqual(report['affected'], ['items/a.json', 'items/b.json'])
        self.assertEqual(report['instances'][0]['document']['description'], 'manual')
        self.assertEqual(report['instances'][0]['document']['value'], 12)
        self.assertEqual(report['instances'][1]['document']['value'], 25)
        self.assertEqual(report['instances'][1]['document']['weight'], .3)
        self.assertEqual(report['conflicts'][0]['pointer'], '/value')
        self.assertEqual(report['conflicts'][0]['baseNew']['value'], 12)
        self.assertEqual(len(report['changeSet']['changes']), 1)
        with patch('rpgc_toolkit.templates.check_changes') as gate:
            with self.assertRaises(ValueError): check_templates('eve', self.root, report)
            gate.assert_not_called()
        self.assertEqual(before, {p.name: p.read_bytes() for p in (self.root / 'items').iterdir()})

    def test_update_inherited_base_and_automatic_deletion(self):
        child = {'format': 'rpgc.template', 'version': 1, 'id': 'child', 'revision': 1, 'base': 'potion'}
        self.templates.append(child)
        instance = expand_template(self.templates, 'child', 'custom')
        instance['path'] = 'items/custom.json'
        (self.root / instance['path']).write_text(json.dumps(instance['document']))
        self.templates[0]['revision'] = 2
        del self.templates[0]['document']['description']
        self.templates[0]['allowedOverrides'] = ['/value']
        result = update_instances(self.root, self.templates, self.records(instance))
        self.assertTrue(result['ok']); self.assertEqual(result['affected'], [instance['path']])
        self.assertNotIn('description', result['instances'][0]['document'])
        with patch('rpgc_toolkit.templates.check_changes', return_value={'ok': True}) as gate:
            self.assertTrue(check_templates('eve', self.root, result)['ok'])
            gate.assert_called_once()

    def test_array_conflicts_and_missing_distinguished_from_null(self):
        self.templates[0]['allowedOverrides'] += ['/use/effects']
        a = self.instance(overrides={'/description': None})
        self.templates[0]['revision'] = 2
        del self.templates[0]['document']['description']
        self.templates[0]['allowedOverrides'].remove('/description')
        report = update_instances(self.root, self.templates, self.records(a))
        conflict = report['conflicts'][0]
        self.assertFalse(conflict['baseNew']['exists'])
        self.assertTrue(conflict['instance']['exists']); self.assertIsNone(conflict['instance']['value'])

    def test_arrays_merge_atomically_and_index_overrides_are_authorized(self):
        self.templates[0]['allowedOverrides'] += ['/use/effects/0']
        a = self.instance(overrides={'/use/effects/0': 'manual'})
        self.templates[0]['revision'] = 2
        self.templates[0]['document']['use']['effects'] = ['updated']
        report = update_instances(self.root, self.templates, self.records(a))
        self.assertEqual(report['conflicts'][0]['pointer'], '/use/effects')
        self.assertEqual(report['instances'][0]['document']['use']['effects'], ['manual'])

    def test_removed_override_permission_is_explicit_conflict(self):
        a = self.instance(overrides={'/description': 'manual'})
        self.templates[0]['revision'] = 2
        self.templates[0]['allowedOverrides'] = ['/value']
        report = update_instances(self.root, self.templates, self.records(a))
        self.assertFalse(report['ok'])
        self.assertEqual(report['conflicts'][0]['reason'], 'override-permission-removed')

    def test_malformed_sidecars_fail_closed(self):
        a = self.instance()
        for field, value in [('lineage', None), ('lineage', [{}]), ('parameters', []), ('templateRevision', True)]:
            broken = copy.deepcopy(a); broken['sidecar'][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                update_instances(self.root, self.templates, self.records(broken))

    def test_unauthorized_manual_edit_tampered_sidecar_and_source_paths(self):
        a = self.instance()
        current = dict(a['document'], weight=99)
        (self.root / a['path']).write_text(json.dumps(current))
        with self.assertRaises(ValueError): update_instances(self.root, self.templates, self.records(a))
        a['sidecar']['expandedBase']['value'] = 999
        with self.assertRaises(ValueError): update_instances(self.root, self.templates, self.records(a))
        fresh = expand_template(self.templates, 'potion', 'new')
        for path in ('../outside.json', '/tmp/out.json', 'items/../items/new.json'):
            with self.assertRaises(ValueError): plan_instances(self.root, [{**fresh, 'path': path}])

    def test_update_refuses_concurrent_source_change(self):
        a = self.instance(); mutated = []
        def racing_plan(root, instances):
            if not mutated:
                current = read_json(self.root / a['path']); current['value'] = 777
                (self.root / a['path']).write_text(json.dumps(current)); mutated.append(True)
            return plan_instances(root, instances)
        with patch('rpgc_toolkit.templates.plan_instances', side_effect=racing_plan):
            with self.assertRaisesRegex(ValueError, 'stale candidate'):
                update_instances(self.root, self.templates, self.records(a))
        self.assertEqual(read_json(self.root / a['path'])['value'], 777)

    def test_candidates_guard_current_fingerprint_and_duplicate_identity(self):
        a = self.instance()
        plan = plan_instances(self.root, [a])
        self.assertEqual(plan['changes'][0]['expect'], a['sidecar']['baseFingerprint'])
        with self.assertRaises(ValueError): plan_instances(self.root, [a, a])
        with self.assertRaises(ValueError): plan_instances(self.root, [{**a, 'path': 'items/other.json'}])
        self.assertEqual(read_json(self.root / a['path']), a['document'])

    def object_fixture(self):
        (self.root / 'maps').mkdir()
        workflow = read_json(self.root / 'workflow.json'); workflow['kinds']['map'] = {'directory': 'maps'}
        (self.root / 'workflow.json').write_text(json.dumps(workflow))
        doc = {'schema': 'eve.rpgc.map', 'version': 1, 'id': 'village', 'layers': [
            {'id': 'actors', 'type': 'objectgroup', 'objects': [{'name': 'existing', 'type': 'npc', 'x': 0, 'y': 0}]}]}
        (self.root / 'maps/village.json').write_text(json.dumps(doc))
        group = {'format': 'rpgc.object-group-template', 'version': 1, 'id': 'pair', 'revision': 1,
                 'coordinateSpace': 'world', 'objects': [
                     {'name': 'a', 'type': 'npc', 'x': 5, 'y': -2,
                      'properties': [{'name': 'target', 'type': 'string', 'value': 'b'},
                                     {'name': 'text', 'type': 'string', 'value': 'b'}]},
                     {'name': 'b', 'type': 'npc', 'x': 6, 'y': 4}],
                 'nameReferences': [{'object': 'a', 'pointer': '/properties/0/value'}]}
        return doc, group

    def test_object_group_explicit_names_and_world_offset_no_projection(self):
        doc, group = self.object_fixture(); before = copy.deepcopy(group)
        report = instantiate_object_group(self.root, 'maps/village.json', 'actors', group, 'pair.one', {'a': 'one.a', 'b': 'one.b'}, [10, 20])
        objects = report['instances'][0]['document']['layers'][0]['objects']
        self.assertEqual((objects[1]['x'], objects[1]['y']), (15, 18))
        self.assertEqual(objects[1]['properties'][0]['value'], 'one.b')
        self.assertEqual(objects[1]['properties'][1]['value'], 'b')
        self.assertTrue(report['instances'][0]['sidecar']['staticInstantiation'])
        self.assertEqual(group, before); self.assertEqual(read_json(self.root / 'maps/village.json'), doc)
        for mapping in ({'a': 'one.a'}, {'a': 'same', 'b': 'same'}, {'a': 'existing', 'b': 'new'}):
            with self.assertRaises(ValueError):
                instantiate_object_group(self.root, 'maps/village.json', 'actors', group, 'pair.one', mapping)
        with self.assertRaises(ValueError):
            instantiate_object_group(self.root, 'maps/village.json', 'actors', group, 'pair.one', {'a': 'x', 'b': 'y'}, [True, 0])
        group['coordinateSpace'] = 'tile'
        with self.assertRaises(ValueError):
            instantiate_object_group(self.root, 'maps/village.json', 'actors', group, 'pair.one', {'a': 'x', 'b': 'y'})

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'requires real map candidate gate')
    def test_real_map_object_group_candidate_validates(self):
        template = read_json(ROOT / 'examples/templates/chest-group.json')
        path = 'content/maps/village-outskirts.json'
        before = (ROOT / path).read_bytes()
        report = instantiate_object_group(ROOT, path, 'actors', template, 'cache.example', {'cache': 'template_cache'})
        checked = check_templates(os.environ['RPGC_TEST_EVE'], ROOT, report)
        self.assertTrue(checked['ok'], checked)
        self.assertEqual((ROOT / path).read_bytes(), before)

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'requires real candidate gate')
    def test_real_example_expands_and_passes_existing_project_gate(self):
        templates = read_json(ROOT / 'examples/templates/potion-library.json')
        result = expand_template(templates, 'potion.development', 'potion.template-test', {'name': '模板候选药'})
        result['path'] = 'content/items/potion.template-test.json'
        plan = plan_instances(ROOT, [result])
        report = check_changes(os.environ['RPGC_TEST_EVE'], ROOT, plan)
        self.assertTrue(report['ok'], report)
        self.assertFalse((ROOT / result['path']).exists())


if __name__ == '__main__': unittest.main()
