"""Adapters to the real Squirrel reference providers and battle simulator."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

IMPORTS = '''import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"
import { RpgcBattle } from "game:/lib/rpgc_battle.nut"
'''
MARKER = 'RPGC_TOOLKIT_RESULT='
GRAPH_SOURCE = '''local nodes = []; local edges = []; local diagnostics = [];
foreach (kind in RpgcProject.kinds()) {
    local module = RpgcValidate.moduleFor(kind);
    local loaded = RpgcProject.loadKind(kind);
    foreach (d in loaded.diagnostics) diagnostics.append(d);
    if (module == 0) {
        diagnostics.append({severity="error", code="graph.module-missing", path=kind,
                            message="no reference provider for kind"});
        continue;
    }
    if (!loaded.ok) continue;
    foreach (document in loaded.value) {
        local source = kind + "/" + document.id;
        nodes.append({id=source, path=RpgcProject.pathOf(kind, document.id)});
        foreach (reference in module.references(document)) {
            if (reference.kind == "" || reference.id == "") continue;
            edges.append({source=source, target=reference.kind + "/" + reference.id,
                          path=reference.path});
        }
    }
}
RpgcToolkitResult <- RpgcJson.encodeCompact({nodes=nodes, edges=edges, diagnostics=diagnostics});
'''


def graph_report(report, impact=None):
    report['nodes'].sort(key=lambda row: row['id'])
    report['edges'].sort(key=lambda row: (row['source'], row['target'], row['path']))
    report['ok'] = not any(d.get('severity') == 'error' for d in report['diagnostics'])
    report['validated'] = False
    if impact:
        if impact not in {node['id'] for node in report['nodes']}:
            raise ValueError('unknown graph node: ' + impact)
        seen, frontier, reverse = {impact}, [impact], {}
        for edge in report['edges']:
            reverse.setdefault(edge['target'], set()).add(edge['source'])
        while frontier:
            for source in reverse.get(frontier.pop(), ()):
                if source not in seen:
                    seen.add(source)
                    frontier.append(source)
        report['impact'] = sorted(seen - {impact})
    return report


def simulation_source(party, encounter, seed=1, runs=1, max_orders=512):
    if not all(type(n) is int for n in (seed, runs, max_orders)) or not 1 <= seed <= 2147483647 or not 1 <= runs <= 100 or not 1 <= max_orders <= 10000 or seed + runs - 1 > 2147483647:
        raise ValueError('seed must be positive int32; runs 1..100; max_orders 1..10000')
    for value in (party, encounter):
        if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
            raise ValueError('party and encounter must be nonempty IDs')
    # JSON strings and Squirrel strings share the escapes needed for IDs;
    # ensure_ascii=False avoids unsupported \\u escapes in EveScript.
    party, encounter = json.dumps(party, ensure_ascii=False), json.dumps(encounter, ensure_ascii=False)
    return f'''local rows = []; local diagnostics = []; local success = true;
local config = RpgcBattle.loadProject({party}, {encounter}, "");
if (!config.ok) {{
    success = false;
    foreach (d in config.diagnostics) diagnostics.append(d);
}} else {{
    for (local i = 0; i < {runs}; i += 1) {{
        config.value.seed <- {seed} + i;
        local made = RpgcBattle.newFight(config.value);
        if (!made.ok) {{
            success = false;
            foreach (d in made.diagnostics) diagnostics.append(d);
            break;
        }}
        RpgcBattle.runToEnd(made.value, {max_orders});
        local report = RpgcJson.parse(RpgcBattle.reportJson(made.value)).value;
        if (made.value.outcome == "stalled" || made.value.outcome == "") success = false;
        rows.append({{seed={seed} + i, fight=report, settlement=RpgcBattle.settlement(made.value)}});
    }}
}}
RpgcToolkitResult <- RpgcJson.encodeCompact({{ok=success, validated=false,
    simulator="RpgcBattle", runs=rows, diagnostics=diagnostics}});
'''


def run_headless(binary, root, source, timeout=120):
    """Run a bounded no-window VM script, deleting its temporary entry afterward.

    This bypasses the MCP/display host, never the simulation implementation.
    A crash, absent marker, or malformed output is a failure even if eve exits 0.
    """
    if not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('timeout must be positive and finite')
    root = Path(root).resolve()
    filename = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=root,
                                         prefix='.rpgc-toolkit-', suffix='.nut', delete=False) as file:
            filename = Path(file.name)
            file.write(IMPORTS + source + '\nprint("' + MARKER + '" + RpgcToolkitResult + "\\n");\n')
        env = dict(os.environ)
        env.setdefault('SDL_VIDEODRIVER', 'dummy')
        env.setdefault('SDL_AUDIODRIVER', 'dummy')
        process = subprocess.run([str(binary), 'run', '--no-window', '-r', filename.name],
                                 cwd=root, env=env, capture_output=True, text=True,
                                 errors='replace', timeout=timeout)
        output = process.stdout + '\n' + process.stderr
        if process.returncode:
            raise ValueError(f'headless eve failed ({process.returncode}): {output[-2000:]}')
        lines = [line[len(MARKER):] for line in output.splitlines() if line.startswith(MARKER)]
        if len(lines) != 1:
            raise ValueError(f'headless eve produced no unique result: {output[-2000:]}')
        return json.loads(lines[0])
    except subprocess.TimeoutExpired as error:
        raise ValueError(f'headless eve exceeded {timeout}s') from error
    finally:
        if filename is not None:
            filename.unlink(missing_ok=True)


def run_module_checks(binary, root, timeout=180):
    """Run the repository's full VM probe suite; require its explicit final PASS.

    eve run may exit zero on script assertion failures. Conversely a native
    crash after printing PASS must also fail. Check both the log and exit code.
    """
    import re
    if not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('timeout must be positive and finite')
    env = dict(os.environ)
    env.setdefault('SDL_VIDEODRIVER', 'dummy')
    env.setdefault('SDL_AUDIODRIVER', 'dummy')
    try:
        process = subprocess.run([str(binary), 'run', '--no-window', '-r', 'tools/modules_check.nut'],
                                 cwd=Path(root).resolve(), env=env, capture_output=True, text=True,
                                 errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ValueError(f'module checks exceeded {timeout}s') from error
    output = process.stdout + '\n' + process.stderr
    checks, summaries = [], []
    for line in output.splitlines():
        summary = re.fullmatch(r'\[modules\] (PASS|FAIL) \((\d+) failure\(s\)\)', line.strip())
        if summary:
            summaries.append(summary.groups())
            continue
        check = re.match(r'\[modules\] (ok|FAIL)\s+(\S+)(?:\s+(.*))?$', line.strip())
        if check:
            checks.append({'check':check[2], 'ok':check[1]=='ok', 'detail':check[3] or ''})
    ok = (process.returncode == 0 and summaries == [('PASS','0')] and bool(checks)
          and all(check['ok'] for check in checks))
    report = {'ok':ok, 'suite':'modules_check.nut', 'exitCode':process.returncode,
              'checks':checks, 'diagnostics':[]}
    if not ok:
        report['diagnostics'].append({'severity':'error','code':'selftest.modules-failed',
            'path':'tools/modules_check.nut',
            'message':'module suite failed, crashed, or did not produce a unique final PASS'})
        report['logTail'] = output[-4000:]
    return report
