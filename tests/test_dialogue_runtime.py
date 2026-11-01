"""Real SDK coverage for the shared dialogue interpreter, without UI substitutes."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MARKER = 'RPGC_DIALOGUE_RESULT='


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE to run the real dialogue VM')
class DialogueRuntimeTests(unittest.TestCase):
    def test_real_dialogue_schema_state_and_negative_scenarios(self):
        environment = dict(os.environ)
        environment.setdefault('SDL_VIDEODRIVER', 'dummy')
        environment.setdefault('SDL_AUDIODRIVER', 'dummy')
        result = subprocess.run([os.environ['RPGC_TEST_EVE'], 'run', '--no-window', '-r', 'tools/dialogue_check.nut'],
                                cwd=ROOT, env=environment, capture_output=True, text=True,
                                errors='replace', timeout=60)
        output = result.stdout + '\n' + result.stderr
        self.assertEqual(result.returncode, 0, output[-5000:])
        reports = [line[len(MARKER):] for line in output.splitlines() if line.startswith(MARKER)]
        self.assertEqual(len(reports), 1, output[-5000:])
        report = json.loads(reports[0])
        self.assertTrue(report['ok'], report)
        self.assertGreaterEqual(len(report['checks']), 29)
        for check in report['checks']:
            with self.subTest(check=check['check']):
                self.assertTrue(check['ok'])


if __name__ == '__main__':
    unittest.main()
