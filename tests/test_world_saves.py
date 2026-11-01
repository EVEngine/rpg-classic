import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.world_saves import prepare_migration,publish_new,capture_world,check_world,migrate_world,_run

class MigrationTests(unittest.TestCase):
    def fixture(self):
        content={'map/old':'aaaa','item/old-item':'bbbb','event/old-event':'cccc','quest/q':'dddd'}
        target={'map/new':'aaaa','item/new-item':'bbbb','event/new-event':'cccc','quest/q':'dddd'}
        snapshot={'format':'eve.rpgc.world.snapshot','version':1,'content':content,'payload':{
            'world':{'mapId':'old','consumed':{'old/chest':True},'completedEvents':{'old-event':True},'quests':{'q':{'status':'claimed'}},'commandIds':{'game.1':'historical command'}},
            'inventory':{'stacks':[{'bagSlot':0,'itemId':'old-item','quantity':3}],'equipped':[]}}}
        step={'id':'rename','fromContent':content,'toContent':target,'maps':{'old':'new'},'items':{'old-item':'new-item'},'events':{'old-event':'new-event'},'objects':{'old/chest':'new/renamed-chest'}}
        return snapshot,{'format':'rpgc.world-migration-plan','version':1,'steps':[step]}

    def test_explicit_rename_preserves_quantities_history_and_source(self):
        snapshot,plan=self.fixture(); before=copy.deepcopy(snapshot); plan_before=copy.deepcopy(plan)
        result,history=prepare_migration(snapshot,plan)
        self.assertEqual(snapshot,before); self.assertEqual(plan,plan_before)
        self.assertEqual(result['payload']['world']['mapId'],'new')
        self.assertEqual(result['payload']['world']['consumed'],{'new/renamed-chest':True})
        self.assertEqual(result['payload']['world']['completedEvents'],{'new-event':True})
        self.assertEqual(result['payload']['inventory']['stacks'],[{'bagSlot':0,'itemId':'new-item','quantity':3}])
        self.assertEqual(result['payload']['world']['commandIds'],before['payload']['world']['commandIds'])
        history[0]['maps']['old']='mutation'
        self.assertEqual(plan,plan_before)

    def test_gaps_cycles_quest_changes_collision_and_unknown_steps_rejected(self):
        for mode in ('gap','cycle','quest','collision','unknown','future','precision'):
            snapshot,plan=self.fixture(); step=plan['steps'][0]
            if mode=='gap':step['fromContent']=dict(step['fromContent'],extra='x')
            if mode=='cycle':plan['steps'].append({'id':'back','fromContent':step['toContent'],'toContent':step['fromContent']})
            if mode=='quest':step['toContent']['quest/q']='changed'
            if mode=='collision':snapshot['payload']['world']['consumed']['new/renamed-chest']=False
            if mode=='unknown':step['dropUnknown']=True
            if mode=='future':snapshot['version']=2
            if mode=='precision':snapshot['payload']['inventory']['stacks'][0]['quantity']=16777217
            with self.subTest(mode=mode),self.assertRaises(ValueError):prepare_migration(snapshot,plan)

    def test_publication_never_overwrites_existing_or_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'save.json';publish_new(output,{'first':True})
            with self.assertRaises(FileExistsError):publish_new(output,{'second':True})
            self.assertEqual(json.loads(output.read_text()),{'first':True})
            link=Path(directory)/'linked.json';link.symlink_to(output)
            with self.assertRaises(FileExistsError):publish_new(link,{'second':True})
            self.assertEqual(json.loads(output.read_text()),{'first':True})
            self.assertFalse(list(Path(directory).glob('.rpgc-world-*')))

@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'real SDK required')
class WorldSaveAdapterTests(unittest.TestCase):
    def capture(self,request=None):
        if request is None:request=json.loads((ROOT/'examples/toolkit/world.capture.json').read_text())
        result=capture_world(os.environ['RPGC_TEST_EVE'],ROOT,request)
        self.assertTrue(result['ok'],result)
        return result

    def test_capture_restore_and_deferred_no_snapshot(self):
        result=self.capture();snapshot=result['value']['snapshot']
        restored=check_world(os.environ['RPGC_TEST_EVE'],ROOT,snapshot)
        self.assertTrue(restored['ok'],restored)
        self.assertEqual(restored['value']['state']['mapId'],'village-outskirts')
        bad=copy.deepcopy(snapshot);bad['payload']['world']['gold']=999
        self.assertFalse(check_world(os.environ['RPGC_TEST_EVE'],ROOT,bad)['ok'])
        request=json.loads((ROOT/'examples/toolkit/world.capture.json').read_text())
        request['context']={key:key=='battleActive' for key in ('eventActive','dialogueActive','battleActive','pendingDomainEvents','pendingTransfer')}
        deferred=self.capture(request)
        self.assertEqual(deferred['value']['status'],'deferred');self.assertNotIn('snapshot',deferred['value'])

    def test_real_continuous_content_migration_and_stale_source_refusal(self):
        snapshot=self.capture()['value']['snapshot']; current=copy.deepcopy(snapshot['content'])
        body=copy.deepcopy(snapshot);body.pop('checksum');old=copy.deepcopy(current)
        old['map/legacy-village']=old.pop('map/village-outskirts')
        body['content']=old;body['payload']['world']['mapId']='legacy-village'
        sealed=_run(os.environ['RPGC_TEST_EVE'],ROOT,body,'RpgcSave.seal(input)',120)['value']
        self.assertFalse(check_world(os.environ['RPGC_TEST_EVE'],ROOT,sealed)['ok'])
        intermediate=dict(old,**{'map/legacy-village':'intermediate-content'})
        plan={'format':'rpgc.world-migration-plan','version':1,'steps':[
            {'id':'intermediate','fromContent':old,'toContent':intermediate},
            {'id':'rename','fromContent':intermediate,'toContent':current,'maps':{'legacy-village':'village-outskirts'}}]}
        result=migrate_world(os.environ['RPGC_TEST_EVE'],ROOT,sealed,plan)
        self.assertTrue(result['ok'],result)
        self.assertEqual(result['value']['snapshot']['payload']['world']['mapId'],'village-outskirts')
        self.assertEqual(sealed['payload']['world']['mapId'],'legacy-village')
        self.assertEqual([x['id'] for x in result['migrations']],['intermediate','rename'])
        corrupted=copy.deepcopy(sealed);corrupted['checksum']='00000000'
        self.assertFalse(migrate_world(os.environ['RPGC_TEST_EVE'],ROOT,corrupted,plan)['ok'])
