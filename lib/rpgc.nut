// EVEngine workflow / rpg-classic — toolchain composition root.
//
// Every file in this directory is an EveScript module with an explicit
// `import` list, so a consumer takes exactly what it uses:
//
//   import { RpgcJson } from "game:/lib/rpgc_json.nut"
//   import { Rpgc, RpgcStore } from "game:/lib/rpgc_core.nut"
//
// This module is for a caller that wants the whole toolchain present (and a
// version to report); importing it instantiates every module through the
// module system's dependency graph.
//
// There is deliberately no `load()` / `reload()` and no file list here. The
// old entry point read the eleven files with `dofile` in a hand-maintained
// order and then dropped them by name in a second hand-maintained list, so a
// stale entry silently kept a cached table alive across a library edit.
// `import` replaces both: a module is instantiated once per Runtime generation,
// and the dependency graph invalidates exactly the modules a changed file
// affects.
//
// Each module is a class-object singleton. EveScript can only `export` a
// top-level `function`, `class`, or scalar `const`, so a module that owns state
// (as every one of these does) exports a class and hangs its members off it;
// callers use `RpgcJson.parse(...)` and never construct the class.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcIso } from "./rpgc_iso.nut"
import { RpgcStore } from "./rpgc_store.nut"
import { RpgcProject } from "./rpgc_project.nut"
import { RpgcHost } from "./rpgc_host.nut"
import { RpgcTilemap } from "./rpgc_tilemap.nut"
import { RpgcSkill } from "./rpgc_skill.nut"
import { RpgcEvent } from "./rpgc_event.nut"
import { RpgcSystems } from "./rpgc_systems.nut"
import { RpgcBattle } from "./rpgc_battle.nut"
import { RpgcItems } from "./rpgc_items.nut"
import { RpgcValidate } from "./rpgc_validate.nut"
import { RpgcApp } from "./rpgc_app.nut"

export class RpgcWorkflow {
}

// The on-disk document contract this toolchain implements. Bump it when a
// stored document shape changes; a module edit alone does not move it.
// v3 adds the five open-world/combat kinds (rules, world, art, heart, combo)
// and the skill fields they are checked against.
// v4 adds `item` / `enemy` / `encounter` and, with them, the first projection
// artifact (`data/encounters.engine.json`).
// v5 adds `battle`: the on-screen layout of a fight. It is the only kind whose
// content is screen-space geometry rather than world-space data, and the only
// one with no engine type to project onto.
// v6 adds `party` and `RpgcBattle`: the player-side roster plus the resolver that
// turns five documents into a fight. The resolver is a PROJECT-SIDE restatement
// of the engine's arithmetic, because this build binds no `rpg` module at all
// (see lib/rpgc_battle.nut's header and tools/modules_check.nut).
// v7 adds `RpgcItems` and `party.startingItems`: the bag the item documents
// describe. `inventory` is unbound in this build for the same reason `rpg` is
// (`SCRIPT Inventory` with no `SLOT`), so the bag is a project-side restatement
// too -- see lib/rpgc_items.nut's header.
RpgcWorkflow.version <- 7

// The instantiated toolchain. Every importer of a given module gets the same
// object, so this is an inventory rather than a second set of instances.
RpgcWorkflow.modules <- [Rpgc, RpgcJson, RpgcIso, RpgcStore, RpgcProject,
                         RpgcHost, RpgcTilemap, RpgcSkill, RpgcEvent,
                         RpgcSystems, RpgcBattle, RpgcItems, RpgcValidate, RpgcApp]

RpgcWorkflow.moduleCount <- function () {
    return this.modules.len();
};
