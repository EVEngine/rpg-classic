"""Fail-closed aggregation of fixed shared-runtime VM probes."""
import json
import os
from pathlib import Path
import subprocess
import time

PROBES = (
    ('world', 'tools/world_runtime_check.nut', 'RPGC_WORLD_RUNTIME='),
    ('dialogue', 'tools/dialogue_check.nut', 'RPGC_DIALOGUE_RESULT='),
    ('quests', 'tools/quest_check.nut', 'RPGC_QUEST_RESULT='),
    ('saves', 'tools/save_check.nut', 'RPGC_SAVE='),
)


def run_world_checks(binary, root, timeout=120):
    import math
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('timeout must be positive and finite')
    root=Path(root).resolve()
    environment=dict(os.environ)
    environment.setdefault('SDL_VIDEODRIVER','dummy')
    environment.setdefault('SDL_AUDIODRIVER','dummy')
    deadline=time.monotonic()+timeout
    results=[]
    for name, script, marker in PROBES:
        path=root/script
        remaining=deadline-time.monotonic()
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
            results.append({'id':name,'ok':False,'error':'missing or unsafe probe script'})
            continue
        if remaining <= 0:
            results.append({'id':name,'ok':False,'error':'shared timeout exhausted'})
            continue
        try:
            process=subprocess.run([str(binary),'run','--no-window','-r',script],cwd=root,env=environment,
                                   capture_output=True,text=True,errors='replace',timeout=remaining)
            output=process.stdout+'\n'+process.stderr
            reports=[line[len(marker):] for line in output.splitlines() if line.startswith(marker)]
            if process.returncode != 0 or len(reports) != 1:
                raise ValueError(f'probe exit={process.returncode}; unique report required: {output[-1500:]}')
            report=json.loads(reports[0])
            checks=report.get('checks') if isinstance(report,dict) else None
            if not isinstance(checks,list) or not checks or any(not isinstance(row,dict) or type(row.get('ok')) is not bool for row in checks):
                raise ValueError('probe report requires nonempty boolean checks')
            passed=report.get('ok') is True and all(row['ok'] for row in checks)
            results.append({'id':name,'ok':passed,'report':report})
        except (ValueError,OSError,subprocess.TimeoutExpired) as error:
            results.append({'id':name,'ok':False,'error':str(error)})
    return {'ok':all(row['ok'] for row in results),'checks':results,'rendered':False}
