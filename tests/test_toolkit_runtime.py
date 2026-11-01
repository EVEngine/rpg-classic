import json
import os
import sys
import unittest
from unittest.mock import patch
from subprocess import CompletedProcess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.runtime import graph_report, run_headless, simulation_source, GRAPH_SOURCE, run_module_checks


class RuntimeTests(unittest.TestCase):
    def test_reverse_impact_handles_cycles_and_is_directional(self):
        graph = {'nodes':[{'id':x} for x in ('a','b','c','d')], 'diagnostics':[],
                 'edges':[{'source':a,'target':b,'path':'/ref'} for a,b in
                          [('a','b'),('b','c'),('c','b'),('c','d')]]}
        result = graph_report(graph, 'b')
        self.assertEqual(result['impact'], ['a','c'])
        self.assertFalse(result['validated'])
        with self.assertRaises(ValueError):
            graph_report(graph, 'unknown')

    def test_simulation_budget_bounds(self):
        for kwargs in ({'runs':0}, {'runs':101}, {'seed':True}, {'seed':-1},
                       {'seed':2147483647,'runs':2}, {'max_orders':10001}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                simulation_source('party.default','encounter.test',**kwargs)

    def test_module_runner_checks_both_exit_and_assertions(self):
        passed='[modules] ok   fixture\n[modules] PASS (0 failure(s))\n'
        cases=[(0,passed,True),(0,'[modules] FAIL fixture\n[modules] FAIL (1 failure(s))',False),
               (-6,passed,False),(0,'[modules] ok fixture',False),(0,passed+passed,False)]
        for code,output,wanted in cases:
            with self.subTest(code=code,output=output), patch('rpgc_toolkit.runtime.subprocess.run',
                    return_value=CompletedProcess([],code,'',output)):
                self.assertEqual(run_module_checks('eve',ROOT)['ok'],wanted)

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for full module regression')
    def test_full_module_suite(self):
        report = run_module_checks(os.environ['RPGC_TEST_EVE'], ROOT)
        self.assertTrue(report['ok'], report.get('logTail', report))
        checks = {entry['check']:entry['ok'] for entry in report['checks']}
        self.assertTrue(checks['cross.encounter-hosted-twice'])
        self.assertTrue(checks['cross.battle-capacity'])
        self.assertGreater(len(report['checks']), 300)

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for real no-window VM checks')
    def test_real_vm_graph_and_reproducible_battle(self):
        binary = os.environ['RPGC_TEST_EVE']
        graph = graph_report(run_headless(binary, ROOT, GRAPH_SOURCE), 'skill/skill.strike')
        self.assertTrue(graph['ok'])
        self.assertGreater(len(graph['edges']), 100)
        source = simulation_source('party.default','encounter.outskirts-night',42,2)
        first = run_headless(binary,ROOT,source)
        second = run_headless(binary,ROOT,source)
        self.assertEqual(first, second)
        self.assertTrue(first['ok'])
        self.assertEqual([r['seed'] for r in first['runs']], [42,43])
        self.assertTrue(all(r['fight']['outcome'] in ('victory','defeat') for r in first['runs']))
        self.assertFalse(list(ROOT.glob('.rpgc-toolkit-*.nut')))


if __name__ == '__main__':
    unittest.main()
