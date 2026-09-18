#!/usr/bin/env python3
"""Expand a version-2 (rule) tileset into the version-1 shape the engine reads.

`content/tilesets/<id>.json` stores the atlas grid plus the ordered size runs --
a few KB for thousands of tiles.  The engine's loader
(`src/modules/map/TileConfig.cpp`) instead wants an explicit `tiles[]` array
with a `region` per GID, ~450 B per tile.  This is the on-demand step between
them: the rule file stays the source of truth, and this output is generated.

    python tools/bake_tilesets.py            # bake every version-2 tileset
    python tools/bake_tilesets.py --check    # fail if the baked files are stale

Output is `<id>.baked.json` beside the rule file and is git-ignored.  A map
points its `tilesets[].source` at the baked file; the image path is unchanged,
because the baked document sits in the same directory as its atlas.

The expansion is not a re-implementation: `replay_runs` is the same function
that produced the atlas, so a baked file cannot describe a region the atlas does
not contain.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from import_terrain_assets import class_of, derived_pivot, replay_runs  # noqa: E402

WORKFLOW_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILESET_DIR = os.path.join(WORKFLOW_ROOT, "content", "tilesets")

SUFFIX = ".baked.json"


def bake(doc: dict, names: list) -> dict:
    """A version-2 rule document -> the version-1 document the engine reads."""
    rule = doc["layout"]
    pages, sizes = replay_runs(doc["runs"], rule["width"], rule["maxDim"])
    flat = [slot for page in pages for slot in page]
    first, count = rule["firstTile"], doc["count"]
    if first + count > len(flat):
        raise SystemExit(f"{doc['id']}: page window {first}+{count} exceeds "
                         f"the {len(flat)} packed tiles")

    out = {
        "schema": doc["schema"],
        "version": 1,
        "id": doc["id"],
        "title": doc.get("title", ""),
        "image": doc["image"],
        "firstGid": doc["firstGid"],
        "columns": max(1, rule["width"] // doc["tileWidth"]),
        "tileWidth": doc["tileWidth"],
        "tileHeight": doc["tileHeight"],
        "margin": doc["margin"],
        "spacing": doc["spacing"],
        "tiles": [],
    }
    for i in range(count):
        index = first + i
        x, y = flat[index]
        w, h = sizes[index]
        klass = class_of(doc, index)
        klass_rule = doc["classes"][klass]
        entry = {
            "gid": i + 1,
            "name": names[i] if i < len(names) else "",
            "region": [x, y, w, h],
            "pivot": derived_pivot(doc, klass, w, h),
            "footprint": klass_rule["footprint"],
            "walkable": klass_rule["walkable"],
            "cost": klass_rule["cost"],
            "sortBias": klass_rule["sortBias"],
            # The engine only reads these three from `properties[]`, but the
            # workflow's own schema documents them flat, so emit both shapes.
            "opaque": klass_rule["opaque"],
            "enterMask": klass_rule["enterMask"],
            "exitMask": klass_rule["exitMask"],
            "tags": [klass],
        }
        out["tiles"].append(entry)
    return out


def rule_files() -> list:
    found = sorted(glob.glob(os.path.join(TILESET_DIR, "*.json")))
    return [p for p in found if not p.endswith(SUFFIX)]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="fail if a baked file is missing or stale")
    args = parser.parse_args(argv)

    failures = 0
    for path in rule_files():
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
        if doc.get("version") != 2 or "runs" not in doc:
            continue                      # version 1 is already engine-shaped
        names = doc.get("names", [])
        baked = bake(doc, names)
        fresh = json.dumps(baked, indent=2, ensure_ascii=False) + "\n"
        target = path[: -len(".json")] + SUFFIX
        if args.check:
            same = (os.path.isfile(target)
                    and open(target, encoding="utf-8").read() == fresh)
            print(f"check {os.path.basename(target):<28} "
                  f"{'current' if same else 'STALE'}")
            failures += 0 if same else 1
            continue
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(fresh)
        print(f"baked {os.path.basename(target):<28} "
              f"{len(baked['tiles'])} tiles, "
              f"{os.path.getsize(target) / 1024:.0f} KB")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
