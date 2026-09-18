// EVEngine workflow / rpg-classic — open-world, combat, inventory,
// battle-layout and roster documents (kinds `rules`, `world`, `art`, `heart`,
// `combo`, `item`, `enemy`, `encounter`, `party`, `battle`).
//
// These are the documents docs/06-game-design.md,
// docs/09-enemies-and-encounters.md and docs/10-battle-scene.md add on top of
// the three editors. None of them is engine-native, and that is the whole
// reason they need a gate: the engine's RPG module has no grade, no
// five-element algebra, no world gate, no heart method, no combo and no
// battlefield, so a mistake in any of them is silent at runtime rather than
// rejected. The three the design names are:
//
//   * rpg.registerTraitsFromJson accepts a bad trait entry without reporting it;
//   * Trait has no "style" multiplier, so a wrong weak-style tag simply never
//     fires;
//   * EffectDefinition.duration is in SECONDS while the design speaks in TURNS,
//     so `2 turns` is `2 * rules.clock.turnSeconds` and nothing derives it.
//
// `item` is the exception in the other direction: `inventory` does carry an item
// registry, but its loader is silent in four ways and EquipmentSystem discards
// the only signal that an equip stat's `op` was rejected. See itemDiagnostics.
//
// `encounter` is the other exception, and it fails the opposite way: the
// engine's EncounterCatalogue.replaceFromJsonStrict DOES reject unknown fields
// and DOES reject a bad member -- but it is atomic, so one malformed encounter
// costs the project every other encounter too (EncounterCatalogue.cpp:63-176).
// A gate is therefore cheaper than a runtime that silently has no battles.
//
// `battle` fails a third way: nothing downstream reads it at all. The engine has
// no battlefield, formation or slot type anywhere in `src/modules/rpg` (nor
// elsewhere), so there is no loader to reject a scene and no projection to get
// wrong — a scene whose enemy bank spills into the party half, or whose slot
// sits outside its own zone, simply renders the wrong picture forever. The gate
// is therefore the ONLY thing that ever looks at this document's geometry.
//
// Everything the schema cannot express lives here. Cross-document rules that
// span several of these kinds (and the two documents owned by other modules)
// live in `extraDiagnostics`, which `RpgcValidate.validateProject` calls once
// per module after the generic reference gate has run.
//
// The condition vocabulary is NOT re-declared here: `eve.rpgc.condition` is the
// single schema both `event` and `world` reference, and `conditionDiagnostics`
// below is the single implementation both delegate to. Two copies of either is
// exactly how the two syntaxes would drift apart.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcProject } from "./rpgc_project.nut"
import { RpgcTilemap } from "./rpgc_tilemap.nut"

export class RpgcSystems {
}

RpgcSystems.version <- 1
RpgcSystems.kinds <- ["art", "battle", "combo", "encounter", "enemy", "heart", "item", "party", "rules", "world"]

// Closed sets the schema cannot express because the engine types are free
// strings. `category` is a free string in ItemDefinition and `equipSlot` is
// explicitly documented as an unresolvable suggestion, so both need a gate.
RpgcSystems.itemCategories <- ["consumable", "weapon", "armor", "accessory", "material", "quest", "manual"]
RpgcSystems.itemEquipmentCategories <- ["weapon", "armor", "accessory"]

// EncounterCatalogue rejects a composition of more than 32 members outright
// (EncounterCatalogue.cpp:88). The schema caps `members[]` at 32 ENTRIES, but
// each entry carries a `count`, so the projected member total is what must fit.
RpgcSystems.maxEncounterMembers <- 32

// The battle screen holds at most eight enemy positions in its top-left half
// and at most five party positions in its bottom-right half. These two are the
// ONLY copy of those numbers: the schema deliberately declares no `maxItems`
// for the two slot arrays, because `RpgcValidate.validateDocument` returns on a
// schema failure before the semantic gate runs, so a structural cap would make
// `systems.battle-slot-count` below unreachable -- and a gate nothing can
// trigger is a gate nothing can trust.
RpgcSystems.maxBattleEnemySlots <- 8
RpgcSystems.maxBattleAllySlots <- 5

// The screen furniture's own caps, same reasoning as the two above: they are
// design constants the gate reads, not schema `maxItems` (a schema failure
// short-circuits validateDocument and would make these checks unreachable).
RpgcSystems.maxBattleCommandButtons <- 8
RpgcSystems.maxBattlePartyBars <- 4

RpgcSystems.semanticDiagnostics <- function (document) {
    local schema = Rpgc.asString(Rpgc.get(document, "schema", ""));
    if (schema == "eve.rpgc.rules") return this.rulesDiagnostics(document);
    if (schema == "eve.rpgc.world") return this.worldDiagnostics(document);
    if (schema == "eve.rpgc.art") return this.artDiagnostics(document);
    if (schema == "eve.rpgc.heart") return this.heartDiagnostics(document);
    if (schema == "eve.rpgc.combo") return this.comboDiagnostics(document);
    if (schema == "eve.rpgc.item") return this.itemDiagnostics(document);
    if (schema == "eve.rpgc.enemy") return this.enemyDiagnostics(document);
    if (schema == "eve.rpgc.party") return this.partyDiagnostics(document);
    if (schema == "eve.rpgc.encounter") return this.encounterDiagnostics(document);
    if (schema == "eve.rpgc.battle") return this.battleDiagnostics(document);
    return [Rpgc.error("systems.unknown-schema",
        "RpgcSystems cannot validate schema '" + schema + "'", "$", "")];
}

// ------------------------------------------------------- document source
//
// Every document this module consults is read through the two accessors below,
// so there is exactly one answer to "where does a cross-document check read
// from". `documentSource` is 0 in normal operation, and then that answer is
// `RpgcProject` — the on-disk content tree.
//
// `tools/modules_check.nut` replaces it with in-memory documents, which is how
// each cross-document rule is driven with a deliberately broken document and
// observed to refuse. A gate nothing can trigger is a gate nothing can trust,
// and the alternative — writing a broken file into `content/` to watch a check
// fire — would mutate the very tree the check exists to protect.

RpgcSystems.documentSource <- 0

RpgcSystems.documentsOf <- function (kind) {
    if (typeof this.documentSource == "table" && this.documentSource.rawin(kind)) {
        return this.documentSource.rawget(kind);
    }
    return RpgcProject.loadKind(kind).value;
}

// Result-shaped, matching `RpgcProject.loadById`, so callers stay uniform.
RpgcSystems.documentOf <- function (kind, id) {
    if (typeof this.documentSource == "table" && this.documentSource.rawin(kind)) {
        foreach (candidate in this.documentSource.rawget(kind)) {
            if (Rpgc.asString(Rpgc.get(candidate, "id", "")) == id) return Rpgc.ok(candidate);
        }
        return Rpgc.fail([Rpgc.error("systems.no-such-document",
            "no " + kind + " with id '" + id + "' in the substituted source", "$", "")]);
    }
    return RpgcProject.loadById(kind, id);
}

// ----------------------------------------------------------- the rule doc
//
// `rules` is the root of the whole combat half: art/heart/combo all read its
// element table, and breakEffects is the only place the turn-to-second
// derivation is written down. Exactly one is expected, and a second one would
// silently become a second authority for the same tables.

RpgcSystems.rulesDocument <- function () {
    local documents = this.documentsOf("rules");
    if (documents.len() != 1) return 0;
    return documents[0];
}

RpgcSystems.worldDocument <- function () {
    local documents = this.documentsOf("world");
    if (documents.len() != 1) return 0;
    return documents[0];
}

RpgcSystems.elementsOf <- function (rules) {
    local out = [];
    foreach (value in Rpgc.get(rules, "elements", [])) {
        out.append(Rpgc.asString(value));
    }
    return out;
}

// id -> trait entry, so a heart can be checked without re-scanning the array.
RpgcSystems.traitTableOf <- function (rules) {
    local out = {};
    foreach (entry in Rpgc.get(rules, "traits", [])) {
        local id = Rpgc.asString(Rpgc.get(entry, "id", ""));
        if (id != "") out.rawset(id, entry);
    }
    return out;
}

// id -> [startHour, endHour].
RpgcSystems.momentTableOf <- function (world) {
    local out = {};
    local moments = Rpgc.get(world, "clock.moments", 0);
    if (typeof moments != "table") return out;
    foreach (name, band in moments) out.rawset(name, band);
    return out;
}

// The closed equipment-slot vocabulary, the same shape as `weakStyles`: a
// project-side list that lives in the singleton rule document. `equipSlot` is a
// hint the engine never resolves (inventory/ItemTypes.h:21 calls it a
// suggestion and decides wearability from EquipmentSet config instead), so this
// list is the only thing standing between a typo and an item that silently can
// never be worn.
RpgcSystems.equipmentSlotsOf <- function (rules) {
    local out = [];
    foreach (value in Rpgc.get(rules, "equipmentSlots", [])) {
        out.append(Rpgc.asString(value));
    }
    return out;
}

// ----------------------------------------------------------- shared bits

// A stable-id list must be non-empty, well-formed and duplicate-free. Used for
// elements, weakStyles, moment bands, art/trait references and combo chains.
RpgcSystems.idListDiagnostics <- function (values, pointer, label, diagnostics) {
    local seen = {};
    for (local i = 0; i < values.len(); i += 1) {
        local id = Rpgc.asString(values[i]);
        local at = pointer + "/" + i;
        if (!Rpgc.validId(id)) {
            diagnostics.append(Rpgc.error("systems.bad-id",
                label + " entry must be a stable id", at, ""));
        } else if (seen.rawin(id)) {
            diagnostics.append(Rpgc.error("systems.duplicate-id",
                label + " entry '" + id + "' is listed twice", at, ""));
        } else {
            seen.rawset(id, true);
        }
    }
    return diagnostics;
}

RpgcSystems.memberOfList <- function (list, id) {
    foreach (value in list) if (value == id) return true;
    return false;
}

// Element-wise numeric comparison for tile geometry (region / pivot /
// footprint). Used by the variant-isomorphism gate below.
RpgcSystems.sameNumbers <- function (left, right) {
    if (typeof left != "array" || typeof right != "array") return left == right;
    if (left.len() != right.len()) return false;
    for (local i = 0; i < left.len(); i += 1) {
        if (Rpgc.asNumber(left[i]) != Rpgc.asNumber(right[i])) return false;
    }
    return true;
}

// The one condition gate. `moments` is the project's moment table (or an empty
// table when no world document is available); a `moment` condition whose band
// is unknown would otherwise select no layer and no gate, silently.
RpgcSystems.conditionDiagnostics <- function (condition, at, moments, diagnostics) {
    local kind = Rpgc.asString(Rpgc.get(condition, "kind", ""));
    if (kind == "variable" || kind == "switch") {
        if (Rpgc.asString(Rpgc.get(condition, "name", "")) == "") {
            diagnostics.append(Rpgc.error("systems.condition-name",
                "condition '" + kind + "' needs a name", at + "/name", ""));
        }
    }
    if (kind == "variable") {
        if (Rpgc.asString(Rpgc.get(condition, "compare", "")) == "") {
            diagnostics.append(Rpgc.error("systems.condition-compare",
                "a variable condition needs a compare operator", at + "/compare",
                "eq/ne/lt/lte/gt/gte"));
        }
        if (!Rpgc.has(condition, "value")) {
            diagnostics.append(Rpgc.error("systems.condition-value",
                "a variable condition needs a value", at + "/value", ""));
        }
    }
    if (kind == "object_consumed") {
        foreach (field in ["mapId", "objectName"]) {
            if (Rpgc.asString(Rpgc.get(condition, field, "")) == "") {
                diagnostics.append(Rpgc.error("systems.condition-field",
                    "object_consumed needs '" + field + "'", at + "/" + field, ""));
            }
        }
    }
    if (kind == "moment") {
        local any = Rpgc.get(condition, "any", []);
        if (any.len() == 0) {
            diagnostics.append(Rpgc.error("systems.condition-moment-empty",
                "a moment condition needs a non-empty `any` list", at + "/any",
                "otherwise it can never be true"));
        }
        diagnostics = this.idListDiagnostics(any, at + "/any", "moment condition", diagnostics);
        for (local i = 0; i < any.len(); i += 1) {
            local id = Rpgc.asString(any[i]);
            if (id == "" || !Rpgc.validId(id)) continue;
            if (!moments.rawin(id)) {
                diagnostics.append(Rpgc.error("systems.condition-unknown-moment",
                    "moment condition names '" + id
                    + "', which world.clock.moments does not define",
                    at + "/any/" + i,
                    "declare the band in eve.rpgc.world.clock.moments"));
            }
        }
    }
    return diagnostics;
}

// ---------------------------------------------------------------- rules

RpgcSystems.rulesDiagnostics <- function (doc) {
    local diagnostics = [];
    local elements = this.elementsOf(doc);
    diagnostics = this.idListDiagnostics(elements, "/elements", "elements", diagnostics);
    if (elements.len() < 2) {
        diagnostics.append(Rpgc.error("systems.rules-elements",
            "the element table needs at least two entries", "/elements", ""));
        return diagnostics;
    }

    diagnostics = this.relationDiagnostics(Rpgc.get(doc, "generates", 0),
        elements, "/generates", "generates", diagnostics);
    diagnostics = this.relationDiagnostics(Rpgc.get(doc, "overcomes", 0),
        elements, "/overcomes", "overcomes", diagnostics);

    diagnostics = this.idListDiagnostics(Rpgc.get(doc, "weakStyles", []),
        "/weakStyles", "weakStyles", diagnostics);
    diagnostics = this.traitDiagnostics(doc, elements, diagnostics);
    diagnostics = this.breakDiagnostics(doc, diagnostics);
    diagnostics = this.breakEffectDiagnostics(doc, diagnostics);
    diagnostics = this.resourceDiagnostics(doc, diagnostics);
    return diagnostics;
}

// The pools a skill's `costs[]` is paid from. Like `break.max`, this is a rule
// table fact rather than a per-character one: a skill costs `stamina: 3`, and
// what a full stamina pool IS belongs with the rest of the combat constants.
// The gate exists because `SkillDefinition.costs` is a free-form attribute name
// with no registry behind it -- a cost naming an attribute nothing declares is
// a skill that is either free or unaffordable, and neither is visible anywhere.
//
// The schema deliberately does NOT carry `minimum: 1` on `max`. It did at first,
// and that made the zero case a layer-1 `validate.schema` failure: the semantic
// gate never ran, and `systems.resource-max` was a check that could not fire
// (tools/modules_check.nut's `reject.rules-resource-max` probe is what proved
// it). A gate nothing can trigger is a gate nothing can trust.
RpgcSystems.resourceDiagnostics <- function (doc, diagnostics) {
    local resources = Rpgc.get(doc, "resources", []);
    local seen = {};
    for (local i = 0; i < resources.len(); i += 1) {
        local at = "/resources/" + i;
        local attribute = Rpgc.asString(Rpgc.get(resources[i], "attribute", ""));
        if (attribute == "") {
            diagnostics.append(Rpgc.error("systems.resource-attribute",
                "a resource pool must name the attribute it fills", at + "/attribute", ""));
        } else if (seen.rawin(attribute)) {
            diagnostics.append(Rpgc.error("systems.resource-duplicate",
                "resource pool '" + attribute + "' is declared twice", at + "/attribute",
                "one pool per attribute; two maxima for one pool is two answers"));
        } else {
            seen.rawset(attribute, true);
        }
        if (Rpgc.asNumber(Rpgc.get(resources[i], "max", 0)) <= 0.0) {
            diagnostics.append(Rpgc.error("systems.resource-max",
                "resource pool '" + attribute + "' has max <= 0", at + "/max",
                "a pool nobody can pay from turns every cost into a refusal"));
        }
    }
    return diagnostics;
}

// `generates` / `overcomes` are element -> element maps that must form a single
// cycle over the whole element set. A partial map, a duplicated target or a
// two-cycle is a rule table a player can drive into a corner, and the engine
// cannot see any of it: it only ever looks up one element pair at a time.
RpgcSystems.relationDiagnostics <- function (relation, elements, pointer, label, diagnostics) {
    if (typeof relation != "table") {
        diagnostics.append(Rpgc.error("systems.relation-missing",
            "the " + label + " table is required", pointer, ""));
        return diagnostics;
    }
    foreach (element in elements) {
        if (!relation.rawin(element)) {
            diagnostics.append(Rpgc.error("systems.relation-incomplete",
                label + " does not define an entry for '" + element + "'",
                pointer, "every element needs exactly one " + label + " target"));
        }
    }
    foreach (source, target in relation) {
        if (!this.memberOfList(elements, source)) {
            diagnostics.append(Rpgc.error("systems.relation-unknown-source",
                label + " names '" + source + "', which is not in /elements",
                pointer + "/" + source, ""));
            continue;
        }
        local value = Rpgc.asString(target);
        if (!this.memberOfList(elements, value)) {
            diagnostics.append(Rpgc.error("systems.relation-unknown-target",
                label + " maps '" + source + "' to '" + value
                + "', which is not in /elements", pointer + "/" + source, ""));
        } else if (value == source) {
            diagnostics.append(Rpgc.error("systems.relation-self",
                label + " maps '" + source + "' to itself", pointer + "/" + source, ""));
        }
    }

    // Walk the chain from the first element: a correct table visits every
    // element exactly once and returns to the start.
    local start = elements[0];
    local visited = {};
    local cursor = start;
    local steps = 0;
    while (steps <= elements.len()) {
        if (visited.rawin(cursor)) break;
        visited.rawset(cursor, true);
        local target = "";
        if (relation.rawin(cursor)) target = Rpgc.asString(relation.rawget(cursor));
        if (target == "") break;
        cursor = target;
        steps += 1;
    }
    if (cursor != start || visited.len() != elements.len()) {
        diagnostics.append(Rpgc.error("systems.relation-not-a-cycle",
            label + " must form one cycle covering every element; starting at '"
            + start + "' it visits " + visited.len() + " of "
            + elements.len() + " element(s) and "
            + (cursor == start ? "returns to the start" : "stops at '" + cursor + "'"),
            pointer,
            "the design's tables are a single " + elements.len() + "-cycle"));
    }
    return diagnostics;
}

RpgcSystems.traitDiagnostics <- function (doc, elements, diagnostics) {
    local traits = Rpgc.get(doc, "traits", []);
    local seen = {};
    // Kinds that name a target; the rest (attackSpeed/attackTimes) are bare
    // numbers and a stray target on them would be ignored by the engine.
    local needsTarget = ["paramRate", "elementRate", "stateRate", "stateResist",
                         "exParam", "attackElement", "attackState"];
    local elementKinds = ["elementRate", "attackElement"];
    for (local i = 0; i < traits.len(); i += 1) {
        local entry = traits[i];
        local at = "/traits/" + i;
        local id = Rpgc.asString(Rpgc.get(entry, "id", ""));
        if (!Rpgc.validId(id)) {
            diagnostics.append(Rpgc.error("systems.trait-id",
                "trait id must be a stable id", at + "/id", ""));
        } else if (seen.rawin(id)) {
            diagnostics.append(Rpgc.error("systems.trait-duplicate",
                "trait '" + id + "' is declared twice", at + "/id",
                "registerTraitsFromJson lets the last one win silently"));
        } else {
            seen.rawset(id, true);
        }

        local kind = Rpgc.asString(Rpgc.get(entry, "kind", ""));
        local target = Rpgc.asString(Rpgc.get(entry, "target", ""));
        if (this.memberOfList(needsTarget, kind) && target == "") {
            diagnostics.append(Rpgc.error("systems.trait-target",
                "trait '" + id + "' of kind '" + kind + "' needs a target",
                at + "/target", ""));
        }
        if (this.memberOfList(elementKinds, kind) && target != "" &&
            !this.memberOfList(elements, target)) {
            diagnostics.append(Rpgc.error("systems.trait-element",
                "trait '" + id + "' targets element '" + target
                + "', which is not in /elements", at + "/target", ""));
        }
    }
    return diagnostics;
}

RpgcSystems.breakDiagnostics <- function (doc, diagnostics) {
    local block = Rpgc.get(doc, "break", 0);
    if (typeof block != "table") {
        diagnostics.append(Rpgc.error("systems.break-missing",
            "a break block is required", "/break", ""));
        return diagnostics;
    }
    local max = Rpgc.asInt(Rpgc.get(block, "max", 0));
    foreach (field in ["onOvercome", "onWeakElement", "onWeakStyle", "regenPerRound"]) {
        if (!Rpgc.has(block, field)) continue;
        local value = Rpgc.asInt(Rpgc.get(block, field, 0));
        if (value > max) {
            diagnostics.append(Rpgc.error("systems.break-exceeds-max",
                "break." + field + " (" + value + ") exceeds break.max (" + max + ")",
                "/break/" + field, "a single hit could drop the gauge below zero"));
        }
    }
    return diagnostics;
}

// The turn-to-second derivation the design calls out (06-game-design.md §3.4):
// EffectDefinition.duration is in seconds and StatusSystem::update(dt) counts it
// down, while the rules speak in turns. Writing "2 turns" as duration = 2 is a
// silent two-second stun that looks like a working rule, so the gate derives it
// and refuses any effect whose duration does not match.
RpgcSystems.breakEffectDiagnostics <- function (doc, diagnostics) {
    local entries = Rpgc.get(doc, "breakEffects", []);
    local turnSeconds = Rpgc.asNumber(Rpgc.get(doc, "clock.turnSeconds", 0));
    local seen = {};
    for (local i = 0; i < entries.len(); i += 1) {
        local entry = entries[i];
        local at = "/breakEffects/" + i;
        local id = Rpgc.asString(Rpgc.get(entry, "effect", ""));
        if (id == "") continue;
        if (seen.rawin(id)) {
            diagnostics.append(Rpgc.error("systems.break-effect-duplicate",
                "breakEffects lists effect '" + id + "' twice", at + "/effect", ""));
        }
        seen.rawset(id, true);

        local turns = Rpgc.asInt(Rpgc.get(entry, "turns", 1));
        local expected = turns * turnSeconds;
        local effect = this.documentOf("effect", id);
        if (!effect.ok) continue;  // the reference gate owns the dangling case
        local policy = Rpgc.asString(Rpgc.get(effect.value, "durationPolicy", "instant"));
        local duration = Rpgc.asNumber(Rpgc.get(effect.value, "duration", 0));
        if (policy != "duration") {
            diagnostics.append(Rpgc.error("systems.break-effect-policy",
                "breakEffects names effect '" + id + "' but its durationPolicy is '"
                + policy + "'", at + "/effect",
                "a break status must have durationPolicy \"duration\""));
            continue;
        }
        if (Rpgc.asNumber(duration) != Rpgc.asNumber(expected)) {
            diagnostics.append(Rpgc.error("systems.break-effect-duration",
                "effect '" + id + "' must last " + turns + " turn(s) = "
                + expected + "s (clock.turnSeconds=" + turnSeconds
                + ") but its duration is " + duration + "s",
                at + "/effect",
                "duration is seconds, not turns; derive it from clock.turnSeconds"));
        }
    }
    return diagnostics;
}

// ---------------------------------------------------------------- world

RpgcSystems.worldDiagnostics <- function (doc) {
    local diagnostics = [];
    local moments = Rpgc.get(doc, "clock.moments", 0);
    if (typeof moments != "table" || moments.len() == 0) {
        diagnostics.append(Rpgc.error("systems.moments-empty",
            "clock.moments must declare at least one band", "/clock/moments", ""));
    } else {
        foreach (name, band in moments) {
            local at = "/clock/moments/" + name;
            if (!Rpgc.validId(name)) {
                diagnostics.append(Rpgc.error("systems.moment-id",
                    "moment id must be a stable id", at, ""));
            }
            if (typeof band != "array" || band.len() != 2) {
                diagnostics.append(Rpgc.error("systems.moment-band",
                    "moment '" + name + "' must be a [startHour, endHour] pair",
                    at, "24-hour clock, e.g. [19, 5] for night"));
                continue;
            }
            local start = Rpgc.asInt(band[0]);
            local end = Rpgc.asInt(band[1]);
            for (local k = 0; k < 2; k += 1) {
                local hour = Rpgc.asInt(band[k]);
                if (hour < 0 || hour > 24) {
                    diagnostics.append(Rpgc.error("systems.moment-hour",
                        "moment '" + name + "' hour " + hour + " is outside 0..24",
                        at + "/" + k, ""));
                }
            }
            if (start == end) {
                diagnostics.append(Rpgc.error("systems.moment-empty-band",
                    "moment '" + name + "' starts and ends at the same hour",
                    at, "the band would never be active"));
            }
        }
    }

    // `gates[].open` is validated by the schema; the per-kind rules are the
    // shared condition gate, which needs the moment table this document owns.
    local known = this.momentTableOf(doc);
    local gates = Rpgc.get(doc, "gates", []);
    local seenPortals = {};
    for (local i = 0; i < gates.len(); i += 1) {
        local gate = gates[i];
        local at = "/gates/" + i;
        local portal = Rpgc.asString(Rpgc.get(gate, "portal", ""));
        if (portal == "") continue;
        local slash = portal.find("/");
        if (slash == null || slash <= 0 || slash >= portal.len() - 1) {
            diagnostics.append(Rpgc.error("systems.gate-portal",
                "gate portal must be written \"<mapId>/<objectName>\", got '"
                + portal + "'", at + "/portal", ""));
        } else {
            local mapId = portal.slice(0, slash);
            local objectName = portal.slice(slash + 1, portal.len());
            if (!Rpgc.validId(mapId) || !Rpgc.validId(objectName)) {
                diagnostics.append(Rpgc.error("systems.gate-portal",
                    "gate portal '" + portal + "' must be two stable ids",
                    at + "/portal", ""));
            }
        }
        if (seenPortals.rawin(portal)) {
            diagnostics.append(Rpgc.error("systems.gate-duplicate",
                "portal '" + portal + "' has two gates", at + "/portal",
                "one portal, one condition"));
        }
        seenPortals.rawset(portal, true);

        local open = Rpgc.get(gate, "open", 0);
        if (typeof open == "table") {
            diagnostics = this.conditionDiagnostics(open, at + "/open", known, diagnostics);
        } else {
            diagnostics.append(Rpgc.error("systems.gate-condition",
                "gate '" + portal + "' needs an `open` condition", at + "/open", ""));
        }
    }

    diagnostics = this.styleVariantDiagnostics(doc, known, diagnostics);
    return diagnostics;
}

RpgcSystems.styleVariantDiagnostics <- function (doc, moments, diagnostics) {
    local variants = Rpgc.get(doc, "styleVariants", []);
    local seen = {};
    for (local i = 0; i < variants.len(); i += 1) {
        local variant = variants[i];
        local at = "/styleVariants/" + i;
        local id = Rpgc.asString(Rpgc.get(variant, "id", ""));
        if (!Rpgc.validId(id)) {
            diagnostics.append(Rpgc.error("systems.variant-id",
                "style variant id must be a stable id", at + "/id", ""));
        } else if (seen.rawin(id)) {
            diagnostics.append(Rpgc.error("systems.variant-duplicate",
                "style variant '" + id + "' is declared twice", at + "/id", ""));
        } else {
            seen.rawset(id, true);
        }

        local bands = Rpgc.get(variant, "moments", []);
        diagnostics = this.idListDiagnostics(bands, at + "/moments", "variant moments", diagnostics);
        for (local k = 0; k < bands.len(); k += 1) {
            local band = Rpgc.asString(bands[k]);
            if (band != "" && Rpgc.validId(band) && !moments.rawin(band)) {
                diagnostics.append(Rpgc.error("systems.variant-unknown-moment",
                    "style variant '" + id + "' names moment '" + band
                    + "', which clock.moments does not define", at + "/moments/" + k, ""));
            }
        }

        local mode = Rpgc.asString(Rpgc.get(variant, "mode", ""));
        if (mode == "tint") {
            local tint = Rpgc.get(variant, "tint", 0);
            if (typeof tint != "array" || tint.len() != 4) {
                diagnostics.append(Rpgc.error("systems.variant-tint",
                    "a tint variant needs four components", at + "/tint",
                    "TileLayer::setTint(r, g, b, a)"));
            } else {
                for (local k = 0; k < 4; k += 1) {
                    local component = Rpgc.asNumber(tint[k]);
                    if (component < 0.0 || component > 1.0) {
                        diagnostics.append(Rpgc.error("systems.variant-tint-range",
                            "tint component " + k + " is " + component
                            + ", outside 0..1", at + "/tint/" + k, ""));
                    }
                }
            }
            if (Rpgc.has(variant, "tileset") || Rpgc.has(variant, "baseTileset")) {
                diagnostics.append(Rpgc.error("systems.variant-mixed",
                    "a tint variant must not also name an atlas", at,
                    "the design keeps setTint and setTileset mutually exclusive"));
            }
        } else if (mode == "atlas") {
            if (Rpgc.asString(Rpgc.get(variant, "tileset", "")) == "" ||
                Rpgc.asString(Rpgc.get(variant, "baseTileset", "")) == "") {
                diagnostics.append(Rpgc.error("systems.variant-atlas",
                    "an atlas variant needs both `tileset` and `baseTileset`", at,
                    "the base is what the isomorphism gate compares against"));
            }
            if (Rpgc.has(variant, "tint")) {
                diagnostics.append(Rpgc.error("systems.variant-mixed",
                    "an atlas variant must not also declare a tint", at, ""));
            }
        }
    }
    return diagnostics;
}

// ---------------------------------------------------------------- art

RpgcSystems.artDiagnostics <- function (doc) {
    local diagnostics = [];
    local maxGrade = Rpgc.asInt(Rpgc.get(doc, "maxGrade", 0));
    local grades = Rpgc.get(doc, "grades", []);
    local seen = {};
    local lastGrade = 0;
    for (local i = 0; i < grades.len(); i += 1) {
        local row = grades[i];
        local at = "/grades/" + i;
        local grade = Rpgc.asInt(Rpgc.get(row, "grade", 0));
        if (grade < 1) {
            diagnostics.append(Rpgc.error("systems.art-grade",
                "grade must be >= 1", at + "/grade", ""));
        } else if (seen.rawin(grade)) {
            diagnostics.append(Rpgc.error("systems.art-duplicate-grade",
                "grade " + grade + " is declared twice", at + "/grade", ""));
        } else if (grade <= lastGrade) {
            diagnostics.append(Rpgc.error("systems.art-unsorted-grades",
                "grade rows must be ordered ascending", at + "/grade", ""));
        } else {
            lastGrade = grade;
        }
        seen.rawset(grade, true);

        if (grade > maxGrade) {
            diagnostics.append(Rpgc.error("systems.art-grade-over-max",
                "grade " + grade + " exceeds maxGrade " + maxGrade, at + "/grade",
                "maxGrade is the art's own ceiling"));
        }

        local requirement = Rpgc.get(row, "requirement", 0);
        if (typeof requirement == "table") {
            if (Rpgc.asString(Rpgc.get(requirement, "kind", "")) == "") {
                diagnostics.append(Rpgc.error("systems.art-requirement",
                    "a requirement needs a kind", at + "/requirement/kind", ""));
            }
            if (Rpgc.asNumber(Rpgc.get(requirement, "value", 0)) < 0) {
                diagnostics.append(Rpgc.error("systems.art-requirement-value",
                    "a requirement value must not be negative",
                    at + "/requirement/value", ""));
            }
        }

        // `skills` / `ultimates` / `traits` are cumulative from this grade up
        // (06-game-design.md §2.3), so a duplicate across grades is legal but a
        // duplicate inside one row is not.
        diagnostics = this.idListDiagnostics(Rpgc.get(row, "skills", []),
            at + "/skills", "grade skills", diagnostics);
        diagnostics = this.idListDiagnostics(Rpgc.get(row, "ultimates", []),
            at + "/ultimates", "grade ultimates", diagnostics);
        diagnostics = this.idListDiagnostics(Rpgc.get(row, "traits", []),
            at + "/traits", "grade traits", diagnostics);

        local modifiers = Rpgc.get(row, "modifiers", []);
        for (local k = 0; k < modifiers.len(); k += 1) {
            local modifier = modifiers[k];
            local mat = at + "/modifiers/" + k;
            if (Rpgc.asString(Rpgc.get(modifier, "attribute", "")) == "") {
                diagnostics.append(Rpgc.error("systems.art-modifier",
                    "a grade modifier needs an attribute", mat + "/attribute", ""));
            }
        }
    }
    if (grades.len() == 0) {
        diagnostics.append(Rpgc.error("systems.art-no-grades",
            "an art must declare at least one grade", "/grades", ""));
    }
    return diagnostics;
}

// ---------------------------------------------------------------- heart

RpgcSystems.heartDiagnostics <- function (doc) {
    local diagnostics = [];
    local grants = Rpgc.get(doc, "grants", 0);
    if (typeof grants != "table") {
        diagnostics.append(Rpgc.error("systems.heart-no-grants",
            "a heart method must declare what it grants", "/grants", ""));
        return diagnostics;
    }

    // `elementOverride` REPLACES the move's element while an `attackElement`
    // trait APPENDS one (06-game-design.md §4.3). Declaring both means the
    // runtime has to pick, so the document must pick.
    local override = Rpgc.asString(Rpgc.get(grants, "elementOverride", ""));
    local declared = Rpgc.get(grants, "traits", []);
    if (override != "" && declared.len() > 0) {
        local rules = this.rulesDocument();
        if (typeof rules == "table") {
            local registry = this.traitTableOf(rules);
            foreach (id in declared) {
                local traitId = Rpgc.asString(id);
                if (!registry.rawin(traitId)) continue;
                if (Rpgc.asString(Rpgc.get(registry.rawget(traitId), "kind", "")) == "attackElement") {
                    diagnostics.append(Rpgc.error("systems.heart-element-conflict",
                        "elementOverride and the attackElement trait '" + traitId
                        + "' are both declared", "/grants/elementOverride",
                        "override replaces the element, attackElement appends one"));
                }
            }
        }
    }

    local costScale = Rpgc.get(grants, "costScale", 0);
    if (typeof costScale == "table") {
        if (Rpgc.asString(Rpgc.get(costScale, "attribute", "")) == "") {
            diagnostics.append(Rpgc.error("systems.heart-cost-attribute",
                "costScale needs an attribute", "/grants/costScale/attribute", ""));
        }
    }

    local onHit = Rpgc.get(grants, "onHit", []);
    for (local i = 0; i < onHit.len(); i += 1) {
        if (Rpgc.asString(Rpgc.get(onHit[i], "effectId", "")) == "") {
            diagnostics.append(Rpgc.error("systems.heart-onhit",
                "an onHit entry needs an effectId", "/grants/onHit/" + i + "/effectId", ""));
        }
    }

    local requires = Rpgc.get(doc, "requires", 0);
    if (typeof requires == "table") {
        local artId = Rpgc.asString(Rpgc.get(requires, "artId", ""));
        if (artId == "") {
            diagnostics.append(Rpgc.error("systems.heart-requires",
                "requires needs an artId", "/requires/artId", ""));
        } else {
            local art = this.documentOf("art", artId);
            if (art.ok) {
                local minGrade = Rpgc.asInt(Rpgc.get(requires, "minGrade", 1));
                local maxGrade = Rpgc.asInt(Rpgc.get(art.value, "maxGrade", 0));
                if (minGrade > maxGrade) {
                    diagnostics.append(Rpgc.error("systems.heart-min-grade",
                        "requires.minGrade " + minGrade + " exceeds " + artId
                        + ".maxGrade " + maxGrade, "/requires/minGrade",
                        "the heart could never become equippable"));
                }
            }
        }
    }
    return diagnostics;
}

// ---------------------------------------------------------------- combo

RpgcSystems.comboDiagnostics <- function (doc) {
    local diagnostics = [];
    local members = Rpgc.get(doc, "members", 0);
    local stages = Rpgc.get(doc, "stages", []);
    if (typeof members == "table") {
        local low = Rpgc.asInt(Rpgc.get(members, "min", 0));
        local high = Rpgc.asInt(Rpgc.get(members, "max", 0));
        if (low > high) {
            diagnostics.append(Rpgc.error("systems.combo-members",
                "members.min " + low + " exceeds members.max " + high,
                "/members/min", ""));
        }
        if (stages.len() < low || stages.len() > high) {
            diagnostics.append(Rpgc.error("systems.combo-stage-count",
                "stages has " + stages.len() + " entries but members declares "
                + low + ".." + high, "/stages",
                "one stage per participating member"));
        }
    } else {
        diagnostics.append(Rpgc.error("systems.combo-members-missing",
            "a combo must declare its member range", "/members", ""));
    }

    local actors = {};
    for (local i = 0; i < stages.len(); i += 1) {
        local actor = Rpgc.asInt(Rpgc.get(stages[i], "actor", -1));
        if (actor < 0) continue;
        if (actors.rawin(actor)) {
            diagnostics.append(Rpgc.error("systems.combo-duplicate-actor",
                "actor slot " + actor + " appears in two stages", "/stages/" + i + "/actor",
                "the design's combos are one action per member"));
        }
        actors.rawset(actor, true);
    }

    local condition = Rpgc.get(doc, "condition", 0);
    if (typeof condition == "table") {
        local elements = Rpgc.get(condition, "elements", 0);
        if (typeof elements == "table") {
            local chain = Rpgc.get(elements, "chain", []);
            diagnostics = this.idListDiagnostics(chain, "/condition/elements/chain",
                "combo chain", diagnostics);
        }
    }
    return diagnostics;
}

// ---------------------------------------------------------------- item

// Every rule below answers a silence in `inventory::ItemRegistry::loadFromJson`
// (src/modules/inventory/Item.cpp:45-80) or in `EquipmentSystem`:
//
//   * an unknown key is dropped without a word (parseItemObject reads nine);
//   * `table()[id] = copy` overwrites a duplicate definition, last one wins;
//   * `maxStack <= 0` is coerced to 1 (Item.cpp:48) — the *schema* owns this
//     one with `minimum: 1`, so there is no duplicate check here;
//   * an empty `displayName` becomes the id (Item.cpp:49) — also the schema's,
//     which requires the field;
//   * `equipSlot` is carried and never resolved (ItemTypes.h:21);
//   * an unknown `op` makes `AttributeSystem::addModifier` return early with an
//     empty string (AttributeSystem.cpp:66-69) and `syncEquipModifiers`
//     discards that return (EquipmentSystem.cpp:73), so a misspelled operation
//     is an equip bonus that silently does not exist. The schema closes the
//     spelling set; the gates below close the category/slot coupling.
//
// The categories below are the workflow's own closure of a free-string engine
// field, exactly like `weakStyles` is for style tags.
RpgcSystems.itemDiagnostics <- function (doc) {
    local diagnostics = [];
    local category = Rpgc.asString(Rpgc.get(doc, "category", ""));
    local equipSlot = Rpgc.asString(Rpgc.get(doc, "equipSlot", ""));
    local isEquipment = this.memberOfList(this.itemEquipmentCategories, category);

    local maxStack = Rpgc.asInt(Rpgc.get(doc, "maxStack", 1));

    // The engine never resolves equipSlot, so the category is the only thing
    // that can say whether one is meaningful.
    if (isEquipment && equipSlot == "") {
        diagnostics.append(Rpgc.error("systems.item-slot-missing",
            "category '" + category + "' needs an equipSlot", "/equipSlot",
            "equipment without a slot can never be worn"));
    }
    if (!isEquipment && equipSlot != "") {
        diagnostics.append(Rpgc.error("systems.item-slot-unexpected",
            "category '" + category + "' must not declare an equipSlot", "/equipSlot",
            "the engine would carry it and nothing would ever read it"));
    }

    // Equipping "one of five" has no defined meaning: EquipmentSet carries a
    // single stack per slot.
    if (isEquipment && maxStack > 1) {
        diagnostics.append(Rpgc.error("systems.item-equipment-stacks",
            "equipment must not stack, but maxStack is " + maxStack, "/maxStack",
            "equipping from a stack is undefined; EquipmentSet holds one stack per slot"));
    }

    local stats = Rpgc.get(doc, "equipStats", []);
    if (stats.len() > 0 && !isEquipment) {
        diagnostics.append(Rpgc.error("systems.item-stats-not-equipment",
            "category '" + category + "' must not declare equipStats", "/equipStats",
            "registerItemStatsFromJson would register them and nothing would apply them"));
    }
    for (local i = 0; i < stats.len(); i += 1) {
        if (Rpgc.asString(Rpgc.get(stats[i], "attribute", "")) == "") {
            diagnostics.append(Rpgc.error("systems.item-stat-attribute",
                "an equip stat needs an attribute", "/equipStats/" + i + "/attribute", ""));
        }
    }

    local use = Rpgc.get(doc, "use", 0);
    if (category == "consumable" && typeof use != "table") {
        diagnostics.append(Rpgc.error("systems.item-use-missing",
            "a consumable must declare what using it does", "/use",
            "no engine field carries this; the adapter reads it"));
    }
    if (category != "consumable" && typeof use == "table") {
        diagnostics.append(Rpgc.error("systems.item-use-unexpected",
            "category '" + category + "' must not declare `use`", "/use",
            "a second way to apply an effect is how the two drift apart"));
    }
    if (typeof use == "table") {
        local effects = Rpgc.get(use, "effects", []);
        if (effects.len() == 0) {
            diagnostics.append(Rpgc.error("systems.item-use-effects",
                "a usable item must grant at least one effect", "/use/effects",
                "a consumable that does nothing is almost always a wrong category"));
        }
        diagnostics = this.idListDiagnostics(effects, "/use/effects", "use effects", diagnostics);
    }

    local teaches = Rpgc.get(doc, "teaches", 0);
    if (category == "manual" && typeof teaches != "table") {
        diagnostics.append(Rpgc.error("systems.item-teaches-missing",
            "a manual must declare what it teaches", "/teaches",
            "a manual with no target is just a book-shaped material"));
    }
    if (category != "manual" && typeof teaches == "table") {
        diagnostics.append(Rpgc.error("systems.item-teaches-unexpected",
            "category '" + category + "' must not declare `teaches`", "/teaches", ""));
    }
    if (typeof teaches == "table") {
        local artId = Rpgc.asString(Rpgc.get(teaches, "art", ""));
        local skillId = Rpgc.asString(Rpgc.get(teaches, "skill", ""));
        if (artId == "" && skillId == "") {
            diagnostics.append(Rpgc.error("systems.item-teaches-empty",
                "teaches must name an art or a skill", "/teaches", ""));
        }
    }
    return diagnostics;
}

// --------------------------------------------------------------- enemy
//
// An enemy archetype is the only document that carries a creature's combat
// numbers. The engine's half of it is not a document at all: EncounterCatalogue
// inlines `id/displayName/skillId/attack/defense/maxHp/speed` into each member
// of a published encounter, so an enemy is really "the member definition, named
// once, plus the project-side presentation and drop table". `tools/build_encounters.py`
// is what performs that join; this gate is what keeps the join total.
RpgcSystems.enemyDiagnostics <- function (doc) {
    local diagnostics = [];
    local id = Rpgc.asString(Rpgc.get(doc, "id", ""));
    local where = "enemy/" + id;

    if (!Rpgc.validId(id)) {
        diagnostics.append(Rpgc.error("systems.enemy-id",
            "enemy id must be a stable id", "/id", ""));
    }

    // EncounterCatalogue rejects an empty displayName and a >512-byte one
    // (EncounterCatalogue.cpp:84-86) -- but only when the encounter array is
    // published, at which point the failure takes every encounter with it. The
    // same rule is applied here so the cost is one document, not the catalogue.
    local displayName = Rpgc.asString(Rpgc.get(doc, "displayName", ""));
    if (displayName == "") {
        diagnostics.append(Rpgc.error("systems.enemy-display-name",
            where + " needs a non-empty displayName", "/displayName",
            "the engine rejects the whole encounter array over one empty member name"));
    } else if (displayName.len() > 512) {
        diagnostics.append(Rpgc.error("systems.enemy-display-name-length",
            "displayName is " + displayName.len() + " bytes; the engine caps it at 512",
            "/displayName", ""));
    }

    // The engine demands maxHp STRICTLY greater than zero (strictMinimum=true,
    // EncounterCatalogue.cpp:148); zero is legal for the other three. Eve Schema
    // v1 has no exclusiveMinimum, so the strict half can only be enforced here.
    local combat = Rpgc.get(doc, "combat", 0);
    if (typeof combat == "table") {
        if (Rpgc.asNumber(Rpgc.get(combat, "maxHp", 0)) <= 0.0) {
            diagnostics.append(Rpgc.error("systems.enemy-max-hp",
                where + " has maxHp <= 0, which the engine rejects", "/combat/maxHp",
                "maxHp must be strictly positive"));
        }
    }

    local skillId = Rpgc.asString(Rpgc.get(doc, "skillId", ""));
    if (!Rpgc.validId(skillId)) {
        diagnostics.append(Rpgc.error("systems.enemy-skill-id",
            where + " needs a stable skillId", "/skillId",
            "the engine rejects an empty member skillId"));
    }

    // `skills` is the project-side rotation; `skillId` is the single move the
    // engine records on the member. A rotation that does not contain it means
    // the first move the player meets is not the one the document advertises.
    local skills = Rpgc.get(doc, "skills", []);
    diagnostics = this.idListDiagnostics(skills, "/skills", "skills", diagnostics);
    if (skills.len() > 0 && skillId != "" && !this.memberOfList(skills, skillId)) {
        diagnostics.append(Rpgc.error("systems.enemy-skill-rotation",
            where + " declares skillId '" + skillId + "' but skills[] does not list it",
            "/skillId",
            "the engine only ever sees skillId, so the rotation must contain it"));
    }

    diagnostics = this.idListDiagnostics(Rpgc.get(doc, "weakElements", []),
        "/weakElements", "weakElements", diagnostics);
    diagnostics = this.idListDiagnostics(Rpgc.get(doc, "weakStyles", []),
        "/weakStyles", "weakStyles", diagnostics);
    diagnostics = this.idListDiagnostics(Rpgc.get(doc, "habitat", []),
        "/habitat", "habitat", diagnostics);

    local sprite = Rpgc.get(doc, "sprite", 0);
    if (typeof sprite == "table") {
        if (!Rpgc.validId(Rpgc.asString(Rpgc.get(sprite, "anim", "")))) {
            diagnostics.append(Rpgc.error("systems.enemy-sprite-anim",
                where + " sprite must name an animation set", "/sprite/anim", ""));
        }
        if (!Rpgc.validId(Rpgc.asString(Rpgc.get(sprite, "clip", "")))) {
            diagnostics.append(Rpgc.error("systems.enemy-sprite-clip",
                where + " sprite must name a clip", "/sprite/clip", ""));
        }
    }

    // `ai.opener` names one of the moves in `skills`, so it is resolved against
    // that list rather than left as a free string nothing reads.
    local ai = Rpgc.get(doc, "ai", 0);
    if (typeof ai == "table") {
        local opener = Rpgc.asString(Rpgc.get(ai, "opener", ""));
        if (opener != "" && !this.memberOfList(skills, opener)) {
            diagnostics.append(Rpgc.error("systems.enemy-opener-unknown",
                where + " opens with '" + opener + "', which skills[] does not list",
                "/ai/opener", "the rotation is the only list of moves this enemy has"));
        }
    }

    local drops = Rpgc.get(doc, "drops", []);
    local seenDrops = {};
    for (local i = 0; i < drops.len(); i += 1) {
        local at = "/drops/" + i;
        local itemId = Rpgc.asString(Rpgc.get(drops[i], "itemId", ""));
        if (!Rpgc.validId(itemId)) {
            diagnostics.append(Rpgc.error("systems.enemy-drop-id",
                where + " drop must name an item", at + "/itemId", ""));
        } else if (seenDrops.rawin(itemId)) {
            diagnostics.append(Rpgc.error("systems.enemy-drop-duplicate",
                where + " lists drop '" + itemId + "' twice", at + "/itemId",
                "merge the ranges, or one roll silently shadows the other"));
        } else {
            seenDrops.rawset(itemId, true);
        }
        local low = Rpgc.asInt(Rpgc.get(drops[i], "min", 1));
        local high = Rpgc.asInt(Rpgc.get(drops[i], "max", 1));
        if (high < low) {
            diagnostics.append(Rpgc.error("systems.enemy-drop-range",
                where + " drop '" + itemId + "' has max < min", at, ""));
        }
    }
    return diagnostics;
}

// --------------------------------------------------------------- party
//
// The player side of `enemy`, and the second kind in this module whose
// numbers exist nowhere else: the engine has no party CONTENT type at all.
// `Party` (src/modules/rpg/Party.h) is a runtime container of actors that were
// already registered one by one -- it has no loader, no schema and no
// `replacePartyFromJson`, so a roster whose member has no element, no skills or
// a breakMax above the rule table is accepted by everything and read by nobody.
// This gate and `partyCrossDiagnostics` are the only readers.
//
// One asymmetry with `enemyDiagnostics` is deliberate: there is no
// `displayName > 512` check, because that cap belongs to
// EncounterCatalogue's member parser, and a party member never goes through it.
RpgcSystems.partyDiagnostics <- function (doc) {
    local diagnostics = [];
    local id = Rpgc.asString(Rpgc.get(doc, "id", ""));
    local where = "party/" + id;

    if (!Rpgc.validId(id)) {
        diagnostics.append(Rpgc.error("systems.party-id",
            "party id must be a stable id", "/id", ""));
    }

    local members = Rpgc.get(doc, "members", []);
    if (members.len() == 0) {
        diagnostics.append(Rpgc.error("systems.party-empty",
            where + " has no members, so it can never field a party", "/members",
            "a roster with nobody in it is a fight the player cannot start"));
    }

    // The opening bag. `count` is already bounded at 1 by the schema
    // (`minimum: 1`), so repeating that here would be a check that can never
    // fire -- the same reason `systems.item` leaves `maxStack` to the schema.
    // What the schema CANNOT see is the id shape and a duplicate, because both
    // are facts about the whole array.
    local starting = Rpgc.get(doc, "startingItems", []);
    local seenStarting = {};
    for (local i = 0; i < starting.len(); i += 1) {
        local at = "/startingItems/" + i;
        local itemId = Rpgc.asString(Rpgc.get(starting[i], "itemId", ""));
        if (!Rpgc.validId(itemId)) {
            diagnostics.append(Rpgc.error("systems.party-starting-item-id",
                where + " startingItems[" + i + "] must name an item", at + "/itemId", ""));
        } else if (seenStarting.rawin(itemId)) {
            // `RpgcItems.add` would happily place both rows, so the bag would
            // hold the sum while the document reads like two separate grants.
            // Two rows for one item is two answers to "how many do we start
            // with", which is the shape this workflow removes everywhere else.
            diagnostics.append(Rpgc.error("systems.party-starting-item-duplicate",
                where + " lists starting item '" + itemId + "' twice", at + "/itemId",
                "one row per item; sum the count into it"));
        } else {
            seenStarting.rawset(itemId, true);
        }
    }

    local seenMembers = {};
    for (local i = 0; i < members.len(); i += 1) {
        local at = "/members/" + i;
        local member = members[i];
        local memberId = Rpgc.asString(Rpgc.get(member, "id", ""));
        if (!Rpgc.validId(memberId)) {
            diagnostics.append(Rpgc.error("systems.party-member-id",
                where + " member #" + i + " needs a stable id", at + "/id", ""));
        } else if (seenMembers.rawin(memberId)) {
            // The runtime keys its combatants by member id, so two members with
            // one id are one combatant that heals itself every round.
            diagnostics.append(Rpgc.error("systems.party-member-duplicate",
                where + " lists member id '" + memberId + "' twice", at + "/id",
                "member ids are the runtime's identity; they must be unique"));
        } else {
            seenMembers.rawset(memberId, true);
        }

        local displayName = Rpgc.asString(Rpgc.get(member, "displayName", ""));
        if (displayName == "") {
            diagnostics.append(Rpgc.error("systems.party-member-name",
                where + " member '" + memberId + "' needs a non-empty displayName",
                at + "/displayName",
                "the battle HUD prints this and nothing else"));
        }

        local combat = Rpgc.get(member, "combat", 0);
        if (typeof combat == "table") {
            // Same strict lower bound the engine applies to an encounter member
            // (EncounterCatalogue.cpp:148), applied here for the same reason: a
            // zero-HP combatant is dead before the first turn.
            if (Rpgc.asNumber(Rpgc.get(combat, "maxHp", 0)) <= 0.0) {
                diagnostics.append(Rpgc.error("systems.party-member-max-hp",
                    where + " member '" + memberId + "' has maxHp <= 0", at + "/combat/maxHp",
                    "maxHp must be strictly positive"));
            }
        }

        // `art` and `grade` are one statement about one thing -- which moves this
        // member has -- so neither half is legal alone. `art` without `grade`
        // would silently mean "grade 1"; `grade` without `art` means nothing at
        // all, and both would be read as a member with no martial art.
        local artId = Rpgc.asString(Rpgc.get(member, "art", ""));
        local hasGrade = Rpgc.has(member, "grade");
        if (artId != "" && !hasGrade) {
            diagnostics.append(Rpgc.error("systems.party-member-grade-missing",
                where + " member '" + memberId + "' names art '" + artId
                + "' but no grade", at + "/art",
                "add the grade the member currently holds, or drop the art"));
        } else if (artId == "" && hasGrade) {
            diagnostics.append(Rpgc.error("systems.party-member-art-missing",
                where + " member '" + memberId + "' declares a grade but no art",
                at + "/grade",
                "a grade only means something relative to one martial art"));
        }
        if (artId != "" && !Rpgc.validId(artId)) {
            diagnostics.append(Rpgc.error("systems.party-member-art-id",
                where + " member '" + memberId + "' has an invalid art id", at + "/art", ""));
        }

        diagnostics = this.idListDiagnostics(Rpgc.get(member, "skills", []),
            at + "/skills", "skills", diagnostics);

        local sprite = Rpgc.get(member, "sprite", 0);
        if (typeof sprite == "table") {
            if (!Rpgc.validId(Rpgc.asString(Rpgc.get(sprite, "anim", "")))) {
                diagnostics.append(Rpgc.error("systems.party-member-sprite-anim",
                    where + " member '" + memberId + "' sprite must name an animation set",
                    at + "/sprite/anim", ""));
            }
            if (!Rpgc.validId(Rpgc.asString(Rpgc.get(sprite, "clip", "")))) {
                diagnostics.append(Rpgc.error("systems.party-member-sprite-clip",
                    where + " member '" + memberId + "' sprite must name a clip",
                    at + "/sprite/clip", ""));
            }
        }
    }
    return diagnostics;
}

// ----------------------------------------------------------- encounter
//
// A composition, plus the whole-battle settlement. Everything here exists
// because EncounterCatalogue validates the ARRAY as one unit: a single bad
// element makes `replaceFromJsonStrict` return failure and leave the previous
// catalogue in place, so a mistake in one encounter document silently removes
// every other battle from the game.
RpgcSystems.encounterDiagnostics <- function (doc) {
    local diagnostics = [];
    local id = Rpgc.asString(Rpgc.get(doc, "id", ""));
    local where = "encounter/" + id;

    if (!Rpgc.validId(id)) {
        diagnostics.append(Rpgc.error("systems.encounter-id",
            "encounter id must be a stable id", "/id", ""));
    }

    local displayName = Rpgc.asString(Rpgc.get(doc, "displayName", ""));
    if (displayName == "") {
        diagnostics.append(Rpgc.error("systems.encounter-display-name",
            where + " needs a non-empty displayName", "/displayName", ""));
    } else if (displayName.len() > 512) {
        diagnostics.append(Rpgc.error("systems.encounter-display-name-length",
            "displayName is " + displayName.len() + " bytes; the engine caps it at 512",
            "/displayName", ""));
    }

    // The one reward with a STRICT lower bound in the engine
    // (`finiteNumber(xpReward, 0.0, true)` -- EncounterCatalogue.cpp:94).
    if (Rpgc.asNumber(Rpgc.get(doc, "xpReward", 0)) <= 0.0) {
        diagnostics.append(Rpgc.error("systems.encounter-xp-reward",
            where + " has xpReward <= 0, which the engine rejects", "/xpReward",
            "xpReward must be strictly positive"));
    }
    // xpGrowth's bound is INCLUSIVE from 1.0 (EncounterCatalogue.cpp:94).
    local xpGrowth = Rpgc.asNumber(Rpgc.get(doc, "xpGrowth", 1.2));
    if (xpGrowth < 1.0) {
        diagnostics.append(Rpgc.error("systems.encounter-xp-growth",
            where + " has xpGrowth " + xpGrowth + "; the engine floors it at 1.0",
            "/xpGrowth", ""));
    }

    local members = Rpgc.get(doc, "members", []);
    local seen = {};
    for (local i = 0; i < members.len(); i += 1) {
        local at = "/members/" + i;
        local enemyId = Rpgc.asString(Rpgc.get(members[i], "enemy", ""));
        if (!Rpgc.validId(enemyId)) {
            diagnostics.append(Rpgc.error("systems.encounter-member-enemy",
                where + " member must name an enemy", at + "/enemy", ""));
            continue;
        }
        if (seen.rawin(enemyId)) {
            diagnostics.append(Rpgc.error("systems.encounter-member-duplicate",
                where + " lists enemy '" + enemyId + "' in two member entries",
                at + "/enemy",
                "member ids are derived from the enemy id and the loader rejects "
                + "duplicates; raise `count` on the first entry instead"));
            continue;
        }
        seen.rawset(enemyId, true);
    }
    local total = this.projectedMemberCount(doc);
    if (total > this.maxEncounterMembers) {
        diagnostics.append(Rpgc.error("systems.encounter-member-count",
            where + " projects " + total + " members but the engine caps a composition at "
            + this.maxEncounterMembers, "/members",
            "lower a `count`, or split the battle into two encounters"));
    }

    // Every id the settlement half feeds to the engine has to be non-empty:
    // `validId(value)` rejects "" at EncounterCatalogue.cpp:102-109.
    local quest = Rpgc.get(doc, "quest", 0);
    if (typeof quest == "table") {
        foreach (field in ["requiredQuestId", "notifyTopic", "notifyTarget",
                           "defeatCounterId", "levelPointAttributeId"]) {
            if (!Rpgc.validId(Rpgc.asString(Rpgc.get(quest, field, "")))) {
                diagnostics.append(Rpgc.error("systems.encounter-quest-id",
                    where + " needs a stable quest." + field, "/quest/" + field,
                    "the engine rejects an empty id here"));
            }
        }
    }
    return diagnostics;
}

// ------------------------------------------------------------ battle scene
//
// `battle` is the only kind in this module that describes SCREEN geometry
// rather than world data, and the only one nothing downstream reads: the engine
// has no battlefield / formation / slot type, so no loader will ever reject a
// scene and no renderer will ever complain about one. Every geometric rule the
// document depends on therefore has to be here, or it is never checked at all.
//
// The layout contract is two banks on one design-space canvas:
//
//   * the ENEMY bank is the top-left half  — x + width <= canvas.width / 2
//                                           AND y + height <= canvas.height / 2
//   * the PARTY bank is the bottom-right half — x >= canvas.width / 2
//                                              AND y >= canvas.height / 2
//
// Both axes matter. A bank that clears only one of them puts the two sides
// beside each other on the axis it ignored, which is the exact thing the design
// says must not happen, and it is invisible in the document unless you draw it.

RpgcSystems.rectOf <- function (value) {
    if (typeof value != "table") return 0;
    local rect = {};
    rect.x <- Rpgc.asNumber(Rpgc.get(value, "x", 0));
    rect.y <- Rpgc.asNumber(Rpgc.get(value, "y", 0));
    rect.width <- Rpgc.asNumber(Rpgc.get(value, "width", 0));
    rect.height <- Rpgc.asNumber(Rpgc.get(value, "height", 0));
    return rect;
}

// Inclusive on every edge, so a slot sitting exactly on the bank border is a
// legal position rather than an off-by-one surprise.
RpgcSystems.insideRect <- function (rect, x, y) {
    if (typeof rect != "table") return false;
    return x >= rect.x && x <= rect.x + rect.width
        && y >= rect.y && y <= rect.y + rect.height;
}

RpgcSystems.battleDiagnostics <- function (doc) {
    local diagnostics = [];
    local id = Rpgc.asString(Rpgc.get(doc, "id", ""));
    local where = "battle/" + id;

    if (!Rpgc.validId(id)) {
        diagnostics.append(Rpgc.error("systems.battle-id",
            "battle id must be a stable id", "/id", ""));
    }

    if (Rpgc.asString(Rpgc.get(doc, "displayName", "")) == "") {
        diagnostics.append(Rpgc.error("systems.battle-display-name",
            where + " needs a non-empty displayName", "/displayName", ""));
    }

    local canvas = Rpgc.get(doc, "canvas", 0);
    local canvasWidth = Rpgc.asNumber(Rpgc.get(canvas, "width", 0));
    local canvasHeight = Rpgc.asNumber(Rpgc.get(canvas, "height", 0));
    if (canvasWidth <= 0.0 || canvasHeight <= 0.0) {
        diagnostics.append(Rpgc.error("systems.battle-canvas",
            where + " needs a positive canvas width and height", "/canvas",
            "every slot coordinate is expressed in this design space"));
        return diagnostics;
    }

    local zones = Rpgc.get(doc, "zones", 0);
    local enemyZone = this.rectOf(Rpgc.get(zones, "enemy", 0));
    local allyZone = this.rectOf(Rpgc.get(zones, "ally", 0));
    if (enemyZone == 0 || allyZone == 0) {
        diagnostics.append(Rpgc.error("systems.battle-zone",
            where + " needs both zones.enemy and zones.ally rectangles", "/zones",
            "the enemy bank is the top-left half, the party bank the bottom-right"));
        return diagnostics;
    }

    // Off-canvas before off-half: a bank that runs off the canvas makes the
    // half comparison meaningless, and the two failures need different repairs.
    local sides = [["enemy", enemyZone, "/zones/enemy"],
                   ["ally", allyZone, "/zones/ally"]];
    foreach (entry in sides) {
        local name = entry[0];
        local rect = entry[1];
        local at = entry[2];
        if (rect.width <= 0.0 || rect.height <= 0.0) {
            diagnostics.append(Rpgc.error("systems.battle-zone-empty",
                where + " zone '" + name + "' has no area", at,
                "a zone with zero width or height can never hold a slot"));
            continue;
        }
        if (rect.x < 0.0 || rect.y < 0.0
            || rect.x + rect.width > canvasWidth
            || rect.y + rect.height > canvasHeight) {
            diagnostics.append(Rpgc.error("systems.battle-zone-outside-canvas",
                where + " zone '" + name + "' extends past the "
                + canvasWidth + "x" + canvasHeight + " canvas", at,
                "slot coordinates are relative to the canvas origin"));
        }
    }

    local halfX = canvasWidth / 2.0;
    local halfY = canvasHeight / 2.0;
    if (enemyZone.x + enemyZone.width > halfX || enemyZone.y + enemyZone.height > halfY) {
        diagnostics.append(Rpgc.error("systems.battle-zone-half",
            where + " zone 'enemy' is not inside the top-left half"
            + " (needs x + width <= " + halfX + " and y + height <= " + halfY + ")",
            "/zones/enemy",
            "enemies hold the top-left of the battle screen on BOTH axes"));
    }
    if (allyZone.x < halfX || allyZone.y < halfY) {
        diagnostics.append(Rpgc.error("systems.battle-zone-half",
            where + " zone 'ally' is not inside the bottom-right half"
            + " (needs x >= " + halfX + " and y >= " + halfY + ")",
            "/zones/ally",
            "the party holds the bottom-right of the battle screen on BOTH axes"));
    }

    diagnostics = this.battleSlotDiagnostics(doc, "enemySlots", "enemy", enemyZone,
        this.maxBattleEnemySlots, diagnostics);
    diagnostics = this.battleSlotDiagnostics(doc, "allySlots", "ally", allyZone,
        this.maxBattleAllySlots, diagnostics);

    // Only the per-document half of the hosting list is checked here. Whether
    // the list COVERS the project is `battleCrossDiagnostics`' job, because a
    // scene cannot see the other scenes -- and the schema's `minItems: 1` means
    // an empty list never reaches this function anyway.
    local encounters = Rpgc.get(doc, "encounters", []);
    local seen = {};
    for (local i = 0; i < encounters.len(); i += 1) {
        local encounterId = Rpgc.asString(encounters[i]);
        if (!Rpgc.validId(encounterId)) {
            diagnostics.append(Rpgc.error("systems.battle-encounter-id",
                where + " encounters[" + i + "] is not a stable id",
                "/encounters/" + i, ""));
            continue;
        }
        if (seen.rawin(encounterId)) {
            diagnostics.append(Rpgc.error("systems.battle-encounter-duplicate",
                where + " lists encounter '" + encounterId + "' twice",
                "/encounters/" + i,
                "one encounter is hosted by exactly one scene; listing it twice "
                + "here is two answers for the same fact"));
        }
        seen.rawset(encounterId, true);
    }

    diagnostics = this.battleUiDiagnostics(doc, canvasWidth, canvasHeight, enemyZone, diagnostics);
    return diagnostics;
}

// ------------------------------------------------------ battle screen UI
//
// The optional `ui` layer: the bottom-right party HUD and the left-hand command
// wheel. It is pure screen geometry like everything else in this document, and
// it is the only layer that can be WRONG IN A WAY THE PICTURE HIDES: furniture
// that slides over the enemy bank still renders, still validates numerically,
// and simply covers the thing the player is choosing a target from.
//
// So every rule here is about where a panel may NOT be:
//
//   * inside the canvas (a panel half off-screen is unreadable, not just ugly)
//   * the party HUD in the BOTTOM-RIGHT half, the command wheel in the LEFT half
//     -- the same two-axis rule the two banks obey, because the HUD belongs to
//     the side it reports on
//   * the command wheel not reaching into the ENEMY bank (the HUD cannot, and
//     the comment on the overlap check below spells out why)
//   * a bar row that does not spill past its own row, and a button that fits
//     inside its ring
//
// Four rules that look obvious are deliberately NOT here, because they could
// never fire and a gate nothing can trigger is worse than no gate:
//
//   * "a panel has zero area" / "the ring has no radius" -- the schema's
//     `minimum: 1` rejects those first, and validateDocument short-circuits;
//   * "the ui block is missing a panel" -- the schema marks both `required`;
//   * "the two panels overlap each other" -- the two half rules above already
//     force the wheel's right edge to <= canvas.width/2 and the HUD's left edge
//     to >= canvas.width/2, so the check is unreachable by construction;
//   * "the party HUD covers the enemy bank" -- the zone-half rule forces the
//     enemy bank to end at or before canvas.width/2 and the HUD to start at or
//     after it, so a HUD obeying its own half rule cannot reach it;
//   * "a command button is off-canvas" -- every button fits inside the wheel and
//     the wheel fits inside the canvas, so the button does too.
//
// A scene is valid; a scene whose HUD covers the monsters is a scene nobody can
// play. Only this function knows the difference.

RpgcSystems.rectsOverlap <- function (a, b) {
    if (typeof a != "table" || typeof b != "table") return false;
    if (a.x + a.width <= b.x || b.x + b.width <= a.x) return false;
    if (a.y + a.height <= b.y || b.y + b.height <= a.y) return false;
    return true;
}

RpgcSystems.discsOverlap <- function (ax, ay, ar, bx, by, br) {
    local dx = ax - bx;
    local dy = ay - by;
    local reach = ar + br;
    return dx * dx + dy * dy < reach * reach;
}

RpgcSystems.battleUiDiagnostics <- function (doc, canvasWidth, canvasHeight, enemyZone, diagnostics) {
    local where = "battle/" + Rpgc.asString(Rpgc.get(doc, "id", ""));

    // The backdrop path. Only the one thing the schema cannot say is checked:
    // that a declared path is not empty. The path SHAPE is not validated here
    // for the same reason `tileset.image` and `anim.image` are not -- the
    // workflow does not resolve or inspect images (README's "not provided"
    // list), and a document-relative path legitimately starts with `..` when the
    // art lives outside the kind directory, which `Rpgc.validRelPath` rejects.
    local background = Rpgc.get(doc, "background", 0);
    if (typeof background == "string" && background == "") {
        diagnostics.append(Rpgc.error("systems.battle-background-empty",
            where + " declares an empty background path", "/background",
            "omit the field entirely, or name a document-relative image"));
    }

    local ui = Rpgc.get(doc, "ui", 0);
    if (typeof ui != "table") return diagnostics;

    local halfX = canvasWidth / 2.0;
    local halfY = canvasHeight / 2.0;

    // ------------------------------------------------------------ party HUD
    local party = Rpgc.get(ui, "party", 0);
    local partyRect = this.rectOf(party);
    // The schema makes both panels required inside a `ui` block, so a missing
    // one never reaches here; this guard only keeps the arithmetic sane.
    if (partyRect == 0) return diagnostics;

    if (partyRect.width <= 0.0 || partyRect.height <= 0.0) {
        // Schema bounds own the floor; this only keeps the arithmetic sane.
        return diagnostics;
    }
    if (partyRect.x < 0.0 || partyRect.y < 0.0
        || partyRect.x + partyRect.width > canvasWidth
        || partyRect.y + partyRect.height > canvasHeight) {
        diagnostics.append(Rpgc.error("systems.battle-ui-outside-canvas",
            where + " ui.party extends past the " + canvasWidth + "x" + canvasHeight
            + " canvas", "/ui/party", "panel coordinates are relative to the canvas origin"));
    }

    // The HUD reports on the party, so it belongs to the party's half. This is
    // the same two-axis rule as zones.ally, for the same reason.
    if (partyRect.x < halfX || partyRect.y < halfY) {
        diagnostics.append(Rpgc.error("systems.battle-ui-half",
            where + " ui.party is not inside the bottom-right half"
            + " (needs x >= " + halfX + " and y >= " + halfY + ")",
            "/ui/party", "the party HUD sits with the party, mirroring zones.ally"));
    }

    local slotCount = Rpgc.asInt(Rpgc.get(party, "slots", 0));
    if (slotCount < 1 || slotCount > this.maxBattleAllySlots) {
        diagnostics.append(Rpgc.error("systems.battle-ui-slots",
            where + " ui.party.slots is " + slotCount + " but the party bank shows at most "
            + this.maxBattleAllySlots, "/ui/party/slots",
            "the HUD cannot show a face for a position the party bank does not have"));
    }

    // Every position the party bank can hold needs a face in the row, or the
    // member standing in the last one has no portrait at all. `allySlots` is a
    // capacity, so this is a capacity comparison, not a roster count -- the
    // roster is runtime state and cannot be checked from content.
    local allySlots = Rpgc.get(doc, "allySlots", []);
    if (slotCount > 0 && slotCount < allySlots.len()) {
        diagnostics.append(Rpgc.error("systems.battle-ui-slots-coverage",
            where + " ui.party shows " + slotCount + " portraits but the party bank holds "
            + allySlots.len() + " positions", "/ui/party/slots",
            "the HUD must be able to show every position the bank can fill"));
    }

    // The portrait row is horizontal, so the thing that has to fit is its WIDTH:
    // slots cells of slotWidth plus one gap between each pair. A row that runs
    // off the panel puts the last member's face outside the HUD entirely.
    local slotWidth = Rpgc.asNumber(Rpgc.get(party, "slotWidth", 0));
    local slotGap = Rpgc.asNumber(Rpgc.get(party, "slotGap", 0));
    local portraitHeight = Rpgc.asNumber(Rpgc.get(party, "portraitHeight", 0));
    if (slotCount > 0 && slotWidth > 0.0) {
        local rowWidth = slotCount * slotWidth + (slotCount - 1) * slotGap;
        if (rowWidth > partyRect.width) {
            diagnostics.append(Rpgc.error("systems.battle-ui-row-overflow",
                where + " ui.party shows " + slotCount + " portraits of " + slotWidth
                + " with " + slotGap + " between them (" + rowWidth
                + ") but the panel is only " + partyRect.width + " wide",
                "/ui/party/slotWidth",
                "the last face would hang outside the HUD"));
        }
    }

    // The bars live BELOW the portrait strip, so they are measured from its
    // bottom edge and their budget is the panel height minus portraitHeight.
    // A bar past that budget is drawn on top of the faces it is reporting on.
    local barBudget = partyRect.height - portraitHeight;
    if (portraitHeight > 0.0 && barBudget <= 0.0) {
        diagnostics.append(Rpgc.error("systems.battle-ui-portrait-overflow",
            where + " ui.party.portraitHeight (" + portraitHeight
            + ") leaves no room for the bars in a " + partyRect.height + " tall panel",
            "/ui/party/portraitHeight",
            "the bars sit under the portraits; the two have to share the panel"));
    }

    local bars = Rpgc.get(party, "bars", []);
    if (bars.len() > this.maxBattlePartyBars) {
        diagnostics.append(Rpgc.error("systems.battle-ui-bar-count",
            where + " ui.party declares " + bars.len() + " bars but the row shows at most "
            + this.maxBattlePartyBars, "/ui/party/bars",
            "each bar is a resource number the player has to read at a glance"));
    }
    local seenBars = {};
    for (local i = 0; i < bars.len(); i += 1) {
        local at = "/ui/party/bars/" + i;
        local barId = Rpgc.asString(Rpgc.get(bars[i], "id", ""));
        if (!Rpgc.validId(barId)) {
            diagnostics.append(Rpgc.error("systems.battle-ui-bar-id",
                where + " ui.party.bars[" + i + "] needs a stable id", at + "/id",
                "the runtime writes the current hp (or the resource the id names) into "
                + "the bar this id labels"));
        } else if (seenBars.rawin(barId)) {
            diagnostics.append(Rpgc.error("systems.battle-ui-bar-duplicate",
                where + " declares bar '" + barId + "' twice", at + "/id",
                "two bars with one id draw the same number in two places"));
        } else {
            seenBars.rawset(barId, true);
        }

        local offsetY = Rpgc.asNumber(Rpgc.get(bars[i], "offsetY", 0));
        local barHeight = Rpgc.asNumber(Rpgc.get(bars[i], "height", 0));
        if (barBudget > 0.0 && offsetY + barHeight > barBudget) {
            diagnostics.append(Rpgc.error("systems.battle-ui-bar-overflow",
                where + " bar '" + barId + "' ends at " + (offsetY + barHeight)
                + " below the portraits but only " + barBudget + " is left for bars", at,
                "bars start at the bottom of the portrait strip; keep offsetY + height "
                + "within panel.height - portraitHeight"));
        }
    }

    // -------------------------------------------------------- command wheel
    local ring = Rpgc.get(ui, "commandRing", 0);
    if (typeof ring != "table") return diagnostics;
    local cx = Rpgc.asNumber(Rpgc.get(ring, "cx", 0));
    local cy = Rpgc.asNumber(Rpgc.get(ring, "cy", 0));
    local radius = Rpgc.asNumber(Rpgc.get(ring, "radius", 0));
    if (radius > 0.0) {
        if (cx - radius < 0.0 || cy - radius < 0.0
            || cx + radius > canvasWidth || cy + radius > canvasHeight) {
            diagnostics.append(Rpgc.error("systems.battle-ui-outside-canvas",
                where + " ui.commandRing reaches past the " + canvasWidth + "x"
                + canvasHeight + " canvas", "/ui/commandRing",
                "the wheel is drawn whole or it is drawn as a broken circle"));
        }
        if (cx + radius > halfX) {
            diagnostics.append(Rpgc.error("systems.battle-ui-half",
                where + " ui.commandRing crosses the vertical midline"
                + " (needs cx + radius <= " + halfX + ")", "/ui/commandRing",
                "the command wheel owns the left of the screen, the party HUD the right"));
        }
    }

    // The overlap rule, and only for the wheel.
    //
    // There is no equivalent for the party HUD, and that is not an omission: the
    // zone-half rule already forces the enemy bank to end at or before
    // canvas.width/2 and the HUD to start at or after it, so a HUD that obeys
    // its own half rule cannot reach the enemy bank. The wheel is different --
    // being in the LEFT half does not keep it in the BOTTOM one, so a high wheel
    // really can sit over the monsters.
    local ringRect = {};
    ringRect.x <- cx - radius;
    ringRect.y <- cy - radius;
    ringRect.width <- radius * 2.0;
    ringRect.height <- radius * 2.0;
    if (radius > 0.0 && this.rectsOverlap(ringRect, enemyZone)) {
        diagnostics.append(Rpgc.error("systems.battle-ui-overlaps-enemies",
            where + " ui.commandRing reaches into the enemy bank", "/ui/commandRing",
            "screen furniture must not hide a target"));
    }

    local buttons = Rpgc.get(ring, "buttons", []);
    if (buttons.len() > this.maxBattleCommandButtons) {
        diagnostics.append(Rpgc.error("systems.battle-ui-button-count",
            where + " ui.commandRing declares " + buttons.len()
            + " buttons but the wheel holds at most " + this.maxBattleCommandButtons,
            "/ui/commandRing/buttons",
            "a wheel with more buttons than a hand can reach is a menu, not a wheel"));
    }
    local seenButtons = {};
    local placed = [];
    for (local i = 0; i < buttons.len(); i += 1) {
        local at = "/ui/commandRing/buttons/" + i;
        local buttonId = Rpgc.asString(Rpgc.get(buttons[i], "id", ""));
        if (!Rpgc.validId(buttonId)) {
            diagnostics.append(Rpgc.error("systems.battle-ui-button-id",
                where + " ui.commandRing.buttons[" + i + "] needs a stable id",
                at + "/id", "an input binding resolves a pressed button by this id"));
        } else if (seenButtons.rawin(buttonId)) {
            diagnostics.append(Rpgc.error("systems.battle-ui-button-duplicate",
                where + " declares command button '" + buttonId + "' twice", at + "/id",
                "two buttons with one id send the same command"));
        } else {
            seenButtons.rawset(buttonId, true);
        }

        local bx = Rpgc.asNumber(Rpgc.get(buttons[i], "x", 0));
        local by = Rpgc.asNumber(Rpgc.get(buttons[i], "y", 0));
        local br = Rpgc.asNumber(Rpgc.get(buttons[i], "radius", 0));
        if (br <= 0.0) {
            // Schema floor again; only here to keep the distance maths sane.
            continue;
        }
        // The button's whole disc has to fit in the wheel, not just its centre:
        // a button hanging over the rim reads as a rendering bug. This also
        // implies the button is on-canvas, because the wheel is.
        local dx = bx - cx;
        local dy = by - cy;
        local reach = dx * dx + dy * dy;
        local limit = radius - br;
        if (radius > 0.0 && (limit < 0.0 || reach > limit * limit)) {
            diagnostics.append(Rpgc.error("systems.battle-ui-button-outside-ring",
                where + " command button '" + buttonId + "' sticks out past the wheel",
                at, "buttons are placed inside the ring they belong to"));
        }
        for (local k = 0; k < placed.len(); k += 1) {
            if (!this.discsOverlap(bx, by, br, placed[k][0], placed[k][1], placed[k][2])) continue;
            diagnostics.append(Rpgc.error("systems.battle-ui-button-collision",
                where + " command button '" + buttonId + "' overlaps button '"
                + placed[k][3] + "'", at,
                "overlapping buttons make one of them unclickable"));
            break;
        }
        placed.append([bx, by, br, buttonId]);
    }

    return diagnostics;
}

// One bank's slots: the cap, the ids, the position, and the overlap rule.
// `maxCount` is a parameter rather than a `this.` read so the two banks cannot
// drift onto the same number by accident.
RpgcSystems.battleSlotDiagnostics <- function (doc, field, side, zone, maxCount, diagnostics) {
    local where = "battle/" + Rpgc.asString(Rpgc.get(doc, "id", ""));
    local slots = Rpgc.get(doc, field, []);
    if (slots.len() > maxCount) {
        diagnostics.append(Rpgc.error("systems.battle-slot-count",
            where + " declares " + slots.len() + " " + field + " but the " + side
            + " bank holds at most " + maxCount, "/" + field,
            "the top-left enemy bank holds 8, the bottom-right party bank 5"));
    }

    local seen = {};
    local positions = [];
    for (local i = 0; i < slots.len(); i += 1) {
        local at = "/" + field + "/" + i;
        local slotId = Rpgc.asString(Rpgc.get(slots[i], "id", ""));
        if (!Rpgc.validId(slotId)) {
            diagnostics.append(Rpgc.error("systems.battle-slot-id",
                where + " " + field + "[" + i + "] needs a stable slot id",
                at + "/id", "the runtime adapter keys its actor->slot table on this id"));
        } else if (seen.rawin(slotId)) {
            diagnostics.append(Rpgc.error("systems.battle-slot-duplicate",
                where + " declares slot id '" + slotId + "' twice in " + field,
                at + "/id", "two actors would be placed at the same bank position"));
        } else {
            seen.rawset(slotId, true);
        }

        local x = Rpgc.asNumber(Rpgc.get(slots[i], "x", 0));
        local y = Rpgc.asNumber(Rpgc.get(slots[i], "y", 0));
        if (!this.insideRect(zone, x, y)) {
            diagnostics.append(Rpgc.error("systems.battle-slot-outside-zone",
                where + " " + field + "[" + i + "] at (" + x + ", " + y
                + ") is outside the " + side + " zone ("
                + zone.x + ", " + zone.y + " " + zone.width + "x" + zone.height + ")",
                at, "the zone is the only thing keeping the two sides apart"));
        }
        for (local k = 0; k < positions.len(); k += 1) {
            if (positions[k][0] != x || positions[k][1] != y) continue;
            diagnostics.append(Rpgc.error("systems.battle-slot-collision",
                where + " " + field + "[" + i + "] shares its position with "
                + field + "[" + positions[k][2] + "]", at,
                "two slots at one point draw two actors on top of each other"));
            break;
        }
        positions.append([x, y, i]);
    }
    return diagnostics;
}

// ---------------------------------------------------------- references

// Typed references handed to the generic gate. Traits are deliberately absent:
// the trait registry lives inside eve.rpgc.rules rather than in a content kind,
// so it is checked in `extraDiagnostics` instead.
RpgcSystems.references <- function (doc) {
    local out = [];
    local schema = Rpgc.asString(Rpgc.get(doc, "schema", ""));
    if (schema == "eve.rpgc.rules") {
        local entries = Rpgc.get(doc, "breakEffects", []);
        for (local i = 0; i < entries.len(); i += 1) {
            local id = Rpgc.asString(Rpgc.get(entries[i], "effect", ""));
            if (id != "") {
                out.append({ kind = "effect", id = id, path = "/breakEffects/" + i + "/effect" });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.world") {
        local gates = Rpgc.get(doc, "gates", []);
        for (local i = 0; i < gates.len(); i += 1) {
            local at = "/gates/" + i;
            local portal = Rpgc.asString(Rpgc.get(gates[i], "portal", ""));
            local slash = portal.find("/");
            if (slash != null && slash > 0) {
                out.append({ kind = "map", id = portal.slice(0, slash),
                             path = at + "/portal" });
            }
            local open = Rpgc.get(gates[i], "open", 0);
            if (typeof open == "table" && Rpgc.get(open, "kind", "") == "object_consumed") {
                local mapId = Rpgc.asString(Rpgc.get(open, "mapId", ""));
                if (mapId != "") {
                    out.append({ kind = "map", id = mapId, path = at + "/open/mapId" });
                }
            }
        }
        local variants = Rpgc.get(doc, "styleVariants", []);
        for (local i = 0; i < variants.len(); i += 1) {
            foreach (field in ["tileset", "baseTileset"]) {
                local id = Rpgc.asString(Rpgc.get(variants[i], field, ""));
                if (id != "") {
                    out.append({ kind = "tileset", id = id,
                                 path = "/styleVariants/" + i + "/" + field });
                }
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.art") {
        local grades = Rpgc.get(doc, "grades", []);
        for (local i = 0; i < grades.len(); i += 1) {
            local at = "/grades/" + i;
            local skills = Rpgc.get(grades[i], "skills", []);
            for (local k = 0; k < skills.len(); k += 1) {
                out.append({ kind = "skill", id = Rpgc.asString(skills[k]),
                             path = at + "/skills/" + k });
            }
            local ultimates = Rpgc.get(grades[i], "ultimates", []);
            for (local k = 0; k < ultimates.len(); k += 1) {
                out.append({ kind = "skill", id = Rpgc.asString(ultimates[k]),
                             path = at + "/ultimates/" + k });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.heart") {
        local grants = Rpgc.get(doc, "grants", 0);
        if (typeof grants == "table") {
            local effects = Rpgc.get(grants, "effects", []);
            for (local i = 0; i < effects.len(); i += 1) {
                out.append({ kind = "effect", id = Rpgc.asString(effects[i]),
                             path = "/grants/effects/" + i });
            }
            local onHit = Rpgc.get(grants, "onHit", []);
            for (local i = 0; i < onHit.len(); i += 1) {
                out.append({ kind = "effect", id = Rpgc.asString(Rpgc.get(onHit[i], "effectId", "")),
                             path = "/grants/onHit/" + i + "/effectId" });
            }
        }
        local requires = Rpgc.get(doc, "requires", 0);
        if (typeof requires == "table") {
            local artId = Rpgc.asString(Rpgc.get(requires, "artId", ""));
            if (artId != "") {
                out.append({ kind = "art", id = artId, path = "/requires/artId" });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.combo") {
        local stages = Rpgc.get(doc, "stages", []);
        for (local i = 0; i < stages.len(); i += 1) {
            out.append({ kind = "skill", id = Rpgc.asString(Rpgc.get(stages[i], "skill", "")),
                         path = "/stages/" + i + "/skill" });
        }
        local finish = Rpgc.get(doc, "finish", 0);
        if (typeof finish == "table") {
            out.append({ kind = "skill", id = Rpgc.asString(Rpgc.get(finish, "skill", "")),
                         path = "/finish/skill" });
            local anim = Rpgc.get(finish, "anim", 0);
            if (typeof anim == "table") {
                out.append({ kind = "anim", id = Rpgc.asString(Rpgc.get(anim, "anim", "")),
                             path = "/finish/anim/anim" });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.item") {
        local use = Rpgc.get(doc, "use", 0);
        if (typeof use == "table") {
            local effects = Rpgc.get(use, "effects", []);
            for (local i = 0; i < effects.len(); i += 1) {
                out.append({ kind = "effect", id = Rpgc.asString(effects[i]),
                             path = "/use/effects/" + i });
            }
        }
        local teaches = Rpgc.get(doc, "teaches", 0);
        if (typeof teaches == "table") {
            local artId = Rpgc.asString(Rpgc.get(teaches, "art", ""));
            if (artId != "") out.append({ kind = "art", id = artId, path = "/teaches/art" });
            local skillId = Rpgc.asString(Rpgc.get(teaches, "skill", ""));
            if (skillId != "") out.append({ kind = "skill", id = skillId, path = "/teaches/skill" });
        }
        local requires = Rpgc.get(doc, "requires", 0);
        if (typeof requires == "table") {
            local artId = Rpgc.asString(Rpgc.get(requires, "artId", ""));
            if (artId != "") out.append({ kind = "art", id = artId, path = "/requires/artId" });
        }
        return out;
    }
    if (schema == "eve.rpgc.enemy") {
        local skillId = Rpgc.asString(Rpgc.get(doc, "skillId", ""));
        if (skillId != "") out.append({ kind = "skill", id = skillId, path = "/skillId" });
        local skills = Rpgc.get(doc, "skills", []);
        for (local i = 0; i < skills.len(); i += 1) {
            out.append({ kind = "skill", id = Rpgc.asString(skills[i]),
                         path = "/skills/" + i });
        }
        // Inverted on purpose: the habitat list names the MAPS the enemy lives
        // on, so each entry is an outbound reference to a map document.
        local habitat = Rpgc.get(doc, "habitat", []);
        for (local i = 0; i < habitat.len(); i += 1) {
            out.append({ kind = "map", id = Rpgc.asString(habitat[i]),
                         path = "/habitat/" + i });
        }
        local sprite = Rpgc.get(doc, "sprite", 0);
        if (typeof sprite == "table") {
            local animId = Rpgc.asString(Rpgc.get(sprite, "anim", ""));
            if (animId != "") out.append({ kind = "anim", id = animId, path = "/sprite/anim" });
        }
        local drops = Rpgc.get(doc, "drops", []);
        for (local i = 0; i < drops.len(); i += 1) {
            local itemId = Rpgc.asString(Rpgc.get(drops[i], "itemId", ""));
            if (itemId != "") {
                out.append({ kind = "item", id = itemId, path = "/drops/" + i + "/itemId" });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.party") {
        // Only the declared half is a reference. The moves a member actually
        // fights with are compiled at runtime from `art` + `grade` (docs/06
        // §2.4), so the art document is one reference covering all of them --
        // the per-grade skill ids themselves are already checked by
        // `artCrossDiagnostics`, against the same art.
        local members = Rpgc.get(doc, "members", []);
        for (local i = 0; i < members.len(); i += 1) {
            local at = "/members/" + i;
            local artId = Rpgc.asString(Rpgc.get(members[i], "art", ""));
            if (artId != "") out.append({ kind = "art", id = artId, path = at + "/art" });
            local skills = Rpgc.get(members[i], "skills", []);
            for (local k = 0; k < skills.len(); k += 1) {
                out.append({ kind = "skill", id = Rpgc.asString(skills[k]),
                             path = at + "/skills/" + k });
            }
            local sprite = Rpgc.get(members[i], "sprite", 0);
            if (typeof sprite == "table") {
                local animId = Rpgc.asString(Rpgc.get(sprite, "anim", ""));
                if (animId != "") {
                    out.append({ kind = "anim", id = animId, path = at + "/sprite/anim" });
                }
            }
        }
        // The opening bag is the only thing on a roster that points at another
        // kind: `combat` numbers and `art`/`grade` are resolved inside this
        // module, but an item id has a document behind it like any other ref.
        local starting = Rpgc.get(doc, "startingItems", []);
        for (local i = 0; i < starting.len(); i += 1) {
            local itemId = Rpgc.asString(Rpgc.get(starting[i], "itemId", ""));
            if (itemId != "") {
                out.append({ kind = "item", id = itemId, path = "/startingItems/" + i + "/itemId" });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.encounter") {
        local mapId = Rpgc.asString(Rpgc.get(doc, "map", ""));
        if (mapId != "") out.append({ kind = "map", id = mapId, path = "/map" });
        local members = Rpgc.get(doc, "members", []);
        for (local i = 0; i < members.len(); i += 1) {
            local enemyId = Rpgc.asString(Rpgc.get(members[i], "enemy", ""));
            if (enemyId != "") {
                out.append({ kind = "enemy", id = enemyId, path = "/members/" + i + "/enemy" });
            }
        }
        return out;
    }
    if (schema == "eve.rpgc.battle") {
        // Only the hosting list is a reference. The scene's geometry names no
        // document at all: the backdrop comes from the hosted encounter's `map`,
        // which is precisely why one scene can host fights on several maps.
        local encounters = Rpgc.get(doc, "encounters", []);
        for (local i = 0; i < encounters.len(); i += 1) {
            local encounterId = Rpgc.asString(encounters[i]);
            if (encounterId != "") {
                out.append({ kind = "encounter", id = encounterId,
                             path = "/encounters/" + i });
            }
        }
        return out;
    }
    return out;
}

// ------------------------------------------------------ whole-project

// The moment table every other `moment` mention is resolved against. Read here
// rather than passed in because `RpgcEvent` delegates its condition gate to this
// module, and an event document can be validated on its own.
RpgcSystems.momentTable <- function () {
    local world = this.worldDocument();
    if (typeof world != "table") return {};
    return this.momentTableOf(world);
}

// Every cross-document rule the six kinds need, in one place. `RpgcValidate`
// calls this once per module (not once per kind) after the generic reference
// gate has run, so the array indices and pointers below point at real problems
// rather than at references that are already reported.
RpgcSystems.extraDiagnostics <- function () {
    local diagnostics = [];
    local rules = this.rulesDocument();
    local world = this.worldDocument();

    diagnostics = this.singletonDiagnostics("rules", diagnostics);
    diagnostics = this.singletonDiagnostics("world", diagnostics);

    local moments = {};
    if (typeof world == "table") moments = this.momentTableOf(world);
    diagnostics = this.worldCrossDiagnostics(world, diagnostics);
    diagnostics = this.mapMomentDiagnostics(moments, diagnostics);
    diagnostics = this.artCrossDiagnostics(rules, diagnostics);
    diagnostics = this.heartCrossDiagnostics(rules, diagnostics);
    diagnostics = this.comboCrossDiagnostics(rules, diagnostics);
    diagnostics = this.itemCrossDiagnostics(rules, diagnostics);
    diagnostics = this.enemyCrossDiagnostics(rules, diagnostics);
    diagnostics = this.partyCrossDiagnostics(rules, diagnostics);
    diagnostics = this.resourceCrossDiagnostics(rules, diagnostics);
    diagnostics = this.encounterCrossDiagnostics(diagnostics);
    diagnostics = this.battleCrossDiagnostics(rules, diagnostics);
    diagnostics = this.styleVariantIsomorphismDiagnostics(world, diagnostics);
    return diagnostics;
}

// `rules` and `world` are tables every other document is read against, so two
// of them would be two authorities for the same fact — the failure mode the
// design refuses everywhere else. Zero is equally fatal: every art/heart/combo
// check below would silently pass over an empty element table.
RpgcSystems.singletonDiagnostics <- function (kind, diagnostics) {
    local count = this.documentsOf(kind).len();
    if (count == 1) return diagnostics;
    if (count == 0) {
        diagnostics.append(Rpgc.error("systems.no-" + kind,
            "no " + kind + " document exists, so nothing that depends on it was checked",
            "/" + kind, "add one under " + RpgcProject.directoryOf(kind)));
    } else {
        diagnostics.append(Rpgc.error("systems.many-" + kind,
            count + " " + kind + " documents exist; exactly one is the authority",
            "/" + kind, "merge them or delete the stale copy"));
    }
    return diagnostics;
}

RpgcSystems.findObjectInMap <- function (map, name) {
    foreach (layer in Rpgc.get(map, "layers", [])) {
        if (Rpgc.get(layer, "type", "") != "objectgroup") continue;
        foreach (object in Rpgc.get(layer, "objects", [])) {
            if (Rpgc.asString(Rpgc.get(object, "name", "")) == name) return object;
        }
    }
    return 0;
}

// A gate is keyed by "<mapId>/<objectName>" and the design keeps a locked
// portal IN the object layer, so the object must exist and must be a portal.
// A gate that points at a misspelled object is a door that never opens and
// never explains why.
RpgcSystems.worldCrossDiagnostics <- function (world, diagnostics) {
    if (typeof world != "table") return diagnostics;
    local gates = Rpgc.get(world, "gates", []);
    for (local i = 0; i < gates.len(); i += 1) {
        local portal = Rpgc.asString(Rpgc.get(gates[i], "portal", ""));
        local slash = portal.find("/");
        if (slash == null || slash <= 0 || slash >= portal.len() - 1) continue;
        local mapId = portal.slice(0, slash);
        local objectName = portal.slice(slash + 1, portal.len());
        local map = this.documentOf("map", mapId);
        if (!map.ok) continue;  // the reference gate reports the missing map
        local object = this.findObjectInMap(map.value, objectName);
        if (object == 0) {
            diagnostics.append(Rpgc.error("systems.gate-portal-missing",
                "gate names portal '" + portal + "' but map/" + mapId
                + " has no object '" + objectName + "'",
                "/gates/" + i + "/portal", "the object layer is the gate's anchor"));
        } else if (Rpgc.get(object, "type", "") != "portal") {
            diagnostics.append(Rpgc.error("systems.gate-portal-type",
                "gate names object '" + objectName + "' but its type is '"
                + Rpgc.asString(Rpgc.get(object, "type", "")) + "', not 'portal'",
                "/gates/" + i + "/portal", ""));
        }
    }
    return diagnostics;
}

// The other two places a moment id is written: a `moment.<id>` layer and an
// object's `moment` property. Both must name a band the world defines, or the
// layer simply never switches on and the NPC simply never appears.
RpgcSystems.mapMomentDiagnostics <- function (moments, diagnostics) {
    foreach (map in this.documentsOf("map")) {
        local mapId = Rpgc.asString(Rpgc.get(map, "id", ""));
        local layers = Rpgc.get(map, "layers", []);
        for (local i = 0; i < layers.len(); i += 1) {
            local id = Rpgc.asString(Rpgc.get(layers[i], "id", ""));
            if (id.len() <= 7 || id.slice(0, 7) != "moment.") continue;
            local band = id.slice(7, id.len());
            if (!moments.rawin(band)) {
                diagnostics.append(Rpgc.error("systems.map-unknown-moment",
                    "map/" + mapId + " layer '" + id + "' names moment '" + band
                    + "', which world.clock.moments does not define",
                    "map/" + mapId + ":/layers/" + i + "/id",
                    "declare the band, or the layer can never be selected"));
            }
        }
        foreach (layer in layers) {
            if (Rpgc.get(layer, "type", "") != "objectgroup") continue;
            foreach (object in Rpgc.get(layer, "objects", [])) {
                local name = Rpgc.asString(Rpgc.get(object, "name", ""));
                foreach (property in Rpgc.get(object, "properties", [])) {
                    if (Rpgc.asString(Rpgc.get(property, "name", "")) != "moment") continue;
                    local value = Rpgc.asString(Rpgc.get(property, "value", ""));
                    if (value != "" && !moments.rawin(value)) {
                        diagnostics.append(Rpgc.error("systems.object-unknown-moment",
                            "map/" + mapId + " object '" + name + "' has moment '"
                            + value + "', which world.clock.moments does not define",
                            "map/" + mapId + ":/layers/objects/" + name + "/moment",
                            "a typo here hides the unit instead of reporting it"));
                    }
                }
            }
        }
    }
    return diagnostics;
}

// The design's anti-cross-talk rule: a skill listed in an art's grade ladder
// must name the same art back. Without it, moving a skill between arts by
// copy-paste leaves the old art claiming a skill that has moved on — the art
// compiles to a skill id that does something else.
RpgcSystems.artCrossDiagnostics <- function (rules, diagnostics) {
    local registry = typeof rules == "table" ? this.traitTableOf(rules) : {};
    foreach (art in this.documentsOf("art")) {
        local artId = Rpgc.asString(Rpgc.get(art, "id", ""));
        local where = "art/" + artId;
        local grades = Rpgc.get(art, "grades", []);
        for (local i = 0; i < grades.len(); i += 1) {
            local at = "/grades/" + i;
            local skills = Rpgc.get(grades[i], "skills", []);
            for (local k = 0; k < skills.len(); k += 1) {
                local skillId = Rpgc.asString(skills[k]);
                local skill = this.documentOf("skill", skillId);
                if (!skill.ok) continue;  // the reference gate owns this one
                local declared = Rpgc.asString(Rpgc.get(skill.value, "art", ""));
                if (declared != artId) {
                    diagnostics.append(Rpgc.error("systems.art-skill-backref",
                        where + " lists skill '" + skillId + "' but that skill declares art '"
                        + (declared == "" ? "(none)" : declared) + "'",
                        where + ":" + at + "/skills/" + k,
                        "a skill must name the art that lists it"));
                }
            }
            local ultimates = Rpgc.get(grades[i], "ultimates", []);
            for (local k = 0; k < ultimates.len(); k += 1) {
                local skillId = Rpgc.asString(ultimates[k]);
                local skill = this.documentOf("skill", skillId);
                if (!skill.ok) continue;
                if (Rpgc.asString(Rpgc.get(skill.value, "art", "")) != artId) {
                    diagnostics.append(Rpgc.error("systems.art-ultimate-backref",
                        where + " lists ultimate '" + skillId
                        + "' but that skill does not declare this art",
                        where + ":" + at + "/ultimates/" + k, ""));
                }
                // Without the tag, "ultimate" is just a skill in a different list
                // and the project-side availability check has nothing to key on.
                local tagged = false;
                foreach (tag in Rpgc.get(skill.value, "tags", [])) {
                    if (Rpgc.asString(tag) == "ultimate") tagged = true;
                }
                if (!tagged) {
                    diagnostics.append(Rpgc.error("systems.art-ultimate-untagged",
                        "ultimate '" + skillId + "' is not tagged 'ultimate'",
                        where + ":" + at + "/ultimates/" + k,
                        "add \"ultimate\" to the skill's tags"));
                }
            }
            local traits = Rpgc.get(grades[i], "traits", []);
            for (local k = 0; k < traits.len(); k += 1) {
                local traitId = Rpgc.asString(traits[k]);
                if (traitId == "" || registry.rawin(traitId)) continue;
                diagnostics.append(Rpgc.error("systems.art-unknown-trait",
                    where + " grants unknown trait '" + traitId + "'",
                    where + ":" + at + "/traits/" + k,
                    "declare it in " + RpgcProject.directoryOf("rules")
                    + "/rules.wuxing.json under /traits"));
            }
        }
    }
    return diagnostics;
}

RpgcSystems.heartCrossDiagnostics <- function (rules, diagnostics) {
    if (typeof rules != "table") return diagnostics;
    local elements = this.elementsOf(rules);
    local registry = this.traitTableOf(rules);
    local hearts = this.documentsOf("heart");
    local groups = {};

    foreach (heart in hearts) {
        local heartId = Rpgc.asString(Rpgc.get(heart, "id", ""));
        local where = "heart/" + heartId;
        local grants = Rpgc.get(heart, "grants", 0);
        if (typeof grants == "table") {
            local traits = Rpgc.get(grants, "traits", []);
            for (local i = 0; i < traits.len(); i += 1) {
                local traitId = Rpgc.asString(traits[i]);
                if (traitId == "" || registry.rawin(traitId)) continue;
                diagnostics.append(Rpgc.error("systems.heart-unknown-trait",
                    where + " grants unknown trait '" + traitId + "'",
                    where + ":/grants/traits/" + i,
                    "declare it in " + RpgcProject.directoryOf("rules") + "/rules.wuxing.json"));
            }
            local override = Rpgc.asString(Rpgc.get(grants, "elementOverride", ""));
            if (override != "" && !this.memberOfList(elements, override)) {
                diagnostics.append(Rpgc.error("systems.heart-element-override",
                    where + " overrides to element '" + override
                    + "', which is not in the rules element table",
                    where + ":/grants/elementOverride", ""));
            }
        }

        local slots = Rpgc.get(heart, "slots", 0);
        local group = "";
        if (typeof slots == "table") group = Rpgc.asString(Rpgc.get(slots, "exclusiveGroup", ""));
        if (group == "") continue;
        if (!groups.rawin(group)) groups.rawset(group, []);
        local requires = Rpgc.get(heart, "requires", 0);
        local entry = {};
        entry.id <- heartId;
        entry.artId <- "";
        entry.minGrade <- 1;
        if (typeof requires == "table") {
            entry.artId = Rpgc.asString(Rpgc.get(requires, "artId", ""));
            entry.minGrade = Rpgc.asInt(Rpgc.get(requires, "minGrade", 1));
        }
        groups.rawget(group).append(entry);
    }

    // Two hearts in one exclusive group that require the same art at different
    // grades can never both be equipped (the looser one is implied by the
    // stricter one), so the document is already describing a contradiction the
    // runtime would only discover at equip time.
    foreach (group, entries in groups) {
        for (local i = 0; i < entries.len(); i += 1) {
            for (local k = i + 1; k < entries.len(); k += 1) {
                if (entries[i].artId == "" || entries[i].artId != entries[k].artId) continue;
                diagnostics.append(Rpgc.error("systems.heart-group-nesting",
                    "exclusiveGroup '" + group + "' holds heart/" + entries[i].id
                    + " (minGrade " + entries[i].minGrade + ") and heart/" + entries[k].id
                    + " (minGrade " + entries[k].minGrade + "), which both gate on art '"
                    + entries[i].artId + "'",
                    "heart/" + entries[k].id + ":/requires",
                    "one of them is redundant: the stricter requirement implies the other"));
            }
        }
    }
    return diagnostics;
}

// Combo resonance reads the SAME generates/overcomes tables as weak-point
// breaking, so an un-walkable chain is a combo that can never be performed.
RpgcSystems.comboCrossDiagnostics <- function (rules, diagnostics) {
    if (typeof rules != "table") return diagnostics;
    local elements = this.elementsOf(rules);
    local generates = Rpgc.get(rules, "generates", 0);
    local overcomes = Rpgc.get(rules, "overcomes", 0);
    local combos = this.documentsOf("combo");

    foreach (combo in combos) {
        local comboId = Rpgc.asString(Rpgc.get(combo, "id", ""));
        local where = "combo/" + comboId;
        local stages = Rpgc.get(combo, "stages", []);
        for (local i = 0; i < stages.len(); i += 1) {
            local skillId = Rpgc.asString(Rpgc.get(stages[i], "skill", ""));
            local skill = this.documentOf("skill", skillId);
            if (!skill.ok) continue;
            local declared = Rpgc.asString(Rpgc.get(skill.value, "combo", ""));
            if (declared != comboId) {
                diagnostics.append(Rpgc.error("systems.combo-skill-backref",
                    where + " lists skill '" + skillId + "' at stage " + i
                    + " but that skill declares combo '"
                    + (declared == "" ? "(none)" : declared) + "'",
                    where + ":/stages/" + i + "/skill",
                    "a combo stage skill must name the combo it belongs to"));
            }
        }

        local finish = Rpgc.get(combo, "finish", 0);
        if (typeof finish == "table") {
            local skillId = Rpgc.asString(Rpgc.get(finish, "skill", ""));
            local skill = this.documentOf("skill", skillId);
            if (skill.ok && Rpgc.asString(Rpgc.get(skill.value, "combo", "")) != comboId) {
                diagnostics.append(Rpgc.error("systems.combo-finish-backref",
                    where + " finisher '" + skillId + "' does not declare this combo",
                    where + ":/finish/skill", ""));
            }
            diagnostics = this.clipDiagnostics(Rpgc.get(finish, "anim", 0),
                where + ":/finish/anim", where + " finisher", diagnostics);
        }

        local condition = Rpgc.get(combo, "condition", 0);
        if (typeof condition != "table") continue;
        local elementBlock = Rpgc.get(condition, "elements", 0);
        if (typeof elementBlock != "table") continue;
        local chain = Rpgc.get(elementBlock, "chain", []);
        local relation = Rpgc.get(elementBlock, "kind", "") == "overcomes" ? overcomes : generates;
        local label = Rpgc.get(elementBlock, "kind", "") == "overcomes" ? "overcomes" : "generates";
        for (local i = 0; i + 1 < chain.len(); i += 1) {
            local from = Rpgc.asString(chain[i]);
            local to = Rpgc.asString(chain[i + 1]);
            if (!this.memberOfList(elements, from) || !this.memberOfList(elements, to)) continue;
            local mapped = "";
            if (typeof relation == "table" && relation.rawin(from)) {
                mapped = Rpgc.asString(relation.rawget(from));
            }
            if (mapped != to) {
                diagnostics.append(Rpgc.error("systems.combo-chain",
                    where + " requires '" + from + "' to " + label + " '" + to
                    + "', but the rules table says '" + from + "' " + label + " '"
                    + (mapped == "" ? "(nothing)" : mapped) + "'",
                    where + ":/condition/elements/chain/" + i,
                    "the combo's element rule and the break rule are one table"));
            }
        }
    }
    return diagnostics;
}

// An item's equipment half reaches the engine through two channels that do not
// know about each other: the item definition carries `equipSlot` as an
// unvalidated string, and the slot vocabulary lives only in whatever
// `EquipmentSet::defineSlot` calls the project makes at runtime. Nothing in the
// engine can tell that the two disagree, so the vocabulary is declared once in
// the rule document and every item is resolved against it here.
RpgcSystems.itemCrossDiagnostics <- function (rules, diagnostics) {
    if (typeof rules != "table") return diagnostics;
    local slots = this.equipmentSlotsOf(rules);
    foreach (item in this.documentsOf("item")) {
        local itemId = Rpgc.asString(Rpgc.get(item, "id", ""));
        local where = "item/" + itemId;

        local slot = Rpgc.asString(Rpgc.get(item, "equipSlot", ""));
        if (slot != "" && !this.memberOfList(slots, slot)) {
            diagnostics.append(Rpgc.error("systems.item-unknown-slot",
                where + " declares equipSlot '" + slot + "', which is not in the rule document's"
                + " equipmentSlots table",
                "/equipSlot",
                "the engine never resolves equipSlot, so the item would simply never be wearable"));
        }

        // A manual that names an art and a move must name a move of that art.
        // `artCrossDiagnostics` already enforces the skill -> art direction, so
        // this is the only place the pair can be checked.
        local teaches = Rpgc.get(item, "teaches", 0);
        if (typeof teaches == "table") {
            local artId = Rpgc.asString(Rpgc.get(teaches, "art", ""));
            local skillId = Rpgc.asString(Rpgc.get(teaches, "skill", ""));
            if (artId != "" && skillId != "") {
                local skill = this.documentOf("skill", skillId);
                if (skill.ok) {
                    local declared = Rpgc.asString(Rpgc.get(skill.value, "art", ""));
                    if (declared != artId) {
                        diagnostics.append(Rpgc.error("systems.item-teaches-mismatch",
                            where + " teaches skill '" + skillId + "' as part of art '" + artId
                            + "', but that skill declares art '"
                            + (declared == "" ? "(none)" : declared) + "'",
                            "/teaches/skill",
                            "a manual must teach a move that belongs to the art it names"));
                    }
                }
            }
        }

        local requires = Rpgc.get(item, "requires", 0);
        if (typeof requires == "table") {
            local artId = Rpgc.asString(Rpgc.get(requires, "artId", ""));
            if (artId != "") {
                local art = this.documentOf("art", artId);
                if (art.ok) {
                    local minGrade = Rpgc.asInt(Rpgc.get(requires, "minGrade", 1));
                    local maxGrade = Rpgc.asInt(Rpgc.get(art.value, "maxGrade", 0));
                    if (minGrade > maxGrade) {
                        diagnostics.append(Rpgc.error("systems.item-min-grade",
                            where + " requires " + artId + " grade " + minGrade
                            + ", but that art tops out at grade " + maxGrade,
                            "/requires/minGrade",
                            "the item could never become equippable"));
                    }
                }
            }
        }
    }
    return diagnostics;
}

// The five-element table and the weak-style table live in `eve.rpgc.rules` and
// nowhere else, so every element and style an enemy names is resolved against
// that one document here. A typo would otherwise be perfectly silent:
// `TraitSystem::getElementRate` looks the element up by string and simply finds
// no trait, so a mistyped weakness is not a wrong multiplier -- it is no
// multiplier at all, and the enemy reads as unkillable-by-design.
RpgcSystems.enemyCrossDiagnostics <- function (rules, diagnostics) {
    if (typeof rules != "table") return diagnostics;
    local elements = this.elementsOf(rules);
    local weakStyles = Rpgc.get(rules, "weakStyles", []);
    local breakCap = Rpgc.asInt(Rpgc.get(rules, "break.max", 0));

    foreach (enemy in this.documentsOf("enemy")) {
        local enemyId = Rpgc.asString(Rpgc.get(enemy, "id", ""));
        local where = "enemy/" + enemyId;

        local element = Rpgc.asString(Rpgc.get(enemy, "element", ""));
        if (element != "" && !this.memberOfList(elements, element)) {
            diagnostics.append(Rpgc.error("systems.enemy-unknown-element",
                where + " declares element '" + element + "', which the rule document's"
                + " elements table does not define", "/element",
                "the engine resolves an element by string and silently finds no trait"));
        }

        local weak = Rpgc.get(enemy, "weakElements", []);
        for (local i = 0; i < weak.len(); i += 1) {
            local id = Rpgc.asString(weak[i]);
            if (!this.memberOfList(elements, id)) {
                diagnostics.append(Rpgc.error("systems.enemy-unknown-weak-element",
                    where + " is weak to '" + id + "', which is not in the rule document's"
                    + " elements table", "/weakElements/" + i,
                    "an unknown element never fires, so the weakness is decorative"));
            } else if (id == element) {
                diagnostics.append(Rpgc.error("systems.enemy-weak-self",
                    where + " has element '" + id + "' and is also weak to it",
                    "/weakElements/" + i, "a creature is not weak to its own element"));
            }
        }

        local styles = Rpgc.get(enemy, "weakStyles", []);
        for (local i = 0; i < styles.len(); i += 1) {
            local id = Rpgc.asString(styles[i]);
            if (!this.memberOfList(weakStyles, id)) {
                diagnostics.append(Rpgc.error("systems.enemy-unknown-weak-style",
                    where + " is weak to style '" + id + "', which the rule document's"
                    + " weakStyles table does not define", "/weakStyles/" + i,
                    "the engine has no per-tag multiplier, so the project-side lookup"
                    + " is the only consumer and an unknown tag is dead weight"));
            }
        }

        if (Rpgc.has(enemy, "breakMax") && breakCap > 0) {
            local own = Rpgc.asInt(Rpgc.get(enemy, "breakMax", 0));
            if (own > breakCap) {
                diagnostics.append(Rpgc.error("systems.enemy-break-over-max",
                    where + " has breakMax " + own + " but the rule document caps break at "
                    + breakCap, "/breakMax",
                    "a gauge larger than the rule table's maximum can never be filled"));
            }
        }

        // The sprite's `{anim, clip}` pair must name a clip the set really
        // defines -- the same check `comboCrossDiagnostics` runs on its finisher.
        if (Rpgc.has(enemy, "sprite")) {
            diagnostics = this.clipDiagnostics(Rpgc.get(enemy, "sprite", 0),
                "/sprite", where, diagnostics);
        }
    }
    return diagnostics;
}

// `habitat` on an enemy and `map` on an encounter are two statements about the
// same fact -- where this creature is fought -- so the gate holds them to one
// answer. The repair is a single string in the enemy document, which is what
// keeps `habitat` a fact rather than decoration. An enemy that declares no
// habitat opts out: the field is optional, and "this thing roams everywhere"
// is expressed by listing the maps, not by omitting them.
//
// The second half reports the one reference this toolchain CANNOT resolve. The
// engine requires `requiredQuestId` to name an already-registered quest, but the
// workflow models no quest kind, so nothing here can look it up. A warning per
// document would print the same sentence once per encounter; one aggregated
// warning names exactly the ids the runtime must register before it calls
// replaceEncountersFromJson, which either succeeds for all of them or none.
// The player side, read against the same three tables as the monsters:
// `rules.elements`, `rules.break.max` and the battle screen's ally capacity.
//
// The capacity check is the reason the roster size is not a schema `maxItems`:
// `maxBattleAllySlots` is the single number that also decides how many slots a
// battle scene may declare, so a roster of six would be a roster whose sixth
// member has no position to stand on -- and both sides of that comparison have
// to read the same constant.
RpgcSystems.partyCrossDiagnostics <- function (rules, diagnostics) {
    if (typeof rules != "table") return diagnostics;
    local elements = this.elementsOf(rules);
    local breakCap = Rpgc.asInt(Rpgc.get(rules, "break.max", 0));

    foreach (party in this.documentsOf("party")) {
        local partyId = Rpgc.asString(Rpgc.get(party, "id", ""));
        local where = "party/" + partyId;
        local members = Rpgc.get(party, "members", []);

        if (members.len() > this.maxBattleAllySlots) {
            diagnostics.append(Rpgc.error("systems.party-too-many-members",
                where + " lists " + members.len() + " members but the battle screen"
                + " holds at most " + this.maxBattleAllySlots, "/members",
                "the extra members would be in the roster and on no slot"));
        }

        for (local i = 0; i < members.len(); i += 1) {
            local member = members[i];
            local memberId = Rpgc.asString(Rpgc.get(member, "id", ""));
            local at = "/members/" + i;
            local memberWhere = where + " member '" + memberId + "'";

            local element = Rpgc.asString(Rpgc.get(member, "element", ""));
            if (element != "" && !this.memberOfList(elements, element)) {
                diagnostics.append(Rpgc.error("systems.party-unknown-element",
                    memberWhere + " declares element '" + element + "', which the rule"
                    + " document's elements table does not define", at + "/element",
                    "both the break chain and the damage multiplier resolve an element"
                    + " by string, so an unknown one is a member with no element"));
            }

            if (Rpgc.has(member, "breakMax") && breakCap > 0) {
                local own = Rpgc.asInt(Rpgc.get(member, "breakMax", 0));
                if (own > breakCap) {
                    diagnostics.append(Rpgc.error("systems.party-break-over-max",
                        memberWhere + " has breakMax " + own + " but the rule document"
                        + " caps break at " + breakCap, at + "/breakMax",
                        "a gauge larger than the rule table's maximum can never be filled"));
                }
            }

            // The member's grade is compiled into that art's skills, so a grade
            // the art does not have would compile to an empty move list -- a
            // member who can act and has nothing to act with.
            local artId = Rpgc.asString(Rpgc.get(member, "art", ""));
            if (artId != "") {
                local art = this.documentOf("art", artId);
                if (!art.ok) {
                    // The generic reference gate already reported the dangling id;
                    // repeating it here would double every missing art.
                } else {
                    local grade = Rpgc.asInt(Rpgc.get(member, "grade", 1));
                    local maxGrade = Rpgc.asInt(Rpgc.get(art.value, "maxGrade", 0));
                    if (grade > maxGrade) {
                        diagnostics.append(Rpgc.error("systems.party-grade-over-max",
                            memberWhere + " holds grade " + grade + " of '" + artId
                            + "', whose maxGrade is " + maxGrade, at + "/grade",
                            "the runtime compiles the move list from grades[1..grade]"));
                    }
                }
            }

            if (Rpgc.has(member, "sprite")) {
                diagnostics = this.clipDiagnostics(Rpgc.get(member, "sprite", 0),
                    at + "/sprite", memberWhere, diagnostics);
            }
        }
    }
    return diagnostics;
}

// Every cost a skill declares must name a pool the rule document actually
// defines. `SkillDefinition.costs` is a list of free-form attribute names with
// no registry behind it, so a typo ("stamina" vs "staminia") produces a skill
// whose cost is read by nobody -- it silently becomes free. This is the second
// half of `resourceDiagnostics`: one gate checks the pool table's shape, this
// one checks that the pool table and the skills agree on the vocabulary.
RpgcSystems.resourceCrossDiagnostics <- function (rules, diagnostics) {
    if (typeof rules != "table") return diagnostics;
    local pools = {};
    foreach (entry in Rpgc.get(rules, "resources", [])) {
        pools.rawset(Rpgc.asString(Rpgc.get(entry, "attribute", "")), true);
    }

    foreach (skill in this.documentsOf("skill")) {
        local skillId = Rpgc.asString(Rpgc.get(skill, "id", ""));
        local costs = Rpgc.get(skill, "costs", []);
        for (local i = 0; i < costs.len(); i += 1) {
            local attribute = Rpgc.asString(Rpgc.get(costs[i], "attribute", ""));
            if (attribute == "") continue;
            if (!pools.rawin(attribute)) {
                diagnostics.append(Rpgc.error("systems.skill-cost-unregistered",
                    "skill/" + skillId + " costs '" + attribute + "', which the rule"
                    + " document declares no pool for", "/costs/" + i + "/attribute",
                    "declare the pool in " + RpgcProject.directoryOf("rules")
                    + "/rules.wuxing.json under /resources, or the cost is free"));
            }
        }
    }
    return diagnostics;
}

RpgcSystems.encounterCrossDiagnostics <- function (diagnostics) {
    local habitats = {};
    foreach (enemy in this.documentsOf("enemy")) {
        local maps = {};
        foreach (mapId in Rpgc.get(enemy, "habitat", [])) {
            maps.rawset(Rpgc.asString(mapId), true);
        }
        habitats.rawset(Rpgc.asString(Rpgc.get(enemy, "id", "")), maps);
    }

    local quests = {};
    foreach (encounter in this.documentsOf("encounter")) {
        local encounterId = Rpgc.asString(Rpgc.get(encounter, "id", ""));
        local where = "encounter/" + encounterId;

        local mapId = Rpgc.asString(Rpgc.get(encounter, "map", ""));
        if (mapId != "") {
            local members = Rpgc.get(encounter, "members", []);
            for (local i = 0; i < members.len(); i += 1) {
                local enemyId = Rpgc.asString(Rpgc.get(members[i], "enemy", ""));
                if (!habitats.rawin(enemyId)) continue;  // the reference gate owns this
                local maps = habitats.rawget(enemyId);
                if (maps.len() == 0 || maps.rawin(mapId)) continue;
                diagnostics.append(Rpgc.error("systems.encounter-habitat",
                    where + " is placed on map '" + mapId + "' but enemy '" + enemyId
                    + "' does not list that map in its habitat",
                    "/members/" + i + "/enemy",
                    "add \"" + mapId + "\" to the enemy's habitat, or move the encounter"));
            }
        }

        local quest = Rpgc.get(encounter, "quest", 0);
        if (typeof quest == "table") {
            local questId = Rpgc.asString(Rpgc.get(quest, "requiredQuestId", ""));
            if (questId != "") quests.rawset(questId, true);
        }
    }

    local names = [];
    foreach (questId, present in quests) names.append(questId);
    if (names.len() > 0) {
        names.sort();
        diagnostics.append(Rpgc.warn("systems.encounter-quest-unregistered",
            "encounter settlements require quest id(s) "
            + Rpgc.joinList(names, ", ") + ", which this toolchain cannot resolve",
            "/encounters",
            "the engine refuses the ENTIRE encounter array unless every requiredQuestId"
            + " is registered before replaceEncountersFromJson is called"));
    }
    return diagnostics;
}

// How many actors an encounter puts on the field. Lives here rather than inside
// either caller because three checks need the same number: the encounter's own
// 32-member ceiling, the battle scene's enemy-bank capacity, and anything added
// later. Two loops over `members[]` is exactly how those three answers drift.
RpgcSystems.projectedMemberCount <- function (encounter) {
    local total = 0;
    foreach (entry in Rpgc.get(encounter, "members", [])) {
        local count = Rpgc.asInt(Rpgc.get(entry, "count", 1));
        if (count < 1) count = 1;
        total += count;
    }
    return total;
}

// The battle layout's two whole-project rules. Neither is decidable from one
// document:
//
//   1. CAPACITY. An encounter projects N actors; the scene that hosts it offers
//      M enemy slots. N > M means the N-M-th enemy is drawn on top of an earlier
//      one (or not at all), and nothing in the engine will ever say so.
//   2. COVERAGE. Every encounter is hosted by EXACTLY one scene. Zero is a fight
//      with no layout; two is two answers to one question. Both are invisible
//      until someone plays the affected battle, which is precisely the kind of
//      hole a content tree accumulates silently.
RpgcSystems.battleCrossDiagnostics <- function (rules, diagnostics) {
    // The vocabulary the HUD bars are named in, read from the rule document the
    // same way `resourceCrossDiagnostics` reads it for skill costs.
    local pools = {};
    foreach (entry in Rpgc.get(rules, "resources", [])) {
        pools.rawset(Rpgc.asString(Rpgc.get(entry, "attribute", "")), true);
    }

    // encounter id -> the scene ids that claim it.
    local hosts = {};

    foreach (scene in this.documentsOf("battle")) {
        local sceneId = Rpgc.asString(Rpgc.get(scene, "id", ""));
        local where = "battle/" + sceneId;
        local slots = Rpgc.get(scene, "enemySlots", []);
        local encounters = Rpgc.get(scene, "encounters", []);

        // A HUD bar is `hp` or a registered pool. The runtime resolves the id in
        // the unit's resource table, so an id the rule document does not declare
        // draws an empty stripe that can never fill -- indistinguishable, on
        // screen, from a member who is simply out of mana.
        local ui = Rpgc.get(scene, "ui", 0);
        if (typeof ui == "table") {
            local party = Rpgc.get(ui, "party", 0);
            if (typeof party == "table") {
                local bars = Rpgc.get(party, "bars", []);
                for (local i = 0; i < bars.len(); i += 1) {
                    local barId = Rpgc.asString(Rpgc.get(bars[i], "id", ""));
                    if (barId == "" || barId == "hp") continue;
                    if (pools.rawin(barId)) continue;
                    diagnostics.append(Rpgc.error("systems.battle-ui-bar-unregistered",
                        where + " ui.party.bars[" + i + "] reads '" + barId
                        + "', which the rule document declares no pool for",
                        "/ui/party/bars/" + i + "/id",
                        "declare the pool in " + RpgcProject.directoryOf("rules")
                        + "/rules.wuxing.json under /resources, or the bar reads 0/0 "
                        + "for every member of every fight"));
                }
            }
        }

        if (encounters.len() == 0) {
            diagnostics.append(Rpgc.error("systems.battle-no-encounter",
                where + " hosts no encounter", "/encounters",
                "a scene nothing plays on is dead content; the coverage gate wants "
                + "every encounter hosted by exactly one scene"));
        }

        for (local i = 0; i < encounters.len(); i += 1) {
            local encounterId = Rpgc.asString(encounters[i]);
            if (encounterId == "") continue;
            local list = hosts.rawin(encounterId) ? hosts.rawget(encounterId) : [];
            list.append(sceneId);
            hosts.rawset(encounterId, list);

            local encounter = this.documentOf("encounter", encounterId);
            if (!encounter.ok) continue;  // the reference gate owns this
            local projected = this.projectedMemberCount(encounter.value);
            if (projected <= slots.len()) continue;
            diagnostics.append(Rpgc.error("systems.battle-capacity",
                where + " offers " + slots.len() + " enemy slot(s) but hosts '"
                + encounterId + "', which projects " + projected + " member(s)",
                "/enemySlots",
                "grow the enemy bank (the battle screen holds at most "
                + this.maxBattleEnemySlots + " slots), lower a `count`, or split "
                + "the encounter; anything past the last slot has no position"));
        }
    }

    foreach (encounter in this.documentsOf("encounter")) {
        local encounterId = Rpgc.asString(Rpgc.get(encounter, "id", ""));
        if (encounterId == "") continue;
        local list = hosts.rawin(encounterId) ? hosts.rawget(encounterId) : [];
        if (list.len() == 0) {
            diagnostics.append(Rpgc.error("systems.encounter-without-battle",
                "encounter/" + encounterId + " is hosted by no battle scene",
                "/encounters/" + encounterId,
                "add it to a `battle.encounters[]`, or the fight has no layout"));
            continue;
        }
        if (list.len() > 1) {
            diagnostics.append(Rpgc.error("systems.encounter-hosted-twice",
                "encounter/" + encounterId + " is hosted by " + list.len()
                + " battle scenes (" + Rpgc.joinList(list, ", ") + ")",
                "/encounters/" + encounterId,
                "one fight has exactly one layout; two scenes would be two "
                + "last-edited-wins answers to the same question"));
        }
    }
    return diagnostics;
}

// A `{anim, clip}` pair must name a clip the animation set really defines, the
// same shape `RpgcEvent.extraDiagnostics` uses for `play_animation`.
RpgcSystems.clipDiagnostics <- function (anim, pointer, where, diagnostics) {
    if (typeof anim != "table") return diagnostics;
    local animId = Rpgc.asString(Rpgc.get(anim, "anim", ""));
    local clipId = Rpgc.asString(Rpgc.get(anim, "clip", ""));
    if (animId == "" || clipId == "") return diagnostics;
    local document = this.documentOf("anim", animId);
    if (!document.ok) return diagnostics;
    foreach (clip in Rpgc.get(document.value, "clips", [])) {
        if (Rpgc.asString(Rpgc.get(clip, "id", "")) == clipId) return diagnostics;
    }
    diagnostics.append(Rpgc.error("systems.unknown-clip",
        where + " references clip '" + clipId + "' which anim/" + animId
        + " does not define", pointer + "/clip", ""));
    return diagnostics;
}

// The variant-isomorphism gate (06-game-design.md §1.7). Two atlases may only
// be swapped for one another if they agree GID for GID, because the engine
// checks none of it: a GID that means "grass" in the base atlas and "water" in
// the variant turns a handful of cells into the wrong terrain, and nobody finds
// that by eye in a few thousand tiles.
RpgcSystems.styleVariantIsomorphismDiagnostics <- function (world, diagnostics) {
    if (typeof world != "table") return diagnostics;
    local variants = Rpgc.get(world, "styleVariants", []);
    for (local i = 0; i < variants.len(); i += 1) {
        if (Rpgc.asString(Rpgc.get(variants[i], "mode", "")) != "atlas") continue;
        local at = "/styleVariants/" + i;
        local variantId = Rpgc.asString(Rpgc.get(variants[i], "tileset", ""));
        local baseId = Rpgc.asString(Rpgc.get(variants[i], "baseTileset", ""));
        if (variantId == "" || baseId == "") continue;
        local variant = this.documentOf("tileset", variantId);
        // `base` is a Squirrel keyword (class base), so the document is `baseDoc`.
        local baseDoc = this.documentOf("tileset", baseId);
        if (!variant.ok || !baseDoc.ok) continue;  // the reference gate reports these

        local where = "world/" + Rpgc.asString(Rpgc.get(world, "id", ""));
        if (Rpgc.asInt(Rpgc.get(variant.value, "firstGid", 1))
            != Rpgc.asInt(Rpgc.get(baseDoc.value, "firstGid", 1))) {
            diagnostics.append(Rpgc.error("systems.variant-firstgid",
                "atlas variant '" + variantId + "' has a different firstGid than '"
                + baseId + "'", where + ":" + at + "/tileset",
                "swapping them would shift every GID on the map"));
        }

        local variantTiles = RpgcTilemap.tilesOf(variant.value);
        local baseTiles = RpgcTilemap.tilesOf(baseDoc.value);
        if (variantTiles.len() != baseTiles.len()) {
            diagnostics.append(Rpgc.error("systems.variant-tile-count",
                "atlas variant '" + variantId + "' has " + variantTiles.len()
                + " tile(s) but '" + baseId + "' has " + baseTiles.len(),
                where + ":" + at + "/tileset",
                "a variant must be the same atlas redrawn, tile for tile"));
            continue;
        }
        local reported = 0;
        local mismatches = 0;
        for (local k = 0; k < baseTiles.len(); k += 1) {
            local baseTile = baseTiles[k];
            local variantTile = variantTiles[k];
            local same = Rpgc.asInt(Rpgc.get(baseTile, "gid", 0)) == Rpgc.asInt(Rpgc.get(variantTile, "gid", 0));
            if (same) same = this.sameNumbers(Rpgc.get(baseTile, "region", []),
                                              Rpgc.get(variantTile, "region", []));
            if (same) same = this.sameNumbers(Rpgc.get(baseTile, "pivot", []),
                                              Rpgc.get(variantTile, "pivot", []));
            if (same) same = this.sameNumbers(Rpgc.get(baseTile, "footprint", []),
                                              Rpgc.get(variantTile, "footprint", []));
            if (same) continue;
            mismatches += 1;
            if (reported >= 4) continue;
            reported += 1;
            diagnostics.append(Rpgc.error("systems.variant-mismatch",
                "atlas variant '" + variantId + "' does not match '" + baseId
                + "' at GID " + Rpgc.asInt(Rpgc.get(baseTile, "gid", 0)),
                where + ":" + at, "variants must be isomorphic, GID for GID"));
        }
        if (mismatches > reported) {
            diagnostics.append(Rpgc.error("systems.variant-mismatch-more",
                mismatches + " GID(s) differ between atlas variant '" + variantId
                + "' and '" + baseId + "'", where + ":" + at,
                "only the first " + reported + " are listed"));
        }
    }
    return diagnostics;
}
