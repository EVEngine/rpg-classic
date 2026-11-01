import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from rpgc_toolkit.assets import audit_assets
from rpgc_toolkit.build import build_bundle, verify_bundle, MANIFEST


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'project'
        self.root.mkdir()
        (self.root / 'content').mkdir()
        (self.root / 'workflow.json').write_text(json.dumps({'kinds': {'anim': {'directory': 'content'}}}))
        self.doc = {'image': 'hero.png', 'frameWidth': 16, 'frameHeight': 24, 'columns': 2, 'rows': 3}
        self.write_doc()
        # IHDR-only fixture: audit promises header inspection, not decoding.
        (self.root / 'content/hero.png').write_bytes(b'\x89PNG\r\n\x1a\n\0\0\0\rIHDR' + struct.pack('>II', 32, 72))

    def write_doc(self):
        (self.root / 'content/hero.json').write_text(json.dumps(self.doc))

    def test_audit_hash_and_grid(self):
        report = audit_assets(self.root)
        self.assertTrue(report['ok'])
        self.assertEqual(report['assets'][0]['width'], 32)
        self.assertEqual(report['assets'][0]['sha256'], hashlib.sha256((self.root / 'content/hero.png').read_bytes()).hexdigest())
        self.doc['rows'] = 4
        self.write_doc()
        self.assertEqual(audit_assets(self.root)['diagnostics'][0]['code'], 'asset.dimensions')

    def test_missing_and_escape(self):
        (self.root / 'content/hero.png').unlink()
        self.assertEqual(audit_assets(self.root)['diagnostics'][0]['code'], 'asset.missing')
        self.doc['image'] = '../../outside.png'
        self.write_doc()
        self.assertFalse(audit_assets(self.root)['ok'])

    def test_internal_symlink_refused(self):
        (self.root / 'content/link.png').symlink_to('hero.png')
        self.doc['image'] = 'link.png'
        self.write_doc()
        self.assertFalse(audit_assets(self.root)['ok'])

    def test_bundle_reproducible_and_exclusions(self):
        (self.root / '.git').mkdir()
        (self.root / '.git/secret').write_text('not source')
        (self.root / 'eve.log').write_text('runtime')
        first = Path(self.temp.name) / 'first.zip'
        second = Path(self.temp.name) / 'second.zip'
        self.assertFalse(build_bundle(self.root, first)['validated'])
        build_bundle(self.root, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertTrue(verify_bundle(first)['ok'])
        with zipfile.ZipFile(first) as z:
            self.assertNotIn('eve.log', z.namelist())
            self.assertNotIn('.git/secret', z.namelist())
        with self.assertRaises(ValueError):
            build_bundle(self.root, first)

    def test_bundle_tamper_rejected(self):
        bundle = Path(self.temp.name) / 'bundle.zip'
        build_bundle(self.root, bundle)
        with zipfile.ZipFile(bundle) as z:
            entries = {n: z.read(n) for n in z.namelist()}
        entries['content/hero.png'] = b'tampered'
        with zipfile.ZipFile(bundle, 'w') as z:
            for name, data in entries.items():
                z.writestr(name, data)
        self.assertFalse(verify_bundle(bundle)['ok'])

    def test_bundle_symlink_rejected(self):
        (self.root / 'linked').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):
            build_bundle(self.root, Path(self.temp.name) / 'bundle.zip')

    def test_audit_missing_directory_and_duplicate_keys(self):
        workflow = self.root / 'workflow.json'
        workflow.write_text('{"kinds":{"anim":{"directory":"absent"}}}')
        self.assertEqual(audit_assets(self.root)['diagnostics'][0]['code'], 'asset.project')
        workflow.write_text('{"kinds":{"anim":{"directory":"content"}}}')
        (self.root / 'content/hero.json').write_text('{"image":"a.png","image":"hero.png"}')
        self.assertFalse(audit_assets(self.root)['ok'])
        workflow.write_text('{"kinds":{},"kinds":{"anim":{"directory":"content"}}}')
        self.assertFalse(audit_assets(self.root)['ok'])

    def test_bundle_output_location_and_repeat(self):
        (self.root / 'releases').mkdir()
        for path in [self.root / 'bundle.zip', self.root / 'releases/bundle.zip']:
            with self.assertRaises(ValueError):
                build_bundle(self.root, path)
        (self.root / 'dist').mkdir()
        first, second = self.root / 'dist/one.zip', self.root / 'dist/two.zip'
        build_bundle(self.root, first)
        build_bundle(self.root, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertTrue(verify_bundle(second)['ok'])

    def test_bundle_nonportable_source_name(self):
        (self.root / 'bad:name').write_text('bad')
        with self.assertRaises(ValueError):
            build_bundle(self.root, Path(self.temp.name) / 'bundle.zip')

    def test_bundle_malformed_manifest(self):
        bundle = Path(self.temp.name) / 'bad.zip'
        base = {'format': 'rpgc-source-bundle', 'version': 1}
        malformed = [None, [], 'oops', {}, dict(base, files=None), dict(base, files={}),
                     dict(base, files=[None]), dict(base, files=[[]]),
                     dict(base, files=[{'path': []}]), dict(base, files=[{'path': 'x', 'bytes': True, 'sha256': '0' * 64}])]
        for document in malformed:
            with self.subTest(document=document):
                with zipfile.ZipFile(bundle, 'w') as z:
                    z.writestr(MANIFEST, json.dumps(document))
                self.assertFalse(verify_bundle(bundle)['ok'])
        with zipfile.ZipFile(bundle, 'w') as z:
            z.writestr(MANIFEST, '{"format":"rpgc-source-bundle","version":1,"files":[],"files":[]}')
        self.assertFalse(verify_bundle(bundle)['ok'])

    def test_bundle_traversal_rejected(self):
        bundle = Path(self.temp.name) / 'bad.zip'
        with zipfile.ZipFile(bundle, 'w') as z:
            z.writestr('../escape', b'no')
            z.writestr(MANIFEST, '{}')
        self.assertFalse(verify_bundle(bundle)['ok'])


if __name__ == '__main__':
    unittest.main()
