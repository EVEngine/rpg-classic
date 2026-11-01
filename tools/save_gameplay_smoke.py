#!/usr/bin/env python3
"""Real-window player-save smoke, including an actual engine process restart.

Run against a DISPOSABLE frozen game copy (config hotReload=false) and an EMPTY
--data-home directory, with a working display/Vulkan environment. The tool owns
and stops two eve processes. It uses gameplay functions through MCP rather than
OS key injection, but exercises the same F5/F9 handlers and native filesystem.
It intentionally corrupts only saves in its explicitly supplied test userdir.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time

from gameplay_smoke import GameplaySmoke
from rpgc import McpClient


class SaveGameplaySmoke:
    def __init__(self, binary, project, data_home, timeout=120):
        self.binary, self.project, self.data_home = Path(binary).resolve(), Path(project).resolve(), Path(data_home).resolve()
        self.timeout, self.process, self.client, self.probe = timeout, None, None, None
        self.log, self.checks, self.generation = None, [], 0

    def check(self, name, ok, detail=None):
        self.checks.append({'name': name, 'ok': bool(ok), 'detail': detail})
        if not ok:
            raise ValueError(name + ': ' + str(detail))

    def start(self):
        self.generation += 1
        with socket.socket() as socket_probe:
            socket_probe.bind(('127.0.0.1', 0))
            port = socket_probe.getsockname()[1]
        self.log = (self.data_home.parent / f'{self.data_home.name}-process-{self.generation}.log').open('wb')
        environment = dict(os.environ, XDG_DATA_HOME=str(self.data_home))
        environment.setdefault('SDL_AUDIODRIVER', 'dummy')
        self.process = subprocess.Popen([str(self.binary), 'run', '--mcp-port', str(port), '.'], cwd=self.project,
                                        env=environment, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise ValueError('engine exited before opening the real window; inspect process log')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise ValueError('engine MCP startup timed out')
        self.client = McpClient('127.0.0.1', port, timeout=self.timeout)
        self.client.initialize()
        self.probe = GameplaySmoke(self.client, self.timeout)
        last = None
        while time.monotonic() < deadline:
            try:
                last = self.probe.report()
                if last['renderedFrames'] >= 2 and not last['busy']:
                    return last
            except (ValueError, KeyError):
                pass
            time.sleep(.1)
        raise ValueError('real game initialization did not complete: ' + str(last))

    def stop(self):
        if self.client:
            self.client.close()
            self.client = None
        if self.process:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
            self.process = None
        if self.log:
            self.log.close()
            self.log = None

    def run(self, screenshot=None):
        if self.data_home.exists() and any(self.data_home.iterdir()):
            raise ValueError('--data-home must be empty; never run corruption tests on player data')
        if self.data_home.is_relative_to(self.project):
            raise ValueError('test user directory must be outside the disposable game')
        config = (self.project / 'config.nut').read_text()
        if 'hotReload = false' not in config and 'hotReload=false' not in config:
            raise ValueError('freeze the disposable game with hotReload=false before this smoke')
        self.data_home.mkdir(parents=True, exist_ok=True)
        try:
            first = self.start()
            self.check('first-process-is-fresh', first['questStatus'] == 'inactive' and first['gold'] == 0)
            p = self.probe
            p.script('visitWorldGuide();')
            p.wait(lambda r: r['dialogueKind'] == 'line', 'greeting')
            p.script('worldDialogueInput(-1,true);')
            choice = p.wait(lambda r: r['dialogueKind'] == 'choice', 'choices')
            index = next(i for i, option in enumerate(choice['options']) if option['id'] == 'accept')
            p.script(f'worldDialogueInput({index},false);')
            p.wait(lambda r: r['questStatus'] == 'active', 'activation')
            p.script('refreshWorldDialogue(); worldDialogueInput(-1,true);')
            p.wait(lambda r: not r['busy'], 'dialogue closed')
            p.chest()
            p.wait(lambda r: r['questStatus'] == 'completed', 'chest objective')
            p.script('visitWorldGuide();')
            claimed = p.wait(lambda r: r['questStatus'] == 'claimed', 'quest claim')
            p.script('requestWorldSave();')
            saved = p.wait(lambda r: not r['saveRequested'] and bool(r['saveResult']) and r['saveResult']['ok'], 'first native save')
            folder = Path(saved['saveDirectory']).resolve()
            self.check('isolated-native-user-directory', folder.is_relative_to(self.data_home) and not folder.is_relative_to(self.project), str(folder))
            primary, backup = folder / 'player-slot1.json', folder / 'player-slot1.json.backup'
            generation_a = primary.read_bytes()
            a = json.loads(generation_a)
            self.check('first-save-is-player-snapshot', a['format'] == 'eve.rpgc.world.snapshot' and a['payload']['world']['quests']['quest.toolkit-guide']['status'] == 'claimed')
            p.script('applyWorldCommands([{kind="set_variable",name="gold",op="add",value=7}]); worldLocale="en"; visitWorldGuide(); requestWorldSave();')
            deferred = p.wait(lambda r: r['saveRequested'] and r['saveResult']['value']['status'] == 'deferred', 'deferred save')
            self.check('busy-save-does-not-write', primary.read_bytes() == generation_a and deferred['busy'])
            p.script('if(requestWorldLoad().ok) throw "busy load accepted";')
            self.check('busy-load-does-not-replace-world', p.report()['gold'] == claimed['gold'] + 7)
            p.script('cancelWorldEvent();')
            saved_b = p.wait(lambda r: not r['saveRequested'] and r['saveResult']['ok'], 'deferred save completes at safe point')
            generation_b = primary.read_bytes()
            self.check('previous-valid-generation-backed-up', backup.read_bytes() == generation_a and generation_b != generation_a)
            b = json.loads(generation_b)
            self.check('new-generation-retains-locale', b['payload']['locale'] == 'en')
            self.stop()
            fresh = self.start()
            self.check('actual-process-restart-resets-live-world', fresh['questStatus'] == 'inactive' and fresh['gold'] == 0)
            p = self.probe
            p.script('requestWorldLoad();')
            loaded = p.wait(lambda r: bool(r['saveResult']) and r['saveResult']['ok'] and r['questStatus'] == 'claimed', 'restart load')
            self.check('restart-restores-player-state', loaded['gold'] == saved_b['gold'] and loaded['potionCount'] == saved_b['potionCount'] and loaded['consumed'] == saved_b['consumed'])
            p.script('visitWorldGuide(); cancelWorldEvent();')
            no_repeat = p.report()
            self.check('restart-does-not-repeat-quest-reward', no_repeat['gold'] == loaded['gold'] and no_repeat['potionCount'] == loaded['potionCount'])
            p.script('''import { RpgcSave } from "game:/lib/rpgc_save.nut"
import { RpgcSaveStore } from "game:/lib/rpgc_save_store.nut"
local capture=RpgcSave.capture(worldState,itemEquip,worldSaveMeta(),worldSaveContext());
if(!capture.ok || capture.value.status!="ready") throw "capture failed";
capture.value.snapshot.checksum="broken";
if(RpgcSaveStore.save(capture.value.snapshot).ok) throw "invalid candidate was written";''')
            self.check('invalid-candidate-preserves-both-files', primary.read_bytes() == generation_b and backup.read_bytes() == generation_a)
            primary.write_text('{corrupt-primary', encoding='utf-8')
            p.script('requestWorldLoad();')
            fallback = p.wait(lambda r: r['saveResult']['ok'] and r['saveResult']['value'].get('source') == 'backup', 'valid backup fallback')
            self.check('corrupt-primary-loads-valid-backup', fallback['gold'] == a['payload']['world']['gold'] and fallback['questStatus'] == 'claimed')
            self.check('backup-recovery-preserves-corrupt-primary', primary.read_text() == '{corrupt-primary' and backup.read_bytes() == generation_a)
            before = p.report()
            p.script('''import { RpgcSave } from "game:/lib/rpgc_save.nut"
import { RpgcSaveStore } from "game:/lib/rpgc_save_store.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
local capture=RpgcSave.capture(worldState,itemEquip,worldSaveMeta(),worldSaveContext());
if(!capture.ok || capture.value.status!="ready") throw "capture failed";
local body=capture.value.snapshot; body.rawdelete("checksum"); local found=false;
for(local y=0;y<worldLayer.getMapHeight() && !found;y+=1) for(local x=0;x<worldLayer.getMapWidth();x+=1) if(!worldPath.isWalkable(x,y)){body.payload.world.x=x;body.payload.world.y=y;found=true;break;}
if(!found)throw "blocked landing fixture missing";
local sealed=RpgcSave.seal(body);if(!sealed.ok || !RpgcSaveStore.save(sealed.value).ok)throw "could not write blocked-map fixture";
SaveSmokeBefore <- RpgcJson.encodeCompact({world=worldState,equipment=itemEquip,sequence=worldInputSequence,locale=worldLocale});''')
            blocked_bytes = primary.read_bytes()
            p.script('''import { RpgcJson } from "game:/lib/rpgc_json.nut"
local loaded=requestWorldLoad();if(loaded.ok)throw "blocked landing was accepted";
if(SaveSmokeBefore!=RpgcJson.encodeCompact({world=worldState,equipment=itemEquip,sequence=worldInputSequence,locale=worldLocale}))throw "failed load changed live state";''')
            rolled_back = p.report()
            self.check('native-map-failure-keeps-live-world', rolled_back['saveResult']['diagnostics'][0]['code'] == 'save.map-adapter' and
                       (rolled_back['mapId'], rolled_back['x'], rolled_back['y'], rolled_back['nativeOriginX'], rolled_back['nativeObjects']) ==
                       (before['mapId'], before['x'], before['y'], before['nativeOriginX'], before['nativeObjects']))
            self.check('native-map-failure-preserves-save-files', primary.read_bytes() == blocked_bytes and backup.read_bytes() == generation_a)
            if screenshot:
                p.script('gfx.saveFramePng(' + json.dumps(str(screenshot)) + ');')
                frame = p.report()['renderedFrames']
                p.wait(lambda r: r['renderedFrames'] > frame + 1, 'readback frame')
                p.script('if(!gfx.saveFramePng(' + json.dumps(str(screenshot)) + '))throw "screenshot failed";')
            return {'ok': True, 'realHost': True, 'processRestarts': 1, 'debuggerAttached': True,
                    'inputMode': 'F5/F9 gameplay handlers via MCP, not OS key injection',
                    'checks': self.checks, 'saveDirectory': str(folder), 'screenshot': str(screenshot) if screenshot else None}
        finally:
            self.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--eve', required=True)
    parser.add_argument('--project', required=True, type=Path)
    parser.add_argument('--data-home', required=True, type=Path)
    parser.add_argument('--screenshot', type=Path)
    args = parser.parse_args()
    smoke = SaveGameplaySmoke(args.eve, args.project, args.data_home)
    try:
        result = smoke.run(args.screenshot.resolve() if args.screenshot else None)
    except Exception as error:
        result = {'ok': False, 'checks': smoke.checks, 'error': str(error)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
