"""Snapshot validation runs in the real engine, never mirrored in Python."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for native save probes')
class SaveRuntimeTests(unittest.TestCase):
    def test_snapshot_integrity_safe_points_and_restore(self):
        process = subprocess.run(
            [os.environ['RPGC_TEST_EVE'], 'run', '--no-window', '-r', 'tools/save_check.nut'],
            cwd=ROOT, env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy'),
            capture_output=True, text=True, timeout=120)
        output = process.stdout + process.stderr
        self.assertEqual(process.returncode, 0, output)
        lines = [line[len('RPGC_SAVE='):] for line in output.splitlines() if line.startswith('RPGC_SAVE=')]
        self.assertEqual(len(lines), 1, output)
        report = json.loads(lines[0])
        self.assertGreaterEqual(len(report['checks']), 40)
        self.assertEqual(len({row['name'] for row in report['checks']}), len(report['checks']))
        for row in report['checks']:
            with self.subTest(check=row['name']):
                self.assertTrue(row['ok'])
        self.assertTrue(report['ok'])
