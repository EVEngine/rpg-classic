"""Fail-closed, fixed-operation preflight profiles; never a shell runner.

Profiles are JSON data describing check IDs, requirement flags, and wall-clock
budgets. A profile cannot supply commands, scripts, arguments, or environment.
The selected project is trusted code: its fixed generator scripts and runtime
modules are executed, just as with the corresponding standalone tooling.
"""
from __future__ import annotations

import copy
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time

from .project import read_json
from .runtime import run_headless, run_module_checks

CHECK_IDS = frozenset({'engine', 'assets', 'placeholder-anims', 'encounters', 'modules', 'world-runtime', 'map-qa'})
RELEASE_REQUIRED = frozenset({'engine', 'assets', 'placeholder-anims', 'encounters'})


def _check(check_id, required=True, timeout=120):
    return {'id': check_id, 'required': required, 'timeoutSeconds': timeout}


DEFAULT_PROFILES = {
    'quick': {'version': 1, 'id': 'quick', 'checks': [
        _check('assets', timeout=30), _check('placeholder-anims', timeout=30),
        _check('encounters', timeout=30)]},
    'release': {'version': 1, 'id': 'release', 'checks': [
        _check('engine'), _check('assets', timeout=30),
        _check('placeholder-anims', timeout=30), _check('encounters', timeout=30),
        _check('modules', required=False, timeout=180)]},
}


def normalize_profile(profile='quick') -> dict:
    """Validate persisted JSON or a named default and return an independent copy."""
    if isinstance(profile, str):
        if profile not in DEFAULT_PROFILES:
            raise ValueError('unknown profile; use quick, release, or a profile object')
        profile = DEFAULT_PROFILES[profile]
    if not isinstance(profile, dict) or set(profile) - {'version', 'id', 'checks'}:
        raise ValueError('profile allows only version, id, and checks (no commands)')
    if type(profile.get('version', 1)) is not int or profile.get('version', 1) != 1:
        raise ValueError('unsupported preflight profile version')
    if not isinstance(profile.get('id'), str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', profile['id']):
        raise ValueError('profile requires a stable id')
    checks = profile.get('checks')
    if not isinstance(checks, list) or not checks:
        raise ValueError('profile requires a nonempty checks array')
    seen, required = set(), set()
    for check in checks:
        if not isinstance(check, dict) or set(check) != {'id', 'required', 'timeoutSeconds'}:
            raise ValueError('each check requires only id, required, and timeoutSeconds')
        name, budget = check['id'], check['timeoutSeconds']
        if not isinstance(name, str) or name not in CHECK_IDS or name in seen:
            raise ValueError('unknown or duplicate preflight check id')
        if type(check['required']) is not bool:
            raise ValueError('check required must be boolean')
        if type(budget) not in (int, float) or not math.isfinite(budget) or not 0 < budget <= 3600:
            raise ValueError('timeoutSeconds must be finite and between 0 and 3600')
        seen.add(name)
        if check['required']:
            required.add(name)
    if profile['id'] == 'release' and not RELEASE_REQUIRED <= required:
        raise ValueError('release requires engine, assets, placeholder-anims, and encounters')
    result = copy.deepcopy(profile)
    result.setdefault('version', 1)
    return result


def load_profile(path: Path) -> dict:
    """Read a persistent JSON profile with duplicate-key/nonfinite rejection."""
    return normalize_profile(read_json(path))


def _source_file(root, relative):
    path = root / relative
    if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
        raise ValueError(f'missing or unsafe required check implementation: {relative}')
    return path


def _subprocess_check(root, check_id, timeout):
    if check_id == 'assets':
        _source_file(root, 'tools/rpgc_toolkit/assets.py')
        # The program is a fixed constant, never interpolated from profile data.
        code = ('import json,sys; from pathlib import Path; '
                'sys.path.insert(0,str(Path.cwd()/"tools")); '
                'from rpgc_toolkit.assets import audit_assets; '
                'r=audit_assets(Path.cwd()); print(json.dumps(r)); '
                'sys.exit(0 if r.get("ok") is True else 1)')
        command = [sys.executable, '-c', code]
    else:
        script = {'placeholder-anims': 'tools/build_placeholder_anims.py',
                  'encounters': 'tools/build_encounters.py'}[check_id]
        _source_file(root, script)
        command = [sys.executable, script, '--check']
    process = subprocess.run(command, cwd=root, capture_output=True, text=True,
                             errors='replace', timeout=timeout, shell=False)
    output = process.stdout + '\n' + process.stderr
    detail = {'exitCode': process.returncode, 'logTail': output[-4000:]}
    if check_id == 'assets':
        try:
            report = json.loads(process.stdout)
        except (ValueError, TypeError) as error:
            raise ValueError('asset check produced no valid JSON report: ' + output[-1000:]) from error
        if not isinstance(report, dict) or type(report.get('ok')) is not bool:
            raise ValueError('asset check produced an invalid report')
        detail['report'] = report
        return process.returncode == 0 and report['ok'], detail
    return process.returncode == 0, detail


def _execute(root, binary, check):
    name, budget = check['id'], check['timeoutSeconds']
    if name == 'engine':
        _source_file(root, 'lib/rpgc_validate.nut')
        report = run_headless(binary, root,
                              'RpgcToolkitResult <- RpgcValidate.reportJson(RpgcValidate.validateProject());',
                              timeout=budget)
        if not isinstance(report, dict) or type(report.get('ok')) is not bool:
            raise ValueError('engine produced an invalid validation report')
        return report['ok'], report
    if name == 'map-qa':
        from .map_qa import inspect_maps
        report = inspect_maps(binary, root, timeout=budget)
        return report['ok'], report
    if name == 'world-runtime':
        from .world_checks import run_world_checks
        report = run_world_checks(binary, root, timeout=budget)
        return report['ok'], report
    if name == 'modules':
        _source_file(root, 'tools/modules_check.nut')
        report = run_module_checks(binary, root, timeout=budget)
        if not isinstance(report, dict) or type(report.get('ok')) is not bool:
            raise ValueError('module suite produced an invalid report')
        return report['ok'], report
    return _subprocess_check(root, name, budget)


def run_preflight(root: Path, binary: str | None = None, profile='quick') -> dict:
    """Run every selected check, retaining failures and proceeding to the next.

    Missing eve fails required VM checks, skips optional VM checks. An optional
    check that actually runs and fails is reported as fail but does not block
    `ok`; required checks must all pass. A release profile cannot weaken its
    four required gates. Custom profiles may choose their own fixed-ID subset.
    All execution receives finite wall-clock budgets, including asset inspection.
    """
    config = normalize_profile(profile)
    root = Path(root).resolve()
    started = time.monotonic()
    rows = []
    for check in config['checks']:
        begin = time.monotonic()
        row = {'id': check['id'], 'required': check['required'], 'status': 'fail',
               'timeoutSeconds': check['timeoutSeconds'], 'diagnostics': []}
        try:
            if not root.is_dir() or not (root / 'workflow.json').is_file():
                raise ValueError('project root must contain workflow.json')
            if check['id'] in {'engine', 'modules', 'world-runtime', 'map-qa'} and not binary:
                if check['required']:
                    raise ValueError('required engine binary was not supplied')
                row['status'] = 'skipped'
                row['diagnostics'].append({'severity': 'info', 'code': 'preflight.no-engine',
                                           'message': 'optional VM check skipped: no engine binary supplied'})
            else:
                passed, detail = _execute(root, binary, check)
                row['status'] = 'pass' if passed else 'fail'
                row['detail'] = detail
                if not passed:
                    row['diagnostics'].append({'severity': 'error', 'code': 'preflight.check-failed',
                                               'message': 'check failed; inspect detail for its diagnostics'})
        except subprocess.TimeoutExpired:
            row['diagnostics'].append({'severity': 'error', 'code': 'preflight.timeout',
                                       'message': f"check exceeded {check['timeoutSeconds']} seconds"})
        except (OSError, ValueError, TypeError, KeyError) as error:
            code = 'preflight.timeout' if isinstance(error.__cause__, subprocess.TimeoutExpired) else 'preflight.error'
            row['diagnostics'].append({'severity': 'error', 'code': code, 'message': str(error)})
        row['durationMs'] = round((time.monotonic() - begin) * 1000, 3)
        rows.append(row)
    return {'ok': all(row['status'] == 'pass' for row in rows if row['required']),
            'profile': config['id'], 'profileDefinition': config, 'checks': rows,
            'durationMs': round((time.monotonic() - started) * 1000, 3),
            'failed': [row['id'] for row in rows if row['status'] == 'fail'],
            'skipped': [row['id'] for row in rows if row['status'] == 'skipped']}
