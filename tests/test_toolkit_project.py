import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import rpgc
from rpgc_toolkit.project import Project, fingerprint, inside, patch_document, read_json


class ProjectTests(unittest.TestCase):
    def test_real_catalog_uses_manifest_and_schema(self):
        project = Project(ROOT)
        result = project.catalog()
        self.assertGreater(result['count'], 100)
        self.assertEqual({x['kind'] for x in result['documents']}, set(project.kinds))
        self.assertEqual(project.schema('skill')['id'], 'eve.rpgc.skill')
        self.assertFalse(result['validated'])

    def test_patch_is_atomic_and_handles_escaped_keys_and_arrays(self):
        doc = {'a/b': {'~x': [1, 2]}, 'flag': True}
        result = patch_document(doc, [
            {'op':'test','path':'/flag','value':True},
            {'op':'add','path':'/a~1b/~0x/1','value':3},
            {'op':'remove','path':'/a~1b/~0x/0'},
            {'op':'replace','path':'/flag','value':False}])
        self.assertEqual(result, {'a/b': {'~x': [3, 2]}, 'flag':False})
        self.assertEqual(doc, {'a/b': {'~x': [1, 2]}, 'flag':True})
        with self.assertRaises(ValueError):
            patch_document(doc, [{'op':'replace','path':'/flag','value':False},
                                 {'op':'remove','path':'/missing'}])
        self.assertTrue(doc['flag'])

    def test_stale_fingerprint_and_json_test_semantics(self):
        doc = {'flag':True}
        with self.assertRaises(ValueError):
            patch_document(doc, [], expected='stale')
        with self.assertRaises(ValueError):
            patch_document(doc, [{'op':'test','path':'/flag','value':1}])
        self.assertEqual(patch_document(doc, [], fingerprint(doc)), doc)
        self.assertEqual(fingerprint({'b':1,'a':2}), fingerprint({'a':2,'b':1}))

    def test_malformed_pointer_and_array_indices(self):
        for path in ('a', '/~2', '/xs/-1', '/xs/01', '/xs/9', '/xs/-'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                patch_document({'xs':[1,2]}, [{'op':'remove','path':path}])
        self.assertEqual(patch_document({'xs':[]}, [{'op':'add','path':'/xs/-','value':1}]), {'xs':[1]})

    def test_strict_json_and_path_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p = root / 'bad.json'
            for text in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":1e999}'):
                p.write_text(text)
                with self.assertRaises(ValueError):
                    read_json(p)
            for path in ('../out', '/etc/passwd'):
                with self.assertRaises(ValueError):
                    inside(root, path)
            (root / 'escape').symlink_to('/tmp')
            with self.assertRaises(ValueError):
                inside(root, 'escape/foo')

    def test_offline_cli_does_not_require_engine_and_emits_errors(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = rpgc.main(['--eve','/no/engine','toolkit','catalog','--kind','item'])
        self.assertEqual(status, 0)
        self.assertGreater(json.loads(output.getvalue())['count'], 0)
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = rpgc.main(['toolkit','catalog','--kind','unknown'])
        self.assertEqual(status, 1)
        self.assertFalse(json.loads(errors.getvalue())['ok'])

    def test_candidate_cli_round_trip(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = rpgc.main(['toolkit','clone','content/items/potion.heal.json','potion.test'])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())['id'], 'potion.test')
        self.assertFalse((ROOT / 'content/items/potion.test.json').exists())


if __name__ == '__main__':
    unittest.main()
