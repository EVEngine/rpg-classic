"""Read-only native map QA and disposable candidate QA; no geometry emulation."""
import hashlib
import json
from pathlib import Path
import re
import time
import math

from .changes import candidate_workspace, prepare_changes
from .project import fingerprint
from .runtime import run_headless


def map_id(value):
    if not isinstance(value, str) or (value and not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', value)):
        raise ValueError('map ID must be a stable content ID')
    return value


def input_manifest(root):
    """Exact native loader/validator inputs, including images and implementation."""
    root = Path(root).resolve()
    paths = [root / 'workflow.json']
    for directory in ('lib', 'schema', 'content', 'data'):
        paths.extend(sorted((root / directory).rglob('*')))
    records = {}
    for path in paths:
        if path.is_symlink():
            raise ValueError('symlink in map QA inputs: ' + str(path))
        if path.is_file():
            records[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {'sha256': fingerprint(records), 'files': records}


def qa_source(identifier=''):
    return ('import { RpgcMapQA } from "game:/lib/rpgc_map_qa.nut"\n'
            'RpgcToolkitResult <- RpgcJson.encodeCompact(RpgcMapQA.auditProject(' +
            json.dumps(map_id(identifier)) + '));\n')


def inspect_maps(binary, root, identifier='', timeout=120, changes=None, base=None):
    """Inspect native maps. Candidate changes pass the full gate before loading."""
    map_id(identifier)
    if type(timeout) not in (int,float) or not math.isfinite(timeout) or timeout<=0:
        raise ValueError('timeout must be positive and finite')
    deadline=time.monotonic()+timeout
    def remaining():
        budget=deadline-time.monotonic()
        if budget<=0:
            raise ValueError('map QA total budget exhausted')
        return budget
    if changes is not None:
        prepared = prepare_changes(root, changes, base)
        with candidate_workspace(root, prepared) as workspace:
            gate = run_headless(binary, workspace,
                'RpgcToolkitResult <- RpgcValidate.reportJson(RpgcValidate.validateProject());', remaining())
            if not gate.get('ok'):
                return {'ok': False, 'applied': False, 'rendered': False, 'gate': gate,
                        'diagnostics': gate.get('diagnostics', [])}
            report = inspect_maps(binary, workspace, identifier, remaining())
            report['gate'] = gate
            report['candidate'] = True
            return report
    before = input_manifest(root)
    sdk_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    report = run_headless(binary, root, qa_source(identifier), remaining())
    if before != input_manifest(root):
        raise ValueError('map QA inputs changed during inspection; retry on a stable tree')
    if sdk_hash != hashlib.sha256(Path(binary).read_bytes()).hexdigest():
        raise ValueError('SDK changed during map QA')
    remaining()
    report.update(applied=False, rendered=False, inputs=before, sdkSha256=sdk_hash)
    return report
