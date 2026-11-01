import copy
import json
import os
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.narrative import compile_story, compile_quest
from rpgc_toolkit.runtime import run_headless


class NarrativeTests(unittest.TestCase):
    def story(self):
        return {'format':'rpgc.story-graph','version':1,'id':'story.sample','entry':'start','nodes':[
            {'id':'start','condition':{'kind':'always'},'then':'talk','else':'end'},
            {'id':'talk','action':{'kind':'message','reference':'story.greeting'},'next':'end'},
            {'id':'end','end':True}]}

    def test_branch_compilation_preserves_reference_and_input(self):
        graph=self.story(); before=copy.deepcopy(graph)
        candidate=compile_story(graph)
        self.assertEqual(candidate['steps'][0]['then'][0]['reference'],'story.greeting')
        self.assertEqual(candidate['steps'][0]['else'],[])
        self.assertEqual(graph,before)

    def test_cycles_dangling_and_unreachable(self):
        for mode in ('cycle','dangling','unreachable'):
            graph=self.story()
            if mode=='cycle': graph['nodes'][1]['next']='start'
            if mode=='dangling': graph['nodes'][1]['next']='missing'
            if mode=='unreachable': graph['nodes'].append({'id':'unused','end':True})
            with self.subTest(mode=mode),self.assertRaises(ValueError): compile_story(graph)

    def quest(self):
        return {'format':'rpgc.quest-plan','version':1,'id':'delivery','stages':[
            {'id':'accept','trigger':{'kind':'manual'},'steps':[{'kind':'message','reference':'quest.accept'}]},
            {'id':'reward','trigger':{'kind':'manual'},'steps':[{'kind':'set_variable','name':'gold','op':'add','value':10}]}]}

    def test_quest_guards_reward_and_advances_only_after_actions(self):
        plan=self.quest(); before=copy.deepcopy(plan)
        result=compile_quest(plan)
        reward=result['events'][1]['steps'][0]
        self.assertEqual(reward['condition']['value'],1)
        self.assertEqual(reward['then'][-1]['value'],2)
        self.assertEqual(result['variable'],'quest.delivery.stage')
        self.assertEqual(plan,before)

    def test_duplicate_stage_rejected(self):
        plan=self.quest(); plan['stages'][1]['id']='accept'
        with self.assertRaises(ValueError): compile_quest(plan)

    def test_stage_condition_and_duplicate_automatic_triggers(self):
        plan=self.quest()
        plan['stages'][1]['condition']={'kind':'variable','name':'deliveries','compare':'gte','value':1}
        candidate=compile_quest(plan)['events'][1]
        self.assertEqual(candidate['steps'][0]['op'],'set')
        self.assertEqual(candidate['steps'][-1]['condition']['value'],2)
        for stage in plan['stages']: stage['trigger']={'kind':'game_started'}
        with self.assertRaises(ValueError): compile_quest(plan)
        plan=self.quest()
        plan['stages'][0]['trigger']={'kind':'object_interacted','mapId':'village-outskirts','objectName':'elder'}
        plan['stages'][1]['trigger']=dict(plan['stages'][0]['trigger'],questId='unused')
        with self.assertRaises(ValueError): compile_quest(plan)

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'set RPGC_TEST_EVE for VM candidate validation')
    def test_compiled_candidates_pass_authoritative_event_gate(self):
        plan=self.quest()
        plan['stages'][1]['condition']={'kind':'always'}
        docs=[compile_story(self.story())]+compile_quest(plan)['events']
        for doc in docs:
            raw=json.dumps(json.dumps(doc,ensure_ascii=False),ensure_ascii=False)
            source=f'RpgcToolkitResult <- RpgcValidate.reportJson(RpgcValidate.validateDocument("event", RpgcJson.parse({raw}).value));'
            with self.subTest(id=doc['id']):
                self.assertTrue(run_headless(os.environ['RPGC_TEST_EVE'],ROOT,source)['ok'])

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'requires real gameplay adapter functions')
    def test_quest_guard_executes_real_gameplay_functions_once(self):
        plan=self.quest()
        plan['stages'][1]['condition']={'kind':'variable','name':'deliveries','compare':'gte','value':1}
        docs=compile_quest(plan)['events']
        raw=json.dumps(json.dumps(docs,ensure_ascii=False),ensure_ascii=False)
        source=('import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"\n'
                'import { RpgcEventRunner } from "game:/lib/rpgc_event_runner.nut"\n'
                'function executeEvent(doc,state) {\n'
                ' local started=RpgcEventRunner.newSession(doc,state,{message=true});\n'
                ' if (!started.ok) throw RpgcJson.encodeCompact(started);\n'
                ' local session=started.value; local acks=[];\n'
                ' for (local i=0;i<100;i+=1) {\n'
                '  local result=RpgcEventRunner.tick(session,state,0.1,acks); acks=[];\n'
                '  if (!result.ok) throw RpgcJson.encodeCompact(result);\n'
                '  foreach(request in result.value.requests) acks.append({operationId=request.operationId,ok=true});\n'
                '  if(session.status=="completed") return;\n'
                ' } throw "event did not complete"; }\n'
                f'local events=RpgcJson.parse({raw}).value;\n'+
                'local state=RpgcWorldState.create().value;\n'
                'executeEvent(events[1],state); local before=state.gold;\n'
                'executeEvent(events[0],state); executeEvent(events[1],state); local blocked=state.gold;\n'
                'RpgcWorldState.apply(state,{commandId="delivery",kind="set_variable",name="deliveries",op="set",value=1});\n'
                'executeEvent(events[1],state); local rewarded=state.gold;\n'
                'executeEvent(events[1],state);\n'
                'RpgcToolkitResult <- RpgcJson.encodeCompact({before=before,blocked=blocked,rewarded=rewarded,after=state.gold});')
        report=run_headless(os.environ['RPGC_TEST_EVE'],ROOT,source)
        self.assertEqual(report,{'before':0,'blocked':0,'rewarded':10,'after':10})

if __name__=='__main__': unittest.main()
