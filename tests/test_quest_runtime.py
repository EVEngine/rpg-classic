"""Exercise quest rules in the real Squirrel VM, including atomic item rewards."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for real quest runtime tests')
class QuestRuntimeTests(unittest.TestCase):
    def test_real_quest_progress_claim_capacity_and_failure_cases(self):
        environment = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
        result = subprocess.run([os.environ['RPGC_TEST_EVE'], 'run', '--no-window', '-r', 'tools/quest_check.nut'],
                                cwd=ROOT, env=environment, capture_output=True, text=True,
                                errors='replace', timeout=60)
        output = result.stdout + '\n' + result.stderr
        self.assertEqual(result.returncode, 0, output[-6000:])
        marker = 'RPGC_QUEST_RESULT='
        reports = [line[len(marker):] for line in output.splitlines() if line.startswith(marker)]
        self.assertEqual(len(reports), 1, output[-6000:])
        report = json.loads(reports[0])
        self.assertTrue(report['ok'], report)
        self.assertGreaterEqual(len(report['checks']), 40)
        self.assertEqual(len({check['name'] for check in report['checks']}), len(report['checks']))
        for check in report['checks']:
            with self.subTest(check=check['name']):
                self.assertTrue(check['ok'])


if __name__ == '__main__':
    unittest.main()
