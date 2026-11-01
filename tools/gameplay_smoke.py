#!/usr/bin/env python3
"""Exercise the real rendered game through its MCP game-function adapter.

Start a FRESH disposable copy with hotReload=false, using `eve run --mcp-port
19652 .`, then run `python tools/gameplay_smoke.py --port 19652`. This changes
in-memory gameplay state, opens a chest and claims a quest; do not attach it to
an ongoing player session. No content/save files are written. --screenshot is an
optional absolute path on the ENGINE host. Tests use real native map/camera/
sprite/UI adapters; they do not emulate OS keyboard input or replace game rules.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

from rpgc import McpClient, McpError


class GameplaySmoke:
    def __init__(self, client, timeout=30.0):
        self.client = client
        self.timeout = timeout
        self.checks = []

    def script(self, source):
        result = self.client.call('eve_run_script', {'source': source})
        if result.strip() != 'ok':
            raise ValueError('game script failed: ' + result)

    def report(self):
        response = json.loads(self.client.call('eve_eval', {'expression': 'worldRuntimeReport()'}))
        if not response.get('ok'):
            raise ValueError('game runtime report unavailable: ' + json.dumps(response))
        value = response['value']
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        result = json.loads(value)
        if result['fatal'] or result['questError']:
            raise ValueError('game runtime failed: ' + json.dumps(result, ensure_ascii=False))
        return result

    def wait(self, predicate, label):
        deadline = time.monotonic() + self.timeout
        last = {}
        while time.monotonic() < deadline:
            last = self.report()
            if predicate(last):
                return last
            time.sleep(0.05)
        raise ValueError(f'timed out waiting for {label}: {json.dumps(last, ensure_ascii=False)}')

    def check(self, name, condition, detail=None):
        self.checks.append({'name': name, 'ok': bool(condition), 'detail': detail})
        if not condition:
            raise ValueError('smoke assertion failed: ' + name)

    def fill_bag(self):
        self.script('''import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
GameSmokeBag <- RpgcWorldState.copyValue(worldState.bag);
foreach (slot in worldState.bag.slots) { slot.itemId="potion.heal"; slot.quantity=20; }
syncWorldPresentation();''')

    def restore_bag(self):
        self.script('worldState.bag=GameSmokeBag; syncWorldPresentation();')

    def chest(self):
        self.script('''local found=false;
for (local i=0;i<map.getObjectCount();i+=1) if(map.getObjectName(i)=="old_chest") { interactObject(i); found=true; break; }
if (!found) throw "old_chest fixture missing";''')

    def event(self, identifier):
        self.script('local found=false; foreach (doc in eventDocs) if (doc.id==' +
                    json.dumps(identifier) + ') { runEventDoc(doc); found=true; } if(!found) throw "event fixture missing";')

    def acknowledge_message(self):
        self.wait(lambda row: bool(row['message']), 'message presentation')
        self.script('worldAck(worldMessage.request,true); worldMessage=null;')

    def run(self, screenshot=None):
        initial = self.wait(lambda row: row['renderedFrames'] >= 2 and not row['busy'], 'first rendered frames')
        self.check('fresh-test-session', initial['mapId'] == 'village-outskirts' and
                   initial['questStatus'] == 'inactive' and
                   'village-outskirts/old_chest' not in initial['consumed'])
        self.script('visitWorldGuide();')
        line = self.wait(lambda row: row['dialogueKind'] == 'line', 'guide greeting')
        self.check('dialogue-real-text', bool(line['dialogueText']) and line['dialogueText'] != 'guide.greeting')
        self.script('worldDialogueInput(-1,true);')
        choice = self.wait(lambda row: row['dialogueKind'] == 'choice', 'guide choices')
        option = next(i for i, row in enumerate(choice['options']) if row['id'] == 'accept')
        self.script('applyWorldCommands([{kind="set_variable",name="toolkit.guide.accepted",op="set",value=1}]);'
                    + f'if(worldDialogueInput({option},false)) throw "stale displayed choice was accepted";'
                    + 'applyWorldCommands([{kind="set_variable",name="toolkit.guide.accepted",op="set",value=0}]); refreshWorldDialogue();')
        unchanged = self.report()
        self.check('stale-displayed-choice-refused', unchanged['dialogueKind'] == 'choice')
        option = next(i for i, row in enumerate(unchanged['options']) if row['id'] == 'accept')
        self.script(f'worldDialogueInput({option},false);')
        self.wait(lambda row: row['questStatus'] == 'active', 'quest activation')
        self.script('worldDialogueInput(-1,true);')
        self.wait(lambda row: not row['busy'], 'guide close')
        self.fill_bag()
        self.chest()
        rejected = self.report()
        self.check('full-bag-chest-atomic', rejected['gold'] == initial['gold'] and
                   'village-outskirts/old_chest' not in rejected['consumed'] and rejected['questStatus'] == 'active')
        self.restore_bag()
        self.chest()
        completed = self.wait(lambda row: row['questStatus'] == 'completed', 'chest objective completion')
        self.check('chest-actually-grants-item', completed['potionCount'] == initial['potionCount'] + 1)
        self.check('chest-gold-and-consumed', completed['gold'] == initial['gold'] + 25 and
                   completed['consumed'].get('village-outskirts/old_chest') is True)
        self.fill_bag()
        self.script('visitWorldGuide();')
        rejected = self.report()
        self.check('full-bag-claim-atomic', rejected['questStatus'] == 'completed' and rejected['gold'] == completed['gold'])
        self.restore_bag()
        self.script('visitWorldGuide();')
        claimed = self.wait(lambda row: row['questStatus'] == 'claimed', 'claim rewards')
        self.check('quest-claim-grants-once', claimed['gold'] == completed['gold'] + 5 and
                   claimed['potionCount'] == completed['potionCount'] + 1)
        self.script('visitWorldGuide();')
        duplicate = self.report()
        self.check('repeat-visit-no-reward', duplicate['gold'] == claimed['gold'] and duplicate['potionCount'] == claimed['potionCount'])
        self.script('cancelWorldEvent();')
        self.event('village.elder-offer')
        elder = self.wait(lambda row: row['dialogueKind'] == 'line', 'elder camera/face/wait/dialogue')
        self.check('real-camera-finished', abs(elder['cameraX'] - 3136) < 0.1 and abs(elder['cameraY'] - 1408) < 0.1)
        self.script('worldDialogueInput(-1,true);')
        self.acknowledge_message()
        elder_done = self.wait(lambda row: not row['busy'], 'elder sprite completion')
        self.check('old-event-native-animation-completed',
                   elder_done['completedEvents'].get('village.elder-offer') is True and
                   any(row['id'] == 'player' and not row['playing'] and row['pending'] == '' for row in elder_done['actors']))
        self.check('old-event-shared-gold-command', elder_done['gold'] == claimed['gold'] - 10)
        self.event('mist-forest.arrival')
        self.acknowledge_message()
        forest = self.wait(lambda row: row['dialogueKind'] == 'line', 'parallel camera/loop animation join')
        self.check('real-map-transfer', forest['mapId'] == 'mist-forest' and forest['x'] == 4 and forest['y'] == 10)
        self.script('worldDialogueInput(-1,true);')
        self.acknowledge_message()
        forest_done = self.wait(lambda row: not row['busy'], 'forest event completion')
        self.check('old-event-parallel-completed', forest_done['completedEvents'].get('mist-forest.arrival') is True)
        player = next(row for row in forest_done['actors'] if row['id'] == 'player')
        animated = self.wait(lambda row: any(actor['id'] == 'player' and actor['frame'] != player['frame'] for actor in row['actors']), 'rendered looping sprite frame change')
        self.check('native-loop-animation-advances', player['playing'] and animated['renderedFrames'] > forest_done['renderedFrames'])
        before = self.report()
        self.script('''handleWorldRequest({operationId="smoke.bad-transfer",kind="load_map",
step={mapId="mist-forest",x=99999,y=0}});''')
        rolled_back = self.report()
        self.check('invalid-map-target-restores-world', (rolled_back['mapId'], rolled_back['x'], rolled_back['y']) ==
                   (before['mapId'], before['x'], before['y']) and rolled_back['fatal'] == '' and
                   rolled_back['nativeOriginX'] == before['nativeOriginX'] and rolled_back['nativeObjects'] == before['nativeObjects'])
        self.script('local originalOrigin=worldLayer.tileToWorldX(0,0);\nhandleWorldRequest({operationId="smoke.cancel-transfer",kind="load_map",step={mapId="village-outskirts",x=11,y=8}});\nif (worldLayer.tileToWorldX(0,0)==originalOrigin) throw "native transfer fixture did not change maps";\ncancelWorldEvent();')
        restored = self.report()
        self.check('cancel-pending-transfer-restores-native-map', restored['mapId'] == before['mapId'] and
                   restored['nativeOriginX'] == before['nativeOriginX'] and restored['nativeObjects'] == before['nativeObjects'])
        self.script('''worldAcks=[];
runEventDoc({schema="eve.rpgc.event",version=1,id="smoke.cancel",trigger={kind="manual"},steps=[
{kind="wait",duration=0.5},{kind="set_variable",name="gold",op="add",value=100}]});''')
        self.wait(lambda row: row['currentEvent'] == 'smoke.cancel', 'cancellable wait')
        self.script('cancelWorldEvent();')
        stop = time.monotonic() + 0.7
        cancelled = self.wait(lambda row: time.monotonic() >= stop, 'cancelled wait deadline')
        self.check('cancel-no-late-reward', cancelled['gold'] == before['gold'] and 'smoke.cancel' not in cancelled['completedEvents'])
        self.script('''runEventDoc({schema="eve.rpgc.event",version=1,id="smoke.unsupported",trigger={kind="manual"},steps=[
{kind="move_actor",actorId="player",x=4,y=10,duration=1.0}]});''')
        refused = self.wait(lambda row: not row['busy'] and any(d['code'] == 'runtime.capability-missing' for d in row['lastDiagnostics']), 'explicit unsupported capability')
        self.check('unsupported-capability-fails', 'smoke.unsupported' not in refused['completedEvents'])
        if screenshot:
            # First call enables readback; the next presented frame supplies pixels.
            self.script('gfx.saveFramePng(' + json.dumps(screenshot) + ');')
            capture_frame = self.report()['renderedFrames']
            self.wait(lambda row: row['renderedFrames'] > capture_frame + 1, 'screenshot readback frame')
            self.script('if (!gfx.saveFramePng(' + json.dumps(screenshot) + ')) throw "screenshot failed";')
        final = self.report()
        self.check('real-host-kept-rendering', final['renderedFrames'] > initial['renderedFrames'])
        return {'ok': True, 'realHost': True, 'rendered': True,
                'inputMode': 'game functions over MCP (not OS keyboard simulation)',
                'checks': self.checks, 'initial': initial, 'final': final, 'screenshot': screenshot}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--timeout', default=30.0, type=float, help='per-transition deadline in seconds')
    parser.add_argument('--screenshot', help='absolute output PNG path on the engine host')
    args = parser.parse_args()
    if args.screenshot and not Path(args.screenshot).is_absolute():
        parser.error('--screenshot must be an absolute path on the engine host')
    if not 0 < args.timeout <= 300:
        parser.error('--timeout must be in (0,300]')
    client = None
    probe = None
    try:
        client = McpClient(args.host, args.port)
        client.initialize()
        probe = GameplaySmoke(client, args.timeout)
        result = probe.run(args.screenshot)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, McpError, KeyError, StopIteration) as error:
        print(json.dumps({'ok': False, 'realHost': True, 'rendered': False,
                          'checks': [] if probe is None else probe.checks,
                          'error': str(error)}, ensure_ascii=False, indent=2))
        return 1
    finally:
        if client:
            client.close()


if __name__ == '__main__':
    raise SystemExit(main())
