// EVEngine workflow / rpg-classic — editor host bridge.
//
// `eve mcp` compiles `editors/*.vm.nut` BEFORE `mcp.nut`, so the host hooks
// (`eve_host_update` / `eve_host_render`) must be defined by the host script,
// not by an editor. Each editor's ViewModel therefore registers a drawer table
// here, and `mcp.nut` pumps them. That keeps one definition of the frame hooks
// no matter how many editors are open, and lets an editor be unloaded without
// taking the others down.
//
// A drawer is:
//   { update = function(dt) { ... },   // optional
//     draw   = function() { ... },     // optional, runs before ImGui panels
//     status = function() { ... } }    // optional, returns a one-line summary

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcStore } from "./rpgc_store.nut"

export class RpgcHost {
}

RpgcHost.version <- 1
RpgcHost.drawerOrder <- []
RpgcHost.drawers <- {}
RpgcHost.activeId <- ""
RpgcHost.frames <- 0
RpgcHost.lastError <- ""

RpgcHost.register <- function (id, drawer) {
    if (!this.drawers.rawin(id)) this.drawerOrder.append(id);
    this.drawers.rawset(id, drawer);
    if (this.activeId == "") this.activeId <- id;
    return Rpgc.ok(id);
}

RpgcHost.unregister <- function (id) {
    this.drawers.rawdelete(id);
    local kept = [];
    foreach (candidate in this.drawerOrder) {
        if (candidate != id) kept.append(candidate);
    }
    this.drawerOrder <- kept;
    if (this.activeId == id) this.activeId <- (kept.len() > 0 ? kept[0] : "");
    return Rpgc.ok(kept.len());
}

RpgcHost.setActive <- function (id) {
    this.activeId <- id;
    return Rpgc.ok(id);
}

RpgcHost.active <- function () {
    return this.activeId;
}

// Drawers run in registration order so the tilemap board (the only one
// that paints the main-window background) is drawn first.
RpgcHost.updateAll <- function (dt) {
    foreach (id in this.drawerOrder) {
        local drawer = this.drawers.rawget(id);
        if (!("update" in drawer)) continue;
        try {
            drawer.update(dt);
        } catch (e) {
            this.lastError <- id + ".update: " + e;
            print("[rpgc] " + this.lastError + "\n");
        }
    }
}

RpgcHost.renderAll <- function () {
    this.frames <- this.frames + 1;
    foreach (id in this.drawerOrder) {
        local drawer = this.drawers.rawget(id);
        if (!("draw" in drawer)) continue;
        try {
            drawer.draw();
        } catch (e) {
            this.lastError <- id + ".draw: " + e;
            print("[rpgc] " + this.lastError + "\n");
        }
    }
}

// One-line summaries for `eve_eval RpgcHost.reportJson()`.
RpgcHost.report <- function () {
    local lines = [];
    foreach (id in this.drawerOrder) {
        local drawer = this.drawers.rawget(id);
        local text = "";
        if ("status" in drawer) {
            try {
                text = "" + drawer.status();
            } catch (e) {
                text = "status error: " + e;
            }
        }
        local item = {};
        item.id <- id;
        item.status <- text;
        lines.append(item);
    }
    return lines;
}

RpgcHost.reportJson <- function () {
    local out = {};
    out.active <- this.activeId;
    out.frames <- this.frames;
    out.lastError <- this.lastError;
    out.editors <- this.report();
    out.backend <- RpgcStore.backend();
    out.pending <- RpgcStore.pendingCount();
    return RpgcJson.encodeCompact(out);
}
