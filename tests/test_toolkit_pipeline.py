import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from rpgc_toolkit.pipeline import DEFAULT_PROFILES, load_profile, normalize_profile, run_preflight


def profile(*checks, name='custom'):
    return {'version': 1, 'id': name, 'checks': [
        {'id': check, 'required': required, 'timeoutSeconds': .25}
        for check, required in checks]}


def result(code=0, stdout='checked'):
    return subprocess.CompletedProcess([], code, stdout, '')


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in ['workflow.json', 'tools/build_placeholder_anims.py', 'tools/build_encounters.py',
                         'tools/rpgc_toolkit/assets.py', 'lib/rpgc_validate.nut', 'tools/modules_check.nut']:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{}')

    def test_profiles_are_json_persistable_and_independent(self):
        path = self.root / 'profile.json'
        path.write_text(json.dumps(DEFAULT_PROFILES['release']))
        loaded = load_profile(path)
        self.assertEqual(loaded['id'], 'release')
        loaded['checks'][0]['required'] = False
        self.assertTrue(DEFAULT_PROFILES['release']['checks'][0]['required'])
        with self.assertRaises(ValueError):
            normalize_profile(loaded)
        path.write_text('{"id":"quick","id":"release","checks":[]}')
        with self.assertRaises(ValueError):
            load_profile(path)

    def test_missing_eve_fails_required_skips_optional_and_continues(self):
        config = profile(('engine', True), ('modules', False), ('encounters', True))
        with patch('rpgc_toolkit.pipeline.subprocess.run', return_value=result()) as run:
            report = run_preflight(self.root, profile=config)
        self.assertFalse(report['ok'])
        self.assertEqual([row['status'] for row in report['checks']], ['fail', 'skipped', 'pass'])
        self.assertEqual(run.call_count, 1)
        self.assertTrue(all(row['durationMs'] >= 0 for row in report['checks']))

    def test_nonzero_and_timeout_aggregate_without_stopping(self):
        config = profile(('placeholder-anims', True), ('encounters', True), ('assets', True))
        with patch('rpgc_toolkit.pipeline.subprocess.run', side_effect=[
                result(2, 'stale'), subprocess.TimeoutExpired(['fixed-check'], .25), result(0, '{"ok":true,"diagnostics":[]}')]):
            report = run_preflight(self.root, profile=config)
        self.assertFalse(report['ok'])
        self.assertEqual([r['status'] for r in report['checks']], ['fail', 'fail', 'pass'])
        self.assertEqual(report['checks'][1]['diagnostics'][0]['code'], 'preflight.timeout')
        self.assertEqual(report['checks'][0]['detail']['exitCode'], 2)

    def test_missing_generator_is_failure_never_silent_skip(self):
        (self.root / 'tools/build_encounters.py').unlink()
        with patch('rpgc_toolkit.pipeline.subprocess.run') as run:
            report = run_preflight(self.root, profile=profile(('encounters', True)))
        self.assertFalse(report['ok'])
        self.assertEqual(report['checks'][0]['status'], 'fail')
        run.assert_not_called()

    def test_arbitrary_commands_and_unknown_checks_rejected_before_execution(self):
        base = profile(('assets', True))
        examples = [dict(base, command='touch /tmp/unsafe'), profile(('shell', True)),
                    dict(base, checks=[dict(base['checks'][0], command='evil')]),
                    dict(base, checks=[dict(base['checks'][0], timeoutSeconds=float('inf'))]),
                    dict(base, checks=[dict(base['checks'][0], timeoutSeconds=True)])]
        with patch('rpgc_toolkit.pipeline.subprocess.run') as run:
            for document in examples:
                with self.subTest(profile=document), self.assertRaises(ValueError):
                    run_preflight(self.root, profile=document)
        run.assert_not_called()

    def test_fixed_subprocess_argv_budget_and_selected_root(self):
        with patch('rpgc_toolkit.pipeline.subprocess.run', return_value=result()) as run:
            report = run_preflight(self.root, profile=profile(('encounters', True)))
        self.assertTrue(report['ok'])
        args, kwargs = run.call_args
        self.assertEqual(args[0], [sys.executable, 'tools/build_encounters.py', '--check'])
        self.assertEqual(kwargs['cwd'], self.root)
        self.assertEqual(kwargs['timeout'], .25)
        self.assertIs(kwargs['shell'], False)

    def test_engine_and_modules_use_real_adapters_and_optional_fail_is_visible(self):
        config = profile(('engine', True), ('modules', False))
        with patch('rpgc_toolkit.pipeline.run_headless', return_value={'ok': True}) as headless, \
                patch('rpgc_toolkit.pipeline.run_module_checks', return_value={'ok': False}) as modules:
            report = run_preflight(self.root, binary='eve-test', profile=config)
        self.assertTrue(report['ok'])
        self.assertEqual(report['failed'], ['modules'])
        self.assertEqual(headless.call_args.kwargs['timeout'], .25)
        self.assertEqual(modules.call_args.kwargs['timeout'], .25)
        self.assertIn('validateProject()', headless.call_args.args[2])

    def test_false_or_malformed_asset_report_never_passes_exit_zero(self):
        for output in ['{"ok":false}', '{"ok":"yes"}', 'null', 'not json']:
            with self.subTest(output=output), patch('rpgc_toolkit.pipeline.subprocess.run', return_value=result(0, output)):
                report = run_preflight(self.root, profile=profile(('assets', True)))
                self.assertFalse(report['ok'])


if __name__ == '__main__':
    unittest.main()
