// EVEngine workflow / rpg-classic — shared result, diagnostic and path helpers.
//
// Every library entry point in this toolchain returns the same shape, so an AI
// can reason about and persist the outcome without special cases:
//
//   { ok = <bool>,
//     value = <document value or 0/""/[]/{}>,
//     diagnostics = [ { code, severity, message, path, hint } ] }
//
// `code` is stable and machine-readable, `path` is a JSON-Pointer-ish document
// path ("/events/0/steps/2/kind"), and `hint` is the human-facing repair advice.
// An "ok" result may still carry warnings; callers must gate on `ok` for errors
// and may surface warnings.
//
// Two engine-specific rules this library is written around, both reproduced in
// the `eve mcp` host (see docs/05-ai-safe-operation.md §3.6):
//
//   1. A table slot is created with `<-`, never with `=`. `t.newSlot = v` raises
//      "the index 'newSlot' does not exist"; `=` only assigns what already
//      exists. Documents decoded from JSON omit optional fields, so every write
//      into a document must use `<-` (or `rawset` when the key is computed).
//   2. A member call is type-checked against any native binding with the same
//      name, regardless of the receiver. `Rpgc.warning` was renamed to `warn`
//      for this reason.

export class Rpgc {
}

Rpgc.version <- 1

// ------------------------------------------------------------ diagnostics

Rpgc.error <- function (code, message, path, hint) {
    return this._diag(code, "error", message, path, hint);
}

// Named `warn`/`note` rather than `warning`/`info`: the EveScript compiler
// rejects a table slot called `warning` with "value is not assignable to the
// declared type" (reproduced in this repo), and `info` is avoided for the
// same class of collision.
Rpgc.warn <- function (code, message, path, hint) {
    return this._diag(code, "warning", message, path, hint);
}

Rpgc.note <- function (code, message, path, hint) {
    return this._diag(code, "info", message, path, hint);
}

Rpgc._diag <- function (code, severity, message, path, hint) {
    local d = {};
    d.code <- code;
    d.severity <- severity;
    d.message <- message;
    d.path <- (path == null ? "$" : path);
    d.hint <- (hint == null ? "" : hint);
    return d;
}

Rpgc.ok <- function (value) {
    local r = {};
    r.ok <- true;
    r.value <- (value == null ? 0 : value);
    r.diagnostics <- [];
    return r;
}

Rpgc.fail <- function (diagnostics) {
    local r = {};
    r.ok <- false;
    r.value <- 0;
    r.diagnostics <- diagnostics;
    return r;
}

Rpgc.result <- function (value, diagnostics) {
    local r = {};
    r.diagnostics <- diagnostics;
    r.value <- (value == null ? 0 : value);
    r.ok <- (this.errorCount(diagnostics) == 0);
    return r;
}

Rpgc.errorCount <- function (diagnostics) {
    local n = 0;
    foreach (d in diagnostics) if (d.severity == "error") n += 1;
    return n;
}

// Combine several results: all must be ok and no diagnostics are dropped.
Rpgc.merge <- function (results, value) {
    local diagnostics = [];
    foreach (r in results) {
        foreach (d in r.diagnostics) diagnostics.append(d);
    }
    return this.result(value == null ? 0 : value, diagnostics);
}

Rpgc.append <- function (result, diagnostics) {
    foreach (d in diagnostics) result.diagnostics.append(d);
    if (this.errorCount(diagnostics) > 0) result.ok = false;
    return result;
}

Rpgc.firstError <- function (result) {
    foreach (d in result.diagnostics) if (d.severity == "error") return d;
    return null;
}

Rpgc.summary <- function (result) {
    local errors = 0;
    local warnings = 0;
    foreach (d in result.diagnostics) {
        if (d.severity == "error") errors += 1;
        else if (d.severity == "warning") warnings += 1;
    }
    if (errors == 0 && warnings == 0) return result.ok ? "ok" : "failed";
    local parts = "";
    if (errors > 0) parts += errors + " error(s)";
    if (warnings > 0) parts += (parts == "" ? "" : ", ") + warnings + " warning(s)";
    local first = this.firstError(result);
    if (first != null) parts += ": [" + first.path + "] " + first.message;
    return parts;
}

// ---------------------------------------------------------------- values

Rpgc.isObject <- function (value) {
    return typeof value == "table";
}

Rpgc.isArray <- function (value) {
    return typeof value == "array";
}

Rpgc.isNumber <- function (value) {
    local t = typeof value;
    return t == "integer" || t == "float";
}

Rpgc.asNumber <- function (value) {
    local t = typeof value;
    if (t == "integer") return value.tofloat();
    if (t == "float") return value;
    return 0.0;
}

Rpgc.asInt <- function (value) {
    local t = typeof value;
    if (t == "integer") return value;
    if (t == "float") return value.tointeger();
    return 0;
}

// `EditorHost` writes a `slider` value into the bound ViewModel slot as a
// ONE-ELEMENT ARRAY and a `dropdown`/`listbox` value as a STRING
// (src/modules/ui/EditorHost.cpp:876-930). A ViewModel that expects a plain
// number therefore has to normalise, and getting this wrong is silent: the
// slot becomes an array, arithmetic degrades to 0, and nothing errors.
// These two helpers are the single place that unwrapping happens.
Rpgc.numberOf <- function (value) {
    local t = typeof value;
    if (t == "float") return value;
    if (t == "integer") return value.tofloat();
    if (t == "bool") return value ? 1.0 : 0.0;
    if (t == "array") {
        if (value.len() == 0) return 0.0;
        return this.numberOf(value[0]);
    }
    if (t == "string") {
        local parsed = 0.0;
        try {
            parsed = value.tofloat();
        } catch (e) {
            return 0.0;
        }
        return parsed;
    }
    return 0.0;
}

Rpgc.intOf <- function (value) {
    return this.numberOf(value).tointeger();
}

// Resolve "which item is selected" from a ViewModel that may hold an id
// (dropdown), a label string (listbox) or an index (numeric widget).
Rpgc.selectedIndexOf <- function (list, idValue, indexValue) {
    local text = this.asString(idValue);
    if (text != "") {
        for (local i = 0; i < list.len(); i += 1) {
            if (list[i] == text) return i;
        }
    }
    local label = this.asString(indexValue);
    if (label != "") {
        for (local i = 0; i < list.len(); i += 1) {
            if (list[i] == label) return i;
        }
    }
    local index = this.intOf(indexValue);
    if (index >= 0 && index < list.len()) return index;
    return list.len() > 0 ? 0 : -1;
}

Rpgc.asString <- function (value) {
    if (typeof value == "string") return value;
    return "";
}

Rpgc.keyCount <- function (value) {
    if (typeof value == "table") return value.len();
    if (typeof value == "array") return value.len();
    return 0;
}

// Dotted lookup ("steps.0.kind"). Returns sentinel `fallback` when absent.
Rpgc.get <- function (value, path, fallback) {
    local node = value;
    foreach (segment in this.split(path, ".")) {
        if (typeof node == "table") {
            if (!node.rawin(segment)) return fallback;
            node = node.rawget(segment);
        } else if (typeof node == "array") {
            local index = this.parseIndex(segment);
            if (index < 0 || index >= node.len()) return fallback;
            node = node[index];
        } else {
            return fallback;
        }
    }
    return node;
}

Rpgc.has <- function (value, path) {
    local node = value;
    foreach (segment in this.split(path, ".")) {
        if (typeof node == "table") {
            if (!node.rawin(segment)) return false;
            node = node.rawget(segment);
        } else if (typeof node == "array") {
            local index = this.parseIndex(segment);
            if (index < 0 || index >= node.len()) return false;
            node = node[index];
        } else {
            return false;
        }
    }
    return true;
}

Rpgc.parseIndex <- function (text) {
    if (text.len() == 0) return -1;
    for (local i = 0; i < text.len(); i += 1) {
        local c = text[i];
        if (c < 48 || c > 57) return -1;
    }
    return text.tointeger();
}

Rpgc.split <- function (text, separator) {
    local parts = [];
    local start = 0;
    while (true) {
        local at = text.find(separator, start);
        if (at == null || at < 0) {
            parts.append(text.slice(start, text.len()));
            return parts;
        }
        parts.append(text.slice(start, at));
        start = at + separator.len();
    }
}

// ------------------------------------------------------------------- ids

// Stable document ids: ASCII letters/digits plus `._-`, 1..64 bytes.
// They end up in file names, GameState scopes and localisation keys, so
// anything exotic would break a later stage.
Rpgc.validId <- function (text) {
    if (typeof text != "string") return false;
    local n = text.len();
    if (n < 1 || n > 64) return false;
    for (local i = 0; i < n; i += 1) {
        local c = text[i] & 0xFF;
        local ok = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ||
                   (c >= 48 && c <= 57) || c == 46 || c == 95 || c == 45;
        if (!ok) return false;
    }
    return true;
}

// Project-relative POSIX path: no drive letter, no leading slash, no `..`,
// no backslash, no empty segment. Anything else could escape the project
// root once an editor or the CLI joins it with a base directory.
Rpgc.validRelPath <- function (text) {
    if (typeof text != "string") return false;
    local n = text.len();
    if (n < 1 || n > 240) return false;
    if (text[0] == 47) return false;
    if (text.find("\\") >= 0) return false;
    if (text.find(":") >= 0) return false;
    foreach (segment in this.split(text, "/")) {
        if (segment == "" || segment == "." || segment == "..") return false;
    }
    return true;
}

Rpgc.dirName <- function (path) {
    local last = -1;
    local search = 0;
    while (true) {
        local hit = path.find("/", search);
        if (hit == null || hit < 0) break;
        last = hit;
        search = hit + 1;
    }
    if (last < 0) return "";
    return path.slice(0, last);
}

Rpgc.baseName <- function (path) {
    local last = -1;
    local search = 0;
    while (true) {
        local hit = path.find("/", search);
        if (hit == null || hit < 0) break;
        last = hit;
        search = hit + 1;
    }
    if (last < 0) return path;
    return path.slice(last + 1, path.len());
}

Rpgc.stem <- function (path) {
    local name = this.baseName(path);
    local dot = name.find(".");
    if (dot == null || dot < 0) return name;
    return name.slice(0, dot);
}

Rpgc.joinList <- function (values, separator) {
    local text = "";
    for (local i = 0; i < values.len(); i += 1) {
        if (i > 0) text += separator;
        text += values[i];
    }
    return text;
}

// Collapse "." and ".." segments. Used to turn a document-relative
// reference ("../tilesets/x.json") into a project-relative path that the
// rest of the toolchain can look up.
Rpgc.normalizePath <- function (path) {
    local out = [];
    foreach (segment in this.split(path, "/")) {
        if (segment == "" || segment == ".") continue;
        if (segment == "..") {
            if (out.len() > 0) out.pop();
            continue;
        }
        out.append(segment);
    }
    return this.joinList(out, "/");
}

// Resolve `rel` against the directory that holds `baseFile`.
Rpgc.resolveFrom <- function (baseFile, rel) {
    local dir = this.dirName(baseFile);
    if (dir == "") return this.normalizePath(rel);
    return this.normalizePath(dir + "/" + rel);
}

// ------------------------------------------------------------- limits

// Document size guards. They exist so a malformed or hostile file cannot
// lock up the editor; they are not gameplay budgets.
Rpgc.limits <- {
    maxMapWidth = 512,
    maxMapHeight = 512,
    maxLayers = 16,
    maxObjects = 2048,
    maxSkills = 512,
    maxEvents = 256,
    maxSteps = 512,
    maxTracks = 32,
    maxLevelRows = 64
}
