// EVEngine workflow / rpg-classic — battle scene editor ViewModel.
//
// Bound to editors/battle.editor.json. A battle scene is pure screen geometry:
// one design-space canvas, an enemy bank in the TOP-LEFT half, a party bank in
// the BOTTOM-RIGHT half, at most 8 enemy positions and at most 5 party
// positions. Nothing in the engine reads any of it — there is no battlefield,
// formation or slot type anywhere under `src/modules/rpg` — so the panel and the
// validation gate are the only two things that ever look at this document.
//
// That is why the preview draws the half split and the two banks rather than
// only printing numbers: a bank that slid across the middle, or a slot that left
// its bank, is a picture problem and is invisible in a field list. The panel
// also refuses a ninth enemy or a sixth ally locally, so the author learns the
// cap while dragging instead of from an error after staging.
//
// `validate` runs the same gate the CLI runs, on the in-memory document.

import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcHost } from "game:/lib/rpgc_host.nut"
import { RpgcIso } from "game:/lib/rpgc_iso.nut"
import { RpgcSystems } from "game:/lib/rpgc_systems.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"

// EditorHost registers a ViewModel by looking the name up in the VM root
// (`EditorHost::registerVM`), and this file is a module, so `::BattleVM` would
// land in the module's private environment and never be found. Publish it on
// the root explicitly.
getroottable().BattleVM <- {
    // ------------------------------------------------------------- state
    // The panel is bound to a project FOLDER, not to a document that has to be
    // opened: `kind` names the manifest entry whose directory is the list, and
    // `battleList` is that directory's contents as of the last scan. Picking a
    // row loads it (`onChange`), and `pollFolder` keeps the list honest while
    // the editor is up -- an AI writing into content/battles is the normal case.
    kind = "battle",
    folderLabel = "content/battles",
    folderPath = "content/battles",
    folderCount = 0,
    folderTimer = 0.0,
    folderPollSeconds = 1.0,

    battleList = [],
    battleIndex = 0,
    battleId = "",
    battleTitle = "",
    canvasWidth = 0.0,
    canvasHeight = 0.0,
    canvasLabel = "",
    enemyZoneX = 0.0,
    enemyZoneY = 0.0,
    enemyZoneWidth = 0.0,
    enemyZoneHeight = 0.0,
    enemyZoneLabel = "",
    allyZoneX = 0.0,
    allyZoneY = 0.0,
    allyZoneWidth = 0.0,
    allyZoneHeight = 0.0,
    allyZoneLabel = "",
    hostLabel = "",
    slotLabel = "",

    enemySlotList = [],
    enemyIndex = 0,
    enemyX = 0.0,
    enemyY = 0.0,
    allySlotList = [],
    allyIndex = 0,
    allyX = 0.0,
    allyY = 0.0,

    status = "ready",
    diagnostics = "",
    dirty = false,
    doc = 0,

    // ---------------------------------------------------- screen furniture
    // Projected from the document's optional `ui` block and `background` path.
    // Read-only: the editor draws them so a layout that hides a target is
    // visible before anyone plays it, and the document stays the only authority.
    backgroundPath = "",
    backgroundDeclared = "",
    backgroundTexturePath = "",
    backgroundTexture = 0,
    backgroundSize = "",
    uiPartyX = 0.0,
    uiPartyY = 0.0,
    uiPartyWidth = 0.0,
    uiPartyHeight = 0.0,
    uiPartySlots = 0,
    uiPartySlotWidth = 0.0,
    uiPartySlotGap = 0.0,
    uiPartyPortraitHeight = 0.0,
    uiBars = [],
    uiRingX = 0.0,
    uiRingY = 0.0,
    uiRingRadius = 0.0,
    uiButtons = [],
    uiLabel = "",
    barsLabel = "",
    buttonsLabel = "",

    // ------------------------------------------------------------ lifecycle
    // Read `content/battles` and publish it as the panel's list. There is no
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
        this.battleList = Rpgc.get(info, "ids", []);
        if (this.battleList.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 里没有战场";
            return;
        }
        this.battleIndex = Rpgc.selectedIndexOf(this.battleList, this.battleId, this.battleIndex);
        if (this.battleIndex < 0) this.battleIndex = 0;
        this.battleId = this.battleList[this.battleIndex];
    },

    // Load whichever row the list has selected. Called by `onChange` (picking a
    // row IS opening it), by `refreshFolder`, and at start-up -- never by a
    // button of its own, which is what "no open-document gesture" means here.
    loadSelected = function (editor, widget) {
        if (this.battleList.len() == 0) {
            this.status = "项目文件夹 " + this.folderPath + " 里没有战场";
            return;
        }
        local id = this.resolveBattleId();
        local read = RpgcProject.loadById("battle", id);
        if (!read.ok) {
            this.report(read);
            return;
        }
        this.doc = read.value;
        this.dirty = false;
        this.refresh();
        this.status = "载入 battle/" + id;
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
        if (RpgcProject.idsMatch(this.battleList, ids)) return;
        this.battleList = ids;
        if (ids.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 已没有战场";
            return;
        }
        this.battleIndex = Rpgc.selectedIndexOf(ids, this.battleId, this.battleIndex);
        if (this.battleIndex < 0) this.battleIndex = 0;
        if (ids[this.battleIndex] == this.battleId) {
            this.status = "项目文件夹已变化 (" + ids.len() + " 个战场)";
            return;
        }
        this.battleId = ids[this.battleIndex];
        this.loadSelected("battle", "");
        this.status = "所选战场已不在文件夹中，载入 battle/" + this.battleId;
    },

    newBattle = function (editor, widget) {
        local doc = {};
        doc.schema <- "eve.rpgc.battle";
        doc.version <- 1;
        doc.id <- "battle.untitled";
        doc.title <- "新战场";
        doc.displayName <- "新战场";
        doc.canvas <- { width = 1920.0, height = 1080.0 };
        doc.zones <- {
            enemy = { x = 80.0, y = 60.0, width = 760.0, height = 420.0 },
            ally = { x = 1120.0, y = 620.0, width = 720.0, height = 400.0 }
        };
        doc.enemySlots <- [];
        doc.allySlots <- [];
        // A new scene starts at the full bank capacity so the author deletes
        // what the fight does not need, rather than discovering the cap later.
        for (local i = 0; i < RpgcSystems.maxBattleEnemySlots; i += 1) {
            doc.enemySlots.append(this.defaultEnemySlot(doc, i));
        }
        for (local i = 0; i < RpgcSystems.maxBattleAllySlots; i += 1) {
            doc.allySlots.append(this.defaultAllySlot(doc, i));
        }
        doc.encounters <- ["encounter.untitled"];
        // The screen furniture ships with the scene for the same reason the
        // banks do: a panel that hands the author a scene the gate rejects
        // teaches them to ignore the diagnostics. Both panels sit where the
        // geometry rules put them -- HUD in the party's half, wheel in the left
        // half, neither over the enemy bank.
        doc.ui <- {
            party = {
                x = 1310.0, y = 840.0, width = 570.0, height = 200.0,
                slots = RpgcSystems.maxBattleAllySlots,
                slotWidth = 104.0,
                slotGap = 8.0,
                portraitHeight = 130.0,
                bars = [
                    { id = "hp", offsetY = 8.0, height = 18.0, colour = [0.30, 0.72, 0.36] },
                    { id = "mana", offsetY = 32.0, height = 18.0, colour = [0.25, 0.48, 0.85] }
                ]
            },
            commandRing = {
                cx = 300.0, cy = 800.0, radius = 190.0,
                buttons = [
                    { id = "cmd.attack", x = 410.0, y = 800.0, radius = 40.0, label = "攻击" },
                    { id = "cmd.skill", x = 300.0, y = 690.0, radius = 40.0, label = "招式" },
                    { id = "cmd.item", x = 190.0, y = 800.0, radius = 40.0, label = "物品" },
                    { id = "cmd.defend", x = 300.0, y = 910.0, radius = 40.0, label = "防御" }
                ]
            }
        };
        this.doc = doc;
        this.dirty = true;
        this.refresh();
        this.status = "new battle scene (unsaved)";
    },

    saveBattle = function (editor, widget) {
        if (this.doc == 0) {
            this.status = "nothing to save";
            return;
        }
        this.loadSlots();
        local id = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        local path = RpgcProject.directoryOf("battle") + "/" + id + ".json";
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
    addEnemySlot = function (editor, widget) {
        this.loadSlots();
        local slots = Rpgc.get(this.doc, "enemySlots", []);
        if (slots.len() >= RpgcSystems.maxBattleEnemySlots) {
            this.status = "the enemy bank already holds the maximum "
                + RpgcSystems.maxBattleEnemySlots + " positions";
            return;
        }
        slots.append(this.defaultEnemySlot(this.doc, slots.len()));
        this.doc.enemySlots <- slots;
        this.enemyIndex = slots.len() - 1;
        this.dirty = true;
        this.refresh();
        this.status = "added enemy slot " + slots.len();
    },

    removeEnemySlot = function (editor, widget) {
        if (!this.removeSlot("enemySlots", this.enemyIndex)) return;
        this.enemyIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "removed enemy slot";
    },

    addAllySlot = function (editor, widget) {
        this.loadSlots();
        local slots = Rpgc.get(this.doc, "allySlots", []);
        if (slots.len() >= RpgcSystems.maxBattleAllySlots) {
            this.status = "the party bank already holds the maximum "
                + RpgcSystems.maxBattleAllySlots + " positions";
            return;
        }
        slots.append(this.defaultAllySlot(this.doc, slots.len()));
        this.doc.allySlots <- slots;
        this.allyIndex = slots.len() - 1;
        this.dirty = true;
        this.refresh();
        this.status = "added party slot " + slots.len();
    },

    removeAllySlot = function (editor, widget) {
        if (!this.removeSlot("allySlots", this.allyIndex)) return;
        this.allyIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "removed party slot";
    },

    // Two apply commands rather than one: the X/Y sliders are bound per bank
    // (`enemyX` vs `allyX`), so an implicit "which bank is selected" would be a
    // second piece of state that can disagree with the sliders the author sees.
    applyEnemySlot = function (editor, widget) {
        local slots = Rpgc.get(this.doc, "enemySlots", []);
        if (this.enemyIndex < 0 || this.enemyIndex >= slots.len()) {
            this.status = "no enemy slot selected";
            return;
        }
        this.writeSlot(slots[this.enemyIndex], this.enemyX, this.enemyY);
        this.dirty = true;
        this.refresh();
        this.status = "enemy slot " + (this.enemyIndex + 1) + " -> ("
            + this.enemyX + ", " + this.enemyY + ")";
    },

    applyAllySlot = function (editor, widget) {
        local slots = Rpgc.get(this.doc, "allySlots", []);
        if (this.allyIndex < 0 || this.allyIndex >= slots.len()) {
            this.status = "no party slot selected";
            return;
        }
        this.writeSlot(slots[this.allyIndex], this.allyX, this.allyY);
        this.dirty = true;
        this.refresh();
        this.status = "party slot " + (this.allyIndex + 1) + " -> ("
            + this.allyX + ", " + this.allyY + ")";
    },

    validate = function (editor, widget) {
        this.loadSlots();
        local result = RpgcValidate.validateDocument("battle", this.doc);
        local extras = RpgcSystems.semanticDiagnostics(this.doc);
        foreach (d in extras) {
            if (d.severity == "error") result.ok = false;
            result.diagnostics.append(d);
        }
        this.report(result);
        if (result.ok) this.status = "document is valid";
    },

    // -------------------------------------------------------------- helpers

    // The host writes a `slider` as a one-element array and a
    // `dropdown`/`listbox` as the selected string (EditorHost.cpp:876-930), so
    // numeric slots are unwrapped once per frame instead of at every use.
    normalize = function () {
        this.battleIndex = Rpgc.intOf(this.battleIndex);
        this.enemyIndex = Rpgc.intOf(this.enemyIndex);
        this.allyIndex = Rpgc.intOf(this.allyIndex);
        this.enemyX = Rpgc.numberOf(this.enemyX);
        this.enemyY = Rpgc.numberOf(this.enemyY);
        this.allyX = Rpgc.numberOf(this.allyX);
        this.allyY = Rpgc.numberOf(this.allyY);
    },

    resolveBattleId = function () {
        local index = Rpgc.selectedIndexOf(this.battleList, this.battleId, this.battleIndex);
        if (index < 0) return "";
        this.battleIndex = index;
        return this.battleList[index];
    },

    removeSlot = function (field, index) {
        local slots = Rpgc.get(this.doc, field, []);
        if (index < 0 || index >= slots.len()) {
            this.status = "nothing selected in " + field;
            return false;
        }
        slots.remove(index);
        this.doc.rawset(field, slots);
        return true;
    },

    // `<-` rather than `=`: the document was decoded from JSON, and this
    // EveScript VM raises "the index 'x' does not exist" for `slot.x = v` when
    // the slot was never declared. See skill.vm.nut for the measurement.
    writeSlot = function (slot, x, y) {
        slot.x <- x;
        slot.y <- y;
    },

    // Default stands use the 45-degree diamond: enemies fill two iso-rows
    // (4 columns), the party fills one iso-row so five people stand in a line.
    defaultEnemySlot = function (doc, index) {
        local zone = Rpgc.get(doc, "zones.enemy", 0);
        local point = RpgcIso.battleIsoSlot(zone, index, 4, 2);
        local slot = {};
        slot.id <- "enemy." + (index + 1);
        slot.x <- point.x;
        slot.y <- point.y;
        return slot;
    },

    defaultAllySlot = function (doc, index) {
        local zone = Rpgc.get(doc, "zones.ally", 0);
        local point = RpgcIso.battleIsoSlot(zone, index, 5, 1);
        local slot = {};
        slot.id <- "ally." + (index + 1);
        slot.x <- point.x;
        slot.y <- point.y;
        return slot;
    },

    refresh = function () {
        if (this.doc == 0) return;
        this.battleId = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        this.battleTitle = Rpgc.asString(Rpgc.get(this.doc, "title", this.battleId));
        local canvas = Rpgc.get(this.doc, "canvas", 0);
        this.canvasWidth = Rpgc.asNumber(Rpgc.get(canvas, "width", 0));
        this.canvasHeight = Rpgc.asNumber(Rpgc.get(canvas, "height", 0));
        this.canvasLabel = "画布 canvas " + this.canvasWidth + "x" + this.canvasHeight;

        local zones = Rpgc.get(this.doc, "zones", 0);
        local enemy = Rpgc.get(zones, "enemy", 0);
        this.enemyZoneX = Rpgc.asNumber(Rpgc.get(enemy, "x", 0));
        this.enemyZoneY = Rpgc.asNumber(Rpgc.get(enemy, "y", 0));
        this.enemyZoneWidth = Rpgc.asNumber(Rpgc.get(enemy, "width", 0));
        this.enemyZoneHeight = Rpgc.asNumber(Rpgc.get(enemy, "height", 0));
        this.enemyZoneLabel = "敌阵 zones.enemy " + this.enemyZoneWidth + "x"
            + this.enemyZoneHeight + " @ (" + this.enemyZoneX + ", " + this.enemyZoneY + ")";

        local ally = Rpgc.get(zones, "ally", 0);
        this.allyZoneX = Rpgc.asNumber(Rpgc.get(ally, "x", 0));
        this.allyZoneY = Rpgc.asNumber(Rpgc.get(ally, "y", 0));
        this.allyZoneWidth = Rpgc.asNumber(Rpgc.get(ally, "width", 0));
        this.allyZoneHeight = Rpgc.asNumber(Rpgc.get(ally, "height", 0));
        this.allyZoneLabel = "我方 zones.ally " + this.allyZoneWidth + "x"
            + this.allyZoneHeight + " @ (" + this.allyZoneX + ", " + this.allyZoneY + ")";

        this.enemySlotList = this.describeSlots("enemySlots");
        this.allySlotList = this.describeSlots("allySlots");
        if (this.enemyIndex >= this.enemySlotList.len()) this.enemyIndex = 0;
        if (this.allyIndex >= this.allySlotList.len()) this.allyIndex = 0;

        this.hostLabel = "hosts " + Rpgc.get(this.doc, "encounters", []).len()
            + " encounter(s): " + Rpgc.joinList(Rpgc.get(this.doc, "encounters", []), ", ");
        this.slotLabel = "敌 " + this.enemySlotList.len()
            + " / 我 " + this.allySlotList.len();
        this.refreshScreenFurniture();
        this.loadSlots();
    },

    // The optional backdrop + `ui` block, flattened into drawable state.
    //
    // Everything here is a projection of the document: nothing is written back,
    // and a document without the fields leaves the editor in its pre-`ui` shape
    // (no backdrop, no furniture) rather than in a half-drawn one.
    refreshScreenFurniture = function () {
        // `background` is document-relative, exactly like `tileset.image` and
        // `anim.image`, so it has to be resolved against the document that
        // declared it before it can be handed to the texture loader. Feeding the
        // raw `backdrops/x.png` to `newTextureFromFile` would resolve it against
        // the project root and never find anything.
        local docPath = RpgcProject.directoryOf("battle") + "/"
            + Rpgc.asString(Rpgc.get(this.doc, "id", "")) + ".json";
        local declared = Rpgc.asString(Rpgc.get(this.doc, "background", ""));
        this.backgroundDeclared = declared;
        this.backgroundPath = declared == "" ? "" : Rpgc.resolveFrom(docPath, declared);
        // A document load is the moment to re-attempt the texture, so the
        // "already tried" marker is cleared here and re-armed by the loader.
        this.backgroundTexturePath = "";
        this.backgroundTexture = 0;
        this.backgroundSize = "";

        local ui = Rpgc.get(this.doc, "ui", 0);
        if (typeof ui != "table") {
            this.uiPartySlots = 0;
            this.uiRingRadius = 0.0;
            this.uiBars = [];
            this.uiButtons = [];
            this.uiLabel = "ui 未声明：本场景只画战场几何";
            this.barsLabel = "";
            this.buttonsLabel = "";
            return;
        }

        local party = Rpgc.get(ui, "party", 0);
        this.uiPartyX = Rpgc.asNumber(Rpgc.get(party, "x", 0));
        this.uiPartyY = Rpgc.asNumber(Rpgc.get(party, "y", 0));
        this.uiPartyWidth = Rpgc.asNumber(Rpgc.get(party, "width", 0));
        this.uiPartyHeight = Rpgc.asNumber(Rpgc.get(party, "height", 0));
        this.uiPartySlots = Rpgc.asInt(Rpgc.get(party, "slots", 0));
        this.uiPartySlotWidth = Rpgc.asNumber(Rpgc.get(party, "slotWidth", 0));
        this.uiPartySlotGap = Rpgc.asNumber(Rpgc.get(party, "slotGap", 0));
        this.uiPartyPortraitHeight = Rpgc.asNumber(Rpgc.get(party, "portraitHeight", 0));
        this.uiBars = Rpgc.get(party, "bars", []);

        local ring = Rpgc.get(ui, "commandRing", 0);
        this.uiRingX = Rpgc.asNumber(Rpgc.get(ring, "cx", 0));
        this.uiRingY = Rpgc.asNumber(Rpgc.get(ring, "cy", 0));
        this.uiRingRadius = Rpgc.asNumber(Rpgc.get(ring, "radius", 0));
        this.uiButtons = Rpgc.get(ring, "buttons", []);

        this.uiLabel = "HUD " + this.uiPartyWidth + "x" + this.uiPartyHeight
            + " @ (" + this.uiPartyX + ", " + this.uiPartyY + ") · "
            + this.uiPartySlots + " 个头像 × " + this.uiPartySlotWidth
            + " (间隔 " + this.uiPartySlotGap + ") · 头像高 " + this.uiPartyPortraitHeight
            + " · 条 " + this.uiBars.len()
            + " · 操作环 r" + this.uiRingRadius + " · " + this.uiButtons.len() + " 键";

        local barNames = [];
        foreach (bar in this.uiBars) {
            barNames.append(Rpgc.asString(Rpgc.get(bar, "id", "?"))
                + " @" + Rpgc.asNumber(Rpgc.get(bar, "offsetY", 0)));
        }
        this.barsLabel = "bars: " + Rpgc.joinList(barNames, ", ");

        local buttonNames = [];
        foreach (button in this.uiButtons) {
            buttonNames.append(Rpgc.asString(Rpgc.get(button, "label",
                Rpgc.asString(Rpgc.get(button, "id", "?")))));
        }
        this.buttonsLabel = "buttons: " + Rpgc.joinList(buttonNames, " / ");
    },

    // The backdrop. `eve.Graphics()` exposes `drawTexturedRect` but not the UV
    // form, so this draws the whole image stretched onto the design field --
    // exact when the backdrop matches the canvas aspect, which is why the panel
    // reports the texture's real pixel size rather than pretending it fits.
    //
    // `backgroundTexturePath` records the path we last ATTEMPTED, success or
    // failure. Without that, a backdrop that fails to load leaves both the
    // texture and the path empty, so the guard never matches and every frame
    // re-attempts a file open. The attempt is re-armed on every document load
    // (`refreshScreenFurniture`), which is often enough to pick up a fixed image
    // without paying for the retry every frame.
    ensureBackgroundTexture = function (gfx) {
        if (this.backgroundPath == "") {
            this.backgroundTexture = 0;
            this.backgroundTexturePath = "";
            this.backgroundSize = "";
            return;
        }
        if (this.backgroundTexturePath == this.backgroundPath) return;
        this.backgroundTexturePath = this.backgroundPath;
        this.backgroundTexture = 0;
        this.backgroundSize = "";
        try {
            local texture = gfx.newTextureFromFile(this.backgroundPath);
            this.backgroundTexture = texture;
            this.backgroundSize = texture.getWidth() + "x" + texture.getHeight();
        } catch (e) {
            this.backgroundTexture = 0;
            if ("log" in eve) eve.log("warn", "battle: backdrop '" + this.backgroundPath
                + "' failed to load: " + e);
        }
    },

    describeSlots = function (field) {
        local out = [];
        local slots = Rpgc.get(this.doc, field, []);
        for (local i = 0; i < slots.len(); i += 1) {
            out.append((i + 1) + ". " + Rpgc.asString(Rpgc.get(slots[i], "id", "?"))
                + "  (" + Rpgc.asNumber(Rpgc.get(slots[i], "x", 0)) + ", "
                + Rpgc.asNumber(Rpgc.get(slots[i], "y", 0)) + ")");
        }
        return out;
    },

    loadSlots = function () {
        local enemySlots = Rpgc.get(this.doc, "enemySlots", []);
        if (this.enemyIndex >= 0 && this.enemyIndex < enemySlots.len()) {
            this.enemyX = Rpgc.asNumber(Rpgc.get(enemySlots[this.enemyIndex], "x", 0));
            this.enemyY = Rpgc.asNumber(Rpgc.get(enemySlots[this.enemyIndex], "y", 0));
        }
        local allySlots = Rpgc.get(this.doc, "allySlots", []);
        if (this.allyIndex >= 0 && this.allyIndex < allySlots.len()) {
            this.allyX = Rpgc.asNumber(Rpgc.get(allySlots[this.allyIndex], "x", 0));
            this.allyY = Rpgc.asNumber(Rpgc.get(allySlots[this.allyIndex], "y", 0));
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
        return this.battleId + " | canvas " + Rpgc.intOf(this.canvasWidth)
            + "x" + Rpgc.intOf(this.canvasHeight)
            + " | enemy " + this.enemySlotList.len()
            + " / ally " + this.allySlotList.len()
            + (this.backgroundDeclared == "" ? " | no backdrop"
                : (this.backgroundTexture != 0
                    ? " | backdrop " + this.backgroundSize
                    : " | backdrop declared, not loaded yet"))
            + " | " + this.uiLabel
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
        local rect = this.canvasRect();
        if (rect.width <= 1.0 || rect.height <= 1.0) return;
        gfx.drawSolidRect(rect.x, rect.y, rect.width, rect.height, 0.06, 0.07, 0.10, 1.0);
        if (this.canvasWidth <= 0.0 || this.canvasHeight <= 0.0) return;

        // Letterbox the design canvas into the widget so the picture keeps the
        // document's aspect ratio: a bank that only just clears the middle must
        // not look like it clears it by more than it does.
        local box = this.fieldBox();
        local left = box.left;
        local top = box.top;
        local fieldW = box.width;
        local fieldH = box.height;
        local scale = box.scale;

        // The painted backdrop, under everything. Drawn first and dimmed a
        // little so the slot markers and the furniture keep their contrast.
        this.ensureBackgroundTexture(gfx);
        if (this.backgroundTexture != 0) {
            gfx.drawTexturedRect(this.backgroundTexture, left, top, fieldW, fieldH,
                                 0.82, 0.82, 0.84, 1.0);
        }

        // The two halves, shaded differently, then the split lines. The tints
        // are translucent rather than opaque so a backdrop still reads through.
        this.outline(gfx, left, top, fieldW, fieldH, 0.30, 0.33, 0.40, 0.9);
        gfx.drawSolidRect(left, top, fieldW * 0.5, fieldH * 0.5, 0.15, 0.10, 0.10, 0.30);
        gfx.drawSolidRect(left + fieldW * 0.5, top + fieldH * 0.5,
                          fieldW * 0.5, fieldH * 0.5, 0.10, 0.12, 0.18, 0.30);
        gfx.drawSolidRect(left + fieldW * 0.5 - 1.0, top, 2.0, fieldH, 0.38, 0.40, 0.48, 0.85);
        gfx.drawSolidRect(left, top + fieldH * 0.5 - 1.0, fieldW, 2.0, 0.38, 0.40, 0.48, 0.85);

        // The two banks.
        this.outline(gfx,
            left + this.enemyZoneX * scale, top + this.enemyZoneY * scale,
            this.enemyZoneWidth * scale, this.enemyZoneHeight * scale,
            0.92, 0.42, 0.36, 0.95);
        this.outline(gfx,
            left + this.allyZoneX * scale, top + this.allyZoneY * scale,
            this.allyZoneWidth * scale, this.allyZoneHeight * scale,
            0.40, 0.70, 0.95, 0.95);

        // The screen furniture goes UNDER the slot markers: the marker for the
        // selected actor has to stay on top or you cannot see what you picked.
        this.drawPartyHud(gfx, box);
        this.drawCommandRing(gfx, box);

        this.drawSlots(gfx, "enemySlots", this.enemyIndex, 0.95, 0.35, 0.30);
        this.drawSlots(gfx, "allySlots", this.allyIndex, 0.35, 0.65, 0.95);
    },

    // The letterbox once, so the picture and the furniture cannot disagree about
    // where the design space ended up (they used to compute it separately).
    fieldBox = function () {
        local rect = this.canvasRect();
        local out = {};
        out.left <- rect.x;
        out.top <- rect.y;
        out.width <- 0.0;
        out.height <- 0.0;
        out.scale <- 1.0;
        if (rect.width <= 1.0 || rect.height <= 1.0) return out;
        if (this.canvasWidth <= 0.0 || this.canvasHeight <= 0.0) return out;
        local scale = rect.width / this.canvasWidth;
        local vertical = rect.height / this.canvasHeight;
        if (vertical < scale) scale = vertical;
        out.width = this.canvasWidth * scale;
        out.height = this.canvasHeight * scale;
        out.left = rect.x + (rect.width - out.width) * 0.5;
        out.top = rect.y + (rect.height - out.height) * 0.5;
        out.scale <- scale;
        return out;
    },

    // The bottom-right party HUD: a horizontal row of portrait cells with the
    // resource bars underneath them, which is what a party of five actually
    // looks like along the bottom of a battle screen.
    //
    // Nothing here is simulated. The faces are empty boxes, the names are dashes
    // and the bars sit at a fixed demo fraction, because the real values are
    // runtime `Party` state and a content document cannot know them; drawing a
    // full bar would read as "this is what it will look like".
    drawPartyHud = function (gfx, box) {
        if (this.uiPartySlots <= 0 || this.uiPartyWidth <= 0.0 || this.uiPartyHeight <= 0.0) return;
        local s = box.scale;
        local px = box.left + this.uiPartyX * s;
        local py = box.top + this.uiPartyY * s;
        local pw = this.uiPartyWidth * s;
        local ph = this.uiPartyHeight * s;
        local cellW = this.uiPartySlotWidth * s;
        local gap = this.uiPartySlotGap * s;
        local portraitH = this.uiPartyPortraitHeight * s;
        gfx.drawSolidRect(px, py, pw, ph, 0.07, 0.08, 0.12, 0.88);
        this.outline(gfx, px, py, pw, ph, 0.72, 0.62, 0.32, 0.95);

        // One member card: portrait on top, resource bars underneath at the
        // same width, then that card is repeated across the row.
        local rowWidth = this.uiPartySlots * cellW + (this.uiPartySlots - 1) * gap;
        local rowX = px + (pw - rowWidth) * 0.5;
        local faceY = py + 6.0;
        local barsTop = faceY + portraitH;
        for (local i = 0; i < this.uiPartySlots; i += 1) {
            local cx = rowX + i * (cellW + gap);
            gfx.drawSolidRect(cx, faceY, cellW, portraitH, 0.16, 0.18, 0.26, 1.0);
            gfx.drawSolidRect(cx + cellW * 0.12, faceY + portraitH * 0.18,
                cellW * 0.76, portraitH * 0.42, 0.42, 0.38, 0.48, 1.0);
            gfx.drawSolidRect(cx + cellW * 0.18, faceY + portraitH * 0.58,
                cellW * 0.64, portraitH * 0.28, 0.28, 0.26, 0.34, 1.0);
            this.outline(gfx, cx, faceY, cellW, portraitH, 0.55, 0.58, 0.68, 0.9);
            for (local b = 0; b < this.uiBars.len(); b += 1) {
                local bar = this.uiBars[b];
                local barH = Rpgc.asNumber(Rpgc.get(bar, "height", 0)) * s;
                if (barH < 2.0) barH = 2.0;
                local barY = barsTop + Rpgc.asNumber(Rpgc.get(bar, "offsetY", 0)) * s;
                local colour = Rpgc.get(bar, "colour", [0.4, 0.7, 0.4]);
                local r = Rpgc.asNumber(Rpgc.get(colour, "0", 0.4));
                local g = Rpgc.asNumber(Rpgc.get(colour, "1", 0.7));
                local bl = Rpgc.asNumber(Rpgc.get(colour, "2", 0.4));
                local fill = 0.82 - i * 0.12;
                if (fill < 0.28) fill = 0.28;
                gfx.drawSolidRect(cx, barY, cellW, barH, 0.12, 0.13, 0.17, 0.95);
                gfx.drawSolidRect(cx, barY, cellW * fill, barH, r, g, bl, 0.95);
                this.outline(gfx, cx, barY, cellW, barH, 0.02, 0.02, 0.03, 0.9);
            }
        }
    },

    // The left-hand command wheel: the disc, then one disc per button with its
    // label strip. Drawn from the document, so a button outside the ring or two
    // buttons on top of each other look wrong here before the gate says so.
    drawCommandRing = function (gfx, box) {
        if (this.uiRingRadius <= 0.0) return;
        local s = box.scale;
        local cx = box.left + this.uiRingX * s;
        local cy = box.top + this.uiRingY * s;
        local radius = this.uiRingRadius * s;
        if (radius < 2.0) return;
        this.fillDisc(gfx, cx, cy, radius, 0.10, 0.09, 0.14, 0.50);
        this.outlineDisc(gfx, cx, cy, radius, 0.78, 0.66, 0.34, 0.9);
        this.outlineDisc(gfx, cx, cy, radius * 0.86, 0.62, 0.52, 0.26, 0.55);

        for (local i = 0; i < this.uiButtons.len(); i += 1) {
            local button = this.uiButtons[i];
            local bx = box.left + Rpgc.asNumber(Rpgc.get(button, "x", 0)) * s;
            local by = box.top + Rpgc.asNumber(Rpgc.get(button, "y", 0)) * s;
            local br = Rpgc.asNumber(Rpgc.get(button, "radius", 0)) * s;
            if (br < 2.0) continue;
            this.fillDisc(gfx, bx, by, br, 0.30, 0.20, 0.14, 0.95);
            this.outlineDisc(gfx, bx, by, br, 0.86, 0.72, 0.38, 1.0);
            // The inner seal square, the way the reference wheels are drawn.
            local q = br * 0.42;
            gfx.drawSolidRect(bx - q, by - q, q * 2.0, q * 2.0, 0.72, 0.58, 0.28, 0.9);
        }
    },

    // `drawSolidRect` has no circle primitive. A disc is a stack of horizontal
    // slices -- 14 is past the point where a panel-sized circle reads as faceted
    // -- and a ring is 24 points walked around the circumference.
    fillDisc = function (gfx, cx, cy, radius, r, g, b, a) {
        if (radius <= 0.0) return;
        local slices = 14;
        local step = (radius * 2.0) / slices;
        for (local i = 0; i < slices; i += 1) {
            local dy = -radius + step * (i + 0.5);
            local half = radius * radius - dy * dy;
            if (half <= 0.0) continue;
            local halfWidth = sqrt(half);
            gfx.drawSolidRect(cx - halfWidth, cy + dy - step * 0.5,
                              halfWidth * 2.0, step + 1.0, r, g, b, a);
        }
    },

    outlineDisc = function (gfx, cx, cy, radius, r, g, b, a) {
        if (radius <= 0.0) return;
        local segments = 24;
        local thickness = radius * 0.10;
        if (thickness < 1.0) thickness = 1.0;
        for (local i = 0; i < segments; i += 1) {
            local angle = 6.2831853 * i / segments;
            local x = cx + radius * cos(angle) - thickness * 0.5;
            local y = cy + radius * sin(angle) - thickness * 0.5;
            gfx.drawSolidRect(x, y, thickness, thickness, r, g, b, a);
        }
    },

    // A slot that sits outside its own bank is drawn white-hot: the semantic
    // gate rejects it, and the picture should say so before the gate is run.
    drawSlots = function (gfx, field, selected, r, g, b) {
        local box = this.fieldBox();
        if (box.width <= 1.0) return;
        local scale = box.scale;
        local left = box.left;
        local top = box.top;

        local zone = this.zoneOf(field);
        local size = scale * 26.0;
        if (size < 5.0) size = 5.0;
        local slots = Rpgc.get(this.doc, field, []);
        for (local i = 0; i < slots.len(); i += 1) {
            local x = left + Rpgc.asNumber(Rpgc.get(slots[i], "x", 0)) * scale;
            local y = top + Rpgc.asNumber(Rpgc.get(slots[i], "y", 0)) * scale;
            local inside = RpgcSystems.insideRect(zone,
                Rpgc.asNumber(Rpgc.get(slots[i], "x", 0)),
                Rpgc.asNumber(Rpgc.get(slots[i], "y", 0)));
            local mark = size;
            if (i == selected) mark = size * 1.7;
            if (!inside) {
                gfx.drawSolidRect(x - mark * 0.5, y - mark * 0.5, mark, mark,
                                  1.0, 0.95, 0.85, 1.0);
                continue;
            }
            gfx.drawSolidRect(x - mark * 0.5, y - mark * 0.5, mark, mark, r, g, b, 0.95);
            if (i == selected) {
                this.outline(gfx, x - mark * 0.5 - 3.0, y - mark * 0.5 - 3.0,
                    mark + 6.0, mark + 6.0, 1.0, 0.85, 0.25, 1.0);
            }
        }
    },

    zoneOf = function (field) {
        local zone = {};
        if (field == "allySlots") {
            zone.x <- this.allyZoneX; zone.y <- this.allyZoneY;
            zone.width <- this.allyZoneWidth; zone.height <- this.allyZoneHeight;
        } else {
            zone.x <- this.enemyZoneX; zone.y <- this.enemyZoneY;
            zone.width <- this.enemyZoneWidth; zone.height <- this.enemyZoneHeight;
        }
        return zone;
    },

    // `drawSolidRect` is the only primitive the editors use; a border is four
    // thin rects rather than a new binding.
    outline = function (gfx, x, y, w, h, r, g, b, a) {
        if (w <= 0.0 || h <= 0.0) return;
        gfx.drawSolidRect(x, y, w, 2.0, r, g, b, a);
        gfx.drawSolidRect(x, y + h - 2.0, w, 2.0, r, g, b, a);
        gfx.drawSolidRect(x, y, 2.0, h, r, g, b, a);
        gfx.drawSolidRect(x + w - 2.0, y, 2.0, h, r, g, b, a);
    },

    canvasRect = function () {
        local out = {};
        out.x <- 0.0;
        out.y <- 0.0;
        out.width <- 0.0;
        out.height <- 0.0;
        try {
            local parsed = RpgcJson.parse(eve.host.widgetRect("battle", "field"));
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
        if (widget == "battle") {
            // Selecting a row loads it immediately: the folder listing is the
            // document list, so there is no second "open" gesture to wait for.
            this.battleId = Rpgc.asString(value);
            this.normalize();
            this.loadSelected("battle", "");
            return;
        }
        if (widget == "enemySlot") {
            this.enemyIndex = Rpgc.intOf(value);
            this.normalize();
            this.loadSlots();
        }
        if (widget == "allySlot") {
            this.allyIndex = Rpgc.intOf(value);
            this.normalize();
            this.loadSlots();
        }
        this.normalize();
    }
};

RpgcHost.register("battle", {
    update = function (dt) { BattleVM.update(dt); },
    draw = function () { BattleVM.draw(); },
    status = function () { return BattleVM.status_line(); }
});

// Start-up: scan the project folder and show its first battle scene. No
// argument, no document chooser -- the editor opens onto the game folder's data.
try {
    BattleVM.loadFolder();
    BattleVM.loadSelected("battle", "");
} catch (e) {
    BattleVM.status = "" + e;
    if ("log" in eve) eve.log("error", "battle: initial folder load: " + e);
}
