"""Candidate isolation, diagnostic previews, diffs and owned-window lifecycle."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.map_diff import map_diff
from rpgc_toolkit.map_preview import render_map, open_map, _render_map_workspace, validate_actions
from rpgc_toolkit.project import read_json, fingerprint


class MapDiffTests(unittest.TestCase):
    def test_resize_compares_coordinates_not_flat_indices_and_preserves_objects(self):
        before = {'id':'test','width':2,'height':2,'layers':[
            {'id':'tiles','type':'tilelayer','data':[1,2,3,4]},
            {'id':'objects','type':'objectgroup','objects':[{'name':'a','x':1,'y':2}]}]}
        after = copy.deepcopy(before); after['width'] = 3
        after['layers'][0]['data'] = [1,2,0,3,4,5]
        after['layers'][1]['objects'][0]['x'] = 9
        original = copy.deepcopy(before)
        result = map_diff(before, after)
        self.assertEqual(result['cells'], [
            {'layerId':'tiles','x':2,'y':0,'before':None,'after':0},
            {'layerId':'tiles','x':2,'y':1,'before':None,'after':5}])
        self.assertEqual(result['counts'], {'cells':2,'objects':1})
        result['objects'][0]['before']['x'] = -1
        self.assertEqual(before, original)
        self.assertFalse(map_diff(before, before)['changed'])
        self.assertEqual(map_diff(None, before)['counts'], {'cells':4,'objects':1})
        self.assertEqual(map_diff(before, None)['counts'], {'cells':4,'objects':1})


class PreviewCandidateTests(unittest.TestCase):
    def specification(self):
        relative = 'content/maps/village-outskirts.json'
        doc = read_json(ROOT / relative)
        index = next(i for i,gid in enumerate(doc['layers'][0]['data']) if gid != 0)
        doc['layers'][0]['data'][index] = 0
        return relative, doc, {'format':'rpgc.change-set','version':1,'changes':[
            {'path':relative,'expect':fingerprint(read_json(ROOT/relative)),'document':doc}]}

    def test_candidate_full_gate_precedes_qa_and_renders_diagnostics(self):
        relative, candidate, spec = self.specification()
        before = (ROOT/relative).read_bytes()
        calls = []
        def gate(binary, root, source, timeout):
            calls.append('gate'); self.assertNotEqual(Path(root), ROOT)
            self.assertEqual(read_json(root/relative), candidate)
            return {'ok':True,'diagnostics':[]}
        def qa(binary, root, identifier, timeout):
            calls.append('qa')
            return {'ok':False,'value':{'maps':[{'id':identifier}]},
                    'diagnostics':[{'code':'map-qa.spawn-blocked'}]}
        def render(binary, root, identifier, screenshot, timeout, context, window, actions):
            calls.append('render');self.assertEqual(read_json(root/relative),candidate)
            self.assertTrue(context['candidate']['enabled']);self.assertTrue(context['diff']['changed'])
            self.assertFalse(context['qa']['ok']);self.assertFalse(window)
            return {'ok':True,'rendered':True,'frames':5}
        with patch('rpgc_toolkit.map_preview.run_headless', side_effect=gate), \
             patch('rpgc_toolkit.map_preview.inspect_maps', side_effect=qa), \
             patch('rpgc_toolkit.map_preview._render_map_workspace', side_effect=render):
            report = render_map('/fake/eve', ROOT, 'village-outskirts', '/tmp/fake.png', changes=spec)
        self.assertEqual(calls, ['gate','qa','render'])
        self.assertFalse(report['ok']);self.assertTrue(report['rendered'])
        self.assertFalse(report['applied']);self.assertEqual(report['diff']['counts']['cells'],1)
        self.assertEqual((ROOT/relative).read_bytes(),before)

    def test_gate_failure_never_renders_or_runs_qa(self):
        _, _, spec = self.specification()
        with patch('rpgc_toolkit.map_preview.run_headless',return_value={'ok':False,'diagnostics':[{'code':'invalid'}]}), \
             patch('rpgc_toolkit.map_preview.inspect_maps') as qa, \
             patch('rpgc_toolkit.map_preview._render_map_workspace') as render:
            report=render_map('/fake/eve',ROOT,'village-outskirts','/tmp/fake.png',changes=spec)
        self.assertFalse(report['rendered']);qa.assert_not_called();render.assert_not_called()

    def test_unknown_map_qa_failure_does_not_crash_on_zero_value(self):
        with patch('rpgc_toolkit.map_preview.run_headless',return_value={'ok':True}), \
             patch('rpgc_toolkit.map_preview.inspect_maps',return_value={'ok':False,'value':0,'diagnostics':[]}), \
             patch('rpgc_toolkit.map_preview._render_map_workspace') as render:
            report=render_map('/fake/eve',ROOT,'missing','/tmp/fake.png')
        self.assertFalse(report['rendered']);render.assert_not_called()

    def test_open_api_keeps_window_mode_distinct_from_capture(self):
        with patch('rpgc_toolkit.map_preview._preview',return_value={}) as preview:
            open_map('/fake/eve',ROOT,'village-outskirts',timeout=12,inspector=False)
        self.assertEqual(preview.call_args.args[3],None)
        self.assertEqual(preview.call_args.args[-3:],(False,True,None))

    def test_action_admission_rejects_unknown_commands_and_bool_indices(self):
        for invalid in ({},[{'action':'unknown'}],[{'action':'fit','arg':1}],
                        [{'action':'select-cell','arg':True}],[{'action':'select-cell','arg':65536}],
                        [{'action':'fit','extra':1}],[{'action':'fit'}]*65):
            with self.subTest(actions=invalid),self.assertRaises(ValueError):
                validate_actions(invalid)
        self.assertEqual(validate_actions([{'action':'blocked'},{'action':'select-cell','arg':3}]),
                         [{'action':'blocked','arg':0},{'action':'select-cell','arg':3}])

    def test_actions_record_real_host_state_and_rejected_actions_cleanup(self):
        for accepted in (True, False):
            with self.subTest(accepted=accepted), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);(root/'workflow.json').write_text('{}')
                binary=root/'eve';binary.write_bytes(b'fake binary')
                process=MagicMock();process.poll.side_effect=[None, 0 if accepted else None];process.wait.return_value=0
                client=MagicMock(); state={'blocked':True}; frames=[3]
                def call(tool,args):
                    if tool=='eve_eval':
                        frames[0]+=1
                        return json.dumps({'ok':True,'value':json.dumps({'frames':frames[0],'error':'','qa':{},'state':state})})
                    if accepted:
                        state['blocked']=False
                        return 'ok'
                    return 'error: rejected index'
                client.call.side_effect=call
                with patch('rpgc_toolkit.map_preview.subprocess.Popen',return_value=process), \
                     patch('rpgc_toolkit.map_preview.socket.create_connection'), \
                     patch('rpgc.McpClient',return_value=client):
                    if accepted:
                        report=_render_map_workspace(binary,root,'test',None,timeout=1,window=True,actions=[{'action':'blocked'}])
                        self.assertEqual(report['actions'],[{'action':'blocked','arg':0,'before':{'blocked':True},'after':{'blocked':False}}])
                    else:
                        with self.assertRaisesRegex(ValueError,'preview action failed'):
                            _render_map_workspace(binary,root,'test',None,timeout=1,window=True,actions=[{'action':'select-cell','arg':50}])
                        process.terminate.assert_called_once()
                client.close.assert_called_once()

    def test_window_wait_has_no_startup_deadline_and_only_owned_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'workflow.json').write_text('{}')
            binary=root/'eve';binary.write_bytes(b'fake binary')
            process=MagicMock();process.poll.side_effect=[None,0];process.wait.return_value=0
            client=MagicMock();client.call.return_value=json.dumps({'ok':True,'value':json.dumps({'frames':3,'error':'','qa':{}})})
            with patch('rpgc_toolkit.map_preview.subprocess.Popen',return_value=process), \
                 patch('rpgc_toolkit.map_preview.socket.create_connection'), \
                 patch('rpgc.McpClient',return_value=client):
                report=_render_map_workspace(binary,root,'test',None,timeout=1,window=True)
            self.assertTrue(report['rendered']);self.assertTrue(report['window'])
            process.wait.assert_called_once_with()
            process.terminate.assert_not_called();client.close.assert_called_once()
            self.assertFalse((root/'main.nut').exists())


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'requires native candidate gate and map QA')
class NativePreviewAdmissionTests(unittest.TestCase):
    def test_blocked_spawn_passes_content_gate_and_is_presented_with_error(self):
        relative = 'content/maps/village-outskirts.json'
        doc = read_json(ROOT / relative)
        doc['layers'][0]['data'][8 * doc['width'] + 11] = 0
        changes = {'format':'rpgc.change-set','version':1,'changes':[{'path':relative,'document':doc}]}
        before = (ROOT / relative).read_bytes()
        with patch('rpgc_toolkit.map_preview._render_map_workspace', return_value={'ok':True,'rendered':True}) as render:
            report = render_map(os.environ['RPGC_TEST_EVE'], ROOT, 'village-outskirts', '/tmp/unused.png', changes=changes)
        self.assertTrue(report['gate']['ok'])
        self.assertFalse(report['ok']); self.assertTrue(report['rendered'])
        self.assertIn('map-qa.spawn-blocked', {row['code'] for row in report['diagnostics']})
        render.assert_called_once()
        self.assertEqual((ROOT / relative).read_bytes(), before)
