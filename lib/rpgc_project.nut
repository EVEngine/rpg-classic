// EVEngine workflow / rpg-classic — project manifest and content index.
//
// The workflow treats one directory tree as the single source of truth:
//
//   workflow.json            manifest (kind -> directory + schema id)
//   schema/*.json            Eve Schema v1 documents, registered at start-up
//   content/tilesets/*.json  atlas + per-GID navigation metadata
//   content/anims/*.json     sprite animation clips (frame lists)
//   content/effects/*.json   effect templates used by skills
//   content/maps/*.json      isometric level documents
//   content/skills/*.json    skills (animation + effect + per-level scaling)
//   content/events/*.json    staged event documents (cutscenes)
//
// Everything else (editors, CLI, an AI session) reads and writes through this
// index, so there is exactly one authority for "which content exists".

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcStore } from "./rpgc_store.nut"

export class RpgcProject {
}

RpgcProject.version <- 1
RpgcProject.manifestPath <- "workflow.json"
RpgcProject.manifestValue <- 0
RpgcProject.indexValue <- 0
RpgcProject.diagnosticsValue <- []

// -------------------------------------------------------------- manifest

RpgcProject.load <- function (path) {
    if (path == null || path == "") path = this.manifestPath;
    local read = RpgcStore.readText(path);
    if (!read.ok) return read;
    local parsed = RpgcJson.parse(read.value);
    if (!parsed.ok) {
        foreach (d in parsed.diagnostics) d.path = path + ":" + d.path;
        return Rpgc.fail(parsed.diagnostics);
    }
    local doc = parsed.value;
    local diagnostics = [];

    if (!Rpgc.has(doc, "schema") || doc.schema != "eve.workflow") {
        diagnostics.append(Rpgc.error("workflow.schema",
            "manifest must declare schema 'eve.workflow'", "$",
            "add { \"schema\": \"eve.workflow\" }"));
    }
    if (Rpgc.asInt(Rpgc.get(doc, "version", 0)) != 1) {
        diagnostics.append(Rpgc.error("workflow.version",
            "manifest version must be 1", "$", ""));
    }
    if (!Rpgc.validId(Rpgc.asString(Rpgc.get(doc, "id", "")))) {
        diagnostics.append(Rpgc.error("workflow.id",
            "manifest id must be a stable id", "$", "e.g. \"rpg-classic\""));
    }

    // Every declared directory must be a valid relative path and exist.
    local kinds = Rpgc.get(doc, "kinds", 0);
    if (typeof kinds != "table" || kinds.len() == 0) {
        diagnostics.append(Rpgc.error("workflow.kinds",
            "manifest must declare at least one content kind", "$",
            "see workflow.json for the expected shape"));
    } else {
        foreach (kind, spec in kinds) {
            local directory = Rpgc.asString(Rpgc.get(spec, "directory", ""));
            if (!Rpgc.validRelPath(directory)) {
                diagnostics.append(Rpgc.error("workflow.kind-directory",
                    "kind '" + kind + "' has an invalid directory '" + directory + "'",
                    "/kinds/" + kind + "/directory", "use a project-relative POSIX path"));
                continue;
            }
            if (!Rpgc.validId(Rpgc.asString(Rpgc.get(spec, "schema", "")))) {
                diagnostics.append(Rpgc.error("workflow.kind-schema",
                    "kind '" + kind + "' must name a schema id",
                    "/kinds/" + kind + "/schema", ""));
            }
        }
    }

    this.manifestValue <- doc;
    this.indexValue <- 0;
    this.diagnosticsValue <- diagnostics;
    return Rpgc.result(doc, diagnostics);
}

RpgcProject.manifest <- function () {
    if (this.manifestValue == 0) this.load("")
    return this.manifestValue;
}

RpgcProject.kinds <- function () {
    local manifest = this.manifest();
    local out = [];
    local declared = Rpgc.get(manifest, "kinds", 0);
    if (typeof declared != "table") return out;
    foreach (kind, spec in declared) out.append(kind);
    out.sort();
    return out;
}

RpgcProject.kindSpec <- function (kind) {
    local spec = Rpgc.get(this.manifest(), "kinds." + kind, 0);
    if (typeof spec != "table") return 0;
    return spec;
}

RpgcProject.directoryOf <- function (kind) {
    return Rpgc.asString(Rpgc.get(this.kindSpec(kind), "directory", ""));
}

RpgcProject.schemaOf <- function (kind) {
    return Rpgc.asString(Rpgc.get(this.kindSpec(kind), "schema", ""));
}

RpgcProject.extensionOf <- function (kind) {
    local declared = Rpgc.asString(Rpgc.get(this.kindSpec(kind), "extension", ""));
    return declared == "" ? ".json" : declared;
}

// ---------------------------------------------------------------- index

// `kind` -> the ids currently present in its directory, read NOW.
//
// This is the single place that decides what counts as a document of a kind:
// the manifest names a directory and an extension, and the file stem is the id
// (which is what the gate checks the document's own `id` against). Both the
// start-up index and the live folder view below call it, so the two can never
// disagree about which documents exist.
RpgcProject.idsIn <- function (kind) {
    local directory = this.directoryOf(kind);
    local extension = this.extensionOf(kind);
    local ids = [];
    if (directory == "" || extension == "") return ids;
    local names = [];
    try {
        names = eve.Filesystem().getDirectoryItems(directory);
    } catch (e) {
        names = [];
    }
    names.sort();
    foreach (name in names) {
        if (name.len() <= extension.len()) continue;
        if (name.slice(name.len() - extension.len(), name.len()) != extension) continue;
        ids.append(name.slice(0, name.len() - extension.len()));
    }
    return ids;
}

// One pass over every declared kind directory: id -> { kind, path, id }.
// Ids come from the file stem, which is what the manifest documents.
RpgcProject.index <- function () {
    if (this.indexValue != 0) return this.indexValue;
    local entries = [];
    local byKey = {};
    foreach (kind in this.kinds()) {
        local directory = this.directoryOf(kind);
        if (directory == "") continue;
        local extension = this.extensionOf(kind);
        foreach (id in this.idsIn(kind)) {
            local entry = {};
            entry.kind <- kind;
            entry.id <- id;
            entry.path <- directory + "/" + id + extension;
            entries.append(entry);
            byKey.rawset(kind + ":" + id, entry);
        }
    }
    local out = {};
    out.entries <- entries;
    out.byKey <- byKey;
    this.indexValue <- out;
    return out;
}

RpgcProject.invalidate <- function () {
    this.indexValue <- 0;
    return Rpgc.ok(true);
}

// ------------------------------------------------------------- folder view
//
// An editor shows the project FOLDER, not a list of documents a user has to
// "open" one of: the manifest already names exactly one directory per kind, so
// that directory is the list and picking a row is the load. `folder()` answers
// with that directory read live, plus the label a panel binds to.

RpgcProject.idsMatch <- function (left, right) {
    if (left.len() != right.len()) return false;
    for (local i = 0; i < left.len(); i += 1) {
        if (left[i] != right[i]) return false;
    }
    return true;
}

// What a panel shows for one kind, read from disk on every call.
//
// This deliberately bypasses `indexValue`: the index above is a start-up
// snapshot the validation gate wants to stay stable, while a panel must show
// the folder as it is now -- including a document an AI wrote five seconds ago.
//
// When the live listing disagrees with the cached index the cache is dropped.
// Without that, `loadById` would keep answering "project.unknown-id" for a row
// the panel is already displaying, which is the one way this view could lie.
RpgcProject.folder <- function (kind) {
    local ids = this.idsIn(kind);
    if (!this.idsMatch(this.idsOf(kind), ids)) this.invalidate();
    local directory = this.directoryOf(kind);
    local out = {};
    out.kind <- kind;
    out.directory <- directory;
    out.extension <- this.extensionOf(kind);
    out.ids <- ids;
    out.count <- ids.len();
    out.label <- directory + "  ·  " + ids.len() + " 个文档";
    return Rpgc.ok(out);
}

RpgcProject.entry <- function (kind, id) {
    local key = kind + ":" + id;
    local index = this.index();
    if (!index.byKey.rawin(key)) return 0;
    return index.byKey.rawget(key);
}

RpgcProject.pathOf <- function (kind, id) {
    local found = this.entry(kind, id);
    return found == 0 ? "" : found.path;
}

RpgcProject.idsOf <- function (kind) {
    local out = [];
    foreach (entry in this.index().entries) {
        if (entry.kind == kind) out.append(entry.id);
    }
    out.sort();
    return out;
}

// --------------------------------------------------------------- load

// Read and parse every document of a kind. Parse failures are reported but
// do not abort the scan, so the editor can show all broken files at once.
RpgcProject.loadKind <- function (kind) {
    local documents = [];
    local diagnostics = [];
    foreach (id in this.idsOf(kind)) {
        local path = this.pathOf(kind, id);
        local read = RpgcStore.readDocument(path);
        if (!read.ok) {
            foreach (d in read.diagnostics) diagnostics.append(d);
            continue;
        }
        local document = read.value;
        documents.append(document);
    }
    return Rpgc.result(documents, diagnostics);
}

RpgcProject.loadById <- function (kind, id) {
    local path = this.pathOf(kind, id);
    if (path == "") {
        return Rpgc.fail([Rpgc.error("project.unknown-id",
            "no " + kind + " with id '" + id + "'", "$",
            "known ids: " + this._join(this.idsOf(kind), ", "))]);
    }
    return RpgcStore.readDocument(path);
}

RpgcProject._join <- function (values, separator) {
    local text = "";
    for (local i = 0; i < values.len(); i += 1) {
        if (i > 0) text += separator;
        text += values[i];
    }
    return text;
}
