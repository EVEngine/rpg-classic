#!/usr/bin/env python3
"""Project the rpg-classic bestiary into the engine's encounter array.

`eve.rpg.EncounterCatalogue.replaceFromJsonStrict` does not take documents: it
takes one JSON **array**, with each enemy's stats written inline in the member
list. The workflow keeps the opposite shape on purpose -- one enemy archetype
per file, so `attack`/`maxHp`/`skillId` have exactly one owner -- and this tool
is the join between the two.

It writes ``data/encounters.engine.json``, a bare array with no wrapper object,
because that is literally what the engine parses. The file is a **derived
artifact**: edit ``content/enemies/`` and ``content/encounters/``, never this.

Usage::

    python tools/build_encounters.py            # regenerate
    python tools/build_encounters.py --check    # fail when the file is stale

``--check`` is what CI (and a reviewer) should run: it re-derives the array and
compares it byte for byte with the committed artifact, so a hand-edited or
forgotten projection is a build failure rather than a silent divergence.

Two engine constraints this tool is careful about, both enforced upstream by
`RpgcSystems.encounterDiagnostics` and re-asserted here so this tool is safe to
run on its own:

* member ids must be unique within an encounter -- they are derived from the
  enemy stem plus a running index, and a repeated enemy id is refused;
* the array must be non-empty, because the loader rejects an empty one.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENEMY_DIR = ROOT / "content" / "enemies"
ENCOUNTER_DIR = ROOT / "content" / "encounters"
OUTPUT = ROOT / "data" / "encounters.engine.json"


def stem_of(document_id: str) -> str:
    """`enemy.market-thug` -> `market-thug`.

    The engine caps a member id at 256 bytes and rejects control characters;
    the stem is what keeps the projected ids readable in a log line.
    """
    _, _, tail = document_id.partition(".")
    return tail or document_id


def load(directory: Path) -> list:
    documents = []
    for path in sorted(directory.glob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        if document.get("id") != path.stem:
            raise SystemExit("refusing to project: %s declares id %r but is named %r"
                             % (path, document.get("id"), path.stem))
        documents.append(document)
    return documents


def project(enemies: list, encounters: list) -> list:
    if not enemies:
        raise SystemExit("no enemy documents under %s" % ENEMY_DIR)
    if not encounters:
        raise SystemExit("no encounter documents under %s" % ENCOUNTER_DIR)

    by_id = {document["id"]: document for document in enemies}
    if len(by_id) != len(enemies):
        raise SystemExit("two enemy documents share an id")

    out = []
    for encounter in encounters:
        members = []
        used = set()
        for entry in encounter["members"]:
            enemy_id = entry["enemy"]
            if enemy_id not in by_id:
                raise SystemExit("%s references unknown enemy %s"
                                 % (encounter["id"], enemy_id))
            if enemy_id in used:
                raise SystemExit("%s lists enemy %s twice; raise `count` instead"
                                 % (encounter["id"], enemy_id))
            used.add(enemy_id)
            enemy = by_id[enemy_id]
            combat = enemy["combat"]
            for index in range(int(entry.get("count", 1))):
                members.append({
                    # The engine only needs uniqueness inside one encounter, and
                    # the stem makes a failure report name the creature.
                    "id": "%s.%d" % (stem_of(enemy_id), index),
                    "displayName": enemy["displayName"],
                    "skillId": enemy["skillId"],
                    "attack": combat["attack"],
                    "defense": combat["defense"],
                    "maxHp": combat["maxHp"],
                    "speed": combat["speed"],
                })
        if len(members) > 32:
            raise SystemExit("%s projects %d members; the engine caps a composition at 32"
                             % (encounter["id"], len(members)))

        quest = encounter["quest"]
        out.append({
            "id": encounter["id"],
            "displayName": encounter["displayName"],
            "members": members,
            "xpReward": encounter["xpReward"],
            "xpGrowth": encounter.get("xpGrowth", 1.2),
            "goldReward": encounter.get("goldReward", 0.0),
            "requiredQuestId": quest["requiredQuestId"],
            "notifyTopic": quest["notifyTopic"],
            "notifyTarget": quest["notifyTarget"],
            "notifyAmount": quest["notifyAmount"],
            "defeatCounterId": quest["defeatCounterId"],
            "defeatCounterAmount": quest["defeatCounterAmount"],
            "levelPointAttributeId": quest["levelPointAttributeId"],
            "pointsPerLevel": quest["pointsPerLevel"],
        })
    return out


def render(array: list) -> str:
    return json.dumps(array, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="fail when the committed artifact is stale; write nothing")
    args = parser.parse_args()

    enemies = load(ENEMY_DIR)
    encounters = load(ENCOUNTER_DIR)
    array = project(enemies, encounters)
    text = render(array)

    total = sum(len(entry["members"]) for entry in array)
    if args.check:
        if not OUTPUT.exists():
            raise SystemExit("missing %s; run `python tools/build_encounters.py`"
                             % OUTPUT.relative_to(ROOT))
        if OUTPUT.read_text(encoding="utf-8") != text:
            raise SystemExit("%s is stale; run `python tools/build_encounters.py`"
                             % OUTPUT.relative_to(ROOT))
        print("ok      %s (%d encounter(s), %d projected member(s))"
              % (OUTPUT.relative_to(ROOT), len(array), total))
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(text, encoding="utf-8")
    print("build   %s (%d encounter(s), %d projected member(s))"
          % (OUTPUT.relative_to(ROOT), len(array), total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
