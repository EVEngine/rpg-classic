"""Manifest-driven project queries and pure candidate transformations."""
from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(text):
    def reject(value):
        raise ValueError(f"non-finite JSON number: {value}")
    def number(value):
        parsed = float(value)
        if not math.isfinite(parsed):
            reject(value)
        return parsed
    return json.loads(text,
                      object_pairs_hook=_pairs, parse_constant=reject, parse_float=number)


def read_json(path):
    return parse_json(Path(path).read_text(encoding="utf-8"))


def fingerprint(document):
    payload = json.dumps(document, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def inside(root, relative):
    root = Path(root).resolve()
    rel = Path(relative)
    if rel.is_absolute() or ".." in rel.parts:
        raise ValueError(f"expected project-relative path: {relative}")
    target = (root / rel).resolve()
    if not target.is_relative_to(root):
        raise ValueError(f"path escapes project: {relative}")
    return target


class Project:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.manifest = read_json(self.root / "workflow.json")
        if not isinstance(self.manifest, dict) or not isinstance(self.manifest.get("kinds"), dict) or not self.manifest["kinds"]:
            raise ValueError("workflow.json must declare nonempty kinds")
        self.kinds = self.manifest["kinds"]
        for kind, spec in self.kinds.items():
            if not isinstance(spec, dict) or not isinstance(spec.get("directory"), str):
                raise ValueError(f"invalid kind descriptor: {kind}")
            inside(self.root, spec["directory"])
            extension = spec.get("extension", ".json")
            if not isinstance(extension, str) or not extension.startswith(".") or any(c in extension for c in "/\\*?["):
                raise ValueError(f"invalid extension: {kind}")

    def documents(self, kind=None):
        if kind is not None and kind not in self.kinds:
            raise ValueError(f"unknown kind: {kind}")
        result = []
        for name in ([kind] if kind else sorted(self.kinds)):
            spec = self.kinds[name]
            directory = inside(self.root, spec["directory"])
            if not directory.is_dir():
                raise ValueError(f"missing content directory: {spec['directory']}")
            ext = spec.get("extension", ".json")
            for path in sorted(directory.iterdir()):
                if not path.name.endswith(ext) or path.name.endswith(".baked.json"):
                    continue
                safe = inside(self.root, path.relative_to(self.root))
                doc = read_json(safe)
                if not isinstance(doc, dict):
                    raise ValueError(f"expected object: {path}")
                result.append({"kind": name, "id": doc.get("id"),
                               "path": path.relative_to(self.root).as_posix(),
                               "fingerprint": fingerprint(doc), "document": doc})
        return result

    def catalog(self, kind=None, query=None):
        rows = []
        for entry in self.documents(kind):
            doc = entry["document"]
            row = {k: v for k, v in entry.items() if k != "document"}
            row["title"] = doc.get("title", doc.get("displayName", ""))
            if query is None or query.casefold() in json.dumps(row, ensure_ascii=False).casefold():
                rows.append(row)
        return {"ok": True, "validated": False, "documents": rows, "count": len(rows)}

    def schema(self, kind):
        if kind not in self.kinds:
            raise ValueError(f"unknown kind: {kind}")
        schema_id = self.kinds[kind]["schema"]
        return read_json(inside(self.root, f"schema/{schema_id}.json"))


def pointer_tokens(pointer):
    if not isinstance(pointer, str) or (pointer and not pointer.startswith("/")):
        raise ValueError("JSON pointer must be empty or begin with /")
    if not pointer:
        return []
    result = []
    for token in pointer[1:].split("/"):
        for i, char in enumerate(token):
            if char == "~" and (i + 1 == len(token) or token[i + 1] not in "01"):
                raise ValueError(f"invalid JSON pointer escape: {pointer}")
        result.append(token.replace("~1", "/").replace("~0", "~"))
    return result


def _index(token, length, append=False):
    if append and token == "-":
        return length
    if not token.isascii() or not token.isdigit() or (len(token) > 1 and token[0] == "0"):
        raise ValueError(f"invalid array index: {token}")
    index = int(token)
    if index >= length + int(append):
        raise ValueError(f"array index out of range: {token}")
    return index


def _get(container, token):
    if isinstance(container, list):
        return container[_index(token, len(container))]
    if isinstance(container, dict) and token in container:
        return container[token]
    raise ValueError(f"missing pointer component: {token}")


def _equal(left, right):
    # JSON booleans are not numbers (unlike Python's True == 1).
    if isinstance(left, bool) != isinstance(right, bool):
        return False
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(_equal(left[k], right[k]) for k in left)
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(_equal(a, b) for a, b in zip(left, right))
    return left == right


def patch_document(document, operations, expected=None):
    """RFC 6902 add/remove/replace/test subset. Entire patch is pure and atomic."""
    if expected is not None and fingerprint(document) != expected:
        raise ValueError("stale document fingerprint")
    if not isinstance(operations, list):
        raise ValueError("patch must be an array")
    result = copy.deepcopy(document)
    for operation in operations:
        if not isinstance(operation, dict):
            raise ValueError("patch operation must be an object")
        op = operation.get("op")
        if op not in ("add", "remove", "replace", "test"):
            raise ValueError(f"unsupported patch operation: {op}")
        if "path" not in operation or (op != "remove" and "value" not in operation):
            raise ValueError("patch operation requires path and value")
        tokens = pointer_tokens(operation["path"])
        value = copy.deepcopy(operation.get("value"))
        if not tokens:
            if op == "test":
                if not _equal(result, value):
                    raise ValueError("patch test failed at root")
            elif op == "remove":
                raise ValueError("cannot remove document root")
            else:
                result = value
            continue
        parent = result
        for token in tokens[:-1]:
            parent = _get(parent, token)
        token = tokens[-1]
        if op == "test":
            if not _equal(_get(parent, token), value):
                raise ValueError(f"patch test failed: {operation['path']}")
        elif isinstance(parent, list):
            index = _index(token, len(parent), op == "add")
            if op == "add":
                parent.insert(index, value)
            elif op == "remove":
                parent.pop(index)
            else:
                parent[index] = value
        elif isinstance(parent, dict):
            if op != "add" and token not in parent:
                raise ValueError(f"missing pointer component: {token}")
            if op == "remove":
                del parent[token]
            else:
                parent[token] = value
        else:
            raise ValueError("pointer parent must be object or array")
    if not isinstance(result, dict):
        raise ValueError("candidate document must remain an object")
    fingerprint(result)  # ensure JSON serializability, including finite numbers
    return result


def encounter_report(project):
    """Inspect authored totals; deliberately not a battle/win-rate simulator."""
    enemies = {e["id"]: e["document"] for e in project.documents("enemy")}
    rows = []
    for entry in project.documents("encounter"):
        doc = entry["document"]
        row = {"id": entry["id"], "map": doc.get("map"), "members": 0,
               "totalHp": 0, "totalAttack": 0,
               "goldReward": doc.get("goldReward", 0), "xpReward": doc.get("xpReward", 0)}
        for member in doc.get("members", []):
            enemy_id, count = member["enemy"], member.get("count", 1)
            if isinstance(count, bool) or not isinstance(count, int) or count <= 0:
                raise ValueError(f"invalid member count in {entry['id']}")
            if enemy_id not in enemies:
                raise ValueError(f"missing enemy: {enemy_id}")
            combat = enemies[enemy_id]["combat"]
            for field, total in (("maxHp", "totalHp"), ("attack", "totalAttack")):
                value = combat[field]
                if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
                    raise ValueError(f"invalid {field}: {enemy_id}")
                row[total] += value * count
            row["members"] += count
        rows.append(row)
    return {"ok": True, "mode": "authored-stat-totals", "simulated": False, "encounters": rows}
