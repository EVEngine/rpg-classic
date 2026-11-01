"""Real Squirrel regression checks; no Python reimplementation of world rules."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.runtime import run_headless


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for real world-runtime VM tests')
class WorldRuntimeTests(unittest.TestCase):
    def test_real_state_scheduler_and_failure_probes(self):
        environment = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
        process = subprocess.run([os.environ['RPGC_TEST_EVE'], 'run', '--no-window', '-r',
                                  'tools/world_runtime_check.nut'], cwd=ROOT, env=environment,
                                 capture_output=True, text=True, timeout=120)
        output = process.stdout + '\n' + process.stderr
        self.assertEqual(process.returncode, 0, output)
        marker = 'RPGC_WORLD_RUNTIME='
        lines = [line[len(marker):] for line in output.splitlines() if line.startswith(marker)]
        self.assertEqual(len(lines), 1, output)
        report = json.loads(lines[0])
        self.assertGreaterEqual(len(report['checks']), 38)
        self.assertEqual(len({row['name'] for row in report['checks']}), len(report['checks']))
        for row in report['checks']:
            with self.subTest(check=row['name']):
                self.assertTrue(row['ok'])
        self.assertTrue(report['ok'])

    def test_shipped_event_v1_runs_with_explicit_acknowledging_test_host(self):
        # This verifies logical compatibility, not actual animation/rendering.
        source = '''import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcEventRunner } from "game:/lib/rpgc_event_runner.nut"
function runWorldCompatibility() {
    local checks=[]; local success=true;
    local caps={load_map=true,move_actor=true,face_actor=true,play_animation=true,
        camera_focus=true,camera_pan=true,dialogue=true,message=true};
    foreach (id in RpgcProject.idsOf("event")) {
        local document=RpgcProject.loadById("event",id);
        local state=RpgcWorldState.create({gold=100,moment="day",mapId="village-outskirts"}).value;
        local made=RpgcEventRunner.newSession(document.value,state,caps);
        local ok=made.ok; local ticks=0; local acks=[]; local requests=0;
        if (ok) {
            while (ticks<200 && made.value.status!="completed" && made.value.status!="failed") {
                local result=RpgcEventRunner.tick(made.value,state,0.1,acks);
                ticks+=1; acks=[];
                if (!result.ok) { ok=false; break; }
                foreach (request in result.value.requests) {
                    requests+=1;
                    acks.append({operationId=request.operationId,ok=true});
                }
            }
            ok=ok && made.value.status=="completed";
        }
        checks.append({id=id,ok=ok,ticks=ticks,requests=requests});
        if (!ok) success=false;
    }
    return {ok=success,checks=checks};
}
RpgcToolkitResult <- RpgcJson.encodeCompact(runWorldCompatibility());
'''
        result = run_headless(os.environ['RPGC_TEST_EVE'], ROOT, source)
        self.assertTrue(result['ok'], result)
        self.assertGreaterEqual(len(result['checks']), 2)
        for row in result['checks']:
            self.assertTrue(row['ok'], row)
            self.assertGreater(row['ticks'], 1)
            self.assertGreater(row['requests'], 0)


if __name__ == '__main__':
    unittest.main()
