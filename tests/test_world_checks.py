import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from rpgc_toolkit.world_checks import PROBES,run_world_checks

class WorldChecksTests(unittest.TestCase):
    def test_crashes_empty_duplicate_and_false_probes_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for _,script,_ in PROBES:
                path=root/script;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
            for mode in ('crash','empty','duplicate','false','malformed'):
                def run(args,**kwargs):
                    marker=next(marker for _,script,marker in PROBES if script==args[-1])
                    report={'ok':True,'checks':[{'ok':mode!='false'}]}
                    if mode=='empty': report['checks']=[]
                    if mode=='malformed': report['checks']=[{'ok':'yes'}]
                    output=marker+json.dumps(report)+'\n'
                    if mode=='duplicate':output+=output
                    return subprocess.CompletedProcess(args,-11 if mode=='crash' else 0,output,'')
                with self.subTest(mode=mode),patch('rpgc_toolkit.world_checks.subprocess.run',side_effect=run):
                    result=run_world_checks('eve',root)
                    self.assertFalse(result['ok'])
                    self.assertEqual(len(result['checks']),len(PROBES))
                    self.assertTrue(all(not row['ok'] for row in result['checks']))

    def test_missing_probe_is_failure(self):
        with tempfile.TemporaryDirectory() as directory,patch('rpgc_toolkit.world_checks.subprocess.run') as run:
            self.assertFalse(run_world_checks('eve',directory)['ok'])
            run.assert_not_called()
