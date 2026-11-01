import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.changes import prepare_changes,candidate_workspace,check_changes
from rpgc_toolkit.saves import migrate_inventory,check_inventory
from rpgc_toolkit.project import fingerprint,read_json


class ChangesTests(unittest.TestCase):
    def test_preview_and_stale_sources(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'items').mkdir()
            (root/'workflow.json').write_text(json.dumps({'kinds':{'item':{'directory':'items'}}}))
            doc={'id':'a','value':1}; (root/'items/a.json').write_text(json.dumps(doc))
            (root/'candidate.json').write_text(json.dumps({'id':'a','value':2}))
            plan={'format':'rpgc.change-set','version':1,'changes':[{'path':'items/a.json','source':'candidate.json','expect':fingerprint(doc)}]}
            prepared=prepare_changes(root,plan)
            with candidate_workspace(root,prepared) as workspace:
                self.assertEqual(read_json(workspace/'items/a.json')['value'],2)
                self.assertEqual(read_json(root/'items/a.json')['value'],1)
            self.assertFalse(workspace.exists())
            plan['changes'][0]['expect']='stale'
            with self.assertRaises(ValueError): prepare_changes(root,plan)

    def test_paths_duplicates_and_deletion_preconditions(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'items').mkdir()
            (root/'workflow.json').write_text(json.dumps({'kinds':{'item':{'directory':'items'}}}))
            for path in ('../escape.json','workflow.json','items/missing.json'):
                plan={'format':'rpgc.change-set','version':1,'deletions':[{'path':path}]}
                with self.subTest(path=path),self.assertRaises(ValueError): prepare_changes(root,plan)

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'requires real VM')
    def test_cross_document_failure_leaves_original_untouched(self):
        path='content/skills/skill.strike.json'
        before=(ROOT/path).read_bytes()
        plan={'format':'rpgc.change-set','version':1,'deletions':[{'path':path}]}
        result=check_changes(os.environ['RPGC_TEST_EVE'],ROOT,plan)
        self.assertFalse(result['ok'])
        self.assertFalse(result['applied'])
        self.assertEqual((ROOT/path).read_bytes(),before)
        self.assertTrue(any(d['code']=='ref.dangling' for d in result['diagnostics']))


class SaveTests(unittest.TestCase):
    def snapshot(self):
        return {'format':'eve.rpgc.items.snapshot','version':1,'id':'party','slotCount':4,
                'maxWeight':0,'maxVolume':0,'capacityPolicy':'reject',
                'stacks':[{'bagSlot':0,'itemId':'potion.old','quantity':3}],'equipped':[]}

    def test_migration_preserves_stacks_and_input(self):
        doc=self.snapshot(); before=copy.deepcopy(doc)
        result=migrate_inventory(doc,{'potion.old':'potion.heal'},expected=fingerprint(doc))
        self.assertEqual(result['stacks'][0],{'bagSlot':0,'itemId':'potion.heal','quantity':3})
        self.assertEqual(doc,before)

    def test_conflicts_and_unknown_versions(self):
        doc=self.snapshot()
        with self.assertRaises(ValueError): migrate_inventory(doc,expected='stale')
        huge=self.snapshot(); huge['stacks'][0]['quantity']=4294967297
        with self.assertRaises(ValueError): migrate_inventory(huge)
        doc['version']=2
        with self.assertRaises(ValueError): migrate_inventory(doc)
        doc=self.snapshot(); doc['stacks'].append(dict(doc['stacks'][0]))
        with self.assertRaises(ValueError): migrate_inventory(doc)
        doc=self.snapshot(); doc['equipped']=[{'slot':'hand','itemId':'a'},{'slot':'body','itemId':'b'}]
        with self.assertRaises(ValueError): migrate_inventory(doc,equipment_slots={'body':'hand'})

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'requires real VM')
    def test_real_restore_checks_ids(self):
        doc=migrate_inventory(self.snapshot(),{'potion.old':'potion.heal'})
        good=check_inventory(os.environ['RPGC_TEST_EVE'],ROOT,doc)
        self.assertTrue(good['ok'])
        bad=check_inventory(os.environ['RPGC_TEST_EVE'],ROOT,self.snapshot())
        self.assertFalse(bad['ok'])

if __name__=='__main__': unittest.main()
