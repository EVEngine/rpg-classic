#!/usr/bin/env python3
"""Real owned-window smoke: retained UI events plus inspector handler calls.

Requires a rendered SDK environment (for example xvfb-run plus software Vulkan).
Does not inject OS mouse/keyboard input or replace engine/rules implementations.
Run serially with other rendered verification tools.
"""
import argparse
import json
import multiprocessing
import sys
from pathlib import Path
import time

from rpgc import McpClient
from rpgc_toolkit.map_preview import open_map


def worker(connection, binary, root, identifier, timeout):
    # Observe the backend-selected port, then hand it off only once open_map
    # closes its startup client and enters the user-controlled window wait.
    original = McpClient.__init__
    original_close = McpClient.close
    observed_clients = {}
    def observed(self, host, port, *args, **kwargs):
        original(self, host, port, *args, **kwargs)
        observed_clients[id(self)] = {'port':port,'host':host}
    def handed_off(self):
        original_close(self)
        endpoint = observed_clients.pop(id(self), None)
        if endpoint is not None:
            connection.send(endpoint)
    McpClient.__init__ = observed
    McpClient.close = handed_off
    try:
        report = open_map(binary, root, identifier, timeout=timeout)
        connection.send({'result': report})
    except BaseException as error:
        connection.send({'error': str(error)})
    finally:
        McpClient.__init__ = original
        McpClient.close = original_close
        connection.close()


def run(binary, root, identifier, timeout):
    context = multiprocessing.get_context('spawn')
    parent, child = context.Pipe()
    process = context.Process(target=worker, args=(child, binary, root, identifier, timeout))
    process.start(); child.close()
    client = None
    checks = []
    deadline = time.monotonic() + timeout
    def progress(message):
        print('[map-inspector-window] ' + message, file=sys.stderr, flush=True)
    def check(name, condition):
        progress(name + (': PASS' if condition else ': FAIL'))
        checks.append({'name':name,'ok':bool(condition)})
        if not condition:
            raise ValueError('window smoke failed: ' + name)
    def status():
        envelope = json.loads(client.call('eve_eval', {'expression':'previewStatus()'}))
        if not envelope.get('ok'):
            raise ValueError('native inspector status unavailable: ' + str(envelope))
        value = envelope['value']
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        report = json.loads(value)
        if report['error']:
            raise ValueError(report['error'])
        return report
    def wait_state(predicate):
        while time.monotonic() < deadline:
            report = status()
            if predicate(report['state']):
                return report
            time.sleep(.05)
        raise ValueError('retained UI event did not update inspector state before deadline')
    def click(widget):
        queued = json.loads(client.call('eve_ui_click', {'host':'inspector','widget':widget}))
        if not queued.get('queued'):
            raise ValueError('native UI click was not queued: ' + str(queued))
    def script(source):
        result = client.call('eve_run_script', {'source':source})
        if result.strip() != 'ok':
            raise ValueError('native inspector command failed: ' + result)
    try:
        progress('waiting for backend startup MCP handoff')
        if not parent.poll(timeout):
            raise ValueError('open_map did not expose its actual MCP port before deadline')
        message = parent.recv()
        if 'port' not in message:
            raise ValueError(str(message))
        endpoint = (message['host'], message['port'])
        client = McpClient(*endpoint, timeout=max(.1,deadline-time.monotonic()), deadline=deadline)
        client.initialize()
        progress('connected after backend startup handoff')
        while True:
            initial = status()
            if initial['frames'] >= 3:
                break
            if time.monotonic() >= deadline:
                raise ValueError('inspector did not present first frames')
            time.sleep(.05)
        check('rendered-first-frames', initial['frames'] >= 3)
        check('open-map-remains-running', process.is_alive() and not parent.poll())
        before = initial['state']
        click('blocked')
        toggled = wait_state(lambda state: state['blocked'] != before['blocked'])
        check('retained-ui-blocked-toggle', toggled['state']['blocked'] != before['blocked'])
        click('objects')
        toggled = wait_state(lambda state: state['objects'] != before['objects'])
        check('retained-ui-objects-toggle', toggled['state']['objects'] != before['objects'])
        click('changes')
        toggled = wait_state(lambda state: state['changes'] != before['changes'])
        check('retained-ui-changes-toggle', toggled['state']['changes'] != before['changes'])
        click('object-1')
        chosen = wait_state(lambda state: state['selectedObject'] == 1)
        check('retained-ui-object-selection', chosen['state']['selectedObject'] == 1)
        script('if(!previewAction("select-cell",0))throw "selection rejected";')
        selected = status()
        check('actual-cell-selection-handler', selected['state']['selectedX'] == 0 and selected['state']['selectedY'] == 0
              and selected['state']['selectionCount'] > before['selectionCount'])
        click('zoom-in')
        zoomed = wait_state(lambda state: state['zoom'] > selected['state']['zoom'])
        check('retained-ui-camera-zoom', zoomed['state']['zoom'] > selected['state']['zoom'])
        check('window-still-owned-before-platform-quit', process.is_alive() and not parent.poll())
        # The bootstrap ignores quit during its first 45 startup frames.
        # Observe actual presented frames instead of mutating its grace counter.
        progress('waiting for native startup grace to finish (at least 50 frames)')
        while True:
            ready = status()
            if ready['frames'] >= 50:
                break
            if time.monotonic() >= deadline:
                raise ValueError('startup grace did not finish before deadline')
            time.sleep(.05)
        check('startup-grace-finished', ready['frames'] >= 50)
        progress('sending native platform quit event')
        # Exercise the SDK bootstrap's actual quit-event shutdown path.
        # Window.close() alone destroys the window but does not stop load.nut's
        # event loop. Transport may close before the quit RPC response arrives.
        try:
            script('eve.PlatformEvent().pushData("quit","");')
        except (OSError, RuntimeError):
            pass
        progress('waiting for owned engine normal shutdown')
        if not parent.poll(max(.1, deadline-time.monotonic())):
            raise ValueError('open_map did not return after native platform-quit shutdown')
        message = parent.recv()
        if 'result' not in message:
            raise ValueError(str(message))
        result = message['result']
        process.join(timeout=5)
        check('normal-platform-quit-returned', result.get('ok') and result.get('rendered') and result.get('closedByUser'))
        check('worker-clean-exit', not process.is_alive() and process.exitcode == 0)
        # A new TCP connection must fail once the owned engine has exited.
        import socket
        listening = False
        try:
            with socket.create_connection(endpoint, timeout=.2):
                listening = True
        except OSError:
            pass
        check('owned-engine-port-closed', not listening)
        return {'ok':True,'realHost':True,'rendered':True,
                'inputMode':'MCP eve_ui_click retained UI events and select-cell handler; no OS input injection',
                'shutdownMode':'native PlatformEvent quit consumed by SDK bootstrap; Window.close alone is insufficient',
                'checks':checks,'initial':initial,'after':zoomed,'windowResult':result}
    finally:
        if client is not None:
            client.close()
        if process.is_alive():
            # Give open_map's finally block an opportunity to stop its owned SDK.
            import signal
            process_pid = process.pid
            try:
                import os
                os.kill(process_pid, signal.SIGINT)
            except ProcessLookupError:
                pass
            process.join(timeout=10)
            if process.is_alive():
                process.terminate(); process.join(timeout=5)
        parent.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--eve',required=True)
    parser.add_argument('--root',default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--map',default='village-outskirts')
    parser.add_argument('--timeout',type=float,default=120)
    args=parser.parse_args()
    if not 0 < args.timeout <= 600:
        parser.error('--timeout must be in (0,600]')
    try:
        result=run(str(Path(args.eve).resolve()),str(Path(args.root).resolve()),args.map,args.timeout)
        print(json.dumps(result,ensure_ascii=False,indent=2))
        return 0
    except (OSError,ValueError,RuntimeError,EOFError) as error:
        print(json.dumps({'ok':False,'realHost':True,'error':str(error)},ensure_ascii=False,indent=2))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
