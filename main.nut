// Default `eve run .` entry: play the authored maps.
//
// Editors stay under `apps/{tilemap,skill,event}`. This file is the runtime
// adapter described in docs/04-runtime-integration.md: documents remain the
// source of truth, and this script only projects them into Map / Pathfinder.

// The toolchain this adapter uses. `import` rather than `dofile`: a module has
// a private environment and is instantiated once per generation, so there is no
// load-order list to keep in sync, no root-table slot to collide with, and the
// dependency graph tells a hot reload what a `lib/` edit affects.
//
// `load.nut` still loads this file with `dofile("main.nut")`. That path now
// compiles through ScriptCompiler and instantiates `import`s before running
// (`src/modules/filesystem/physfs/FileApi.cpp`), so a game entry can be the
// first script to import.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcTilemap } from "game:/lib/rpgc_tilemap.nut"
import { RpgcBattle } from "game:/lib/rpgc_battle.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"

// The only copy of the roster id: the fight and the opening bag must read the
// same document, or the player owns items the party they fight with never got.
const PARTY_ID = "party.default";

persist worldMapId = "village-outskirts"
persist playerX = -1
persist playerY = -1
persist facingX = 1
persist facingY = 0
persist gold = 0
persist hudBuilt = false
persist previousKeys = {}
persist previousMouseDown = false
// The bag survives a hot reload as a JSON snapshot rather than as a live table:
// `RpgcItems.snapshot` is the same shape the engine's InventorySaveSession keeps
// for its own Bag/EquipmentSet pair, so this is the save format the game would
// ship, exercised on every reload instead of only in a test.
persist bagSnapshot = ""
persist bagOpen = false

worldLayer <- null
worldPath <- null
camera <- null
atlasByGid <- {}
consumed <- {}
switches <- {}
variables <- {}
statusText <- ""
statusTimer <- 0.0
activePath <- null
pathIndex <- 0
stepClock <- 0.0
onPortal <- false
objectContract <- ""
eventDocs <- []

// Battle state. `null` means the overworld is live; anything else means the
// fight owns the frame. None of it is `persist`: a battle is a moment, not a
// save-worthy fact, and reloading the script mid-fight should drop it.
battleFight <- null
battleExtra <- ""
battleBackground <- null
battleBackgroundPath <- ""
battleKeys <- {}

// Item state. `null` means the item documents did not load, and every caller
// checks: a missing content tree must not turn a potion into a crash.
itemsConfig <- null
itemBag <- null
itemEquip <- null

const START_MAP = "village-outskirts";
const STEP_SECONDS = 0.16;
const INTERACT_RANGE = 1;
// Packed overworld art is 128×64; isometric pitch is 256×128 (`renderSpacing`
// [2, 2]). Stretch visuals to fill the diamond. Camera zoom stays 1 — stacking
// zoom 2 on top of this scale made every tile four times native size.
const TILE_VISUAL_SCALE = 2.0;
const CAMERA_ZOOM = 1.0;

function say(text) {
    statusText = "" + text;
    statusTimer = 4.0;
    print("[rpgc] " + statusText + "\n");
}

function keyPressed(name) {
    local down = keyboard.isDown(name);
    local wasDown = (name in previousKeys) ? previousKeys[name] : false;
    previousKeys[name] <- down;
    return down && !wasDown;
}

function asInt(text, fallback) {
    local kind = typeof text;
    if (kind == "integer") return text;
    if (kind == "float") return text.tointeger();
    local raw = "" + text;
    local n = raw.tointeger();
    if (raw == "" + n) return n;
    return fallback;
}

function mapPath(mapId) {
    return "content/maps/" + mapId + ".json";
}

function consumedKey(mapId, name) {
    return mapId + "/" + name;
}

function loadObjectContract() {
    objectContract = eve.Filesystem().readText("data/world-object-contract.json");
    if (objectContract == "") throw "rpgc: missing data/world-object-contract.json";
}

function loadAtlasWalkRules(mapDocPath) {
    atlasByGid = {};
    local mapText = eve.Filesystem().readText(mapDocPath);
    local parsed = RpgcJson.parse(mapText);
    if (!parsed.ok) return;
    local tilesets = Rpgc.get(parsed.value, "tilesets", []);
    if (tilesets.len() == 0) return;
    local source = Rpgc.asString(Rpgc.get(tilesets[0], "source", ""));
    if (source == "") return;
    local atlasPath = "content/tilesets/" + Rpgc.stem(source) + ".json";
    local cut = source.find("tilesets/");
    if (cut != null) atlasPath = "content/" + source.slice(cut);
    local atlasText = eve.Filesystem().readText(atlasPath);
    local atlas = RpgcJson.parse(atlasText);
    if (!atlas.ok) return;
    // `tilesOf` handles both shapes: an explicit `tiles[]` (version 1, and the
    // `*.baked.json` the engine loader needs) and a version-2 rule document, in
    // which case the per-GID records are replayed from the grid and size runs.
    foreach (tile in RpgcTilemap.tilesOf(atlas.value)) {
        local gid = asInt(Rpgc.get(tile, "gid", 0), 0);
        if (gid <= 0) continue;
        atlasByGid["" + gid] <- {
            walkable = Rpgc.get(tile, "walkable", true) ? true : false,
            cost = Rpgc.get(tile, "cost", 1.0)
        };
    }
}

function applyNavigation(layer, pathfinder) {
    pathfinder.setDiagonal(false);
    pathfinder.setBlockEmpty(true);
    foreach (key, tile in atlasByGid) {
        if (!tile.walkable) pathfinder.blockGid(key.tointeger());
    }
    pathfinder.syncFromLayer();
    local w = layer.getMapWidth();
    local h = layer.getMapHeight();
    for (local y = 0; y < h; y += 1) {
        for (local x = 0; x < w; x += 1) {
            local gid = layer.getTile(x, y);
            local key = "" + gid;
            if (key in atlasByGid) {
                local info = atlasByGid[key];
                if (info.walkable) pathfinder.setCellCost(x, y, info.cost * 1.0);
            }
        }
    }
}

function objectTile(index) {
    local wx = map.getObjectX(index);
    local wy = map.getObjectY(index);
    return {
        x = worldLayer.worldToTileX(wx, wy),
        y = worldLayer.worldToTileY(wx, wy),
        wx = wx,
        wy = wy
    };
}

function findSpawnTile() {
    local spawn = map.findObjectByName("spawn");
    if (spawn >= 0) {
        local cell = objectTile(spawn);
        if (worldPath.isWalkable(cell.x, cell.y)) return cell;
    }
    local w = worldLayer.getMapWidth();
    local h = worldLayer.getMapHeight();
    for (local y = 0; y < h; y += 1) {
        for (local x = 0; x < w; x += 1) {
            if (worldPath.isWalkable(x, y)) return { x = x, y = y, wx = 0, wy = 0 };
        }
    }
    return { x = 0, y = 0, wx = 0, wy = 0 };
}

function bindCamera() {
    if (camera == null) {
        camera = eve.Camera2D();
        camera.setZoom(CAMERA_ZOOM);
        camera.setAmbient(0.18, 0.20, 0.24);
    }
    for (local i = 0; i < map.getLayerCount(); i += 1) {
        local layer = map.getLayer(i);
        if (layer != null) {
            layer.setCamera(camera);
            layer.setVisualScale(TILE_VISUAL_SCALE, TILE_VISUAL_SCALE);
        }
    }
}

function followCamera() {
    if (worldLayer == null || camera == null) return;
    local wx = worldLayer.tileToWorldX(playerX, playerY);
    local wy = worldLayer.tileToWorldY(playerX, playerY) + worldLayer.getTileHeight() * 0.5;
    camera.setPosition(wx, wy);
}

function loadWorldMap(mapId, x, y, fx, fy) {
    local path = mapPath(mapId);
    if (eve.Filesystem().readText(path) == "") return false;
    loadAtlasWalkRules(path);
    local admitted = map.loadFromFileWithObjectContract(path, objectContract);
    if (!admitted.ok) {
        print("rpgc: map rejected " + path + ": " + admitted.status.summary + "\n");
        return false;
    }
    local layer = map.getLayer(0);
    if (layer == null) return false;
    local pathfinder = map.newPathfinder(layer);
    if (pathfinder == null) return false;
    applyNavigation(layer, pathfinder);
    worldLayer = layer;
    worldPath = pathfinder;
    worldMapId = mapId;
    bindCamera();
    local spawn = findSpawnTile();
    if (x < 0 || y < 0 || !pathfinder.isWalkable(x, y)) {
        playerX = spawn.x;
        playerY = spawn.y;
    } else {
        playerX = x;
        playerY = y;
    }
    facingX = fx;
    facingY = fy;
    activePath = null;
    pathIndex = 0;
    onPortal = false;
    followCamera();
    return true;
}

function chebyshev(ax, ay, bx, by) {
    local dx = ax - bx;
    if (dx < 0) dx = -dx;
    local dy = ay - by;
    if (dy < 0) dy = -dy;
    return dx > dy ? dx : dy;
}

function nearestObject(maxRange) {
    local best = -1;
    local bestDist = maxRange + 1;
    for (local i = 0; i < map.getObjectCount(); i += 1) {
        local kind = map.getObjectType(i);
        if (kind == "spawn") continue;
        local cell = objectTile(i);
        local dist = chebyshev(playerX, playerY, cell.x, cell.y);
        if (dist <= maxRange && dist < bestDist) {
            best = i;
            bestDist = dist;
        }
    }
    return best;
}

function objectAtPlayer() {
    for (local i = 0; i < map.getObjectCount(); i += 1) {
        local cell = objectTile(i);
        if (cell.x == playerX && cell.y == playerY) return i;
    }
    return -1;
}

function loadEventDocs() {
    eventDocs = [];
    local names = ["content/events/mist-forest.arrival.json", "content/events/village.elder-offer.json"];
    foreach (path in names) {
        local text = eve.Filesystem().readText(path);
        if (text == "") continue;
        local parsed = RpgcJson.parse(text);
        if (parsed.ok) eventDocs.append(parsed.value);
    }
}

function conditionHolds(condition) {
    if (condition == null) return true;
    local kind = Rpgc.get(condition, "kind", "");
    if (kind == "switch") {
        local name = Rpgc.asString(Rpgc.get(condition, "name", ""));
        return (name in switches) ? switches[name] : false;
    }
    if (kind == "variable") {
        local name = Rpgc.asString(Rpgc.get(condition, "name", ""));
        local have = name == "gold" ? gold : ((name in variables) ? variables[name] : 0);
        local want = Rpgc.get(condition, "value", 0);
        local cmp = Rpgc.asString(Rpgc.get(condition, "compare", "eq"));
        if (cmp == "gte") return have >= want;
        if (cmp == "lte") return have <= want;
        if (cmp == "gt") return have > want;
        if (cmp == "lt") return have < want;
        return have == want;
    }
    return false;
}

function applyVariable(step) {
    local name = Rpgc.asString(Rpgc.get(step, "name", ""));
    local op = Rpgc.asString(Rpgc.get(step, "op", "set"));
    local value = Rpgc.get(step, "value", 0);
    if (op == "switchOn") {
        switches[name] <- true;
        return;
    }
    if (op == "switchOff") {
        switches[name] <- false;
        return;
    }
    local current = name == "gold" ? gold : ((name in variables) ? variables[name] : 0);
    if (op == "add") current += value;
    else if (op == "sub") current -= value;
    else current = value;
    if (name == "gold") gold = current;
    else variables[name] <- current;
}

function runSteps(steps) {
    foreach (step in steps) {
        local kind = Rpgc.asString(Rpgc.get(step, "kind", ""));
        if (kind == "load_map") {
            loadWorldMap(Rpgc.asString(Rpgc.get(step, "mapId", "")),
                         asInt(Rpgc.get(step, "x", 0), 0),
                         asInt(Rpgc.get(step, "y", 0), 0),
                         facingX, facingY);
        } else if (kind == "wait") {
            // Instant in this adapter; the HUD already shows the last message.
        } else if (kind == "camera_focus" || kind == "camera_pan") {
            if (camera != null) {
                camera.setPosition(Rpgc.get(step, "x", camera.getX()), Rpgc.get(step, "y", camera.getY()));
                if (Rpgc.has(step, "zoom")) camera.setZoom(Rpgc.get(step, "zoom", 1.0));
            }
        } else if (kind == "message") {
            say(Rpgc.asString(Rpgc.get(step, "reference", "")));
        } else if (kind == "dialogue") {
            say(Rpgc.asString(Rpgc.get(step, "reference", "dialogue")));
        } else if (kind == "set_variable") {
            applyVariable(step);
        } else if (kind == "face_actor") {
            if (Rpgc.asString(Rpgc.get(step, "actorId", "")) == "player") {
                facingX = asInt(Rpgc.get(step, "facingX", facingX), facingX);
                facingY = asInt(Rpgc.get(step, "facingY", facingY), facingY);
            }
        } else if (kind == "play_animation") {
            // hero.png is a documented placeholder; skip playback.
        } else if (kind == "parallel") {
            runSteps(Rpgc.get(step, "steps", []));
        } else if (kind == "branch") {
            if (conditionHolds(Rpgc.get(step, "condition", null)))
                runSteps(Rpgc.get(step, "then", []));
            else
                runSteps(Rpgc.get(step, "else", []));
        }
    }
}

function runEventDoc(doc) {
    say(Rpgc.asString(Rpgc.get(doc, "title", Rpgc.get(doc, "id", "event"))));
    runSteps(Rpgc.get(doc, "steps", []));
}

function matchingEvent(triggerKind, extra) {
    foreach (doc in eventDocs) {
        local trigger = Rpgc.get(doc, "trigger", {});
        if (Rpgc.asString(Rpgc.get(trigger, "kind", "")) != triggerKind) continue;
        if (Rpgc.asString(Rpgc.get(trigger, "mapId", "")) != worldMapId) continue;
        if (triggerKind == "portal_entered") {
            if (Rpgc.asString(Rpgc.get(trigger, "targetMap", "")) != extra) continue;
        } else if (triggerKind == "object_interacted") {
            if (Rpgc.asString(Rpgc.get(trigger, "objectName", "")) != extra) continue;
        }
        return doc;
    }
    return null;
}

function enterPortal(index) {
    local targetMap = map.getObjectProperty(index, "targetMap", "");
    local event = matchingEvent("portal_entered", targetMap);
    if (event != null) {
        runEventDoc(event);
        return;
    }
    loadWorldMap(targetMap,
                 asInt(map.getObjectProperty(index, "targetX", "0"), 0),
                 asInt(map.getObjectProperty(index, "targetY", "0"), 0),
                 asInt(map.getObjectProperty(index, "facingX", "1"), 1),
                 asInt(map.getObjectProperty(index, "facingY", "0"), 0));
    say("进入 " + targetMap);
}

function interactObject(index) {
    if (index < 0) {
        say("附近没有可互动的对象");
        return;
    }
    local kind = map.getObjectType(index);
    local name = map.getObjectName(index);
    if (kind == "portal") {
        enterPortal(index);
        return;
    }
    if (kind == "npc") {
        local event = matchingEvent("object_interacted", name);
        if (event != null) {
            runEventDoc(event);
            return;
        }
        say(map.getObjectProperty(index, "speaker", name) + "：" + map.getObjectProperty(index, "dialogue", ""));
        return;
    }
    if (kind == "chest") {
        local key = consumedKey(worldMapId, name);
        if (key in consumed) {
            say("箱子是空的");
            return;
        }
        local amount = asInt(map.getObjectProperty(index, "gold", "0"), 0);
        gold += amount;
        consumed[key] <- true;
        say("获得 " + map.getObjectProperty(index, "itemId", "item") + " 和 " + amount + " 金币");
        return;
    }
    say(name);
}

function tryMove(dx, dy) {
    if (dx == 0 && dy == 0) return;
    local nx = playerX + dx;
    local ny = playerY + dy;
    if (!worldPath.isWalkable(nx, ny)) {
        say("无法通行");
        return;
    }
    playerX = nx;
    playerY = ny;
    facingX = dx;
    facingY = dy;
    activePath = null;
    followCamera();
}

function requestPath(tx, ty) {
    if (!worldPath.isWalkable(tx, ty)) {
        say("目标无法通行");
        return;
    }
    activePath = worldPath.findPath(playerX, playerY, tx, ty);
    pathIndex = (activePath != null && activePath.getLength() > 1) ? 1 : 0;
    stepClock = 0.0;
    if (activePath == null || activePath.getLength() == 0) say("没有路线");
}

function refreshHud() {
    if (!hudBuilt) return;
    ui.select("hud");
    if (battleFight != null) {
        ui.setText("area", battleHeader());
        ui.setText("help", battleHelp());
        ui.setText("battle", battleRoster());
        ui.setText("items", "");
        ui.setText("status", statusText);
        return;
    }
    if (bagOpen) {
        ui.setText("area", bagSummary());
        ui.setText("help", "1..9 装备 / 查看 · I 关闭背包");
        ui.setText("battle", "");
        ui.setText("items", bagPanelText() + "\n装备：" + equipSummary());
        ui.setText("status", statusText);
        return;
    }
    ui.setText("area", worldMapId + "  (" + playerX + "," + playerY + ")  金币 " + gold);
    ui.setText("battle", "");
    ui.setText("items", "");
    ui.setText("status", statusText);
}

// --------------------------------------------------------------------- items
//
// The runtime half of docs/08-items-and-equipment.md. The documents stay the
// source of truth and `RpgcItems` owns the arithmetic; this file owns the screen,
// the keyboard, and the three moments where a bag changes: start-up, loot, and
// a player using or wearing something.
//
// Nothing here calls the engine's inventory module, because this build does not
// bind it (`cmake/module_manifest/core_foundation.cmake:105` declares `inventory`
// with no SLOT, so `eve.Inventory` is not on the `eve` table at all --
// tools/modules_check.nut asserts that). docs/08 §7 used to show
// `eve.Inventory().registerItemsFromJson(...)`; that call cannot run here.

function setupItems() {
    local loaded = RpgcItems.loadProject();
    if (!loaded.ok) {
        itemsConfig = null;
        itemBag = null;
        itemEquip = null;
        print("[rpgc] warn: item documents did not load: " + Rpgc.summary(loaded) + "\n");
        return false;
    }
    itemsConfig = loaded.value;
    itemEquip = RpgcItems.newEquipmentSet(itemsConfig, "party");

    if (bagSnapshot != "") {
        local restored = RpgcItems.restore(bagSnapshot, itemsConfig);
        if (restored.ok) {
            itemBag = restored.value.bag;
            itemEquip = restored.value.equipment;
            return true;
        }
        // A snapshot that no longer matches the content tree is refused rather
        // than half-applied (`RpgcItems.restore` never leaves a partial bag), so
        // the fallback is a fresh bag and a loud line, not a silent reset.
        print("[rpgc] warn: bag snapshot rejected: " + Rpgc.summary(restored) + "\n");
    }

    itemBag = RpgcItems.newBag(RpgcItems.defaultBagSlots, "party");
    local party = RpgcProject.loadById("party", PARTY_ID);
    if (party.ok) {
        foreach (row in Rpgc.get(party.value, "startingItems", [])) {
            local itemId = Rpgc.asString(Rpgc.get(row, "itemId", ""));
            local count = Rpgc.asInt(Rpgc.get(row, "count", 0));
            if (itemId == "" || count <= 0) continue;
            local placed = RpgcItems.add(itemBag, itemsConfig, itemId, count);
            if (!placed.ok || placed.value.added < count) {
                // The opening kit does not fit the bag, which is a content
                // mistake the gate cannot see (it has no slot count). Reported
                // instead of silently dropping the difference.
                print("[rpgc] warn: starting item '" + itemId + "' only partly placed\n");
            }
        }
    }
    saveBag();
    return true;
}

// Persist the bag as the snapshot the next start-up reads back. Called after
// every mutation, so a hot reload can never lose a potion the player just used.
function saveBag() {
    if (itemBag == null || itemEquip == null) return;
    bagSnapshot = RpgcJson.encodeCompact(RpgcItems.snapshot(itemBag, itemEquip));
}

function bagRows() {
    if (itemBag == null || itemsConfig == null) return [];
    return RpgcItems.entries(itemBag, itemsConfig);
}

function bagSummary() {
    if (itemBag == null) return "物品系统不可用";
    return "背包 " + RpgcItems.usedSlots(itemBag) + "/" + itemBag.slots.len() + " 格 · 重 "
        + RpgcItems.usedWeight(itemBag, itemsConfig) + " · 金币 " + gold;
}

function equipSummary() {
    if (itemEquip == null) return "";
    local parts = [];
    foreach (slot in itemEquip.order) {
        local itemId = RpgcItems.equipped(itemEquip, slot);
        if (itemId != "") parts.append(slot + "=" + itemId);
    }
    return parts.len() == 0 ? "未装备" : Rpgc.joinList(parts, " ");
}

function bagPanelText() {
    local rows = bagRows();
    if (rows.len() == 0) return "背包是空的。";
    local lines = [];
    for (local i = 0; i < rows.len() && i < 9; i += 1) {
        local row = rows[i];
        local suffix = "";
        if (row.equipment) {
            suffix = "  [装备 " + RpgcItems.slotOf(RpgcItems.definitionOf(itemsConfig, row.itemId)) + "]";
        } else if (row.usable) {
            suffix = "  [战斗中用]";
        }
        lines.append("" + (i + 1) + "  " + row.displayName + "×" + row.quantity + suffix);
    }
    if (rows.len() > 9) lines.append("…还有 " + (rows.len() - 9) + " 行");
    return Rpgc.joinList(lines, "\n");
}

// The overworld bag does exactly two things, and refusing the third is the
// design: a `use.effects` list is applied by `RpgcBattle.applyEffect`, which
// needs a fight. Drinking a potion in a town would consume it and do nothing,
// so the panel says so instead.
function bagAct(index) {
    local rows = bagRows();
    if (index < 0 || index >= rows.len()) return false;
    local row = rows[index];
    local def = RpgcItems.definitionOf(itemsConfig, row.itemId);
    if (def != 0 && RpgcItems.isEquipment(def)) {
        local equipped = RpgcItems.equip(itemBag, itemEquip, itemsConfig, row.itemId);
        if (!equipped.ok) {
            say("装备不了：" + Rpgc.summary(equipped));
            return false;
        }
        saveBag();
        say("装备 " + row.displayName + " → " + equipped.value.slot
            + (equipped.value.replaced == "" ? "" : "（换下 " + equipped.value.replaced + "）"));
        return true;
    }
    if (row.usable) {
        say("「" + row.displayName + "」要在战斗里用（开战后按对应数字键）。");
        return false;
    }
    say("「" + row.displayName + "」现在用不了。");
    return false;
}

// ------------------------------------------------------------------- battle
//
// The runtime half of docs/10-battle-scene.md and docs/11-battle-system.md: the
// documents stay the source of truth and everything here is a projection of
// them. `RpgcBattle` owns the rules and the state machine; this file owns the
// screen, the keyboard and the two lines of glue that start and end a fight.
//
// The encounter is chosen by MAP, not by a map object: this workflow deliberately
// models no "step on it and fight" object type (docs/09 §7), and every map has
// exactly one encounter gated against it (`systems.encounter-without-battle`).
// Pressing B is therefore the whole of the trigger -- an explicit gesture rather
// than an invisible one.

function encounterForMap(mapId) {
    foreach (id in RpgcProject.idsOf("encounter")) {
        local read = RpgcProject.loadById("encounter", id);
        if (!read.ok) continue;
        if (Rpgc.asString(Rpgc.get(read.value, "map", "")) == mapId) return id;
    }
    return "";
}

function startBattle() {
    local encounterId = encounterForMap(worldMapId);
    if (encounterId == "") {
        say("这块地方没有遭遇。");
        return;
    }
    local config = RpgcBattle.loadProject(PARTY_ID, encounterId, "");
    if (!config.ok) {
        say("战斗无法开始：" + Rpgc.summary(config));
        return;
    }
    local fight = RpgcBattle.newFight(config.value);
    if (!fight.ok) {
        say("战斗无法开始：" + Rpgc.summary(fight));
        return;
    }
    battleFight = fight.value;
    battleExtra = "";
    battleKeys = {};
    loadBattleBackground();
    statusText = "";
    statusTimer = 0.0;
    print("[rpgc] battle " + encounterId + " on " + worldMapId + "\n");
    refreshHud();
}

function loadBattleBackground() {
    local declared = Rpgc.asString(Rpgc.get(battleFight.battle, "background", ""));
    battleBackground = null;
    battleBackgroundPath = "";
    if (declared == "") return;
    local path = "content/battles/" + Rpgc.normalizePath(declared);
    battleBackgroundPath = path;
    battleBackground = gfx.newTextureFromFile(path);
    if (battleBackground == null) {
        // `newTextureFromFile` swallows a missing file, so a scene would simply
        // stop drawing its backdrop with nothing said anywhere. The editor
        // learned this the same way (docs/10 §6.4).
        print("[rpgc] warn: battle backdrop '" + path + "' failed to load\n");
    }
}

// The ring has one button per `ui.commandRing.buttons` entry and the keyboard
// has nine digits, so the usable command list is capped by whichever is smaller.
// `RpgcSystems.battleUiDiagnostics` caps the ring at `maxBattlePartyBars` keys,
// and the cap is applied HERE rather than to the documents because what fits is
// a property of this adapter's screen, not of the content.
function battleCommandLimit() {
    if (battleFight == null) return 9;
    local ring = Rpgc.get(Rpgc.get(battleFight.battle, "ui", 0), "commandRing", 0);
    if (typeof ring != "table") return 9;
    local buttons = Rpgc.get(ring, "buttons", []).len();
    if (buttons <= 0) return 9;
    return buttons < 9 ? buttons : 9;
}

function battleCommandList() {
    if (battleFight == null) return [];
    local unit = RpgcBattle.unitOf(battleFight, battleFight.pending);
    if (unit == 0) return [];
    local out = [];
    foreach (entry in RpgcBattle.commandsFor(battleFight, unit)) {
        if (entry.id == "command.defend") {
            out.append(entry);
            continue;
        }
        // Only what can be used now gets a key: a refused order still spends the
        // unit's turn in `RpgcBattle.performSkill`'s contract, and a button that
        // silently costs a turn is worse than no button.
        if (entry.ready && entry.affordable) out.append(entry);
    }
    // Consumables come after the moves: a skill is the primary action and an
    // item is the exception. `RpgcItems.battleCommands` carries the effects, so
    // the resolver below never reads an item document.
    if (itemBag != null && itemsConfig != null) {
        foreach (entry in RpgcItems.battleCommands(itemBag, itemsConfig)) out.append(entry);
    }
    local limit = battleCommandLimit();
    if (out.len() > limit) {
        local kept = [];
        for (local i = 0; i < limit; i += 1) kept.append(out[i]);
        return kept;
    }
    return out;
}

// The player picks the move; the target follows the move's own target type, so
// a heal never tries to land on an enemy and a self buff needs no target at all.
function battleDefaultTarget(unit, targetType) {
    if (targetType == "self") return unit.id;
    if (targetType == "allySingle" || targetType == "allyAll") {
        local best = 0;
        local bestFraction = 2.0;
        foreach (candidate in RpgcBattle.livingUnits(battleFight, unit.side)) {
            local fraction = candidate.maxHp > 0.0 ? candidate.hp / candidate.maxHp : 1.0;
            if (fraction < bestFraction) {
                best = candidate;
                bestFraction = fraction;
            }
        }
        return best == 0 ? "" : best.id;
    }
    return RpgcBattle.pickTarget(battleFight, unit);
}

function battleAct(index) {
    local unit = RpgcBattle.unitOf(battleFight, battleFight.pending);
    if (unit == 0) return false;
    local commands = battleCommandList();
    if (index < 0 || index >= commands.len()) return false;
    local chosen = commands[index];
    if (chosen.id == "command.defend") {
        RpgcBattle.submitCommand(battleFight, { skill = "command.defend", target = "" });
        return true;
    }
    // An item order is submitted BEFORE the item leaves the bag: the resolver
    // refuses an illegal target without spending anything, and a bag mutation
    // first would make a refused order cost a potion. The order carries its own
    // effects, so `RpgcBattle` never has to know what an item is.
    if (chosen.id.find("command.item:") == 0) {
        local order = {};
        order.itemId <- chosen.itemId;
        order.label <- chosen.label;
        order.targetType <- chosen.targetType;
        order.target <- battleDefaultTarget(unit, chosen.targetType);
        order.effects <- chosen.effects;
        local done = RpgcBattle.submitItemCommand(battleFight, order);
        if (!done.ok) {
            battleExtra = Rpgc.summary(done);
            return false;
        }
        local used = RpgcItems.use(itemBag, itemsConfig, chosen.itemId);
        if (used.ok) {
            saveBag();
            battleExtra = used.value.displayName + " → " + Rpgc.joinList(used.value.effects, "、");
        }
        return true;
    }
    local target = battleDefaultTarget(unit, chosen.targetType);
    RpgcBattle.submitCommand(battleFight, { skill = chosen.id, target = target });
    return true;
}

function drainBattleEvents() {
    foreach (event in RpgcBattle.takeEvents(battleFight)) {
        if (event.kind == "broken") {
            battleExtra = "破绽被击穿！";
        }
    }
}

function updateBattle(dt) {
    if (battleFight == null) return;
    drainBattleEvents();

    if (battleFight.outcome != "") {
        finishBattle();
        return;
    }
    local commands = battleCommandList();
    for (local i = 0; i < commands.len() && i < 9; i += 1) {
        local key = "" + (i + 1);
        if (!keyPressed(key)) continue;
        battleExtra = "";
        battleAct(i);
        drainBattleEvents();
        break;
    }
    if (keyPressed("q") || keyPressed("Q")) {
        RpgcBattle.runToEnd(battleFight, 400);
        drainBattleEvents();
    }
    if (battleFight.outcome != "") finishBattle();
}

// Rewards are applied to the overworld here and only here: the fight reports, the
// game decides (docs/11 §6). XP has nowhere to go yet -- this workflow models no
// level curve -- so it is reported rather than spent, which is the honest shape.
function finishBattle() {
    local settled = RpgcBattle.settlement(battleFight);
    local line = "";
    if (settled.outcome == "victory") {
        gold += settled.gold;
        line = "胜利（" + settled.rounds + " 回合） +" + settled.gold + " 金币";
        // The drops go INTO the bag here. Before the bag existed this line
        // printed the ids and the items evaporated -- the settlement reported
        // them, nothing held them, and the screen made it look like a reward.
        if (itemBag != null && itemsConfig != null) {
            local placed = RpgcItems.applyLoot(itemBag, itemsConfig, settled.loot);
            foreach (entry in placed.value.added) {
                line += "、" + entry.itemId + "×" + entry.count;
            }
            foreach (entry in placed.value.lost) {
                // `addItem` returns a partial count and says nothing, so a full
                // bag would otherwise read as a full reward.
                line += "（" + entry.itemId + "×" + entry.count + " 放不下）";
            }
            saveBag();
        } else {
            foreach (entry in settled.loot) line += "、" + entry.itemId + "×" + entry.count;
        }
    } else if (settled.outcome == "defeat") {
        line = "我方全灭。退回 " + worldMapId + "。";
    } else {
        line = "战斗以「" + settled.outcome + "」结束。";
    }
    print("[rpgc] battle outcome=" + settled.outcome + " rounds=" + settled.rounds
        + " gold=" + settled.gold + "\n");
    battleFight = null;
    battleExtra = "";
    battleBackground = null;
    battleBackgroundPath = "";
    say(line);
    refreshHud();
}

function battleHeader() {
    if (battleFight == null) return "";
    local encounter = battleFight.encounter;
    return "战斗 · " + Rpgc.asString(Rpgc.get(encounter, "displayName", "遭遇"))
        + " · 第 " + battleFight.round + " 回合"
        + (battleExtra == "" ? "" : "   " + battleExtra);
}

function battleHelp() {
    if (battleFight == null) return "";
    local commands = battleCommandList();
    if (commands.len() == 0) return "……";
    local parts = [];
    for (local i = 0; i < commands.len() && i < 9; i += 1) {
        parts.append((i + 1) + "=" + commands[i].label);
    }
    return Rpgc.joinList(parts, "  ") + "   Q=自动打完";
}

function battleRoster() {
    if (battleFight == null) return "";
    local lines = [];
    foreach (unit in battleFight.units) {
        if (unit.side != RpgcBattle.allySide) continue;
        lines.append(unit.displayName + " " + unit.hp.tointeger() + "/"
            + unit.maxHp.tointeger() + " 破绽 " + unit.breakValue + "/" + unit.breakMax
            + (unit.alive ? "" : " [倒]"));
    }
    foreach (unit in battleFight.units) {
        if (unit.side != RpgcBattle.enemySide) continue;
        lines.append(unit.displayName + " " + unit.hp.tointeger() + "/"
            + unit.maxHp.tointeger() + (unit.alive ? "" : (unit.fled ? " [逃]" : " [倒]")));
    }
    return Rpgc.joinList(lines, "\n");
}

// ---------------------------------------------------------------- battle draw

function battleFit() {
    return RpgcBattle.fitToViewport(battleFight.battle,
        gfx.getWidth().tofloat(), gfx.getHeight().tofloat());
}

// Text is optional furniture. `Graphics::drawText` throws on a null font
// (`src/modules/graphics/Graphics.cpp:1735`), and the font belongs to whoever
// loaded one, so the battle screen asks and draws without labels when nobody
// provided it: a HUD that dies because a font is missing is worse than a HUD
// without names.
function hudFont() {
    local font = null;
    try { font = gfx.getFont(); } catch (e) { font = null; }
    return font;
}

function hudText(text, x, y, r, g, b, scale) {
    local font = hudFont();
    if (font == null) return;
    gfx.drawText(font, "" + text, x, y, r, g, b, 1.0, scale);
}

// A 3x5 bitmap face, one row per entry, bit 2 = leftmost column. It exists
// because this workflow ships no font file and the engine's script text path
// needs one (`gfx.getFont()` is null here, and the default charset is ASCII),
// so `hudText` draws nothing and the HUD would show bars without numbers.
// Digits and a slash are all the bars need; a game that installs a real font
// gets names through `hudText` on top of these.
hudGlyphs <- {
    ["0"] = [0x7, 0x5, 0x5, 0x5, 0x7],
    ["1"] = [0x2, 0x6, 0x2, 0x2, 0x7],
    ["2"] = [0x7, 0x1, 0x7, 0x4, 0x7],
    ["3"] = [0x7, 0x1, 0x7, 0x1, 0x7],
    ["4"] = [0x5, 0x5, 0x7, 0x1, 0x1],
    ["5"] = [0x7, 0x4, 0x7, 0x1, 0x7],
    ["6"] = [0x7, 0x4, 0x7, 0x5, 0x7],
    ["7"] = [0x7, 0x1, 0x1, 0x1, 0x1],
    ["8"] = [0x7, 0x5, 0x7, 0x5, 0x7],
    ["9"] = [0x7, 0x5, 0x7, 0x1, 0x7],
    ["/"] = [0x1, 0x1, 0x2, 0x4, 0x4],
    [" "] = [0x0, 0x0, 0x0, 0x0, 0x0]
};

function hudGlyphWidth(height) {
    local pixel = height / 5.0;
    if (pixel < 1.0) pixel = 1.0;
    return pixel;
}

function hudDigits(text, x, y, height, r, g, b, a) {
    local pixel = hudGlyphWidth(height);
    local cursor = x;
    local raw = "" + text;
    for (local i = 0; i < raw.len(); i += 1) {
        local ch = raw.slice(i, i + 1);
        local rows = hudGlyphs.rawin(ch) ? hudGlyphs.rawget(ch) : hudGlyphs[" "];
        for (local row = 0; row < 5; row += 1) {
            for (local col = 0; col < 3; col += 1) {
                if (rows[row] & (4 >> col)) {
                    gfx.drawSolidRect(cursor + col * pixel, y + row * pixel,
                        pixel, pixel, r, g, b, a);
                }
            }
        }
        cursor += 4.0 * pixel;
    }
    return cursor - x;
}

// One readout, two renderers: the game's font when it installed one, the rect
// face otherwise. The caller passes the row's height, not a scale, because the
// two renderers scale differently.
function hudReadout(text, x, y, height, r, g, b) {
    local font = hudFont();
    if (font != null) {
        gfx.drawText(font, "" + text, x, y, r, g, b, 1.0, height / 12.0);
        return;
    }
    hudDigits(text, x, y, height, r, g, b, 1.0);
}

// Four bars, because the script surface has no outline mode. This is also the
// shape that exposed the depth bug: an inner rect drawn after an outer one was
// rejected by the pipeline's default depth test and vanished, so the whole HUD
// painted as one flat plate (docs/11 §5, §9).
function hudFrame(x, y, w, h, thickness, r, g, b, a) {
    if (thickness <= 0.0 || w <= 0.0 || h <= 0.0) return;
    gfx.drawSolidRect(x, y, w, thickness, r, g, b, a);
    gfx.drawSolidRect(x, y + h - thickness, w, thickness, r, g, b, a);
    gfx.drawSolidRect(x, y, thickness, h, r, g, b, a);
    gfx.drawSolidRect(x + w - thickness, y, thickness, h, r, g, b, a);
}

// `hue` arrives in [0,1) so `sector` is in [0,6): truncating is flooring, and
// this build's script environment exposes no `floor` at all.
function hudHsv(hue, saturation, value) {
    local sector = hue * 6.0;
    local index = sector.tointeger();
    local f = sector - index;
    local p = value * (1.0 - saturation);
    local q = value * (1.0 - saturation * f);
    local t = value * (1.0 - saturation * (1.0 - f));
    if (index == 0) return [value, t, p];
    if (index == 1) return [q, value, p];
    if (index == 2) return [p, value, t];
    if (index == 3) return [p, q, value];
    if (index == 4) return [t, p, value];
    return [value, p, q];
}

// An element's colour is its INDEX in `rules.elements`, not a table here: a
// sixth element added to the rule document gets a colour without touching this
// file. The rule document stays the only authority on what the elements are.
function hudElementColour(element) {
    local elements = Rpgc.get(battleFight.rules, "elements", []);
    local count = elements.len();
    for (local i = 0; i < count; i += 1) {
        if (Rpgc.asString(elements[i]) == Rpgc.asString(element))
            return hudHsv(i.tofloat() / count.tofloat(), 0.55, 0.90);
    }
    return [0.42, 0.45, 0.54];
}

function unitAtSlot(side, slot) {
    foreach (unit in battleFight.units) {
        if (unit.side == side && unit.slot == slot) return unit;
    }
    return 0;
}

// The two numbers a character HUD exists to show: how much is left of a pool,
// and how much of it there is. A pool the rule document does not declare has no
// maximum, so it reads 0/0 rather than a plausible-looking lie -- the bar's id
// is checked against /resources by `systems.battle-ui-bar-unregistered`.
function hudPoolCurrent(unit, id) {
    if (id == "hp") return unit.hp;
    return unit.resources.rawin(id) ? unit.resources.rawget(id) : 0.0;
}

function hudPoolMaximum(unit, id) {
    if (id == "hp") return unit.maxHp;
    return unit.resourceMax.rawin(id) ? unit.resourceMax.rawget(id) : 0.0;
}

function drawBattleUnit(unit, fit) {
    local placed = 0;
    foreach (entry in RpgcBattle.placeOnScene(battleFight)) {
        if (entry.unit == unit.id) placed = entry;
    }
    if (placed == 0) return;
    local x = RpgcBattle.toScreenX(fit, placed.x);
    local y = RpgcBattle.toScreenY(fit, placed.y);
    local w = 72.0 * fit.scale;
    local h = 96.0 * fit.scale;

    local r = 0.78;
    local g = 0.30;
    local b = 0.26;
    if (unit.side == RpgcBattle.allySide) {
        r = 0.28;
        g = 0.48;
        b = 0.82;
    }
    if (!unit.alive) {
        r = 0.22;
        g = 0.22;
        b = 0.24;
    }
    if (battleFight.pending == unit.id) {
        gfx.drawSolidRect(x - w * 0.5 - 4.0, y - h - 4.0, w + 8.0, h + 8.0, 1.0, 0.92, 0.35, 1.0);
    }
    gfx.drawSolidRect(x - w * 0.5, y - h, w, h, r, g, b, 1.0);

    // HP bar above the body, break bar under it: the two numbers the fight is
    // actually about. The end-of-turn actor also gets its name above the bar,
    // because "whose turn is it" is the one question the field cannot answer by
    // colour alone.
    local barWidth = w + 24.0;
    local barX = x - barWidth * 0.5;
    local hp = hudPoolMaximum(unit, "hp") > 0.0 ? hudPoolCurrent(unit, "hp") / hudPoolMaximum(unit, "hp") : 0.0;
    gfx.drawSolidRect(barX, y - h - 16.0, barWidth, 8.0, 0.12, 0.12, 0.14, 1.0);
    gfx.drawSolidRect(barX, y - h - 16.0, barWidth * hp, 8.0, 0.34, 0.76, 0.38, 1.0);
    local poise = unit.breakMax > 0 ? unit.breakValue.tofloat() / unit.breakMax.tofloat() : 0.0;
    gfx.drawSolidRect(barX, y + 4.0, barWidth, 6.0, 0.12, 0.12, 0.14, 1.0);
    gfx.drawSolidRect(barX, y + 4.0, barWidth * poise, 6.0, 0.85, 0.68, 0.24, 1.0);

    if (battleFight.pending != 0 && battleFight.pending == unit.id) {
        hudText(unit.displayName, barX, y - h - 40.0, 1.0, 0.94, 0.62, fit.scale * 1.2);
    }
}

function drawBattleHud(fit) {
    local uiDoc = Rpgc.get(battleFight.battle, "ui", 0);
    if (typeof uiDoc != "table") return;
    local party = Rpgc.get(uiDoc, "party", 0);
    if (typeof party != "table") return;

    local scale = fit.scale;
    local panelX = RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(party, "x", 0)));
    local panelY = RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(party, "y", 0)));
    local panelW = Rpgc.asNumber(Rpgc.get(party, "width", 0)) * scale;
    local panelH = Rpgc.asNumber(Rpgc.get(party, "height", 0)) * scale;
    local slotWidth = Rpgc.asNumber(Rpgc.get(party, "slotWidth", 0)) * scale;
    local slotGap = Rpgc.asNumber(Rpgc.get(party, "slotGap", 0)) * scale;
    local portraitHeight = Rpgc.asNumber(Rpgc.get(party, "portraitHeight", 0)) * scale;
    local slots = Rpgc.asInt(Rpgc.get(party, "slots", 0));
    local bars = Rpgc.get(party, "bars", []);

    local nameHeight = hudFont() != null ? 22.0 * scale : 0.0;
    local breakHeight = 9.0 * scale;
    local inset = 4.0 * scale;
    local labelScale = scale * 1.15;

    gfx.drawSolidRect(panelX, panelY, panelW, panelH, 0.05, 0.06, 0.09, 0.88);
    hudFrame(panelX, panelY, panelW, panelH, 2.0 * scale, 0.32, 0.34, 0.42, 0.95);

    for (local i = 0; i < slots; i += 1) {
        local cellX = panelX + i * (slotWidth + slotGap);
        local unit = unitAtSlot(RpgcBattle.allySide, i);

        // The bank is a CAP, not a roster: a position nobody fills is a legal
        // state and has to look like an empty seat rather than a missing plate.
        if (unit == 0) {
            gfx.drawSolidRect(cellX, panelY, slotWidth, portraitHeight, 0.08, 0.09, 0.11, 1.0);
            hudFrame(cellX, panelY, slotWidth, portraitHeight, 1.0 * scale, 0.20, 0.21, 0.26, 1.0);
            continue;
        }

        local active = battleFight.pending != 0 && battleFight.pending == unit.id;
        local colour = unit.alive ? hudElementColour(unit.element) : [0.24, 0.24, 0.27];

        // The portrait band, top to bottom: a name plate, the face, a break
        // strip. The workflow ships no character art (docs/11 §9), so the face
        // is the unit's element colour: it reads who is in the slot, whether the
        // slot is the one acting, and whether the member is still standing.
        local faceX = cellX + inset;
        local faceY = panelY + nameHeight;
        local faceW = slotWidth - inset * 2.0;
        local faceH = portraitHeight - nameHeight - breakHeight - inset * 2.0;
        if (faceH > 0.0 && faceW > 0.0) {
            gfx.drawSolidRect(faceX, faceY, faceW, faceH, colour[0], colour[1], colour[2], 1.0);
            // A darker skirt so the plate reads as a figure, not a swatch.
            gfx.drawSolidRect(faceX, faceY + faceH * 0.52, faceW, faceH * 0.48,
                colour[0] * 0.55, colour[1] * 0.55, colour[2] * 0.55, 1.0);
            hudFrame(faceX, faceY, faceW, faceH, 1.0 * scale, 0.10, 0.11, 0.14, 0.8);
        }

        gfx.drawSolidRect(cellX, panelY, slotWidth, nameHeight, 0.06, 0.07, 0.10, 1.0);
        if (nameHeight > 0.0) {
            hudText(unit.displayName, cellX + inset, panelY + 4.0 * scale,
                unit.alive ? 0.94 : 0.58, unit.alive ? 0.95 : 0.58, unit.alive ? 0.98 : 0.62,
                labelScale);
        }

        // 破绽: the bar the whole break chain is about. It lives inside the
        // portrait band because the document only budgets panel bars below it.
        local breakY = panelY + portraitHeight - breakHeight - inset;
        local breakRatio = unit.breakMax > 0
            ? unit.breakValue.tofloat() / unit.breakMax.tofloat() : 0.0;
        gfx.drawSolidRect(faceX, breakY, faceW, breakHeight, 0.10, 0.09, 0.07, 1.0);
        gfx.drawSolidRect(faceX, breakY, faceW * breakRatio, breakHeight, 0.88, 0.70, 0.24, 1.0);

        if (active) {
            hudFrame(cellX, panelY, slotWidth, portraitHeight, 2.0 * scale, 1.0, 0.92, 0.35, 1.0);
        } else if (!unit.alive && faceH > 0.0) {
            gfx.drawSolidRect(faceX, faceY, faceW, faceH, 0.06, 0.06, 0.08, 0.55);
        }

        // The document's bars, drawn at the document's offsets from the bottom
        // of the portrait strip, and labelled with the two numbers that make
        // them a readout instead of a coloured stripe.
        local budget = panelY + portraitHeight;
        foreach (bar in bars) {
            local barId = Rpgc.asString(Rpgc.get(bar, "id", ""));
            local barY = budget + Rpgc.asNumber(Rpgc.get(bar, "offsetY", 0)) * scale;
            local barH = Rpgc.asNumber(Rpgc.get(bar, "height", 0)) * scale;
            local colourBar = Rpgc.get(bar, "colour", [1.0, 1.0, 1.0]);
            local maximum = hudPoolMaximum(unit, barId);
            local current = hudPoolCurrent(unit, barId);
            local ratio = maximum > 0.0 ? current / maximum : 0.0;
            gfx.drawSolidRect(cellX, barY, slotWidth, barH, 0.10, 0.10, 0.12, 1.0);
            gfx.drawSolidRect(cellX, barY, slotWidth * ratio, barH,
                colourBar[0], colourBar[1], colourBar[2], 1.0);
            hudFrame(cellX, barY, slotWidth, barH, 1.0 * scale, 0.20, 0.21, 0.26, 0.9);
            local readout = "" + current.tointeger() + "/" + maximum.tointeger();
            local readoutH = barH * 0.62;
            hudReadout(readout, cellX + inset, barY + (barH - readoutH) * 0.5,
                readoutH, 0.96, 0.97, 1.0);
        }
    }

    // The command wheel: geometry from the document, one marker per key, and the
    // key number printed on the ones that are live. The HUD text line above the
    // screen says what the keys do; the numbers say WHICH key.
    local ring = Rpgc.get(uiDoc, "commandRing", 0);
    if (typeof ring != "table") return;
    local ringX = RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(ring, "cx", 0)));
    local ringY = RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(ring, "cy", 0)));
    local radius = Rpgc.asNumber(Rpgc.get(ring, "radius", 0)) * scale;
    gfx.drawSolidRect(ringX - radius, ringY - 1.0, radius * 2.0, 2.0, 0.25, 0.25, 0.30, 0.7);
    gfx.drawSolidRect(ringX - 1.0, ringY - radius, 2.0, radius * 2.0, 0.25, 0.25, 0.30, 0.7);
    local commands = battleCommandList();
    local buttons = Rpgc.get(ring, "buttons", []);
    for (local i = 0; i < buttons.len(); i += 1) {
        local buttonX = RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(buttons[i], "x", 0)));
        local buttonY = RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(buttons[i], "y", 0)));
        local buttonR = Rpgc.asNumber(Rpgc.get(buttons[i], "radius", 0)) * scale;
        local lit = i < commands.len();
        gfx.drawSolidRect(buttonX - buttonR, buttonY - buttonR, buttonR * 2.0, buttonR * 2.0,
            lit ? 0.92 : 0.22, lit ? 0.78 : 0.22, lit ? 0.30 : 0.26, 1.0);
        if (lit && i < 9) {
            local label = "" + (i + 1) + " " + commands[i].label;
            hudText(label, buttonX - buttonR, buttonY + buttonR + 4.0 * scale,
                1.0, 0.96, 0.78, scale * 1.05);
            hudReadout("" + (i + 1), buttonX - buttonR * 0.25, buttonY - buttonR * 0.55,
                buttonR * 0.7, 0.10, 0.10, 0.12);
        }
    }
}

function renderBattle() {
    local fit = battleFit();
    local viewW = gfx.getWidth().tofloat();
    local viewH = gfx.getHeight().tofloat();
    if (battleBackground != null) {
        gfx.drawTexturedRect(battleBackground, 0.0, 0.0, viewW, viewH, 1.0, 1.0, 1.0, 1.0);
    } else {
        gfx.drawSolidRect(0.0, 0.0, viewW, viewH, 0.07, 0.08, 0.11, 1.0);
    }

    // The two banks, drawn from `zones`: the left-top half is the enemy's and the
    // right-bottom half the party's, and the split is visible on purpose.
    local zones = Rpgc.get(battleFight.battle, "zones", 0);
    if (typeof zones == "table") {
        local enemy = Rpgc.get(zones, "enemy", 0);
        local ally = Rpgc.get(zones, "ally", 0);
        if (typeof enemy == "table") {
            gfx.drawSolidRect(RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(enemy, "x", 0))),
                RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(enemy, "y", 0))),
                Rpgc.asNumber(Rpgc.get(enemy, "width", 0)) * fit.scale,
                Rpgc.asNumber(Rpgc.get(enemy, "height", 0)) * fit.scale, 0.45, 0.15, 0.15, 0.16);
        }
        if (typeof ally == "table") {
            gfx.drawSolidRect(RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(ally, "x", 0))),
                RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(ally, "y", 0))),
                Rpgc.asNumber(Rpgc.get(ally, "width", 0)) * fit.scale,
                Rpgc.asNumber(Rpgc.get(ally, "height", 0)) * fit.scale, 0.15, 0.28, 0.45, 0.16);
        }
    }

    foreach (unit in battleFight.units) drawBattleUnit(unit, fit);
    drawBattleHud(fit);
}


function buildHud() {
    if (hudBuilt) return;
    ui.beginBuild();
    ui.beginWindow("rpg-classic", "root");
    ui.text("", "area");
    ui.text("方向键 / WASD 移动 · 点击寻路 · E 互动 · B 打一场 · I 背包", "help");
    ui.text("", "battle");
    ui.text("", "items");
    ui.text("", "status");
    ui.end();
    ui.mountBuildAs("hud");
    ui.select("hud");
    ui.setHostOverlay(true);
    ui.setHostPos(16.0, 12.0, 0.0, 0.0);
    hudBuilt = true;
}

function setupGame() {
    loadObjectContract();
    loadEventDocs();
    setupItems();
    gfx.setBackgroundColor(0.05, 0.07, 0.10, 1.0);
    local startX = playerX;
    local startY = playerY;
    if (!loadWorldMap(worldMapId, startX, startY, facingX, facingY))
        throw "rpgc: failed to load " + worldMapId;
    buildHud();
    if (statusText == "") say("村庄外郊。去找长者，或走向森林入口。");
    refreshHud();
}

eve_init = function () {
    setupGame();
};

eve_reload <- function () {
    hudBuilt = false;
    battleFight = null;
    battleExtra = "";
    battleBackground = null;
    battleBackgroundPath = "";
    bagOpen = false;
    setupGame();
};

eve_update = function (dt) {
    if (battleFight != null) {
        updateBattle(dt);
        if (statusTimer > 0.0) {
            statusTimer -= dt;
            if (statusTimer <= 0.0) statusText = "";
        }
        refreshHud();
        return;
    }
    if (worldLayer == null) return;
    if (statusTimer > 0.0) {
        statusTimer -= dt;
        if (statusTimer <= 0.0) statusText = "";
    }

    if (keyPressed("b") || keyPressed("B")) {
        startBattle();
        return;
    }

    // The bag panel takes the keyboard while it is open: the digits then pick a
    // row instead of walking. Closing it is the same key, so there is no state
    // the player can be stuck in.
    if (keyPressed("i") || keyPressed("I")) {
        bagOpen = !bagOpen;
        refreshHud();
        return;
    }
    if (bagOpen) {
        for (local i = 0; i < 9; i += 1) {
            if (!keyPressed("" + (i + 1))) continue;
            bagAct(i);
            refreshHud();
            return;
        }
        return;
    }

    local dx = 0;
    local dy = 0;
    if (keyPressed("left") || keyPressed("a") || keyPressed("A")) dx = -1;
    if (keyPressed("right") || keyPressed("d") || keyPressed("D")) dx = 1;
    if (keyPressed("up") || keyPressed("w") || keyPressed("W")) dy = -1;
    if (keyPressed("down") || keyPressed("s") || keyPressed("S")) dy = 1;
    if (dx != 0 && dy != 0) dy = 0;
    tryMove(dx, dy);

    local mouseDown = mouse.isDown(1);
    if (mouseDown && !previousMouseDown && camera != null) {
        local viewW = gfx.getWidth().tofloat();
        local viewH = gfx.getHeight().tofloat();
        local wx = camera.screenToWorldX(mouse.getX().tofloat(), mouse.getY().tofloat(), viewW, viewH);
        local wy = camera.screenToWorldY(mouse.getX().tofloat(), mouse.getY().tofloat(), viewW, viewH);
        requestPath(worldLayer.worldToTileX(wx, wy), worldLayer.worldToTileY(wx, wy));
    }
    previousMouseDown = mouseDown;

    if (activePath != null && pathIndex > 0 && pathIndex < activePath.getLength()) {
        stepClock += dt;
        if (stepClock >= STEP_SECONDS) {
            stepClock = 0.0;
            playerX = activePath.getX(pathIndex);
            playerY = activePath.getY(pathIndex);
            pathIndex += 1;
            followCamera();
            if (pathIndex >= activePath.getLength()) activePath = null;
        }
    }

    local standing = objectAtPlayer();
    local standingPortal = standing >= 0 && map.getObjectType(standing) == "portal";
    if (standingPortal && !onPortal) enterPortal(standing);
    onPortal = standingPortal;

    if (keyPressed("e") || keyPressed("E")) interactObject(nearestObject(INTERACT_RANGE));

    map.update(dt);
    refreshHud();
};

function markerColor(kind) {
    if (kind == "npc") return [0.95, 0.82, 0.28, 1.0];
    if (kind == "chest") return [0.92, 0.55, 0.18, 1.0];
    if (kind == "portal") return [0.35, 0.78, 0.95, 1.0];
    return [0.7, 0.7, 0.7, 1.0];
}

eve_render = function () {
    gfx.clear();
    if (battleFight != null) {
        renderBattle();
        ui.beginFrameAndRender();
        return;
    }
    map.render(gfx);
    if (worldLayer != null && camera != null) {
        local viewW = gfx.getWidth().tofloat();
        local viewH = gfx.getHeight().tofloat();
        for (local i = 0; i < map.getObjectCount(); i += 1) {
            local kind = map.getObjectType(i);
            if (kind == "spawn") continue;
            if (kind == "chest" && (consumedKey(worldMapId, map.getObjectName(i)) in consumed)) continue;
            local cell = objectTile(i);
            local wx = worldLayer.tileToWorldX(cell.x, cell.y);
            local wy = worldLayer.tileToWorldY(cell.x, cell.y);
            local sx = camera.worldToScreenX(wx, wy, viewW, viewH);
            local sy = camera.worldToScreenY(wx, wy, viewW, viewH);
            local color = markerColor(kind);
            gfx.drawSolidRect(sx - 6.0, sy - 6.0, 12.0, 12.0, color[0], color[1], color[2], color[3]);
        }
        local px = worldLayer.tileToWorldX(playerX, playerY);
        local py = worldLayer.tileToWorldY(playerX, playerY);
        local sx = camera.worldToScreenX(px, py, viewW, viewH);
        local sy = camera.worldToScreenY(px, py, viewW, viewH);
        gfx.drawSolidRect(sx - 8.0, sy - 22.0, 16.0, 28.0, 0.95, 0.35, 0.28, 1.0);
    }
    ui.beginFrameAndRender();
};
