// EVEngine workflow / rpg-classic — document store.
//
// Reading is always available: the headless `eve mcp` host mounts the project
// root into PhysFS, so `fs.readText("content/maps/village.map.json")` resolves.
//
// Writing is NOT available to Squirrel in that host. Two facts force the design
// (both verified against this checkout, not assumed):
//
//   1. `installScriptFileApi` (src/modules/filesystem/physfs/FileApi.cpp:129)
//      replaces the stdlib `file()` class with a read-only, PhysFS-backed table.
//      There is no write method.
//   2. `Filesystem::setupWriteDirectory()` needs `setIdentity()` and then writes
//      under the *engine save directory*, never the project root. In the MCP
//      host it reports failure outright.
//
// So the store has exactly two backends, both observable through `probe()`:
//
//   "engine-save" — `writeTextAtomic` works; documents live under the engine
//                   save directory (the same convention `examples/terrain-editor`,
//                   `examples/scene-editor` and `examples/level-designer` use).
//   "deferred"    — no writer. The canonical text is staged in the VM and the
//                   operator commits it to the project: an AI reads it back with
//                   `eve_eval`, and `tools/rpgc.py` does the atomic file write.
//
// Nothing is ever persisted before the validation gate passes, which is what
// makes it safe to let an AI drive a save.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"

export class RpgcStore {
}

RpgcStore.version <- 1
RpgcStore.identity <- "eve-rpgc-rpg-classic"

// path -> { text, fingerprint, stagedAt }
RpgcStore.pending <- {}
// path -> fingerprint of the text this session last read or wrote
RpgcStore.revisions <- {}
RpgcStore.backendValue <- ""
RpgcStore.saveDirectoryValue <- ""
RpgcStore.sourceRootValue <- ""

// -------------------------------------------------------------- backend

RpgcStore.probe <- function () {
    // Note: `local fs = null; fs = eve.Filesystem();` is a compile error
    // under EveScript's progressive typing (the slot is inferred as null),
    // so the call is repeated instead of assigned into a pre-nulled local.
    local available = true;
    try {
        eve.Filesystem();
    } catch (e) {
        available = false;
    }
    if (!available) {
        return Rpgc.fail([Rpgc.error("store.no-filesystem",
            "the filesystem module is not available in this build",
            "$", "run inside `eve run` or `eve mcp`")]);
    }
    try {
        this.sourceRootValue <- eve.Filesystem().getSource();
    } catch (e) {
        this.sourceRootValue <- "";
    }

    local writable = false;
    try {
        local fs = eve.Filesystem();
        if (fs.getIdentity() != this.identity) fs.setIdentity(this.identity, false);
        writable = fs.setupWriteDirectory();
        this.saveDirectoryValue <- fs.getSaveDirectory();
    } catch (e) {
        writable = false;
        this.saveDirectoryValue <- "";
    }

    this.backendValue <- writable ? "engine-save" : "deferred";
    local info = {};
    info.backend <- this.backendValue;
    info.writable <- writable;
    info.identity <- this.identity;
    info.sourceRoot <- this.sourceRootValue;
    info.saveDirectory <- this.saveDirectoryValue;
    info.pendingCount <- this.pendingCount();
    info.note <- writable
        ? "documents persist under the engine save directory"
        : "no in-VM writer; staged text must be committed by tools/rpgc.py or the MCP client";
    return Rpgc.ok(info);
}

RpgcStore.backend <- function () {
    if (this.backendValue == "") this.probe();
    return this.backendValue;
}

// ---------------------------------------------------------------- reads

RpgcStore.exists <- function (path) {
    try {
        local handle = file(path, "r");
        return handle != null;
    } catch (e) {
        return false;
    }
}

RpgcStore.readText <- function (path) {
    if (!Rpgc.validRelPath(path)) {
        return Rpgc.fail([Rpgc.error("store.bad-path",
            "path is not a project-relative POSIX path: '" + path + "'", "$",
            "use e.g. content/maps/village.map.json")]);
    }
    if (!this.exists(path)) {
        return Rpgc.fail([Rpgc.error("store.missing",
            "no such document: " + path, "$", "check the path and the project root")]);
    }
    local text = "";
    try {
        text = eve.Filesystem().readText(path);
    } catch (e) {
        return Rpgc.fail([Rpgc.error("store.read-failed",
            "reading " + path + " failed: " + e, "$", "check file permissions")]);
    }
    this.revisions.rawset(path, RpgcJson.hashText(text));
    return Rpgc.ok(text);
}

// Parse a document from disk and attach its path fingerprint.
RpgcStore.readDocument <- function (path) {
    local read = this.readText(path);
    if (!read.ok) return read;
    local parsed = RpgcJson.parse(read.value);
    if (!parsed.ok) {
        foreach (d in parsed.diagnostics) d.path = path + ":" + d.path;
        return Rpgc.fail(parsed.diagnostics);
    }
    return Rpgc.ok(parsed.value);
}

RpgcStore.revisionOf <- function (path) {
    if (this.revisions.rawin(path)) return this.revisions.rawget(path);
    return "";
}

// --------------------------------------------------------------- writes

// Stage canonical text for `path` without touching the filesystem. The
// editor calls this only after the validation gate has accepted the text.
RpgcStore.stage <- function (path, text) {
    if (!Rpgc.validRelPath(path)) {
        return Rpgc.fail([Rpgc.error("store.bad-path",
            "path is not a project-relative POSIX path: '" + path + "'", "$", "")]);
    }
    local entry = {};
    entry.text <- text;
    entry.fingerprint <- RpgcJson.fingerprint({ text = text });
    this.pending.rawset(path, entry);
    return Rpgc.ok(entry.fingerprint);
}

RpgcStore.stageDocument <- function (path, document) {
    return this.stage(path, RpgcJson.encode(document) + "\n");
}

RpgcStore.pendingCount <- function () {
    return this.pending.len();
}

RpgcStore.takePending <- function () {
    local out = [];
    foreach (path, entry in this.pending) {
        local item = {};
        item.path <- path;
        item.text <- entry.text;
        item.fingerprint <- entry.fingerprint;
        out.append(item);
    }
    return out;
}

// The same list, encoded as JSON. `eve_eval` renders a Squirrel array as
// `<array (n)>`, so a transport that needs to parse the staged set has to go
// through this accessor rather than `takePending()`. Still non-destructive.
RpgcStore.takePendingJson <- function () {
    return RpgcJson.encode(this.takePending());
}

RpgcStore.clearPending <- function () {
    this.pending <- {};
    return Rpgc.ok(this.pendingCount());
}

// Persist a document. On the "engine-save" backend this is an atomic write;
// on "deferred" the text stays staged and the result carries a warning so a
// caller cannot mistake staging for persistence.
RpgcStore.save <- function (path, text) {
    if (!Rpgc.validRelPath(path)) {
        return Rpgc.fail([Rpgc.error("store.bad-path",
            "path is not a project-relative POSIX path: '" + path + "'", "$", "")]);
    }
    this.probe();
    local diagnostics = [];
    local info = {};
    info.backend <- this.backendValue;
    info.path <- path;
    info.fingerprint <- RpgcJson.fingerprint({ text = text });
    info.persisted <- false;

    if (this.backendValue != "engine-save") {
        this.stage(path, text);
        diagnostics.append(Rpgc.warn("store.deferred",
            "no in-VM writer; " + path + " was staged, not written", "$",
            "commit with `python tools/rpgc.py export` or let the MCP client write the file"));
        return Rpgc.result(info, diagnostics);
    }

    local written = true;
    try {
        if (!eve.Filesystem().writeTextAtomic(path, text)) written = false;
    } catch (e) {
        return Rpgc.fail([Rpgc.error("store.write-failed",
            "writing " + path + " failed", "$", "check the save directory")]);
    }
    if (!written) {
        return Rpgc.fail([Rpgc.error("store.write-failed",
            "writeTextAtomic rejected " + path, "$",
            "the path must stay inside the configured save directory")]);
    }
    this.revisions.rawset(path, info.fingerprint);
    info.persisted = true;
    return Rpgc.ok(info);
}

RpgcStore.saveDocument <- function (path, document) {
    return this.save(path, RpgcJson.encode(document) + "\n");
}

// Conflict check: refuse to overwrite a file that changed since we read it.
// The editor calls this before staging so an AI's edit cannot silently
// clobber a human's.
RpgcStore.checkRevision <- function (path) {
    local known = this.revisionOf(path);
    if (known == "") return Rpgc.ok(true);
    local read = this.readText(path);
    if (!read.ok) return Rpgc.ok(true);  // new file, nothing to conflict with
    local current = this.revisionOf(path);
    if (current != known) {
        return Rpgc.fail([Rpgc.error("store.stale-revision",
            "on-disk content of " + path + " changed since it was read",
            "$", "reload the document before saving")]);
    }
    return Rpgc.ok(true);
}
