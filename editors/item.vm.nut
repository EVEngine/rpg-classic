// EVEngine workflow / rpg-classic — item editor ViewModel.
//
// Bound to editors/item.editor.json. An item is the first kind in this workflow
// whose ENGINE half already exists as a contract: `ItemRegistry` parses these
// nine keys -- id / displayName / maxStack / weight / volume / category / tags /
// equipSlot / extra -- and `EquipmentSystem` holds the stats in `equipStats`,
// while `use` / `teaches` / `requires` are the project-side half the engine has
// not got at all. That engine half is a REQUIREMENT those two systems state, not
// a call this editor makes: neither runtime is reachable from this build,
// because `inventory` and `rpg` are declared with no `SLOT`, so
// `src/scripts/load.nut` never instantiates them and `eve.Inventory` / `rpg`
// are simply absent (cmake/module_manifest/core_foundation.cmake:105). The
// runtime that owns all of it here is lib/rpgc_items.nut.
//
// The loader behind that contract is silent in four places, and the gate must
// match it: an unknown key is dropped, a duplicate id overwrites the earlier
// definition, maxStack<=0 becomes 1, and an empty displayName becomes the id. A
// misspelled `op` buys a stat that never takes effect, and `equipSlot` is NOT
// merely advisory: a non-empty value is compared against the slot name being
// equipped into (src/modules/inventory/Equipment.cpp:108-111); what the engine
// never does is derive `defineSlot` calls from it.
//
// So this panel does exactly two things: project the document into a form, and
// send every write through the same gate. No rule is duplicated here, and both
// vocabularies come from their single authority:
//
//   equip slot vocabulary   equipmentSlots in content/rules/rules.wuxing.json (dropdown options)
//   op spellings            the 13 spellings the engine's parseAttributeOperation accepts (dropdown options)
//   semantic gate           RpgcSystems.itemDiagnostics
//   cross-document gate     RpgcSystems.itemCrossDiagnostics (slot vocabulary / manual attribution / grade)
//
// Saving always goes through RpgcValidate.commitDocument("content/items/<id>.json", doc),
// so a consumable pointing at an effect that does not exist cannot reach disk.

import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcHost } from "game:/lib/rpgc_host.nut"
import { RpgcSystems } from "game:/lib/rpgc_systems.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"

// EditorHost looks a ViewModel up by name in the VM root
// (`EditorHost::registerVM`), and this file is a module, so `::ItemVM` would land
// in the module's private environment and never be found. Publish it on the root
// explicitly.
getroottable().ItemVM <- {
    // ------------------------------------------------------------- state
    // The panel is bound to a project FOLDER, not to a document that has to be
    // opened: `kind` names the manifest entry whose directory is the list, and
    // `itemList` is that directory's contents as of the last scan. Picking a row
    // loads it (`onChange`), and `pollFolder` keeps the list honest while the
    // editor is up -- an AI writing into content/items is the normal case.
    kind = "item",
    folderLabel = "content/items",
    folderPath = "content/items",
    folderCount = 0,
    folderTimer = 0.0,
    folderPollSeconds = 1.0,

    itemList = [],
    itemIndex = 0,
    itemId = "",
    itemDisplayName = "",
    itemTitle = "",
    itemDescription = "",
    categories = ["consumable", "weapon", "armor", "accessory", "material", "quest", "manual"],
    itemCategory = "material",
    rarities = ["common", "uncommon", "rare", "epic", "legendary"],
    itemRarity = "common",
    itemValue = 0,
    itemMaxStack = 1,
    itemWeight = 0.0,
    itemVolume = 0.0,
    equipSlots = [],
    itemEquipSlot = "",
    tagsLabel = "",
    extraLabel = "",
    slotLabel = "",

    statList = [],
    statIndex = 0,
    statAttribute = "",
    // The spellings the engine side accepts; the schema enum matches it word for
    // word, and the order is copied from the document's §2.2.
    ops = ["add", "additive_percent", "mulAdd", "multiplicative_percent", "mulMul",
           "multiply", "override", "clamp_min", "clampMin", "min", "clamp_max",
           "clampMax", "max"],
    statOp = "add",
    statValue = 0.0,
    statPriority = 0,

    useDeclared = false,
    useLabel = "",
    useConsume = true,
    useCooldown = 0.0,
    targetTypes = ["self", "enemySingle", "enemyAll", "allySingle", "allyAll", "anySingle", "anyAll"],
    useTargetType = "self",
    useEffectList = [],
    useEffectIndex = 0,
    effectId = "",
    effectOptions = [],

    teachesDeclared = false,
    teachesLabel = "",
    artList = [],
    teachesArt = "",
    skillList = [],
    teachesSkill = "",

    requiresDeclared = false,
    requiresLabel = "",
    requiresLevel = 1,
    requiresArtId = "",
    requiresMinGrade = 1,

    status = "ready",
    diagnostics = "",
    dirty = false,

    doc = 0,
    rules = 0,

    // ------------------------------------------------------------ lifecycle
    // Read `content/items` and publish it as the panel's list. There is no
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
        this.itemList = Rpgc.get(info, "ids", []);
        if (this.itemList.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 里没有物品";
            return;
        }
        this.itemIndex = Rpgc.selectedIndexOf(this.itemList, this.itemId, this.itemIndex);
        if (this.itemIndex < 0) this.itemIndex = 0;
        this.itemId = this.itemList[this.itemIndex];
    },

    // Load whichever row the list has selected. Called by `onChange` (picking a
    // row IS opening it), by `refreshFolder`, and at start-up -- never by a
    // button of its own, which is what "no open-document gesture" means in
    // practice.
    loadSelected = function (editor, widget) {
        if (this.itemList.len() == 0) {
            this.status = "项目文件夹 " + this.folderPath + " 里没有物品";
            return;
        }
        local id = this.resolveItemId();
        local read = RpgcProject.loadById("item", id);
        if (!read.ok) {
            this.report(read);
            return;
        }
        this.doc = read.value;
        this.dirty = false;
        this.statIndex = 0;
        this.useEffectIndex = 0;
        this.refresh();
        // A successful load still lets the gate speak: when the document does
        // not pass, the status line points back at the diagnostics tab instead
        // of being overwritten by a "loaded" message.
        this.status = "载入 item/" + id + (this.diagnostics == "ok" ? "" : " — 见诊断");
    },

    // Rescan the project folder and reload the selected document from disk. The
    // only way to throw away unsaved edits, so it is a deliberate gesture.
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
        if (RpgcProject.idsMatch(this.itemList, ids)) return;
        this.itemList = ids;
        if (ids.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 已没有物品";
            return;
        }
        this.itemIndex = Rpgc.selectedIndexOf(ids, this.itemId, this.itemIndex);
        if (this.itemIndex < 0) this.itemIndex = 0;
        if (ids[this.itemIndex] == this.itemId) {
            this.status = "项目文件夹已变化 (" + ids.len() + " 个物品)";
            return;
        }
        this.itemId = ids[this.itemIndex];
        this.loadSelected("item", "");
        this.status = "所选物品已不在文件夹中，载入 item/" + this.itemId;
    },

    newItem = function (editor, widget) {
        local doc = {};
        doc.schema <- "eve.rpgc.item";
        doc.version <- 1;
        doc.id <- "item.untitled";
        doc.title <- "新物品";
        doc.description <- "";
        doc.displayName <- "新物品";
        doc.category <- "material";
        doc.rarity <- "common";
        doc.maxStack <- 99;
        doc.weight <- 0.1;
        doc.volume <- 0.1;
        doc.value <- 0;
        doc.tags <- ["material"];
        doc.extra <- { icon = "ui/items/item.untitled.png" };
        this.doc = doc;
        this.statIndex = 0;
        this.useEffectIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "new item (unsaved)";
    },

    saveItem = function (editor, widget) {
        if (this.doc == 0) {
            this.status = "nothing to save";
            return;
        }
        this.storeEdits();
        local id = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        local path = RpgcProject.directoryOf("item") + "/" + id + ".json";
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

    addStat = function (editor, widget) {
        if (this.doc == 0) return;
        this.storeEdits();
        local stats = Rpgc.get(this.doc, "equipStats", []);
        if (stats.len() >= 8) {
            this.status = "equipStats 最多 8 条";
            return;
        }
        stats.append({ attribute = "attack", op = "add", value = 0.0, priority = 0 });
        this.doc.equipStats <- stats;
        this.statIndex = stats.len() - 1;
        this.dirty = true;
        this.refresh();
        this.status = "新增 equipStats 第 " + stats.len() + " 条";
    },

    removeStat = function (editor, widget) {
        if (this.doc == 0) return;
        local stats = Rpgc.get(this.doc, "equipStats", []);
        if (stats.len() == 0) return;
        stats.remove(this.statIndex);
        // An empty array is not left in the document: the schema allows it, but
        // for a non-equipment category it is only diff noise.
        if (stats.len() == 0 && this.doc.rawin("equipStats")) this.doc.rawdelete("equipStats");
        this.statIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "删除一行 equipStats";
    },

    moveStatUp = function (editor, widget) { this.moveStat(-1); },
    moveStatDown = function (editor, widget) { this.moveStat(1); },

    moveStat = function (delta) {
        if (this.doc == 0) return;
        this.storeEdits();
        local stats = Rpgc.get(this.doc, "equipStats", []);
        local to = this.statIndex + delta;
        if (to < 0 || to >= stats.len()) return;
        local held = stats[this.statIndex];
        stats[this.statIndex] = stats[to];
        stats[to] = held;
        this.statIndex = to;
        this.dirty = true;
        this.refresh();
        this.status = "equipStats 顺序 " + (to + 1) + "/" + stats.len();
    },

    addUse = function (editor, widget) {
        if (this.doc == 0) return;
        this.storeEdits();
        if (typeof Rpgc.get(this.doc, "use", 0) == "table") {
            this.status = "这份文档已经声明了 use";
            return;
        }
        local first = this.effectOptions.len() > 0 ? Rpgc.asString(this.effectOptions[0]) : "";
        this.doc.use <- { consume = true, cooldown = 0.0, targetType = "self", effects = [first] };
        this.useEffectIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "声明 use（consumable 专属）";
    },

    removeUse = function (editor, widget) {
        if (this.doc == 0) return;
        if (!this.doc.rawin("use")) return;
        this.doc.rawdelete("use");
        this.useEffectIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "移除 use";
    },

    addUseEffect = function (editor, widget) {
        if (this.doc == 0) return;
        this.storeEdits();
        local use = Rpgc.get(this.doc, "use", 0);
        if (typeof use != "table") {
            this.status = "先声明 use 再添加效果";
            return;
        }
        local effects = Rpgc.get(use, "effects", []);
        if (effects.len() >= 8) {
            this.status = "use.effects 最多 8 条";
            return;
        }
        effects.append(this.nextEffect(effects));
        use.effects <- effects;
        this.useEffectIndex = effects.len() - 1;
        this.dirty = true;
        this.refresh();
        this.status = "新增 use effect 第 " + effects.len() + " 条";
    },

    removeUseEffect = function (editor, widget) {
        if (this.doc == 0) return;
        local use = Rpgc.get(this.doc, "use", 0);
        if (typeof use != "table") return;
        local effects = Rpgc.get(use, "effects", []);
        // The semantic gate requires a usable item to have at least one effect,
        // so this refuses locally and tells the author why, instead of handing
        // back a `systems.item-use-effects` only after saving.
        if (effects.len() <= 1) {
            this.status = "use 至少要留一条 effect（语义门要求非空）";
            return;
        }
        effects.remove(this.useEffectIndex);
        use.effects <- effects;
        this.useEffectIndex = 0;
        this.dirty = true;
        this.refresh();
        this.status = "删除一条 use effect";
    },

    moveEffectUp = function (editor, widget) { this.moveEffect(-1); },
    moveEffectDown = function (editor, widget) { this.moveEffect(1); },

    moveEffect = function (delta) {
        if (this.doc == 0) return;
        this.storeEdits();
        local use = Rpgc.get(this.doc, "use", 0);
        if (typeof use != "table") return;
        local effects = Rpgc.get(use, "effects", []);
        local to = this.useEffectIndex + delta;
        if (to < 0 || to >= effects.len()) return;
        local held = effects[this.useEffectIndex];
        effects[this.useEffectIndex] = effects[to];
        effects[to] = held;
        use.effects <- effects;
        this.useEffectIndex = to;
        this.dirty = true;
        this.refresh();
        this.status = "use.effects 顺序 " + (to + 1) + "/" + effects.len();
    },

    addTeaches = function (editor, widget) {
        if (this.doc == 0) return;
        this.storeEdits();
        if (typeof Rpgc.get(this.doc, "teaches", 0) == "table") {
            this.status = "这份文档已经声明了 teaches";
            return;
        }
        local first = this.artList.len() > 0 ? Rpgc.asString(this.artList[0]) : "";
        this.doc.teaches <- { art = first, skill = "" };
        this.dirty = true;
        this.refresh();
        this.status = "声明 teaches（manual 专属）";
    },

    removeTeaches = function (editor, widget) {
        if (this.doc == 0) return;
        if (!this.doc.rawin("teaches")) return;
        this.doc.rawdelete("teaches");
        this.dirty = true;
        this.refresh();
        this.status = "移除 teaches";
    },

    addRequires = function (editor, widget) {
        if (this.doc == 0) return;
        this.storeEdits();
        if (typeof Rpgc.get(this.doc, "requires", 0) == "table") {
            this.status = "这份文档已经声明了 requires";
            return;
        }
        local first = this.artList.len() > 0 ? Rpgc.asString(this.artList[0]) : "";
        this.doc.requires <- { level = 1, artId = first, minGrade = 1 };
        this.dirty = true;
        this.refresh();
        this.status = "声明 requires";
    },

    removeRequires = function (editor, widget) {
        if (this.doc == 0) return;
        if (!this.doc.rawin("requires")) return;
        this.doc.rawdelete("requires");
        this.dirty = true;
        this.refresh();
        this.status = "移除 requires";
    },

    // The diagnostics tab button: run the same gate the CLI runs, on the
    // in-memory document, so an author can iterate without staging anything.
    validate = function (editor, widget) {
        if (this.doc == 0) {
            this.status = "没有可校验的文档";
            return;
        }
        this.storeEdits();
        this.runGate();
        this.status = "item/" + Rpgc.asString(Rpgc.get(this.doc, "id", ""))
            + " 校验：" + this.diagnostics;
    },

    // ---------------------------------------------------------------- helpers

    // The host writes a `slider` as a one-element array and a
    // `dropdown`/`listbox` as the selected string (EditorHost.cpp:876-930), so
    // numeric slots are unwrapped once per frame instead of at every use.
    normalize = function () {
        this.itemIndex = Rpgc.intOf(this.itemIndex);
        this.statIndex = Rpgc.intOf(this.statIndex);
        this.useEffectIndex = Rpgc.intOf(this.useEffectIndex);
        this.itemValue = Rpgc.intOf(this.itemValue);
        this.itemMaxStack = Rpgc.intOf(this.itemMaxStack);
        this.itemWeight = Rpgc.numberOf(this.itemWeight);
        this.itemVolume = Rpgc.numberOf(this.itemVolume);
        this.statValue = Rpgc.numberOf(this.statValue);
        this.statPriority = Rpgc.intOf(this.statPriority);
        this.useCooldown = Rpgc.numberOf(this.useCooldown);
        this.requiresLevel = Rpgc.intOf(this.requiresLevel);
        this.requiresMinGrade = Rpgc.intOf(this.requiresMinGrade);
    },

    // `itemId` holds the dropdown's selected id; `itemIndex` may hold a listbox
    // label or an index. Accept either binding.
    resolveItemId = function () {
        local index = Rpgc.selectedIndexOf(this.itemList, this.itemId, this.itemIndex);
        if (index < 0) return "";
        this.itemIndex = index;
        return this.itemList[index];
    },

    // Neither vocabulary lives in this file: `equipSlots` comes from the single
    // rules document, and the effect / art / skill candidates come from the
    // project folders themselves. The panel only reads the authorities out and
    // offers them as dropdown options.
    loadOptions = function () {
        this.equipSlots = this.ruleSlots();
        this.effectOptions = RpgcProject.idsOf("effect");
        this.artList = RpgcProject.idsOf("art");
        this.skillList = RpgcProject.idsOf("skill");
    },

    ruleSlots = function () {
        local out = [];
        this.rules = 0;
        try {
            local rules = RpgcSystems.rulesDocument();
            if (typeof rules == "table") {
                this.rules = rules;
                out = RpgcSystems.equipmentSlotsOf(rules);
            }
        } catch (e) {
            this.rules = 0;
        }
        return out;
    },

    refresh = function () {
        if (this.doc == 0) return;
        this.itemId = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        this.itemDisplayName = Rpgc.asString(Rpgc.get(this.doc, "displayName", this.itemId));
        this.itemTitle = Rpgc.asString(Rpgc.get(this.doc, "title", this.itemDisplayName));
        this.itemDescription = Rpgc.asString(Rpgc.get(this.doc, "description", ""));
        this.itemCategory = Rpgc.asString(Rpgc.get(this.doc, "category", "material"));
        this.itemRarity = Rpgc.asString(Rpgc.get(this.doc, "rarity", "common"));
        this.itemValue = Rpgc.asInt(Rpgc.get(this.doc, "value", 0));
        this.itemMaxStack = Rpgc.asInt(Rpgc.get(this.doc, "maxStack", 1));
        this.itemWeight = Rpgc.asNumber(Rpgc.get(this.doc, "weight", 0));
        this.itemVolume = Rpgc.asNumber(Rpgc.get(this.doc, "volume", 0));
        this.itemEquipSlot = Rpgc.asString(Rpgc.get(this.doc, "equipSlot", ""));
        this.tagsLabel = "标签 (tags)：" + this.tagsText();
        this.extraLabel = "表现键 (extra)：" + this.extraText();
        this.loadOptions();
        this.refreshStats();
        this.refreshUse();
        this.refreshTeaches();
        this.refreshRequires();
        this.slotLabel = (this.itemEquipSlot == "" ? "无装备槽" : "装备槽 " + this.itemEquipSlot)
            + " · 加成 " + this.statList.len() + " 条";
        this.runGate();
    },

    tagsText = function () {
        local tags = Rpgc.get(this.doc, "tags", []);
        if (tags.len() == 0) return "（无）";
        local out = "";
        foreach (tag in tags) out += (out == "" ? "" : ", ") + Rpgc.asString(tag);
        return out;
    },

    extraText = function () {
        local extra = Rpgc.get(this.doc, "extra", 0);
        if (typeof extra != "table" || extra.len() == 0) return "（无）";
        local out = "";
        foreach (key, value in extra) {
            out += (out == "" ? "" : ", ") + ("" + key) + "=" + Rpgc.asString(value);
        }
        return out;
    },

    refreshStats = function () {
        local stats = Rpgc.get(this.doc, "equipStats", []);
        local rows = [];
        for (local i = 0; i < stats.len(); i += 1) {
            rows.append((i + 1) + ". " + Rpgc.asString(Rpgc.get(stats[i], "attribute", "?"))
                + " " + Rpgc.asString(Rpgc.get(stats[i], "op", "add"))
                + " " + format("%.3f", Rpgc.asNumber(Rpgc.get(stats[i], "value", 0))));
        }
        this.statList = rows;
        if (this.statIndex >= stats.len()) this.statIndex = 0;
        this.loadStat();
    },

    loadStat = function () {
        local stats = Rpgc.get(this.doc, "equipStats", []);
        if (this.statIndex < 0 || this.statIndex >= stats.len()) {
            this.statAttribute = "";
            this.statOp = "add";
            this.statValue = 0.0;
            this.statPriority = 0;
            return;
        }
        local stat = stats[this.statIndex];
        this.statAttribute = Rpgc.asString(Rpgc.get(stat, "attribute", ""));
        this.statOp = Rpgc.asString(Rpgc.get(stat, "op", "add"));
        this.statValue = Rpgc.asNumber(Rpgc.get(stat, "value", 0));
        this.statPriority = Rpgc.asInt(Rpgc.get(stat, "priority", 0));
    },

    refreshUse = function () {
        local use = Rpgc.get(this.doc, "use", 0);
        this.useDeclared = (typeof use == "table");
        if (!this.useDeclared) {
            this.useEffectList = [];
            this.useEffectIndex = 0;
            this.effectId = "";
            this.useLabel = "未声明 use（category=consumable 时必须有）";
            return;
        }
        this.useConsume = (Rpgc.get(use, "consume", true) == true);
        this.useCooldown = Rpgc.asNumber(Rpgc.get(use, "cooldown", 0));
        this.useTargetType = Rpgc.asString(Rpgc.get(use, "targetType", "self"));
        local effects = Rpgc.get(use, "effects", []);
        local rows = [];
        foreach (effect in effects) rows.append(Rpgc.asString(effect));
        this.useEffectList = rows;
        if (this.useEffectIndex >= rows.len()) this.useEffectIndex = 0;
        this.loadUseEffect();
        this.useLabel = "use：消耗=" + (this.useConsume ? "是" : "否")
            + " · 目标=" + this.useTargetType + " · 效果 " + rows.len() + " 条";
    },

    loadUseEffect = function () {
        if (this.useEffectIndex < 0 || this.useEffectIndex >= this.useEffectList.len()) {
            this.effectId = "";
            return;
        }
        this.effectId = Rpgc.asString(this.useEffectList[this.useEffectIndex]);
    },

    refreshTeaches = function () {
        local teaches = Rpgc.get(this.doc, "teaches", 0);
        this.teachesDeclared = (typeof teaches == "table");
        if (!this.teachesDeclared) {
            this.teachesArt = "";
            this.teachesSkill = "";
            this.teachesLabel = "未声明 teaches（category=manual 时必须有）";
            return;
        }
        this.teachesArt = Rpgc.asString(Rpgc.get(teaches, "art", ""));
        this.teachesSkill = Rpgc.asString(Rpgc.get(teaches, "skill", ""));
        this.teachesLabel = "teaches：art=" + (this.teachesArt == "" ? "—" : this.teachesArt)
            + " · skill=" + (this.teachesSkill == "" ? "—" : this.teachesSkill);
    },

    refreshRequires = function () {
        local requires = Rpgc.get(this.doc, "requires", 0);
        this.requiresDeclared = (typeof requires == "table");
        if (!this.requiresDeclared) {
            this.requiresLevel = 1;
            this.requiresArtId = "";
            this.requiresMinGrade = 1;
            this.requiresLabel = "未声明 requires（可选）";
            return;
        }
        this.requiresLevel = Rpgc.asInt(Rpgc.get(requires, "level", 1));
        this.requiresArtId = Rpgc.asString(Rpgc.get(requires, "artId", ""));
        this.requiresMinGrade = Rpgc.asInt(Rpgc.get(requires, "minGrade", 1));
        this.requiresLabel = "requires：level=" + this.requiresLevel
            + " · artId=" + (this.requiresArtId == "" ? "—" : this.requiresArtId)
            + " · minGrade=" + this.requiresMinGrade;
    },

    // Pick the first candidate that is not used yet, so holding down "add" does
    // not stack duplicate rows.
    nextEffect = function (effects) {
        foreach (candidate in this.effectOptions) {
            local used = false;
            foreach (existing in effects) {
                if (Rpgc.asString(existing) == Rpgc.asString(candidate)) used = true;
            }
            if (!used) return Rpgc.asString(candidate);
        }
        return this.effectOptions.len() > 0 ? Rpgc.asString(this.effectOptions[0]) : "";
    },

    // Write the form back into the document before any structural change or
    // save.
    //
    // Every assignment here uses `<-`, not `=`: in this EveScript VM
    // `t.newSlot = v` raises "the index 'newSlot' does not exist", and only `<-`
    // creates a slot. Documents are decoded from JSON, so an optional field is
    // simply absent, and the `use` / `teaches` / `requires` fields and the
    // `equipStats[i]` fields are exactly that case; skill.vm.nut records the
    // same measurement.
    storeEdits = function () {
        if (this.doc == 0) return;
        // Identity fields are editable: changing an id renames the file.
        local id = Rpgc.asString(this.itemId);
        if (Rpgc.validId(id)) this.doc.id <- id;
        this.doc.displayName <- Rpgc.asString(this.itemDisplayName);
        this.doc.title <- Rpgc.asString(this.itemTitle);
        this.doc.description <- Rpgc.asString(this.itemDescription);
        this.doc.category <- Rpgc.asString(this.itemCategory);
        this.doc.rarity <- Rpgc.asString(this.itemRarity);
        this.doc.maxStack <- Rpgc.intOf(this.itemMaxStack);
        this.doc.weight <- Rpgc.numberOf(this.itemWeight);
        this.doc.volume <- Rpgc.numberOf(this.itemVolume);
        this.doc.value <- Rpgc.intOf(this.itemValue);

        // An empty equipSlot is not written into the document: the schema allows
        // the empty string, but writing it only adds a diff line, and
        // `systems.item-slot-unexpected` triggers on "non-empty and not
        // equipment".
        local slot = Rpgc.asString(this.itemEquipSlot);
        if (slot != "") this.doc.equipSlot <- slot;
        else if (this.doc.rawin("equipSlot")) this.doc.rawdelete("equipSlot");

        local stats = Rpgc.get(this.doc, "equipStats", []);
        if (this.statIndex >= 0 && this.statIndex < stats.len()) {
            local stat = stats[this.statIndex];
            stat.attribute <- Rpgc.asString(this.statAttribute);
            stat.op <- Rpgc.asString(this.statOp);
            stat.value <- Rpgc.numberOf(this.statValue);
            stat.priority <- Rpgc.intOf(this.statPriority);
        }

        local use = Rpgc.get(this.doc, "use", 0);
        if (typeof use == "table") {
            use.consume <- (this.useConsume == true);
            use.cooldown <- Rpgc.numberOf(this.useCooldown);
            use.targetType <- Rpgc.asString(this.useTargetType);
            local effects = Rpgc.get(use, "effects", []);
            if (this.useEffectIndex >= 0 && this.useEffectIndex < effects.len()) {
                effects[this.useEffectIndex] = Rpgc.asString(this.effectId);
                use.effects <- effects;
            }
        }

        local teaches = Rpgc.get(this.doc, "teaches", 0);
        if (typeof teaches == "table") {
            teaches.art <- Rpgc.asString(this.teachesArt);
            teaches.skill <- Rpgc.asString(this.teachesSkill);
        }

        local requires = Rpgc.get(this.doc, "requires", 0);
        if (typeof requires == "table") {
            requires.level <- Rpgc.intOf(this.requiresLevel);
            requires.artId <- Rpgc.asString(this.requiresArtId);
            requires.minGrade <- Rpgc.intOf(this.requiresMinGrade);
        }
    },

    // The cross-document gate is shaped as "ask once for the whole project", but
    // the panel cares about this one document: it picks out the findings that
    // carry the `item/<id> ` prefix, and rewrites none of the rules.
    crossDiagnostics = function () {
        local out = [];
        if (typeof this.rules != "table" || this.doc == 0) return out;
        local prefix = "item/" + Rpgc.asString(Rpgc.get(this.doc, "id", "")) + " ";
        local all = [];
        try {
            all = RpgcSystems.itemCrossDiagnostics(this.rules, []);
        } catch (e) {
            return out;
        }
        foreach (d in all) {
            if (Rpgc.asString(Rpgc.get(d, "message", "")).find(prefix) == 0) out.append(d);
        }
        return out;
    },

    // Schema layer + semantic gate + this document's cross-document gate, in one
    // run -- the same gate the CLI runs.
    runGate = function () {
        if (this.doc == 0) return;
        local result = 0;
        try {
            result = RpgcValidate.validateDocument("item", this.doc);
        } catch (e) {
            this.diagnostics = "gate unavailable: " + e;
            return;
        }
        Rpgc.append(result, this.crossDiagnostics());
        this.report(result);
    },

    report = function (result) {
        this.diagnostics = Rpgc.summary(result);
        if (!result.ok) {
            local first = Rpgc.firstError(result);
            if (first != null) this.status = "[" + first.path + "] " + first.message;
        }
    },

    status_line = function () {
        return this.itemId + " | " + this.itemCategory + "/" + this.itemRarity
            + " | stats " + this.statList.len()
            + " | use " + (this.useDeclared ? "on" : "off")
            + " | " + this.diagnostics
            + (this.dirty ? " | DIRTY" : "");
    },

    // --------------------------------------------------------------- drawer
    update = function (dt) {
        this.normalize();
        this.pollFolder(dt);
    },

    // The main window draws this card's "runtime look": identity, category and
    // rarity, slot, price and the first few equipment stats. The rectangle comes
    // from eve.host.widgetRect, so it follows the panel when it is moved or
    // resized; with no rectangle (the editor is not up) nothing is drawn.
    draw = function () {
        local rect = this.canvasRect();
        if (rect.width <= 1.0 || rect.height <= 1.0) return;
        local gfx = eve.Graphics();
        gfx.drawSolidRect(rect.x, rect.y, rect.width, rect.height, 0.07, 0.08, 0.12, 1.0);
        this.cardFrame(gfx, rect.x + 10.0, rect.y + 10.0, rect.width - 20.0, rect.height - 20.0);

        local x = rect.x + 26.0;
        local y = rect.y + 28.0;
        this.cardText(gfx, this.itemTitle == "" ? this.itemId : this.itemTitle,
                      x, y, 0.95, 0.86, 0.55, 1.3);
        y += 32.0;
        this.cardText(gfx, this.itemId, x, y, 0.70, 0.74, 0.82, 0.95);
        y += 26.0;
        this.cardText(gfx, this.itemCategory + " · " + this.itemRarity,
                      x, y, 0.92, 0.72, 0.30, 1.0);
        y += 24.0;
        this.cardText(gfx, "价值 " + this.itemValue + " · 堆叠 " + this.itemMaxStack
                      + " · 重 " + format("%.2f", this.itemWeight)
                      + " · 体积 " + format("%.2f", this.itemVolume),
                      x, y, 0.78, 0.80, 0.86, 0.95);
        y += 22.0;
        this.cardText(gfx, "装备槽 " + (this.itemEquipSlot == "" ? "—" : this.itemEquipSlot),
                      x, y, 0.78, 0.80, 0.86, 0.95);
        y += 22.0;
        this.cardText(gfx, this.tagsLabel, x, y, 0.66, 0.70, 0.78, 0.9);
        y += 30.0;

        if (this.statList.len() == 0) {
            this.cardText(gfx, "无装备加成", x, y, 0.55, 0.58, 0.66, 0.95);
            return;
        }
        this.cardText(gfx, "装备加成", x, y, 0.62, 0.66, 0.74, 0.95);
        y += 24.0;
        for (local i = 0; i < this.statList.len() && i < 6; i += 1) {
            this.cardText(gfx, this.statList[i], x, y, 0.86, 0.88, 0.94, 0.95);
            y += 21.0;
        }
    },

    cardFrame = function (gfx, x, y, w, h) {
        if (w <= 0.0 || h <= 0.0) return;
        gfx.drawSolidRect(x, y, w, 2.0, 0.92, 0.72, 0.30, 0.9);
        gfx.drawSolidRect(x, y + h - 2.0, w, 2.0, 0.92, 0.72, 0.30, 0.9);
        gfx.drawSolidRect(x, y, 2.0, h, 0.92, 0.72, 0.30, 0.9);
        gfx.drawSolidRect(x + w - 2.0, y, 2.0, h, 0.92, 0.72, 0.30, 0.9);
    },

    cardText = function (gfx, text, x, y, r, g, b, scale) {
        try { gfx.print("" + text, x, y, r, g, b, 1.0, scale); } catch (e) {}
    },

    canvasRect = function () {
        local out = {};
        out.x <- 0.0;
        out.y <- 0.0;
        out.width <- 0.0;
        out.height <- 0.0;
        try {
            local parsed = RpgcJson.parse(eve.host.widgetRect("item", "card"));
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
        if (widget == "item") {
            // Picking a row loads it: the folder listing is the document list,
            // so there is no second "open" gesture to wait for.
            this.itemId = Rpgc.asString(value);
            this.normalize();
            this.loadSelected("item", "");
            return;
        }
        if (widget == "item-stat") {
            // Write the current row's form back into the document before moving
            // rows, or the last input is lost.
            this.storeEdits();
            this.statIndex = Rpgc.intOf(value);
            this.normalize();
            this.loadStat();
            return;
        }
        if (widget == "use-effect") {
            this.storeEdits();
            local index = Rpgc.selectedIndexOf(this.useEffectList, Rpgc.asString(value),
                                                this.useEffectIndex);
            this.useEffectIndex = index < 0 ? 0 : index;
            this.loadUseEffect();
            return;
        }
        // The remaining onChange bindings are written into their slot by the
        // host first; here they are only unwrapped and stored back uniformly.
        this.normalize();
        this.storeEdits();
    }
};

RpgcHost.register("item", {
    update = function (dt) { ItemVM.update(dt); },
    draw = function () { ItemVM.draw(); },
    status = function () { return ItemVM.status_line(); }
});

// Start-up: scan the project folder and show its first item. No argument, no
// document chooser -- the editor opens onto the game folder's data. A failed
// scan must not take the host down with it, so the whole thing is wrapped in
// try/catch.
try {
    ItemVM.loadFolder();
    ItemVM.loadSelected("item", "");
} catch (e) {
    ItemVM.status = "" + e;
    if ("log" in eve) eve.log("error", "item: initial folder load: " + e);
}
