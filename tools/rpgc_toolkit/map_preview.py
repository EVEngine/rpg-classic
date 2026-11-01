"""Single-purpose native map window, bounded capture and owned process cleanup."""
import hashlib
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from .map_qa import input_manifest, map_id, inspect_maps
from .changes import candidate_workspace, prepare_changes
from .project import Project, inside, read_json, fingerprint
from .runtime import run_headless
from .map_diff import map_diff
from .map_preview_app import preview_source


def _map_document(root, identifier):
    spec = Project(root).kinds['map']
    path = inside(root, spec['directory'] + '/' + identifier + spec.get('extension', '.json'))
    return read_json(path) if path.exists() else None


def render_map(binary, root, identifier, screenshot, timeout=120, changes=None, base=None, inspector=True, actions=None):
    """Capture a disposable map inspector; source project and candidates stay untouched."""
    return _preview(binary, root, identifier, screenshot, timeout, changes, base, inspector, False, actions)


def open_map(binary, root, identifier, timeout=120, changes=None, base=None, inspector=True, actions=None):
    """Open a disposable inspector until the user closes it.

    timeout bounds validation/startup/first frames. After those succeed, window
    lifetime is user-controlled; Ctrl-C also closes only the owned process.
    """
    return _preview(binary, root, identifier, None, timeout, changes, base, inspector, True, actions)


def validate_actions(actions):
    if actions is None:
        return []
    allowed = {'blocked','objects','changes','fit','zoom-in','zoom-out',
               'select-object','select-cell','diagnostic'}
    indexed = {'select-object','select-cell','diagnostic'}
    if not isinstance(actions, list) or len(actions)>64:
        raise ValueError('preview actions must be an array of at most 64 commands')
    result = []
    for row in actions:
        if not isinstance(row,dict) or not {'action'} <= set(row) <= {'action','arg'}:
            raise ValueError('preview action requires action and optional arg only')
        action, arg = row['action'], row.get('arg',0)
        if not isinstance(action,str) or action not in allowed:
            raise ValueError('unknown preview action')
        if type(arg) is not int or not 0<=arg<=65535 or (action not in indexed and arg!=0):
            raise ValueError('preview arg must be an index 0..65535, or zero for a non-indexed action')
        result.append({'action':action,'arg':arg})
    return result


def _preview(binary, root, identifier, screenshot, timeout, changes, base, inspector, window, actions):
    actions = validate_actions(actions)
    map_id(identifier)
    if not identifier:
        raise ValueError('preview requires a map ID')
    if type(inspector) is not bool:
        raise ValueError('inspector must be a boolean')
    if type(timeout) not in (int,float) or not math.isfinite(timeout) or timeout<=0:
        raise ValueError('timeout must be positive and finite')
    deadline = time.monotonic()+timeout
    def remaining():
        budget = deadline-time.monotonic()
        if budget<=0:
            raise ValueError('preview total budget exhausted')
        return budget
    root = Path(root).resolve()
    source_inputs = input_manifest(root)
    prepared = prepare_changes(root, changes, base) if changes is not None else []
    original = _map_document(root, identifier)
    # Copy unmodified inputs first so the source freeze can be checked exactly.
    # Overlay prepared documents only inside that admitted disposable copy.
    with candidate_workspace(root, []) as workspace:
        if source_inputs != input_manifest(workspace) or source_inputs != input_manifest(root):
            raise ValueError('preview inputs changed while creating the isolated app')
        for change in prepared:
            path = inside(workspace, change['path'])
            if change['delete']:
                path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(change['document'],ensure_ascii=False,allow_nan=False)+'\n', encoding='utf-8')
        candidate_inputs = input_manifest(workspace)
        source = {'inputsSha256': source_inputs['sha256'],
                  'mapFingerprint': fingerprint(original) if original is not None else None}
        candidate = {'enabled': changes is not None, 'inputsSha256': candidate_inputs['sha256'],
                     'changes': [{key: row.get(key) for key in ('path','kind','before','after','delete')}
                                 for row in prepared]}
        gate = run_headless(binary, workspace,
            'RpgcToolkitResult <- RpgcValidate.reportJson(RpgcValidate.validateProject());', remaining())
        summary = {'applied':False,'source':source,'candidate':candidate,'gate':gate}
        if not gate.get('ok'):
            return dict(summary, ok=False, rendered=False, diagnostics=gate.get('diagnostics', []))
        candidate_doc = _map_document(workspace, identifier)
        candidate['mapFingerprint'] = fingerprint(candidate_doc) if candidate_doc is not None else None
        # Source may be malformed while a candidate repairs it. Diff is optional
        # presentation data; a malformed source must not break a valid preview.
        try:
            difference = map_diff(original, candidate_doc)
        except (KeyError, TypeError, IndexError, ValueError):
            difference = {'mapId':identifier,'available':False,
                          'reason':'source map cannot be compared structurally'}
        qa = inspect_maps(binary, workspace, identifier, remaining())
        context = {'qa':qa,'diff':difference,'source':source,'candidate':candidate,'inspector':inspector}
        qa_value = qa.get('value') if isinstance(qa.get('value'), dict) else {}
        if not any(row.get('id') == identifier for row in qa_value.get('maps', [])):
            return dict(summary, ok=False, rendered=False, qa=qa, diff=difference,
                        diagnostics=qa.get('diagnostics', []))
        if candidate_inputs != input_manifest(workspace):
            raise ValueError('candidate inputs changed before preview rendering')
        result = _render_map_workspace(binary, workspace, identifier, screenshot, remaining(), context, window, actions)
        result.update(summary)
        result.update(qa=qa,diff=difference,diagnostics=qa.get('diagnostics', []),
                      ok=bool(result.get('ok')) and bool(qa.get('ok')))
        return result


def _render_map_workspace(binary, root, identifier, screenshot, timeout=120, context=None, window=False, actions=None):
    """Render via actual engine. Refuse existing output; do not launch main game."""
    from rpgc import McpClient
    actions = validate_actions(actions)
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('timeout must be positive and finite')
    root = Path(root).resolve()
    output = Path(screenshot).absolute() if screenshot is not None else None
    if not window and output is None:
        raise ValueError("screenshot path required in capture mode")
    if output is not None and (output.exists() or output.is_symlink()):
        raise ValueError('preview output already exists')
    if output is not None and not output.parent.is_dir():
        raise ValueError('preview output directory must exist')
    if output is not None and output.suffix.lower() != '.png':
        raise ValueError('preview output must be PNG')
    source = preview_source(identifier, context)
    before = input_manifest(root)
    sdk_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    process = client = entry = None
    deadline = time.monotonic() + timeout
    with tempfile.TemporaryDirectory(prefix='rpgc-map-preview-') as temporary:
        temp = Path(temporary)
        capture = temp / 'frame.png'
        try:
            entry = root / 'main.nut'
            entry.write_text(source, encoding='utf-8')
            (root / 'config.nut').write_text('config = {width=1280,height=720,title="RPG map preview",debug=false,hotReload=false,editorHost=false};\n', encoding='utf-8')
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
            with (temp / 'engine.log').open('wb') as log:
                environment = dict(os.environ)
                environment.setdefault('SDL_AUDIODRIVER', 'dummy')
                process = subprocess.Popen([str(binary), 'run', '--mcp-port', str(port), '.'],
                    cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
                while True:
                    if process.poll() is not None:
                        raise ValueError('preview engine exited: ' + (temp / 'engine.log').read_text(errors='replace')[-2000:])
                    if time.monotonic() >= deadline:
                        raise ValueError('preview window startup timed out')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.2):
                            break
                    except OSError:
                        time.sleep(.05)
                client = McpClient('127.0.0.1', port, timeout=max(.001, deadline-time.monotonic()), deadline=deadline)
                client.initialize()

                def status():
                    answer = json.loads(client.call('eve_eval', {'expression': 'previewStatus()'}))
                    if not answer.get('ok'):
                        raise ValueError('preview report unavailable: ' + str(answer))
                    value = answer['value']
                    if value.startswith('"') and value.endswith('"'):
                        value = value[1:-1]
                    report = json.loads(value)
                    if report['error']:
                        raise ValueError(report['error'])
                    return report

                def wait_frames(count):
                    while time.monotonic() < deadline:
                        report = status()
                        if report['frames'] >= count:
                            return report
                        time.sleep(.05)
                    raise ValueError('preview rendering timed out')

                report = wait_frames(3)
                action_reports = []
                for action in actions:
                    before_state = report.get('state')
                    command = 'if(!previewAction(' + json.dumps(action['action']) + ',' + str(action['arg']) + '))throw "preview action rejected";'
                    accepted = client.call('eve_run_script', {'source':command})
                    if accepted.strip() != 'ok':
                        raise ValueError('preview action failed: ' + accepted)
                    report = wait_frames(report['frames'] + 1)
                    action_reports.append(dict(action,before=before_state,after=report.get('state')))
                if window:
                    # Startup succeeded. This wait deliberately has no timeout:
                    # normal window close is the user's explicit lifecycle control.
                    client.close(); client = None
                    code = process.wait()
                    if code != 0:
                        raise ValueError('preview window exited with status ' + str(code))
                    if before != input_manifest(root):
                        raise ValueError('preview inputs changed while window was open')
                    if sdk_hash != hashlib.sha256(Path(binary).read_bytes()).hexdigest():
                        raise ValueError('SDK changed while preview window was open')
                    return {'ok':True,'rendered':True,'applied':False,'window':True,
                            'closedByUser':True,'frames':report['frames'],'inputs':before,
                            'actions':action_reports,'state':report.get('state'),
                            'previewAppSha256':hashlib.sha256(source.encode()).hexdigest(),
                            'previewConfig':{'width':1280,'height':720,'hotReload':False},
                            'sdkSha256':sdk_hash,'screenshot':None}
                command = 'PreviewGfx.saveFramePng(' + json.dumps(str(capture)) + ')'
                client.call('eve_run_script', {'source': command + ';'})
                report = wait_frames(report['frames'] + 3)
                result = client.call('eve_run_script', {'source': 'if(!' + command + ')throw "native frame capture failed";'})
                if result.strip() != 'ok' or not capture.is_file():
                    raise ValueError('native frame capture failed: ' + result)
                data = capture.read_bytes()
                if data[:8] != b'\x89PNG\r\n\x1a\n':
                    raise ValueError('native capture is not a PNG')
                if before != input_manifest(root):
                    raise ValueError('preview inputs changed during rendering')
                if sdk_hash != hashlib.sha256(Path(binary).read_bytes()).hexdigest():
                    raise ValueError('SDK changed during preview')
                if time.monotonic() >= deadline:
                    raise ValueError('preview total budget exhausted')
                # Publish only a complete PNG; exclusive link refuses a race
                # with another writer and failures leave no truncated output.
                staged = None
                try:
                    with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.rpgc-preview-', delete=False) as handle:
                        staged = Path(handle.name)
                        handle.write(data)
                        handle.flush()
                    os.link(staged, output)
                finally:
                    if staged is not None:
                        staged.unlink(missing_ok=True)
                return {'ok': True, 'rendered': True, 'applied': False, 'frames': report['frames'],
                        'qa': report['qa'], 'inputs': before,
                        'actions':action_reports,'state':report.get('state'),
                        'previewAppSha256': hashlib.sha256(source.encode()).hexdigest(),
                        'previewConfig': {'width':1280,'height':720,'hotReload':False},
                        'sdkSha256': sdk_hash,
                        'screenshot': str(output), 'screenshotSha256': hashlib.sha256(data).hexdigest()}
        except (OSError, ValueError, RuntimeError) as error:
            log_path = temp / 'engine.log'
            tail = log_path.read_text(errors='replace')[-2500:] if log_path.exists() else ''
            raise ValueError(str(error) + '\n' + tail) from error
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
            if client is not None:
                client.close()
            if entry is not None:
                entry.unlink(missing_ok=True)
