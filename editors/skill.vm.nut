// EVEngine workflow / rpg-classic — skill editor ViewModel.
//
// Bound to editors/skill.editor.json. A skill is authored as three linked
// documents: the animation sets its playback segments point at, the effects it
// grants, and the skill itself. This ViewModel edits the skill document; the
// inspector is a right-hand panel only. The host draws the game combat screen
// in the main window (battle canvas letterboxed left of the inspector), which
// is also where presentation clips play.
//
// Everything shown here is a projection of `RpgcSkill`; no rule is duplicated.
// Saving goes through `RpgcValidate.commitDocument`, so a skill that points at a
// clip that does not exist cannot reach disk.

import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcHost } from "game:/lib/rpgc_host.nut"
import { RpgcSkill } from "game:/lib/rpgc_skill.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"

// EditorHost registers a ViewModel by looking the name up in the VM root
// (`EditorHost::registerVM`), and this file is a module, so `::SkillVM` would
// land in the module's private environment and never be found. Publish it on
// the root explicitly.
getroottable().SkillVM <- {
    // ------------------------------------------------------------- state
    // The panel is bound to a project FOLDER, not to a document that has to be
    // opened: `kind` names the manifest entry whose directory is the list, and
    // `skillList` is that directory's contents as of the last scan. Picking a
    // row loads it (`onChange`), and `pollFolder` keeps the list honest while
    // the editor is up -- an AI writing into content/skills is the normal case.
    kind = "skill",
    folderLabel = "content/skills",
    folderPath = "content/skills",
    folderCount = 0,
    folderTimer = 0.0,
    folderPollSeconds = 1.0,

    skillList = [],
    skillIndex = 0,
    skillId = "",
    skillTitle = "",
    targetTypes = ["enemySingle", "enemyAll", "allySingle", "allyAll", "self", "anySingle", "anyAll"],
    targetType = "enemySingle",
    cooldown = 3.0,
    castTime = 0.6,
    formula = "a.attack * 1.0",
    element = "none",
    elements = ["none", "fire", "ice", "thunder", "earth", "wind", "light", "dark"],
    effectList = [],
    animList = [],
    segmentList = [],
    segmentIndex = 0,
    segmentAnim = "",
    segmentClip = "",
    segmentOn = "caster",
    segmentAtEvent = "",
    segmentHold = 0.0,
    levelList = [],
    levelIndex = 0,
    levelValue = 1,
    levelMagnitude = 1.0,
    levelVfx = "",
    vfx = "",
    status = "ready",
    diagnostics = "",
    dirty = false,
    frameCount = 0,
    clipDuration = 0.0,

    inspectorWidth = 380.0,

    doc = 0,
    animDoc = 0,
    player = 0,
    sheet = 0,

    battleDoc = 0,
    battleId = "",
    canvasWidth = 1920.0,
    canvasHeight = 1080.0,
    enemyZone = 0,
    allyZone = 0,
    animAssets = {},
    combatAllies = [],
    combatEnemies = [],
    combatVfx = 0,
    combatSprites = [],
    playSegments = [],
    playIndex = -1,
    playHold = 0.0,
    playOn = "",
    playUsesVfx = false,
    dummyHp = [1.0, 0.86, 0.72, 0.58, 0.41],
    dummyMp = [0.92, 0.64, 1.0, 0.38, 0.77],
    partyNames = ["主角", "队友", "游侠", "术士", "守卫"],

    // ------------------------------------------------------------ lifecycle
    // Read `content/skills` and publish it as the panel's list. There is no
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
        this.skillList = Rpgc.get(info, "ids", []);
        if (this.skillList.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 里没有技能";
            return;
        }
        this.skillIndex = Rpgc.selectedIndexOf(this.skillList, this.skillId, this.skillIndex);
        if (this.skillIndex < 0) this.skillIndex = 0;
        this.skillId = this.skillList[this.skillIndex];
    },

    // Load whichever row the list has selected. Called by `onChange` (picking a
    // row IS opening it), by `refresh`, and at start-up -- never by a button of
    // its own, which is what "no open-document gesture" means in practice.
    loadSelected = function (editor, widget) {
        if (this.skillList.len() == 0) {
            this.status = "项目文件夹 " + this.folderPath + " 里没有技能";
            return;
        }
        local id = this.resolveSkillId();
        local read = RpgcProject.loadById("skill", id);
        if (!read.ok) {
            this.report(read);
            return;
        }
        this.doc = read.value;
        this.dirty = false;
        this.refresh();
        this.rebuildPreview();
        this.ensureBattle();
        this.status = "载入 skill/" + id;
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
        if (RpgcProject.idsMatch(this.skillList, ids)) return;
        this.skillList = ids;
        if (ids.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 已没有技能";
            return;
        }
        this.skillIndex = Rpgc.selectedIndexOf(ids, this.skillId, this.skillIndex);
        if (this.skillIndex < 0) this.skillIndex = 0;
        if (ids[this.skillIndex] == this.skillId) {
            this.status = "项目文件夹已变化 (" + ids.len() + " 个技能)";
            return;
        }
        this.skillId = ids[this.skillIndex];
        this.loadSelected("skill", "");
        this.status = "所选技能已不在文件夹中，载入 skill/" + this.skillId;
    },

    newSkill = function (editor, widget) {
        local doc = {};
        doc.schema <- "eve.rpgc.skill";
        doc.version <- 1;
        doc.id <- "skill.untitled";
        doc.title <- "新技能";
        doc.targetType <- "enemySingle";
        doc.cooldown <- 3.0;
        doc.castTime <- 0.6;
        doc.costs <- [{ attribute = "mana", amount = 10 }];
        doc.effects <- [];
        doc.tags <- ["attack"];
        doc.damage <- { formula = "a.attack * 1.0", element = "none",
                        critChance = 0.05, hitChance = 0.95 };
        doc.presentation <- {
            segments = [this.blankSegment("caster")],
            vfx = "",
            levels = []
        };
        this.doc = doc;
        this.dirty = true;
        this.refresh();
        this.ensureBattle();
        this.status = "new skill (unsaved)";
    },

    saveSkill = function (editor, widget) {
        if (this.doc == 0) {
            this.status = "nothing to save";
            return;
        }
        this.storePresentation();
        local id = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        local path = RpgcProject.directoryOf("skill") + "/" + id + ".json";
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

    // -------------------------------------------------------------- editing
    // Named `selectClip`, not `setClip`: the engine's `Outline` class binds a
    // native `setClip(float nearZ, float farZ)`, and the EveScript compiler
    // resolves a member call by that name against the native signature. Calling
    // `SkillVM.setClip(...)` from `eve_run_script` / `eve_host_script` — the two
    // AI-facing transports — is rejected with
    // "value is not assignable to the declared type" no matter what is passed.
    // The C++ command path used by the ImGui buttons is unaffected, so this is
    // exactly the kind of defect that only shows up when an agent drives the
    // editor. `lib/rpgc_core.nut:24-27` documents the same class of collision
    // for a slot named `warning`.
    selectClip = function (editor, widget) {
        this.segmentClip = this.clipList().len() > 0 ? this.clipList()[0] : "";
        this.rebuildPreview();
    },

    addSegment = function (editor, widget) {
        this.storePresentation();
        this.doc.presentation.segments.append(this.blankSegment("target"));
        this.dirty = true;
        this.refresh();
        this.status = "added segment " + this.doc.presentation.segments.len();
    },

    removeSegment = function (editor, widget) {
        local segments = Rpgc.get(this.doc, "presentation.segments", []);
        if (segments.len() <= 1) {
            this.status = "a skill needs at least one segment";
            return;
        }
        segments.remove(this.segmentIndex);
        this.doc.presentation.segments <- segments;
        this.segmentIndex = 0;
        this.dirty = true;
        this.refresh();
    },

    moveSegmentUp = function (editor, widget) { this.moveSegment(-1); },
    moveSegmentDown = function (editor, widget) { this.moveSegment(1); },

    moveSegment = function (delta) {
        local segments = Rpgc.get(this.doc, "presentation.segments", []);
        local to = this.segmentIndex + delta;
        if (to < 0 || to >= segments.len()) return;
        local held = segments[this.segmentIndex];
        segments[this.segmentIndex] = segments[to];
        segments[to] = held;
        this.segmentIndex = to;
        this.doc.presentation.segments <- segments;
        this.dirty = true;
        this.refresh();
        this.status = "segment order " + (to + 1) + "/" + segments.len();
    },

    appendLevel = function (editor, widget) {
        this.storePresentation();
        local levels = Rpgc.get(this.doc, "presentation.levels", []);
        local level = 1;
        if (levels.len() > 0) level = Rpgc.asInt(Rpgc.get(levels[levels.len() - 1], "level", 1)) + 1;
        levels.append({ level = level, magnitude = 1.0, vfx = "", segments = [] });
        this.doc.presentation.levels <- levels;
        this.dirty = true;
        this.refresh();
        this.status = "added level row " + level;
    },

    removeLevel = function (editor, widget) {
        local levels = Rpgc.get(this.doc, "presentation.levels", []);
        if (levels.len() == 0) return;
        levels.remove(this.levelIndex);
        this.doc.presentation.levels <- levels;
        this.levelIndex = 0;
        this.dirty = true;
        this.refresh();
    },

    previewClip = function (editor, widget) {
        this.storePresentation();
        this.rebuildPreview();
        this.ensureBattle();
        this.playSegments = Rpgc.get(this.doc, "presentation.segments", []);
        if (this.playSegments.len() == 0) {
            this.status = "this skill has no presentation segments";
            return;
        }
        this.playIndex = 0;
        this.playHold = 0.0;
        this.startPlaySegment(0);
    },

    // -------------------------------------------------------------- helpers

    // The host writes a `slider` as a one-element array and a
    // `dropdown`/`listbox` as the selected string (EditorHost.cpp:876-930), so
    // numeric slots are unwrapped once per frame instead of at every use.
    normalize = function () {
        this.skillIndex = Rpgc.intOf(this.skillIndex);
        this.segmentIndex = Rpgc.intOf(this.segmentIndex);
        this.levelIndex = Rpgc.intOf(this.levelIndex);
        this.cooldown = Rpgc.numberOf(this.cooldown);
        this.castTime = Rpgc.numberOf(this.castTime);
        this.segmentHold = Rpgc.numberOf(this.segmentHold);
        this.levelValue = Rpgc.intOf(this.levelValue);
        this.levelMagnitude = Rpgc.numberOf(this.levelMagnitude);
    },

    // `skillId` holds the dropdown's selected id; `skillIndex` may hold a
    // listbox label or an index. Accept either binding.
    resolveSkillId = function () {
        local index = Rpgc.selectedIndexOf(this.skillList, this.skillId, this.skillIndex);
        if (index < 0) return "";
        this.skillIndex = index;
        return this.skillList[index];
    },

    blankSegment = function (on) {
        local target = Rpgc.get(this.animList, "0", "");
        return { anim = (target == 0 ? "" : "" + target), clip = "", on = on,
                 atEvent = "", hold = 0.0 };
    },

    clipList = function () {
        local out = [];
        if (typeof this.animDoc != "table") return out;
        foreach (clip in Rpgc.get(this.animDoc, "clips", [])) {
            out.append(Rpgc.asString(Rpgc.get(clip, "id", "")));
        }
        return out;
    },

    // Pull the editable fields back into the document before any structural
    // change, so the form never loses what the user typed.
    //
    // Every write here uses `<-`, not `=`. In this EveScript VM `t.newSlot = v`
    // raises "the index 'newSlot' does not exist" — `=` only assigns a slot that
    // already exists, and `<-` is what creates one. Documents are decoded from
    // JSON, so an optional field such as `atEvent` is simply absent, and
    // `segment.atEvent = ...` aborted the whole edit on
    // `content/skills/skill.fireball.json` until this was fixed. Measured in the
    // `eve mcp` host: `local t = {}; t.k = 1;` errors, `t.k <- 1;` works.
    storePresentation = function () {
        if (this.doc == 0) return;
        // Identity fields are editable: renaming a skill renames the file.
        local id = Rpgc.asString(this.skillId);
        if (Rpgc.validId(id)) this.doc.id <- id;
        local title = Rpgc.asString(this.skillTitle);
        if (title != "") this.doc.title <- title;
        this.doc.targetType <- this.targetType;
        this.doc.cooldown <- this.cooldown;
        this.doc.castTime <- this.castTime;
        if (typeof this.doc.damage == "table") {
            this.doc.damage.formula <- this.formula;
            this.doc.damage.element <- this.element;
        }
        if (typeof this.doc.presentation == "table") {
            this.doc.presentation.vfx <- this.vfx;
            local segments = Rpgc.get(this.doc, "presentation.segments", []);
            if (this.segmentIndex >= 0 && this.segmentIndex < segments.len()) {
                local segment = segments[this.segmentIndex];
                segment.anim <- this.segmentAnim;
                segment.clip <- this.segmentClip;
                segment.on <- this.segmentOn;
                segment.atEvent <- this.segmentAtEvent;
                segment.hold <- this.segmentHold;
            }
        }
    },

    refresh = function () {
        if (this.doc == 0) return;
        this.skillId = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        this.skillTitle = Rpgc.asString(Rpgc.get(this.doc, "title", this.skillId));
        this.targetType = Rpgc.asString(Rpgc.get(this.doc, "targetType", "enemySingle"));
        this.cooldown = Rpgc.asNumber(Rpgc.get(this.doc, "cooldown", 0));
        this.castTime = Rpgc.asNumber(Rpgc.get(this.doc, "castTime", 0));
        local damage = Rpgc.get(this.doc, "damage", 0);
        if (typeof damage == "table") {
            this.formula = Rpgc.asString(Rpgc.get(damage, "formula", ""));
            this.element = Rpgc.asString(Rpgc.get(damage, "element", "none"));
        } else {
            this.formula = "";
            this.element = "none";
        }
        this.effectList = Rpgc.get(this.doc, "effects", []);
        this.animList = RpgcProject.idsOf("anim");

        local segments = Rpgc.get(this.doc, "presentation.segments", []);
        local labels = [];
        for (local i = 0; i < segments.len(); i += 1) {
            labels.append((i + 1) + ". " + Rpgc.asString(Rpgc.get(segments[i], "anim", "?"))
                + "/" + Rpgc.asString(Rpgc.get(segments[i], "clip", "?"))
                + " -> " + Rpgc.asString(Rpgc.get(segments[i], "on", "caster")));
        }
        this.segmentList = labels;
        if (this.segmentIndex >= segments.len()) this.segmentIndex = 0;
        if (segments.len() > 0) {
            local segment = segments[this.segmentIndex];
            this.segmentAnim = Rpgc.asString(Rpgc.get(segment, "anim", ""));
            this.segmentClip = Rpgc.asString(Rpgc.get(segment, "clip", ""));
            this.segmentOn = Rpgc.asString(Rpgc.get(segment, "on", "caster"));
            this.segmentAtEvent = Rpgc.asString(Rpgc.get(segment, "atEvent", ""));
            this.segmentHold = Rpgc.asNumber(Rpgc.get(segment, "hold", 0));
        }

        local levels = Rpgc.get(this.doc, "presentation.levels", []);
        local rows = [];
        foreach (row in levels) {
            rows.append("Lv" + Rpgc.asInt(Rpgc.get(row, "level", 0))
                + "  x" + format("%.2f", Rpgc.asNumber(Rpgc.get(row, "magnitude", 1.0)))
                + (Rpgc.asString(Rpgc.get(row, "vfx", "")) == "" ? ""
                   : "  " + Rpgc.asString(Rpgc.get(row, "vfx", ""))));
        }
        this.levelList = rows;
        if (this.levelIndex >= levels.len()) this.levelIndex = 0;
        this.vfx = Rpgc.asString(Rpgc.get(this.doc, "presentation.vfx", ""));
    },

    // Build the live preview from the referenced anim document.
    rebuildPreview = function () {
        this.player = 0;
        this.sheet = 0;
        this.animDoc = 0;
        this.frameCount = 0;
        if (this.segmentAnim == "") return;
        local read = RpgcProject.loadById("anim", this.segmentAnim);
        if (!read.ok) return;
        this.animDoc = read.value;
        local columns = Rpgc.asInt(Rpgc.get(this.animDoc, "columns", 1));
        local rows = Rpgc.asInt(Rpgc.get(this.animDoc, "rows", 0));
        this.frameCount = rows > 0 ? columns * rows : columns;
        try {
            local anim = eve.Animation();
            local sheet = anim.newSpriteSheet();
            local frameW = Rpgc.asInt(Rpgc.get(this.animDoc, "frameWidth", 32));
            local frameH = Rpgc.asInt(Rpgc.get(this.animDoc, "frameHeight", 32));
            sheet.setGrid(columns, rows > 0 ? rows : 1, frameW, frameH,
                          Rpgc.asInt(Rpgc.get(this.animDoc, "margin", 0)),
                          Rpgc.asInt(Rpgc.get(this.animDoc, "spacing", 0)), 0, 0);
            this.sheet = sheet;
            local player = anim.newSpriteAnim();
            player.setSheet(sheet);
            this.player = player;
        } catch (e) {
            this.player = 0;
            this.status = "animation module unavailable in this build: " + e;
        }
    },

    currentClip = function () {
        if (this.player == 0) return 0;
        local clip = this.player.getClip();
        if (clip != null && clip.getName() == this.segmentClip) return clip;
        // The module has no clip lookup, so the clip is rebuilt from the
        // document every time; that is also what the runtime adapter does.
        try {
            local anim = eve.Animation();
            foreach (entry in Rpgc.get(this.animDoc, "clips", [])) {
                if (Rpgc.asString(Rpgc.get(entry, "id", "")) != this.segmentClip) continue;
                local built = anim.newSpriteClip(this.segmentClip);
                local fps = Rpgc.asNumber(Rpgc.get(entry, "fps", 8));
                foreach (frame in Rpgc.get(entry, "frames", [])) {
                    built.addFrame(Rpgc.asInt(frame), 1.0 / fps);
                }
                built.setLoop(Rpgc.get(entry, "loop", true) != false);
                foreach (event in Rpgc.get(entry, "events", [])) {
                    built.addEvent(Rpgc.asInt(Rpgc.get(event, "frame", 0)),
                                   Rpgc.asString(Rpgc.get(event, "name", "")));
                }
                return built;
            }
        } catch (e) {
            this.status = "clip build failed: " + e;
        }
        return 0;
    },

    report = function (result) {
        this.diagnostics = Rpgc.summary(result);
        if (!result.ok) {
            local first = Rpgc.firstError(result);
            if (first != null) this.status = "[" + first.path + "] " + first.message;
        }
    },

    status_line = function () {
        return this.skillId + " | " + this.targetType
            + " | segments " + this.segmentList.len()
            + " | battlefield " + this.battleId
            + (this.playIndex >= 0 ? " | playing " + (this.playIndex + 1) : "")
            + (this.dirty ? " | DIRTY" : "");
    },

    // --------------------------------------------------------------- combat
    // The inspector is ImGui-only. Combat occupies the rest of the window,
    // letterboxing the authored battle canvas so slots stay in design space.

    ensureBattle = function () {
        if (typeof this.battleDoc == "table") {
            this.ensureCombatActors();
            return;
        }
        local ids = RpgcProject.idsOf("battle");
        if (ids.len() == 0) {
            this.status = "no battle scene in content/battles";
            return;
        }
        local id = "battle.open-field";
        local found = false;
        foreach (candidate in ids) {
            if (candidate == id) found = true;
        }
        if (!found) id = ids[0];
        local read = RpgcProject.loadById("battle", id);
        if (!read.ok) {
            this.report(read);
            return;
        }
        this.battleDoc = read.value;
        this.battleId = Rpgc.asString(Rpgc.get(this.battleDoc, "id", id));
        this.canvasWidth = Rpgc.asNumber(Rpgc.get(this.battleDoc, "canvas.width", 1920));
        this.canvasHeight = Rpgc.asNumber(Rpgc.get(this.battleDoc, "canvas.height", 1080));
        this.enemyZone = Rpgc.get(this.battleDoc, "zones.enemy", 0);
        this.allyZone = Rpgc.get(this.battleDoc, "zones.ally", 0);
        this.ensureCombatActors();
    },

    idleClipOf = function (doc) {
        foreach (clip in Rpgc.get(doc, "clips", [])) {
            local id = Rpgc.asString(Rpgc.get(clip, "id", ""));
            if (id.find("idle") != null) return id;
        }
        local clips = Rpgc.get(doc, "clips", []);
        if (clips.len() == 0) return "";
        return Rpgc.asString(Rpgc.get(clips[0], "id", ""));
    },

    loadAnimAsset = function (animId) {
        if (animId == "") return 0;
        if (this.animAssets.rawin(animId)) return this.animAssets.rawget(animId);
        local read = RpgcProject.loadById("anim", animId);
        if (!read.ok) return 0;
        local asset = {};
        asset.id <- animId;
        asset.doc <- read.value;
        asset.texture <- 0;
        asset.sheet <- 0;
        asset.path <- RpgcProject.pathOf("anim", animId);
        try {
            local gfx = eve.Graphics();
            local imageName = Rpgc.asString(Rpgc.get(asset.doc, "image", ""));
            if (imageName != "") {
                asset.texture = gfx.newTextureFromFile(Rpgc.resolveFrom(asset.path, imageName));
            }
            local anim = eve.Animation();
            local sheet = anim.newSpriteSheet();
            local columns = Rpgc.asInt(Rpgc.get(asset.doc, "columns", 1));
            local rows = Rpgc.asInt(Rpgc.get(asset.doc, "rows", 1));
            if (rows < 1) rows = 1;
            sheet.setGrid(columns, rows,
                          Rpgc.asInt(Rpgc.get(asset.doc, "frameWidth", 32)),
                          Rpgc.asInt(Rpgc.get(asset.doc, "frameHeight", 32)),
                          Rpgc.asInt(Rpgc.get(asset.doc, "margin", 0)),
                          Rpgc.asInt(Rpgc.get(asset.doc, "spacing", 0)), 0, 0);
            if (asset.texture != 0) sheet.setTexture(asset.texture);
            asset.sheet = sheet;
        } catch (e) {
            this.status = "anim '" + animId + "' failed: " + e;
        }
        this.animAssets.rawset(animId, asset);
        return asset;
    },

    makeCombatActor = function (animId, side) {
        local asset = this.loadAnimAsset(animId);
        local actor = {};
        actor.animId <- animId;
        actor.side <- side;
        actor.idle <- asset == 0 ? "" : this.idleClipOf(asset.doc);
        actor.doc <- asset == 0 ? 0 : asset.doc;
        actor.texture <- asset == 0 ? 0 : asset.texture;
        actor.sheet <- asset == 0 ? 0 : asset.sheet;
        actor.sprite <- 0;
        actor.quad <- 0;
        actor.player <- 0;
        try {
            local gfx = eve.Graphics();
            local anim = eve.Animation();
            actor.sprite = gfx.newSprite2D();
            actor.sprite.setReceiveLight(false);
            actor.sprite.setAnchor(0.5, 1.0);
            actor.sprite.setVisible(false);
            actor.quad = gfx.newQuad(0, 0, 1, 1);
            if (actor.texture != 0) actor.sprite.setTexture(actor.texture);
            actor.sprite.setQuad(actor.quad);
            local player = anim.newSpriteAnim();
            if (actor.sheet != 0) player.setSheet(actor.sheet);
            player.bindQuad(actor.quad);
            player.bindSprite(actor.sprite);
            actor.player = player;
            this.combatSprites.append(actor.sprite);
        } catch (e) {
            this.status = "combat actor '" + animId + "' failed: " + e;
        }
        this.playIdle(actor);
        return actor;
    },

    playIdle = function (actor) {
        if (actor == 0 || actor.player == 0 || actor.idle == "") return;
        local clip = this.buildClip(actor.animId, actor.idle);
        if (clip == 0) return;
        try { actor.player.play(clip); } catch (e) {}
    },

    ensureCombatActors = function () {
        local allySlots = Rpgc.get(this.battleDoc, "allySlots", []);
        local enemySlots = Rpgc.get(this.battleDoc, "enemySlots", []);
        local allies = allySlots.len();
        local enemies = enemySlots.len();
        if (this.combatAllies.len() == allies && this.combatEnemies.len() == enemies
            && this.combatVfx != 0) return;
        foreach (sprite in this.combatSprites) {
            try { sprite.setVisible(false); } catch (e) {}
        }
        this.combatAllies = [];
        this.combatEnemies = [];
        this.combatSprites = [];
        for (local i = 0; i < allies; i += 1) {
            this.combatAllies.append(this.makeCombatActor("hero", "ally"));
        }
        for (local i = 0; i < enemies; i += 1) {
            this.combatEnemies.append(this.makeCombatActor("enemy-skeleton", "enemy"));
        }
        this.combatVfx = this.makeCombatActor("fireball", "vfx");
        if (this.combatVfx != 0 && this.combatVfx.sprite != 0) {
            try { this.combatVfx.sprite.setVisible(false); } catch (e) {}
        }
    },

    buildClip = function (animId, clipId) {
        if (animId == "" || clipId == "") return 0;
        local asset = this.loadAnimAsset(animId);
        if (asset == 0) return 0;
        try {
            local anim = eve.Animation();
            foreach (entry in Rpgc.get(asset.doc, "clips", [])) {
                if (Rpgc.asString(Rpgc.get(entry, "id", "")) != clipId) continue;
                local built = anim.newSpriteClip(clipId);
                local fps = Rpgc.asNumber(Rpgc.get(entry, "fps", 8));
                foreach (frame in Rpgc.get(entry, "frames", [])) {
                    built.addFrame(Rpgc.asInt(frame), 1.0 / fps);
                }
                built.setLoop(Rpgc.get(entry, "loop", true) != false);
                foreach (event in Rpgc.get(entry, "events", [])) {
                    built.addEvent(Rpgc.asInt(Rpgc.get(event, "frame", 0)),
                                   Rpgc.asString(Rpgc.get(event, "name", "")));
                }
                return built;
            }
        } catch (e) {
            this.status = "clip build failed: " + e;
        }
        return 0;
    },

    slotOf = function (field, index) {
        local slots = Rpgc.get(this.battleDoc, field, []);
        if (index < 0 || index >= slots.len()) return 0;
        return slots[index];
    },

    actorForOn = function (on, animId) {
        local host = 0;
        if (on == "target" || on == "impact") {
            if (this.combatEnemies.len() > 0) host = this.combatEnemies[0];
        } else {
            if (this.combatAllies.len() > 0) host = this.combatAllies[0];
        }
        if (host != 0 && host.animId == animId) return host;
        if (this.combatVfx != 0 && this.combatVfx.animId != animId
            && this.combatVfx.sprite != 0) {
            try { this.combatVfx.sprite.setVisible(false); } catch (e) {}
        }
        if (this.combatVfx == 0 || this.combatVfx.animId != animId) {
            this.combatVfx = this.makeCombatActor(animId, "vfx");
        }
        this.playOn = on;
        return this.combatVfx;
    },

    startPlaySegment = function (index) {
        if (index < 0 || index >= this.playSegments.len()) {
            this.finishPlay();
            return;
        }
        this.playIndex = index;
        local segment = this.playSegments[index];
        local animId = Rpgc.asString(Rpgc.get(segment, "anim", ""));
        local clipId = Rpgc.asString(Rpgc.get(segment, "clip", ""));
        local on = Rpgc.asString(Rpgc.get(segment, "on", "caster"));
        this.playOn = on;
        this.playHold = Rpgc.asNumber(Rpgc.get(segment, "hold", 0));
        local clip = this.buildClip(animId, clipId);
        if (clip == 0) {
            this.status = "clip '" + clipId + "' not found in anim/" + animId;
            this.startPlaySegment(index + 1);
            return;
        }
        local looping = false;
        try { looping = clip.getLoop(); } catch (e) {}
        if (looping && this.playHold <= 0.0) this.playHold = 0.4;
        try { this.clipDuration = clip.getDuration(); } catch (e) { this.clipDuration = 0.0; }
        local actor = this.actorForOn(on, animId);
        if (actor == 0 || actor.player == 0) {
            this.status = "no combat actor for " + on;
            this.startPlaySegment(index + 1);
            return;
        }
        this.player = actor.player;
        this.playUsesVfx = (actor.side == "vfx");
        if (!this.playUsesVfx && this.combatVfx != 0 && this.combatVfx.sprite != 0) {
            try { this.combatVfx.sprite.setVisible(false); } catch (e) {}
        }
        if (actor.sprite != 0) {
            try { actor.sprite.setVisible(true); } catch (e) {}
        }
        try { actor.player.play(clip); } catch (e) {
            this.status = "play failed: " + e;
            return;
        }
        this.status = "play " + (index + 1) + "/" + this.playSegments.len()
            + " " + animId + "/" + clipId + " on " + on;
    },

    finishPlay = function () {
        this.playIndex = -1;
        this.playHold = 0.0;
        this.playUsesVfx = false;
        this.player = 0;
        foreach (actor in this.combatAllies) this.playIdle(actor);
        foreach (actor in this.combatEnemies) this.playIdle(actor);
        if (this.combatVfx != 0 && this.combatVfx.sprite != 0) {
            try { this.combatVfx.sprite.setVisible(false); } catch (e) {}
        }
        this.status = "ready " + this.skillId;
    },

    pumpActors = function (dt) {
        local lists = [this.combatAllies, this.combatEnemies];
        foreach (group in lists) {
            foreach (actor in group) {
                if (actor.player == 0) continue;
                try { actor.player.update(dt); } catch (e) {}
            }
        }
        if (this.combatVfx != 0 && this.combatVfx.player != 0) {
            try { this.combatVfx.player.update(dt); } catch (e) {}
        }
        if (this.playIndex < 0) return;
        local looping = false;
        local done = false;
        if (this.player != 0) {
            try { this.player.consumeEvent(); } catch (e) {}
            try { looping = this.player.getLoop(); } catch (e) {}
            try { done = this.player.consumeCompleted(); } catch (e) {}
        }
        if (looping) {
            this.playHold = this.playHold - Rpgc.numberOf(dt);
            if (this.playHold <= 0.0) this.startPlaySegment(this.playIndex + 1);
            return;
        }
        if (done) {
            this.playHold = this.playHold - Rpgc.numberOf(dt);
            if (this.playHold <= 0.0) this.startPlaySegment(this.playIndex + 1);
        }
    },

    windowSize = function () {
        local out = {};
        out.width <- 1280.0;
        out.height <- 800.0;
        try {
            local gfx = eve.Graphics();
            out.width = gfx.getWidth() * 1.0;
            out.height = gfx.getHeight() * 1.0;
        } catch (e) {}
        if (out.width < 64.0) out.width = 64.0;
        if (out.height < 64.0) out.height = 64.0;
        return out;
    },

    boardRect = function () {
        local win = this.windowSize();
        local out = {};
        out.x <- 0.0;
        out.y <- 0.0;
        out.width <- win.width - this.inspectorWidth;
        out.height <- win.height;
        if (out.width < 64.0) out.width = win.width * 0.65;
        if (out.height < 64.0) out.height = win.height;
        return out;
    },

    fieldLayout = function () {
        local rect = this.boardRect();
        local layout = {};
        layout.rect <- rect;
        layout.scale <- 1.0;
        layout.left <- rect.x;
        layout.top <- rect.y;
        layout.fieldW <- rect.width;
        layout.fieldH <- rect.height;
        if (this.canvasWidth <= 0.0 || this.canvasHeight <= 0.0) return layout;
        local scale = rect.width / this.canvasWidth;
        local vertical = rect.height / this.canvasHeight;
        if (vertical < scale) scale = vertical;
        layout.scale = scale;
        layout.fieldW = this.canvasWidth * scale;
        layout.fieldH = this.canvasHeight * scale;
        layout.left = rect.x + (rect.width - layout.fieldW) * 0.5;
        layout.top = rect.y + (rect.height - layout.fieldH) * 0.5;
        return layout;
    },

    outline = function (gfx, x, y, w, h, r, g, b, a) {
        if (w <= 0.0 || h <= 0.0) return;
        gfx.drawSolidRect(x, y, w, 2.0, r, g, b, a);
        gfx.drawSolidRect(x, y + h - 2.0, w, 2.0, r, g, b, a);
        gfx.drawSolidRect(x, y, 2.0, h, r, g, b, a);
        gfx.drawSolidRect(x + w - 2.0, y, 2.0, h, r, g, b, a);
    },

    placeActorAtSlot = function (actor, field, index, layout, scaleMul) {
        if (actor == 0 || actor.sprite == 0) return;
        local slot = this.slotOf(field, index);
        if (slot == 0) {
            try { actor.sprite.setVisible(false); } catch (e) {}
            return;
        }
        local sx = layout.left + Rpgc.asNumber(Rpgc.get(slot, "x", 0)) * layout.scale;
        local sy = layout.top + Rpgc.asNumber(Rpgc.get(slot, "y", 0)) * layout.scale;
        local frameW = 32.0;
        local frameH = 48.0;
        if (typeof actor.doc == "table") {
            frameW = Rpgc.asNumber(Rpgc.get(actor.doc, "frameWidth", frameW));
            frameH = Rpgc.asNumber(Rpgc.get(actor.doc, "frameHeight", frameH));
        }
        local h = frameH * 2.4 * layout.scale * scaleMul;
        local w = frameW * 2.4 * layout.scale * scaleMul;
        if (h < 24.0) h = 24.0;
        try {
            actor.sprite.setPosition(sx, sy);
            actor.sprite.setSize(w, h);
            actor.sprite.setVisible(true);
        } catch (e) {}
    },

    placeVfx = function (layout) {
        if (this.combatVfx == 0 || this.combatVfx.sprite == 0) return;
        if (this.playIndex < 0 || !this.playUsesVfx) {
            try { this.combatVfx.sprite.setVisible(false); } catch (e) {}
            return;
        }
        local field = "allySlots";
        local index = 0;
        if (this.playOn == "target" || this.playOn == "impact") field = "enemySlots";
        if (this.playOn == "screen") {
            local sx = layout.left + layout.fieldW * 0.5;
            local sy = layout.top + layout.fieldH * 0.42;
            try {
                this.combatVfx.sprite.setPosition(sx, sy);
                this.combatVfx.sprite.setSize(96.0 * layout.scale, 96.0 * layout.scale);
                this.combatVfx.sprite.setVisible(true);
            } catch (e) {}
            return;
        }
        this.placeActorAtSlot(this.combatVfx, field, index, layout, 1.35);
    },

    drawMemberHud = function (gfx, x, y, width, portraitH, bars, hp, mp, name, tone) {
        gfx.drawSolidRect(x, y, width, portraitH, 0.10, 0.11, 0.15, 1.0);
        local faceX = x + width * 0.10;
        local faceY = y + portraitH * 0.10;
        local faceW = width * 0.80;
        local faceH = portraitH * 0.58;
        gfx.drawSolidRect(faceX, faceY, faceW, faceH,
            tone[0], tone[1], tone[2], 1.0);
        gfx.drawSolidRect(faceX, faceY + faceH * 0.52, faceW, faceH * 0.48,
            tone[0] * 0.55, tone[1] * 0.55, tone[2] * 0.55, 1.0);
        this.outline(gfx, x, y, width, portraitH, 0.55, 0.58, 0.68, 0.9);
        try {
            gfx.print(name, x + 4.0, y + 2.0, 0.94, 0.95, 0.98, 1.0, 0.75);
        } catch (e) {}

        local barsTop = y + portraitH;
        local ratios = [hp, mp];
        for (local b = 0; b < bars.len(); b += 1) {
            local bar = bars[b];
            local barH = Rpgc.asNumber(Rpgc.get(bar, "height", 10));
            if (barH < 2.0) barH = 2.0;
            local barY = barsTop + Rpgc.asNumber(Rpgc.get(bar, "offsetY", 0));
            local colour = Rpgc.get(bar, "colour", [0.4, 0.7, 0.4]);
            local r = Rpgc.asNumber(Rpgc.get(colour, "0", 0.4));
            local g = Rpgc.asNumber(Rpgc.get(colour, "1", 0.7));
            local bl = Rpgc.asNumber(Rpgc.get(colour, "2", 0.4));
            local ratio = 0.7;
            if (b < ratios.len()) ratio = ratios[b];
            gfx.drawSolidRect(x, barY, width, barH, 0.12, 0.13, 0.17, 0.95);
            gfx.drawSolidRect(x, barY, width * ratio, barH, r, g, bl, 0.95);
            this.outline(gfx, x, barY, width, barH, 0.02, 0.02, 0.03, 0.9);
        }
    },

    drawHud = function (gfx, layout) {
        local uiDoc = Rpgc.get(this.battleDoc, "ui", 0);
        local party = typeof uiDoc == "table" ? Rpgc.get(uiDoc, "party", 0) : 0;
        local count = this.combatAllies.len();
        if (count < 1) count = 1;

        local scale = layout.scale;
        local cellW = 104.0 * scale;
        local gap = 8.0 * scale;
        local portraitH = 130.0 * scale;
        local px = layout.left + layout.fieldW * 0.52;
        local py = layout.top + layout.fieldH - 210.0 * scale;
        local bars = [
            { id = "hp", offsetY = 8.0 * scale, height = 18.0 * scale, colour = [0.30, 0.72, 0.36] },
            { id = "mana", offsetY = 32.0 * scale, height = 18.0 * scale, colour = [0.25, 0.48, 0.85] }
        ];
        if (typeof party == "table") {
            px = layout.left + Rpgc.asNumber(Rpgc.get(party, "x", 0)) * scale;
            py = layout.top + Rpgc.asNumber(Rpgc.get(party, "y", 0)) * scale;
            cellW = Rpgc.asNumber(Rpgc.get(party, "slotWidth", 104)) * scale;
            gap = Rpgc.asNumber(Rpgc.get(party, "slotGap", 8)) * scale;
            portraitH = Rpgc.asNumber(Rpgc.get(party, "portraitHeight", 130)) * scale;
            local docBars = Rpgc.get(party, "bars", []);
            if (docBars.len() > 0) {
                bars = [];
                foreach (bar in docBars) {
                    local copy = {};
                    copy.id <- Rpgc.asString(Rpgc.get(bar, "id", ""));
                    copy.offsetY <- Rpgc.asNumber(Rpgc.get(bar, "offsetY", 0)) * scale;
                    copy.height <- Rpgc.asNumber(Rpgc.get(bar, "height", 10)) * scale;
                    copy.colour <- Rpgc.get(bar, "colour", [0.4, 0.7, 0.4]);
                    bars.append(copy);
                }
            }
            local shown = Rpgc.asInt(Rpgc.get(party, "slots", count));
            if (shown < count) count = shown;
        }

        local tones = [
            [0.72, 0.42, 0.38], [0.38, 0.52, 0.78], [0.42, 0.62, 0.40],
            [0.62, 0.42, 0.72], [0.72, 0.58, 0.32]
        ];
        for (local i = 0; i < count; i += 1) {
            local name = "队友" + (i + 1);
            if (i < this.partyNames.len()) name = this.partyNames[i];
            local hp = 0.7;
            local mp = 0.7;
            if (i < this.dummyHp.len()) hp = this.dummyHp[i];
            if (i < this.dummyMp.len()) mp = this.dummyMp[i];
            local tone = tones[i % tones.len()];
            this.drawMemberHud(gfx, px + i * (cellW + gap), py, cellW, portraitH,
                bars, hp, mp, name, tone);
        }

        local ring = typeof uiDoc == "table" ? Rpgc.get(uiDoc, "commandRing", 0) : 0;
        if (typeof ring != "table") return;
        local cx = layout.left + Rpgc.asNumber(Rpgc.get(ring, "cx", 0)) * scale;
        local cy = layout.top + Rpgc.asNumber(Rpgc.get(ring, "cy", 0)) * scale;
        local radius = Rpgc.asNumber(Rpgc.get(ring, "radius", 0)) * scale;
        this.outline(gfx, cx - radius, cy - radius, radius * 2.0, radius * 2.0,
            0.78, 0.66, 0.34, 0.55);
        foreach (button in Rpgc.get(ring, "buttons", [])) {
            local bx = layout.left + Rpgc.asNumber(Rpgc.get(button, "x", 0)) * scale;
            local by = layout.top + Rpgc.asNumber(Rpgc.get(button, "y", 0)) * scale;
            local br = Rpgc.asNumber(Rpgc.get(button, "radius", 0)) * scale;
            gfx.drawSolidRect(bx - br, by - br, br * 2.0, br * 2.0,
                0.30, 0.20, 0.14, 0.95);
            this.outline(gfx, bx - br, by - br, br * 2.0, br * 2.0,
                0.86, 0.72, 0.38, 1.0);
            try {
                gfx.print(Rpgc.asString(Rpgc.get(button, "label", "")),
                    bx - br, by + br + 2.0, 1.0, 0.96, 0.78, 1.0, 0.8);
            } catch (e) {}
        }
    },

    // --------------------------------------------------------------- drawer
    update = function (dt) {
        this.normalize();
        this.pollFolder(dt);
        this.ensureBattle();
        this.pumpActors(dt);
    },

    draw = function () {
        local gfx = eve.Graphics();
        local win = this.windowSize();
        gfx.drawSolidRect(0.0, 0.0, win.width, win.height, 0.06, 0.07, 0.10, 1.0);
        this.ensureBattle();
        local layout = this.fieldLayout();
        local rect = layout.rect;
        if (rect.width <= 1.0) return;

        gfx.drawSolidRect(layout.left, layout.top, layout.fieldW, layout.fieldH, 0.08, 0.09, 0.12, 1.0);
        gfx.drawSolidRect(layout.left, layout.top, layout.fieldW * 0.5, layout.fieldH * 0.5,
                          0.14, 0.10, 0.10, 1.0);
        gfx.drawSolidRect(layout.left + layout.fieldW * 0.5, layout.top + layout.fieldH * 0.5,
                          layout.fieldW * 0.5, layout.fieldH * 0.5, 0.10, 0.12, 0.18, 1.0);
        gfx.drawSolidRect(layout.left + layout.fieldW * 0.5 - 1.0, layout.top, 2.0, layout.fieldH,
                          0.32, 0.34, 0.40, 0.8);
        gfx.drawSolidRect(layout.left, layout.top + layout.fieldH * 0.5 - 1.0, layout.fieldW, 2.0,
                          0.32, 0.34, 0.40, 0.8);

        if (typeof this.enemyZone == "table") {
            this.outline(gfx,
                layout.left + Rpgc.asNumber(Rpgc.get(this.enemyZone, "x", 0)) * layout.scale,
                layout.top + Rpgc.asNumber(Rpgc.get(this.enemyZone, "y", 0)) * layout.scale,
                Rpgc.asNumber(Rpgc.get(this.enemyZone, "width", 0)) * layout.scale,
                Rpgc.asNumber(Rpgc.get(this.enemyZone, "height", 0)) * layout.scale,
                0.92, 0.42, 0.36, 0.55);
        }
        if (typeof this.allyZone == "table") {
            this.outline(gfx,
                layout.left + Rpgc.asNumber(Rpgc.get(this.allyZone, "x", 0)) * layout.scale,
                layout.top + Rpgc.asNumber(Rpgc.get(this.allyZone, "y", 0)) * layout.scale,
                Rpgc.asNumber(Rpgc.get(this.allyZone, "width", 0)) * layout.scale,
                Rpgc.asNumber(Rpgc.get(this.allyZone, "height", 0)) * layout.scale,
                0.40, 0.70, 0.95, 0.55);
        }

        for (local i = 0; i < this.combatEnemies.len(); i += 1) {
            this.placeActorAtSlot(this.combatEnemies[i], "enemySlots", i, layout, 1.0);
        }
        for (local i = 0; i < this.combatAllies.len(); i += 1) {
            this.placeActorAtSlot(this.combatAllies[i], "allySlots", i, layout, 1.0);
        }
        this.placeVfx(layout);
        try { gfx.renderSprites(); } catch (e) {}
        this.drawHud(gfx, layout);
    },


    onChange = function (widget, value) {
        if (widget == "skill") {
            // Selecting a row loads it immediately: the folder listing is the
            // document list, so there is no second "open" gesture to wait for.
            this.skillId = Rpgc.asString(value);
            this.normalize();
            this.loadSelected("skill", "");
            return;
        }
        if (widget == "segment") this.segmentIndex = Rpgc.intOf(value);
        if (widget == "level") this.levelIndex = Rpgc.intOf(value);
        if (widget == "segmentAnim") {
            this.segmentAnim = Rpgc.asString(value);
            this.segmentClip = "";
            this.rebuildPreview();
        }
        if (widget == "segmentClip") {
            this.segmentClip = Rpgc.asString(value);
            this.rebuildPreview();
        }
        this.normalize();
        this.storePresentation();
    }
};

RpgcHost.register("skill", {
    update = function (dt) { SkillVM.update(dt); },
    draw = function () { SkillVM.draw(); },
    status = function () { return SkillVM.status_line(); }
});

// Start-up: scan the project folder and show its first skill. No argument, no
// document chooser -- the editor opens onto the game folder's data.
try {
    SkillVM.loadFolder();
    SkillVM.loadSelected("skill", "");
} catch (e) {
    SkillVM.status = "" + e;
    if ("log" in eve) eve.log("error", "skill: initial folder load: " + e);
}
