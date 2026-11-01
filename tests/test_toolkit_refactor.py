import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.refactor import rename_changes
from rpgc_toolkit.changes import prepare_changes,candidate_workspace
from rpgc_toolkit.project import read_json

class RefactorTests(unittest.TestCase):
    def test_id_and_document_relative_paths_and_self_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for d in ('tilesets','maps'): (root/d).mkdir()
            (root/'workflow.json').write_text(json.dumps({'kinds':{k:{'directory':d} for k,d in [('tileset','tilesets'),('map','maps')]}}))
            (root/'tilesets/old.json').write_text(json.dumps({'id':'old','self':'old'}))
            (root/'maps/room.json').write_text(json.dumps({'id':'room','source':'../tilesets/old.json','atlas':'old'}))
            graph={'ok':True,'nodes':[{'id':'tileset/old'},{'id':'map/room'}],'edges':[
                {'source':'tileset/old','target':'tileset/old','path':'/self'},
                {'source':'map/room','target':'tileset/old','path':'/source'},
                {'source':'map/room','target':'tileset/old','path':'/atlas'}]}
            plan=rename_changes(root,graph,'tileset','old','new')
            with candidate_workspace(root,prepare_changes(root,plan)) as temp:
                self.assertFalse((temp/'tilesets/old.json').exists())
                self.assertEqual(read_json(temp/'tilesets/new.json'),{'id':'new','self':'new'})
                self.assertEqual(read_json(temp/'maps/room.json')['source'],'../tilesets/new.json')
                self.assertEqual(read_json(temp/'maps/room.json')['atlas'],'new')
            self.assertTrue((root/'tilesets/old.json').exists())
            graph['edges'][1]['path']='/missing'
            with self.assertRaises(ValueError): rename_changes(root,graph,'tileset','old','new')

if __name__=='__main__': unittest.main()
