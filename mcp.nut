// EVEngine workflow / rpg-classic — shared host script.
//
// Human entries (`eve run apps/<editor>`) run this file
// after mounting the workflow root, then open one editor. The Agent entry
// (`eve mcp --root .`) runs it after every `editors/*.vm.nut`
// has been compiled (src/engine/cmdline/Mcp.cpp:152-170) and restores all three
// panels. Both paths pump `eve_host_update` / `eve_host_render` from
// `EditorHost::frame`.
//
// The frame hooks live here rather than in an editor so that adding or removing
// an editor cannot break the others: each editor registers a drawer with
// `RpgcHost`, and the hooks pump whatever is registered.
//
// Saving this file reloads the host script and every module it imports, so a
// `lib/*.nut` edit is picked up without restarting the host: EditorHost reloads
// `mcp.nut`'s dependency closure through the module system's graph (`lib/` is
// not itself on the host's hot-reload list). Staged writes are session state and
// are cleared by that reload, so commit them first with `tools/rpgc.py export`.

// Each module is imported by name; there is no `dofile` loader any more, so
// this file declares exactly the surface it uses.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcIso } from "game:/lib/rpgc_iso.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcHost } from "game:/lib/rpgc_host.nut"
import { RpgcTilemap } from "game:/lib/rpgc_tilemap.nut"
import { RpgcSkill } from "game:/lib/rpgc_skill.nut"
import { RpgcEvent } from "game:/lib/rpgc_event.nut"
import { RpgcSystems } from "game:/lib/rpgc_systems.nut"
import { RpgcBattle } from "game:/lib/rpgc_battle.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"
import { RpgcApp } from "game:/lib/rpgc_app.nut"
import { RpgcWorkflow } from "game:/lib/rpgc.nut"

// ---------------------------------------------------------------------------
// Root facade for the eval-based entry points.
//
// `eve_eval` and `eve_run_script` evaluate with the ROOT table as their
// environment, while an `import`ed name is module-local -- that is the point of
// the module boundary. The CLI (`tools/rpgc.py`) and every recipe in
// docs/05-ai-safe-operation.md address the toolchain by name
// (`RpgcValidate.reportJson(...)`, `RpgcStore.takePendingJson()`,
// `RpgcHost.reportJson()`), so the host script -- the one place that owns the
// composition -- re-publishes the objects they name. Same mechanism as
// `RpgcGateJson` / `RpgcCommit` further down.
//
// This does not weaken the boundary. `tools/modules_check.nut` asserts these
// names are absent from the root table of ITS process; that is a plain
// `eve run -r` script and never loads this file. What is public here is the
// facade, not the modules' internals.
//
// The assignment has to go through `getroottable()`: an imported name is a
// module-scope slot, so a bare `RpgcHost <- RpgcHost` re-declares it and the
// host reports `MCP host script load failed: error: compile failed`.
// ---------------------------------------------------------------------------

RpgcPublishRoot <- function () {
    local root = getroottable();
    root.Rpgc <- Rpgc;
    root.RpgcJson <- RpgcJson;
    root.RpgcIso <- RpgcIso;
    root.RpgcStore <- RpgcStore;
    root.RpgcProject <- RpgcProject;
    root.RpgcHost <- RpgcHost;
    root.RpgcTilemap <- RpgcTilemap;
    root.RpgcSkill <- RpgcSkill;
    root.RpgcEvent <- RpgcEvent;
    root.RpgcSystems <- RpgcSystems;
    root.RpgcBattle <- RpgcBattle;
    root.RpgcItems <- RpgcItems;
    root.RpgcValidate <- RpgcValidate;
    root.RpgcApp <- RpgcApp;
    root.RpgcWorkflow <- RpgcWorkflow;
};

RpgcPublishRoot();

// ---------------------------------------------------------------------------
// Start-up validation. The host prints the gate result on every reload so an
// operator sees immediately whether the content tree is still sound; a failure
// is loud but does not stop the host, because an editor is exactly the tool you
// want when a document is broken.
// ---------------------------------------------------------------------------

RpgcInventory <- function () {
    local kinds = "";
    foreach (kind in RpgcProject.kinds()) {
        if (kinds != "") kinds += " ";
        kinds += kind + "=" + RpgcProject.idsOf(kind).len();
    }
    return kinds;
};

RpgcBootstrap <- function () {
    local report = RpgcValidate.validateProject();
    local summary = Rpgc.summary(report);
    local counts = Rpgc.get(report.value, "documents", {});
    local kinds = "";
    foreach (kind in RpgcProject.kinds()) {
        if (kinds != "") kinds += " ";
        kinds += kind + "=" + Rpgc.asInt(Rpgc.get(counts, kind, 0));
    }
    print("[rpgc] rpg-classic v" + RpgcWorkflow.version + " "
        + (report.ok ? "PASS" : "FAIL")
        + " | " + kinds + " | " + summary + "\n");
    if (!report.ok) {
        foreach (d in report.diagnostics) {
            if (d.severity == "error") {
                print("[rpgc]   " + d.path + ": " + d.message + "\n");
            }
        }
    }
    print("[rpgc] store backend=" + RpgcStore.backend()
        + " pending=" + RpgcStore.pendingCount() + "\n");
    return report;
};

// Human editor apps (`RpgcDeferBootstrap`) must not parse every tileset on
// the first frame: `content/tilesets/sbs-floors.json` is ~14k lines and the
// Squirrel JSON codec plus schema gate freeze the window for tens of seconds.
// Directory counts are enough to show the tree is mounted; the full gate stays
// on `RpgcGateJson()` / `RpgcBootstrap()` (MCP still runs it below).
if (("RpgcDeferBootstrap" in getroottable()) && RpgcDeferBootstrap) {
    print("[rpgc] ready v" + RpgcWorkflow.version + " | " + RpgcInventory()
        + " | store=" + RpgcStore.backend()
        + " | full gate: RpgcBootstrap()\n");
} else {
    RpgcBootstrap();
}

// ---------------------------------------------------------------------------
// Human editor app entry.
//
// `apps/<id>/main.nut` is a game script, so `load.nut` runs it with `dofile`:
// it has no module environment and therefore cannot `import` the library. It
// mounts this workflow root and runs *this* file through the host instead, and
// publishes the editor it wants as `RpgcEditorId` on the VM root. Opening the
// editor here — where the imports exist — keeps the module boundary intact.
// ---------------------------------------------------------------------------

if (("RpgcEditorId" in getroottable()) && RpgcEditorId != "") {
    local opened = RpgcApp.openEditor(RpgcEditorId);
    if (!opened.ok) {
        local message = opened.diagnostics.len() > 0
            ? opened.diagnostics[0].message : "openEditor failed";
        if ("log" in eve) eve.log("error", "rpgc: openEditor " + RpgcEditorId + ": " + message);
        throw message;
    }
    print("[rpgc] editor open " + RpgcEditorId + "\n");
}

// ---------------------------------------------------------------------------
// Host frame hooks.
// ---------------------------------------------------------------------------

eve_host_update <- function (dt) {
    RpgcHost.updateAll(dt);
};

eve_host_render <- function () {
    RpgcHost.renderAll();
};

// Convenience for an agent that wants the gate without building the expression
// by hand: `eve_eval RpgcGateJson()`.
RpgcGateJson <- function () {
    return RpgcValidate.reportJson(RpgcValidate.validateProject());
};

// Convenience for an agent driving a save: validates, then stages, then reports
// the canonical text length so the caller can decide to export.
RpgcCommit <- function (path, document) {
    return RpgcValidate.reportJson(RpgcValidate.commitDocument(path, document));
};
