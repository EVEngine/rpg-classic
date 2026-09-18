// EVEngine workflow / rpg-classic — event editor ViewModel.
//
// Bound to editors/event.editor.json. An event is one ordered step list; the
// interesting editing problem is not typing fields but moving steps between the
// top level and a branch/parallel child, which is what `indentStep` /
// `outdentStep` do. The tree is kept one level deep on purpose: `RpgcEvent`
// enforces that limit, and the editor refuses the gesture locally too so the
// author learns why instead of getting a validation error after the fact.
//
// `validate` runs the same gate the CLI runs, on the in-memory document, so an
// author can iterate without staging anything.

import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcHost } from "game:/lib/rpgc_host.nut"
import { RpgcEvent } from "game:/lib/rpgc_event.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"

// EditorHost registers a ViewModel by looking the name up in the VM root
// (`EditorHost::registerVM`), and this file is a module, so `::EventVM` would
// land in the module's private environment and never be found. Publish it on
// the root explicitly.
getroottable().EventVM <- {
    // ------------------------------------------------------------- state
    // The panel is bound to a project FOLDER, not to a document that has to be
    // opened: `kind` names the manifest entry whose directory is the list, and
    // `eventList` is that directory's contents as of the last scan. Picking a
    // row loads it (`onChange`), and `pollFolder` keeps the list honest while
    // the editor is up -- an AI writing into content/events is the normal case.
    kind = "event",
    folderLabel = "content/events",
    folderPath = "content/events",
    folderCount = 0,
    folderTimer = 0.0,
    folderPollSeconds = 1.0,

    eventList = [],
    eventIndex = 0,
    eventId = "",
    eventTitle = "",
    repeatable = false,
    triggerKinds = ["manual", "portal_entered", "map_entered", "object_interacted", "quest_completed", "game_started"],
    triggerKind = "manual",
    triggerMap = "",
    triggerObject = "",
    triggerQuest = "",
    stepKinds = ["load_map", "move_actor", "face_actor", "play_animation", "wait", "camera_focus", "camera_pan", "dialogue", "message", "set_variable", "consume_object", "parallel", "branch"],
    stepKind = "message",
    stepList = [],
    stepIndex = 0,
    stepReference = "",
    stepActorId = "player",
    stepMapId = "",
    stepObjectName = "",
    stepAnim = "",
    stepClip = "",
    stepName = "",
    stepValue = 0.0,
    stepOp = "set",
    stepX = 0.0,
    stepY = 0.0,
    stepDuration = 0.35,
    stepCompare = "gte",
    status = "ready",
    diagnostics = "",
    dirty = false,
    mapList = [],
    animList = [],

    // Preview state for the selected step's camera/map target.
    previewKind = "",
    previewMap = "",
    previewX = 0.0,
    previewY = 0.0,

    doc = 0,
    // Parallel to `stepList`: the path of each row, e.g. [0] or [2, "then", 0].
    stepPaths = [],
    stepDepths = [],

    // ------------------------------------------------------------ lifecycle
    // Read `content/events` and publish it as the panel's list. There is no
    // "open a document" step in this editor: the folder is the list, and the
    // selection is the document, so scanning and selecting is the whole of it.
    loadFolder = function () {
        local folder = RpgcProject.folder(this.kind);
        if (!folder.ok) {
            this.report(folder);
            return;
        }
        local info = folder.value;
        this.folderPath = Rpgc.asString(Rpgc.get(info, "directory", ""));
        this.folderCount = Rpgc.asInt(Rpgc.get(info, "count", 0));
        this.folderLabel = Rpgc.asString(Rpgc.get(info, "label", this.folderPath));
        this.eventList = Rpgc.get(info, "ids", []);
        if (this.eventList.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 里没有事件";
            return;
        }
        this.eventIndex = Rpgc.selectedIndexOf(this.eventList, this.eventId, this.eventIndex);
        if (this.eventIndex < 0) this.eventIndex = 0;
        this.eventId = this.eventList[this.eventIndex];
    },

    // Load whichever row the list has selected. Called by `onChange` (picking a
    // row IS opening it), by `refreshFolder`, and at start-up -- never by a
    // button of its own, which is what "no open-document gesture" means here.
    loadSelected = function (editor, widget) {
        if (this.eventList.len() == 0) {
            this.status = "项目文件夹 " + this.folderPath + " 里没有事件";
            return;
        }
        local id = this.resolveEventId();
        local read = RpgcProject.loadById("event", id);
        if (!read.ok) {
            this.report(read);
            return;
        }
        this.doc = read.value;
        this.dirty = false;
        this.refresh();
        this.status = "载入 event/" + id;
        this.report(Rpgc.ok(true));
    },

    // Rescan the project folder and reload the selected document from disk.
    // The only way to throw away unsaved edits, so it is a deliberate gesture.
    refreshFolder = function (editor, widget) {
        this.loadFolder();
        this.loadSelected(editor, widget);
    },

    // Keep the list equal to what is on disk, on a slow timer.
    //
    // Only the LIST is refreshed here. Re-reading the open document would
    // silently discard unsaved edits, so that happens when the user asks
    // (`refreshFolder`) or when the selected row no longer exists at all -- in
    // which case there is nothing left to edit.
    pollFolder = function (dt) {
        this.folderTimer = Rpgc.numberOf(this.folderTimer) + Rpgc.numberOf(dt);
        if (this.folderTimer < this.folderPollSeconds) return;
        this.folderTimer = 0.0;
        local folder = RpgcProject.folder(this.kind);
        if (!folder.ok) return;
        local info = folder.value;
        this.folderPath = Rpgc.asString(Rpgc.get(info, "directory", this.folderPath));
        this.folderCount = Rpgc.asInt(Rpgc.get(info, "count", this.folderCount));
        this.folderLabel = Rpgc.asString(Rpgc.get(info, "label", this.folderLabel));
        local ids = Rpgc.get(info, "ids", []);
        if (RpgcProject.idsMatch(this.eventList, ids)) return;
        this.eventList = ids;
        if (ids.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 已没有事件";
            return;
        }
        this.eventIndex = Rpgc.selectedIndexOf(ids, this.eventId, this.eventIndex);
        if (this.eventIndex < 0) this.eventIndex = 0;
        if (ids[this.eventIndex] == this.eventId) {
            this.status = "项目文件夹已变化 (" + ids.len() + " 个事件)";
            return;
        }
        this.eventId = ids[this.eventIndex];
        this.loadSelected("event", "");
        this.status = "所选事件已不在文件夹中，载入 event/" + this.eventId;
    },

    newEvent = function (editor, widget) {
        local doc = {};
        doc.schema <- "eve.rpgc.event";
        doc.version <- 1;
        doc.id <- "event.untitled";
        doc.title <- "新事件";
        doc.repeatable <- false;
        doc.trigger <- { kind = "manual" };
        doc.steps <- [
            { kind = "camera_focus", x = 0.0, y = 0.0, zoom = 1.0 },
            { kind = "message", reference = "gameplayLog.story.recorded" },
            { kind = "wait", duration = 0.5 }
        ];
        this.doc = doc;
        this.dirty = true;
        this.refresh();
        this.status = "new event (unsaved)";
    },

    saveEvent = function (editor, widget) {
        if (this.doc == 0) {
            this.status = "nothing to save";
            return;
        }
        this.storeStep();
        local id = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        local path = RpgcProject.directoryOf("event") + "/" + id + ".json";
        local stale = RpgcStore.checkRevision(path);
        if (!stale.ok) {
            this.report(stale);
            return;
        }
        local result = RpgcValidate.commitDocument(path, this.doc);
        this.report(result);
        if (result.ok) {
            this.dirty = false;
            this.status = "staged " + path + " — run tools/rpgc.py export";
        }
    },

    // --------------------------------------------------------------- editing
    addStep = function (editor, widget) {
        this.storeStep();
        local steps = Rpgc.get(this.doc, "steps", []);
        steps.append(this.blankStep(this.stepKind));
        this.doc.steps <- steps;
        this.stepIndex = steps.len() - 1;
        this.dirty = true;
        this.refresh();
        this.status = "added " + this.stepKind + " step";
    },

    removeStep = function (editor, widget) {
        if (this.stepPaths.len() == 0) return;
        local path = this.stepPaths[this.stepIndex];
        local list = this.listAt(path);
        local index = path[path.len() - 1];
        if (list == 0 || index < 0 || index >= list.len()) return;
        list.remove(index);
        this.stepIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "removed step";
    },

    moveStepUp = function (editor, widget) { this.moveStep(-1); },
    moveStepDown = function (editor, widget) { this.moveStep(1); },

    moveStep = function (delta) {
        if (this.stepPaths.len() == 0) return;
        local path = this.stepPaths[this.stepIndex];
        local list = this.listAt(path);
        local index = path[path.len() - 1];
        local to = index + delta;
        if (list == 0 || to < 0 || to >= list.len()) return;
        local held = list[index];
        list[index] = list[to];
        list[to] = held;
        this.stepIndex = this.stepIndex + delta;
        this.dirty = true;
        this.refresh();
    },

    // Move the selected step into the previous sibling's branch/parallel body.
    // When there is no such sibling, a new `parallel` is created around the
    // selected step and its successor, which is the gesture authors actually
    // want when they decide two actions happen together.
    indentStep = function (editor, widget) {
        if (this.stepPaths.len() == 0) return;
        local path = this.stepPaths[this.stepIndex];
        local list = this.listAt(path);
        local index = path[path.len() - 1];
        if (list == 0) return;
        if (path.len() > 1) {
            this.status = "step is already inside a branch/parallel (v1 allows one level)";
            return;
        }
        local step = list[index];
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));

        if (index > 0) {
            local previous = list[index - 1];
            local previousKind = Rpgc.asString(Rpgc.get(previous, "kind", ""));
            if (previousKind == "branch" || previousKind == "parallel") {
                local field = previousKind == "branch" ? "then" : "steps";
                local body = Rpgc.get(previous, field, []);
                body.append(step);
                // `field` is computed ("then" / "steps"), so `<-` cannot express
                // this write; `rawset` creates the slot exactly like `<-` does.
                previous.rawset(field, body);
                list.remove(index);
                this.dirty = true;
                this.refresh();
                this.stepIndex = this.indexOfPath(this.pathOfChild(index - 1, field, body.len() - 1));
                this.status = "moved into " + previousKind + " body";
                return;
            }
        }

        local sibling = (index + 1 < list.len()) ? list[index + 1] : 0;
        local wrapper = { kind = "parallel", steps = [] };
        if (sibling != 0) wrapper.steps.append(sibling);
        wrapper.steps.append(step);
        if (sibling != 0) list.remove(index + 1);
        list[index] = wrapper;
        this.dirty = true;
        this.refresh();
        this.status = "wrapped " + (sibling == 0 ? 1 : 2) + " step(s) in parallel";
    },

    outdentStep = function (editor, widget) {
        if (this.stepPaths.len() == 0) return;
        local path = this.stepPaths[this.stepIndex];
        if (path.len() < 3) {
            this.status = "step is already at the top level";
            return;
        }
        local childIndex = path[path.len() - 1];
        local body = this.listAt(path);
        local parentPath = [];
        for (local i = 0; i < path.len() - 2; i += 1) parentPath.append(path[i]);
        local parentList = this.listAt(parentPath);
        local parentIndex = parentPath[parentPath.len() - 1];
        if (body == 0 || parentList == 0) return;
        local step = body[childIndex];
        body.remove(childIndex);
        parentList.insert(parentIndex + 1, step);
        this.dirty = true;
        this.refresh();
        this.stepIndex = parentIndex + 1;
        this.status = "moved step out of its parent";
    },

    setStepKind = function (editor, widget) {
        if (this.stepPaths.len() == 0) return;
        local step = this.stepAt(this.stepPaths[this.stepIndex]);
        if (step == 0) return;
        step.kind <- this.stepKind;
        // Start the new kind from a valid shape so the gate has something
        // meaningful to say about the rest of the fields.
        local blank = this.blankStep(this.stepKind);
        local names = blank.keys();
        for (local n = 0; n < names.len(); n += 1) {
            local name = names[n];
            if (!step.rawin(name)) step.rawset(name, blank.rawget(name));
        }
        this.dirty = true;
        this.refresh();
        this.status = "kind -> " + this.stepKind;
    },

    validate = function (editor, widget) {
        this.storeStep();
        local result = RpgcValidate.validateDocument("event", this.doc);
        local extras = RpgcEvent.semanticDiagnostics(this.doc);
        foreach (d in extras) {
            if (d.severity == "error") result.ok = false;
            result.diagnostics.append(d);
        }
        this.report(result);
        if (result.ok) this.status = "document is valid";
    },

    previewStep = function (editor, widget) {
        if (this.stepPaths.len() == 0) return;
        local step = this.stepAt(this.stepPaths[this.stepIndex]);
        if (step == 0) return;
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
        this.previewKind = kind;
        this.previewMap = Rpgc.asString(Rpgc.get(step, "mapId", this.triggerMap));
        this.previewX = Rpgc.asNumber(Rpgc.get(step, "x", 0));
        this.previewY = Rpgc.asNumber(Rpgc.get(step, "y", 0));
        this.status = "preview " + kind + " on map '" + this.previewMap + "'";
    },

    // -------------------------------------------------------------- helpers

    // The host writes a `slider` as a one-element array and a
    // `dropdown`/`listbox` as the selected string (EditorHost.cpp:876-930), so
    // numeric slots are unwrapped once per frame instead of at every use.
    normalize = function () {
        this.eventIndex = Rpgc.intOf(this.eventIndex);
        this.stepIndex = Rpgc.intOf(this.stepIndex);
        this.stepValue = Rpgc.numberOf(this.stepValue);
        this.stepX = Rpgc.numberOf(this.stepX);
        this.stepY = Rpgc.numberOf(this.stepY);
        this.stepDuration = Rpgc.numberOf(this.stepDuration);
    },

    // `eventId` holds the dropdown's selected id; `eventIndex` may hold a
    // listbox label or an index. Accept either binding.
    resolveEventId = function () {
        local index = Rpgc.selectedIndexOf(this.eventList, this.eventId, this.eventIndex);
        if (index < 0) return "";
        this.eventIndex = index;
        return this.eventList[index];
    },

    blankStep = function (kind) {
        local step = {};
        step.kind <- kind;
        if (kind == "load_map") {
            step.mapId <- (this.mapList.len() > 0 ? this.mapList[0] : "");
            step.x <- 0.0; step.y <- 0.0;
        } else if (kind == "move_actor") {
            step.actorId <- "player"; step.x <- 0.0; step.y <- 0.0;
        } else if (kind == "face_actor") {
            step.actorId <- "player"; step.facingX <- 0; step.facingY <- 1;
        } else if (kind == "play_animation") {
            step.actorId <- "player";
            step.anim <- (this.animList.len() > 0 ? this.animList[0] : "");
            step.clip <- "";
            step.loop <- false;
        } else if (kind == "wait") {
            step.duration <- 0.35;
        } else if (kind == "camera_focus") {
            step.x <- 0.0; step.y <- 0.0; step.zoom <- 1.0;
        } else if (kind == "camera_pan") {
            step.x <- 0.0; step.y <- 0.0; step.duration <- 0.6;
        } else if (kind == "dialogue" || kind == "message") {
            step.reference <- "";
        } else if (kind == "set_variable") {
            step.name <- "gold"; step.op <- "set"; step.value <- 0.0;
        } else if (kind == "consume_object") {
            step.mapId <- (this.mapList.len() > 0 ? this.mapList[0] : "");
            step.objectName <- "";
        } else if (kind == "parallel") {
            step.steps <- [];
        } else if (kind == "branch") {
            step.condition <- { kind = "switch", name = "" };
            step.then <- [];
            // `else` is a Squirrel keyword, so it cannot be written as a member
            // slot (`step.else <- []` is a parse error). The document key is
            // still "else"; it is only reachable through rawset/rawget.
            step.rawset("else", []);
        }
        return step;
    },

    // Depth-first walk producing the flat editor rows plus the path of each row.
    flatten = function () {
        this.stepList = [];
        this.stepPaths = [];
        this.stepDepths = [];
        this.walk(Rpgc.get(this.doc, "steps", []), [], 0);
    },

    walk = function (steps, prefix, depth) {
        for (local i = 0; i < steps.len(); i += 1) {
            local path = [];
            foreach (segment in prefix) path.append(segment);
            path.append(i);
            local step = steps[i];
            local indent = "";
            for (local d = 0; d < depth; d += 1) indent += "    ";
            this.stepList.append(indent + (i + 1) + ". "
                + Rpgc.asString(Rpgc.get(step, "kind", "?"))
                + this.stepSummary(step));
            this.stepPaths.append(path);
            this.stepDepths.append(depth);

            local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
            local field = kind == "branch" ? "then" : (kind == "parallel" ? "steps" : "");
            if (field == "") continue;
            local body = Rpgc.get(step, field, []);
            local bodyPrefix = [];
            foreach (segment in path) bodyPrefix.append(segment);
            bodyPrefix.append(field);
            this.walk(body, bodyPrefix, depth + 1);
            if (kind == "branch") {
                local elsePrefix = [];
                foreach (segment in path) elsePrefix.append(segment);
                elsePrefix.append("else");
                this.walk(Rpgc.get(step, "else", []), elsePrefix, depth + 1);
            }
        }
    },

    stepSummary = function (step) {
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
        if (kind == "wait" || kind == "camera_pan") {
            return "  " + format("%.2f", Rpgc.asNumber(Rpgc.get(step, "duration", 0))) + "s";
        }
        if (kind == "dialogue" || kind == "message") {
            return "  " + Rpgc.asString(Rpgc.get(step, "reference", ""));
        }
        if (kind == "load_map" || kind == "consume_object") {
            return "  " + Rpgc.asString(Rpgc.get(step, "mapId", ""))
                + (kind == "consume_object" ? "/" + Rpgc.asString(Rpgc.get(step, "objectName", "")) : "");
        }
        if (kind == "play_animation") {
            return "  " + Rpgc.asString(Rpgc.get(step, "anim", "")) + "/"
                + Rpgc.asString(Rpgc.get(step, "clip", ""));
        }
        if (kind == "set_variable") {
            return "  " + Rpgc.asString(Rpgc.get(step, "name", "")) + " "
                + Rpgc.asString(Rpgc.get(step, "op", "")) + " "
                + Rpgc.asNumber(Rpgc.get(step, "value", 0));
        }
        if (kind == "camera_focus") {
            return "  " + format("%.0f,%.0f", Rpgc.asNumber(Rpgc.get(step, "x", 0)),
                                 Rpgc.asNumber(Rpgc.get(step, "y", 0)));
        }
        return "";
    },

    listAt = function (path) {
        // path = [i]                 -> the root steps array
        // path = [i, "then", j]      -> the body array of steps[i]
        if (path.len() == 1) return Rpgc.get(this.doc, "steps", []);
        local stepIndex = path[0];
        local field = path[1];
        local steps = Rpgc.get(this.doc, "steps", []);
        if (stepIndex < 0 || stepIndex >= steps.len()) return 0;
        return Rpgc.get(steps[stepIndex], field, []);
    },

    stepAt = function (path) {
        local list = this.listAt(path);
        if (list == 0) return 0;
        local index = path[path.len() - 1];
        if (index < 0 || index >= list.len()) return 0;
        return list[index];
    },

    pathOfChild = function (parentIndex, field, childIndex) {
        return [parentIndex, field, childIndex];
    },

    indexOfPath = function (path) {
        for (local i = 0; i < this.stepPaths.len(); i += 1) {
            local candidate = this.stepPaths[i];
            if (candidate.len() != path.len()) continue;
            local same = true;
            for (local k = 0; k < path.len(); k += 1) {
                if (candidate[k] != path[k]) same = false;
            }
            if (same) return i;
        }
        return 0;
    },

    // Writes use `<-`, not `=`: in this EveScript VM `t.newSlot = v` raises
    // "the index 'newSlot' does not exist" and only `<-` creates a slot. Steps
    // are decoded from JSON and each kind carries only its own fields, so most
    // of the slots written below are absent until this runs. `skill.vm.nut`
    // documents the measurement.
    storeStep = function () {
        if (this.doc == 0 || this.stepPaths.len() == 0) return;
        local step = this.stepAt(this.stepPaths[this.stepIndex]);
        if (step == 0) return;
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
        if (kind == "dialogue" || kind == "message") step.reference <- this.stepReference;
        if (kind == "load_map" || kind == "consume_object" || kind == "move_actor"
            || kind == "play_animation" || kind == "face_actor") {
            step.actorId <- this.stepActorId;
        }
        if (kind == "load_map" || kind == "consume_object") {
            step.mapId <- this.stepMapId;
            step.objectName <- this.stepObjectName;
        }
        if (kind == "play_animation") {
            step.anim <- this.stepAnim;
            step.clip <- this.stepClip;
        }
        if (kind == "wait" || kind == "camera_pan") step.duration <- this.stepDuration;
        if (kind == "set_variable") {
            step.name <- this.stepName;
            step.op <- this.stepOp;
            step.value <- this.stepValue;
        }
        if (kind == "camera_focus" || kind == "camera_pan" || kind == "load_map"
            || kind == "move_actor") {
            step.x <- this.stepX;
            step.y <- this.stepY;
        }
        if (kind == "branch") {
            local condition = Rpgc.get(step, "condition", 0);
            if (typeof condition == "table") {
                condition.name <- this.stepName;
                condition.compare <- this.stepCompare;
                condition.value <- this.stepValue;
            }
        }
    },

    refresh = function () {
        if (this.doc == 0) return;
        this.eventId = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        this.eventTitle = Rpgc.asString(Rpgc.get(this.doc, "title", this.eventId));
        this.repeatable = Rpgc.get(this.doc, "repeatable", false) == true;
        local trigger = Rpgc.get(this.doc, "trigger", 0);
        if (typeof trigger == "table") {
            this.triggerKind = Rpgc.asString(Rpgc.get(trigger, "kind", "manual"));
            this.triggerMap = Rpgc.asString(Rpgc.get(trigger, "mapId", ""));
            this.triggerObject = Rpgc.asString(Rpgc.get(trigger, "objectName", ""));
            this.triggerQuest = Rpgc.asString(Rpgc.get(trigger, "questId", ""));
        }
        this.mapList = RpgcProject.idsOf("map");
        this.animList = RpgcProject.idsOf("anim");
        this.flatten();
        if (this.stepIndex >= this.stepList.len()) this.stepIndex = 0;
        this.loadStep();
    },

    loadStep = function () {
        if (this.stepPaths.len() == 0) return;
        local step = this.stepAt(this.stepPaths[this.stepIndex]);
        if (step == 0) return;
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
        this.stepKind = kind;
        this.stepReference = Rpgc.asString(Rpgc.get(step, "reference", ""));
        this.stepActorId = Rpgc.asString(Rpgc.get(step, "actorId", "player"));
        this.stepMapId = Rpgc.asString(Rpgc.get(step, "mapId", ""));
        this.stepObjectName = Rpgc.asString(Rpgc.get(step, "objectName", ""));
        this.stepAnim = Rpgc.asString(Rpgc.get(step, "anim", ""));
        this.stepClip = Rpgc.asString(Rpgc.get(step, "clip", ""));
        this.stepName = Rpgc.asString(Rpgc.get(step, "name", ""));
        this.stepOp = Rpgc.asString(Rpgc.get(step, "op", "set"));
        this.stepValue = Rpgc.asNumber(Rpgc.get(step, "value", 0));
        this.stepX = Rpgc.asNumber(Rpgc.get(step, "x", 0));
        this.stepY = Rpgc.asNumber(Rpgc.get(step, "y", 0));
        this.stepDuration = Rpgc.asNumber(Rpgc.get(step, "duration", 0));
        local condition = Rpgc.get(step, "condition", 0);
        if (typeof condition == "table") {
            if (Rpgc.asString(Rpgc.get(condition, "name", "")) != "") {
                this.stepName = Rpgc.asString(Rpgc.get(condition, "name", ""));
            }
            this.stepCompare = Rpgc.asString(Rpgc.get(condition, "compare", "gte"));
            this.stepValue = Rpgc.asNumber(Rpgc.get(condition, "value", 0));
        }
    },

    report = function (result) {
        this.diagnostics = Rpgc.summary(result);
        if (!result.ok) {
            local first = Rpgc.firstError(result);
            if (first != null) this.status = "[" + first.path + "] " + first.message;
        }
    },

    status_line = function () {
        return this.eventId + " | " + this.triggerKind
            + " | steps " + this.stepList.len()
            + " | selected " + (this.stepList.len() > 0 ? this.stepIndex + 1 : 0)
            + (this.dirty ? " | DIRTY" : "");
    },

    // --------------------------------------------------------------- drawer
    update = function (dt) {
        this.normalize();
        this.pollFolder(dt);
    },

    draw = function () {
        // See tilemap.vm.nut: no `gfx` root slot in the MCP host VM.
        local gfx = eve.Graphics();
        local canvas = this.canvasRect();
        if (canvas.width <= 1) return;
        gfx.drawSolidRect(canvas.x, canvas.y, canvas.width, canvas.height, 0.06, 0.07, 0.10, 1.0);
        // A storyboard strip: one block per step, indented by nesting depth,
        // with the selected step highlighted.
        local rows = this.stepList.len();
        if (rows == 0) return;
        local rowH = (canvas.height - 12.0) / rows;
        if (rowH > 34.0) rowH = 34.0;
        for (local i = 0; i < rows; i += 1) {
            local depth = this.stepDepths[i];
            local selected = (i == this.stepIndex);
            local x = canvas.x + 8.0 + depth * 22.0;
            local y = canvas.y + 6.0 + i * rowH;
            local w = canvas.width - 16.0 - depth * 22.0;
            local kind = Rpgc.asString(Rpgc.get(this.stepAt(this.stepPaths[i]), "kind", ""));
            local tint = this.tintOf(kind);
            gfx.drawSolidRect(x, y, w, rowH - 4.0,
                              selected ? tint[0] + 0.15 : tint[0] * 0.55,
                              selected ? tint[1] + 0.15 : tint[1] * 0.55,
                              selected ? tint[2] + 0.15 : tint[2] * 0.55,
                              1.0);
        }
    },

    tintOf = function (kind) {
        if (kind == "dialogue" || kind == "message") return [0.35, 0.45, 0.85];
        if (kind == "wait") return [0.45, 0.45, 0.50];
        if (kind == "camera_focus" || kind == "camera_pan") return [0.30, 0.70, 0.60];
        if (kind == "play_animation") return [0.80, 0.45, 0.30];
        if (kind == "load_map") return [0.55, 0.65, 0.30];
        if (kind == "branch") return [0.80, 0.70, 0.25];
        if (kind == "parallel") return [0.70, 0.40, 0.75];
        if (kind == "set_variable") return [0.40, 0.60, 0.40];
        return [0.40, 0.45, 0.55];
    },

    canvasRect = function () {
        local out = {};
        out.x <- 0.0;
        out.y <- 0.0;
        out.width <- 0.0;
        out.height <- 0.0;
        try {
            local parsed = RpgcJson.parse(eve.host.widgetRect("event", "storyboard"));
            if (!parsed.ok) return out;
            out.x = Rpgc.asNumber(Rpgc.get(parsed.value, "x", 0));
            out.y = Rpgc.asNumber(Rpgc.get(parsed.value, "y", 0));
            out.width = Rpgc.asNumber(Rpgc.get(parsed.value, "width", 0));
            out.height = Rpgc.asNumber(Rpgc.get(parsed.value, "height", 0));
        } catch (e) {
        }
        return out;
    },

    onChange = function (widget, value) {
        if (widget == "event") {
            // Selecting a row loads it immediately: the folder listing is the
            // document list, so there is no second "open" gesture to wait for.
            this.eventId = Rpgc.asString(value);
            this.normalize();
            this.loadSelected("event", "");
            return;
        }
        if (widget == "step") {
            this.storeStep();
            this.stepIndex = Rpgc.intOf(value);
            this.loadStep();
        }
        if (widget == "stepKind") this.stepKind = Rpgc.asString(value);
        if (widget == "triggerKind") this.triggerKind = Rpgc.asString(value);
        this.normalize();
        this.storeStep();
    }
};

RpgcHost.register("event", {
    update = function (dt) { EventVM.update(dt); },
    draw = function () { EventVM.draw(); },
    status = function () { return EventVM.status_line(); }
});

// Start-up: scan the project folder and show its first event. No argument, no
// document chooser -- the editor opens onto the game folder's data.
try {
    EventVM.loadFolder();
    EventVM.loadSelected("event", "");
} catch (e) {
    EventVM.status = "" + e;
    if ("log" in eve) eve.log("error", "event: initial folder load: " + e);
}
