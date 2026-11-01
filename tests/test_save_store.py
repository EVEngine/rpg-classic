"""Actual native atomic writes, always under an isolated Linux user directory."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.runtime import run_headless

@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE') and sys.platform.startswith('linux'), 'real Linux SDK and isolated XDG userdir required')
class NativeSaveStoreTests(unittest.TestCase):
    def test_native_generations_corruption_and_invalid_candidate_preservation(self):
        source='''import { RpgcSave } from "game:/lib/rpgc_save.nut"
import { RpgcSaveStore } from "game:/lib/rpgc_save_store.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
function storeChecks() {
    local rows=[];local check=function(name,ok){rows.append({name=name,ok=ok});if(!ok)throw name;};
    local init=RpgcSaveStore.initialize();check("initialize",init.ok);
    local state=RpgcWorldState.create({mapId="village-outskirts",x=11,y=8,moment="day",gold=7,bag=RpgcItems.newBag(4,"party")}).value;
    local config=RpgcItems.loadProject().value;local equipment=RpgcItems.newEquipmentSet(config,"party");
    local meta={partyId="party.default",locale="zh-CN",inputSequence=0};
    local first=RpgcSave.capture(state,equipment,meta);check("capture",first.ok);
    check("save-primary",RpgcSaveStore.save(first.value.snapshot,"probe").ok);
    local fs=eve.Filesystem();local original=fs.readText("player-probe.json");
    state.gold=8;local second=RpgcSave.capture(state,equipment,meta);
    check("save-replacement",second.ok && RpgcSaveStore.save(second.value.snapshot,"probe").ok);
    check("previous-generation",fs.readText("player-probe.json.backup")==original);
    local latest=RpgcSaveStore.load("probe");check("load-primary",latest.ok && latest.value.source=="primary" && latest.value.candidate.state.gold==8);
    check("corrupt-test-primary",fs.writeTextAtomic("player-probe.json","{")==1);
    local fallback=RpgcSaveStore.load("probe");check("backup-fallback",fallback.ok && fallback.value.source=="backup" && fallback.value.candidate.state.gold==7);
    check("fallback-does-not-overwrite",fs.readText("player-probe.json")=="{" && fs.readText("player-probe.json.backup")==original);
    local invalid=RpgcWorldState.copyValue(second.value.snapshot);invalid.checksum="00000000";
    check("invalid-save-refused",!RpgcSaveStore.save(invalid,"probe").ok);
    check("invalid-save-keeps-files",fs.readText("player-probe.json")=="{" && fs.readText("player-probe.json.backup")==original);
    check("traversal-refused",!RpgcSaveStore.save(second.value.snapshot,"../probe").ok);
    return {ok=true,checks=rows,directory=RpgcSaveStore.directory};
}
RpgcToolkitResult <- RpgcJson.encodeCompact(storeChecks());
'''
        with tempfile.TemporaryDirectory(prefix='rpgc-user-save-') as directory:
            with patch.dict(os.environ,{'XDG_DATA_HOME':directory}):
                result=run_headless(os.environ['RPGC_TEST_EVE'],ROOT,source)
            self.assertTrue(result['ok'],result)
            self.assertTrue(Path(result['directory']).resolve().is_relative_to(Path(directory).resolve()))
            self.assertEqual(len(result['checks']),12)
            self.assertTrue(all(row['ok'] for row in result['checks']))
            self.assertEqual((Path(result['directory'])/'player-probe.json').read_text(),'{')
