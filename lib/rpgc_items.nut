// EVEngine workflow / rpg-classic — the item system.
//
// `content/items/*.json` describe 25 items in a shape with TWO halves. The
// engine half (`id` / `displayName` / `maxStack` / `weight` / `volume` /
// `category` / `tags` / `equipSlot` / `extra`) is what `ItemRegistry` reads;
// `equipStats` / `use` / `teaches` are the project half. docs/08 called the
// engine "the other half" of this kind and that was true of the DOCUMENTS --
// what was missing was a runtime.
//
// The engine's runtime is not reachable from this build. `inventory` is declared
// with `SCRIPT Inventory` and no `SLOT`
// (cmake/module_manifest/core_foundation.cmake:105), and `src/scripts/load.nut`
// only instantiates modules that name a slot, so `eve.Inventory` is not a class
// on the `eve` table at all. That is not an inference: tools/modules_check.nut
// asserts `("Inventory" in eve) == false`. docs/08 §7 used to show
// `eve.Inventory()` -- code that cannot run here.
//
// So this module is the project-side restatement, exactly as `RpgcBattle` is for
// `rpg`. Every rule below is written against the source:
//
//   * a definition is parsed from nine keys and a duplicate id overwrites the
//     earlier one (`Item.cpp:45-80`);
//   * `maxStack <= 0` is coerced to 1 (`Item.cpp:48`, again at
//     `InventorySystem.cpp:330`);
//   * `addItem` tops up existing stacks first and opens empty ones second, and
//     returns how many actually landed -- a partial add is a normal outcome
//     (`InventorySystem.cpp:369-430`);
//   * the default capacity policy is `slotsAndWeight`, and a weight or volume
//     limit of `<= 0` means "this dimension is unlimited" (`Bag.h:114-117`);
//   * an equipment slot holds a WHOLE stack, and a swap puts the previous stack
//     back into the bag slot the new item came from
//     (`InventorySystem.cpp:718-745`) -- which is why the gate refuses
//     equipment with `maxStack > 1` (`systems.item-equipment-stacks`);
//   * `equipSlot` IS compared: a non-empty `equipSlot` must equal the slot name
//     being equipped into (`Equipment.cpp:108-111`). What the engine does NOT do
//     is derive `defineSlot` calls from it, so the slot NAMES still come from
//     the project -- here, `rules.equipmentSlots`.
//
// What this module does NOT do: it never loads a texture, never reads the mouse,
// never writes a file. Everything is pure computation over document values, so a
// whole bag can be exercised in a headless `-r` script and give the same answer
// twice -- tools/modules_check.nut does exactly that.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcProject } from "./rpgc_project.nut"

export class RpgcItems {
}

RpgcItems.version <- 1

// The engine's `Bag` defaults (`Bag.h:115-118`), same three names, so an adapter
// that later gets a real engine Bag configures it the same way instead of
// inventing a second convention.
RpgcItems.defaultCapacityPolicy <- "slotsAndWeight"
RpgcItems.defaultStackRule <- "sameItem"

// How many slots a fresh bag has. The engine takes this as a constructor
// argument and imposes no default (`Bag.h:23`); 24 is the project's number and
// it is a runtime parameter, not a document field.
RpgcItems.defaultBagSlots <- 24

RpgcItems.slotOf <- function (def) {
    return typeof def == "table" ? Rpgc.asString(Rpgc.get(def, "equipSlot", "")) : "";
}

RpgcItems.maxStackOf <- function (def) {
    local raw = Rpgc.asInt(Rpgc.get(def, "maxStack", 0));
    // `Item.cpp:48` coerces a non-positive maxStack to 1 without a word. The
    // schema already refuses it (minimum 1), so this branch exists to be
    // IDENTICAL to the engine for a definition that reached the runtime by some
    // other road, not because the gate lets one through.
    return raw > 0 ? raw : 1;
}

RpgcItems.categoryOf <- function (def) {
    return Rpgc.asString(Rpgc.get(def, "category", ""));
}

// The workflow's closed set, mirrored from `RpgcSystems.itemEquipmentCategories`.
RpgcItems.isEquipment <- function (def) {
    local category = this.categoryOf(def);
    return category == "weapon" || category == "armor" || category == "accessory";
}

RpgcItems.useOf <- function (def) {
    local use = typeof def == "table" ? Rpgc.get(def, "use", 0) : 0;
    return typeof use == "table" ? use : 0;
}

RpgcItems.teachesOf <- function (def) {
    local teaches = typeof def == "table" ? Rpgc.get(def, "teaches", 0) : 0;
    return typeof teaches == "table" ? teaches : 0;
}

// A definition is usable in a fight when it carries a `use` block with at least
// one effect. `RpgcSystems.itemDiagnostics` enforces exactly that shape on a
// `consumable`, so this is a runtime mirror rather than a second rule.
RpgcItems.usableInBattle <- function (def) {
    local use = this.useOf(def);
    if (use == 0) return false;
    return Rpgc.get(use, "effects", []).len() > 0;
}

// ------------------------------------------------------------------ loading
//
// One `Result` carrying every item document plus the slot vocabulary the rule
// document owns. `items` is keyed by id, which is the access the engine's
// `ItemRegistry::find` gives -- including the same silent overwrite on a
// duplicate id, except that a duplicate is reported here (the gate refuses it
// even earlier, so this is the belt to that pair of braces).

RpgcItems.loadProject <- function () {
    local diagnostics = [];

    local items = {};
    local loaded = RpgcProject.loadKind("item");
    foreach (d in loaded.diagnostics) diagnostics.append(d);
    foreach (document in loaded.value) {
        local id = Rpgc.asString(Rpgc.get(document, "id", ""));
        if (id == "") continue;
        if (items.rawin(id)) {
            diagnostics.append(Rpgc.warn("items.definition-overwritten",
                "item '" + id + "' is defined twice; the later document wins",
                RpgcProject.pathOf("item", id),
                "Item.cpp:50 overwrites the registry entry without a word"));
        }
        items.rawset(id, document);
    }

    local rulesRead = RpgcProject.loadKind("rules");
    local rules = rulesRead.value.len() > 0 ? rulesRead.value[0] : 0;
    if (typeof rules != "table") {
        diagnostics.append(Rpgc.error("items.no-rules",
            "no rules document is loaded, so the equipment slot vocabulary is unknown",
            "$", ""));
    }

    local slots = [];
    foreach (value in Rpgc.get(rules, "equipmentSlots", [])) {
        local name = Rpgc.asString(value);
        if (name != "") slots.append(name);
    }

    local config = {};
    config.items <- items;
    config.slots <- slots;
    config.rules <- rules;
    if (Rpgc.errorCount(diagnostics) > 0) return Rpgc.fail(diagnostics);
    return Rpgc.result(config, diagnostics);
}

RpgcItems.definitionOf <- function (config, itemId) {
    if (typeof config != "table") return 0;
    local items = Rpgc.get(config, "items", 0);
    if (typeof items != "table" || !items.rawin(itemId)) return 0;
    return items.rawget(itemId);
}

// ---------------------------------------------------------------- the bag
//
// A bag is a plain value so it can be snapshotted, printed and compared: a
// fixed-length `slots` array of `{ itemId, quantity }` plus the three policy
// names the engine's Bag carries. An empty stack is `itemId == ""`.

RpgcItems.emptyStack <- function () {
    local stack = {};
    stack.itemId <- "";
    stack.quantity <- 0;
    return stack;
}

RpgcItems.newBag <- function (slotCount, id) {
    local count = Rpgc.asInt(slotCount);
    if (count <= 0) count = this.defaultBagSlots;
    local slots = [];
    for (local i = 0; i < count; i += 1) slots.append(this.emptyStack());
    local bag = {};
    bag.id <- (id == null || id == "") ? "bag" : "" + id;
    bag.slotCount <- count;
    bag.maxWeight <- 0.0;                        // <= 0: unlimited (Bag.h:114)
    bag.maxVolume <- 0.0;
    bag.capacityPolicy <- this.defaultCapacityPolicy;
    bag.stackRule <- this.defaultStackRule;
    bag.slots <- slots;
    return bag;
}

RpgcItems.isEmpty <- function (stack) {
    return stack.itemId == "" || Rpgc.asInt(Rpgc.get(stack, "quantity", 0)) <= 0;
}

// `InventorySystem::freeSpaceInSlot` (InventorySystem.cpp:327-347), including the
// `maxStack <= 0` correction it repeats.
RpgcItems.freeSpaceInSlot <- function (bag, slot, def) {
    if (slot < 0 || slot >= bag.slots.len()) return 0;
    local maxStack = this.maxStackOf(def);
    local stack = bag.slots[slot];
    if (this.isEmpty(stack)) return maxStack;
    if (stack.itemId != Rpgc.asString(Rpgc.get(def, "id", ""))) return 0;
    local space = maxStack - Rpgc.asInt(Rpgc.get(stack, "quantity", 0));
    return space > 0 ? space : 0;
}

RpgcItems.countOf <- function (bag, itemId) {
    local total = 0;
    foreach (stack in bag.slots) {
        if (!this.isEmpty(stack) && stack.itemId == itemId) {
            total += Rpgc.asInt(Rpgc.get(stack, "quantity", 0));
        }
    }
    return total;
}

RpgcItems.usedSlots <- function (bag) {
    local used = 0;
    foreach (stack in bag.slots) if (!this.isEmpty(stack)) used += 1;
    return used;
}

RpgcItems.usedWeight <- function (bag, config) {
    local total = 0.0;
    foreach (stack in bag.slots) {
        if (this.isEmpty(stack)) continue;
        local def = this.definitionOf(config, stack.itemId);
        if (def == 0) continue;
        total += Rpgc.asNumber(Rpgc.get(def, "weight", 0))
            * Rpgc.asNumber(Rpgc.get(stack, "quantity", 0));
    }
    return total;
}

RpgcItems.usedVolume <- function (bag, config) {
    local total = 0.0;
    foreach (stack in bag.slots) {
        if (this.isEmpty(stack)) continue;
        local def = this.definitionOf(config, stack.itemId);
        if (def == 0) continue;
        total += Rpgc.asNumber(Rpgc.get(def, "volume", 0))
            * Rpgc.asNumber(Rpgc.get(stack, "quantity", 0));
    }
    return total;
}

// The bag as the HUD wants it: one row per non-empty stack, in slot order, with
// the display name the engine would have answered from `getItemDisplayName`.
RpgcItems.entries <- function (bag, config) {
    local out = [];
    for (local i = 0; i < bag.slots.len(); i += 1) {
        local stack = bag.slots[i];
        if (this.isEmpty(stack)) continue;
        local def = this.definitionOf(config, stack.itemId);
        local row = {};
        row.slot <- i;
        row.itemId <- stack.itemId;
        row.quantity <- Rpgc.asInt(Rpgc.get(stack, "quantity", 0));
        row.displayName <- def == 0
            ? stack.itemId
            : Rpgc.asString(Rpgc.get(def, "displayName", stack.itemId));
        row.category <- def == 0 ? "" : this.categoryOf(def);
        row.equipment <- def != 0 && this.isEquipment(def);
        row.usable <- def != 0 && this.usableInBattle(def);
        out.append(row);
    }
    return out;
}

// --------------------------------------------------------- capacity / add
//
// The refusal reasons are the engine's own strings (`no_slot`, `over_weight`,
// `over_volume` -- InventorySystem.cpp:162-193) so a caller that later swaps in a
// real Bag reads the same words. `capacityPolicy` is checked first and FAILS
// CLOSED: a policy this runtime does not implement is an error, not a bag with
// no limits (`InventorySystem.cpp:317-325` refuses an unknown name too).

RpgcItems.canAdd <- function (bag, config, itemId, quantity) {
    local count = Rpgc.asInt(quantity);
    if (count <= 0) {
        return Rpgc.fail([Rpgc.error("items.invalid-quantity",
            "quantity must be at least 1, got " + count, "$", "")]);
    }
    local def = this.definitionOf(config, itemId);
    if (def == 0) {
        return Rpgc.fail([Rpgc.error("items.unknown-item",
            "no item definition for '" + itemId + "'", "$",
            "register it as a content/items document")]);
    }
    local policy = Rpgc.asString(Rpgc.get(bag, "capacityPolicy", this.defaultCapacityPolicy));
    if (policy != "slotsAndWeight" && policy != "slots" && policy != "weight"
        && policy != "unlimited") {
        return Rpgc.fail([Rpgc.error("items.unknown-policy",
            "capacity policy '" + policy + "' is not implemented by this runtime", "$",
            "the engine refuses an unregistered policy as well (InventorySystem.cpp:321)")]);
    }

    if (policy != "unlimited") {
        local need = count;
        for (local i = 0; i < bag.slots.len() && need > 0; i += 1) {
            local space = this.freeSpaceInSlot(bag, i, def);
            if (space > 0) need -= space;
        }
        if (need > 0) {
            return Rpgc.fail([Rpgc.error("items.no-slot",
                "no_slot: " + count + " of '" + itemId + "' does not fit in "
                + bag.slots.len() + " slots", "$", "")]);
        }
    }
    if (policy == "slotsAndWeight" || policy == "weight") {
        local limit = Rpgc.asNumber(Rpgc.get(bag, "maxWeight", 0));
        if (limit > 0.0) {
            local add = Rpgc.asNumber(Rpgc.get(def, "weight", 0)) * count;
            if (this.usedWeight(bag, config) + add > limit + 0.000001) {
                return Rpgc.fail([Rpgc.error("items.over-weight",
                    "over_weight: " + count + " of '" + itemId + "' would exceed the "
                    + limit + " weight limit", "$", "")]);
            }
        }
    }
    if (policy == "slotsAndWeight" || policy == "volume") {
        local limit = Rpgc.asNumber(Rpgc.get(bag, "maxVolume", 0));
        if (limit > 0.0) {
            local add = Rpgc.asNumber(Rpgc.get(def, "volume", 0)) * count;
            if (this.usedVolume(bag, config) + add > limit + 0.000001) {
                return Rpgc.fail([Rpgc.error("items.over-volume",
                    "over_volume: " + count + " of '" + itemId + "' would exceed the "
                    + limit + " volume limit", "$", "")]);
            }
        }
    }
    return Rpgc.ok(true);
}

// The largest quantity the CURRENT bag still accepts, binary-searched the way
// `InventorySystem.cpp:380-390` does. `canAdd` is the predicate, so the search
// cannot drift away from the check.
RpgcItems.maxFittable <- function (bag, config, def, space, remaining) {
    local lo = 0;
    local hi = space < remaining ? space : remaining;
    while (lo < hi) {
        local mid = lo + (hi - lo + 1) / 2;
        if (this.canAdd(bag, config, Rpgc.asString(Rpgc.get(def, "id", "")), mid).ok) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return lo;
}

// `InventorySystem::addItemImpl` (InventorySystem.cpp:369-430). Pass 0 tops up
// existing stacks, pass 1 opens empty ones, and each step places as much as
// capacity still allows. The result carries `added` AND `remaining`, because a
// partial add is a normal outcome and a caller that assumes otherwise is the
// bug this shape prevents.
RpgcItems.add <- function (bag, config, itemId, quantity) {
    local def = this.definitionOf(config, itemId);
    if (def == 0) {
        return Rpgc.fail([Rpgc.error("items.unknown-item",
            "no item definition for '" + itemId + "'", "$", "")]);
    }
    local remaining = Rpgc.asInt(quantity);
    if (remaining <= 0) {
        return Rpgc.fail([Rpgc.error("items.invalid-quantity",
            "quantity must be at least 1, got " + remaining, "$", "")]);
    }
    local added = 0;
    for (local pass = 0; pass < 2 && remaining > 0; pass += 1) {
        for (local i = 0; i < bag.slots.len() && remaining > 0; i += 1) {
            local stack = bag.slots[i];
            local empty = this.isEmpty(stack);
            if (pass == 0 && empty) continue;
            if (pass == 1 && !empty) continue;
            local space = this.freeSpaceInSlot(bag, i, def);
            if (space <= 0) continue;
            local put = this.maxFittable(bag, config, def, space, remaining);
            if (put <= 0) continue;
            if (empty) stack.itemId = itemId;
            stack.quantity = Rpgc.asInt(Rpgc.get(stack, "quantity", 0)) + put;
            remaining -= put;
            added += put;
        }
    }
    local value = {};
    value.added <- added;
    value.requested <- Rpgc.asInt(quantity);
    value.remaining <- remaining;
    return Rpgc.ok(value);
}

RpgcItems.remove <- function (bag, itemId, quantity) {
    local want = Rpgc.asInt(quantity);
    if (want <= 0) {
        return Rpgc.fail([Rpgc.error("items.invalid-quantity",
            "quantity must be at least 1, got " + want, "$", "")]);
    }
    local removed = 0;
    for (local i = 0; i < bag.slots.len() && removed < want; i += 1) {
        local stack = bag.slots[i];
        if (this.isEmpty(stack) || stack.itemId != itemId) continue;
        local have = Rpgc.asInt(Rpgc.get(stack, "quantity", 0));
        local take = (want - removed) < have ? (want - removed) : have;
        stack.quantity = have - take;
        if (stack.quantity <= 0) {
            stack.itemId = "";
            stack.quantity = 0;
        }
        removed += take;
    }
    local value = {};
    value.removed <- removed;
    value.requested <- want;
    return Rpgc.ok(value);
}

// ----------------------------------------------------------- equipment
//
// `rules.equipmentSlots` is the only copy of the slot vocabulary
// (`RpgcSystems.equipmentSlotsOf` reads the same field), so the runtime cannot
// define a slot the gate has never seen, and an item whose `equipSlot` is not in
// that list cannot reach a set built from it.

RpgcItems.newEquipmentSet <- function (config, id) {
    local set = {};
    set.id <- (id == null || id == "") ? "equip" : "" + id;
    set.order <- [];
    set.slots <- {};
    foreach (name in Rpgc.get(config, "slots", [])) this.defineSlot(set, name);
    return set;
}

RpgcItems.defineSlot <- function (set, name) {
    if (name == "") return false;
    if (!(name in set.slots)) {
        set.order.append(name);
        set.slots.rawset(name, this.emptyStack());
    }
    return true;
}

RpgcItems.equipped <- function (set, slot) {
    if (!(slot in set.slots)) return "";
    return Rpgc.asString(Rpgc.get(set.slots.rawget(slot), "itemId", ""));
}

RpgcItems.findSlot <- function (bag, itemId) {
    for (local i = 0; i < bag.slots.len(); i += 1) {
        local stack = bag.slots[i];
        if (!this.isEmpty(stack) && stack.itemId == itemId) return i;
    }
    return -1;
}

// One logical item per slot: `equipFromBag` moves the WHOLE stack into the
// equipment slot (`InventorySystem.cpp:718-745`), which is why
// `systems.item-equipment-stacks` refuses equipment with `maxStack > 1`.
// A swap puts whatever was worn back into the bag slot the new item came from,
// so this can never need more room than the bag already had.
RpgcItems.equip <- function (bag, set, config, itemId) {
    local def = this.definitionOf(config, itemId);
    if (def == 0) {
        return Rpgc.fail([Rpgc.error("items.unknown-item",
            "no item definition for '" + itemId + "'", "$", "")]);
    }
    local slot = this.slotOf(def);
    if (slot == "") {
        return Rpgc.fail([Rpgc.error("items.not-equipment",
            "'" + itemId + "' declares no equipSlot, so no slot can hold it", "$", "")]);
    }
    if (!(slot in set.slots)) {
        return Rpgc.fail([Rpgc.error("items.unknown-slot",
            "slot '" + slot + "' is not in the rule document's equipmentSlots", "$",
            "build the set from rules.equipmentSlots, the only copy of the vocabulary")]);
    }
    local index = this.findSlot(bag, itemId);
    if (index < 0) {
        return Rpgc.fail([Rpgc.error("items.not-held",
            "the bag holds no '" + itemId + "'", "$", "")]);
    }
    local moving = bag.slots[index];
    local worn = set.slots.rawget(slot);
    bag.slots[index] = worn;
    set.slots.rawset(slot, moving);

    local value = {};
    value.slot <- slot;
    value.itemId <- itemId;
    value.quantity <- Rpgc.asInt(Rpgc.get(moving, "quantity", 0));
    value.replaced <- Rpgc.asString(Rpgc.get(worn, "itemId", ""));
    return Rpgc.ok(value);
}

// The mirror of `InventorySystem::unequipToBag`. The engine moves the stack and
// keeps whatever the bag refused in the slot, so the result says how much left
// and how much stayed -- an unequip that silently loses an item is worse than
// one that refuses.
RpgcItems.unequip <- function (bag, set, config, slot) {
    if (!(slot in set.slots)) {
        return Rpgc.fail([Rpgc.error("items.unknown-slot",
            "slot '" + slot + "' is not defined on this equipment set", "$", "")]);
    }
    local worn = set.slots.rawget(slot);
    local itemId = Rpgc.asString(Rpgc.get(worn, "itemId", ""));
    if (itemId == "") {
        return Rpgc.fail([Rpgc.error("items.slot-empty",
            "slot '" + slot + "' is already empty", "$", "")]);
    }
    local quantity = Rpgc.asInt(Rpgc.get(worn, "quantity", 0));
    if (quantity <= 0) quantity = 1;
    local placed = this.add(bag, config, itemId, quantity);
    local moved = placed.ok ? placed.value.added : 0;

    local kept = this.emptyStack();
    if (moved < quantity) {
        kept.itemId = itemId;
        kept.quantity = quantity - moved;
    }
    set.slots.rawset(slot, kept);

    local value = {};
    value.slot <- slot;
    value.itemId <- itemId;
    value.moved <- moved;
    value.kept <- quantity - moved;
    return Rpgc.ok(value);
}

// ------------------------------------------------------- equipment maths
//
// `EquipmentSystem::syncEquipModifiers` (EquipmentSystem.cpp:60-79) removes every
// modifier whose source is `equip:<slot>` and then re-applies that slot's stats.
// This is the list that loop would produce, with the same source names, so
// applying it is idempotent across a re-equip or a hot reload.

RpgcItems.modifiersOf <- function (set, config) {
    local out = [];
    foreach (slot in set.order) {
        local itemId = this.equipped(set, slot);
        if (itemId == "") continue;
        local def = this.definitionOf(config, itemId);
        if (def == 0) continue;
        local source = "equip:" + slot;
        foreach (stat in Rpgc.get(def, "equipStats", [])) {
            local attribute = Rpgc.asString(Rpgc.get(stat, "attribute", ""));
            if (attribute == "") continue;
            local modifier = {};
            modifier.attribute <- attribute;
            modifier.op <- Rpgc.asString(Rpgc.get(stat, "op", "add"));
            modifier.value <- Rpgc.asNumber(Rpgc.get(stat, "value", 0));
            modifier.priority <- Rpgc.asInt(Rpgc.get(stat, "priority", 0));
            modifier.source <- source;
            modifier.itemId <- itemId;
            modifier.known <- this.opIsKnown(modifier.op);
            out.append(modifier);
        }
    }
    return out;
}

// `parseAttributeOperation` (AttributeSet.cpp:30-53) exactly.
RpgcItems.operationSpellings <- function () {
    return ["add", "additive_percent", "mulAdd", "multiplicative_percent", "mulMul",
            "multiply", "override", "clamp_min", "clampMin", "min",
            "clamp_max", "clampMax", "max"];
}

RpgcItems.opIsKnown <- function (op) {
    foreach (name in this.operationSpellings()) if (name == op) return true;
    return false;
}

// The engine's silence, made visible. `EquipmentSystem.cpp:73` drops the Result
// of `AttributeSystem::addModifier`, and `parseAttributeOperation` fails on an
// unknown spelling, after which `AttributeSystem.cpp:66-69` returns an empty
// binding list. So a misspelled `op` is an equipment bonus that does not exist
// and nothing says so anywhere. The schema pins the spelling set, so this can
// only fire on a document that bypassed the gate -- it exists so that "nothing
// says so" is false at the runtime boundary.
RpgcItems.unknownModifiers <- function (set, config) {
    local out = [];
    foreach (modifier in this.modifiersOf(set, config)) {
        if (!modifier.known) out.append(modifier);
    }
    return out;
}

// `computeAttributeValue` (AttributeSet.cpp:100-142): additive and
// additive-percent first, then multiplicative, then the priority-ordered
// override / clamp chain. `multiply N` is stored by the parser as `N - 1` and
// therefore means "multiply by N"; this restates that as well.
RpgcItems.attributeValue <- function (baseValue, modifiers, attribute) {
    local additive = 0.0;
    local additivePercent = 0.0;
    local multiplicative = 1.0;
    local ordered = [];
    foreach (modifier in modifiers) {
        if (modifier.attribute != attribute) continue;
        local op = Rpgc.asString(Rpgc.get(modifier, "op", "add"));
        local value = Rpgc.asNumber(Rpgc.get(modifier, "value", 0));
        if (op == "multiply") value = value - 1.0;
        if (op == "add") additive += value;
        else if (op == "additive_percent" || op == "mulAdd") additivePercent += value;
        else if (op == "multiplicative_percent" || op == "mulMul" || op == "multiply") {
            multiplicative *= 1.0 + value;
        } else if (this.opIsKnown(op)) {
            ordered.append(modifier);
        }
        // An unknown spelling contributes nothing, for the same reason it
        // contributes nothing in the engine.
    }
    local result = (Rpgc.asNumber(baseValue) + additive) * (1.0 + additivePercent) * multiplicative;

    // `std::stable_sort` by priority over a list that is already in insertion
    // order: a stable insertion sort is the same permutation.
    for (local i = 1; i < ordered.len(); i += 1) {
        local current = ordered[i];
        local j = i - 1;
        while (j >= 0 && Rpgc.asInt(Rpgc.get(ordered[j], "priority", 0))
                > Rpgc.asInt(Rpgc.get(current, "priority", 0))) {
            ordered[j + 1] = ordered[j];
            j -= 1;
        }
        ordered[j + 1] = current;
    }
    foreach (modifier in ordered) {
        local op = Rpgc.asString(Rpgc.get(modifier, "op", "add"));
        local value = Rpgc.asNumber(Rpgc.get(modifier, "value", 0));
        local name = (op == "min" || op == "clampMin") ? "clamp_min" : op;
        name = (op == "max" || op == "clampMax") ? "clamp_max" : name;
        if (name == "override") result = value;
        else if (name == "clamp_min") result = result > value ? result : value;
        else if (name == "clamp_max") result = result < value ? result : value;
    }
    return result;
}

// ------------------------------------------------------------------- use
//
// The engine has no "an item was used" callback at all -- docs/08 §3 calls `use`
// the project's half. What the engine does have is `rpg.applyEffect`, which is
// unreachable here for the same reason `rpg` is, so the effect list is returned
// to the caller and the battle resolver (`RpgcBattle.applyEffect`) applies it.
// Consuming is a bag operation and happens here, before the caller sees the
// result.

RpgcItems.use <- function (bag, config, itemId) {
    local def = this.definitionOf(config, itemId);
    if (def == 0) {
        return Rpgc.fail([Rpgc.error("items.unknown-item",
            "no item definition for '" + itemId + "'", "$", "")]);
    }
    local use = this.useOf(def);
    if (use == 0 || Rpgc.get(use, "effects", []).len() == 0) {
        return Rpgc.fail([Rpgc.error("items.not-usable",
            "'" + itemId + "' has no use.effects, so using it would do nothing", "$",
            "docs/08 §5: only a consumable carries `use`")]);
    }
    if (this.countOf(bag, itemId) <= 0) {
        return Rpgc.fail([Rpgc.error("items.not-held",
            "the bag holds no '" + itemId + "'", "$", "")]);
    }

    local effects = [];
    foreach (value in Rpgc.get(use, "effects", [])) {
        local effectId = Rpgc.asString(value);
        if (effectId != "") effects.append(effectId);
    }
    // `consume` defaults to true when the document omits it: a consumable that
    // does not consume is indistinguishable from an infinite one.
    local consume = Rpgc.get(use, "consume", true) == true;
    local consumed = 0;
    if (consume) {
        local removed = this.remove(bag, itemId, 1);
        consumed = removed.ok ? removed.value.removed : 0;
    }

    local value = {};
    value.itemId <- itemId;
    value.displayName <- Rpgc.asString(Rpgc.get(def, "displayName", itemId));
    value.targetType <- Rpgc.asString(Rpgc.get(use, "targetType", "self"));
    value.cooldown <- Rpgc.asNumber(Rpgc.get(use, "cooldown", 0));
    value.consume <- consume;
    value.consumed <- consumed;
    value.effects <- effects;
    value.teaches <- this.teachesOf(def);
    return Rpgc.ok(value);
}

// ---------------------------------------------------------------- loot
//
// `RpgcBattle.settlement` reports loot as `{ itemId, count }` rows. A bag with no
// room is a real outcome, so what could not be placed is REPORTED rather than
// dropped: the engine's `addItem` returns a partial count and says nothing, and
// "the boss dropped it and it vanished" is exactly the class of silence this
// workflow exists to remove.

RpgcItems.applyLoot <- function (bag, config, loot) {
    local added = [];
    local lost = [];
    foreach (row in loot) {
        local itemId = Rpgc.asString(Rpgc.get(row, "itemId", ""));
        local count = Rpgc.asInt(Rpgc.get(row, "count", 0));
        if (itemId == "" || count <= 0) continue;
        local placed = this.add(bag, config, itemId, count);
        local took = placed.ok ? placed.value.added : 0;
        if (took > 0) {
            local entry = {};
            entry.itemId <- itemId;
            entry.count <- took;
            added.append(entry);
        }
        if (took < count) {
            local entry = {};
            entry.itemId <- itemId;
            entry.count <- count - took;
            entry.reason <- placed.diagnostics.len() > 0
                ? placed.diagnostics[0].code : "items.no-slot";
            lost.append(entry);
        }
    }
    local value = {};
    value.added <- added;
    value.lost <- lost;
    return Rpgc.ok(value);
}

// ------------------------------------------------------------------ save
//
// The shape `InventorySaveSession` keeps for the engine's own Bag + EquipmentSet
// pair, so a later swap to the real module reads the same document. `restore`
// refuses a malformed snapshot instead of leaving a half-applied bag behind.

RpgcItems.snapshot <- function (bag, set) {
    local out = {};
    // A SAVE marker, not a schema id: this document is never a content kind, so
    // naming a registered schema here would be a claim the gate cannot check.
    // The fields below are what `restore` reads back, and nothing else does.
    out.format <- "eve.rpgc.items.snapshot";
    out.version <- 1;
    out.id <- Rpgc.asString(Rpgc.get(bag, "id", "bag"));
    out.slotCount <- bag.slots.len();
    out.maxWeight <- Rpgc.asNumber(Rpgc.get(bag, "maxWeight", 0));
    out.maxVolume <- Rpgc.asNumber(Rpgc.get(bag, "maxVolume", 0));
    out.capacityPolicy <- Rpgc.asString(Rpgc.get(bag, "capacityPolicy", this.defaultCapacityPolicy));
    local stacks = [];
    for (local i = 0; i < bag.slots.len(); i += 1) {
        local stack = bag.slots[i];
        if (this.isEmpty(stack)) continue;
        local row = {};
        row.bagSlot <- i;
        row.itemId <- stack.itemId;
        row.quantity <- Rpgc.asInt(Rpgc.get(stack, "quantity", 0));
        stacks.append(row);
    }
    out.stacks <- stacks;
    local worn = [];
    foreach (slot in set.order) {
        local itemId = this.equipped(set, slot);
        if (itemId == "") continue;
        local row = {};
        row.slot <- slot;
        row.itemId <- itemId;
        worn.append(row);
    }
    out.equipped <- worn;
    return out;
}

RpgcItems.restore <- function (text, config) {
    local parsed = RpgcJson.parse(text);
    if (!parsed.ok) return parsed;
    local document = parsed.value;
    if (typeof document != "table") {
        return Rpgc.fail([Rpgc.error("items.snapshot-shape",
            "an item snapshot must be an object", "$", "")]);
    }
    local bag = this.newBag(Rpgc.asInt(Rpgc.get(document, "slotCount",
        this.defaultBagSlots)), Rpgc.asString(Rpgc.get(document, "id", "bag")));
    bag.maxWeight = Rpgc.asNumber(Rpgc.get(document, "maxWeight", 0));
    bag.maxVolume = Rpgc.asNumber(Rpgc.get(document, "maxVolume", 0));
    bag.capacityPolicy = Rpgc.asString(Rpgc.get(document, "capacityPolicy",
        this.defaultCapacityPolicy));

    local diagnostics = [];
    foreach (row in Rpgc.get(document, "stacks", [])) {
        local index = Rpgc.asInt(Rpgc.get(row, "bagSlot", -1));
        local itemId = Rpgc.asString(Rpgc.get(row, "itemId", ""));
        local quantity = Rpgc.asInt(Rpgc.get(row, "quantity", 0));
        if (index < 0 || index >= bag.slots.len() || quantity <= 0) {
            diagnostics.append(Rpgc.error("items.snapshot-row",
                "snapshot row is out of range: slot " + index + " x" + quantity, "$", ""));
            continue;
        }
        if (this.definitionOf(config, itemId) == 0) {
            diagnostics.append(Rpgc.error("items.snapshot-item",
                "snapshot names unknown item '" + itemId + "'", "$", ""));
            continue;
        }
        bag.slots[index].itemId = itemId;
        bag.slots[index].quantity = quantity;
    }

    local set = this.newEquipmentSet(config, Rpgc.asString(Rpgc.get(document, "id", "equip")));
    foreach (row in Rpgc.get(document, "equipped", [])) {
        local slot = Rpgc.asString(Rpgc.get(row, "slot", ""));
        local itemId = Rpgc.asString(Rpgc.get(row, "itemId", ""));
        local def = this.definitionOf(config, itemId);
        if (!(slot in set.slots) || def == 0 || this.slotOf(def) != slot) {
            diagnostics.append(Rpgc.error("items.snapshot-equip",
                "snapshot equips '" + itemId + "' in slot '" + slot + "'", "$", ""));
            continue;
        }
        local stack = this.emptyStack();
        stack.itemId = itemId;
        stack.quantity = 1;
        set.slots.rawset(slot, stack);
    }
    if (Rpgc.errorCount(diagnostics) > 0) return Rpgc.fail(diagnostics);
    local value = {};
    value.bag <- bag;
    value.equipment <- set;
    return Rpgc.ok(value);
}

// --------------------------------------------------------- battle bridge
//
// What the unit may use in a fight, in the same shape
// `RpgcBattle.commandsFor` returns skills in, so the runtime adapter can put both
// in one command list. `id` is namespaced so a skill and an item can never be
// confused for one another, and the effect list travels WITH the entry: the
// battle resolver never reads an item document.

RpgcItems.battleCommands <- function (bag, config) {
    local out = [];
    foreach (row in this.entries(bag, config)) {
        if (!row.usable) continue;
        local def = this.definitionOf(config, row.itemId);
        local use = this.useOf(def);
        local effects = [];
        foreach (value in Rpgc.get(use, "effects", [])) {
            local effectId = Rpgc.asString(value);
            if (effectId != "") effects.append(effectId);
        }
        local entry = {};
        entry.id <- "command.item:" + row.itemId;
        entry.itemId <- row.itemId;
        entry.label <- row.displayName + "×" + row.quantity;
        entry.targetType <- Rpgc.asString(Rpgc.get(use, "targetType", "self"));
        entry.effects <- effects;
        entry.ready <- true;
        entry.affordable <- true;
        entry.damaging <- false;
        out.append(entry);
    }
    return out;
}
