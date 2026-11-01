// EVEngine workflow / rpg-classic — event documents (kind `event`).
//
// The engine ships one strict, versioned, resumable presentation-command
// document: `eve.rpg.story-events` v1 (src/modules/rpg/StoryEvent.cpp), with the
// closed step set {dialogue, message, wait, move, camera}. It has no map-load
// step, no animation step, no parallel group, no branch, no variable step, and
// its `camera` step is parsed but never applied by the example runtime.
//
// This module defines the document that fills those gaps. Each step kind is
// labelled with what actually backs it at runtime (see docs/03-event-editor.md
// for the full table):
//
//   engine-real    load_map, wait, camera_focus, dialogue, message,
//                  set_variable, consume_object
//   project-hook   move_actor (NPC), face_actor, play_animation, camera_pan,
//                  parallel, branch
//
// The schema bounds the step vocabulary; this gate enforces per-kind required
// fields, the nesting depth limit, and the cross-document references. Anything
// the engine parses but silently ignores is therefore an error here.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcProject } from "./rpgc_project.nut"
import { RpgcSystems } from "./rpgc_systems.nut"

export class RpgcEvent {
}

RpgcEvent.version <- 1
RpgcEvent.kinds <- ["event"]
RpgcEvent.maxDepth <- 2

// kind -> required field names. Kept as a table so the editor can render a
// "what is still missing" hint without hard-coding the rules twice.
RpgcEvent.requiredFields <- {
    load_map = ["mapId", "x", "y"],
    move_actor = ["actorId", "x", "y"],
    face_actor = ["actorId", "facingX", "facingY"],
    play_animation = ["anim", "clip"],
    wait = ["duration"],
    camera_focus = ["x", "y"],
    camera_pan = ["x", "y", "duration"],
    dialogue = ["reference"],
    message = ["reference"],
    set_variable = ["name", "op", "value"],
    consume_object = ["mapId", "objectName"],
    parallel = ["steps"],
    branch = ["condition", "then"]
}

RpgcEvent.semanticDiagnostics <- function (document) {
    if (Rpgc.get(document, "schema", "") != "eve.rpgc.event") {
        return [Rpgc.error("event.schema-mismatch",
            "expected schema eve.rpgc.event", "/schema", "")];
    }
    local diagnostics = [];
    local trigger = Rpgc.get(document, "trigger", 0);
    if (typeof trigger == "table") {
        local kind = Rpgc.asString(Rpgc.get(trigger, "kind", ""));
        if (kind == "portal_entered" || kind == "map_entered") {
            if (Rpgc.asString(Rpgc.get(trigger, "mapId", "")) == "") {
                diagnostics.append(Rpgc.error("event.trigger-map",
                    "trigger kind '" + kind + "' needs a mapId", "/trigger/mapId", ""));
            }
        }
        if (kind == "object_interacted" &&
            Rpgc.asString(Rpgc.get(trigger, "objectName", "")) == "") {
            diagnostics.append(Rpgc.error("event.trigger-object",
                "trigger kind 'object_interacted' needs an objectName",
                "/trigger/objectName", ""));
        }
        if (kind == "quest_completed" &&
            Rpgc.asString(Rpgc.get(trigger, "questId", "")) == "") {
            diagnostics.append(Rpgc.error("event.trigger-quest",
                "trigger kind 'quest_completed' needs a questId", "/trigger/questId", ""));
        }
    }
    diagnostics = this.stepListDiagnostics(Rpgc.get(document, "steps", []),
        "/steps", 1, diagnostics);
    return diagnostics;
}

RpgcEvent.stepListDiagnostics <- function (steps, pointer, depth, diagnostics) {
    for (local i = 0; i < steps.len(); i += 1) {
        diagnostics = this.stepDiagnostics(steps[i], pointer + "/" + i, depth, diagnostics);
    }
    return diagnostics;
}

RpgcEvent.stepDiagnostics <- function (step, at, depth, diagnostics) {
    local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
    if (!this.requiredFields.rawin(kind)) {
        diagnostics.append(Rpgc.error("event.unknown-step",
            "unknown step kind '" + kind + "'", at + "/kind",
            "see docs/03-event-editor.md for the closed set"));
        return diagnostics;
    }

    foreach (field in this.requiredFields.rawget(kind)) {
        if (!this.present(step, field)) {
            diagnostics.append(Rpgc.error("event.missing-field",
                "step '" + kind + "' needs '" + field + "'", at + "/" + field,
                "the runtime cannot execute a step with an empty " + field));
        }
    }

    if (kind == "wait" || kind == "camera_pan") {
        if (Rpgc.asNumber(Rpgc.get(step, "duration", 0)) <= 0) {
            diagnostics.append(Rpgc.error("event.bad-duration",
                "step '" + kind + "' requires duration > 0", at + "/duration",
                "the engine's own wait step rejects a zero duration"));
        }
    }
    if (kind == "face_actor") {
        local fx = Rpgc.asInt(Rpgc.get(step, "facingX", 0));
        local fy = Rpgc.asInt(Rpgc.get(step, "facingY", 0));
        if (fx == 0 && fy == 0) {
            diagnostics.append(Rpgc.error("event.zero-facing",
                "face_actor needs a non-zero facing", at + "/facingX",
                "the project runtime keeps exactly one non-zero component"));
        }
        if (fx != 0 && fy != 0) {
            diagnostics.append(Rpgc.error("event.diagonal-facing",
                "face_actor must set only one of facingX/facingY", at + "/facingX",
                "the project runtime keeps exactly one non-zero component"));
        }
    }
    if (kind == "set_variable") {
        local op = Rpgc.asString(Rpgc.get(step, "op", ""));
        if (op == "switchOn" || op == "switchOff") {
            if (Rpgc.asString(Rpgc.get(step, "name", "")) == "") {
                diagnostics.append(Rpgc.error("event.bad-switch",
                    "a switch step needs a name", at + "/name", ""));
            }
        }
    }

    if (kind == "branch") {
        local condition = Rpgc.get(step, "condition", 0);
        if (typeof condition == "table") {
            diagnostics = this.conditionDiagnostics(condition, at + "/condition", diagnostics);
        }
        local thenSteps = Rpgc.get(step, "then", []);
        local elseSteps = Rpgc.get(step, "else", []);
        if (depth >= this.maxDepth) {
            diagnostics.append(Rpgc.error("event.depth",
                "branch/parallel nesting is limited to " + this.maxDepth
                + " levels in v1", at, "flatten the step list or split the event"));
        }
        diagnostics = this.stepListDiagnostics(thenSteps, at + "/then", depth + 1, diagnostics);
        diagnostics = this.stepListDiagnostics(elseSteps, at + "/else", depth + 1, diagnostics);
        if (thenSteps.len() == 0) {
            diagnostics.append(Rpgc.error("event.empty-branch",
                "branch needs at least one step in `then`", at + "/then", ""));
        }
    }
    if (kind == "parallel") {
        local children = Rpgc.get(step, "steps", []);
        if (children.len() < 2) {
            diagnostics.append(Rpgc.warn("event.trivial-parallel",
                "parallel with fewer than two steps is just a sequence", at + "/steps",
                "use the plain step order instead"));
        }
        if (depth >= this.maxDepth) {
            diagnostics.append(Rpgc.error("event.depth",
                "branch/parallel nesting is limited to " + this.maxDepth
                + " levels in v1", at, "flatten the step list or split the event"));
        }
        diagnostics = this.stepListDiagnostics(children, at + "/steps", depth + 1, diagnostics);
    }
    return diagnostics;
}

// The condition vocabulary is shared with `eve.rpgc.world` through the single
// schema `eve.rpgc.condition`, so its per-kind rules live in exactly one place:
// `RpgcSystems.conditionDiagnostics`. This used to be a second implementation
// with its own diagnostic codes, which is precisely how two syntaxes drift.
// `momentTable()` is what lets a `moment` condition be resolved against the
// world document even when a single event file is validated on its own.
RpgcEvent.conditionDiagnostics <- function (condition, at, diagnostics) {
    return RpgcSystems.conditionDiagnostics(condition, at,
        RpgcSystems.momentTable(), diagnostics);
}

RpgcEvent.present <- function (step, field) {
    if (!Rpgc.has(step, field)) return false;
    local value = Rpgc.get(step, field, 0);
    if (typeof value == "string") return value != "";
    if (typeof value == "array") return value.len() > 0;
    return true;  // numbers and booleans are meaningful even at 0/false
}

// ---------------------------------------------------------- references

RpgcEvent.references <- function (doc) {
    local out = [];
    local trigger = Rpgc.get(doc, "trigger", 0);
    if (typeof trigger == "table") {
        foreach (field in ["mapId", "targetMap"]) {
            local id = Rpgc.asString(Rpgc.get(trigger, field, ""));
            if (id != "") out.append({ kind = "map", id = id, path = "/trigger/" + field });
        }
    }
    this.collectStepRefs(Rpgc.get(doc, "steps", []), "/steps", out);
    return out;
}

RpgcEvent.collectStepRefs <- function (steps, pointer, out) {
    for (local i = 0; i < steps.len(); i += 1) {
        local step = steps[i];
        local at = pointer + "/" + i;
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
        local mapId = Rpgc.asString(Rpgc.get(step, "mapId", ""));
        if (mapId != "" && (kind == "load_map" || kind == "consume_object")) {
            out.append({ kind = "map", id = mapId, path = at + "/mapId" });
        }
        local anim = Rpgc.asString(Rpgc.get(step, "anim", ""));
        if (anim != "" && kind == "play_animation") {
            out.append({ kind = "anim", id = anim, path = at + "/anim" });
        }
        if (kind == "dialogue") {
            local ref = Rpgc.asString(Rpgc.get(step, "reference", ""));
            if (ref != "") out.append({ kind = "dialogue", id = ref, path = at + "/reference" });
        }
        local condition = Rpgc.get(step, "condition", 0);
        if (typeof condition == "table") {
            local conditionMap = Rpgc.asString(Rpgc.get(condition, "mapId", ""));
            if (conditionMap != "" && Rpgc.get(condition, "kind", "") == "object_consumed") {
                out.append({ kind = "map", id = conditionMap, path = at + "/condition/mapId" });
            }
        }
        this.collectStepRefs(Rpgc.get(step, "then", []), at + "/then", out);
        this.collectStepRefs(Rpgc.get(step, "else", []), at + "/else", out);
        this.collectStepRefs(Rpgc.get(step, "steps", []), at + "/steps", out);
    }
    return out;
}

// A `play_animation` step must name a clip the animation set really defines.
// Called by `RpgcValidate.validateProject` through the uniform
// `extraDiagnostics` hook.
RpgcEvent.extraDiagnostics <- function () {
    local diagnostics = [];
    local events = RpgcProject.loadKind("event");
    if (!events.ok) return diagnostics;
    foreach (document in events.value) {
        diagnostics = this.checkSteps(Rpgc.get(document, "steps", []), "/steps",
            "event/" + Rpgc.asString(Rpgc.get(document, "id", "")), diagnostics);
    }
    return diagnostics;
}

RpgcEvent.checkSteps <- function (steps, pointer, where, diagnostics) {
    for (local i = 0; i < steps.len(); i += 1) {
        local step = steps[i];
        local at = pointer + "/" + i;
        if (Rpgc.get(step, "kind", "") == "play_animation") {
            local animId = Rpgc.asString(Rpgc.get(step, "anim", ""));
            local clipId = Rpgc.asString(Rpgc.get(step, "clip", ""));
            if (animId != "" && clipId != "") {
                local anim = RpgcProject.loadById("anim", animId);
                if (anim.ok) {
                    local found = false;
                    foreach (clip in Rpgc.get(anim.value, "clips", [])) {
                        if (Rpgc.asString(Rpgc.get(clip, "id", "")) == clipId) found = true;
                    }
                    if (!found) {
                        diagnostics.append(Rpgc.error("event.unknown-clip",
                            where + " references clip '" + clipId + "' which anim/"
                            + animId + " does not define", at + "/clip", ""));
                    }
                }
            }
        }
        diagnostics = this.checkSteps(Rpgc.get(step, "then", []), at + "/then", where, diagnostics);
        diagnostics = this.checkSteps(Rpgc.get(step, "else", []), at + "/else", where, diagnostics);
        diagnostics = this.checkSteps(Rpgc.get(step, "steps", []), at + "/steps", where, diagnostics);
    }
    return diagnostics;
}
