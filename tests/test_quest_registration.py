"""Quest definitions must pass the same isolated project gate as other content."""
import copy
import json
import os
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.changes import check_changes

@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'real SDK required')
class QuestRegistrationTests(unittest.TestCase):
    def test_project_gate_rejects_dependency_cycle_and_missing_reward_item(self):
        original=json.loads((ROOT/'content/quests/quest.toolkit-guide.json').read_text())
        a=copy.deepcopy(original);a['id']='quest.cycle-a';a['dependencies']=['quest.cycle-b']
        b=copy.deepcopy(original);b['id']='quest.cycle-b';b['dependencies']=['quest.cycle-a']
        missing=copy.deepcopy(original);missing['rewards'][1]['itemId']='missing.reward'
        for documents,expected in (([a,b],'cycle'),([missing],'missing.reward')):
            specification={'format':'rpgc.change-set','version':1,'changes':[
                {'path':f"content/quests/{doc['id']}.json",'document':doc} for doc in documents]}
            with self.subTest(expected=expected):
                result=check_changes(os.environ['RPGC_TEST_EVE'],ROOT,specification)
                self.assertFalse(result['ok'],result)
                self.assertIn(expected,json.dumps(result['diagnostics']))
        self.assertEqual(original,json.loads((ROOT/'content/quests/quest.toolkit-guide.json').read_text()))
        self.assertFalse((ROOT/'content/quests/quest.cycle-a.json').exists())
