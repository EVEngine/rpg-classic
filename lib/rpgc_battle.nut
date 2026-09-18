// EVEngine workflow / rpg-classic — the battle system.
//
// This module is the missing half of everything the workflow already had. The
// content tree describes a fight in five documents that never touch each other
// at runtime: `enemy` says what a creature is worth, `encounter` says which
// creatures show up, `party` says who the player brings, `battle` says where
// everyone stands, and `rules` says how the five elements and the break gauge
// work. Nothing in `src/` runs any of it. `src/modules/rpg` does carry a battle
// runtime (Battle / BattleSystem / BattleControl / StatusSystem), but this
// build does not bind it: `cmake/module_manifest/core_foundation.cmake` declares
// `rpg` with `SCRIPT RPG` and no `SLOT`, so `load.nut` never instantiates it and
// `"rpg" in getroottable()` is false (reproduced in tools/modules_check.nut).
// The resolver below is therefore a PROJECT-SIDE re-statement of the engine's
// rules, written against the source rather than guessed:
//
//   * the damage formula grammar and its error cases mirror
//     `BattleSystem::parseFormula` (BattleSystem.cpp:55-196);
//   * one hit is `resolveHit` in order (BattleSystem.cpp:210-251): hit roll,
//     formula, floor of 1, `elementRate`, crit multiplier 3;
//   * a modifier list composes the way `computeAttributeValue` does
//     (AttributeSet.cpp:100-142): additive, additive-percent, multiplicative,
//     then priority-ordered override / clamp;
//   * `multiply` is stored as `value - 1` and therefore means `*= value`
//     (AttributeSet.cpp:38-40).
//
// What is NOT the engine's: the five-element algebra, the break gauge, the turn
// clock and the enemy AI. Those are project-side by design (docs/06 §3.5,
// docs/09 §7), and the tables they read live in `eve.rpgc.rules` — this module
// hard-codes no element pair, no threshold and no duration.
//
// Everything here is deterministic and takes no engine binding: `newFight`
// consumes document values, and the random stream is carried inside the fight
// state, so a whole battle can be resolved in a headless `-r` script and get the
// same answer twice. `tools/modules_check.nut` does exactly that.
//
// The one thing this module does NOT own is presentation. It never loads a
// texture, never touches a SpriteAnim and never reads the mouse: it produces
// events, and `placeOnScene` projects slot indices onto screen coordinates, so
// the runtime adapter stays a projection (docs/10-battle-scene.md §5).

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcProject } from "./rpgc_project.nut"

export class RpgcBattle {
}

RpgcBattle.version <- 1

// Sides. `ally` is the player's half of the screen (bottom-right), `enemy` the
// other one. Strings rather than an enum because they end up in event records
// that a Squirrel UI reads back.
RpgcBattle.allySide <- "ally"
RpgcBattle.enemySide <- "enemy"

// The multiplier a target takes from an element it is weak to. The engine's own
// channel is `TraitSystem::getElementRate`, a product of `elementRate` traits --
// but enemy documents deliberately carry no traits (docs/09 §7), so the project
// side has exactly one source for this number and it is this constant, applied
// to `weakElements` membership.
RpgcBattle.weakElementRate <- 1.5

// `resolveHit` multiplies a crit by 3 (BattleSystem.cpp:242-247).
RpgcBattle.critMultiplier <- 3.0

// Guarding halves what the unit takes until its next turn. The design has a
// defend command (docs/10 §6.3) and the engine has no such modifier channel, so
// the project owns the factor as well.
RpgcBattle.guardMultiplier <- 0.5

// A hit is never worth zero: `resolveHit` floors a non-positive formula at 1
// (BattleSystem.cpp:234).
RpgcBattle.minDamage <- 1.0

// A fight that runs this many rounds without a winner is reported as stalled
// rather than looped forever. The engine's own scene director has no such cap
// because it has no turn scheduler; this is the project's, and it is a bug
// alarm, not a balance number.
RpgcBattle.maxRounds <- 99

RpgcBattle.defaultTurnSeconds <- 6.0
RpgcBattle.defaultBreakMax <- 100

// How often a fleeing enemy actually gets away once its HP is under the
// threshold its document declares. `ai.fleeBelowHp` is a condition, not a
// probability, and the document carries no second number -- so the chance is a
// project constant and the threshold stays the document's.
RpgcBattle.fleeChance <- 0.5

// ---------------------------------------------------------------- the clock
//
// The design speaks in TURNS and the engine speaks in SECONDS
// (`EffectDefinition.duration`, docs/06 §3.4). One round is exactly one
// `clock.turnSeconds` of status time, which is what makes `2 turns` equal
// `2 * turnSeconds` -- the derivation `RpgcSystems.breakEffectDiagnostics`
// already enforces on the effect documents.

RpgcBattle.turnSeconds <- function (rules) {
    local seconds = Rpgc.asNumber(Rpgc.get(rules, "clock.turnSeconds", 0));
    if (seconds <= 0.0) return this.defaultTurnSeconds;
    return seconds;
}

RpgcBattle.breakRules <- function (rules) {
    local out = {};
    out.max <- Rpgc.asInt(Rpgc.get(rules, "break.max", this.defaultBreakMax));
    out.onOvercome <- Rpgc.asInt(Rpgc.get(rules, "break.onOvercome", 0));
    out.onWeakElement <- Rpgc.asInt(Rpgc.get(rules, "break.onWeakElement", 0));
    out.onWeakStyle <- Rpgc.asInt(Rpgc.get(rules, "break.onWeakStyle", 0));
    out.regenPerRound <- Rpgc.asInt(Rpgc.get(rules, "break.regenPerRound", 0));
    return out;
}

// `rules.overcomes` is the table the design calls 相克. It is read here and
// nowhere else: re-typing the cycle into a runtime script is exactly the drift
// `eve.rpgc.rules` exists to prevent.
RpgcBattle.overcomes <- function (rules, attackerElement, defenderElement) {
    if (attackerElement == "" || defenderElement == "") return false;
    local table = Rpgc.get(rules, "overcomes", 0);
    if (typeof table != "table") return false;
    if (!table.rawin(attackerElement)) return false;
    return Rpgc.asString(table.rawget(attackerElement)) == defenderElement;
}

// ------------------------------------------------------------------- random
//
// A xorshift32 stream carried inside the fight, not a global and not the
// engine's `std::mt19937(seed)`: the engine's per-hit generator cannot be driven
// from Squirrel, and a fight that replays differently on the second run cannot
// be tested. Every draw goes through these two functions so there is one stream.

RpgcBattle.nextRandomInt <- function (fight) {
    local x = fight.rng;
    x = (x ^ (x << 13)) & 4294967295;
    x = (x ^ (x >> 17)) & 4294967295;
    x = (x ^ (x << 5)) & 4294967295;
    if (x <= 0) x = 2463534242;
    fight.rng = x;
    return x;
}

RpgcBattle.rollRandom <- function (fight) {
    return this.nextRandomInt(fight).tofloat() / 4294967296.0;
}

RpgcBattle.rollInt <- function (fight, low, high) {
    if (high <= low) return low;
    return low + (this.nextRandomInt(fight) % (high - low + 1));
}

// ------------------------------------------------------------- expressions
//
// The grammar is the engine's, exactly: `+ - * /`, parentheses, unary sign,
// numbers, and `a.<attribute>` / `b.<attribute>`. An attribute is read through
// `attributeOf`, i.e. the FINAL value, because `parseFactor` calls
// `AttributeSystem::getFinal` (BattleSystem.cpp:152).

RpgcBattle.evaluate <- function (formula, attacker, target) {
    if (typeof formula != "string" || formula.len() == 0) {
        return Rpgc.fail([Rpgc.error("battle.formula-empty",
            "damage formula must not be empty", "/damage/formula", "")]);
    }
    local p = {};
    p.text <- formula;
    p.pos <- 0;
    p.a <- attacker;
    p.b <- target;
    p.error <- "";
    local value = this._expression(p);
    if (p.error != "") {
        return Rpgc.fail([Rpgc.error("battle.formula-syntax", p.error,
            "/damage/formula", formula)]);
    }
    if (p.pos != formula.len()) {
        return Rpgc.fail([Rpgc.error("battle.formula-trailing",
            "damage formula contains trailing input at " + p.pos, "/damage/formula", formula)]);
    }
    if (value != value || value > 1.0e308 || value < -1.0e308) {
        return Rpgc.fail([Rpgc.error("battle.formula-not-finite",
            "damage formula result must be finite", "/damage/formula", formula)]);
    }
    return Rpgc.ok(value);
}

RpgcBattle._skipSpace <- function (p) {
    while (p.pos < p.text.len()) {
        local c = p.text[p.pos];
        if (c == 32 || c == 9 || c == 10 || c == 13) p.pos += 1;
        else break;
    }
}

RpgcBattle._fail <- function (p, message) {
    if (p.error == "") p.error = message + " at " + p.pos;
}

RpgcBattle._expression <- function (p) {
    local lhs = this._term(p);
    while (true) {
        this._skipSpace(p);
        if (p.pos >= p.text.len()) break;
        local c = p.text[p.pos];
        if (c == 43) {
            p.pos += 1;
            lhs += this._term(p);
        } else if (c == 45) {
            p.pos += 1;
            lhs -= this._term(p);
        } else {
            break;
        }
    }
    return lhs;
}

RpgcBattle._term <- function (p) {
    local lhs = this._factor(p);
    while (true) {
        this._skipSpace(p);
        if (p.pos >= p.text.len()) break;
        local c = p.text[p.pos];
        if (c == 42) {
            p.pos += 1;
            lhs *= this._factor(p);
        } else if (c == 47) {
            p.pos += 1;
            local rhs = this._factor(p);
            if (rhs == 0.0) {
                this._fail(p, "damage formula cannot divide by zero");
                lhs = 0.0;
            } else {
                lhs /= rhs;
            }
        } else {
            break;
        }
    }
    return lhs;
}

RpgcBattle._factor <- function (p) {
    this._skipSpace(p);
    if (p.pos >= p.text.len()) {
        this._fail(p, "damage formula is incomplete");
        return 0.0;
    }
    local c = p.text[p.pos];

    if (c == 43 || c == 45) {
        p.pos += 1;
        local signed = this._factor(p);
        return c == 45 ? -signed : signed;
    }

    if (c == 40) {
        p.pos += 1;
        local grouped = this._expression(p);
        this._skipSpace(p);
        if (p.pos >= p.text.len() || p.text[p.pos] != 41) {
            this._fail(p, "damage formula is missing a closing parenthesis");
            return 0.0;
        }
        p.pos += 1;
        return grouped;
    }

    if ((c == 97 || c == 98) && p.pos + 1 < p.text.len() && p.text[p.pos + 1] == 46) {
        local isAttacker = (c == 97);
        p.pos += 2;
        local name = "";
        while (p.pos < p.text.len()) {
            local n = p.text[p.pos];
            local named = (n >= 48 && n <= 57) || (n >= 65 && n <= 90) ||
                          (n >= 97 && n <= 122) || n == 95;
            if (!named) break;
            name += p.text.slice(p.pos, p.pos + 1);
            p.pos += 1;
        }
        if (name == "") {
            this._fail(p, "damage formula attribute name must not be empty");
            return 0.0;
        }
        local actor = isAttacker ? p.a : p.b;
        if (typeof actor != "table") return 0.0;
        return this.attributeOf(actor, name);
    }

    if ((c >= 48 && c <= 57) || c == 46) {
        local text = "";
        while (p.pos < p.text.len()) {
            local n = p.text[p.pos];
            if (!((n >= 48 && n <= 57) || n == 46)) break;
            text += p.text.slice(p.pos, p.pos + 1);
            p.pos += 1;
        }
        if (!this._looksLikeNumber(text)) {
            this._fail(p, "damage formula contains an invalid number");
            return 0.0;
        }
        local value = 0.0;
        try {
            value = text.tofloat();
        } catch (e) {
            this._fail(p, "damage formula contains an invalid number");
            return 0.0;
        }
        return value;
    }

    this._fail(p, "damage formula expected a number, attribute, unary sign, or"
        + " parenthesized expression");
    return 0.0;
}

// `strtod` in the engine is strict about the whole run being one number
// (BattleSystem.cpp:161-165): "1.2.3" is an error, not 1.2 with a tail.
RpgcBattle._looksLikeNumber <- function (text) {
    local digits = 0;
    local dots = 0;
    for (local i = 0; i < text.len(); i += 1) {
        local c = text[i];
        if (c == 46) dots += 1;
        else if (c >= 48 && c <= 57) digits += 1;
        else return false;
    }
    return digits > 0 && dots <= 1;
}

// ------------------------------------------------------------- attributes
//
// `attributeOf` is `AttributeSystem::getFinal`, restricted to the attributes a
// combatant actually owns. The name is looked up on the unit first (attack,
// defense, speed, maxHp, hp), then in its resource pools; anything else is 0,
// which is what the engine returns for an attribute an actor does not have.

RpgcBattle.baseAttribute <- function (unit, name) {
    if (name == "attack") return unit.attack;
    if (name == "defense") return unit.defense;
    if (name == "speed") return unit.speed;
    if (name == "maxHp") return unit.maxHp;
    if (name == "hp") return unit.hp;
    if (unit.resourceMax.rawin(name)) return unit.resources.rawget(name);
    return 0.0;
}

RpgcBattle.attributeOf <- function (unit, name) {
    if (typeof unit != "table") return 0.0;
    local declared = this.baseAttribute(unit, name);
    local additive = 0.0;
    local additivePercent = 0.0;
    local multiplicative = 1.0;
    local ordered = [];

    foreach (inst in unit.effects) {
        // A periodic effect binds no modifiers at all while it is running:
        // StatusSystem returns an empty binding table the moment `period > 0`
        // (StatusSystem.cpp:202), and content/effects/bleed.json records that.
        if (this.effectIsPeriodic(inst)) continue;
        foreach (modifier in Rpgc.get(inst.def, "modifiers", [])) {
            if (Rpgc.asString(Rpgc.get(modifier, "attribute", "")) != name) continue;
            local op = Rpgc.asString(Rpgc.get(modifier, "op", "add"));
            local value = Rpgc.asNumber(Rpgc.get(modifier, "value", 0));
            if (op == "add") {
                additive += value;
            } else if (op == "additive_percent" || op == "mulAdd") {
                additivePercent += value;
            } else if (op == "multiplicative_percent" || op == "mulMul") {
                multiplicative *= (1.0 + value);
            } else if (op == "multiply") {
                multiplicative *= value;
            } else {
                local entry = {};
                entry.op <- op;
                entry.value <- value;
                entry.priority <- Rpgc.asInt(Rpgc.get(modifier, "priority", 0));
                ordered.append(entry);
            }
        }
    }

    local result = (declared + additive) * (1.0 + additivePercent) * multiplicative;
    foreach (entry in this._byPriority(ordered)) {
        if (entry.op == "override") result = entry.value;
        else if (entry.op == "clamp_min" || entry.op == "clampMin" || entry.op == "min") {
            if (entry.value > result) result = entry.value;
        } else if (entry.op == "clamp_max" || entry.op == "clampMax" || entry.op == "max") {
            if (entry.value < result) result = entry.value;
        }
    }
    return result;
}

// Stable insertion sort by priority: `computeAttributeValue` uses
// `std::stable_sort` on `(priority, sequence)`, so equal priorities keep the
// order they were declared in.
RpgcBattle._byPriority <- function (entries) {
    local out = [];
    foreach (entry in entries) {
        local at = out.len();
        while (at > 0 && out[at - 1].priority > entry.priority) at -= 1;
        out.insert(at, entry);
    }
    return out;
}

RpgcBattle.effectIsPeriodic <- function (inst) {
    return Rpgc.asNumber(Rpgc.get(inst.def, "period", 0)) > 0.0;
}

RpgcBattle.hasEffectTag <- function (unit, wanted) {
    foreach (inst in unit.effects) {
        foreach (candidate in Rpgc.get(inst.def, "tags", [])) {
            if (Rpgc.asString(candidate) == wanted) return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------ units

// The same member id `tools/build_encounters.py` projects into the engine's
// array (`stem.index`), so a log line from this resolver names the same creature
// the engine's catalogue would.
RpgcBattle.projectedMemberId <- function (enemyId, index) {
    local stem = enemyId;
    local dot = enemyId.find(".");
    if (dot != null && dot >= 0) stem = enemyId.slice(dot + 1, enemyId.len());
    return stem + "." + index;
}

RpgcBattle.blankUnit <- function (id, side, slot, displayName, element, combat, breakMax) {
    local unit = {};
    unit.id <- id;
    unit.side <- side;
    unit.slot <- slot;
    unit.displayName <- displayName;
    unit.element <- element;
    unit.attack <- Rpgc.asNumber(Rpgc.get(combat, "attack", 0));
    unit.defense <- Rpgc.asNumber(Rpgc.get(combat, "defense", 0));
    unit.maxHp <- Rpgc.asNumber(Rpgc.get(combat, "maxHp", 0));
    unit.speed <- Rpgc.asNumber(Rpgc.get(combat, "speed", 0));
    unit.hp <- unit.maxHp;
    unit.breakMax <- breakMax;
    unit.breakValue <- breakMax;
    unit.broken <- false;
    unit.alive <- true;
    unit.fled <- false;
    unit.guarding <- false;
    unit.turns <- 0;
    unit.weakElements <- [];
    unit.weakStyles <- [];
    unit.skills <- [];
    unit.cooldowns <- {};
    unit.resources <- {};
    unit.resourceMax <- {};
    unit.effects <- [];
    unit.basicSkill <- "";
    unit.blueprint <- 0;
    return unit;
}

RpgcBattle.attachResources <- function (unit, rules) {
    foreach (pool in Rpgc.get(rules, "resources", [])) {
        local attribute = Rpgc.asString(Rpgc.get(pool, "attribute", ""));
        if (attribute == "") continue;
        local maximum = Rpgc.asNumber(Rpgc.get(pool, "max", 0));
        unit.resourceMax.rawset(attribute, maximum);
        unit.resources.rawset(attribute, maximum);
    }
    return unit;
}

// A member's move list is COMPILED, never stored: `art` + `grade` name the art
// document's grade rows, and the union of `skills` + `ultimates` up to that
// grade is the move set (docs/06 §2.4). `skills[]` on the member is for the
// moves that belong to no art at all. Keeping the compiled list on the unit is
// a projection of documents that are still the source of truth -- the unit is
// rebuilt from them on every fight.
RpgcBattle.compileSkills <- function (member, arts) {
    local out = [];
    local seen = {};
    foreach (skillId in Rpgc.get(member, "skills", [])) {
        local id = Rpgc.asString(skillId);
        if (id == "" || seen.rawin(id)) continue;
        seen.rawset(id, true);
        out.append(id);
    }
    local artId = Rpgc.asString(Rpgc.get(member, "art", ""));
    if (artId != "" && arts.rawin(artId)) {
        local art = arts.rawget(artId);
        local grade = Rpgc.asInt(Rpgc.get(member, "grade", 1));
        foreach (row in Rpgc.get(art, "grades", [])) {
            if (Rpgc.asInt(Rpgc.get(row, "grade", 0)) > grade) continue;
            foreach (field in ["skills", "ultimates"]) {
                foreach (skillId in Rpgc.get(row, field, [])) {
                    local id = Rpgc.asString(skillId);
                    if (id == "" || seen.rawin(id)) continue;
                    seen.rawset(id, true);
                    out.append(id);
                }
            }
        }
    }
    return out;
}

// ------------------------------------------------------------ fight setup

// `config` is a plain bag of document VALUES:
//
//   rules, battle, encounter, party
//   enemies = { id -> document }, skills = { id -> document }
//   effects = { id -> document }, arts = { id -> document }
//   seed = <integer>
//
// Nothing is read from disk here, which is what lets the checks drive a fight
// with in-memory documents that never touch `content/`.
RpgcBattle.newFight <- function (config) {
    local diagnostics = [];
    foreach (field in ["rules", "battle", "encounter", "party"]) {
        if (!config.rawin(field) || typeof config.rawget(field) != "table") {
            diagnostics.append(Rpgc.error("battle.missing-document",
                "a fight needs a " + field + " document", "/" + field, ""));
        }
    }
    if (Rpgc.errorCount(diagnostics) > 0) return Rpgc.fail(diagnostics);

    local rules = config.rawget("rules");
    local battle = config.rawget("battle");
    local encounter = config.rawget("encounter");
    local party = config.rawget("party");
    local enemies = config.rawin("enemies") ? config.rawget("enemies") : {};
    local skills = config.rawin("skills") ? config.rawget("skills") : {};
    local effects = config.rawin("effects") ? config.rawget("effects") : {};
    local arts = config.rawin("arts") ? config.rawget("arts") : {};

    local fight = {};
    fight.rules <- rules;
    fight.battle <- battle;
    fight.encounter <- encounter;
    fight.party <- party;
    fight.skills <- skills;
    fight.effects <- effects;
    fight.arts <- arts;
    fight.round <- 1;
    fight.turnIndex <- 0;
    fight.order <- [];
    fight.units <- [];
    fight.byId <- {};
    fight.log <- [];
    fight.events <- [];
    fight.outcome <- "";
    fight.pending <- "";
    fight.rng <- Rpgc.asInt(Rpgc.get(config, "seed", 20260916));
    if (fight.rng <= 0) fight.rng = 20260916;
    fight.turnSeconds <- this.turnSeconds(rules);
    fight.breakRules <- this.breakRules(rules);

    // --- the player's side
    //
    // `allySlots` is a capacity, not a roster (docs/10 §3): a scene with four
    // ally positions seats four people, and the fifth waits. That is why the
    // surplus is named on `fight.bench` rather than refused -- the encounter
    // tables in this project host fights in the narrow pass, and a resolver that
    // insisted on seating everybody would make real content unplayable.
    local allySlots = Rpgc.get(battle, "allySlots", []);
    local index = 0;
    fight.bench <- [];
    foreach (member in Rpgc.get(party, "members", [])) {
        local memberId = Rpgc.asString(Rpgc.get(member, "id", ""));
        if (index >= allySlots.len()) {
            fight.bench.append(memberId);
            continue;
        }
        local unit = this.blankUnit(memberId, this.allySide, index,
            Rpgc.asString(Rpgc.get(member, "displayName", memberId)),
            Rpgc.asString(Rpgc.get(member, "element", "")),
            Rpgc.get(member, "combat", {}),
            Rpgc.asInt(Rpgc.get(member, "breakMax", fight.breakRules.max)));
        unit.weakElements <- [];
        unit.weakStyles <- [];
        unit.skills <- this.compileSkills(member, arts);
        this.attachResources(unit, rules);
        this.addUnit(fight, unit);
        index += 1;
    }

    // --- the encounter's side, expanded exactly the way the projection tool does
    local enemySlots = Rpgc.get(battle, "enemySlots", []);
    local projected = 0;
    foreach (entry in Rpgc.get(encounter, "members", [])) {
        local enemyId = Rpgc.asString(Rpgc.get(entry, "enemy", ""));
        local count = Rpgc.asInt(Rpgc.get(entry, "count", 1));
        if (count < 1) count = 1;
        local prototype = enemies.rawin(enemyId) ? enemies.rawget(enemyId) : 0;
        for (local n = 0; n < count; n += 1) {
            if (projected >= enemySlots.len()) {
                diagnostics.append(Rpgc.error("battle.over-capacity",
                    "the encounter expands to more members than the scene has enemy slots",
                    "/enemySlots", "RpgcSystems.battle-capacity checks this before the fight"));
                break;
            }
            if (prototype == 0) {
                diagnostics.append(Rpgc.error("battle.unknown-enemy",
                    "the encounter names enemy '" + enemyId + "', which is not loaded",
                    "/members", ""));
                projected += 1;
                continue;
            }
            local unit = this.blankUnit(this.projectedMemberId(enemyId, n),
                this.enemySide, projected,
                Rpgc.asString(Rpgc.get(prototype, "displayName", enemyId)),
                Rpgc.asString(Rpgc.get(prototype, "element", "")),
                Rpgc.get(prototype, "combat", {}),
                Rpgc.asInt(Rpgc.get(prototype, "breakMax", fight.breakRules.max)));
            foreach (weak in Rpgc.get(prototype, "weakElements", [])) {
                unit.weakElements.append(Rpgc.asString(weak));
            }
            foreach (style in Rpgc.get(prototype, "weakStyles", [])) {
                unit.weakStyles.append(Rpgc.asString(style));
            }
            foreach (skillId in Rpgc.get(prototype, "skills", [])) {
                local id = Rpgc.asString(skillId);
                if (id != "") unit.skills.append(id);
            }
            unit.basicSkill <- Rpgc.asString(Rpgc.get(prototype, "skillId", ""));
            unit.blueprint <- prototype;
            this.attachResources(unit, rules);
            this.addUnit(fight, unit);
            projected += 1;
        }
    }

    if (Rpgc.errorCount(diagnostics) > 0) return Rpgc.fail(diagnostics);

    this.beginRound(fight);
    if (fight.outcome == "") this.advanceTurn(fight);
    return Rpgc.ok(fight);
}

RpgcBattle.addUnit <- function (fight, unit) {
    fight.units.append(unit);
    fight.byId.rawset(unit.id, unit);
    return unit;
}

RpgcBattle.unitOf <- function (fight, unitId) {
    if (!fight.byId.rawin(unitId)) return 0;
    return fight.byId.rawget(unitId);
}

RpgcBattle.livingUnits <- function (fight, side) {
    local out = [];
    foreach (unit in fight.units) {
        if (!unit.alive) continue;
        if (side != "" && unit.side != side) continue;
        out.append(unit);
    }
    return out;
}

RpgcBattle.currentUnit <- function (fight) {
    if (fight.turnIndex < 0 || fight.turnIndex >= fight.order.len()) return 0;
    return this.unitOf(fight, fight.order[fight.turnIndex]);
}

// ------------------------------------------------------------ turn order
//
// Fastest first, recomputed every round. Ties go to the player's side and then
// to the lower slot index, so a fight with equal speeds is reproducible rather
// than dependent on table iteration order.

RpgcBattle.beginRound <- function (fight) {
    fight.turnIndex <- 0;
    fight.order <- [];
    local living = this.livingUnits(fight, "");
    local sorted = [];
    foreach (unit in living) {
        local key = this.attributeOf(unit, "speed");
        local at = sorted.len();
        while (at > 0) {
            local other = sorted[at - 1];
            local otherKey = this.attributeOf(other, "speed");
            local before = (key > otherKey);
            if (key == otherKey) {
                if (other.side == this.enemySide && unit.side == this.allySide) before = true;
                else if (other.side == unit.side && other.slot > unit.slot) before = true;
            }
            if (!before) break;
            at -= 1;
        }
        sorted.insert(at, unit);
    }
    foreach (unit in sorted) fight.order.append(unit.id);
    return fight.order;
}

RpgcBattle.endTurn <- function (fight, unit) {
    if (unit != 0) unit.turns += 1;
    fight.turnIndex += 1;
    if (fight.turnIndex < fight.order.len()) return;
    this.endRound(fight);
}

RpgcBattle.endRound <- function (fight) {
    fight.round += 1;
    local seconds = fight.turnSeconds;
    foreach (unit in fight.units) {
        if (!unit.alive) continue;
        this.tickEffects(fight, unit, seconds);
        this.regenBreak(fight, unit);
    }
    if (this.checkOutcome(fight) != "") return;
    if (fight.round > this.maxRounds) {
        fight.outcome <- "stalled";
        this.pushLog(fight, "第 " + this.maxRounds + " 回合仍未分胜负，判定为僵局。");
        return;
    }
    this.beginRound(fight);
}

// Break comes back a little every round rather than being spent once
// (docs/06 §3.4 step 4).
RpgcBattle.regenBreak <- function (fight, unit) {
    local regen = fight.breakRules.regenPerRound;
    if (regen <= 0 || unit.breakValue >= unit.breakMax) return;
    unit.breakValue += regen;
    if (unit.breakValue > unit.breakMax) unit.breakValue = unit.breakMax;
}

// ---------------------------------------------------------------- effects

RpgcBattle.applyEffect <- function (fight, unit, effectId) {
    if (effectId == "" || !fight.effects.rawin(effectId)) return 0;
    local def = fight.effects.rawget(effectId);
    local policy = Rpgc.asString(Rpgc.get(def, "durationPolicy", "duration"));
    if (policy == "instant") return 0;
    local duration = Rpgc.asNumber(Rpgc.get(def, "duration", 0));
    if (policy == "infinite") duration = -1.0;

    local existing = 0;
    foreach (inst in unit.effects) {
        if (inst.effectId == effectId) existing = inst;
    }
    local stackPolicy = Rpgc.asString(Rpgc.get(def, "stackPolicy", "refresh"));
    local maxStacks = Rpgc.asInt(Rpgc.get(def, "maxStacks", 1));
    if (maxStacks < 1) maxStacks = 1;

    if (existing == 0) {
        local inst = {};
        inst.effectId <- effectId;
        inst.def <- def;
        inst.remaining <- duration;
        inst.periodClock <- 0.0;
        inst.stacks <- 1;
        unit.effects.append(inst);
        return inst;
    }

    if (stackPolicy == "stack" && existing.stacks < maxStacks) {
        existing.stacks += 1;
        if (duration > existing.remaining) existing.remaining = duration;
    } else if (stackPolicy == "extend") {
        existing.remaining += duration;
    } else if (duration >= 0) {
        existing.remaining = duration;
    }
    return existing;
}

// One round of status time. A periodic effect fires every `period` seconds and
// pays out its `hp` modifiers; every other modifier is a live binding read by
// `attributeOf`. `remaining = -1` is the engine's "infinite"
// (StatusTypes.h:31) and never expires.
RpgcBattle.tickEffects <- function (fight, unit, seconds) {
    local kept = [];
    foreach (inst in unit.effects) {
        local period = Rpgc.asNumber(Rpgc.get(inst.def, "period", 0));
        if (period > 0.0) {
            inst.periodClock += seconds;
            while (inst.periodClock >= period) {
                inst.periodClock -= period;
                foreach (modifier in Rpgc.get(inst.def, "modifiers", [])) {
                    if (Rpgc.asString(Rpgc.get(modifier, "attribute", "")) != "hp") continue;
                    local amount = Rpgc.asNumber(Rpgc.get(modifier, "value", 0)) * inst.stacks;
                    this.changeHp(fight, unit, amount, inst.effectId);
                }
            }
        }
        if (inst.remaining > 0.0) {
            inst.remaining -= seconds;
            if (inst.remaining <= 0.0) {
                this.pushEvent(fight, { kind = "effect-end", target = unit.id,
                                        effect = inst.effectId });
                continue;
            }
        }
        kept.append(inst);
    }
    unit.effects = kept;
}

RpgcBattle.changeHp <- function (fight, unit, amount, source) {
    if (!unit.alive) return 0.0;
    unit.hp += amount;
    if (unit.hp > unit.maxHp) unit.hp = unit.maxHp;
    if (unit.hp > 0.0) {
        this.pushEvent(fight, { kind = amount < 0.0 ? "damage" : "heal",
                                target = unit.id, amount = amount, source = source });
        return amount;
    }
    unit.hp = 0.0;
    unit.alive = false;
    this.pushEvent(fight, { kind = "down", target = unit.id, source = source });
    this.pushLog(fight, unit.displayName + " 倒下了。");
    return amount;
}

// ------------------------------------------------------------------ events

RpgcBattle.pushEvent <- function (fight, event) {
    fight.events.append(event);
    return event;
}

RpgcBattle.pushLog <- function (fight, line) {
    fight.log.append(line);
    return line;
}

RpgcBattle.takeEvents <- function (fight) {
    local out = fight.events;
    fight.events = [];
    return out;
}

// -------------------------------------------------------------- hit maths

RpgcBattle.elementRate <- function (unit, element) {
    if (element == "" || element == "none") return 1.0;
    foreach (weak in unit.weakElements) {
        if (weak == element) return this.weakElementRate;
    }
    return 1.0;
}

RpgcBattle.weakStyleHit <- function (unit, skill) {
    foreach (tag in Rpgc.get(skill, "tags", [])) {
        local name = Rpgc.asString(tag);
        foreach (weak in unit.weakStyles) {
            if (weak == name) return true;
        }
    }
    return false;
}

// `resolveHit`, in order (BattleSystem.cpp:210-251). The two differences are
// named where they happen: the hit roll has no `hit`/`evasion` ex-params because
// a project combatant carries no traits, and `damageTaken` is a project-side
// multiplier fed by the `exposed` effect.
RpgcBattle.resolveHit <- function (fight, attacker, target, skill) {
    local damage = Rpgc.get(skill, "damage", 0);
    local outcome = {};
    outcome.hit <- false;
    outcome.amount <- 0.0;
    outcome.crit <- false;
    outcome.elementRate <- 1.0;
    outcome.element <- "";
    if (typeof damage != "table") return outcome;

    // The document's `hitChance` is 0..1 and the engine's is a percentage
    // (docs/04 §2.4): one hit roll, before the formula and before the crit roll.
    local hitChance = Rpgc.asNumber(Rpgc.get(damage, "hitChance", 1.0)) * 100.0;
    if (this.rollRandom(fight) * 100.0 >= hitChance) return outcome;

    local formula = Rpgc.asString(Rpgc.get(damage, "formula", ""));
    local amount = 0.0;
    if (formula == "") {
        amount = this.attributeOf(attacker, "attack") - this.attributeOf(target, "defense");
    } else {
        local evaluated = this.evaluate(formula, attacker, target);
        if (!evaluated.ok) {
            // An unparseable formula is a content bug the gate already rejects
            // (`skill.bad-formula`). At runtime the hit still lands, for the
            // floor value, rather than silently doing nothing.
            this.pushEvent(fight, { kind = "formula-error", actor = attacker.id,
                                    skill = Rpgc.asString(Rpgc.get(skill, "id", "")),
                                    message = Rpgc.summary(evaluated) });
            amount = 0.0;
        } else {
            amount = evaluated.value;
        }
    }
    if (amount <= 0.0) amount = this.minDamage;

    local element = Rpgc.asString(Rpgc.get(damage, "element", ""));
    outcome.element <- element;
    outcome.elementRate <- this.elementRate(target, element);
    amount *= outcome.elementRate;

    local critChance = Rpgc.asNumber(Rpgc.get(damage, "critChance", 0));
    if (critChance > 0.0 && this.rollRandom(fight) < critChance) {
        outcome.crit = true;
        amount *= this.critMultiplier;
    }

    amount *= this.damageTakenRate(target);
    if (target.guarding) amount *= this.guardMultiplier;

    outcome.hit <- true;
    outcome.amount <- amount;
    return outcome;
}

// `damageTaken` is not an engine attribute; it is the channel the `exposed`
// effect uses to say "everything hurts more while broken"
// (content/effects/exposed.json).
RpgcBattle.damageTakenRate <- function (unit) {
    local rate = 1.0;
    foreach (inst in unit.effects) {
        if (this.effectIsPeriodic(inst)) continue;
        foreach (modifier in Rpgc.get(inst.def, "modifiers", [])) {
            if (Rpgc.asString(Rpgc.get(modifier, "attribute", "")) != "damageTaken") continue;
            local op = Rpgc.asString(Rpgc.get(modifier, "op", "add"));
            local value = Rpgc.asNumber(Rpgc.get(modifier, "value", 0));
            if (op == "add") rate += value;
            else if (op == "multiply") rate *= value;
            else if (op == "additive_percent" || op == "mulAdd") rate *= (1.0 + value);
            else if (op == "multiplicative_percent" || op == "mulMul") rate *= (1.0 + value);
        }
    }
    return rate;
}

// ------------------------------------------------------------------ break

// The break chain of docs/06 §3.5: overcome and both weaknesses feed one gauge,
// and the gauge reaching zero is what applies `rules.breakEffects`. Resisted
// damage does NOT multiply the hit: `elementRate` is the engine's only
// settlement multiplier (docs/06 §3.2), so 相克 stays out of the damage formula
// and shows up here instead.
RpgcBattle.applyBreak <- function (fight, attacker, target, skill) {
    local gain = 0;
    if (this.overcomes(fight.rules, attacker.element, target.element)) {
        gain += fight.breakRules.onOvercome;
    }
    local element = Rpgc.asString(Rpgc.get(Rpgc.get(skill, "damage", {}), "element", ""));
    if (element != "" && this.elementRate(target, element) > 1.0) {
        gain += fight.breakRules.onWeakElement;
    }
    if (this.weakStyleHit(target, skill)) {
        gain += fight.breakRules.onWeakStyle;
    }
    if (gain <= 0 || !target.alive) return 0;

    target.breakValue -= gain;
    this.pushEvent(fight, { kind = "break", target = target.id, amount = gain,
                            remaining = target.breakValue < 0 ? 0 : target.breakValue });
    if (target.breakValue > 0) return gain;

    target.breakValue <- target.breakMax;
    target.broken <- true;
    this.pushEvent(fight, { kind = "broken", target = target.id });
    this.pushLog(fight, target.displayName + " 破绽被击穿。");
    foreach (entry in Rpgc.get(fight.rules, "breakEffects", [])) {
        local effectId = Rpgc.asString(Rpgc.get(entry, "effect", ""));
        local inst = this.applyEffect(fight, target, effectId);
        if (inst != 0) {
            // `rules.breakEffects[].turns` is in TURNS and the effect document's
            // `duration` is in SECONDS; `RpgcSystems` already refuses a document
            // where the two disagree, so the fight reads the duration and only
            // uses the turn count to say how long that is.
            this.pushEvent(fight, { kind = "status", target = target.id,
                                    effect = effectId, turns = Rpgc.asInt(Rpgc.get(entry, "turns", 1)) });
        }
    }
    return gain;
}

// ------------------------------------------------------------- commands

RpgcBattle.costsOf <- function (skill) {
    return Rpgc.get(skill, "costs", []);
}

RpgcBattle.canAfford <- function (unit, skill) {
    foreach (cost in this.costsOf(skill)) {
        local attribute = Rpgc.asString(Rpgc.get(cost, "attribute", ""));
        local amount = Rpgc.asNumber(Rpgc.get(cost, "amount", 0));
        if (attribute == "" || amount <= 0.0) continue;
        if (!unit.resources.rawin(attribute)) continue;
        if (unit.resources.rawget(attribute) < amount) return false;
    }
    return true;
}

RpgcBattle.payCosts <- function (unit, skill) {
    foreach (cost in this.costsOf(skill)) {
        local attribute = Rpgc.asString(Rpgc.get(cost, "attribute", ""));
        local amount = Rpgc.asNumber(Rpgc.get(cost, "amount", 0));
        if (attribute == "" || amount <= 0.0) continue;
        if (!unit.resources.rawin(attribute)) continue;
        local left = unit.resources.rawget(attribute) - amount;
        unit.resources.rawset(attribute, left < 0.0 ? 0.0 : left);
    }
}

// `cooldown` is in seconds like the engine's; a round is `turnSeconds` of it.
RpgcBattle.cooldownRounds <- function (fight, skill) {
    local seconds = Rpgc.asNumber(Rpgc.get(skill, "cooldown", 0));
    if (seconds <= 0.0) return 0;
    local rounds = (seconds / fight.turnSeconds).tointeger();
    if (rounds * fight.turnSeconds < seconds) rounds += 1;
    return rounds < 1 ? 1 : rounds;
}

RpgcBattle.skillReady <- function (fight, unit, skillId) {
    if (!unit.cooldowns.rawin(skillId)) return true;
    return unit.cooldowns.rawget(skillId) <= fight.round;
}

RpgcBattle.refreshCooldown <- function (fight, unit, skillId, skill) {
    local rounds = this.cooldownRounds(fight, skill);
    if (rounds <= 0) return;
    unit.cooldowns.rawset(skillId, fight.round + rounds);
}

// What the leader may order right now. `targetType` decides whether the caller
// must pick somebody: `self` needs no target, the two `All` kinds hit a whole
// side (AOE is project-side by design, docs/06 §3.5 step 1).
RpgcBattle.commandsFor <- function (fight, unit) {
    local out = [];
    foreach (skillId in unit.skills) {
        local skill = fight.skills.rawin(skillId) ? fight.skills.rawget(skillId) : 0;
        if (skill == 0) continue;
        local entry = {};
        entry.id <- skillId;
        entry.label <- Rpgc.asString(Rpgc.get(skill, "title", skillId));
        entry.targetType <- Rpgc.asString(Rpgc.get(skill, "targetType", "enemySingle"));
        entry.ready <- this.skillReady(fight, unit, skillId);
        entry.affordable <- this.canAfford(unit, skill);
        entry.damaging <- typeof Rpgc.get(skill, "damage", 0) == "table";
        out.append(entry);
    }
    local guard = {};
    guard.id <- "command.defend";
    guard.label <- "防御";
    guard.targetType <- "self";
    guard.ready <- true;
    guard.affordable <- true;
    guard.damaging <- false;
    out.append(guard);
    return out;
}

RpgcBattle.targetsFor <- function (fight, unit, targetType) {
    if (targetType == "self") return [unit];
    if (targetType == "allySingle" || targetType == "allyAll") {
        return this.livingUnits(fight, unit.side);
    }
    if (targetType == "anySingle" || targetType == "anyAll") return this.livingUnits(fight, "");
    return this.livingUnits(fight, unit.side == this.allySide ? this.enemySide : this.allySide);
}

// ------------------------------------------------------------------ acting

RpgcBattle.submitCommand <- function (fight, command) {
    if (fight.outcome != "") {
        return Rpgc.fail([Rpgc.error("battle.over",
            "the fight is already decided (" + fight.outcome + ")", "$", "")]);
    }
    local unit = this.currentUnit(fight);
    if (unit == 0 || unit.side != this.allySide || fight.pending != unit.id) {
        return Rpgc.fail([Rpgc.error("battle.not-your-turn",
            "no ally is waiting for a command", "$", "")]);
    }
    local skillId = Rpgc.asString(Rpgc.get(command, "skill", ""));
    if (skillId == "" || skillId == "command.defend") {
        unit.guarding = true;
        this.pushLog(fight, unit.displayName + " 摆出守势。");
        this.pushEvent(fight, { kind = "guard", actor = unit.id });
    } else {
        local targetId = Rpgc.asString(Rpgc.get(command, "target", ""));
        this.performSkill(fight, unit, skillId, targetId);
    }
    this.endTurn(fight, unit);
    this.checkOutcome(fight);
    if (fight.outcome == "") this.advanceTurn(fight);
    return Rpgc.ok(fight);
}

// Resolve one action. Everything that can refuse it (unknown skill, cooldown,
// cost, dead target) refuses by NOT spending anything -- a refused order leaves
// the fight exactly as it was, so the caller can ask again.
RpgcBattle.performSkill <- function (fight, actor, skillId, targetId) {
    if (!fight.skills.rawin(skillId)) {
        this.pushLog(fight, actor.displayName + " 想用的招式不存在：" + skillId);
        return false;
    }
    local skill = fight.skills.rawget(skillId);
    if (!this.skillReady(fight, actor, skillId)) {
        this.pushLog(fight, actor.displayName + " 的「" + Rpgc.asString(Rpgc.get(skill, "title", skillId)) + "」还在冷却。");
        return false;
    }
    if (!this.canAfford(actor, skill)) {
        this.pushLog(fight, actor.displayName + " 的气力不足以施展「" + Rpgc.asString(Rpgc.get(skill, "title", skillId)) + "」。");
        return false;
    }
    local targetType = Rpgc.asString(Rpgc.get(skill, "targetType", "enemySingle"));
    local targets = [];
    if (targetType == "self") {
        targets.append(actor);
    } else if (targetType == "allyAll" || targetType == "anyAll" || targetType == "enemyAll") {
        targets = this.targetsFor(fight, actor, targetType);
    } else {
        local target = this.unitOf(fight, targetId);
        if (target == 0 || !target.alive) {
            this.pushLog(fight, "目标不存在或已倒下。");
            return false;
        }
        local legal = (targetType == "allySingle")
            ? (target.side == actor.side)
            : (target.side != actor.side);
        if (!legal) {
            this.pushLog(fight, "目标不在这个招式的范围内。");
            return false;
        }
        targets.append(target);
    }
    if (targets.len() == 0) return false;

    this.payCosts(actor, skill);
    this.refreshCooldown(fight, actor, skillId, skill);
    actor.guarding = false;

    local title = Rpgc.asString(Rpgc.get(skill, "title", skillId));
    this.pushLog(fight, actor.displayName + " 施放「" + title + "」。");
    this.pushEvent(fight, { kind = "cast", actor = actor.id, skill = skillId,
                            targets = targets.len() });

    local damaging = typeof Rpgc.get(skill, "damage", 0) == "table";
    foreach (target in targets) {
        if (damaging && target.side != actor.side) {
            local outcome = this.resolveHit(fight, actor, target, skill);
            if (!outcome.hit) {
                this.pushLog(fight, "  ——未命中 " + target.displayName + "。");
                this.pushEvent(fight, { kind = "miss", actor = actor.id,
                                        target = target.id, skill = skillId });
            } else {
                this.pushEvent(fight, { kind = "hit", actor = actor.id, target = target.id,
                                        skill = skillId, amount = outcome.amount,
                                        crit = outcome.crit, element = outcome.element,
                                        elementRate = outcome.elementRate });
                this.pushLog(fight, "  ——" + target.displayName + " 受到 "
                    + outcome.amount.tointeger() + " 点伤害"
                    + (outcome.crit ? "（会心）" : "") + "。");
                this.changeHp(fight, target, -outcome.amount, skillId);
                this.applyBreak(fight, actor, target, skill);
            }
        }
        foreach (effectId in Rpgc.get(skill, "effects", [])) {
            local id = Rpgc.asString(effectId);
            local inst = this.applyEffect(fight, target, id);
            if (inst != 0) {
                this.pushEvent(fight, { kind = "status", target = target.id, effect = id });
            }
        }
    }
    return true;
}

// ------------------------------------------------------------------ items
//
// A consumable is deliberately NOT a skill. `ItemDefinition` carries no effect
// list at all (inventory/ItemTypes.h:13-27) — `use` is the project's half — so
// an item order carries its own effects instead of naming a skill document, and
// this resolver never reads an item definition. `RpgcItems.battleCommands`
// builds the entries; this only spends the turn.
//
// Everything that can refuse the order refuses by NOT spending anything, the
// same contract as `performSkill`: an illegal target leaves the fight exactly
// as it was so the caller can ask again. The item is consumed by the CALLER,
// after this returns ok — a bag mutation inside the resolver would make a
// refused order cost a potion.

RpgcBattle.submitItemCommand <- function (fight, order) {
    if (fight.outcome != "") {
        return Rpgc.fail([Rpgc.error("battle.over",
            "the fight is already decided (" + fight.outcome + ")", "$", "")]);
    }
    local unit = this.currentUnit(fight);
    if (unit == 0 || unit.side != this.allySide || fight.pending != unit.id) {
        return Rpgc.fail([Rpgc.error("battle.not-your-turn",
            "no ally is waiting for a command", "$", "")]);
    }
    local effects = Rpgc.get(order, "effects", []);
    if (effects.len() == 0) {
        return Rpgc.fail([Rpgc.error("battle.item-no-effect",
            "an item order needs at least one effect", "$",
            "`use.effects` is what makes a consumable do something")]);
    }

    local targetType = Rpgc.asString(Rpgc.get(order, "targetType", "self"));
    local targets = [];
    if (targetType == "self") {
        targets.append(unit);
    } else if (targetType == "allyAll" || targetType == "anyAll" || targetType == "enemyAll") {
        targets = this.targetsFor(fight, unit, targetType);
    } else {
        local target = this.unitOf(fight, Rpgc.asString(Rpgc.get(order, "target", "")));
        if (target == 0 || !target.alive) {
            return Rpgc.fail([Rpgc.error("battle.item-no-target",
                "the order names no living target", "$", "")]);
        }
        local legal = (targetType == "allySingle")
            ? (target.side == unit.side)
            : (target.side != unit.side);
        if (!legal) {
            return Rpgc.fail([Rpgc.error("battle.item-bad-target",
                "the target is outside this item's range", "$", "")]);
        }
        targets.append(target);
    }
    if (targets.len() == 0) {
        return Rpgc.fail([Rpgc.error("battle.item-no-target",
            "the order resolves to nobody", "$", "")]);
    }

    local itemId = Rpgc.asString(Rpgc.get(order, "itemId", ""));
    local label = Rpgc.asString(Rpgc.get(order, "label", itemId));
    unit.guarding = false;
    this.pushLog(fight, unit.displayName + " 使用了「" + label + "」。");
    this.pushEvent(fight, { kind = "item", actor = unit.id, item = itemId,
                            targets = targets.len() });

    foreach (target in targets) {
        foreach (value in effects) {
            local effectId = Rpgc.asString(value);
            if (effectId == "") continue;
            local inst = this.applyEffect(fight, target, effectId);
            if (inst != 0) {
                this.pushEvent(fight, { kind = "status", target = target.id,
                                        effect = effectId, source = itemId });
            }
        }
    }

    this.endTurn(fight, unit);
    this.checkOutcome(fight);
    if (fight.outcome == "") this.advanceTurn(fight);
    return Rpgc.ok(fight);
}

// -------------------------------------------------------------- the machine

// Run until an ally is waiting for an order, the fight is over, or the round
// cap is hit. Enemies act inside this loop; the caller only ever sees a stable
// state with `fight.pending` set or an outcome.
RpgcBattle.advanceTurn <- function (fight) {
    local guard = 0;
    while (fight.outcome == "" && guard < 8192) {
        guard += 1;
        this.checkOutcome(fight);
        if (fight.outcome != "") break;
        if (fight.turnIndex >= fight.order.len()) {
            this.endRound(fight);
            if (fight.outcome != "") break;
            continue;
        }
        local unit = this.currentUnit(fight);
        if (unit == 0 || !unit.alive) {
            fight.turnIndex += 1;
            continue;
        }
        if (this.hasEffectTag(unit, "stun")) {
            this.pushLog(fight, unit.displayName + " 仍在击破眩晕中，本回合跳过。");
            this.pushEvent(fight, { kind = "skip", actor = unit.id, reason = "stun" });
            this.endTurn(fight, unit);
            continue;
        }
        if (unit.side == this.allySide) {
            fight.pending <- unit.id;
            return fight;
        }
        fight.pending <- "";
        this.enemyTurn(fight, unit);
        if (unit.alive) this.endTurn(fight, unit);
        else fight.turnIndex += 1;
    }
    if (fight.outcome == "") {
        fight.outcome <- "stalled";
        this.pushLog(fight, "战斗未能推进，判定为僵局。");
    }
    fight.pending <- "";
    return fight;
}

// The enemy's decision, from its own document and nothing else:
// `ai.opener` on the first turn, then `ai.aggression` for "a real move rather
// than its basic one", and `ai.fleeBelowHp` for a chance to leave. The doc's
// `skills[]` is the rotation and `skillId` the fallback, so a turn can always
// end in a basic attack or a guard.
RpgcBattle.enemyTurn <- function (fight, unit) {
    local prototype = unit.blueprint;
    local ai = Rpgc.get(prototype, "ai", 0);
    local aggression = 0.5;
    local fleeBelow = 0.0;
    local opener = "";
    if (typeof ai == "table") {
        aggression = Rpgc.asNumber(Rpgc.get(ai, "aggression", 0.5));
        fleeBelow = Rpgc.asNumber(Rpgc.get(ai, "fleeBelowHp", 0.0));
        opener = Rpgc.asString(Rpgc.get(ai, "opener", ""));
    }

    if (fleeBelow > 0.0 && unit.maxHp > 0.0) {
        local fraction = unit.hp / unit.maxHp;
        if (fraction < fleeBelow && this.rollRandom(fight) < this.fleeChance) {
            unit.alive = false;
            unit.fled = true;
            this.pushLog(fight, unit.displayName + " 逃走了。");
            this.pushEvent(fight, { kind = "flee", actor = unit.id });
            return;
        }
    }

    local choice = "";
    if (unit.turns == 0 && opener != "" && this.skillUsable(fight, unit, opener)) {
        choice = opener;
    } else if (this.rollRandom(fight) < aggression) {
        local candidates = [];
        foreach (skillId in unit.skills) {
            if (!this.skillUsable(fight, unit, skillId)) continue;
            local skill = fight.skills.rawget(skillId);
            if (typeof Rpgc.get(skill, "damage", 0) != "table") continue;
            candidates.append(skillId);
        }
        if (candidates.len() > 0) choice = candidates[this.rollInt(fight, 0, candidates.len() - 1)];
    }
    if (choice == "" && this.skillUsable(fight, unit, unit.basicSkill)) choice = unit.basicSkill;

    if (choice == "") {
        unit.guarding = true;
        this.pushLog(fight, unit.displayName + " 无招可用，原地戒备。");
        this.pushEvent(fight, { kind = "guard", actor = unit.id });
        return;
    }
    this.performSkill(fight, unit, choice, this.pickTarget(fight, unit));
}

RpgcBattle.skillUsable <- function (fight, unit, skillId) {
    if (skillId == "" || !fight.skills.rawin(skillId)) return false;
    local skill = fight.skills.rawget(skillId);
    if (!this.skillReady(fight, unit, skillId)) return false;
    return this.canAfford(unit, skill);
}

// The opponent with the least HP left, ties to the lowest slot: a deterministic
// focus-fire policy that does not need a second random stream to be testable.
RpgcBattle.pickTarget <- function (fight, unit) {
    local side = unit.side == this.allySide ? this.enemySide : this.allySide;
    local best = 0;
    local bestFraction = 2.0;
    foreach (candidate in this.livingUnits(fight, side)) {
        local fraction = candidate.maxHp > 0.0 ? candidate.hp / candidate.maxHp : 1.0;
        if (fraction < bestFraction || (fraction == bestFraction && best != 0 && candidate.slot < best.slot)) {
            best = candidate;
            bestFraction = fraction;
        }
    }
    return best == 0 ? "" : best.id;
}

RpgcBattle.checkOutcome <- function (fight) {
    if (fight.outcome != "") return fight.outcome;
    if (this.livingUnits(fight, this.enemySide).len() == 0) {
        fight.outcome <- "victory";
        this.pushLog(fight, "敌人已被肃清。");
        this.pushEvent(fight, { kind = "outcome", outcome = "victory" });
    } else if (this.livingUnits(fight, this.allySide).len() == 0) {
        fight.outcome <- "defeat";
        this.pushLog(fight, "我方全灭。");
        this.pushEvent(fight, { kind = "outcome", outcome = "defeat" });
    }
    // A decided fight has nobody waiting for an order: leaving `pending` set
    // would let a caller submit one more command against a corpse.
    if (fight.outcome != "") fight.pending <- "";
    return fight.outcome;
}

// ------------------------------------------------------------ auto pilot
//
// Headless resolution, used by the checks and by the game's "finish this fight
// for me" path. The policy is the enemy's: cheapest usable damaging move on the
// opposing unit with the least HP.

RpgcBattle.autoCommand <- function (fight, unit) {
    local best = "";
    local bestCost = 1.0e308;
    foreach (skillId in unit.skills) {
        if (!this.skillUsable(fight, unit, skillId)) continue;
        local skill = fight.skills.rawget(skillId);
        if (typeof Rpgc.get(skill, "damage", 0) != "table") continue;
        if (Rpgc.asString(Rpgc.get(skill, "targetType", "")) == "allySingle") continue;
        local cost = 0.0;
        foreach (entry in this.costsOf(skill)) {
            cost += Rpgc.asNumber(Rpgc.get(entry, "amount", 0));
        }
        if (cost < bestCost) {
            best = skillId;
            bestCost = cost;
        }
    }
    local command = {};
    command.skill <- best;
    command.target <- this.pickTarget(fight, unit);
    return command;
}

RpgcBattle.runToEnd <- function (fight, maxOrders) {
    local budget = maxOrders == null ? 512 : maxOrders;
    local orders = 0;
    while (fight.outcome == "" && orders < budget) {
        if (fight.pending == "") {
            this.advanceTurn(fight);
            if (fight.pending == "") break;
        }
        local unit = this.unitOf(fight, fight.pending);
        if (unit == 0) break;
        this.submitCommand(fight, this.autoCommand(fight, unit));
        orders += 1;
    }
    if (fight.outcome == "" && orders >= budget) fight.outcome <- "stalled";
    return fight;
}

// ------------------------------------------------------------- settlement

// What the caller applies to the world once `outcome == "victory"`. Drops are
// rolled per DEFEATED enemy; one that fled is not looted, which is the reason
// the two are separate flags on the unit.
RpgcBattle.settlement <- function (fight) {
    local encounter = fight.encounter;
    local out = {};
    out.outcome <- fight.outcome;
    out.rounds <- fight.round;
    out.xp <- 0;
    out.gold <- 0;
    out.loot <- [];
    out.quest <- Rpgc.get(encounter, "quest", 0);
    if (fight.outcome != "victory") return out;

    out.xp <- Rpgc.asInt(Rpgc.get(encounter, "xpReward", 0));
    out.gold <- Rpgc.asInt(Rpgc.get(encounter, "goldReward", 0));

    local looted = {};
    foreach (unit in fight.units) {
        if (unit.side != this.enemySide || unit.fled) continue;
        local prototype = unit.blueprint;
        foreach (drop in Rpgc.get(prototype, "drops", [])) {
            local itemId = Rpgc.asString(Rpgc.get(drop, "itemId", ""));
            if (itemId == "") continue;
            local chance = Rpgc.asNumber(Rpgc.get(drop, "chance", 0));
            if (this.rollRandom(fight) >= chance) continue;
            local count = this.rollInt(fight,
                Rpgc.asInt(Rpgc.get(drop, "min", 1)), Rpgc.asInt(Rpgc.get(drop, "max", 1)));
            if (looted.rawin(itemId)) looted.rawset(itemId, looted.rawget(itemId) + count);
            else looted.rawset(itemId, count);
        }
    }
    foreach (itemId, count in looted) {
        local entry = {};
        entry.itemId <- itemId;
        entry.count <- count;
        out.loot.append(entry);
    }
    return out;
}

// --------------------------------------------------------------- the scene

// Slot index -> screen position, in the scene's own design space. This is the
// whole of the layout projection (docs/10 §5): the k-th unit of a side stands on
// the k-th slot of that side, and nothing else in the fight knows where anything
// is drawn.
RpgcBattle.placeOnScene <- function (fight) {
    local battle = fight.battle;
    local out = [];
    foreach (unit in fight.units) {
        local slots = Rpgc.get(battle, unit.side == this.allySide ? "allySlots" : "enemySlots", []);
        if (unit.slot >= slots.len()) continue;
        local slot = slots[unit.slot];
        local entry = {};
        entry.unit <- unit.id;
        entry.slotId <- Rpgc.asString(Rpgc.get(slot, "id", ""));
        entry.x <- Rpgc.asNumber(Rpgc.get(slot, "x", 0));
        entry.y <- Rpgc.asNumber(Rpgc.get(slot, "y", 0));
        entry.side <- unit.side;
        out.append(entry);
    }
    return out;
}

// Letterbox fit of the design canvas into a viewport, the same rule the battle
// editor uses to draw its preview.
RpgcBattle.fitToViewport <- function (battle, viewWidth, viewHeight) {
    local canvasWidth = Rpgc.asNumber(Rpgc.get(battle, "canvas.width", 0));
    local canvasHeight = Rpgc.asNumber(Rpgc.get(battle, "canvas.height", 0));
    local out = {};
    out.scale <- 1.0;
    out.offsetX <- 0.0;
    out.offsetY <- 0.0;
    out.canvasWidth <- canvasWidth;
    out.canvasHeight <- canvasHeight;
    if (canvasWidth <= 0.0 || canvasHeight <= 0.0 || viewWidth <= 0.0 || viewHeight <= 0.0) return out;
    local scaleX = viewWidth / canvasWidth;
    local scaleY = viewHeight / canvasHeight;
    out.scale = scaleX < scaleY ? scaleX : scaleY;
    out.offsetX = (viewWidth - canvasWidth * out.scale) * 0.5;
    out.offsetY = (viewHeight - canvasHeight * out.scale) * 0.5;
    return out;
}

RpgcBattle.toScreenX <- function (fit, x) { return fit.offsetX + x * fit.scale; }
RpgcBattle.toScreenY <- function (fit, y) { return fit.offsetY + y * fit.scale; }

// ------------------------------------------------------------------ reports

RpgcBattle.statusLine <- function (fight) {
    local line = "round " + fight.round + " / " + (fight.outcome == "" ? "active" : fight.outcome);
    local parts = [];
    foreach (unit in fight.units) {
        if (unit.side != this.allySide) continue;
        parts.append(unit.displayName + " " + unit.hp.tointeger() + "/"
            + unit.maxHp.tointeger() + " 破绽 " + unit.breakValue + "/" + unit.breakMax);
    }
    foreach (unit in fight.units) {
        if (unit.side != this.enemySide) continue;
        parts.append(unit.displayName + " " + unit.hp.tointeger() + "/"
            + unit.maxHp.tointeger()
            + (unit.alive ? "" : (unit.fled ? "(逃)" : "(倒)")));
    }
    return line + " | " + Rpgc.joinList(parts, " | ");
}

RpgcBattle.reportJson <- function (fight) {
    local out = {};
    out.round <- fight.round;
    out.outcome <- fight.outcome;
    out.pending <- fight.pending;
    out.bench <- fight.bench;
    out.units <- [];
    foreach (unit in fight.units) {
        local entry = {};
        entry.id <- unit.id;
        entry.side <- unit.side;
        entry.slot <- unit.slot;
        entry.hp <- unit.hp;
        entry.maxHp <- unit.maxHp;
        entry.breakValue <- unit.breakValue;
        entry.breakMax <- unit.breakMax;
        entry.alive <- unit.alive;
        entry.fled <- unit.fled;
        entry.status <- [];
        foreach (inst in unit.effects) entry.status.append(inst.effectId);
        out.units.append(entry);
    }
    out.log <- fight.log;
    return RpgcJson.encodeCompact(out);
}

// -------------------------------------------------------- project loading

// Read the five documents a fight between `partyId` and `encounterId` needs,
// plus the scene that hosts that encounter. The scene is FOUND, not passed:
// `eve.rpgc.battle` says which encounters it hosts, so asking the encounter
// which scene it belongs to is the direction the reference already points
// (docs/10 §5).
RpgcBattle.sceneForEncounter <- function (encounterId) {
    local battleId = RpgcProject.idsOf("battle");
    foreach (id in battleId) {
        local read = RpgcProject.loadById("battle", id);
        if (!read.ok) continue;
        foreach (hosted in Rpgc.get(read.value, "encounters", [])) {
            if (Rpgc.asString(hosted) == encounterId) return Rpgc.ok(read.value);
        }
    }
    return Rpgc.fail([Rpgc.error("battle.no-scene",
        "no battle document hosts encounter '" + encounterId + "'", "$",
        "add it to a battle's encounters[]")]);
}

// `RpgcSystems.maxBattleAllySlots` is the cap; the roster is already gated
// against it, so loading one that overshoots means the gate was bypassed.
RpgcBattle.loadProject <- function (partyId, encounterId, battleId) {
    local diagnostics = [];
    local rulesRead = RpgcProject.loadKind("rules");
    local rules = rulesRead.value.len() > 0 ? rulesRead.value[0] : 0;
    if (typeof rules != "table") {
        diagnostics.append(Rpgc.error("battle.no-rules",
            "no rules document is loaded, so no fight can be resolved", "$", ""));
    }

    local encounter = this._document("encounter", encounterId, diagnostics);
    local party = this._document("party", partyId, diagnostics);
    local battle = 0;
    if (battleId == null || battleId == "") {
        local scene = this.sceneForEncounter(encounterId);
        if (scene.ok) battle = scene.value;
        else foreach (d in scene.diagnostics) diagnostics.append(d);
    } else {
        battle = this._document("battle", battleId, diagnostics);
    }

    // Only the documents the fight can reach are loaded: every skill any unit
    // could use, every effect any of those skills applies, and every art the
    // roster names.
    local config = {};
    config.rules <- rules;
    config.encounter <- encounter;
    config.party <- party;
    config.battle <- battle;
    config.enemies <- this._indexAsTable("enemy");
    config.skills <- this._indexAsTable("skill");
    config.effects <- this._indexAsTable("effect");
    config.arts <- this._indexAsTable("art");
    if (Rpgc.errorCount(diagnostics) > 0) return Rpgc.fail(diagnostics);
    return Rpgc.ok(config);
}

RpgcBattle._document <- function (kind, id, diagnostics) {
    if (id == null || id == "") {
        diagnostics.append(Rpgc.error("battle.no-" + kind,
            "a fight needs a " + kind + " id", "$", ""));
        return 0;
    }
    local read = RpgcProject.loadById(kind, id);
    if (!read.ok) {
        foreach (d in read.diagnostics) diagnostics.append(d);
        return 0;
    }
    return read.value;
}

RpgcBattle._indexAsTable <- function (kind) {
    local out = {};
    local loaded = RpgcProject.loadKind(kind);
    foreach (document in loaded.value) {
        local id = Rpgc.asString(Rpgc.get(document, "id", ""));
        if (id != "") out.rawset(id, document);
    }
    return out;
}
