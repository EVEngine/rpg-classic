// EVEngine workflow / rpg-classic — skill documents (kinds `anim`, `effect`, `skill`).
//
// The engine has no skill-animation model at all: `SkillDefinition`
// (src/modules/rpg/Skill.h:25-39) carries id/cooldown/castTime/targetType/costs/
// grantedEffects/tags/castCondition/extra, none of which name a clip, and
// `extra` is neither read by the engine nor exposed to Squirrel. So the
// "skill = several sprite animations + effects + per-level variation" contract
// has to live project-side, which is what this module defines:
//
//   content/anims/<id>.json    frame grid + named clips      -> SpriteSheet/SpriteClip
//   content/effects/<id>.json  engine effect template        -> replaceEffectsFromJson
//   content/skills/<id>.json   gameplay + presentation script
//
// The `skill` document splits cleanly into the half the engine consumes today
// (targetType/cooldown/castTime/costs/effects/tags/damage -> registerSkills*)
// and the half the project runtime consumes (presentation.segments plus the
// per-level overrides), which is why the editor can hand a validated document
// to both without translation.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcProject } from "./rpgc_project.nut"

export class RpgcSkill {
}

RpgcSkill.version <- 1
RpgcSkill.kinds <- ["anim", "effect", "skill"]

RpgcSkill.semanticDiagnostics <- function (document) {
    local schema = Rpgc.asString(Rpgc.get(document, "schema", ""));
    if (schema == "eve.rpgc.anim") return this.animDiagnostics(document);
    if (schema == "eve.rpgc.effect") return this.effectDiagnostics(document);
    if (schema == "eve.rpgc.skill") return this.skillDiagnostics(document);
    return [Rpgc.error("skill.unknown-schema",
        "RpgcSkill cannot validate schema '" + schema + "'", "$", "")];
}

// -------------------------------------------------------------- clips

RpgcSkill.animDiagnostics <- function (doc) {
    local diagnostics = [];
    local columns = Rpgc.asInt(Rpgc.get(doc, "columns", 1));
    local rows = Rpgc.asInt(Rpgc.get(doc, "rows", 0));
    local frameCount = -1;
    if (rows > 0) frameCount = columns * rows;

    local clips = Rpgc.get(doc, "clips", []);
    local seen = {};
    // The engine rejects a duplicate clip *name* only implicitly (the last
    // SpriteClip built wins), so uniqueness is enforced here.
    for (local i = 0; i < clips.len(); i += 1) {
        local clip = clips[i];
        local at = "/clips/" + i;
        local id = Rpgc.asString(Rpgc.get(clip, "id", ""));
        if (!Rpgc.validId(id)) {
            diagnostics.append(Rpgc.error("skill.bad-clip-id",
                "clip id must be a stable id", at + "/id", ""));
        } else if (seen.rawin(id)) {
            diagnostics.append(Rpgc.error("skill.duplicate-clip",
                "clip id '" + id + "' is used twice", at + "/id", ""));
        } else {
            seen.rawset(id, true);
        }

        local frames = Rpgc.get(clip, "frames", []);
        local events = Rpgc.get(clip, "events", []);
        local lastEventFrame = -1;
        for (local k = 0; k < events.len(); k += 1) {
            local frame = Rpgc.asInt(Rpgc.get(events[k], "frame", -1));
            if (frame < 0 || frame >= frames.len()) {
                diagnostics.append(Rpgc.error("skill.event-out-of-range",
                    "event frame " + frame + " is outside the clip's "
                    + frames.len() + " frame(s)", at + "/events/" + k + "/frame",
                    "SpriteClip::addEvent indexes clip frames, not sheet frames"));
            } else if (frame <= lastEventFrame) {
                diagnostics.append(Rpgc.error("skill.unsorted-events",
                    "clip events must be ordered by frame", at + "/events/" + k + "/frame", ""));
            } else {
                lastEventFrame = frame;
            }
        }

        if (frameCount < 0) continue;
        for (local f = 0; f < frames.len(); f += 1) {
            local sheetFrame = Rpgc.asInt(frames[f]);
            if (sheetFrame < 0 || sheetFrame >= frameCount) {
                diagnostics.append(Rpgc.error("skill.frame-out-of-range",
                    "sheet frame " + sheetFrame + " is outside the "
                    + columns + "x" + rows + " grid", at + "/frames/" + f, ""));
            }
        }
    }
    return diagnostics;
}

// ------------------------------------------------------------ effects

RpgcSkill.effectDiagnostics <- function (doc) {
    local diagnostics = [];
    local policy = Rpgc.asString(Rpgc.get(doc, "durationPolicy", "instant"));
    local duration = Rpgc.asNumber(Rpgc.get(doc, "duration", 0));
    local period = Rpgc.asNumber(Rpgc.get(doc, "period", 0));
    if (policy == "instant" && duration > 0) {
        diagnostics.append(Rpgc.warn("skill.instant-duration",
            "an instant effect ignores `duration`", "/duration",
            "set durationPolicy to \"duration\" or drop the duration"));
    }
    if (period > 0 && policy != "duration") {
        diagnostics.append(Rpgc.error("skill.period-requires-duration",
            "a periodic effect needs durationPolicy \"duration\"", "/period",
            "otherwise the engine never ticks it"));
    }
    if (duration > 0 && period > 0 && period > duration) {
        diagnostics.append(Rpgc.warn("skill.period-exceeds-duration",
            "period is longer than duration: the effect expires before its first tick",
            "/period", "lower the period or raise the duration"));
    }
    local stacks = Rpgc.asInt(Rpgc.get(doc, "maxStacks", 1));
    local stackPolicy = Rpgc.asString(Rpgc.get(doc, "stackPolicy", "none"));
    if (stacks > 1 && stackPolicy == "none") {
        diagnostics.append(Rpgc.warn("skill.stacks-unused",
            "maxStacks is " + stacks + " but stackPolicy is \"none\"", "/maxStacks",
            "use \"stack\" or \"refresh\""));
    }
    return diagnostics;
}

// ------------------------------------------------------------- skills

RpgcSkill.skillDiagnostics <- function (doc) {
    local diagnostics = [];
    local presentation = Rpgc.get(doc, "presentation", 0);
    if (typeof presentation != "table") {
        diagnostics.append(Rpgc.error("skill.no-presentation",
            "a skill needs a presentation block", "/presentation", ""));
        return diagnostics;
    }

    local segments = Rpgc.get(presentation, "segments", []);
    diagnostics = this.segmentDiagnostics(segments, "/presentation/segments", diagnostics);

    local levels = Rpgc.get(presentation, "levels", []);
    local seenLevel = {};
    local lastLevel = 0;
    for (local i = 0; i < levels.len(); i += 1) {
        local row = levels[i];
        local at = "/presentation/levels/" + i;
        local level = Rpgc.asInt(Rpgc.get(row, "level", 0));
        if (level < 1) {
            diagnostics.append(Rpgc.error("skill.bad-level",
                "level must be >= 1", at + "/level", ""));
        } else if (seenLevel.rawin(level)) {
            diagnostics.append(Rpgc.error("skill.duplicate-level",
                "level " + level + " is declared twice", at + "/level", ""));
        } else if (level <= lastLevel) {
            diagnostics.append(Rpgc.error("skill.unsorted-levels",
                "level rows must be ordered ascending", at + "/level", ""));
        } else {
            lastLevel = level;
        }
        seenLevel.rawset(level, true);

        local rowSegments = Rpgc.get(row, "segments", []);
        diagnostics = this.segmentDiagnostics(rowSegments, at + "/segments", diagnostics);
    }

    local damage = Rpgc.get(doc, "damage", 0);
    if (typeof damage == "table") {
        local formula = Rpgc.asString(Rpgc.get(damage, "formula", ""));
        if (formula == "" || this.formulaSanity(formula) != "") {
            local why = formula == "" ? "a damage formula is required" : this.formulaSanity(formula);
            diagnostics.append(Rpgc.error("skill.bad-formula", why, "/damage/formula",
                "the engine parses formulas with its own expression evaluator,"
                + " e.g. \"a.attack * 2\""));
        }
    }
    return diagnostics;
}

RpgcSkill.segmentDiagnostics <- function (segments, pointer, diagnostics) {
    for (local i = 0; i < segments.len(); i += 1) {
        local segment = segments[i];
        local at = pointer + "/" + i;
        if (Rpgc.asString(Rpgc.get(segment, "anim", "")) == "") {
            diagnostics.append(Rpgc.error("skill.segment-anim",
                "segment must name an animation set", at + "/anim", ""));
        }
        if (Rpgc.asString(Rpgc.get(segment, "clip", "")) == "") {
            diagnostics.append(Rpgc.error("skill.segment-clip",
                "segment must name a clip", at + "/clip", ""));
        }
        if (i > 0 && Rpgc.asNumber(Rpgc.get(segment, "hold", 0)) < 0) {
            diagnostics.append(Rpgc.error("skill.segment-hold",
                "hold must not be negative", at + "/hold", ""));
        }
    }
    return diagnostics;
}

// Conservative lexical sanity check. The engine's evaluator is the
// authority; this only rejects text that cannot possibly parse, so the
// editor can fail before an author runs the game.
RpgcSkill.formulaSanity <- function (formula) {
    if (formula.len() > 160) return "formula is unreasonably long";
    local depth = 0;
    for (local i = 0; i < formula.len(); i += 1) {
        local c = formula[i] & 0xFF;
        if (c == 40) depth += 1;
        else if (c == 41) {
            depth -= 1;
            if (depth < 0) return "unbalanced ')' in formula";
        }
    }
    if (depth != 0) return "unbalanced '(' in formula";
    local lowered = formula.tolower();
    foreach (bad in ["<script", ";", "import ", "dofile", "loadfile", "compilestring", "::"]) {
        if (lowered.find(bad) != null && lowered.find(bad) >= 0) {
            return "formula contains '" + bad + "', which the engine evaluator does not accept";
        }
    }
    return "";
}

// ---------------------------------------------------------- references

RpgcSkill.references <- function (doc) {
    local out = [];
    local schema = Rpgc.asString(Rpgc.get(doc, "schema", ""));
    if (schema == "eve.rpgc.skill") {
        local effects = Rpgc.get(doc, "effects", []);
        for (local i = 0; i < effects.len(); i += 1) {
            out.append({ kind = "effect", id = Rpgc.asString(effects[i]),
                         path = "/effects/" + i });
        }
        // A skill's `art` / `combo` back-references are what the art and combo
        // gates check for agreement; a dangling one is an ordinary missing
        // document, so it belongs to the generic reference gate, not to a
        // hand-rolled lookup over there.
        local artId = Rpgc.asString(Rpgc.get(doc, "art", ""));
        if (artId != "") out.append({ kind = "art", id = artId, path = "/art" });
        local comboId = Rpgc.asString(Rpgc.get(doc, "combo", ""));
        if (comboId != "") out.append({ kind = "combo", id = comboId, path = "/combo" });
        local presentation = Rpgc.get(doc, "presentation", 0);
        if (typeof presentation == "table") {
            this.collectSegmentRefs(Rpgc.get(presentation, "segments", []),
                "/presentation/segments", out);
            local levels = Rpgc.get(presentation, "levels", []);
            for (local i = 0; i < levels.len(); i += 1) {
                this.collectSegmentRefs(Rpgc.get(levels[i], "segments", []),
                    "/presentation/levels/" + i + "/segments", out);
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.anim") return out;
    return out;
}

RpgcSkill.collectSegmentRefs <- function (segments, pointer, out) {
    for (local i = 0; i < segments.len(); i += 1) {
        local anim = Rpgc.asString(Rpgc.get(segments[i], "anim", ""));
        if (anim == "") continue;
        out.append({ kind = "anim", id = anim, path = pointer + "/" + i + "/anim" });
    }
}

// Cross-document check the schema cannot express: a segment's clip must
// exist inside the animation set it points at. Called by
// `RpgcValidate.validateProject` through the uniform `extraDiagnostics` hook.
RpgcSkill.extraDiagnostics <- function () {
    local diagnostics = [];
    local skills = RpgcProject.loadKind("skill");
    if (!skills.ok) return diagnostics;
    foreach (skill in skills.value) {
        local presentation = Rpgc.get(skill, "presentation", 0);
        if (typeof presentation != "table") continue;
        local where = "skill/" + Rpgc.asString(Rpgc.get(skill, "id", ""));
        diagnostics = this.checkSegments(Rpgc.get(presentation, "segments", []),
            "/presentation/segments", where, diagnostics);
        local levels = Rpgc.get(presentation, "levels", []);
        for (local i = 0; i < levels.len(); i += 1) {
            diagnostics = this.checkSegments(Rpgc.get(levels[i], "segments", []),
                "/presentation/levels/" + i + "/segments", where, diagnostics);
        }
    }
    return diagnostics;
}

RpgcSkill.checkSegments <- function (segments, pointer, where, diagnostics) {
    for (local i = 0; i < segments.len(); i += 1) {
        local animId = Rpgc.asString(Rpgc.get(segments[i], "anim", ""));
        local clipId = Rpgc.asString(Rpgc.get(segments[i], "clip", ""));
        if (animId == "" || clipId == "") continue;
        local anim = RpgcProject.loadById("anim", animId);
        if (!anim.ok) continue;  // reported by the generic reference gate
        local found = false;
        foreach (clip in Rpgc.get(anim.value, "clips", [])) {
            if (Rpgc.asString(Rpgc.get(clip, "id", "")) == clipId) found = true;
        }
        if (!found) {
            diagnostics.append(Rpgc.error("skill.unknown-clip",
                where + " references clip '" + clipId + "' which anim/" + animId
                + " does not define", pointer + "/" + i + "/clip",
                "add the clip to the animation set or fix the name"));
        }
    }
    return diagnostics;
}
