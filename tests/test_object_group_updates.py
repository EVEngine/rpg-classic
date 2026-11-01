"""Object-group update contract: authoring candidates, provenance and real gates."""
import contextlib
from copy import deepcopy
from io import StringIO
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import rpgc
from rpgc_toolkit import templates as toolkit
from rpgc_toolkit.project import read_json
from rpgc_toolkit.changes import candidate_workspace


def group():
    return {'format': 'rpgc.object-group-template', 'version': 1, 'id': 'cache.group', 'revision': 1,
            'coordinateSpace': 'world', 'objects': [
                {'name': 'cache', 'type': 'chest', 'x': 3648, 'y': 1280,
                 'properties': [{'name': 'itemId', 'type': 'string', 'value': 'potion.heal'},
                                {'name': 'gold', 'type': 'string', 'value': '5'}]},
                {'name': 'retired', 'type': 'chest', 'x': 3776, 'y': 1344,
                 'properties': [{'name': 'itemId', 'type': 'string', 'value': 'potion.heal'},
                                {'name': 'gold', 'type': 'string', 'value': '1'}]}], 'nameReferences': []}


def objects(document):
    return next(layer['objects'] for layer in document['layers'] if layer['id'] == 'actors')


def by_name(document, name):
    return next(obj for obj in objects(document) if obj['name'] == name)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


class ObjectGroupUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.path = 'maps/village.json'
        write(self.root / 'workflow.json', {'kinds': {'map': {'directory': 'maps'}}})
        self.original = {'schema': 'eve.rpgc.map', 'version': 1, 'id': 'village',
                         'layers': [{'id': 'actors', 'type': 'objectgroup', 'objects': [{'name': 'spawn', 'type': 'spawn', 'x': 0, 'y': 0}]}]}
        write(self.root / self.path, self.original)
        self.template = group()

    def install(self, prefix='one', offset=(0, 0)):
        report = toolkit.instantiate_object_group(self.root, self.path, 'actors', self.template,
                                                   prefix, {'cache': prefix+'.cache', 'retired': prefix+'.retired'}, offset)
        write(self.root / self.path, report['changeSet']['changes'][0]['document'])
        old = report['instances'][0]['sidecar']
        upgraded = toolkit.update_object_groups(self.root, [self.template], [{'path': self.path, 'sidecar': old}], previous_templates=[self.template])
        return upgraded['instances'][0]['sidecar']

    def update(self, template, records):
        return toolkit.update_object_groups(self.root, [template], records)

    def cli(self, operation, request):
        source = self.root / 'request.json'; write(source, request)
        output, errors = StringIO(), StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = rpgc.main(['--root', str(self.root), 'toolkit', 'template', operation, str(source)])
        return status, json.loads(output.getvalue() or errors.getvalue())

    def test_manual_coordinate_and_property_preserved_independent_template_update(self):
        sidecar = self.install()
        current = read_json(self.root / self.path)
        obj = by_name(current, 'one.cache'); obj['x'] += 16
        obj['properties'][1]['value'] = '9'
        write(self.root / self.path, current); before = (self.root / self.path).read_bytes()
        newer = deepcopy(self.template); newer['revision'] = 2
        newer['objects'][0]['properties'][0]['value'] = 'potion.focus'
        result = self.update(newer, [{'path': self.path, 'sidecar': sidecar}])
        self.assertTrue(result['ok'], result)
        merged = by_name(result['changeSet']['changes'][0]['document'], 'one.cache')
        self.assertEqual(merged['x'], obj['x'])
        self.assertEqual({p['name']: p['value'] for p in merged['properties']}, {'itemId': 'potion.focus', 'gold': '9'})
        self.assertEqual((self.root / self.path).read_bytes(), before)

    def test_conflict_on_one_instance_excludes_whole_shared_map(self):
        a = self.install('one'); b = self.install('two', (256, 0))
        current = read_json(self.root / self.path); by_name(current, 'one.cache')['x'] += 16
        write(self.root / self.path, current); before = (self.root / self.path).read_bytes()
        newer = deepcopy(self.template); newer['revision'] = 2; newer['objects'][0]['x'] += 32
        result = self.update(newer, [{'path': self.path, 'sidecar': a}, {'path': self.path, 'sidecar': b}])
        self.assertFalse(result['ok']); self.assertTrue(result['conflicts'])
        self.assertEqual(result['changeSet']['changes'], [])
        self.assertTrue(any(c['instanceId'] == 'one' and c['pointer'].endswith('/x') for c in result['conflicts']))
        with self.assertRaises(ValueError): toolkit.check_templates('unused', self.root, result)
        self.assertEqual((self.root / self.path).read_bytes(), before)

    def test_add_delete_and_two_instances_are_combined_once(self):
        a = self.install('one'); b = self.install('two', (256, 0))
        newer = deepcopy(self.template); newer['revision'] = 2
        added = deepcopy(newer['objects'][1]); added['name'] = 'fresh'; added['x'] += 64
        newer['objects'] = [newer['objects'][0], added]
        result = self.update(newer, [{'path': self.path, 'sidecar': sidecar,
            'nameMap': {'cache': prefix+'.cache', 'fresh': prefix+'.fresh'}} for prefix, sidecar in [('one', a), ('two', b)]])
        self.assertTrue(result['ok'], result); self.assertEqual(len(result['changeSet']['changes']), 1)
        merged = result['changeSet']['changes'][0]['document']
        self.assertEqual({o['name'] for o in objects(merged)}, {'spawn', 'one.cache', 'one.fresh', 'two.cache', 'two.fresh'})
        self.assertEqual(by_name(merged, 'two.fresh')['x'] - by_name(merged, 'one.fresh')['x'], 256)
        self.assertEqual(len(result['instances']), 2)

    def test_template_deletion_of_manually_changed_object_conflicts(self):
        sidecar = self.install(); current = read_json(self.root / self.path)
        by_name(current, 'one.retired')['y'] += 9; write(self.root / self.path, current)
        newer = deepcopy(self.template); newer['revision'] = 2; newer['objects'].pop()
        result = self.update(newer, [{'path': self.path, 'sidecar': sidecar}])
        self.assertFalse(result['ok']); self.assertEqual(result['changeSet']['changes'], [])
        self.assertTrue(any(c['object'] in ('retired', 'one.retired') for c in result['conflicts']))

    def test_explicit_rename_preserves_instance_manual_value(self):
        sidecar = self.install(); current = read_json(self.root / self.path)
        by_name(current, 'one.cache')['x'] += 7; write(self.root / self.path, current)
        newer = deepcopy(self.template); newer['revision'] = 2; newer['objects'][0]['name'] = 'renamed'
        result = self.update(newer, [{'path': self.path, 'sidecar': sidecar,
            'nameMap': {'renamed': 'one.renamed', 'retired': 'one.retired'}, 'renames': {'cache': 'renamed'}}])
        self.assertTrue(result['ok'], result)
        merged = result['changeSet']['changes'][0]['document']
        self.assertEqual(by_name(merged, 'one.renamed')['x'], by_name(current, 'one.cache')['x'])
        self.assertNotIn('one.cache', {o['name'] for o in objects(merged)})

    def test_bad_sidecar_and_duplicate_claims_rejected(self):
        sidecar = self.install()
        variants = []
        bad = deepcopy(sidecar); bad['expandedObjects'][0]['x'] += 1; variants.append(bad)
        bad = deepcopy(sidecar); bad['path'] = 'maps/elsewhere.json'; variants.append(bad)
        bad = deepcopy(sidecar); bad['nameMap']['cache'] = 'spawn'; variants.append(bad)
        bad = deepcopy(sidecar); bad['worldOffset'] = [True, 0]; variants.append(bad)
        bad = deepcopy(sidecar); bad['unknown'] = True; variants.append(bad)
        for bad in variants:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.update(self.template, [{'path': self.path, 'sidecar': bad}])
        with self.assertRaises(ValueError):
            self.update(self.template, [{'path': self.path, 'sidecar': sidecar}]*2)

    def test_new_name_collision_cannot_replace_unowned_objects(self):
        sidecar = self.install(); newer = deepcopy(self.template); newer['revision'] = 2
        new = deepcopy(newer['objects'][0]); new['name'] = 'new'; newer['objects'].append(new)
        result = self.update(newer, [{'path': self.path, 'sidecar': sidecar,
            'nameMap': {'cache': 'one.cache', 'retired': 'one.retired', 'new': 'spawn'}}])
        self.assertFalse(result['ok']); self.assertEqual(result['changeSet']['changes'], [])

    def test_cross_instance_name_takeover_is_rejected_in_either_order(self):
        a = self.install('one'); b = self.install('two', (256, 0))
        original = (self.root / self.path).read_bytes()
        newer = deepcopy(self.template); newer['revision'] = 2
        records = [{'path': self.path, 'sidecar': a, 'nameMap': {'cache': 'two.cache', 'retired': 'one.retired'}},
                   {'path': self.path, 'sidecar': b, 'nameMap': {'cache': 'two.moved', 'retired': 'two.retired'}}]
        for ordered in (records, records[::-1]):
            result = self.update(newer, ordered)
            self.assertFalse(result['ok']); self.assertEqual(result['changeSet']['changes'], [])
        self.assertEqual((self.root / self.path).read_bytes(), original)

    def test_v1_sidecar_upgrade_requires_exact_previous_template(self):
        initial = toolkit.instantiate_object_group(self.root, self.path, 'actors', self.template, 'legacy',
                    {'cache': 'legacy.cache', 'retired': 'legacy.retired'})
        write(self.root / self.path, initial['changeSet']['changes'][0]['document'])
        sidecar = initial['instances'][0]['sidecar']; self.assertEqual(sidecar['version'], 1)
        records = [{'path': self.path, 'sidecar': sidecar}]
        with self.assertRaises(ValueError): self.update(self.template, records)
        stale = deepcopy(self.template); stale['objects'][0]['x'] += 1
        with self.assertRaises(ValueError):
            toolkit.update_object_groups(self.root, [self.template], records, previous_templates=[stale])
        upgraded = toolkit.update_object_groups(self.root, [self.template], records, previous_templates=[self.template])
        self.assertTrue(upgraded['ok']); second = upgraded['instances'][0]['sidecar']
        self.assertEqual(second['version'], 2); self.assertIn('baseFingerprint', second)
        self.assertTrue(self.update(self.template, [{'path': self.path, 'sidecar': second}])['ok'])
        status, cli_upgraded = self.cli('objects-update', {'templates': [self.template], 'instances': records, 'previousTemplates': [self.template]})
        self.assertEqual(status, 0, cli_upgraded)

    def test_manual_deletion_is_preserved_until_template_changes_deleted_object(self):
        sidecar = self.install(); current = read_json(self.root / self.path)
        objects(current).remove(by_name(current, 'one.retired')); write(self.root / self.path, current)
        result = self.update(self.template, [{'path': self.path, 'sidecar': sidecar}])
        self.assertTrue(result['ok'], result)
        self.assertNotIn('one.retired', {obj['name'] for obj in objects(result['changeSet']['changes'][0]['document'])})
        newer = deepcopy(self.template); newer['revision'] = 2; newer['objects'][1]['x'] += 1
        result = self.update(newer, [{'path': self.path, 'sidecar': sidecar}])
        self.assertFalse(result['ok']); self.assertEqual(result['changeSet']['changes'], [])

    def test_cli_clean_conflict_and_bad_request(self):
        sidecar = self.install(); newer = deepcopy(self.template); newer['revision'] = 2; newer['objects'][0]['x'] += 2
        request = {'templates': [newer], 'instances': [{'path': self.path, 'sidecar': sidecar}]}
        status, report = self.cli('objects-update', request)
        self.assertEqual(status, 0, report); self.assertTrue(report['ok'])
        current = read_json(self.root / self.path); by_name(current, 'one.cache')['x'] += 9
        write(self.root / self.path, current)
        status, report = self.cli('objects-update', request)
        self.assertEqual(status, 1, report); self.assertFalse(report['ok'])
        status, refused = self.cli('check', report)
        self.assertEqual(status, 1); self.assertFalse(refused['ok'])
        status, malformed = self.cli('objects-update', {'templates': [], 'instances': [], 'command': 'not-run'})
        self.assertEqual(status, 1); self.assertFalse(malformed['ok'])

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'requires full native candidate gate')
    def test_real_sdk_update_accepts_new_objects_preserves_source(self):
        original = (ROOT / 'content/maps/village-outskirts.json').read_bytes()
        with candidate_workspace(ROOT, []) as sandbox:
            path = 'content/maps/village-outskirts.json'; template = group()
            initial = toolkit.instantiate_object_group(sandbox, path, 'actors', template, 'real',
                {'cache': 'update_cache', 'retired': 'update_retired'})
            write(sandbox / path, initial['changeSet']['changes'][0]['document'])
            sidecar = initial['instances'][0]['sidecar']
            current = read_json(sandbox / path); by_name(current, 'update_cache')['x'] += 16
            write(sandbox / path, current); before = (sandbox / path).read_bytes()
            newer = deepcopy(template); newer['revision'] = 2; newer['objects'][0]['properties'][1]['value'] = '15'
            result = toolkit.update_object_groups(sandbox, [newer], [{'path': path, 'sidecar': sidecar}], previous_templates=[template])
            self.assertTrue(result['ok'], result)
            gate = toolkit.check_templates(os.environ['RPGC_TEST_EVE'], sandbox, result)
            self.assertTrue(gate['ok'], gate)
            self.assertEqual((sandbox / path).read_bytes(), before)
        self.assertEqual((ROOT / 'content/maps/village-outskirts.json').read_bytes(), original)


if __name__ == '__main__': unittest.main()
