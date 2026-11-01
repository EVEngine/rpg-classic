// EveScript module check for the rpg-classic toolchain.
//
//   cd .  # repository root
//   <eve> run --no-window -r tools/modules_check.nut
//
// It exercises the one thing a pure refactor can silently break: that every
// `lib/` module instantiates through `import`, that nothing leaks onto the VM
// root, and that the three editor ViewModels still publish themselves where
// `EditorHost::registerVM` looks for them. Exit status is not meaningful for
// `eve run`; grep for `[modules] FAIL`.

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

local failures = 0;

function check(name, condition, detail = "") {
    if (condition) {
        print("[modules] ok   " + name + (detail == "" ? "" : "  " + detail) + "\n");
    } else {
        failures += 1;
        print("[modules] FAIL " + name + (detail == "" ? "" : "  " + detail) + "\n");
    }
    return condition;
}

// --- module boundary -------------------------------------------------------

check("workflow.moduleCount", RpgcWorkflow.moduleCount() == 22,
    "got " + RpgcWorkflow.moduleCount());
foreach (name in ["Rpgc", "RpgcJson", "RpgcStore", "RpgcProject", "RpgcHost",
                  "RpgcValidate", "RpgcWorkflow"]) {
    check("root." + name + " is private", !(name in getroottable()));
}

// --- pure layers -----------------------------------------------------------

local parsed = RpgcJson.parse("{\"a\":[1,2,3],\"b\":\"x\"}");
check("json.parse", parsed.ok);
check("json.encodeCompact", RpgcJson.encodeCompact(parsed.value) == "{\"a\":[1,2,3],\"b\":\"x\"}");
check("json rejects duplicate key", !RpgcJson.parse("{\"a\":1,\"a\":2}").ok);
check("json rejects trailing comment", !RpgcJson.parse("{\"a\":1} //x").ok);
check("core.get dotted path", Rpgc.get(parsed.value, "a.1", -1) == 2);

local cfg = RpgcIso.configFromDocument({ tilewidth = 32, tileheight = 32, renderSpacing = [2, 2] });
check("iso.pickIsConsistent", RpgcIso.pickIsConsistent(cfg).ok);

local enemyBank = { x = 80.0, y = 60.0, width = 760.0, height = 420.0 };
local allyBank = { x = 1120.0, y = 620.0, width = 720.0, height = 400.0 };
local isoInside = true;
for (local i = 0; i < 8; i += 1) {
    local p = RpgcIso.battleIsoSlot(enemyBank, i, 4, 2);
    if (!RpgcSystems.insideRect(enemyBank, p.x, p.y)) isoInside = false;
}
for (local i = 0; i < 5; i += 1) {
    local p = RpgcIso.battleIsoSlot(allyBank, i, 5, 1);
    if (!RpgcSystems.insideRect(allyBank, p.x, p.y)) isoInside = false;
}
check("iso.battle-formation-in-zone", isoInside);
local allyFirst = RpgcIso.battleIsoSlot(allyBank, 0, 5, 1);
local allyLast = RpgcIso.battleIsoSlot(allyBank, 4, 5, 1);
check("iso.battle-line-bottom-left-to-top-right",
    allyFirst.x < allyLast.x && allyFirst.y > allyLast.y,
    "first=(" + allyFirst.x + "," + allyFirst.y + ") last=("
        + allyLast.x + "," + allyLast.y + ")");
local enemyFront = RpgcIso.battleIsoSlot(enemyBank, 0, 4, 2);
local enemyBack = RpgcIso.battleIsoSlot(enemyBank, 4, 4, 2);
check("iso.battle-enemy-two-ranks",
    enemyFront.x != enemyBack.x || enemyFront.y != enemyBack.y,
    "rank0=(" + enemyFront.x + "," + enemyFront.y
        + ") rank1=(" + enemyBack.x + "," + enemyBack.y + ")");

// --- store / project / gate ------------------------------------------------

check("store.backend", RpgcStore.backend() != "", RpgcStore.backend());
check("project.kinds", RpgcProject.kinds().len() > 0,
    "got " + RpgcProject.kinds().len());

// The gate itself is content-dependent: a FAIL here means the content tree is
// broken, not that the modules are. Report it, do not count it as a module bug.
local report = RpgcValidate.validateProject();
print("[modules] gate " + (report.ok ? "PASS" : "FAIL") + ": " + Rpgc.summary(report) + "\n");
foreach (d in report.diagnostics) {
    if (d.severity == "error") print("[modules]   error " + d.path + ": " + d.message + "\n");
}

// --- document modules ------------------------------------------------------

local atlas = RpgcStore.readDocument("content/tilesets/sbs-walls.json");
check("atlas.reads", atlas.ok);
if (atlas.ok) {
    check("tilemap.tilesOf replays runs", RpgcTilemap.tilesOf(atlas.value).len() > 0,
        "tiles=" + RpgcTilemap.tilesOf(atlas.value).len());
    check("tilemap.gidRange", RpgcTilemap.gidRange(atlas.value).last > 0);
}
check("skill.kinds", RpgcSkill.kinds.len() == 3);
check("event.maxDepth", RpgcEvent.maxDepth == 2);
check("host.reportJson", RpgcHost.reportJson().len() > 2);
check("app.parentDir", RpgcApp.parentDir("/a/b/c/") == "/a/b");

// The bestiary kinds must stay wired end to end: workflow.json -> schema id ->
// the module that owns layers 2 and 3. A kind whose `module` name drifts is
// reported by `validate.unknown-module`, but only as a content failure, so the
// wiring itself is asserted here where it reads as a module bug.
check("project.kind.enemy", RpgcProject.schemaOf("enemy") == "eve.rpgc.enemy",
    "got '" + RpgcProject.schemaOf("enemy") + "'");
check("project.kind.encounter", RpgcProject.schemaOf("encounter") == "eve.rpgc.encounter",
    "got '" + RpgcProject.schemaOf("encounter") + "'");
check("validate.module.enemy", RpgcValidate.moduleFor("enemy") == RpgcSystems);
check("validate.module.encounter", RpgcValidate.moduleFor("encounter") == RpgcSystems);
check("project.kind.party", RpgcProject.schemaOf("party") == "eve.rpgc.party",
    "got '" + RpgcProject.schemaOf("party") + "'");
check("validate.module.party", RpgcValidate.moduleFor("party") == RpgcSystems);
check("systems.kinds", RpgcSystems.kinds.len() == 10, "got " + RpgcSystems.kinds.len());

// --- editor ViewModels -----------------------------------------------------
// EditorHost::registerVM compiles these and then looks the name up in the VM
// root, and a module's `::name` never reaches that root — so this is the check
// that the ViewModels are published where the host actually looks.

import * as tilemapVm from "game:/editors/tilemap.vm.nut"
import * as skillVm from "game:/editors/skill.vm.nut"
import * as eventVm from "game:/editors/event.vm.nut"
import * as battleVm from "game:/editors/battle.vm.nut"
import * as itemVm from "game:/editors/item.vm.nut"

foreach (name in ["TilemapVM", "SkillVM", "EventVM", "BattleVM", "ItemVM"]) {
    if (!check("root." + name + " published", name in getroottable())) continue;
    local slots = 0;
    foreach (k, v in getroottable()[name]) slots += 1;
    check(name + " is populated", slots > 0, "slots=" + slots);
}
print("[modules] tilemap status: " + TilemapVM.status + "\n");
print("[modules] battle  status: " + BattleVM.status_line() + "\n");

// The View JSON is the authority on what a panel can dispatch, and a `command`
// or a `bind` that names a slot the ViewModel does not have is a dead button or
// a field that never updates -- invisible until someone clicks it. `rpgc.py
// selftest` covers the commands against a live host; this covers commands AND
// binds statically, for every drawer, including the ones no app opens.

function viewNodes(nodes, out) {
    foreach (node in nodes) {
        if (typeof node != "table") continue;
        local command = Rpgc.asString(Rpgc.get(node, "command", ""));
        if (command != "") out.commands.append(command);
        if (Rpgc.asString(Rpgc.get(node, "type", "")) == "listbox") {
            local box = {};
            box.id <- Rpgc.asString(Rpgc.get(node, "id", ""));
            box.options <- Rpgc.asString(Rpgc.get(node, "bind:options", ""));
            box.change <- Rpgc.asString(Rpgc.get(node, "onChange", ""));
            out.listboxes.append(box);
        }
        foreach (name in node.keys()) {
            local key = "" + name;
            if (key.len() < 4 || key.slice(0, 4) != "bind") continue;
            local target = Rpgc.asString(node.rawget(name));
            if (target.len() > 3 && target.slice(0, 3) == "vm.") {
                out.binds.append(target.slice(3, target.len()));
            }
        }
        local kids = Rpgc.get(node, "children", []);
        if (kids.len() > 0) viewNodes(kids, out);
    }
}

foreach (editorId in ["tilemap", "skill", "event", "battle", "item"]) {
    local view = RpgcStore.readText("editors/" + editorId + ".editor.json");
    if (!check("view." + editorId + " reads", view.ok)) continue;
    local parsed = RpgcJson.parse(view.value);
    if (!check("view." + editorId + " parses", parsed.ok)) continue;
    local vmName = Rpgc.asString(Rpgc.get(parsed.value, "vm", ""));
    if (!check("view." + editorId + " vm published", vmName in getroottable(),
               "vm=" + vmName)) continue;
    local vm = getroottable()[vmName];
    local out = { commands = [], binds = [], listboxes = [] };
    viewNodes(Rpgc.get(parsed.value, "children", []), out);
    local missing = [];
    foreach (command in out.commands) {
        if (!(command in vm) || typeof vm.rawget(command) != "function") {
            missing.append("command:" + command);
        }
    }
    foreach (bind in out.binds) {
        if (!(bind in vm)) missing.append("bind:" + bind);
    }
    check("view." + editorId + " resolves", missing.len() == 0,
        "missing " + Rpgc.joinList(missing, ", ") + " on " + vmName);
    print("[modules] view " + editorId + ": " + out.commands.len() + " command(s), "
        + out.binds.len() + " bind(s) checked against " + vmName + "\n");
}

// --- folder-bound editors --------------------------------------------------
//
// The four editors open onto a project FOLDER, not onto a document picked in an
// "open" gesture: workflow.json names exactly one directory per kind, that
// directory is the list, and picking a row loads it (`onChange`). Three things
// can silently regress that back to the old shape -- a hand-maintained list
// instead of the directory, a re-added open button, or a listbox that only
// records the selection and waits for one. All three are asserted here, because
// the feature IS the absence of the open step: a check that never fires is
// indistinguishable from one that does nothing.

// Commands that would re-introduce the open-document gesture this workflow
// removed. Absence is the feature, so the predicate is named and probed rather
// than inlined where only a passing run ever sees it.
function openGestures(commands) {
    local out = [];
    foreach (command in commands) {
        if (command.find("open") == 0 || command.find("Open") == 0) out.append(command);
    }
    return out;
}

// Document listboxes that record a selection and then wait for something else to
// load it -- the shape this workflow replaced with "selecting the row IS the
// load". `optionsBinding` is the `bind:options` target of the document list.
function silentDocumentLists(listboxes, optionsBinding) {
    local out = [];
    foreach (box in listboxes) {
        if (box.options != optionsBinding) continue;
        if (box.change == "") out.append(box.id);
    }
    return out;
}

// ---------------------------------------------------------------------------

// NOTE: this is a FUNCTION, and that is not a style choice. A `-r` script is
// compiled into `load.nut`'s scope, so every top-level `local` here shares one
// frame with load.nut's own locals -- and the EveScript compiler's limit is
// about 250 before it reports "internal compiler error: too many locals". It
// does not always report it: adding six more top-level locals made the VM take
// an access violation inside `SQVM::Return` (`sqvm.cpp:472`,
// `SQObjectPtr::operator=`) instead, non-deterministically, and the same code
// passes in a small script. Keeping new checks inside functions keeps their
// locals in a frame of their own and off that budget.
function checkFolderBoundEditors() {
    local editorSpecs = [
        { editor = "tilemap", vm = "TilemapVM", kind = "map", list = "mapList", sel = "mapId" },
        { editor = "skill", vm = "SkillVM", kind = "skill", list = "skillList", sel = "skillId" },
        { editor = "event", vm = "EventVM", kind = "event", list = "eventList", sel = "eventId" },
        { editor = "battle", vm = "BattleVM", kind = "battle", list = "battleList", sel = "battleId" },
        { editor = "item", vm = "ItemVM", kind = "item", list = "itemList", sel = "itemId" }
    ];

    foreach (spec in editorSpecs) {
        local kind = spec.kind;
        local directory = RpgcProject.directoryOf(kind);
        local live = RpgcProject.idsIn(kind);
        local folder = RpgcProject.folder(kind);
        local info = folder.ok ? folder.value : {};

        check("folder." + kind + ".reads-directory", live.len() > 0,
            directory + " -> " + live.len() + " document(s)");
        // A folder view that agrees with the index is the whole point: otherwise
        // the panel either hides a document that exists, or shows a row that
        // `loadById` then refuses as `project.unknown-id`.
        check("folder." + kind + ".matches-index",
            RpgcProject.idsMatch(RpgcProject.idsOf(kind), live),
            "index=" + RpgcProject.idsOf(kind).len() + " live=" + live.len());
        check("folder." + kind + ".label-names-directory",
            Rpgc.asString(Rpgc.get(info, "label", "")).find(directory) >= 0,
            "label='" + Rpgc.asString(Rpgc.get(info, "label", "")) + "'");
        check("folder." + kind + ".count", Rpgc.asInt(Rpgc.get(info, "count", -1)) == live.len(),
            "count=" + Rpgc.asInt(Rpgc.get(info, "count", -1)) + " live=" + live.len());

        // Importing the ViewModel ran its start-up scan, so the bound list slot
        // must already equal the directory -- this is the difference between "the
        // panel shows the project folder" and "the panel shows an array someone
        // fills in".
        local vm = getroottable()[spec.vm];
        local bound = vm == null ? 0 : Rpgc.get(vm, spec.list, 0);
        check("folder." + spec.editor + ".panel-shows-folder",
            typeof bound == "array" && RpgcProject.idsMatch(bound, live),
            spec.vm + "." + spec.list + "=" + (typeof bound == "array" ? bound.len() : -1)
            + " on disk=" + live.len());

        local selected = vm == null ? "" : Rpgc.asString(Rpgc.get(vm, spec.sel, ""));
        local inList = false;
        foreach (id in live) if (id == selected) inList = true;
        check("folder." + spec.editor + ".selection-is-a-row", selected != "" && inList,
            spec.sel + "=" + selected);
        check("folder." + spec.editor + ".rescan-command",
            vm != null && (("refreshFolder" in vm) || ("refresh" in vm)), "refreshFolder");

        local view = RpgcStore.readText("editors/" + spec.editor + ".editor.json");
        if (!check("folder." + spec.editor + ".view-reads", view.ok)) continue;
        local parsed = RpgcJson.parse(view.value);
        if (!check("folder." + spec.editor + ".view-parses", parsed.ok)) continue;
        local found = { commands = [], binds = [], listboxes = [] };
        viewNodes(Rpgc.get(parsed.value, "children", []), found);

        local opens = openGestures(found.commands);
        check("folder." + spec.editor + ".no-open-gesture", opens.len() == 0,
            "still dispatches " + Rpgc.joinList(opens, ", "));

        // The document listbox must load on selection. This is what makes the
        // folder the document list rather than a list you then have to open
        // something from.
        local silent = silentDocumentLists(found.listboxes, "vm." + spec.list);
        check("folder." + spec.editor + ".list-loads-on-selection", silent.len() == 0,
            "no onChange on " + Rpgc.joinList(silent, ", "));
    }
}

checkFolderBoundEditors();

// ---------------------------------------------------------------------------
// Negative probes.
//
// Every gate the open-world/combat kinds add is asserted to REFUSE a
// deliberately broken document and to name the reason. A gate that only ever
// answers "ok" is indistinguishable from a gate that does nothing, and the
// design leans on these being real: the engine silently ignores a bad trait
// entry, has no style multiplier at all, and counts `duration` in seconds while
// the rules speak in turns.
//
// The cross-document probes substitute `RpgcSystems.documentSource` so a broken
// document is never written into content/ to watch a check fire.
// ---------------------------------------------------------------------------

function hasCode(diagnostics, code) {
    foreach (d in diagnostics) if (d.code == code) return true;
    return false;
}

function codesOf(diagnostics) {
    local out = [];
    foreach (d in diagnostics) out.append(d.code);
    return Rpgc.joinList(out, ",");
}

// Layer 0+1+2 for a document built in memory. `source` substitutes the
// documents a semantic gate reads from disk (e.g. the effect a break status
// points at).
function expectSemantic(label, kind, document, code, source = 0) {
    if (typeof source == "table") RpgcSystems.documentSource <- source;
    local result = RpgcValidate.validateDocument(kind, document);
    RpgcSystems.documentSource <- 0;
    check("reject." + label, hasCode(result.diagnostics, code),
        "wanted " + code + ", got [" + codesOf(result.diagnostics) + "]");
}

function expectAccept(label, kind, document, source = 0) {
    if (typeof source == "table") RpgcSystems.documentSource <- source;
    local result = RpgcValidate.validateDocument(kind, document);
    RpgcSystems.documentSource <- 0;
    check("accept." + label, result.ok,
        "unexpected [" + codesOf(result.diagnostics) + "]");
}

function expectCross(label, source, code) {
    RpgcSystems.documentSource <- source;
    local diagnostics = RpgcSystems.extraDiagnostics();
    RpgcSystems.documentSource <- 0;
    check("cross." + label, hasCode(diagnostics, code),
        "wanted " + code + ", got [" + codesOf(diagnostics) + "]");
}

// --- builders: schema-valid baselines, mutated one field at a time ---------

function baseRules() {
    local document = {
        schema = "eve.rpgc.rules",
        version = 1,
        id = "probe.rules",
        elements = ["metal", "wood", "water", "fire", "earth"],
        generates = { wood = "fire", fire = "earth", earth = "metal", metal = "water", water = "wood" },
        overcomes = { wood = "earth", earth = "water", water = "fire", fire = "metal", metal = "wood" },
        traits = [{ id = "trait.probe", kind = "paramRate", target = "defense", value = 1.1 }],
        weakStyles = ["sword"],
        equipmentSlots = ["weapon", "offhand", "armor", "accessory"],
        clock = { turnSeconds = 6.0 },
        breakEffects = []
    };
    // `break` is a statement keyword, so it can only be a computed key here.
    document.rawset("break", { max = 100, onOvercome = 30, onWeakElement = 20,
                               onWeakStyle = 25, regenPerRound = 10 });
    return document;
}

function baseWorld() {
    return {
        schema = "eve.rpgc.world",
        version = 1,
        id = "probe.world",
        clock = { moments = { day = [7, 17], night = [19, 5] } },
        gates = [{
            portal = "village-outskirts/forest_gate",
            open = { kind = "variable", name = "a", compare = "gte", value = 1 }
        }],
        styleVariants = [{ id = "night", moments = ["night"], mode = "tint", tint = [0.4, 0.4, 0.6, 1.0] }]
    };
}

function baseArt() {
    return {
        schema = "eve.rpgc.art",
        version = 1,
        id = "art.probe",
        category = "martial",
        maxGrade = 5,
        grades = [
            { grade = 1, requirement = { kind = "proficiency", value = 0 }, skills = ["skill.probe"] },
            { grade = 3, requirement = { kind = "proficiency", value = 100 } }
        ]
    };
}

function baseHeart() {
    return {
        schema = "eve.rpgc.heart",
        version = 1,
        id = "probe.heart",
        slots = { count = 1, exclusiveGroup = "grp" },
        grants = { traits = ["trait.probe"], effects = ["burn"] },
        requires = { artId = "art.probe", minGrade = 1 }
    };
}

function baseCombo() {
    return {
        schema = "eve.rpgc.combo",
        version = 1,
        id = "probe.combo",
        members = { min = 2, max = 2, order = "declared" },
        condition = { elements = { kind = "generates", chain = ["metal", "water"] } },
        stages = [{ actor = 0, skill = "skill.a" }, { actor = 1, skill = "skill.b" }],
        finish = { skill = "skill.c" }
    };
}

function baseItem() {
    return {
        schema = "eve.rpgc.item",
        version = 1,
        id = "probe.item",
        displayName = "探针物品",
        category = "weapon",
        maxStack = 1,
        equipSlot = "weapon",
        equipStats = [{ attribute = "attack", op = "add", value = 8 }]
    };
}

// The enemy baseline is deliberately schema-valid and semantically clean, so a
// probe that fails must fail for the one field it mutated.
function baseEnemy() {
    return {
        schema = "eve.rpgc.enemy",
        version = 1,
        id = "enemy.probe",
        displayName = "探针敌人",
        tier = "minion",
        element = "earth",
        weakElements = ["metal"],
        weakStyles = ["sword"],
        combat = { attack = 10, defense = 2, maxHp = 40, speed = 5 },
        breakMax = 50,
        skillId = "skill.probe",
        skills = ["skill.probe"],
        habitat = ["mist-forest"],
        sprite = { anim = "enemy-beasts", clip = "goblin" },
        drops = [{ itemId = "material.pelt", chance = 0.3, min = 1, max = 2 }],
        ai = { aggression = 0.7, fleeBelowHp = 0.1, opener = "skill.probe" }
    };
}

function baseEncounter() {
    return {
        schema = "eve.rpgc.encounter",
        version = 1,
        id = "encounter.probe",
        displayName = "探针遭遇",
        map = "mist-forest",
        members = [{ enemy = "enemy.probe", count = 2 }],
        xpReward = 30,
        xpGrowth = 1.2,
        goldReward = 10,
        quest = {
            requiredQuestId = "quest.probe",
            notifyTopic = "kill",
            notifyTarget = "probe",
            notifyAmount = 1,
            defeatCounterId = "kills",
            defeatCounterAmount = 1,
            levelPointAttributeId = "statPoints",
            pointsPerLevel = 3
        }
    };
}

function baseBattle() {
    return {
        schema = "eve.rpgc.battle",
        version = 1,
        id = "battle.probe",
        displayName = "探针战场",
        canvas = { width = 1920, height = 1080 },
        zones = {
            enemy = { x = 80, y = 60, width = 760, height = 420 },
            ally = { x = 1120, y = 620, width = 720, height = 400 }
        },
        enemySlots = [
            { id = "enemy.1", x = 175, y = 165 },
            { id = "enemy.2", x = 365, y = 165 }
        ],
        allySlots = [
            { id = "ally.1", x = 1240, y = 720 },
            { id = "ally.2", x = 1480, y = 720 }
        ],
        encounters = ["encounter.probe"]
    };
}

// The optional `ui` layer, in the shape `battle.newBattle` seeds: a horizontal
// row of portrait cells with the bars underneath, HUD in the party's half, wheel
// in the left half, neither reaching the enemy bank.
function baseBattleUi() {
    return {
        party = {
            x = 1310, y = 840, width = 570, height = 200,
            slots = 5, slotWidth = 104, slotGap = 8, portraitHeight = 130,
            bars = [
                { id = "hp", offsetY = 8, height = 18, colour = [0.30, 0.72, 0.36] },
                { id = "mana", offsetY = 32, height = 18, colour = [0.25, 0.48, 0.85] }
            ]
        },
        commandRing = {
            cx = 300, cy = 800, radius = 190,
            buttons = [
                { id = "cmd.attack", x = 410, y = 800, radius = 40, label = "攻击" },
                { id = "cmd.skill", x = 300, y = 690, radius = 40, label = "招式" },
                { id = "cmd.item", x = 190, y = 800, radius = 40, label = "物品" },
                { id = "cmd.defend", x = 300, y = 910, radius = 40, label = "防御" }
            ]
        }
    };
}

// --- shared condition vocabulary (schema `eve.rpgc.condition`) -------------
// Keep fixture locals off the shared load.nut frame (see the note above
// checkFolderBoundEditors). Large root frames can corrupt later fixture values
// before the SDK reports a locals limit, or crash inside the native VM.
function checkDocumentProbes() {
    local badCondition = baseWorld();
    badCondition.gates[0].open = { kind = "bogus" };
    expectSemantic("condition-unknown-kind", "world", badCondition, "validate.schema");

    local momentCondition = baseWorld();
    momentCondition.gates[0].open = { kind = "moment", any = ["day"] };
    expectAccept("condition-moment-known", "world", momentCondition);

    local unknownMoment = baseWorld();
    unknownMoment.gates[0].open = { kind = "moment", any = ["noon"] };
    expectSemantic("condition-unknown-moment", "world", unknownMoment, "systems.condition-unknown-moment");

    // --- rules -----------------------------------------------------------------

    local brokenCycle = baseRules();
    brokenCycle.generates.metal = "wood";
    expectSemantic("rules-cycle", "rules", brokenCycle, "systems.relation-not-a-cycle");

    local selfRelation = baseRules();
    selfRelation.overcomes.fire = "fire";
    expectSemantic("rules-self", "rules", selfRelation, "systems.relation-self");

    local targetlessTrait = baseRules();
    targetlessTrait.traits[0].target = "";
    expectSemantic("rules-trait-target", "rules", targetlessTrait, "systems.trait-target");

    local alienTrait = baseRules();
    alienTrait.traits[0].kind = "elementRate";
    alienTrait.traits[0].target = "shadow";
    expectSemantic("rules-trait-element", "rules", alienTrait, "systems.trait-element");

    local bigBreak = baseRules();
    bigBreak.rawget("break").onOvercome = 500;
    expectSemantic("rules-break-max", "rules", bigBreak, "systems.break-exceeds-max");

    // The turn-to-second derivation: 2 turns at 6 s/turn must be duration = 12,
    // and `duration` is seconds. Writing 2.0 is the mistake the gate exists for.
    local derived = baseRules();
    derived.breakEffects = [{ effect = "probe.effect", turns = 2 }];
    local shortEffect = { effect = [{ schema = "eve.rpgc.effect", version = 1, id = "probe.effect",
                                      durationPolicy = "duration", duration = 2.0 }] };
    expectSemantic("rules-turn-derivation", "rules", derived, "systems.break-effect-duration", shortEffect);

    local correctEffect = { effect = [{ schema = "eve.rpgc.effect", version = 1, id = "probe.effect",
                                        durationPolicy = "duration", duration = 12.0 }] };
    expectAccept("rules-turn-derivation-correct", "rules", derived, correctEffect);

    // --- world -----------------------------------------------------------------

    local badBand = baseWorld();
    badBand.clock.moments.day = [7];
    expectSemantic("world-band-shape", "world", badBand, "systems.moment-band");

    local emptyBand = baseWorld();
    emptyBand.clock.moments.day = [7, 7];
    expectSemantic("world-empty-band", "world", emptyBand, "systems.moment-empty-band");

    local badPortal = baseWorld();
    badPortal.gates[0].portal = "noslash";
    expectSemantic("world-portal-shape", "world", badPortal, "systems.gate-portal");

    local dupPortal = baseWorld();
    dupPortal.gates.append({ portal = "village-outskirts/forest_gate",
                             open = { kind = "always" } });
    expectSemantic("world-portal-duplicate", "world", dupPortal, "systems.gate-duplicate");

    local badTint = baseWorld();
    badTint.styleVariants[0].tint = [1.5, 0.0, 0.0, 1.0];
    expectSemantic("world-tint-range", "world", badTint, "systems.variant-tint-range");

    local mixedVariant = baseWorld();
    mixedVariant.styleVariants[0].tileset <- "sbs-overworld";
    expectSemantic("world-variant-mixed", "world", mixedVariant, "systems.variant-mixed");

    local atlasVariant = baseWorld();
    atlasVariant.styleVariants[0] = { id = "night", moments = ["night"], mode = "atlas" };
    expectSemantic("world-variant-atlas", "world", atlasVariant, "systems.variant-atlas");

    // --- art -------------------------------------------------------------------

    local unsortedGrades = baseArt();
    unsortedGrades.grades[0].grade = 3;
    unsortedGrades.grades[1].grade = 1;
    expectSemantic("art-grade-order", "art", unsortedGrades, "systems.art-unsorted-grades");

    local overMax = baseArt();
    overMax.grades[1].grade = 7;
    expectSemantic("art-grade-over-max", "art", overMax, "systems.art-grade-over-max");

    local noRequirementKind = baseArt();
    noRequirementKind.grades[0].requirement.kind = "";
    expectSemantic("art-requirement", "art", noRequirementKind, "systems.art-requirement");

    // --- heart -----------------------------------------------------------------

    // `elementOverride` REPLACES the element while an `attackElement` trait APPENDS
    // one, so declaring both leaves the runtime a choice the document must make.
    local conflictingHeart = baseHeart();
    conflictingHeart.grants.traits = ["trait.probe.ice"];
    conflictingHeart.grants.elementOverride <- "water";
    local iceRules = baseRules();
    iceRules.traits = [{ id = "trait.probe.ice", kind = "attackElement", target = "water", value = 1.0 }];
    expectSemantic("heart-element-conflict", "heart", conflictingHeart,
        "systems.heart-element-conflict", { rules = [iceRules] });

    local impossibleHeart = baseHeart();
    impossibleHeart.requires.minGrade = 9;
    expectSemantic("heart-min-grade", "heart", impossibleHeart, "systems.heart-min-grade",
        { art = [baseArt()] });

    // --- combo -----------------------------------------------------------------

    local shortCombo = baseCombo();
    shortCombo.members.min = 3;
    shortCombo.members.max = 4;
    expectSemantic("combo-stage-count", "combo", shortCombo, "systems.combo-stage-count");

    local twiceActor = baseCombo();
    twiceActor.stages[1].actor = 0;
    expectSemantic("combo-duplicate-actor", "combo", twiceActor, "systems.combo-duplicate-actor");

    // --- item ------------------------------------------------------------------
    //
    // Every case below answers a silence in `inventory::ItemRegistry` or
    // `EquipmentSystem`: the loader coerces maxStack <= 0 to 1, silently overwrites
    // a duplicate id, drops unknown keys without a word, and `equipSlot` is
    // documented by the engine itself as a suggestion nothing resolves.

    local goodItem = baseItem();
    expectAccept("item-well-formed", "item", goodItem);

    local slotlessGear = baseItem();
    slotlessGear.equipSlot = "";
    expectSemantic("item-slot-missing", "item", slotlessGear, "systems.item-slot-missing");

    local slottedPotion = baseItem();
    slottedPotion.category = "consumable";
    slottedPotion.equipStats = [];
    slottedPotion.use <- { consume = true, effects = ["burn"] };
    expectSemantic("item-slot-unexpected", "item", slottedPotion, "systems.item-slot-unexpected");

    // The engine happily carries maxStack = 5 on a weapon; equipping "one of five"
    // is the part with no defined meaning, because EquipmentSet holds one stack.
    local stackingGear = baseItem();
    stackingGear.maxStack = 5;
    expectSemantic("item-equipment-stacks", "item", stackingGear, "systems.item-equipment-stacks");

    // maxStack <= 0 is another engine coercion (Item.cpp:48 turns it into 1), but
    // the schema's `minimum: 1` already rejects it one layer earlier, so this case
    // pins the layer that actually fires rather than asserting a dead semantic gate.
    local overdrawn = baseItem();
    overdrawn.maxStack = 0;
    expectSemantic("item-max-stack", "item", overdrawn, "validate.schema");

    local pointlessStats = baseItem();
    pointlessStats.category = "material";
    pointlessStats.equipSlot = "";
    expectSemantic("item-stats-not-equipment", "item", pointlessStats,
        "systems.item-stats-not-equipment");

    // No engine field carries "what using this does", so a consumable without one
    // reads as usable and behaves as an inert rock.
    local mutePotion = baseItem();
    mutePotion.category = "consumable";
    mutePotion.equipSlot = "";
    mutePotion.equipStats = [];
    expectSemantic("item-use-missing", "item", mutePotion, "systems.item-use-missing");

    local emptyManual = baseItem();
    emptyManual.category = "manual";
    emptyManual.equipSlot = "";
    emptyManual.equipStats = [];
    emptyManual.teaches <- {};
    expectSemantic("item-teaches-empty", "item", emptyManual, "systems.item-teaches-empty");

    // --- map layer discipline --------------------------------------------------

    local mapRead = RpgcStore.readDocument("content/maps/village-outskirts.json");
    local mapWidth = Rpgc.asInt(Rpgc.get(mapRead.value, "width", 0));
    local mapHeight = Rpgc.asInt(Rpgc.get(mapRead.value, "height", 0));
    local blank = [];
    for (local i = 0; i < mapWidth * mapHeight; i += 1) blank.append(0);

    local noTerrain = RpgcStore.readDocument("content/maps/village-outskirts.json").value;
    noTerrain.layers[0].id = "ground";
    expectSemantic("map-no-terrain", "map", noTerrain, "map.no-terrain-layer");

    local wrongTerrainIndex = RpgcStore.readDocument("content/maps/village-outskirts.json").value;
    wrongTerrainIndex.layers[0].layer = 1;
    expectSemantic("map-terrain-index", "map", wrongTerrainIndex, "map.terrain-layer-index");

    local twoMomentsOneIndex = RpgcStore.readDocument("content/maps/village-outskirts.json").value;
    twoMomentsOneIndex.layers.append({ id = "moment.night", name = "moment.night",
        type = "tilelayer", layer = 3, visible = false, data = blank });
    twoMomentsOneIndex.layers.append({ id = "moment.dusk", name = "moment.dusk",
        type = "tilelayer", layer = 3, visible = false, data = blank });
    expectSemantic("map-moment-layer-index", "map", twoMomentsOneIndex,
        "map.duplicate-moment-layer-index");

    // --- cross-document --------------------------------------------------------

    expectCross("no-rules", { rules = [] }, "systems.no-rules");
    expectCross("many-rules", { rules = [baseRules(), baseRules()] }, "systems.many-rules");

    // A gate whose portal moved: the door would never open, and nothing else says so.
    local strayGate = baseWorld();
    strayGate.gates[0].portal = "village-outskirts/no_such_object";
    expectCross("gate-portal-missing", { world = [strayGate] }, "systems.gate-portal-missing");

    local strayMoment = RpgcStore.readDocument("content/maps/village-outskirts.json").value;
    strayMoment.layers.append({ id = "moment.noon", name = "moment.noon",
        type = "tilelayer", layer = 3, visible = false, data = blank });
    expectCross("map-unknown-moment", { map = [strayMoment] }, "systems.map-unknown-moment");

    // The same moment id written on an OBJECT property: a typo there hides the unit
    // instead of reporting it, because nothing else reads that string.
    local strayObject = RpgcStore.readDocument("content/maps/village-outskirts.json").value;
    foreach (layer in strayObject.layers) {
        if (Rpgc.get(layer, "type", "") != "objectgroup") continue;
        foreach (object in layer.objects) {
            local props = Rpgc.get(object, "properties", 0);
            if (typeof props != "array") continue;
            props.append({ name = "moment", type = "string", value = "noon" });
            break;
        }
        break;
    }
    expectCross("object-unknown-moment", { map = [strayObject] }, "systems.object-unknown-moment");

    // A skill that declares a different art than the one listing it: the art would
    // compile to a skill id that now does something else.
    local loanedArt = baseArt();
    local unaffiliated = { schema = "eve.rpgc.skill", version = 1, id = "skill.probe",
                           targetType = "enemySingle",
                           presentation = { segments = [{ anim = "hero", clip = "attack" }] } };
    expectCross("art-skill-backref", { art = [loanedArt], skill = [unaffiliated] },
        "systems.art-skill-backref");

    local traitArt = baseArt();
    traitArt.grades[0].traits <- ["trait.unknown"];
    local loyal = { schema = "eve.rpgc.skill", version = 1, id = "skill.probe", art = "art.probe",
                    targetType = "enemySingle",
                    presentation = { segments = [{ anim = "hero", clip = "attack" }] } };
    expectCross("art-unknown-trait", { art = [traitArt], skill = [loyal] }, "systems.art-unknown-trait");

    // An "ultimate" that is not tagged as one is just a skill in a different list.
    local ultimateArt = baseArt();
    ultimateArt.grades[0].ultimates <- ["skill.probe"];
    local untagged = { schema = "eve.rpgc.skill", version = 1, id = "skill.probe", art = "art.probe",
                       targetType = "enemySingle", tags = ["martial"],
                       presentation = { segments = [{ anim = "hero", clip = "attack" }] } };
    expectCross("art-ultimate-untagged", { art = [ultimateArt], skill = [untagged] },
        "systems.art-ultimate-untagged");

    local strayHeart = baseHeart();
    strayHeart.grants.traits = ["trait.unknown"];
    expectCross("heart-unknown-trait", { heart = [strayHeart] }, "systems.heart-unknown-trait");

    // Two hearts in one exclusive group gating on the same art: the looser one is
    // implied by the stricter one, so the documents already contradict.
    local nestedA = baseHeart();
    local nestedB = baseHeart();
    nestedB.id = "probe.heart2";
    nestedB.requires.minGrade = 4;
    expectCross("heart-group-nesting", { heart = [nestedA, nestedB] },
        "systems.heart-group-nesting");

    local strayChain = baseCombo();
    strayChain.condition.elements.chain = ["metal", "fire"];
    expectCross("combo-chain", { combo = [strayChain] }, "systems.combo-chain");

    local strayCombo = baseCombo();
    strayCombo.finish.anim <- { anim = "fireball", clip = "no_such_clip" };
    expectCross("combo-clip", { combo = [strayCombo] }, "systems.unknown-clip");

    // The engine never resolves `equipSlot` (inventory/ItemTypes.h:21 calls it a
    // suggestion), so a slot typo yields an item that silently can never be worn
    // and nothing else in the stack can see the disagreement.
    local straySlot = baseItem();
    straySlot.equipSlot = "ring";
    expectCross("item-unknown-slot", { item = [straySlot] }, "systems.item-unknown-slot");

    // A manual naming an art and a move, where the move belongs to another art.
    local mismatchedManual = baseItem();
    mismatchedManual.category = "manual";
    mismatchedManual.equipSlot = "";
    mismatchedManual.equipStats = [];
    mismatchedManual.teaches <- { art = "art.probe", skill = "skill.other" };
    local otherSkill = { schema = "eve.rpgc.skill", version = 1, id = "skill.other",
                         art = "art.somewhere-else", targetType = "enemySingle",
                         presentation = { segments = [{ anim = "hero", clip = "attack" }] } };
    expectCross("item-teaches-mismatch", { item = [mismatchedManual], skill = [otherSkill] },
        "systems.item-teaches-mismatch");

    // A requirement above the art's own ceiling is unreachable by construction, and
    // the engine has no grade concept to notice it.
    local unreachable = baseItem();
    unreachable.requires <- { artId = "art.probe", minGrade = 9 };
    expectCross("item-min-grade", { item = [unreachable], art = [baseArt()] },
        "systems.item-min-grade");

    // Atlas variants must be isomorphic GID for GID, or a handful of cells become
    // the wrong terrain and nobody finds it by eye.
    local atlasSwap = baseWorld();
    atlasSwap.styleVariants = [{ id = "night", moments = ["night"], mode = "atlas",
        tileset = "sbs-walls", baseTileset = "sbs-overworld" }];
    expectCross("variant-isomorphic", { world = [atlasSwap] }, "systems.variant-tile-count");

    // --- enemy -----------------------------------------------------------------
    //
    // EncounterCatalogue validates the whole encounter ARRAY at once, so every
    // bound below is the difference between one bad document and every battle in
    // the game disappearing. The strict `maxHp > 0` and `xpReward > 0` bounds are
    // here rather than in the schema because Eve Schema v1 has no exclusiveMinimum.

    expectAccept("enemy-well-formed", "enemy", baseEnemy());

    local zeroHp = baseEnemy();
    zeroHp.combat.maxHp = 0;
    expectSemantic("enemy-max-hp", "enemy", zeroHp, "systems.enemy-max-hp");

    local nameless = baseEnemy();
    nameless.displayName = "";
    expectSemantic("enemy-display-name", "enemy", nameless, "systems.enemy-display-name");

    local rotation = baseEnemy();
    rotation.skills = ["skill.other"];
    expectSemantic("enemy-skill-rotation", "enemy", rotation, "systems.enemy-skill-rotation");

    local opener = baseEnemy();
    opener.ai.opener = "skill.nope";
    expectSemantic("enemy-opener-unknown", "enemy", opener, "systems.enemy-opener-unknown");

    local doubleDrop = baseEnemy();
    doubleDrop.drops = [
        { itemId = "material.pelt", chance = 0.3, min = 1, max = 1 },
        { itemId = "material.pelt", chance = 0.2, min = 1, max = 1 }
    ];
    expectSemantic("enemy-drop-duplicate", "enemy", doubleDrop, "systems.enemy-drop-duplicate");

    local invertedDrop = baseEnemy();
    invertedDrop.drops[0].min = 3;
    invertedDrop.drops[0].max = 1;
    expectSemantic("enemy-drop-range", "enemy", invertedDrop, "systems.enemy-drop-range");

    // An element the rule table does not define is not a wrong multiplier: the
    // engine resolves it by string, finds no trait, and silently applies none.
    local alienElement = baseEnemy();
    alienElement.element = "shadow";
    expectCross("enemy-unknown-element", { enemy = [alienElement] },
        "systems.enemy-unknown-element");

    local alienWeak = baseEnemy();
    alienWeak.weakElements = ["shadow"];
    expectCross("enemy-unknown-weak-element", { enemy = [alienWeak] },
        "systems.enemy-unknown-weak-element");

    local alienStyle = baseEnemy();
    alienStyle.weakStyles = ["spear"];
    expectCross("enemy-unknown-weak-style", { enemy = [alienStyle] },
        "systems.enemy-unknown-weak-style");

    local selfWeak = baseEnemy();
    selfWeak.weakElements = ["earth"];
    expectCross("enemy-weak-self", { enemy = [selfWeak] }, "systems.enemy-weak-self");

    local fatGauge = baseEnemy();
    fatGauge.breakMax = 200;
    expectCross("enemy-break-over-max", { enemy = [fatGauge] }, "systems.enemy-break-over-max");

    local strayClip = baseEnemy();
    strayClip.sprite.clip = "no_such_clip";
    expectCross("enemy-clip", { enemy = [strayClip] }, "systems.unknown-clip");

    // --- encounter --------------------------------------------------------------

    expectAccept("encounter-well-formed", "encounter", baseEncounter());

    local freeXp = baseEncounter();
    freeXp.xpReward = 0;
    expectSemantic("encounter-xp-reward", "encounter", freeXp, "systems.encounter-xp-reward");

    local twiceSame = baseEncounter();
    twiceSame.members = [{ enemy = "enemy.probe", count = 1 },
                         { enemy = "enemy.probe", count = 1 }];
    expectSemantic("encounter-member-duplicate", "encounter", twiceSame,
        "systems.encounter-member-duplicate");

    // The schema caps `members` at 32 ENTRIES, but each entry carries a `count`, so
    // what has to fit is the projected total.
    local tooMany = baseEncounter();
    tooMany.members = [
        { enemy = "enemy.a", count = 8 }, { enemy = "enemy.b", count = 8 },
        { enemy = "enemy.c", count = 8 }, { enemy = "enemy.d", count = 8 },
        { enemy = "enemy.e", count = 8 }
    ];
    expectSemantic("encounter-member-count", "encounter", tooMany, "systems.encounter-member-count");

    local muteQuest = baseEncounter();
    muteQuest.quest.notifyTopic = "";
    expectSemantic("encounter-quest-id", "encounter", muteQuest, "systems.encounter-quest-id");

    // `habitat` and an encounter's `map` are two statements about where a creature
    // is fought, so the gate holds them to one answer.
    local homeless = baseEnemy();
    homeless.habitat = ["luoyang"];
    local misplaced = baseEncounter();
    misplaced.map = "mist-forest";
    expectCross("encounter-habitat", { enemy = [homeless], encounter = [misplaced] },
        "systems.encounter-habitat");

    // --- battle scene -----------------------------------------------------------
    //
    // Nothing in the engine reads a battle scene -- there is no battlefield,
    // formation or slot type anywhere in src/modules/rpg -- so this gate is the
    // only thing that ever looks at the geometry. Every rejection below is a scene
    // that renders the wrong picture and reports nothing at runtime.

    expectAccept("battle-well-formed", "battle", baseBattle());

    // The 8 / 5 bank caps are design constants rather than schema bounds, so they
    // are reachable from here: nine enemies is legal JSON and a broken battle
    // screen.
    local nineEnemies = baseBattle();
    nineEnemies.enemySlots = [
        { id = "enemy.1", x = 175, y = 165 }, { id = "enemy.2", x = 365, y = 165 },
        { id = "enemy.3", x = 555, y = 165 }, { id = "enemy.4", x = 745, y = 165 },
        { id = "enemy.5", x = 175, y = 375 }, { id = "enemy.6", x = 365, y = 375 },
        { id = "enemy.7", x = 555, y = 375 }, { id = "enemy.8", x = 745, y = 375 },
        { id = "enemy.9", x = 745, y = 275 }
    ];
    expectSemantic("battle-enemy-bank-cap", "battle", nineEnemies, "systems.battle-slot-count");

    local sixAllies = baseBattle();
    sixAllies.allySlots = [
        { id = "ally.1", x = 1240, y = 720 }, { id = "ally.2", x = 1480, y = 720 },
        { id = "ally.3", x = 1720, y = 720 }, { id = "ally.4", x = 1360, y = 920 },
        { id = "ally.5", x = 1600, y = 920 }, { id = "ally.6", x = 1840, y = 920 }
    ];
    expectSemantic("battle-ally-bank-cap", "battle", sixAllies, "systems.battle-slot-count");

    // The half rule has to hold on BOTH axes. Sliding the enemy bank right keeps it
    // in the top band and still puts the two sides beside each other.
    local rightBank = baseBattle();
    rightBank.zones.enemy = { x = 400, y = 60, width = 760, height = 420 };
    expectSemantic("battle-enemy-bank-half-x", "battle", rightBank, "systems.battle-zone-half");

    local lowBank = baseBattle();
    lowBank.zones.enemy = { x = 80, y = 300, width = 760, height = 420 };
    expectSemantic("battle-enemy-bank-half-y", "battle", lowBank, "systems.battle-zone-half");

    local leftBank = baseBattle();
    leftBank.zones.ally = { x = 400, y = 620, width = 720, height = 400 };
    expectSemantic("battle-ally-bank-half-x", "battle", leftBank, "systems.battle-zone-half");

    local highBank = baseBattle();
    highBank.zones.ally = { x = 1120, y = 200, width = 720, height = 400 };
    expectSemantic("battle-ally-bank-half-y", "battle", highBank, "systems.battle-zone-half");

    local offCanvas = baseBattle();
    offCanvas.zones.ally = { x = 1120, y = 620, width = 900, height = 400 };
    expectSemantic("battle-bank-off-canvas", "battle", offCanvas,
        "systems.battle-zone-outside-canvas");

    // Slot coordinates are schema-legal at 1700; the bank is what makes them wrong.
    local straySlot = baseBattle();
    straySlot.enemySlots[0].x = 1700;
    expectSemantic("battle-slot-outside-bank", "battle", straySlot,
        "systems.battle-slot-outside-zone");

    local stackedSlot = baseBattle();
    stackedSlot.allySlots[1] = { id = "ally.9", x = 1240, y = 720 };
    expectSemantic("battle-slot-collision", "battle", stackedSlot,
        "systems.battle-slot-collision");

    local twinSlotId = baseBattle();
    twinSlotId.allySlots[1] = { id = "ally.1", x = 1480, y = 720 };
    expectSemantic("battle-slot-duplicate-id", "battle", twinSlotId,
        "systems.battle-slot-duplicate");

}

checkDocumentProbes();

// A command wheel with its four buttons placed symmetrically inside it, so a
// probe can move the WHEEL without leaving the buttons where they no longer
// belong. `baseBattleUi` keeps the literal shape `battle.newBattle` seeds.
function battleRing(cx, cy, radius) {
    local offset = radius * 0.58;
    local buttonRadius = radius * 0.21;
    local dirs = [[1, 0], [0, -1], [-1, 0], [0, 1]];
    local names = ["cmd.attack", "cmd.skill", "cmd.item", "cmd.defend"];
    local labels = ["攻击", "招式", "物品", "防御"];
    local buttons = [];
    for (local i = 0; i < 4; i += 1) {
        buttons.append({
            id = names[i],
            x = cx + dirs[i][0] * offset,
            y = cy + dirs[i][1] * offset,
            radius = buttonRadius,
            label = labels[i]
        });
    }
    return { cx = cx, cy = cy, radius = radius, buttons = buttons };
}

// ---------------------------------------------------------------------------
// The optional screen-furniture layer.
//
// As with the scene geometry above, nothing in the engine reads any of this and
// no renderer will complain: a HUD that covers the enemy bank renders fine and
// reports nothing. Every rule the layer depends on lives in
// `RpgcSystems.battleUiDiagnostics`, so every rejection below is a scene that
// looks playable in a document and is not one on screen.
//
// This is a FUNCTION so its locals stay off the `load.nut` frame -- see the note
// above `checkFolderBoundEditors` for why that matters.
// ---------------------------------------------------------------------------

function checkBattleUiProbes() {
    // The layer is only meaningfully tested if a scene that USES it is accepted.
    local accepted = baseBattle();
    accepted.ui <- baseBattleUi();
    expectAccept("battle-ui-well-formed", "battle", accepted);

    // A backdrop is a plain path; nothing about it is geometry, and the workflow
    // does not check images (README's "not provided" list).
    local withBackdrop = baseBattle();
    withBackdrop.background <- "backdrops/backdrop.forest-clearing.png";
    expectAccept("battle-backdrop-path", "battle", withBackdrop);

    // An empty path is schema-legal (a plain `string`) and can never load.
    local blankBackdrop = baseBattle();
    blankBackdrop.background <- "";
    expectSemantic("battle-backdrop-empty", "battle", blankBackdrop,
        "systems.battle-background-empty");

    // The HUD reports on the party, so it belongs to the party's half. Same
    // two-axis rule as zones.ally, for the same reason.
    local topHud = baseBattle();
    topHud.ui <- baseBattleUi();
    topHud.ui.party.y = 100.0;
    expectSemantic("battle-ui-hud-half", "battle", topHud, "systems.battle-ui-half");

    local wideHud = baseBattle();
    wideHud.ui <- baseBattleUi();
    wideHud.ui.party.width = 700.0;
    expectSemantic("battle-ui-hud-off-canvas", "battle", wideHud,
        "systems.battle-ui-outside-canvas");

    // The command wheel owns the left of the screen, the party HUD the right.
    local rightRing = baseBattle();
    rightRing.ui <- baseBattleUi();
    rightRing.ui.commandRing = battleRing(800.0, 800.0, 190.0);
    expectSemantic("battle-ui-ring-half", "battle", rightRing, "systems.battle-ui-half");

    local hugeRing = baseBattle();
    hugeRing.ui <- baseBattleUi();
    hugeRing.ui.commandRing = battleRing(300.0, 800.0, 300.0);
    expectSemantic("battle-ui-ring-off-canvas", "battle", hugeRing,
        "systems.battle-ui-outside-canvas");

    // The rule a picture makes obvious and a numeric review never does: screen
    // furniture sitting on top of the thing the player is choosing between.
    //
    // The wheel is the only panel that can do it. Being in the LEFT half does
    // not keep it in the BOTTOM one, so a wheel at y ~ 300 clears the half rule
    // and still lands on the enemy bank. (The party HUD cannot: the zone-half
    // rule forces the enemy bank to end by canvas.width/2 and the HUD to start
    // there, which is why there is no HUD arm of this check.)
    local highRing = baseBattle();
    highRing.ui <- baseBattleUi();
    highRing.ui.commandRing = battleRing(600.0, 300.0, 300.0);
    expectSemantic("battle-ui-ring-over-enemies", "battle", highRing,
        "systems.battle-ui-overlaps-enemies");

    // Ceilings that are semantic, not schema: a 6-face row, a 9-button wheel and
    // a 5-bar strip are all legal JSON, which is the whole reason they are
    // checked here (see the schema's note on why `maxItems` is deliberately
    // absent). `slotWidth` shrinks in the first one so ONLY the cap fires.
    local sixFaces = baseBattle();
    sixFaces.ui <- baseBattleUi();
    sixFaces.ui.party.slots = 6;
    sixFaces.ui.party.slotWidth = 80.0;
    expectSemantic("battle-ui-slots-cap", "battle", sixFaces, "systems.battle-ui-slots");

    // Every position the bank can fill needs a face. `baseBattle` has two ally
    // slots, so a one-face row leaves the second member with no portrait.
    local thinRow = baseBattle();
    thinRow.ui <- baseBattleUi();
    thinRow.ui.party.slots = 1;
    expectSemantic("battle-ui-slots-coverage", "battle", thinRow,
        "systems.battle-ui-slots-coverage");

    local fiveBars = baseBattle();
    fiveBars.ui <- baseBattleUi();
    fiveBars.ui.party.bars.append({ id = "stamina", offsetY = 0, height = 8, colour = [0.8, 0.8, 0.2] });
    fiveBars.ui.party.bars.append({ id = "focus", offsetY = 0, height = 8, colour = [0.8, 0.2, 0.8] });
    fiveBars.ui.party.bars.append({ id = "guard", offsetY = 0, height = 8, colour = [0.2, 0.8, 0.8] });
    expectSemantic("battle-ui-bar-cap", "battle", fiveBars, "systems.battle-ui-bar-count");

    local nineButtons = baseBattle();
    nineButtons.ui <- baseBattleUi();
    local crowded = [];
    for (local i = 0; i < 9; i += 1) {
        local angle = 6.2831853 * i / 9.0;
        crowded.append({
            id = "cmd.extra" + i,
            x = 300.0 + 110.0 * cos(angle),
            y = 800.0 + 110.0 * sin(angle),
            radius = 30.0,
            label = "extra" + i
        });
    }
    nineButtons.ui.commandRing.buttons = crowded;
    expectSemantic("battle-ui-button-cap", "battle", nineButtons,
        "systems.battle-ui-button-count");

    // The portrait row is horizontal, so a row wider than the panel pushes the
    // last face clean outside the HUD.
    local wideRow = baseBattle();
    wideRow.ui <- baseBattleUi();
    wideRow.ui.party.slotWidth = 140.0;
    expectSemantic("battle-ui-row-overflow", "battle", wideRow,
        "systems.battle-ui-row-overflow");

    // The bars live UNDER the portraits, so the two have to share the panel. A
    // portrait strip taller than the panel leaves the bars nowhere to go.
    local tallPortraits = baseBattle();
    tallPortraits.ui <- baseBattleUi();
    tallPortraits.ui.party.portraitHeight = 220.0;
    expectSemantic("battle-ui-portrait-overflow", "battle", tallPortraits,
        "systems.battle-ui-portrait-overflow");

    // A bar that spills past its reserved strip is drawn on top of the faces it
    // is reporting on.
    local spilledBar = baseBattle();
    spilledBar.ui <- baseBattleUi();
    spilledBar.ui.party.bars[0].offsetY = 70.0;
    expectSemantic("battle-ui-bar-overflow", "battle", spilledBar,
        "systems.battle-ui-bar-overflow");

    local twinBars = baseBattle();
    twinBars.ui <- baseBattleUi();
    twinBars.ui.party.bars[1].id = "hp";
    expectSemantic("battle-ui-bar-duplicate", "battle", twinBars,
        "systems.battle-ui-bar-duplicate");

    local badBarId = baseBattle();
    badBarId.ui <- baseBattleUi();
    badBarId.ui.party.bars[0].id = "hp bar";
    expectSemantic("battle-ui-bar-id", "battle", badBarId, "systems.battle-ui-bar-id");

    local rimButton = baseBattle();
    rimButton.ui <- baseBattleUi();
    rimButton.ui.commandRing.buttons[0].x = 480.0;
    expectSemantic("battle-ui-button-outside-ring", "battle", rimButton,
        "systems.battle-ui-button-outside-ring");

    local stackedButton = baseBattle();
    stackedButton.ui <- baseBattleUi();
    stackedButton.ui.commandRing.buttons[1].x = 410.0;
    stackedButton.ui.commandRing.buttons[1].y = 800.0;
    expectSemantic("battle-ui-button-collision", "battle", stackedButton,
        "systems.battle-ui-button-collision");

    local twinButtons = baseBattle();
    twinButtons.ui <- baseBattleUi();
    twinButtons.ui.commandRing.buttons[1].id = "cmd.attack";
    expectSemantic("battle-ui-button-duplicate", "battle", twinButtons,
        "systems.battle-ui-button-duplicate");

    local badButtonId = baseBattle();
    badButtonId.ui <- baseBattleUi();
    badButtonId.ui.commandRing.buttons[0].id = "cmd attack";
    expectSemantic("battle-ui-button-id", "battle", badButtonId,
        "systems.battle-ui-button-id");

    // -----------------------------------------------------------------------
    // The backdrop is DOCUMENT-relative, like `tileset.image` and `anim.image`.
    //
    // This is the one thing about a backdrop that can be checked without parsing
    // an image: that every shipped scene's declared path resolves to a file that
    // exists. It lives here rather than in the semantic gate because it is a
    // build-integrity fact about the vendored set, not a per-document rule --
    // but it is also the check that catches the resolution bug, because
    // `newTextureFromFile` swallows a missing file and the scene then simply
    // renders without a backdrop, saying nothing.
    // -----------------------------------------------------------------------

    local resolved = Rpgc.resolveFrom("content/battles/battle.probe.json",
        "backdrops/backdrop.desert.png");
    check("battle-backdrop.document-relative",
        resolved == "content/battles/backdrops/backdrop.desert.png", resolved);
    // The existence predicate has to be able to say no, or the loop below is a
    // check that only ever answers ok.
    check("battle-backdrop.detector-sees-missing",
        !RpgcStore.exists("content/battles/backdrops/backdrop.does-not-exist.png"), "");

    local declaredCount = 0;
    local unresolved = [];
    foreach (sceneId in RpgcProject.idsOf("battle")) {
        local docPath = RpgcProject.pathOf("battle", sceneId);
        local read = RpgcStore.readDocument(docPath);
        if (!read.ok) continue;
        local declared = Rpgc.asString(Rpgc.get(read.value, "background", ""));
        if (declared == "") continue;
        declaredCount += 1;
        local onDisk = Rpgc.resolveFrom(docPath, declared);
        if (!RpgcStore.exists(onDisk)) unresolved.append(sceneId + " -> " + onDisk);
    }
    check("battle-backdrop.files-exist", unresolved.len() == 0,
        declaredCount + " declared; missing " + Rpgc.joinList(unresolved, ", "));
}

checkBattleUiProbes();

// Coverage and capacity are whole-project facts: a scene cannot see the other
// scenes, and a scene that grows a `count` cannot see the bank that is too full
// for it.
function checkBattleCoverageProbes() {
    local strayEncounter = baseEncounter();
    strayEncounter.id = "encounter.stray";
    expectCross("encounter-without-battle",
        { battle = [baseBattle()], encounter = [baseEncounter(), strayEncounter] },
        "systems.encounter-without-battle");

    local twinScene = baseBattle();
    twinScene.id = "battle.probe-two";
    expectCross("encounter-hosted-twice",
        { battle = [baseBattle(), twinScene], encounter = [baseEncounter()] },
        "systems.encounter-hosted-twice");

    local hostlessScene = baseBattle();
    hostlessScene.encounters = [];
    expectCross("battle-no-encounter",
        { battle = [hostlessScene], encounter = [baseEncounter()] },
        "systems.battle-no-encounter");

    // baseEncounter projects two actors (one entry, `count = 2`); a single-slot
    // bank can only place one of them.
    local oneSlotBank = baseBattle();
    oneSlotBank.enemySlots = [{ id = "enemy.1", x = 175, y = 165 }];
    expectCross("battle-capacity",
        { battle = [oneSlotBank], encounter = [baseEncounter()] },
        "systems.battle-capacity");

    // And the real content tree has to satisfy the coverage rule, not just the
    // probes: the six authored scenes must host every encounter on disk, and every
    // HUD bar they declare must name a pool the rule document registers.
    local rulesOnDisk = RpgcStore.readDocument("content/rules/rules.wuxing.json").value;
    local battleCoverageErrors =
        Rpgc.errorCount(RpgcSystems.battleCrossDiagnostics(rulesOnDisk, []));
    check("battle.content-coverage", battleCoverageErrors == 0,
        "real content tree reports " + battleCoverageErrors + " battle error(s)");

    // A HUD bar names a pool, and the runtime resolves that name in the unit's
    // resource table. `mp` -- what the six shipped scenes said before this gate --
    // is not a pool: `rules.wuxing.json` registers `stamina` and `mana`, so the
    // second bar of every party HUD drew 0/0 for every member of every fight, and
    // no layer of the stack could see it.
    local mislabelledBar = baseBattle();
    mislabelledBar.ui <- baseBattleUi();
    mislabelledBar.ui.party.bars[1].id = "mp";
    local barRules = baseRules();
    barRules.resources <- [{ attribute = "stamina", max = 40 }, { attribute = "mana", max = 30 }];
    expectCross("battle-ui-bar-unregistered",
        { rules = [barRules], battle = [mislabelledBar], encounter = [baseEncounter()] },
        "systems.battle-ui-bar-unregistered");

    // The panel's own "新建" has to seed a document the gate accepts -- a new scene
    // ships with a full enemy bank and a full party bank, and a panel that hands the
    // author an invalid starting point teaches them to ignore the diagnostics.
    BattleVM.newBattle("battle", "");
    local seeded = RpgcValidate.validateDocument("battle", BattleVM.doc);
    check("battle.new-document-valid", seeded.ok,
        "unexpected [" + codesOf(seeded.diagnostics) + "]");

}

checkBattleCoverageProbes();

// ---------------------------------------------------------------------------
// Negative probes for the folder-bound editors.
//
// Everything above asserts that the four Views have no open-document gesture and
// load on selection. A detector that cannot fail proves nothing, so both
// predicates are driven over hand-built View node shapes -- the same
// substitution trick `expectCross` uses, so no broken view has to be written
// into editors/ to watch a check fire.
//
// Like `checkFolderBoundEditors`, this is a function so its locals stay off the
// `load.nut` frame (see the note above it).
// ---------------------------------------------------------------------------

function checkFolderProbes() {
    check("folder.detector.sees-open-command",
        openGestures(["openMap", "refreshFolder"]).len() == 1,
        "got " + Rpgc.joinList(openGestures(["openMap", "refreshFolder"]), ", "));
    check("folder.detector.ignores-approved-commands",
        openGestures(["refreshFolder", "newMap", "saveMap"]).len() == 0, "");

    local probeBox = {};
    probeBox.rawset("id", "map");
    probeBox.rawset("options", "vm.mapList");
    probeBox.rawset("change", "");
    check("folder.detector.sees-silent-list",
        silentDocumentLists([probeBox], "vm.mapList").len() == 1,
        "got " + Rpgc.joinList(silentDocumentLists([probeBox], "vm.mapList"), ", "));
    check("folder.detector.ignores-other-lists",
        silentDocumentLists([probeBox], "vm.layerList").len() == 0, "");

    // -----------------------------------------------------------------------
    // The folder view repairs a stale index.
    //
    // `folder()` re-reads the directory on every call, while `index()` is a
    // snapshot the validation gate wants stable. If the two are allowed to
    // disagree, the panel shows a row and `loadById` answers
    // `project.unknown-id` for it. The repair is only worth having if it
    // actually runs, and it cannot be exercised here by editing files --
    // Squirrel has no writer for the project root (`installScriptFileApi` is
    // read-only, and `writeTextAtomic` rejects a project-relative path, both
    // probed on this checkout). So the cache is made stale the other way: a
    // probe kind is pointed at one directory, the index is warmed, and the kind
    // is then repointed. Those are the real states the repair exists for.
    // -----------------------------------------------------------------------

    RpgcProject.invalidate();
    local probeKind = {};
    probeKind.rawset("directory", "content/maps");
    probeKind.rawset("extension", ".json");
    probeKind.rawset("schema", "eve.rpgc.map");
    probeKind.rawset("module", "RpgcTilemap");
    RpgcProject.manifest().kinds.rawset("folderprobe", probeKind);

    local warmed = RpgcProject.idsOf("folderprobe");
    check("folder.stale.warms-from-first-directory",
        RpgcProject.idsMatch(warmed, RpgcProject.idsIn("map")),
        "cached " + warmed.len() + " from content/maps");

    RpgcProject.manifest().kinds.folderprobe.rawset("directory", "content/battles");
    local stale = RpgcProject.idsOf("folderprobe");
    local onDisk = RpgcProject.idsIn("battle");
    check("folder.stale.index-really-lags",
        RpgcProject.idsMatch(stale, warmed) && !RpgcProject.idsMatch(stale, onDisk),
        "cached " + stale.len() + " vs on disk " + onDisk.len()
        + " -- the gate's snapshot can lag the directory");

    local repaired = RpgcProject.folder("folderprobe");
    check("folder.stale.folder-reads-live",
        RpgcProject.idsMatch(Rpgc.get(repaired.value, "ids", []), onDisk),
        "folder() answered " + Rpgc.get(repaired.value, "ids", []).len()
        + " vs on disk " + onDisk.len());
    check("folder.stale.loader-agrees-after-repair",
        RpgcProject.idsMatch(RpgcProject.idsOf("folderprobe"), onDisk),
        "index=" + RpgcProject.idsOf("folderprobe").len());
    if (onDisk.len() > 0) {
        local loadable = RpgcProject.loadById("folderprobe", onDisk[0]);
        check("folder.stale.loadById-accepts-a-row", loadable.ok,
            "loaded " + onDisk[0]);
    }

    RpgcProject.manifest().kinds.rawdelete("folderprobe");
    RpgcProject.invalidate();
    check("folder.stale.probe-kind-removed",
        !("folderprobe" in RpgcProject.manifest().kinds), "");
}

// ---------------------------------------------------------------------------
// The battle system (lib/rpgc_battle.nut).
//
// Before this module the workflow described a fight and nothing ever resolved
// one: `enemy` held the numbers, `encounter` the composition, `party` the
// player's side, `battle` the screen geometry and `rules` the five-element
// algebra, and no code joined them. The engine cannot do the join either --
// `cmake/module_manifest/core_foundation.cmake` declares `rpg` with `SCRIPT RPG`
// and no `SLOT`, so `load.nut` never instantiates it and `"rpg" in
// getroottable()` is false (asserted below). The resolver therefore restates the
// engine's arithmetic, and these checks are what prove the restatement is
// faithful: every formula, modifier and hit-order case is a vector taken from
// the engine source, not from the resolver's own output.
// ---------------------------------------------------------------------------

function probeRules(over = 0) {
    local rules = baseRules();
    rules.rawset("resources", [
        { attribute = "stamina", max = 40 },
        { attribute = "mana", max = 30 }
    ]);
    rules.rawset("breakEffects", [
        { effect = "stun", turns = 2 },
        { effect = "exposed", turns = 2 }
    ]);
    if (typeof over == "table") foreach (k, v in over) rules.rawset(k, v);
    return rules;
}

// Minimal effect documents with the same shape the shipped ones use. `stun`
// carries the speed-zeroing multiplier content/effects/stun.json declares, and
// `exposed` the two multipliers content/effects/exposed.json declares.
function probeEffectDoc(id, over = 0) {
    local doc = {
        schema = "eve.rpgc.effect", version = 1, id = id,
        durationPolicy = "duration", duration = 12.0,
        stackPolicy = "refresh", maxStacks = 1,
        tags = [], modifiers = []
    };
    if (id == "stun") {
        doc.tags = ["break", "stun", "debuff"];
        doc.modifiers = [{ attribute = "speed", op = "multiply", value = 0.0, priority = 0 }];
    } else if (id == "exposed") {
        doc.tags = ["break", "debuff"];
        doc.modifiers = [
            { attribute = "defense", op = "multiply", value = 0.75, priority = 0 },
            { attribute = "damageTaken", op = "multiply", value = 1.2, priority = 0 }
        ];
    }
    if (typeof over == "table") foreach (k, v in over) doc.rawset(k, v);
    return doc;
}

// A guaranteed-hit, no-crit, metal/sword attack: everything that can add
// randomness is pinned so a break assertion is about the break chain alone.
function probeSkillDoc(id, over = 0) {
    local doc = {
        schema = "eve.rpgc.skill", version = 1, id = id, title = "探针招",
        targetType = "enemySingle",
        costs = [{ attribute = "stamina", amount = 1 }],
        tags = ["attack", "sword"],
        damage = { formula = "a.attack * 2", element = "metal", critChance = 0.0, hitChance = 1.0 },
        presentation = { segments = [{ anim = "hero", clip = "attack" }] }
    };
    if (typeof over == "table") foreach (k, v in over) doc.rawset(k, v);
    return doc;
}

function probePartyMember(over = 0) {
    local member = {
        id = "pc.probe", displayName = "探针", element = "metal",
        combat = { attack = 20, defense = 5, maxHp = 100, speed = 10 },
        breakMax = 100, skills = ["skill.probe"]
    };
    if (typeof over == "table") foreach (k, v in over) member.rawset(k, v);
    return member;
}

function probePartyDoc(members, over = 0) {
    local doc = { schema = "eve.rpgc.party", version = 1, id = "party.probe", members = members };
    if (typeof over == "table") foreach (k, v in over) doc.rawset(k, v);
    return doc;
}

// `baseEnemy` is earth/weak-metal/weak-sword; turning it wood makes the probe
// attacker (metal) overcome it, which is one of the three break sources.
function probeEnemy(over = 0) {
    local doc = baseEnemy();
    doc.element = "wood";
    doc.breakMax = 100;
    if (typeof over == "table") foreach (k, v in over) doc.rawset(k, v);
    return doc;
}

function probeFightConfig(over = 0) {
    local config = {
        rules = probeRules(0),
        battle = baseBattle(),
        encounter = baseEncounter(),
        party = probePartyDoc([probePartyMember(0)]),
        enemies = {}, skills = {}, effects = {}, arts = {},
        seed = 20260916
    };
    config.enemies.rawset("enemy.probe", probeEnemy(0));
    config.skills.rawset("skill.probe", probeSkillDoc("skill.probe", 0));
    config.effects.rawset("stun", probeEffectDoc("stun", 0));
    config.effects.rawset("exposed", probeEffectDoc("exposed", 0));
    if (typeof over == "table") foreach (k, v in over) config.rawset(k, v);
    return config;
}

function probeCombatant(over = 0) {
    local unit = {
        attack = 10.0, defense = 10.0, speed = 5.0, maxHp = 100.0, hp = 100.0,
        resources = {}, resourceMax = {}, effects = []
    };
    if (typeof over == "table") foreach (k, v in over) unit.rawset(k, v);
    return unit;
}

function checkBattleArithmetic() {
    check("battle.version", RpgcBattle.version == 1, "got " + RpgcBattle.version);

    // The engine's damage formula grammar and precedence, from
    // `BattleSystem::parseFormula` (BattleSystem.cpp:55-196).
    local attacker = probeCombatant({ attack = 30.0, defense = 8.0 });
    local defender = probeCombatant({ attack = 1.0, defense = 10.0 });

    local vector = RpgcBattle.evaluate("a.attack * 1.5 - b.defense * 0.6", attacker, defender);
    check("battle.formula.engine-vector", vector.ok && vector.value == 39.0,
        "got " + vector.value + " " + Rpgc.summary(vector));
    check("battle.formula.precedence",
        RpgcBattle.evaluate("2 + 3 * 4", 0, 0).value == 14.0, "");
    check("battle.formula.parentheses",
        RpgcBattle.evaluate("(2 + 3) * 4", 0, 0).value == 20.0, "");
    check("battle.formula.unary",
        RpgcBattle.evaluate("-a.attack + +2", attacker, defender).value == -28.0, "");
    check("battle.formula.division",
        RpgcBattle.evaluate("100 / 4", 0, 0).value == 25.0, "");
    check("battle.formula.unknown-attribute",
        RpgcBattle.evaluate("a.mystery", attacker, defender).value == 0.0, "");
    check("battle.formula.missing-actor",
        RpgcBattle.evaluate("a.attack", 0, 0).value == 0.0, "");

    check("battle.formula.rejects-empty", !RpgcBattle.evaluate("", attacker, defender).ok, "");
    check("battle.formula.rejects-divide-by-zero", !RpgcBattle.evaluate("1 / 0", 0, 0).ok, "");
    check("battle.formula.rejects-double-dot", !RpgcBattle.evaluate("1.2.3", 0, 0).ok, "");
    check("battle.formula.rejects-trailing", !RpgcBattle.evaluate("1 + 2 x", 0, 0).ok, "");
    check("battle.formula.rejects-unbalanced", !RpgcBattle.evaluate("(1 + 2", 0, 0).ok, "");
    check("battle.formula.rejects-statement",
        !RpgcBattle.evaluate("a.attack; print(1)", attacker, defender).ok, "");

    // Modifier composition, from `computeAttributeValue`
    // (AttributeSet.cpp:100-142): additive and additive-percent fold into the
    // base, multiplicative multiplies, and `multiply` means `*= value`.
    local unit = probeCombatant(0);
    local effect = probeEffectDoc("probe.def", {
        modifiers = [{ attribute = "defense", op = "multiply", value = 0.75, priority = 0 }]
    });
    unit.effects.append({ effectId = "probe.def", def = effect, remaining = 12.0,
                          periodClock = 0.0, stacks = 1 });
    check("battle.modifier.multiply", RpgcBattle.attributeOf(unit, "defense") == 7.5,
        "got " + RpgcBattle.attributeOf(unit, "defense"));

    effect.modifiers = [
        { attribute = "defense", op = "add", value = 5, priority = 0 },
        { attribute = "defense", op = "mulAdd", value = 1.0, priority = 0 }
    ];
    check("battle.modifier.additive-percent", RpgcBattle.attributeOf(unit, "defense") == 30.0,
        "got " + RpgcBattle.attributeOf(unit, "defense"));

    effect.modifiers = [
        { attribute = "defense", op = "multiply", value = 2.0, priority = 0 },
        { attribute = "defense", op = "override", value = 99.0, priority = 1 }
    ];
    check("battle.modifier.override-last", RpgcBattle.attributeOf(unit, "defense") == 99.0,
        "got " + RpgcBattle.attributeOf(unit, "defense"));

    // A periodic effect binds NO modifiers while it runs
    // (StatusSystem.cpp:202); only its `hp` modifiers pay out, once per period.
    effect.modifiers = [{ attribute = "defense", op = "multiply", value = 0.1, priority = 0 }];
    effect.rawset("period", 2.0);
    check("battle.modifier.periodic-binds-nothing",
        RpgcBattle.attributeOf(unit, "defense") == 10.0,
        "got " + RpgcBattle.attributeOf(unit, "defense"));

    // Five-element algebra, read from the rule document and nowhere else.
    local rules = probeRules(0);
    check("battle.overcomes.forward", RpgcBattle.overcomes(rules, "metal", "wood"), "");
    check("battle.overcomes.backward", !RpgcBattle.overcomes(rules, "wood", "metal"), "");
    check("battle.overcomes.unknown", !RpgcBattle.overcomes(rules, "plasma", "wood"), "");
    check("battle.element-rate.weak", RpgcBattle.elementRate(probeEnemy(0), "metal") == 1.5, "");
    check("battle.element-rate.neutral", RpgcBattle.elementRate(probeEnemy(0), "fire") == 1.0, "");
    check("battle.element-rate.none", RpgcBattle.elementRate(probeEnemy(0), "none") == 1.0, "");
}

function checkBattleChain() {
    // One hit, three break sources: metal overcomes wood (+30), the skill's
    // element is a declared weakness (+20), the skill's tags hit a declared weak
    // style (+25). The gauge is 100, so the first hit must leave exactly 25.
    local fight = RpgcBattle.newFight(probeFightConfig(0));
    check("battle.newFight", fight.ok, Rpgc.summary(fight));
    if (!fight.ok) return;

    local state = fight.value;
    local ally = RpgcBattle.unitOf(state, "pc.probe");
    local foe = RpgcBattle.unitOf(state, "probe.0");
    check("battle.roster.both-sides", ally != 0 && foe != 0, "");
    check("battle.projected-member-id", foe.id == RpgcBattle.projectedMemberId("enemy.probe", 0),
        "got " + foe.id);

    local skill = state.skills.rawget("skill.probe");
    RpgcBattle.applyBreak(state, ally, foe, skill);
    check("battle.break.three-sources", foe.breakValue == 25,
        "100 - (30 + 20 + 25) = 25, got " + foe.breakValue);

    // Each source on its own, against a fresh gauge, so the total above is a sum
    // of three checks that can each come out different. An attacker whose
    // element does not overcome the target, holding a skill that is neither the
    // target's weak element nor its weak style, moves nothing at all.
    local bystander = probeCombatant({ element = "fire" });
    local neutral = probeSkillDoc("skill.neutral", {
        tags = ["attack"],
        damage = { formula = "a.attack", element = "none", critChance = 0.0, hitChance = 1.0 }
    });
    local untouchedFight = RpgcBattle.newFight(probeFightConfig(0)).value;
    local untouchedFoe = RpgcBattle.unitOf(untouchedFight, "probe.0");
    RpgcBattle.applyBreak(untouchedFight, bystander, untouchedFoe, neutral);
    check("battle.break.no-source-no-change", untouchedFoe.breakValue == 100,
        "got " + untouchedFoe.breakValue);

    // 相克 alone (metal overcomes wood, +30): neither the skill's element nor its
    // tags match, so the gauge must land on exactly 70.
    local overcomeFight = RpgcBattle.newFight(probeFightConfig(0)).value;
    local overcomeFoe = RpgcBattle.unitOf(overcomeFight, "probe.0");
    RpgcBattle.applyBreak(overcomeFight, ally, overcomeFoe, neutral);
    check("battle.break.overcome-only", overcomeFoe.breakValue == 70,
        "100 - 30, got " + overcomeFoe.breakValue);

    // Crossing zero resets the gauge, marks the unit broken and applies both
    // `rules.breakEffects` -- the chain docs/06 §3.4 describes. A fresh fight,
    // because the two hits above have already spent this one.
    local breakFight = RpgcBattle.newFight(probeFightConfig(0)).value;
    local victim = RpgcBattle.unitOf(breakFight, "probe.0");
    local breaker = RpgcBattle.unitOf(breakFight, "pc.probe");
    local breakSkill = breakFight.skills.rawget("skill.probe");
    RpgcBattle.applyBreak(breakFight, breaker, victim, breakSkill);
    RpgcBattle.applyBreak(breakFight, breaker, victim, breakSkill);
    check("battle.break.resets", victim.breakValue == victim.breakMax,
        "got " + victim.breakValue + " of " + victim.breakMax);
    check("battle.break.applies-stun", RpgcBattle.hasEffectTag(victim, "stun"), "");
    // By id, not by tag: `exposed` carries tags ["break", "debuff"], so only the
    // status instance itself proves the second `rules.breakEffects` entry ran.
    local exposedApplied = false;
    foreach (inst in victim.effects) if (inst.effectId == "exposed") exposedApplied = true;
    check("battle.break.applies-exposed", exposedApplied,
        "statuses [" + Rpgc.joinList(victim.effects, ",") + "]");

    // `rules.breakEffects[].turns` is TURNS and the effect document's `duration`
    // is SECONDS: two turns is 12 s at 6 s a turn. Two round ticks of 6 s must
    // expire it, and one must not.
    local stun = 0;
    foreach (inst in victim.effects) if (inst.effectId == "stun") stun = inst;
    check("battle.status.duration-seconds", stun != 0 && stun.remaining == 12.0,
        "got " + (stun == 0 ? -1 : stun.remaining));

    RpgcBattle.tickEffects(breakFight, victim, 6.0);
    check("battle.status.one-round-left", RpgcBattle.hasEffectTag(victim, "stun"), "");
    RpgcBattle.tickEffects(breakFight, victim, 6.0);
    check("battle.status.expires-after-two", !RpgcBattle.hasEffectTag(victim, "stun"), "");

    // `exposed` is the damage-taken channel, and it has to actually raise the
    // number that comes out of `resolveHit`.
    local damaged = probeCombatant(0);
    check("battle.damage-taken.default", RpgcBattle.damageTakenRate(damaged) == 1.0, "");
    damaged.effects.append({ effectId = "exposed", def = probeEffectDoc("exposed", 0),
                             remaining = 12.0, periodClock = 0.0, stacks = 1 });
    check("battle.damage-taken.exposed", RpgcBattle.damageTakenRate(damaged) == 1.2,
        "got " + RpgcBattle.damageTakenRate(damaged));

    // Break comes back a little every round.
    local regenerated = RpgcBattle.newFight(probeFightConfig(0)).value;
    local holed = RpgcBattle.unitOf(regenerated, "probe.0");
    holed.breakValue = 10;
    RpgcBattle.regenBreak(regenerated, holed);
    check("battle.break.regen-per-round", holed.breakValue == 20,
        "10 + regen(10), got " + holed.breakValue);
}

function checkBattleFlow() {
    // Determinism: the same seed and the same documents must produce the same
    // fight, and the stream must actually be drawn from (a fight that never
    // rolls is a fight whose tests prove nothing).
    local first = RpgcBattle.newFight(probeFightConfig(0)).value;
    local second = RpgcBattle.newFight(probeFightConfig(0)).value;
    local startRng = first.rng;
    RpgcBattle.runToEnd(first, 200);
    RpgcBattle.runToEnd(second, 200);
    check("battle.determinism.same-seed",
        Rpgc.joinList(first.log, "|") == Rpgc.joinList(second.log, "|"),
        "log lengths " + first.log.len() + " vs " + second.log.len());
    check("battle.determinism.stream-drawn", first.rng != startRng, "");
    check("battle.outcome.terminal", first.outcome != "" && first.outcome != "stalled",
        "got '" + first.outcome + "'");

    // Settlement: the encounter's own rewards, and drops only from enemies that
    // were actually defeated.
    local won = RpgcBattle.newFight(probeFightConfig(0)).value;
    RpgcBattle.runToEnd(won, 200);
    local settled = RpgcBattle.settlement(won);
    check("battle.settlement.outcome", settled.outcome == "victory", "got " + settled.outcome);
    check("battle.settlement.xp", settled.xp == 30, "got " + settled.xp);
    check("battle.settlement.gold", settled.gold == 10, "got " + settled.gold);

    // Commands and targeting: a refused order must leave the fight untouched.
    local ordered = RpgcBattle.newFight(probeFightConfig(0)).value;
    local pending = ordered.pending;
    check("battle.pending.ally", pending == "pc.probe", "got '" + pending + "'");
    local commands = RpgcBattle.commandsFor(ordered, RpgcBattle.unitOf(ordered, pending));
    check("battle.commands.include-defend", commands.len() >= 2, "got " + commands.len());
    local before = RpgcBattle.unitOf(ordered, "probe.0").hp;
    local refused = RpgcBattle.submitCommand(ordered,
        { skill = "skill.does-not-exist", target = "probe.0" });
    check("battle.command.unknown-skill", refused.ok,
        "the order is accepted and logged as a no-op, not thrown");
    check("battle.command.no-damage-from-noop",
        RpgcBattle.unitOf(ordered, "probe.0").hp == before, "");

    // Slot projection is the whole of the scene's contract: the k-th unit of a
    // side stands on the k-th slot of that side.
    local placed = RpgcBattle.placeOnScene(ordered);
    local battle = ordered.battle;
    local allySlots = Rpgc.get(battle, "allySlots", []);
    local firstAlly = 0;
    foreach (entry in placed) if (entry.side == "ally") firstAlly = entry;
    check("battle.scene.ally-slot", firstAlly != 0
        && firstAlly.x == Rpgc.asNumber(Rpgc.get(allySlots[0], "x", 0))
        && firstAlly.y == Rpgc.asNumber(Rpgc.get(allySlots[0], "y", 0)),
        "got " + (firstAlly == 0 ? 0 : firstAlly.x) + "," + (firstAlly == 0 ? 0 : firstAlly.y));

    local fit = RpgcBattle.fitToViewport(battle, 1600.0, 900.0);
    check("battle.scene.letterbox-scale", fit.scale > 0.8333 && fit.scale < 0.8334,
        "got " + fit.scale);
    check("battle.scene.letterbox-offset", fit.offsetX == 0.0 && fit.offsetY == 0.0,
        "got " + fit.offsetX + "," + fit.offsetY);

    // The two readouts an operator (or an AI) reads back. Neither decides
    // anything, but a report nobody ever called is a report that is free to rot.
    local line = RpgcBattle.statusLine(ordered);
    check("battle.report.status-line", line.find("round") != null && line.find("破绽") != null,
        line);
    local json = RpgcBattle.reportJson(ordered);
    check("battle.report.json", json.len() > 40 && json.find("\"units\"") != null,
        "got " + json.len() + " bytes");
}

function checkBattleContent() {
    // Every encounter in the real content tree must start against the real
    // roster and reach a terminal outcome. This is the only check that joins all
    // five documents at once, and it is the one that would catch a party member
    // whose art grade compiles to no moves at all.
    local party = RpgcProject.loadById("party", "party.default");
    check("battle.content.party-loads", party.ok, Rpgc.summary(party));

    local encounters = RpgcProject.idsOf("encounter");
    local played = 0;
    local victories = 0;
    local stalled = "";
    foreach (id in encounters) {
        local config = RpgcBattle.loadProject("party.default", id, "");
        if (!config.ok) continue;
        local fight = RpgcBattle.newFight(config.value);
        if (!fight.ok) {
            stalled = id + ": " + Rpgc.summary(fight);
            break;
        }
        RpgcBattle.runToEnd(fight.value, 400);
        played += 1;
        if (fight.value.outcome == "victory") victories += 1;
        else if (fight.value.outcome == "" || fight.value.outcome == "stalled") {
            stalled = id + " ended as '" + fight.value.outcome + "'";
            break;
        }
    }
    check("battle.content.every-encounter-plays",
        played == encounters.len() && stalled == "",
        stalled == "" ? played + "/" + encounters.len() + " played" : stalled);    check("battle.content.somebody-wins", victories > 0,
        victories + " victory(ies) of " + played);

    // A narrow scene seats four of the five: `allySlots` is a capacity, and the
    // member left out is named on `fight.bench` rather than silently dropped.
    // battle.mountain-pass is the scene with four ally positions.
    local narrow = RpgcBattle.loadProject("party.default", "encounter.jiange-ambush", "");
    if (narrow.ok) {
        local narrowFight = RpgcBattle.newFight(narrow.value).value;
        local seated = RpgcBattle.livingUnits(narrowFight, "ally").len();
        check("battle.content.narrow-scene-seats-what-fits", seated == 4,
            "seated " + seated);
        check("battle.content.narrow-scene-benches-the-rest", narrowFight.bench.len() == 1,
            "bench " + Rpgc.joinList(narrowFight.bench, ","));
    }

    // The roster's moves are COMPILED from `art` + `grade` (docs/06 §2.4), not
    // copied into the party document. 裴无咎 holds grade 5 of art.liuhe-blade,
    // whose ultimate is skill.liuhe-blade.ultimate.
    local config = RpgcBattle.loadProject("party.default", "encounter.outskirts-night", "");
    if (config.ok) {
        local fight = RpgcBattle.newFight(config.value).value;
        local blade = RpgcBattle.unitOf(fight, "pc.liuhe");
        local hasUltimate = false;
        local hasGrade1 = false;
        foreach (skillId in blade.skills) {
            if (skillId == "skill.liuhe-blade.ultimate") hasUltimate = true;
            if (skillId == "skill.liuhe-blade.p1") hasGrade1 = true;
        }
        check("battle.roster.art-compiles-ultimates", hasUltimate,
            "grade 5 grants " + Rpgc.joinList(blade.skills, ","));
        check("battle.roster.art-compiles-lower-grades", hasGrade1, "");

        // 白婆婆 names no art, so her move list is exactly her `skills[]`.
        local physician = RpgcBattle.unitOf(fight, "pc.physician");
        check("battle.roster.no-art-means-declared-only", physician.skills.len() == 3,
            "got " + physician.skills.len());

        // Resources come from the rule table, one pool per declared attribute.
        check("battle.resources.from-rules",
            physician.resourceMax.rawin("mana") && physician.resources.rawget("mana") == 30.0,
            "mana max " + Rpgc.get(physician.resourceMax, "mana", -1));
    }

    // `tools/build_encounters.py` derives a member id as `stem.index`; a fight's
    // units must carry the same names or a log line stops identifying a creature.
    check("battle.projected-id.matches-projection",
        RpgcBattle.projectedMemberId("enemy.bone-captain", 2) == "bone-captain.2", "");

    // The one claim the resolver does NOT try to make: this build has no `rpg`
    // binding, which is why lib/rpgc_battle.nut restates the engine's arithmetic
    // instead of calling it.
    check("battle.engine.rpg-binding-absent", !("rpg" in getroottable()),
        "if this ever becomes true, delete the restatement and call the engine");
}

function checkPartyGate() {
    expectAccept("party-well-formed", "party", probePartyDoc([probePartyMember(0)]));

    local nameless = probePartyDoc([probePartyMember({ displayName = "" })]);
    expectSemantic("party-member-name", "party", nameless, "systems.party-member-name");

    local duplicated = probePartyDoc([probePartyMember(0), probePartyMember(0)]);
    expectSemantic("party-member-duplicate", "party", duplicated, "systems.party-member-duplicate");

    local zeroHp = probePartyDoc([probePartyMember({
        combat = { attack = 1, defense = 1, maxHp = 0, speed = 1 } })]);
    expectSemantic("party-member-max-hp", "party", zeroHp, "systems.party-member-max-hp");

    local gradeOnly = probePartyDoc([probePartyMember({ grade = 3 })]);
    expectSemantic("party-member-art-missing", "party", gradeOnly, "systems.party-member-art-missing");

    local artOnly = probePartyDoc([probePartyMember({ art = "art.probe" })]);
    expectSemantic("party-member-grade-missing", "party", artOnly, "systems.party-member-grade-missing");

    // The roster cap is `RpgcSystems.maxBattleAllySlots`, the same constant the
    // battle scene's ally bank is checked against.
    local tooMany = probePartyDoc([
        probePartyMember({ id = "pc.a" }), probePartyMember({ id = "pc.b" }),
        probePartyMember({ id = "pc.c" }), probePartyMember({ id = "pc.d" }),
        probePartyMember({ id = "pc.e" }), probePartyMember({ id = "pc.f" })
    ]);
    check("systems.maxBattleAllySlots", RpgcSystems.maxBattleAllySlots == 5,
        "got " + RpgcSystems.maxBattleAllySlots);
    expectCross("party-too-many-members", { rules = [probeRules(0)], party = [tooMany] },
        "systems.party-too-many-members");

    local alien = probePartyDoc([probePartyMember({ element = "plasma" })]);
    expectCross("party-unknown-element", { rules = [probeRules(0)], party = [alien] },
        "systems.party-unknown-element");

    local overBreak = probePartyDoc([probePartyMember({ breakMax = 400 })]);
    expectCross("party-break-over-max", { rules = [probeRules(0)], party = [overBreak] },
        "systems.party-break-over-max");

    local overGrade = probePartyDoc([probePartyMember({ art = "art.probe", grade = 9 })]);
    expectCross("party-grade-over-max",
        { rules = [probeRules(0)], party = [overGrade], art = [baseArt()] },
        "systems.party-grade-over-max");

    // The resource table: the pools exist so a skill's `costs[]` names something
    // that can actually be paid.
    local duplicatedPool = probeRules({
        resources = [
            { attribute = "mana", max = 30 },
            { attribute = "mana", max = 40 }
        ]
    });
    local rulesCheck = RpgcValidate.validateDocument("rules", duplicatedPool);
    check("reject.rules-resource-duplicate",
        hasCode(rulesCheck.diagnostics, "systems.resource-duplicate"),
        "got [" + codesOf(rulesCheck.diagnostics) + "]");

    local emptyPool = probeRules({ resources = [{ attribute = "mana", max = 0 }] });
    local poolCheck = RpgcValidate.validateDocument("rules", emptyPool);
    check("reject.rules-resource-max",
        hasCode(poolCheck.diagnostics, "systems.resource-max"),
        "got [" + codesOf(poolCheck.diagnostics) + "]");

    // A cost naming an attribute no pool declares is a skill whose cost is read
    // by nobody -- the exact failure the pool table exists to make impossible.
    local costlySkill = probeSkillDoc("skill.probe", {
        costs = [{ attribute = "stamina", amount = 1 }, { attribute = "qi", amount = 5 }]
    });
    expectCross("skill-cost-unregistered",
        { rules = [probeRules(0)], skill = [costlySkill] },
        "systems.skill-cost-unregistered");
}

// ---------------------------------------------------------------------------
// The item system (lib/rpgc_items.nut).
//
// `item` is the first kind whose ENGINE half is specified: `ItemRegistry` parses
// nine keys and `EquipmentSystem` holds the equip stats. docs/08 §7 wrote its
// runtime as `eve.Inventory().registerItemsFromJson(...)`, and that call cannot
// run in this build -- `inventory` is declared with `SCRIPT Inventory` and no
// `SLOT` (cmake/module_manifest/core_foundation.cmake:105), so `load.nut` never
// instantiates it and the class is not on the `eve` table.
//
// The checks come in two halves for exactly that reason: the absence that forces
// a project-side runtime to exist, and the runtime's own arithmetic, restated
// from the source and asserted one refusal at a time. A bag operation that
// cannot fail is not a check.

function probeItemConfig(items, slots) {
    local config = {};
    config.items <- items;
    config.slots <- slots;
    config.rules <- {};
    return config;
}

function probeItemDef(over) {
    local def = {
        id = "probe.item", displayName = "探针", category = "material",
        maxStack = 1, weight = 1.0, volume = 1.0
    };
    if (typeof over == "table") foreach (k, v in over) def.rawset(k, v);
    return def;
}

function checkItemSystem() {
    check("items.version", RpgcItems.version == 1, "got " + RpgcItems.version);

    // --- why this module exists ------------------------------------------
    check("items.inventory-unbound", !("Inventory" in eve),
        "eve.Inventory is on the table, so docs/08 §7 may be runnable after all");
    check("items.rpg-unbound", !("rpg" in eve),
        "the rpg slot appeared; RpgcItems' header rests on it being absent");

    local loaded = RpgcItems.loadProject();
    if (!check("items.load", loaded.ok, Rpgc.summary(loaded))) return;
    local config = loaded.value;
    local slots = Rpgc.get(config, "slots", []);
    check("items.slot-vocabulary", slots.len() == 6,
        "rules.equipmentSlots -> " + Rpgc.joinList(slots, ","));
    // The index and the loader are the same statement about the folder, so a
    // definition that fails to parse shows up here rather than as a missing item.
    local onDisk = RpgcProject.idsOf("item").len();
    check("items.every-document-loaded", Rpgc.keyCount(Rpgc.get(config, "items", {})) == onDisk,
        "loaded " + Rpgc.keyCount(Rpgc.get(config, "items", {})) + " of " + onDisk);

    // --- stacking, and the two ways a bag says no ------------------------
    local bag = RpgcItems.newBag(3, "probe");
    local first = RpgcItems.add(bag, config, "material.pelt", 99);
    check("items.add-fills-one-stack",
        first.ok && first.value.added == 99 && RpgcItems.usedSlots(bag) == 1,
        "added=" + (first.ok ? first.value.added : -1) + " slots=" + RpgcItems.usedSlots(bag));
    local second = RpgcItems.add(bag, config, "material.pelt", 1);
    check("items.add-overflows-to-a-second-stack",
        second.ok && second.value.added == 1 && RpgcItems.usedSlots(bag) == 2,
        "slots=" + RpgcItems.usedSlots(bag));

    local tiny = RpgcItems.newBag(1, "tiny");
    RpgcItems.add(tiny, config, "weapon.iron-sword", 1);
    local refused = RpgcItems.canAdd(tiny, config, "weapon.iron-sword", 1);
    check("items.no-slot", !refused.ok && hasCode(refused.diagnostics, "items.no-slot"),
        "got [" + codesOf(refused.diagnostics) + "]");
    // `addItem` returns a partial count rather than failing, so `add` must too:
    // a caller that reads `ok` alone would believe the whole stack landed.
    local partial = RpgcItems.add(tiny, config, "weapon.iron-sword", 1);
    check("items.add-is-partial",
        partial.ok && partial.value.added == 0 && partial.value.remaining == 1,
        "added=" + partial.value.added + " remaining=" + partial.value.remaining);

    local heavy = RpgcItems.newBag(4, "heavy");
    heavy.maxWeight = 4.0;
    local tooHeavy = RpgcItems.canAdd(heavy, config, "weapon.iron-sword", 2);
    check("items.over-weight", !tooHeavy.ok && hasCode(tooHeavy.diagnostics, "items.over-weight"),
        "got [" + codesOf(tooHeavy.diagnostics) + "]");
    local weightPartial = RpgcItems.add(heavy, config, "weapon.iron-sword", 2);
    check("items.over-weight-partial", weightPartial.ok && weightPartial.value.added == 1,
        "added=" + (weightPartial.ok ? weightPartial.value.added : -1));
    // `Bag.h:114` -- a limit of 0 is "unlimited", not "no capacity".
    local loose = RpgcItems.newBag(4, "loose");
    check("items.zero-weight-is-unlimited",
        RpgcItems.canAdd(loose, config, "weapon.iron-sword", 4).ok, "limit 0 refused a 4-sword add");

    local weird = RpgcItems.newBag(2, "weird");
    weird.capacityPolicy = "magic";
    local policy = RpgcItems.canAdd(weird, config, "material.pelt", 1);
    check("items.unknown-policy-fails-closed",
        !policy.ok && hasCode(policy.diagnostics, "items.unknown-policy"),
        "got [" + codesOf(policy.diagnostics) + "]");
    local unknown = RpgcItems.add(bag, config, "item.nope", 1);
    check("items.unknown-item", !unknown.ok && hasCode(unknown.diagnostics, "items.unknown-item"),
        "got [" + codesOf(unknown.diagnostics) + "]");

    // --- equipment --------------------------------------------------------
    local equipBag = RpgcItems.newBag(4, "equip");
    RpgcItems.add(equipBag, config, "weapon.iron-sword", 1);
    RpgcItems.add(equipBag, config, "weapon.iron-sword", 1);
    local set = RpgcItems.newEquipmentSet(config, "probe");
    local worn = RpgcItems.equip(equipBag, set, config, "weapon.iron-sword");
    check("items.equip",
        worn.ok && worn.value.slot == "weapon"
        && RpgcItems.equipped(set, "weapon") == "weapon.iron-sword"
        && RpgcItems.countOf(equipBag, "weapon.iron-sword") == 1,
        Rpgc.summary(worn));
    // A swap puts the previous stack back into the slot the new one came from,
    // so it can never need room the bag did not already have.
    local swap = RpgcItems.equip(equipBag, set, config, "weapon.iron-sword");
    check("items.equip-swap-returns-previous",
        swap.ok && swap.value.replaced == "weapon.iron-sword"
        && RpgcItems.countOf(equipBag, "weapon.iron-sword") == 1,
        "replaced='" + swap.value.replaced + "'");

    local materialBag = RpgcItems.newBag(2, "material");
    RpgcItems.add(materialBag, config, "material.pelt", 1);
    local notGear = RpgcItems.equip(materialBag, set, config, "material.pelt");
    check("items.not-equipment",
        !notGear.ok && hasCode(notGear.diagnostics, "items.not-equipment"),
        "got [" + codesOf(notGear.diagnostics) + "]");
    local notHeld = RpgcItems.equip(materialBag, set, config, "armor.leather");
    check("items.not-held", !notHeld.ok && hasCode(notHeld.diagnostics, "items.not-held"),
        "got [" + codesOf(notHeld.diagnostics) + "]");

    // A set built from anything but `rules.equipmentSlots` is a set whose names
    // the gate has never seen; the runtime refuses rather than inventing a slot.
    local narrow = {};
    narrow.rawset("id", "narrow");
    narrow.rawset("order", []);
    narrow.rawset("slots", {});
    RpgcItems.defineSlot(narrow, "armor");
    local wrongSlot = RpgcItems.equip(equipBag, narrow, config, "weapon.iron-sword");
    check("items.unknown-slot",
        !wrongSlot.ok && hasCode(wrongSlot.diagnostics, "items.unknown-slot"),
        "got [" + codesOf(wrongSlot.diagnostics) + "]");

    local off = RpgcItems.unequip(equipBag, set, config, "weapon");
    check("items.unequip",
        off.ok && off.value.moved == 1 && off.value.kept == 0
        && RpgcItems.equipped(set, "weapon") == ""
        && RpgcItems.countOf(equipBag, "weapon.iron-sword") == 2,
        Rpgc.summary(off));
    local emptySlot = RpgcItems.unequip(equipBag, set, config, "weapon");
    check("items.slot-empty",
        !emptySlot.ok && hasCode(emptySlot.diagnostics, "items.slot-empty"),
        "got [" + codesOf(emptySlot.diagnostics) + "]");

    // --- the equipment maths (`computeAttributeValue`) --------------------
    local mathBag = RpgcItems.newBag(4, "math");
    RpgcItems.add(mathBag, config, "weapon.iron-sword", 1);
    RpgcItems.add(mathBag, config, "armor.leather", 1);
    local mathSet = RpgcItems.newEquipmentSet(config, "math");
    RpgcItems.equip(mathBag, mathSet, config, "weapon.iron-sword");
    RpgcItems.equip(mathBag, mathSet, config, "armor.leather");
    local modifiers = RpgcItems.modifiersOf(mathSet, config);
    check("items.modifier-count", modifiers.len() == 2, "got " + modifiers.len());
    check("items.modifier-source", modifiers.len() > 0 && modifiers[0].source == "equip:weapon",
        modifiers.len() > 0 ? modifiers[0].source : "(none)");
    check("items.attribute-add", RpgcItems.attributeValue(30.0, modifiers, "attack") == 38.0,
        "got " + RpgcItems.attributeValue(30.0, modifiers, "attack"));
    check("items.attribute-is-per-attribute",
        RpgcItems.attributeValue(10.0, modifiers, "defense") == 16.0,
        "got " + RpgcItems.attributeValue(10.0, modifiers, "defense"));

    // Composition order: additive, then additive-percent, then multiplicative.
    // `multiply N` is stored by the parser as `N - 1` and means "times N"
    // (AttributeSet.cpp:38-40), which the defence case pins.
    local syntheticItems = {};
    syntheticItems.rawset("probe.gear", probeItemDef({
        id = "probe.gear", category = "weapon", equipSlot = "weapon", maxStack = 1,
        equipStats = [
            { attribute = "attack", op = "add", value = 10, priority = 0 },
            { attribute = "attack", op = "multiplicative_percent", value = 1.0, priority = 0 },
            { attribute = "defense", op = "multiply", value = 2.0, priority = 0 }
        ] }));
    local synthetic = probeItemConfig(syntheticItems, ["weapon", "accessory"]);
    local syntheticSet = RpgcItems.newEquipmentSet(synthetic, "syn");
    local syntheticBag = RpgcItems.newBag(2, "syn");
    RpgcItems.add(syntheticBag, synthetic, "probe.gear", 1);
    RpgcItems.equip(syntheticBag, syntheticSet, synthetic, "probe.gear");
    local gearMods = RpgcItems.modifiersOf(syntheticSet, synthetic);
    check("items.compose-add-then-percent",
        RpgcItems.attributeValue(100.0, gearMods, "attack") == 220.0,
        "got " + RpgcItems.attributeValue(100.0, gearMods, "attack"));
    check("items.multiply-is-a-factor",
        RpgcItems.attributeValue(10.0, gearMods, "defense") == 20.0,
        "got " + RpgcItems.attributeValue(10.0, gearMods, "defense"));

    // Priority order. Insertion order would leave `override 5` first and the
    // clamp would then lift the result to 50; the sort is what makes it 5.
    syntheticItems.rawset("probe.cap", probeItemDef({
        id = "probe.cap", category = "accessory", equipSlot = "accessory", maxStack = 1,
        equipStats = [
            { attribute = "attack", op = "override", value = 5.0, priority = 10 },
            { attribute = "attack", op = "clamp_min", value = 50.0, priority = 1 }
        ] }));
    local capSet = RpgcItems.newEquipmentSet(synthetic, "cap");
    local capBag = RpgcItems.newBag(2, "cap");
    RpgcItems.add(capBag, synthetic, "probe.cap", 1);
    RpgcItems.equip(capBag, capSet, synthetic, "probe.cap");
    local capMods = RpgcItems.modifiersOf(capSet, synthetic);
    check("items.priority-order", RpgcItems.attributeValue(100.0, capMods, "attack") == 5.0,
        "got " + RpgcItems.attributeValue(100.0, capMods, "attack"));

    // The engine's silence: `EquipmentSystem.cpp:73` drops the Result of
    // `addModifier`, so an unknown operation leaves the attribute untouched and
    // says nothing. The runtime mirrors the arithmetic AND reports the typo.
    syntheticItems.rawset("probe.typo", probeItemDef({
        id = "probe.typo", category = "accessory", equipSlot = "accessory", maxStack = 1,
        equipStats = [{ attribute = "attack", op = "mull", value = 99.0, priority = 0 }] }));
    local typoSet = RpgcItems.newEquipmentSet(synthetic, "typo");
    local typoBag = RpgcItems.newBag(2, "typo");
    RpgcItems.add(typoBag, synthetic, "probe.typo", 1);
    RpgcItems.equip(typoBag, typoSet, synthetic, "probe.typo");
    local typoMods = RpgcItems.modifiersOf(typoSet, synthetic);
    check("items.unknown-op-contributes-nothing",
        RpgcItems.attributeValue(7.0, typoMods, "attack") == 7.0,
        "got " + RpgcItems.attributeValue(7.0, typoMods, "attack"));
    check("items.unknown-op-is-reported", RpgcItems.unknownModifiers(typoSet, synthetic).len() == 1,
        "got " + RpgcItems.unknownModifiers(typoSet, synthetic).len());

    // --- consuming --------------------------------------------------------
    local useBag = RpgcItems.newBag(3, "use");
    RpgcItems.add(useBag, config, "potion.heal", 2);
    local used = RpgcItems.use(useBag, config, "potion.heal");
    check("items.use",
        used.ok && used.value.effects.len() == 1 && used.value.effects[0] == "regenerate"
        && used.value.targetType == "allySingle" && used.value.consumed == 1
        && RpgcItems.countOf(useBag, "potion.heal") == 1,
        Rpgc.summary(used));
    local notUsable = RpgcItems.use(useBag, config, "weapon.iron-sword");
    check("items.use-not-usable",
        !notUsable.ok && hasCode(notUsable.diagnostics, "items.not-usable"),
        "got [" + codesOf(notUsable.diagnostics) + "]");
    local gone = RpgcItems.newBag(1, "gone");
    local notHeldUse = RpgcItems.use(gone, config, "potion.heal");
    check("items.use-not-held",
        !notHeldUse.ok && hasCode(notHeldUse.diagnostics, "items.not-held"),
        "got [" + codesOf(notHeldUse.diagnostics) + "]");

    local teaches = RpgcItems.teachesOf(RpgcItems.definitionOf(config, "manual.liuhe-blade"));
    check("items.teaches",
        typeof teaches == "table"
        && Rpgc.asString(Rpgc.get(teaches, "art", "")) == "art.liuhe-blade"
        && Rpgc.asString(Rpgc.get(teaches, "skill", "")) == "skill.liuhe-blade.p1",
        typeof teaches == "table" ? Rpgc.asString(Rpgc.get(teaches, "art", "")) : "(none)");

    // --- loot -------------------------------------------------------------
    local lootBag = RpgcItems.newBag(1, "loot");
    local looted = RpgcItems.applyLoot(lootBag, config, [
        { itemId = "material.pelt", count = 5 },
        { itemId = "weapon.iron-sword", count = 1 }
    ]);
    check("items.loot-placed",
        looted.ok && looted.value.added.len() == 1 && looted.value.added[0].count == 5,
        "added=" + looted.value.added.len());
    // The overflow is the point: `addItem` would return 0 and say nothing, and
    // the reward line would read as if the player had received everything.
    check("items.loot-overflow-reported",
        looted.value.lost.len() == 1 && looted.value.lost[0].itemId == "weapon.iron-sword"
        && looted.value.lost[0].reason == "items.no-slot",
        "lost=" + looted.value.lost.len());

    // --- save -------------------------------------------------------------
    local snapBag = RpgcItems.newBag(4, "snap");
    RpgcItems.add(snapBag, config, "potion.heal", 2);
    RpgcItems.add(snapBag, config, "weapon.iron-sword", 1);
    local snapSet = RpgcItems.newEquipmentSet(config, "snap");
    RpgcItems.equip(snapBag, snapSet, config, "weapon.iron-sword");
    local text = RpgcJson.encodeCompact(RpgcItems.snapshot(snapBag, snapSet));
    local restored = RpgcItems.restore(text, config);
    check("items.snapshot-round-trip",
        restored.ok && RpgcItems.countOf(restored.value.bag, "potion.heal") == 2
        && RpgcItems.equipped(restored.value.equipment, "weapon") == "weapon.iron-sword",
        Rpgc.summary(restored));
    local brokenSnap = RpgcItems.restore(
        "{\"slotCount\":2,\"stacks\":[{\"bagSlot\":0,\"itemId\":\"item.nope\",\"quantity\":1}]}", config);
    check("items.snapshot-unknown-item",
        !brokenSnap.ok && hasCode(brokenSnap.diagnostics, "items.snapshot-item"),
        "got [" + codesOf(brokenSnap.diagnostics) + "]");

    // --- the battle bridge ------------------------------------------------
    local battleBag = RpgcItems.newBag(3, "battle");
    RpgcItems.add(battleBag, config, "potion.heal", 1);
    local commands = RpgcItems.battleCommands(battleBag, config);
    check("items.battle-command",
        commands.len() == 1 && commands[0].id == "command.item:potion.heal"
        && commands[0].targetType == "allySingle" && commands[0].effects[0] == "regenerate",
        commands.len() == 1 ? commands[0].id : "count=" + commands.len());

    local fightConfig = probeFightConfig(0);
    fightConfig.effects.rawset("regenerate", probeEffectDoc("regenerate", 0));
    local fightRead = RpgcBattle.newFight(fightConfig);
    if (check("items.battle-fight", fightRead.ok, Rpgc.summary(fightRead))) {
        local live = fightRead.value;
        local unit = RpgcBattle.unitOf(live, live.pending);
        local pendingBefore = live.pending;
        local roundBefore = live.round;

        local noEffect = {};
        noEffect.rawset("itemId", "potion.heal");
        noEffect.rawset("label", "金创药");
        noEffect.rawset("targetType", "self");
        noEffect.rawset("target", unit.id);
        noEffect.rawset("effects", []);
        local refusedOrder = RpgcBattle.submitItemCommand(live, noEffect);
        check("items.battle-no-effect",
            !refusedOrder.ok && hasCode(refusedOrder.diagnostics, "battle.item-no-effect"),
            "got [" + codesOf(refusedOrder.diagnostics) + "]");
        // A refused order must leave the fight exactly as it was, or asking
        // again is not the same question.
        check("items.battle-refusal-keeps-turn", live.pending == pendingBefore,
            "pending moved during a refused order");

        local order = {};
        order.rawset("itemId", "potion.heal");
        order.rawset("label", "金创药");
        order.rawset("targetType", "self");
        order.rawset("target", unit.id);
        order.rawset("effects", ["regenerate"]);
        local done = RpgcBattle.submitItemCommand(live, order);
        check("items.battle-submits", done.ok, Rpgc.summary(done));
        check("items.battle-status-applied", unit.effects.len() == 1,
            "effects=" + unit.effects.len());
        // The machine moved: with one ally and one enemy the enemy's turn runs
        // inside `advanceTurn`, so `pending` can come back to the same unit --
        // the round counter is what proves the turn was actually spent.
        check("items.battle-turn-spent",
            live.pending != pendingBefore || live.round > roundBefore || live.outcome != "",
            "pending=" + live.pending + " round=" + live.round + " outcome=" + live.outcome);
    }

    // --- the opening bag is a gate fact too -------------------------------
    //
    // `main.nut` seeds its bag from the shipped roster at start-up, and a row
    // that cannot be placed only prints a warning there. So the same seeding is
    // replayed here, against the real document, where a failure is a failure.
    local shipped = RpgcProject.loadById("party", "party.default");
    if (check("items.starting-party-loads", shipped.ok, Rpgc.summary(shipped))) {
        local seedBag = RpgcItems.newBag(RpgcItems.defaultBagSlots, "seed");
        local rows = Rpgc.get(shipped.value, "startingItems", []);
        local unknown = 0;
        local refused = 0;
        foreach (row in rows) {
            local itemId = Rpgc.asString(Rpgc.get(row, "itemId", ""));
            local count = Rpgc.asInt(Rpgc.get(row, "count", 0));
            if (RpgcItems.definitionOf(config, itemId) == 0) unknown += 1;
            local placed = RpgcItems.add(seedBag, config, itemId, count);
            if (!placed.ok || placed.value.added < count) refused += 1;
        }
        check("items.starting-kit-resolves", rows.len() > 0 && unknown == 0,
            rows.len() + " row(s), " + unknown + " unknown item(s)");
        check("items.starting-kit-fits", refused == 0,
            refused + " row(s) did not fit in " + RpgcItems.defaultBagSlots + " slots");
    }

    local duplicateStart = probePartyDoc([probePartyMember(0)], {
        startingItems = [
            { itemId = "potion.heal", count = 1 },
            { itemId = "potion.heal", count = 2 }
        ] });
    expectSemantic("party-starting-item-duplicate", "party", duplicateStart,
        "systems.party-starting-item-duplicate");

    local badStart = probePartyDoc([probePartyMember(0)], {
        startingItems = [{ itemId = "not a stable id", count = 1 }] });
    expectSemantic("party-starting-item-id", "party", badStart,
        "systems.party-starting-item-id");

    // `count >= 1` is the schema's `minimum`, so the semantic gate deliberately
    // does not repeat it and the probe pins the layer that actually fires --
    // the same shape as the item `maxStack` probe above.
    local zeroStart = probePartyDoc([probePartyMember(0)], {
        startingItems = [{ itemId = "potion.heal", count = 0 }] });
    expectSemantic("party-starting-item-count", "party", zeroStart, "validate.schema");

    // Layer 3 must see the new field: `RpgcSystems.references` is the exact
    // function `RpgcValidate.validateReferences` walks.
    local refs = RpgcSystems.references(duplicateStart);
    local sawItem = false;
    foreach (ref in refs) if (ref.kind == "item" && ref.id == "potion.heal") sawItem = true;
    check("items.starting-item-is-a-reference", sawItem,
        "references() returned " + refs.len() + " entr(ies)");
}

checkBattleArithmetic();
checkBattleChain();
checkBattleFlow();
checkBattleContent();
checkPartyGate();
checkItemSystem();

checkFolderProbes();

print("[modules] " + (failures == 0 ? "PASS" : "FAIL") + " (" + failures + " failure(s))\n");
