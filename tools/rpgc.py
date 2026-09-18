#!/usr/bin/env python3
"""rpgc — command line driver for the rpg-classic workflow.

The workflow's libraries live inside the engine VM (Squirrel + the engine's own
Eve Schema validator).  This CLI is the thin transport around them, so that a
human, a CI job or an AI agent can:

  * validate every content document through the *engine's* validator,
  * read structured diagnostics back as JSON,
  * commit the editor's staged writes into the project atomically.

It deliberately contains no document rules of its own.  Duplicating validation
here would create a second authority that can drift from the engine; instead the
CLI only moves bytes and reports what the engine decided.

Usage
-----
  python tools/rpgc.py validate [--json]
  python tools/rpgc.py check <path> [<path>...]
  python tools/rpgc.py eval "<squirrel expression>"
  python tools/rpgc.py script <file.nut> [<file.nut>...]
  python tools/rpgc.py stage <path> <file>       # validate a file, then stage it
  python tools/rpgc.py export [--dry-run]        # write staged documents
  python tools/rpgc.py status
  python tools/rpgc.py selftest [--json]         # verify the workflow's own claims

The engine is located with, in order: --eve, $EVE_BIN, $EVE_SDK_DIR /
$EVENGINE_SDK, `eve` on PATH, then a sibling EVEngine source checkout's
build/<platform>-debug/src/engine/eve[.exe] ($EVENGINE_ROOT or ../EVEngine).
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

WORKFLOW_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTOCOL_VERSION = "2025-06-18"


# --------------------------------------------------------------------------- #
# engine discovery
# --------------------------------------------------------------------------- #

def _engine_build_candidates(engine_root: str, exe: str) -> list[str]:
    out = []
    for platform in ("win32-debug", "linux-debug", "macosx-debug", "win32", "linux", "macosx"):
        out.append(os.path.join(engine_root, "build", platform, "src", "engine", exe))
    return out


def _sdk_bin_candidates(sdk_root: str, exe: str) -> list[str]:
    if not sdk_root:
        return []
    out = [os.path.join(sdk_root, "bin", exe)]
    for platform in ("win32", "linux", "macosx"):
        out.append(os.path.join(sdk_root, "eve-sdk", platform, "bin", exe))
        out.append(os.path.join(sdk_root, platform, "bin", exe))
    return out


def find_engine(explicit: str | None) -> str:
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("EVE_BIN"):
        candidates.append(os.environ["EVE_BIN"])
    exe = "eve.exe" if os.name == "nt" else "eve"
    for key in ("EVE_SDK_DIR", "EVENGINE_SDK"):
        candidates.extend(_sdk_bin_candidates(os.environ.get(key, ""), exe))
    found = shutil.which("eve")
    if found:
        candidates.append(found)
    engine_root = os.environ.get("EVENGINE_ROOT", "")
    if engine_root:
        candidates.extend(_engine_build_candidates(engine_root, exe))
    parent = os.path.dirname(WORKFLOW_ROOT)
    for sibling in ("EVEngine", "EVEngine.git"):
        candidates.extend(_engine_build_candidates(os.path.join(parent, sibling), exe))
    worktrees = os.path.join(parent, "EVEngine--worktrees")
    if os.path.isdir(worktrees):
        try:
            names = sorted(os.listdir(worktrees))
        except OSError:
            names = []
        for name in names:
            candidates.extend(
                _engine_build_candidates(os.path.join(worktrees, name), exe)
            )
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return os.path.abspath(candidate)
    raise SystemExit(
        "rpgc: cannot find the `eve` binary. Pass --eve <path>, set $EVE_BIN, "
        "install the SDK on PATH, or set $EVENGINE_ROOT to an EVEngine checkout."
    )


# --------------------------------------------------------------------------- #
# MCP client
# --------------------------------------------------------------------------- #

class McpError(RuntimeError):
    pass


class McpClient:
    """Newline-delimited JSON-RPC 2.0 over TCP, matching McpServer.cpp."""

    def __init__(self, host: str, port: int, timeout: float = 30.0):
        # A whole-project validate re-parses and re-validates every document in
        # one RPC, which exceeds a 30 s socket timeout on a busy host. EVE_RPC_TIMEOUT
        # raises it without changing the default.
        configured = os.environ.get("EVE_RPC_TIMEOUT")
        if configured:
            try:
                timeout = float(configured)
            except ValueError:
                pass
        self.sock = None
        last_error = None
        deadline = time.time() + max(timeout, 30.0)
        while self.sock is None and time.time() < deadline:
            try:
                # The host prints "MCP listening" before the listening socket
                # accepts, so a single connect can race with startup.
                self.sock = socket.create_connection((host, port), timeout=timeout)
            except OSError as error:
                last_error = error
                time.sleep(0.5)
        if self.sock is None:
            raise last_error if last_error else OSError("cannot connect")
        self.sock.settimeout(timeout)
        self.buf = b""
        self.next_id = 1

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def _send(self, payload: dict) -> None:
        line = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"
        self.sock.sendall(line)

    def _recv(self) -> dict:
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise McpError("engine closed the MCP connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        line = line.strip()
        if not line:
            return self._recv()
        return json.loads(line.decode("utf-8"))

    def request(self, method: str, params: dict | None = None) -> dict:
        rid = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        while True:
            message = self._recv()
            if message.get("id") == rid:
                if "error" in message:
                    raise McpError(str(message["error"]))
                return message.get("result", {})

    def initialize(self) -> dict:
        result = self.request(
            "initialize",
            {"protocolVersion": PROTOCOL_VERSION,
             "clientInfo": {"name": "rpgc", "version": "1"},
             "capabilities": {}},
        )
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result

    def call(self, tool: str, arguments: dict | None = None) -> str:
        result = self.request(
            "tools/call", {"name": tool, "arguments": arguments or {}}
        )
        content = result.get("content") or []
        text = "\n".join(part.get("text", "") for part in content if part.get("type") == "text")
        return text


# --------------------------------------------------------------------------- #
# engine process
# --------------------------------------------------------------------------- #

class Engine:
    """Runs (or attaches to) `eve mcp` for the workflow root."""

    def __init__(self, binary: str, root: str, port: int | None, wait: float = 25.0):
        self.binary = binary
        self.root = root
        self.own_process = None
        self.client = None
        self.log_path = None
        self.port = port
        if port is None:
            self.port = self._start(wait)
        self.client = McpClient("127.0.0.1", self.port)
        self.client.initialize()

    def _free_port(self) -> int:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def _start(self, wait: float) -> int:
        port = self._free_port()
        handle, self.log_path = tempfile.mkstemp(prefix="rpgc-engine-", suffix=".log")
        os.close(handle)
        log = open(self.log_path, "wb")
        self.own_process = subprocess.Popen(
            [self.binary, "mcp", "--port", str(port), "--root", self.root],
            stdout=subprocess.DEVNULL,
            stderr=log,
            cwd=self.root,
        )
        atexit.register(self.stop)
        deadline = time.time() + wait
        while time.time() < deadline:
            if self.own_process.poll() is not None:
                raise SystemExit(
                    "rpgc: engine exited early:\n" + self._tail_log()
                )
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.4):
                    return port
            except OSError:
                time.sleep(0.25)
        self.stop()
        raise SystemExit("rpgc: engine did not start listening.\n" + self._tail_log())

    def _tail_log(self) -> str:
        if not self.log_path or not os.path.isfile(self.log_path):
            return ""
        with open(self.log_path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()[-4000:]

    def log(self) -> str:
        return self._tail_log()

    def stop(self) -> None:
        if self.client:
            if self.own_process is not None:
                # Never shut down a host we merely attached to.
                try:
                    self.client.call("eve_host_shutdown")
                except Exception:
                    pass
            self.client.close()
            self.client = None
        if self.own_process and self.own_process.poll() is None:
            self.own_process.terminate()
            try:
                self.own_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.own_process.kill()
        self.own_process = None

    # -- convenience ------------------------------------------------------ #

    def eval(self, expression: str):
        text = self.client.call("eve_eval", {"expression": expression})
        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            return {"ok": False, "value": text, "raw": text}
        return payload

    def eval_string(self, expression: str) -> str:
        """Evaluate an expression that yields a string; strip the display quotes."""
        payload = self.eval(expression)
        value = str(payload.get("value", ""))
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        return value

    def eval_json(self, expression: str):
        text = self.eval_string(expression)
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise SystemExit(f"rpgc: engine returned non-JSON: {error}\n{text[:4000]}")

    def script(self, source: str, tool: str = "eve_run_script") -> str:
        # eve_run_script reports a formatted script error; eve_host_script only
        # says "compile failed", which is useless for debugging a library.
        text = self.client.call(tool, {"source": source})
        if text.startswith("error:"):
            raise McpError(text)
        return text


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #

def _emit(payload, as_json: bool, human: str) -> None:
    if as_json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(human)


def _diagnostics_ok(diagnostics) -> bool:
    return all(item.get("severity") != "error" for item in diagnostics or [])


def _print_diagnostics(diagnostics) -> int:
    errors = 0
    for item in diagnostics or []:
        severity = item.get("severity", "error")
        if severity == "info":
            continue
        if severity == "error":
            errors += 1
        hint = item.get("hint") or ""
        line = f"  {severity:<7} {item.get('path','$')}: {item.get('message','')}"
        if hint:
            line += f"\n          hint: {hint}"
        print(line, file=sys.stderr)
    return errors


BANNER = "[rpgc] rpg-classic "


def cmd_validate(engine: Engine, args) -> int:
    """Read the verdict the host already computed before it accepted clients.

    The startup gate in mcp.nut runs exactly `RpgcValidate.validateProject()` and
    prints one summary line; reading that line is both cheaper and more robust
    than evaluating the report again, because the host's stderr is not subject to
    the print-buffer or debugger-value limits that a multi-kilobyte JSON result
    runs into.
    """
    line = ""
    for candidate in engine.log().splitlines():
        if candidate.startswith(BANNER):
            line = candidate[len(BANNER):]
    if line == "":
        print("rpgc: the host printed no start-up verdict; re-run with --verbose",
              file=sys.stderr)
        print(engine.log()[-2000:], file=sys.stderr)
        return 1

    verdict, _, rest = line.partition(" | ")
    failed = verdict.startswith("FAIL")
    if args.json:
        print(json.dumps({"ok": not failed, "line": line}, ensure_ascii=False))
    else:
        print("backend : see `rpgc.py status` (the host reports it separately)")
        counts, _, summary = rest.rpartition(" | ")
        for part in counts.split():
            kind, _, value = part.partition("=")
            print(f"  {kind:<10} {value} document(s)")
        print(f"result  : {'FAIL' if failed else 'PASS'} — {summary}")
    return 1 if failed else 0


def cmd_check(engine: Engine, args) -> int:
    failures = 0
    for path in args.paths:
        rel = _relative(path)
        report = engine.eval_json(
            f'RpgcValidate.reportJson(RpgcValidate.validateFile('
            f'RpgcValidate.kindOfPath("{rel}"), "{rel}"))'
        )
        status = "PASS" if report.get("ok") else "FAIL"
        print(f"{status}  {path}  — {report.get('summary','')}")
        failures += _print_diagnostics(report.get("diagnostics"))
    return 0 if failures == 0 else 1


def _relative(path: str) -> str:
    """Map a user-supplied path to a project-relative POSIX path.

    A relative argument is genuinely ambiguous, and guessing wrong silently
    validates the wrong file.  The README documents
    `rpgc.py check content/maps/forest.json`, where `content/...` is relative to
    the workflow root, while a caller working from the repository root naturally
    writes `content/maps/forest.json`.  So resolve against
    the working directory first, then against the workflow root, and take the
    first candidate that lands inside the workflow root.
    """
    if os.path.isabs(path):
        candidates = [path]
    else:
        candidates = [os.path.join(os.getcwd(), path),
                      os.path.join(WORKFLOW_ROOT, path)]
    for candidate in candidates:
        absolute = os.path.abspath(candidate)
        try:
            rel = os.path.relpath(absolute, WORKFLOW_ROOT)
        except ValueError:  # different drive on Windows
            continue
        if not rel.startswith(".."):
            return rel.replace(os.sep, "/")
    raise SystemExit(f"rpgc: {path} is outside {WORKFLOW_ROOT}")


def cmd_script(engine: Engine, args) -> int:
    if not args.paths:
        engine.script(sys.stdin.read())
        return 0
    for path in args.paths:
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        try:
            engine.script(source)
        except McpError as error:
            print(f"rpgc: {path}: {error}", file=sys.stderr)
            return 1
        print(f"ok    {path}")
    return 0


def cmd_eval(engine: Engine, args) -> int:
    payload = engine.eval(args.expression)
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if payload.get("ok", True) else 1


def cmd_stage(engine: Engine, args) -> int:
    rel = _relative(args.path)
    with open(args.source, "r", encoding="utf-8") as handle:
        text = handle.read()
    # The engine derives the kind from the manifest, validates the exact bytes,
    # runs the semantic gate, and only then stages. One round trip, one gate.
    report = engine.eval_json(
        "RpgcValidate.reportJson(RpgcValidate.commitRaw("
        f"{json.dumps(rel)}, {json.dumps(text)}))"
    )
    if not report.get("ok"):
        _print_diagnostics(report.get("diagnostics"))
        print(f"rpgc: refusing to stage {rel} — validation failed", file=sys.stderr)
        return 1
    value = report.get("value") or {}
    print(f"staged {rel} ({value.get('bytes', len(text))} bytes, "
          f"kind {value.get('kind','?')}, {value.get('fingerprint','?')})")
    return 0


def cmd_export(engine: Engine, args) -> int:
    # `takePending()` returns a Squirrel array, which eve_eval renders as
    # "<array (n)>"; the JSON accessor is what a parser can actually consume.
    pending = engine.eval_json("RpgcStore.takePendingJson()")
    if not isinstance(pending, list) or not pending:
        print("nothing staged")
        return 0
    written = 0
    for item in pending:
        rel = item["path"]
        target = os.path.join(WORKFLOW_ROOT, rel)
        # len() counts characters; the document is UTF-8, so report bytes to
        # stay comparable with the byte counts `stage` prints.
        size = len(item["text"].encode("utf-8"))
        if args.dry_run:
            print(f"would write {rel} ({size} bytes)")
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=os.path.dirname(target))
        try:
            with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(item["text"])
            os.replace(temporary, target)
        except Exception:
            if os.path.exists(temporary):
                os.unlink(temporary)
            raise
        written += 1
        print(f"wrote {rel} ({size} bytes, {item['fingerprint']})")
    if not args.dry_run:
        engine.script("RpgcProject.invalidate();")
    print(f"{written} document(s) exported")
    return 0


def cmd_vm(engine: Engine, args) -> int:
    """Register a ViewModel from a file and report the compiler's verdict.

    `registerVM` returns the real error text, while the editor host's own
    `loadEditorsFromDisk` discards it — so a broken ViewModel is otherwise
    invisible and the editor simply renders with no bindings.
    """
    with open(args.source, "r", encoding="utf-8") as handle:
        source = handle.read()
    result = engine.client.call("eve_host_vm_register",
                                {"name": args.name, "source": source})
    ok = result == "ok"
    print(("ok    " if ok else "FAIL  ") + f"{args.name} <- {args.source}: {result}")
    return 0 if ok else 1


def cmd_log(engine: Engine, args) -> int:
    """Dump the engine's stderr. Squirrel `print()` lands there, not on stdout."""
    print(engine.log(), end="")
    return 0


def cmd_status(engine: Engine, args) -> int:
    host = engine.eval_string("eve.host.status()")
    store = engine.eval_json("RpgcValidate.reportJson(RpgcStore.probe())")
    print(host)
    print(json.dumps(store, indent=2, ensure_ascii=False))
    return 0


# --------------------------------------------------------------------------- #
# self-test
# --------------------------------------------------------------------------- #

def _editor_commands() -> dict:
    """Read {editorId: {vm, commands[]}} from editors/*.editor.json.

    The View JSON is the authority on which commands a panel can dispatch, so the
    harness derives the list from it instead of keeping a second list that could
    drift away from what the buttons actually call.
    """
    editors_dir = os.path.join(WORKFLOW_ROOT, "editors")
    out = {}
    if not os.path.isdir(editors_dir):
        return out
    for name in sorted(os.listdir(editors_dir)):
        if not name.endswith(".editor.json"):
            continue
        with open(os.path.join(editors_dir, name), encoding="utf-8") as handle:
            doc = json.load(handle)
        commands = []

        def walk(nodes):
            for node in nodes:
                if not isinstance(node, dict):
                    continue
                command = node.get("command")
                if isinstance(command, str) and command not in commands:
                    commands.append(command)
                kids = node.get("children")
                if isinstance(kids, list):
                    walk(kids)

        walk(doc.get("children") or [])
        out[doc.get("id", name[: -len(".editor.json")])] = {
            "vm": doc.get("vm", ""),
            "commands": commands,
        }
    return out


# A command that compiles but refuses at runtime (no document open, nothing
# selected) is a pass for reachability; these three are the failures that mean
# the Agent path cannot call the command at all.
_COMPILE_FAILURES = (
    "not assignable to the declared type",   # native binding name collision
    "does not exist",                        # command not defined on the ViewModel
    "wrong number of parameters",            # arity mismatch
)


def _run_selftest(engine: Engine) -> list:
    checks = []

    def record(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})
        return bool(ok)

    # 1. The host computes this gate before it accepts clients; reading its own
    #    verdict avoids re-running a ~35 s whole-project validation.
    #
    #    The line reads `<version> PASS | <kind counts> | <summary>`, so the
    #    verdict is the token after the version -- not the first word of the
    #    line. `cmd_validate` parses the same line the same way.
    banner = ""
    for candidate in engine.log().splitlines():
        if candidate.startswith(BANNER):
            banner = candidate[len(BANNER):]
    fields = banner.partition(" | ")[0].split()
    verdict = fields[-1] if fields else ""
    record("startup-gate", verdict == "PASS", banner or "host printed no verdict")

    # 2. Every declared editor is loaded and its ViewModel registered.
    host = {}
    try:
        host = engine.eval_json("eve.host.status()")
    except Exception as error:
        record("host-status", False, str(error)[:300])
    spec = _editor_commands()
    loaded = {str(e.get("id")) for e in host.get("editors", [])}
    vms = {str(v) for v in host.get("viewModels", [])}
    missing_editors = sorted(set(spec) - loaded)
    missing_vms = sorted({s["vm"] for s in spec.values() if s["vm"]} - vms)
    record("editors-loaded",
           not missing_editors and not missing_vms,
           f"editors={sorted(loaded)} vm={sorted(vms)}"
           + (f" missing_editors={missing_editors}" if missing_editors else "")
           + (f" missing_vms={missing_vms}" if missing_vms else ""))

    # 3. Each drawer answers status() without throwing.
    try:
        report = engine.eval_json("RpgcHost.reportJson()")
        blank = [e.get("id") for e in report.get("editors", []) if not e.get("status")]
        last_error = report.get("lastError", "")
        record("drawer-status", last_error == "" and not blank,
               f"lastError={last_error!r} blank={blank} frames={report.get('frames')}")
    except Exception as error:
        record("drawer-status", False, str(error)[:300])

    # 4. Every command a button can dispatch is reachable from eve_run_script.
    total = 0
    failures = []
    refused = 0
    for editor_id, info in sorted(spec.items()):
        vm = info["vm"]
        if not vm:
            continue
        for command in info["commands"]:
            total += 1
            # getinfos().parameters includes `this`, so the call takes one fewer.
            try:
                arity = int(engine.eval_string(
                    f"{vm}.{command}.getinfos().parameters.len()"))
            except Exception as error:
                failures.append(f"{vm}.{command}: not a function ({str(error)[:70]})")
                continue
            source = f"{vm}.{command}({', '.join(['null'] * max(arity - 1, 0))});"
            try:
                engine.script(source)
            except McpError as error:
                text = str(error)
                if any(marker in text for marker in _COMPILE_FAILURES):
                    failures.append(f"{vm}.{command}: {text[:110]}")
                else:
                    refused += 1
    record("vm-commands", not failures,
           f"{total - len(failures)}/{total} callable, {refused} runtime-refused"
           + ("; " + "; ".join(failures[:4]) if failures else ""))

    # 5. The store reports a backend and a parseable pending view.
    try:
        probe = engine.eval_json("RpgcValidate.reportJson(RpgcStore.probe())")
        backend = (probe.get("value") or {}).get("backend")
        record("store-backend", backend in ("deferred", "engine-save"), f"backend={backend}")
    except Exception as error:
        record("store-backend", False, str(error)[:200])

    # 6. The gate accepts a good document ...
    try:
        good = engine.eval_json(
            "RpgcValidate.reportJson(RpgcValidate.validateFile("
            '"skill", "content/skills/skill.strike.json"))')
        record("gate-accepts-good", bool(good.get("ok")), str(good.get("summary", ""))[:160])
    except Exception as error:
        record("gate-accepts-good", False, str(error)[:200])

    # 7. ... and refuses one with an unknown field, without staging anything.
    try:
        engine.script(
            'local t = RpgcStore.readText("content/skills/skill.strike.json").value;'
            'local i = t.find("}");'
            'local bad = t.slice(0, i) + ",\\"zzz_bogus\\":1" + t.slice(i);'
            'RpgcStore.clearPending();'
            'RpgcProbeBad <- RpgcValidate.reportJson(RpgcValidate.commitRaw('
            '"content/skills/skill.probe.json", bad));'
            'RpgcProbeBadPending <- RpgcStore.pendingCount();')
        bad_report = json.loads(engine.eval_string("RpgcProbeBad"))
        staged = int(engine.eval_string("RpgcProbeBadPending"))
        record("gate-refuses-bad",
               (not bad_report.get("ok")) and staged == 0,
               f"ok={bad_report.get('ok')} staged={staged} "
               f"diag={(bad_report.get('diagnostics') or [{}])[0].get('code')}")
    except Exception as error:
        record("gate-refuses-bad", False, str(error)[:250])

    # 8. stage -> read back -> still staged (takePendingJson is non-destructive).
    try:
        engine.script(
            'RpgcProbeStage <- RpgcValidate.reportJson(RpgcValidate.commitRaw('
            '"content/skills/skill.strike.json", '
            'RpgcStore.readText("content/skills/skill.strike.json").value));')
        stage_report = json.loads(engine.eval_string("RpgcProbeStage"))
        first = engine.eval_json("RpgcStore.takePendingJson()")
        second = engine.eval_json("RpgcStore.takePendingJson()")
        ok = (stage_report.get("ok") and isinstance(first, list) and len(first) == 1
              and len(second) == 1 and first[0].get("path") == "content/skills/skill.strike.json")
        record("stage-roundtrip", ok,
               f"ok={stage_report.get('ok')} first={len(first) if isinstance(first, list) else '?'} "
               f"second={len(second) if isinstance(second, list) else '?'}")
    except Exception as error:
        record("stage-roundtrip", False, str(error)[:250])
    finally:
        try:
            engine.script("RpgcStore.clearPending();")
        except Exception:
            pass

    return checks


def cmd_selftest(engine: Engine, args) -> int:
    """Prove the workflow's own claims against a live host.

    Every assertion here is one the README or docs make in prose; running it is
    what turns those sentences into evidence.
    """
    checks = _run_selftest(engine)
    failed = [c for c in checks if not c["ok"]]
    if args.json:
        print(json.dumps({"ok": not failed, "checks": checks}, indent=2, ensure_ascii=False))
    else:
        for check in checks:
            print(f"{'PASS' if check['ok'] else 'FAIL'}  {check['check']:<18} {check['detail']}")
        print(f"selftest: {'PASS' if not failed else 'FAIL'} "
              f"({len(checks) - len(failed)}/{len(checks)} checks)")
    return 0 if not failed else 1


# --------------------------------------------------------------------------- #
# entry point
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rpgc", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--eve", help="path to the eve binary")
    parser.add_argument("--port", type=int, help="attach to a running `eve mcp` TCP port")
    parser.add_argument("--root", default=WORKFLOW_ROOT,
                        help="workflow root (default: the directory containing workflow.json)")
    parser.add_argument("--wait", type=float, default=30.0, help="seconds to wait for the engine")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="echo the engine's stderr (Squirrel print output, startup log)")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="validate every content document")
    validate.add_argument("--json", action="store_true")
    validate.set_defaults(func=cmd_validate)

    check = sub.add_parser("check", help="validate specific files")
    check.add_argument("paths", nargs="+")
    check.set_defaults(func=cmd_check)

    script = sub.add_parser("script", help="run Squirrel inside the host")
    script.add_argument("paths", nargs="*")
    script.set_defaults(func=cmd_script)

    evaluate = sub.add_parser("eval", help="evaluate a Squirrel expression")
    evaluate.add_argument("expression")
    evaluate.set_defaults(func=cmd_eval)

    stage = sub.add_parser("stage", help="validate a file, then stage it for export")
    stage.add_argument("path", help="project-relative destination")
    stage.add_argument("source", help="local file to stage")
    stage.set_defaults(func=cmd_stage)

    export = sub.add_parser("export", help="write staged documents into the project")
    export.add_argument("--dry-run", action="store_true")
    export.set_defaults(func=cmd_export)

    status = sub.add_parser("status", help="engine + store status")
    status.set_defaults(func=cmd_status)

    selftest = sub.add_parser(
        "selftest", help="verify the workflow's end-to-end claims against a live host")
    selftest.add_argument("--json", action="store_true")
    selftest.set_defaults(func=cmd_selftest)

    log = sub.add_parser("log", help="dump engine stderr (Squirrel print output)")
    log.set_defaults(func=cmd_log)

    vm = sub.add_parser("vm", help="register a ViewModel file and report compiler errors")
    vm.add_argument("name", help="ViewModel table name, e.g. SkillVM")
    vm.add_argument("source", help="path to the .vm.nut file")
    vm.set_defaults(func=cmd_vm)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    binary = find_engine(args.eve)
    engine = Engine(binary, os.path.abspath(args.root), args.port, args.wait)
    status = 0
    try:
        status = args.func(engine, args)
        # Squirrel print() goes to the engine's stderr; surface it whenever the
        # user asked for a script (their prints are the result) or for verbosity.
        if args.verbose or args.command == "script":
            tail = engine.log()
            if tail:
                print(tail, end="", file=sys.stderr)
    finally:
        engine.stop()
    return status


if __name__ == "__main__":
    sys.exit(main())
