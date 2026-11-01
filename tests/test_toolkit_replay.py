import copy
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.replay import (recording_source, replay_source, validate_tape,
                                finish_report, record_battle, replay_battle)


def tape():
    return {'schema': 'rpgc.battle-tape', 'version': 1, 'party': 'party.default',
            'encounter': 'encounter.outskirts-night', 'seed': 42,
            'orders': [{'actor': 'hero', 'skill': 'command.defend', 'target': ''}]}


class ReplayTests(unittest.TestCase):
    def test_tape_rejects_wrong_shapes_and_budget(self):
        for change in ({'orders': [{}]}, {'seed': True}, {'version': True},
                       {'orders': [{'actor': '', 'skill': 'x', 'target': ''}]},
                       {'unexpected': 1}, {'expected': {'fingerprint': 'x', 'steps': []}}):
            doc = tape(); doc.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_tape(doc)
        with self.assertRaises(ValueError):
            validate_tape(tape(), 0)
        doc = tape(); doc['orders'] *= 2
        with self.assertRaises(ValueError):
            validate_tape(doc, 1)

    def test_source_calls_real_runtime(self):
        source = recording_source('party.default', 'encounter.outskirts-night')
        for name in ('autoCommand', 'submitCommand', 'commandsFor', 'takeEvents'):
            self.assertIn('RpgcBattle.' + name, source)
        self.assertIn('local recording = false', replay_source(tape()))
        original = tape()
        validate_tape(original)['orders'][0]['actor'] = 'changed'
        self.assertEqual(original['orders'][0]['actor'], 'hero')

    def test_fingerprint_is_key_order_independent_and_detects_step_change(self):
        report = {'ok': True, 'steps': [{'order': {'actor': 'a', 'skill': 's'}, 'events': []}],
                  'initialEvents': [], 'final': {'outcome': 'victory'}, 'settlement': {},
                  'tape': {}, 'diagnostics': []}
        recorded = finish_report(report)
        same = copy.deepcopy(report)
        same['steps'][0]['order'] = {'skill': 's', 'actor': 'a'}
        self.assertTrue(finish_report(same, recorded['tape']['expected'])['matched'])
        same['steps'][0]['events'].append({'kind': 'miss'})
        changed = finish_report(same, recorded['tape']['expected'])
        self.assertFalse(changed['ok'])
        self.assertEqual(changed['differences'], [0])

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for real VM replay')
    def test_real_record_replay_and_rejection(self):
        binary = os.environ['RPGC_TEST_EVE']
        recorded = record_battle(binary, ROOT, 'party.default', 'encounter.outskirts-night', 42)
        self.assertTrue(recorded['ok'], recorded['diagnostics'])
        self.assertGreater(len(recorded['tape']['orders']), 0)
        replayed = replay_battle(binary, ROOT, recorded['tape'])
        self.assertTrue(replayed['ok'], replayed['diagnostics'])
        self.assertTrue(replayed['matched'])
        self.assertEqual(recorded['fingerprint'], replayed['fingerprint'])
        bad = copy.deepcopy(recorded['tape']); bad['orders'][0]['actor'] = 'not-the-actor'
        rejected = replay_battle(binary, ROOT, bad)
        self.assertFalse(rejected['ok'])
        self.assertEqual(rejected['diagnostics'][0]['code'], 'replay.actor')
        bad = copy.deepcopy(recorded['tape']); bad.pop('expected')
        bad['orders'][0]['skill'] = 'skill.does-not-exist'
        rejected = replay_battle(binary, ROOT, bad)
        self.assertEqual(rejected['diagnostics'][0]['code'], 'replay.command')
        short = copy.deepcopy(recorded['tape']); short.pop('expected'); short['orders'] = []
        rejected = replay_battle(binary, ROOT, short)
        self.assertEqual(rejected['diagnostics'][0]['code'], 'replay.incomplete')
        extra = copy.deepcopy(recorded['tape']); extra.pop('expected')
        extra['orders'].append(extra['orders'][-1])
        rejected = replay_battle(binary, ROOT, extra)
        self.assertEqual(rejected['diagnostics'][0]['code'], 'replay.extra-order')
        budget = record_battle(binary, ROOT, 'party.default', 'encounter.outskirts-night', 42, 1)
        self.assertFalse(budget['ok'])
        self.assertEqual(budget['diagnostics'][0]['code'], 'replay.budget')


if __name__ == '__main__':
    unittest.main()
