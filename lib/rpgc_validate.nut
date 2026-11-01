// EVEngine workflow / rpg-classic — the validation gate.
//
// This is the piece that makes it safe for an AI to drive the editors. No
// mutation reaches the store without passing through here first, and the gate
// is layered so a failure is always attributable:
//
//   layer 0  strict JSON parse      (RpgcJson)        — syntax + duplicate keys
//   layer 1  Eve Schema v1          (eve.Schema())    — the engine's own
//                                                       validator, authoritative
//   layer 2  semantic document gate (RpgcTilemap / RpgcSkill / RpgcEvent)
//   layer 3  cross-reference gate   (this file)       — dangling ids, id/file
//                                                       mismatch, cycles
//
// Layer 1 matters most: it is the same C++ validator the engine uses for its
// own persistent formats, so a document the toolchain accepts is a document the
// engine's schema language accepts — not a re-implementation that can drift.
// Layers 1 and 2 both FAIL CLOSED: if the schema module is missing, or a kind
// names a document module this toolchain does not provide, the gate reports an
// error instead of silently validating nothing.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcStore } from "./rpgc_store.nut"
import { RpgcProject } from "./rpgc_project.nut"
import { RpgcTilemap } from "./rpgc_tilemap.nut"
import { RpgcSkill } from "./rpgc_skill.nut"
import { RpgcEvent } from "./rpgc_event.nut"
import { RpgcSystems } from "./rpgc_systems.nut"

import { RpgcDialogue } from "./rpgc_dialogue.nut"

import { RpgcQuests } from "./rpgc_quests.nut"

export class RpgcValidate {
}

RpgcValidate.version <- 1
RpgcValidate.registered <- false
RpgcValidate.registrationDiagnostics <- []

// -------------------------------------------------------- schema registry

RpgcValidate.registerSchemas <- function (directory) {
    if (directory == null || directory == "") directory = "schema";
    local diagnostics = [];
    local available = true;
    try {
        eve.Schema();
    } catch (e) {
        available = false;
    }
    if (!available) {
        return Rpgc.fail([Rpgc.error("validate.no-schema-module",
            "the schema module is not available; refusing to skip validation",
            "$", "run inside a build that includes the schema module")]);
    }

    local names = [];
    try {
        names = eve.Filesystem().getDirectoryItems(directory);
    } catch (e) {
        names = [];
    }
    if (names.len() == 0) {
        return Rpgc.fail([Rpgc.error("validate.no-schemas",
            "no schema documents found under " + directory, "$",
            "the workflow must ship its Eve Schema v1 files")]);
    }
    names.sort();

    local count = 0;
    foreach (name in names) {
        if (name.len() <= 5) continue;
        if (name.slice(name.len() - 5, name.len()) != ".json") continue;
        local path = directory + "/" + name;
        local read = RpgcStore.readText(path);
        if (!read.ok) {
            foreach (d in read.diagnostics) diagnostics.append(d);
            continue;
        }
        local result = eve.Schema().registerJson(read.value);
        if (!result.ok) {
            local message = result.status.summary;
            if (result.diagnostics.len() > 0) message = result.diagnostics[0].message;
            diagnostics.append(Rpgc.error("validate.schema-rejected",
                "schema " + name + " was rejected: " + message, path,
                "Eve Schema v1 supports id/schemaVersion/title/description/"
                + "additionalProperties/fields only"));
            continue;
        }
        count += 1;
    }

    this.registered <- Rpgc.errorCount(diagnostics) == 0;
    this.registrationDiagnostics <- diagnostics;
    local info = {};
    info.schemas <- count;
    info.directory <- directory;
    return Rpgc.result(info, diagnostics);
}

RpgcValidate.ensureRegistered <- function () {
    if (!this.registered) this.registerSchemas("schema");
    return Rpgc.ok(this.registered);
}

// ------------------------------------------------------------- layering

// Layer 0 + 1 for raw text: refuse anything that is not strict JSON and
// anything the engine's own schema validator rejects.
RpgcValidate.validateRaw <- function (kind, text) {
    local diagnostics = [];

    local parsed = RpgcJson.parse(text);
    if (!parsed.ok) {
        foreach (d in parsed.diagnostics) diagnostics.append(d);
        return Rpgc.fail(diagnostics);
    }

    this.ensureRegistered();
    if (!this.registered) {
        foreach (d in this.registrationDiagnostics) diagnostics.append(d);
        return Rpgc.fail(diagnostics);
    }

    local schemaId = RpgcProject.schemaOf(kind);
    if (schemaId == "") {
        diagnostics.append(Rpgc.error("validate.unknown-kind",
            "no schema is registered for kind '" + kind + "'", "$",
            "declare the kind in workflow.json"));
        return Rpgc.fail(diagnostics);
    }

    local result = eve.Schema().validateJson(schemaId, text);
    if (result == null) {
        diagnostics.append(Rpgc.error("validate.schema-call",
            "schema validation of " + schemaId + " returned nothing", "$", ""));
        return Rpgc.fail(diagnostics);
    }
    if (!result.ok) {
        foreach (d in result.diagnostics) {
            diagnostics.append(Rpgc.error("validate.schema",
                d.message, d.path, "schema " + schemaId));
        }
        if (result.diagnostics.len() == 0) {
            diagnostics.append(Rpgc.error("validate.schema",
                "schema " + schemaId + " rejected the document: " + result.status.summary,
                "$", ""));
        }
        return Rpgc.fail(diagnostics);
    }
    return Rpgc.result(parsed.value, diagnostics);
}

// Layer 0 + 1 + 2 for a whole document value: re-encode first so the schema
// sees exactly the bytes that would be written, then run the semantic gate.
RpgcValidate.validateDocument <- function (kind, document) {
    local text = RpgcJson.encode(document);
    local checked = this.validateRaw(kind, text);
    local diagnostics = [];
    foreach (d in checked.diagnostics) diagnostics.append(d);
    if (!checked.ok) return Rpgc.fail(diagnostics);

    local missing = this.moduleMissing(kind);
    if (missing != 0) diagnostics.append(missing);
    local module = this.moduleFor(kind);
    if (module != 0) {
        local semantic = module.semanticDiagnostics(document);
        foreach (d in semantic) diagnostics.append(d);
    }
    return Rpgc.result(document, diagnostics);
}

// Layers 0..2 for a file on disk.
RpgcValidate.validateFile <- function (kind, path) {
    local read = RpgcStore.readText(path);
    if (!read.ok) {
        foreach (d in read.diagnostics) d.path = path + ":" + d.path;
        return read;
    }
    local result = this.validateRaw(kind, read.value);
    if (!result.ok) {
        foreach (d in result.diagnostics) d.path = path + ":" + d.path;
        return result;
    }
    local document = result.value;
    local diagnostics = [];
    local missing = this.moduleMissing(kind);
    if (missing != 0) {
        missing.path = path + ":" + missing.path;
        diagnostics.append(missing);
    }
    local module = this.moduleFor(kind);
    if (module != 0) {
        foreach (d in module.semanticDiagnostics(document)) {
            d.path = path + ":" + d.path;
            diagnostics.append(d);
        }
    }
    diagnostics.append(this.idMatchesFile(kind, document, path));
    return Rpgc.result(document, diagnostics);
}

// The file stem is the stable id; a mismatch means two ids for one document.
RpgcValidate.idMatchesFile <- function (kind, document, path) {
    // The stem is the basename minus its declared extension, so
    // `content/skills/skill.fireball.json` has the stem `skill.fireball`.
    // Cutting at the FIRST dot instead would report `skill` and reject every
    // dotted id — the naming convention this workflow uses (`skill.strike`,
    // `mist-forest.arrival`, `village.elder-offer`).
    local stem = Rpgc.baseName(path);
    local extension = RpgcProject.extensionOf(kind);
    if (extension != "" && stem.len() > extension.len() &&
        stem.slice(stem.len() - extension.len(), stem.len()) == extension) {
        stem = stem.slice(0, stem.len() - extension.len());
    }
    local id = Rpgc.asString(Rpgc.get(document, "id", ""));
    if (id == stem) return Rpgc.note("ref.id-matches", "", "$", "");
    return Rpgc.error("ref.id-file-mismatch",
        "document id '" + id + "' must equal the file stem '" + stem + "'",
        "/id", "rename the file or fix the id");
}

// --------------------------------------------------------- references

// Layer 2 dispatch. The kind -> document-module edge is a static import now, so
// a manifest that names a module this build does not provide can no longer mean
// "that module happened not to be loaded" — it means the kind is unchecked.
// `moduleFor` returns 0 only for a kind that declares no module at all, and
// every caller that skips on 0 reports `moduleMissing` first: skipping quietly
// would let layers 2 and 3 report a clean pass over documents nothing read.
RpgcValidate.moduleFor <- function (kind) {
    local name = Rpgc.asString(Rpgc.get(RpgcProject.kindSpec(kind), "module", ""));
    if (name == "RpgcTilemap") return RpgcTilemap;
    if (name == "RpgcSkill") return RpgcSkill;
    if (name == "RpgcEvent") return RpgcEvent;
    if (name == "RpgcSystems") return RpgcSystems;
    if (name == "RpgcDialogue") return RpgcDialogue;
    if (name == "RpgcQuests") return RpgcQuests;
    return 0;
}

// A diagnostic when a kind names a document module that does not exist, and 0
// when the kind is fine (module present, or deliberately none).
RpgcValidate.moduleMissing <- function (kind) {
    local name = Rpgc.asString(Rpgc.get(RpgcProject.kindSpec(kind), "module", ""));
    if (name == "" || this.moduleFor(kind) != 0) return 0;
    return Rpgc.error("validate.unknown-module",
        "kind '" + kind + "' names document module '" + name
        + "', which this toolchain does not provide",
        "/kinds/" + kind + "/module",
        "RpgcTilemap, RpgcSkill, RpgcEvent, RpgcSystems, RpgcDialogue or RpgcQuests");
}

// Layer 3. Every loaded document contributes typed references; each must
// resolve to an existing document of the declared kind.
RpgcValidate.validateReferences <- function () {
    local diagnostics = [];
    local counts = {};
    foreach (kind in RpgcProject.kinds()) {
        local module = this.moduleFor(kind);
        if (module == 0) {
            local missing = this.moduleMissing(kind);
            if (missing != 0) diagnostics.append(missing);
            continue;
        }
        local loaded = RpgcProject.loadKind(kind);
        foreach (d in loaded.diagnostics) diagnostics.append(d);
        if (!loaded.ok) continue;
        foreach (document in loaded.value) {
            local id = Rpgc.asString(Rpgc.get(document, "id", ""));
            local where = kind + "/" + id;
            foreach (reference in module.references(document)) {
                local targetKind = Rpgc.asString(Rpgc.get(reference, "kind", ""));
                local targetId = Rpgc.asString(Rpgc.get(reference, "id", ""));
                local at = Rpgc.asString(Rpgc.get(reference, "path", "$"));
                if (targetKind == "" || targetId == "") continue;
                counts[targetKind] <- Rpgc.asInt(Rpgc.get(counts, targetKind, 0)) + 1;
                if (RpgcProject.pathOf(targetKind, targetId) == "") {
                    diagnostics.append(Rpgc.error("ref.dangling",
                        where + " references missing " + targetKind + " '" + targetId + "'",
                        at,
                        "define " + RpgcProject.directoryOf(targetKind) + "/" + targetId
                        + RpgcProject.extensionOf(targetKind)));
                }
            }
        }
    }
    local info = {};
    info.references <- counts;
    return Rpgc.result(info, diagnostics);
}

// ------------------------------------------------------------- whole run

// Everything an editor or the CLI needs in one call: the schema registry,
// every document, and every cross-reference. `ok` is the single gate.
RpgcValidate.validateProject <- function () {
    this.ensureRegistered();
    local diagnostics = [];
    foreach (d in this.registrationDiagnostics) diagnostics.append(d);
    if (!this.registered) {
        return Rpgc.fail(diagnostics);
    }

    // Fail closed on an unreadable manifest: without it there are no kinds,
    // and an empty kind list would make the loops below report a clean pass
    // over zero documents.
    local manifest = RpgcProject.manifest();
    if (typeof manifest != "table") {
        diagnostics.append(Rpgc.error("validate.no-manifest",
            "workflow.json could not be read, so no content was validated", "$",
            "fix or create workflow.json before trusting a PASS"));
        return Rpgc.fail(diagnostics);
    }
    if (RpgcProject.kinds().len() == 0) {
        diagnostics.append(Rpgc.error("validate.no-kinds",
            "workflow.json declares no content kinds, so nothing was validated",
            "/kinds", "declare at least one kind with a directory and schema"));
        return Rpgc.fail(diagnostics);
    }
    RpgcProject.invalidate();

    local kinds = {};
    local totals = {};
    foreach (kind in RpgcProject.kinds()) {
        local results = [];
        local perKind = 0;
        foreach (id in RpgcProject.idsOf(kind)) {
            local path = RpgcProject.pathOf(kind, id);
            local result = this.validateFile(kind, path);
            perKind += 1;
            foreach (d in result.diagnostics) {
                if (d.severity == "info") continue;
                results.append(d);
            }
            if (!result.ok) {
                diagnostics.append(Rpgc.error("validate.document",
                    kind + "/" + id + " failed validation", path,
                    Rpgc.summary(result)));
            }
        }
        foreach (d in results) diagnostics.append(d);
        totals.rawset(kind, perKind);
    }
    kinds.rawset("documents", totals);

    local references = this.validateReferences();
    foreach (d in references.diagnostics) diagnostics.append(d);

    // Cross-document checks each document module owns on top of the generic
    // reference gate (e.g. "this skill names a clip its anim set lacks").
    // Once per MODULE, not once per kind: a module serves several kinds
    // (`RpgcSkill` owns anim/effect/skill, `RpgcSystems` owns five), and asking
    // it the same whole-project question once per kind reported every finding
    // two to five times over.
    local visited = [];
    foreach (kind in RpgcProject.kinds()) {
        local module = this.moduleFor(kind);
        if (module == 0) continue;
        if (!("extraDiagnostics" in module)) continue;
        local seen = false;
        foreach (previous in visited) if (previous == module) seen = true;
        if (seen) continue;
        visited.append(module);
        foreach (d in module.extraDiagnostics()) diagnostics.append(d);
    }

    local report = {};
    report.documents <- totals;
    report.references <- Rpgc.get(references.value, "references", {});
    report.backend <- RpgcStore.backend();
    return Rpgc.result(report, diagnostics);
}

// Stable machine-readable text for an AI to read back through `eve_eval`.
// Diagnostic paths are preserved, so a caller can locate every problem.
RpgcValidate.reportJson <- function (result) {
    local out = {};
    out.ok <- result.ok;
    out.summary <- Rpgc.summary(result);
    out.errors <- Rpgc.errorCount(result.diagnostics);
    out.diagnostics <- result.diagnostics;
    out.value <- result.value;
    return RpgcJson.encodeCompact(out);
}

// Map a project-relative path back to its content kind using the manifest.
// Longest directory prefix wins, so nested kinds stay unambiguous.
RpgcValidate.kindOfPath <- function (path) {
    local best = "";
    local bestLength = -1;
    foreach (kind in RpgcProject.kinds()) {
        local directory = RpgcProject.directoryOf(kind);
        if (directory == "") continue;
        local prefix = directory + "/";
        if (path.len() <= prefix.len()) continue;
        if (path.slice(0, prefix.len()) != prefix) continue;
        if (prefix.len() > bestLength) {
            bestLength = prefix.len();
            best = kind;
        }
    }
    return best;
}

// Validate then stage in one step. This is the only sanctioned write path
// for a caller that is not the editor itself, so the CLI and an AI go
// through exactly the same gate the editor does. Returns a Result whose
// value carries the fingerprint to record.
RpgcValidate.commitRaw <- function (path, text) {
    local kind = this.kindOfPath(path);
    if (kind == "") {
        return Rpgc.fail([Rpgc.error("validate.unknown-kind",
            "cannot tell which content kind '" + path + "' belongs to", "$",
            "paths must live under one of the manifest kind directories")]);
    }
    local checked = this.validateRaw(kind, text);
    if (!checked.ok) return checked;

    local missing = this.moduleMissing(kind);
    if (missing != 0) return Rpgc.fail([missing]);

    local semantic = [];
    local module = this.moduleFor(kind);
    if (module != 0) {
        foreach (d in module.semanticDiagnostics(checked.value)) semantic.append(d);
    }
    if (Rpgc.errorCount(semantic) > 0) {
        return Rpgc.result(0, semantic);
    }

    local staged = RpgcStore.stage(path, text);
    if (!staged.ok) return staged;
    local info = {};
    info.path <- path;
    info.kind <- kind;
    info.fingerprint <- staged.value;
    info.bytes <- text.len();
    return Rpgc.result(info, semantic);
}

RpgcValidate.commitDocument <- function (path, document) {
    return this.commitRaw(path, RpgcJson.encode(document) + "\n");
}
