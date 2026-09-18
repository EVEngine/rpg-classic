#!/usr/bin/env python3
"""Generate the rpg-classic open-world maps from ``data/world-regions.json``.

Twelve documents are produced -- the five 中原主城 and the seven 边缘城镇 --
plus the portals this world attaches to maps that already exist on disk
(``content/maps/village-outskirts.json``). The spec is the authored setting;
this tool is the projection, exactly like ``build_sbs_atlas.py`` and
``bake_tilesets.py`` are for the atlases.

What the generator owns:

* the projection header (``origin`` is derived from the map size, see below);
* the ``terrain`` layer, which must be the first tilelayer and carry ``layer: 0``
  (``RpgcTilemap.layerDisciplineDiagnostics``);
* the ``props`` layer, which is the paving/road pattern;
* the single ``spawn`` object every level needs (``map.no-spawn``);
* the ``npc`` / ``chest`` objects from the spec;
* the ``portal`` objects, which are derived from ``links`` so that a doorway is
  always a pair: A->B and B->A each get one, and each one's landing cell is the
  *other* map's portal stepped one cell inward.

Everything else in an existing map (its terrain, its own objects) is preserved;
``village-outskirts`` is patched, never regenerated.

Usage::

    python tools/build_world_maps.py            # write
    python tools/build_world_maps.py --check    # assert the disk matches
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "data" / "world-regions.json"
MAP_DIR = ROOT / "content" / "maps"

# Tile-axis edges. The isometric projection turns +tx into down-right and +ty
# into down-left, but the generator works in tile space and only converts to
# world pixels for the object coordinates.
OPPOSITE = {"north": "south", "south": "north", "west": "east", "east": "west"}
INWARD = {"north": (0, 1), "south": (0, -1), "west": (1, 0), "east": (-1, 0)}
EDGE_SLOT = {
    "west": (1, None),
    "east": (None, None),  # tx = width - 2, filled in per map
    "north": (None, 1),
    "south": (None, None),
}

# Deterministic nudge order when a spec position lands on an occupied cell.
NUDGE = [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1),
         (2, 0), (0, 2), (-2, 0), (0, -2)]


class SpecError(Exception):
    """The spec cannot produce a valid world; the message names the entry."""


def read_json(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, document):
    text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    return text


def rng_for(map_id):
    """A stable per-map RNG. ``hash()`` is salted per process and unusable."""
    return random.Random(zlib.crc32(map_id.encode("utf-8")))


def origin_for(width, height, tile_width, tile_height):
    """The framing convention the two shipped maps already use.

    ``worldX = originX + (tx - ty) * pitchX / 2`` with ``pitchX = 2 * tileWidth``
    under ``renderSpacing [2, 2]``, so ``originX = (height - 1) * tileWidth +
    tileHeight`` puts the map's bounding box at ``minX = minY = tileHeight``.
    Verified against ``village-outskirts`` (24x20 -> [2496, 64]) and
    ``mist-forest`` (20x18 -> [2240, 64]).
    """
    return [(height - 1) * tile_width + tile_height, tile_height]


def anchor_of(origin, tile_width, tile_height, tx, ty):
    """World pixel of a cell's top-left corner -- where object x/y are written.

    The shipped maps agree: ``village-outskirts``' spawn at (2880, 1280) solves
    to tile (11, 8), and this is the exact inverse of ``RpgcIso.worldToTile*``.
    """
    return (origin[0] + (tx - ty) * tile_width,
            origin[1] + (tx + ty) * tile_height)


def spec_cell(size, fraction, border):
    """Map a spec fraction to an interior cell, keeping a one-cell margin."""
    width, height = size
    return (border + round(fraction[0] * (width - 1 - 2 * border)),
            border + round(fraction[1] * (height - 1 - 2 * border)))


def place(occupied, size, tx, ty, border):
    """First free interior cell at or after (tx, ty). Keeps names unique."""
    width, height = size
    lo, hi_x, hi_y = border, width - 1 - border, height - 1 - border

    def inside(x, y):
        return lo <= x <= hi_x and lo <= y <= hi_y

    if (tx, ty) not in occupied and inside(tx, ty):
        occupied.add((tx, ty))
        return tx, ty
    for dx, dy in NUDGE:
        if (tx + dx, ty + dy) not in occupied and inside(tx + dx, ty + dy):
            occupied.add((tx + dx, ty + dy))
            return tx + dx, ty + dy
    raise SpecError("no free cell near (%d, %d) on a %dx%d map" % (tx, ty, width, height))


# --------------------------------------------------------------------- tiles

def atlas_document(atlas_id):
    path = ROOT / "content" / "tilesets" / (atlas_id + ".json")
    if not path.exists():
        raise SpecError("atlas %s.json is missing" % atlas_id)
    return read_json(path)


def atlas_bounds(atlas_id):
    doc = atlas_document(atlas_id)
    first = int(doc.get("firstGid", 1))
    count = int(doc.get("count", 0))
    if count < 1:
        raise SpecError("atlas %s declares no tiles" % atlas_id)
    return doc, first, first + count - 1


def terrain_layer(location, spec):
    """The base ground, with the outer ring left empty (GID 0)."""
    width, height = location["size"]
    border = spec["projection"]["borderRing"]
    doc, first, last = atlas_bounds(location["atlas"])
    ground_lo, ground_hi = location["ground"]
    if ground_lo < first or ground_hi > last:
        raise SpecError("%s ground %s is outside %s (%d..%d)"
                        % (location["id"], location["ground"],
                           location["atlas"], first, last))

    pool = list(range(ground_lo, ground_hi + 1))
    rng = rng_for(location["id"] + ":terrain")
    # A few distinct ground GIDs keep the fill from reading as one flat sheet.
    weights = [rng.choice(pool) for _ in range(3)]
    data = []
    for ty in range(height):
        for tx in range(width):
            if (tx < border or ty < border
                    or tx >= width - border or ty >= height - border):
                data.append(0)
                continue
            roll = rng.random()
            data.append(weights[0] if roll < 0.72
                        else (weights[1] if roll < 0.90 else weights[2]))
    return {
        "id": "terrain",
        "name": "terrain",
        "type": "tilelayer",
        "layer": 0,
        "visible": True,
        "data": data,
    }


def props_layer(location, spec):
    """Paving. A 主城 gets a street grid; a 边镇 gets one road and a branch."""
    width, height = location["size"]
    border = spec["projection"]["borderRing"]
    doc, first, last = atlas_bounds(location["atlas"])
    street_lo, street_hi = location["street"]
    if street_lo < first or street_hi > last:
        raise SpecError("%s street %s is outside %s (%d..%d)"
                        % (location["id"], location["street"],
                           location["atlas"], first, last))

    pool = list(range(street_lo, street_hi + 1))
    rng = rng_for(location["id"] + ":props")
    main = rng.choice(pool)
    accent = rng.choice(pool)
    centre = (width // 2, height // 2)

    def interior(tx, ty):
        return (border <= tx < width - border and border <= ty < height - border)

    data = [0] * (width * height)
    for ty in range(height):
        for tx in range(width):
            if not interior(tx, ty):
                continue
            if location["tier"] == "主城":
                paved = (tx - border) % 5 == 0 or (ty - border) % 5 == 0
            else:
                # One road along the short axis, one branch to the centre.
                paved = (ty == height // 2
                         or (tx == centre[0] and abs(ty - centre[1]) <= 4))
            if not paved:
                continue
            data[ty * width + tx] = main
    # A plaza at the centre, so every settlement has an anchor worth walking to.
    for ty in range(centre[1] - 1, centre[1] + 2):
        for tx in range(centre[0] - 1, centre[0] + 2):
            if interior(tx, ty):
                data[ty * width + tx] = accent
    return {
        "id": "props",
        "name": "props",
        "type": "tilelayer",
        "layer": 1,
        "visible": True,
        "data": data,
    }


# ------------------------------------------------------------------- portals

def portal_cells(locations, links, spec):
    """Every portal's cell, keyed by map id.

    ``links`` is an edge list, not a pair list: the reverse doorway is derived,
    so a one-sided edit cannot leave a map with a corridor to nowhere.
    """
    border = spec["projection"]["borderRing"]
    sizes = {loc["id"]: loc["size"] for loc in locations}
    by_map = {}

    def size_of(map_id):
        """A generated location's size, or an on-disk map's own header."""
        if map_id not in sizes:
            if not (MAP_DIR / (map_id + ".json")).exists():
                raise SpecError("link endpoint %s is neither generated nor on disk"
                                % map_id)
            sizes[map_id] = _existing_size(map_id)
        return sizes[map_id]

    seen = set()
    for link in links:
        a, b = link["from"], link["to"]
        if a == b:
            raise SpecError("link %s -> %s is a self-loop" % (a, b))
        key = tuple(sorted((a, b)))
        if key in seen:
            raise SpecError("link %s -> %s duplicates an earlier pair" % (a, b))
        seen.add(key)
        size_of(a)
        size_of(b)
        if link["edge"] not in OPPOSITE:
            raise SpecError("link %s -> %s has unknown edge %r" % (a, b, link["edge"]))

        by_map.setdefault(a, []).append({"other": b, "edge": link["edge"]})
        by_map.setdefault(b, []).append({"other": a, "edge": OPPOSITE[link["edge"]]})

    for map_id, entries in by_map.items():
        width, height = sizes[map_id]
        per_edge = {}
        for entry in entries:
            per_edge.setdefault(entry["edge"], []).append(entry)
        for edge, group in per_edge.items():
            span = height if edge in ("west", "east") else width
            if span <= 2 * border + 1:
                raise SpecError("%s is too small for a %s portal" % (map_id, edge))
            for index, entry in enumerate(group):
                along = border + (span - 1 - 2 * border) * (index + 1) // (len(group) + 1)
                if edge == "west":
                    tx, ty = border, along
                elif edge == "east":
                    tx, ty = width - 1 - border, along
                elif edge == "north":
                    tx, ty = along, border
                else:
                    tx, ty = along, height - 1 - border
                entry["tx"] = tx
                entry["ty"] = ty
                entry["name"] = "gate-" + entry["other"]

    for entries in by_map.values():
        for entry in entries:
            if not entry["name"].replace("-", "").replace(".", "").isalnum():
                raise SpecError("portal name %r is not a stable id" % entry["name"])
    return by_map, sizes


def _existing_size(map_id):
    doc = read_json(MAP_DIR / (map_id + ".json"))
    return [int(doc["width"]), int(doc["height"])]


def portal_properties(map_id, entry, portals, sizes, border):
    """Resolve one doorway's target cell and arrival facing.

    The landing cell is the *other* map's portal stepped inward along that
    portal's own inward direction, so arriving never drops the player on the
    cell that would immediately send them back.
    """
    target = entry["other"]
    reverse = None
    for candidate in portals.get(target, []):
        if candidate["other"] == map_id:
            reverse = candidate
            break
    if reverse is None:
        raise SpecError("%s/%s has no reverse portal in %s" % (map_id, entry["name"], target))

    dx, dy = INWARD[reverse["edge"]]
    width, height = sizes[target]
    tx = min(max(reverse["tx"] + dx, border), width - 1 - border)
    ty = min(max(reverse["ty"] + dy, border), height - 1 - border)
    return [
        {"name": "targetMap", "type": "string", "value": target},
        {"name": "targetX", "type": "string", "value": str(tx)},
        {"name": "targetY", "type": "string", "value": str(ty)},
        {"name": "facingX", "type": "string", "value": str(dx)},
        {"name": "facingY", "type": "string", "value": str(dy)},
    ]


# ------------------------------------------------------------------ objects

def build_objects(location, spec, portals, sizes, origin, tile_width, tile_height):
    border = spec["projection"]["borderRing"]
    width, height = location["size"]
    occupied = set()
    objects = []

    def add(name, kind, cell, properties=None):
        tx, ty = cell
        x, y = anchor_of(origin, tile_width, tile_height, tx, ty)
        obj = {"name": name, "type": kind, "x": x, "y": y}
        if properties:
            obj["properties"] = properties
        objects.append(obj)

    spawn = place(occupied, location["size"], width // 2, height // 2, border)
    add("spawn", "spawn", spawn)

    for npc in location["npcs"]:
        cell = place(occupied, location["size"],
                     *spec_cell(location["size"], npc["at"], border), border=border)
        add(npc["name"], "npc", cell, [
            {"name": "dialogue", "type": "string", "value": npc["dialogue"]},
            {"name": "speaker", "type": "string", "value": npc["speaker"]},
        ])

    for chest in location["chests"]:
        cell = place(occupied, location["size"],
                     *spec_cell(location["size"], chest["at"], border), border=border)
        add(chest["name"], "chest", cell, [
            {"name": "itemId", "type": "string", "value": chest["itemId"]},
            {"name": "gold", "type": "string", "value": str(chest["gold"])},
        ])

    for entry in portals.get(location["id"], []):
        cell = place(occupied, location["size"], entry["tx"], entry["ty"], border)
        add(entry["name"], "portal", cell,
            portal_properties(location["id"], entry, portals, sizes, border))
    return objects


def objects_layer(objects):
    return {
        "id": "actors",
        "name": "actors",
        "type": "objectgroup",
        "layer": 2,
        "visible": True,
        "objects": objects,
    }


# -------------------------------------------------------------------- build

def build_map(location, spec, portals, sizes):
    projection = spec["projection"]
    tile_width = projection["tileWidth"]
    tile_height = projection["tileHeight"]
    width, height = location["size"]
    origin = origin_for(width, height, tile_width, tile_height)
    objects = build_objects(location, spec, portals, sizes, origin,
                            tile_width, tile_height)
    return {
        "schema": "eve.rpgc.map",
        "version": 1,
        "id": location["id"],
        "title": location["title"],
        "width": width,
        "height": height,
        "tilewidth": tile_width,
        "tileheight": tile_height,
        "orientation": "isometric",
        "renderSpacing": list(projection["renderSpacing"]),
        "origin": origin,
        "tilesets": [
            {"source": "../tilesets/" + location["atlas"] + ".json", "firstgid": 1}
        ],
        "layers": [
            terrain_layer(location, spec),
            props_layer(location, spec),
            objects_layer(objects),
        ],
    }


def plan(spec):
    """Resolve the whole world once: links -> portals -> per-map documents."""
    locations = spec["locations"]
    ids = [loc["id"] for loc in locations]
    if len(set(ids)) != len(ids):
        raise SpecError("two locations share an id")

    portals, sizes = portal_cells(locations, spec["links"], spec)
    documents = {}
    for location in locations:
        documents[location["id"]] = build_map(location, spec, portals, sizes)

    attached = []
    for map_id in sorted(portals):
        if map_id in documents:
            continue
        attached.append((map_id, portals[map_id]))
    return documents, attached, portals, sizes


def patch_existing(map_id, entries, portals, sizes, spec):
    """Add this world's portals to a map that is authored by hand."""
    path = MAP_DIR / (map_id + ".json")
    document = read_json(path)
    border = spec["projection"]["borderRing"]
    width, height = sizes[map_id]
    origin = [int(v) for v in document["origin"]]
    tile_width = int(document["tilewidth"])
    tile_height = int(document["tileheight"])

    generated = {entry["name"] for entry in entries}
    occupied = set()
    layer = None
    for candidate in document["layers"]:
        if candidate.get("type") != "objectgroup":
            continue
        if layer is None:
            layer = candidate
        candidate["objects"] = [obj for obj in candidate.get("objects", [])
                                if obj.get("name") not in generated]
    if layer is None:
        raise SpecError("%s has no objectgroup layer to attach a portal to" % map_id)

    for obj in layer.get("objects", []):
        # Cells already taken by the hand-authored objects, so a new portal
        # cannot land on top of an existing one.
        anchor = anchor_of(origin, tile_width, tile_height, 0, 0)
        dx = (obj["x"] - anchor[0]) / float(tile_width)
        dy = (obj["y"] - anchor[1]) / float(tile_height)
        occupied.add((round((dy + dx) / 2), round((dy - dx) / 2)))

    for entry in sorted(entries, key=lambda item: item["name"]):
        try:
            tx, ty = place(occupied, sizes[map_id], entry["tx"], entry["ty"], border)
        except SpecError:
            continue  # an edge cell is taken; this doorway keeps its slot
        x, y = anchor_of(origin, tile_width, tile_height, tx, ty)
        layer["objects"].append({
            "name": entry["name"],
            "type": "portal",
            "x": x,
            "y": y,
            "properties": portal_properties(map_id, entry, portals, sizes, border),
        })
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="do not write; fail if the documents on disk differ")
    parser.add_argument("--spec", type=Path, default=SPEC_PATH)
    args = parser.parse_args()

    spec = read_json(args.spec)
    try:
        documents, attached, portals, sizes = plan(spec)
    except SpecError as error:
        print("build_world_maps: %s" % error, file=sys.stderr)
        return 1

    stale = []
    written = []
    for map_id, document in sorted(documents.items()):
        text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        path = MAP_DIR / (map_id + ".json")
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != text:
            stale.append(str(path.relative_to(ROOT)))
            if not args.check:
                write_json(path, document)
        written.append((map_id, len(document["layers"][2]["objects"])))

    for map_id, entries in attached:
        document = patch_existing(map_id, entries, portals, sizes, spec)
        text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        path = MAP_DIR / (map_id + ".json")
        current = path.read_text(encoding="utf-8")
        if current != text:
            stale.append(str(path.relative_to(ROOT)) + " (attached portals)")
            if not args.check:
                write_json(path, document)

    total_portals = sum(len(v) for v in portals.values())
    if args.check:
        if stale:
            print("build_world_maps: %d document(s) out of date:" % len(stale))
            for name in stale:
                print("  " + name)
            return 1
        print("build_world_maps: up to date (%d maps, %d portals)"
              % (len(documents) + len(attached), total_portals))
        return 0

    for map_id, count in written:
        print("  %-18s %d objects" % (map_id, count))
    for map_id, entries in attached:
        print("  %-18s +%d attached portal(s)" % (map_id, len(entries)))
    print("build_world_maps: wrote %d map(s), %d portal(s)"
          % (len(documents) + len(attached), total_portals))
    return 0


if __name__ == "__main__":
    sys.exit(main())
