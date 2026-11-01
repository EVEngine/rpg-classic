"""Public W4 command adapters retain guarded candidate and conflict semantics."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc import build_parser
from rpgc_toolkit.cli import execute
from rpgc_toolkit.project import fingerprint,read_json


class W4CommandTests(unittest.TestCase):
    def arguments(self,*words):
        return build_parser().parse_args(['--root',str(ROOT),*words])

    def test_terrain_report_has_actual_changes_and_source_guard(self):
        path='content/maps/village-outskirts.json'
        report=execute(self.arguments('toolkit','terrain',path,'--layer','terrain',
            '--cells',str(ROOT/'examples/toolkit/terrain.blob8.cells.json'),
            '--rules',str(ROOT/'examples/toolkit/terrain.blob8.json'),'--change-set'))
        self.assertEqual(report['changedCells'],3)
        self.assertEqual(report['bounds'],{'minX':0,'minY':0,'maxX':1,'maxY':1})
        self.assertEqual(report['changeSet']['changes'][0]['expect'],fingerprint(read_json(ROOT/path)))
        self.assertFalse(report['applied'])
        self.assertFalse(report['validated'])

    def test_database_and_map_object_requests_use_existing_candidate_shape(self):
        for operation,filename in [('expand','expand.request.json'),('objects','objects.request.json')]:
            report=execute(self.arguments('toolkit','template',operation,str(ROOT/'examples/templates'/filename)))
            self.assertTrue(report['ok'])
            self.assertEqual(report['changeSet']['format'],'rpgc.change-set')
            self.assertFalse(report['applied'])
            self.assertFalse(report['validated'])
            self.assertTrue(report['instances'])
        self.assertFalse((ROOT/'content/items/potion.template-example.json').exists())

    def test_unknown_template_request_field_is_rejected(self):
        request=read_json(ROOT/'examples/templates/expand.request.json')
        request['execute']='arbitrary'
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'request.json';path.write_text(json.dumps(request))
            with self.assertRaises(ValueError):
                execute(self.arguments('toolkit','template','expand',str(path)))
