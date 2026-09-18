#!/usr/bin/env python3
"""Build the rpg-classic terrain atlas from the Screaming Brain Studios CC0 packs.

Why this exists
---------------
The packs ship as *sheets*: one PNG per material holding a clean grid of 2:1
isometric cells.  Neither the sheet nor its transparency key is usable directly
by the workflow, which wants one atlas image plus an explicit per-GID
`region`/`pivot`:

  * the engine has exactly one atlas per map (`RpgcTilemap.atlasFor` reads
    `tilesets[0]`) and the map's cell size must equal the atlas
    `tileWidth`/`tileHeight` (`lib/rpgc_tilemap.nut`), so many sheets have to
    become one image;
  * the sheets are opaque and their "transparent" colour is **not consistent**:
    the floor / overworld sheets key on magenta `(255,0,255)` (the `.tsx` files
    declare `trans="ff00ff"`), while the object sheets key on black
    `(0,0,0)`.  Both are replaced with real alpha here.

Both backgrounds are removed by **flood-filling inward from the image border**
rather than by a global colour key: artwork legitimately contains dark pixels
inside a diamond, and a global key would punch holes in it.

Cell size
---------
The atlas cell stays `128x64`, the workflow's established isometric unit.

This is not an arbitrary choice.  The floor/overworld sheets are authored at
`256x128` ("Large"), but **every prop, wall and building in these packs is
authored ~128 px wide** -- objects are `128x128`, walls `128x192`/`144x200`,
town buildings `64x96`.  A `256x128` ground cell would therefore render every
prop at half scale.  The `128x64` ground cell is the packs' native pairing, and
it is also the size the two sample maps are hand-authored against, so using it
keeps those maps valid without touching a single tile coordinate.

Source archives
---------------
`assets/*.zip` / `assets/*.rar` are the vendored CC0 downloads (see
`content/tilesets/CREDITS.md`).  The script extracts them itself when pointed at
the directory, so a rebuild is one command and needs no manual unzipping:

    python tools/build_sbs_atlas.py --archives assets
    python tools/build_sbs_atlas.py --archives assets --check   # verify, no write

`.rar` needs `UnRAR.exe` (WinRAR) or `unrar` on PATH; `.zip` is handled by the
standard library.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from collections import deque

import numpy as np
from PIL import Image

WORKFLOW_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILESET_DIR = os.path.join(WORKFLOW_ROOT, "content", "tilesets")
ATLAS_IMAGE = "sbs-atlas.png"
TILESET_ID = "sbs-atlas"

# The atlas cell, and therefore the map cell.  See the module docstring for why
# this stays 128x64 even though the floor sheets are authored at 256x128.
CELL_W, CELL_H = 128, 64
COLUMNS = 6          # ground diamonds per atlas row
PROP_CELL = 128      # props are placed on a 128x128 lattice

FLOORS = "SBS - Isometric Floor Tiles - Large 256x128/Large 256x128"
OBJECTS = "SBS - Isometric Object Pack"
OVERWORLD = "SBS - Isometric Overworld Pack - Large/Overworld - Large"

# GID order is part of the tileset's public contract: the sample maps reference
# slots 1-4 as ground and 5-8 as props, so those eight keep their exact meaning.
# Everything after them is additive.  `pick` selects the source cell:
#   "plain"     -> the flattest full diamond (a tileable base material)
#   "decorated" -> the busiest full diamond (for the decoration sheets, where a
#                  flat pick would just duplicate plain grass)
GROUNDS = [
    ("grass", f"{FLOORS}/Exterior/Grass/Floor_Grass_01-256x128.png", "plain"),
    ("dirt", f"{FLOORS}/Exterior/Dry/Floor_Dry_01-256x128.png", "plain"),
    ("stone", f"{FLOORS}/Exterior/Stones/Floor_Stones_01-256x128.png", "plain"),
    ("water", f"{OVERWORLD}/Flat/Overworld - Water - Flat 256x128.png", "plain"),
    ("rocky", f"{FLOORS}/Exterior/Rocky/Floor_Rocky_01-256x128.png", "plain"),
    ("ice", f"{FLOORS}/Exterior/Ice/Floor_Ice_01-256x128.png", "plain"),
    ("flora", f"{FLOORS}/Exterior/Flora/Floor_Flora_01-256x128.png", "decorated"),
    ("elements", f"{FLOORS}/Exterior/Elements/Floor_Elements_01-256x128.png", "decorated"),
    ("forest", f"{OVERWORLD}/Flat/Overworld - Forest - Flat 256x128.png", "plain"),
    ("terrain", f"{OVERWORLD}/Flat/Overworld - Terrain 1 - Flat 256x128.png", "plain"),
    ("wood", f"{FLOORS}/Interior/Wood/Floor_Wood_01-256x128.png", "plain"),
    ("brick", f"{FLOORS}/Interior/Brick/Floor_Brick_01-256x128.png", "plain"),
    ("tile", f"{FLOORS}/Interior/Tile/Floor_Tile_01-256x128.png", "plain"),
    ("pattern", f"{FLOORS}/Interior/Pattern/Floor_Pattern_01-256x128.png", "plain"),
    ("metal", f"{FLOORS}/Interior/Metal/Floor_Metal_01-256x128.png", "plain"),
    ("grill", f"{FLOORS}/Interior/Grill/Floor_Grill_01-256x128.png", "plain"),
    ("interiorStone", f"{FLOORS}/Interior/Stone/Floor_Stone_01-256x128.png", "plain"),
]

# Grounds before this index take GIDs 1-4; the rest are appended after the props.
CORE_GROUNDS = 4
CORE_PROPS = 4


# (name, sheet, source cell 256x128, cell index in the 3x6 grid, or None = auto)
PROPS = [
    ("ruin", f"{OBJECTS}/Copings/Copings - Stone 1 128x128.png", (128, 128), 14),
    ("wall", f"{OBJECTS}/Copings/Copings - Stone 1 128x128.png", (128, 128), 2),
    ("crate", f"{OBJECTS}/Boxes/Crates - Wood 128x128.png", (128, 128), 0),
    ("stairs", f"{OBJECTS}/Stairs/Brick/Brick A - Stairs 128x128.png", (128, 128), 0),
    ("crateMetal", f"{OBJECTS}/Boxes/Crates - Metal 128x128.png", (128, 128), 0),
    ("stairsStone", f"{OBJECTS}/Stairs/Stone/Stone A - Stairs 128x128.png", (128, 128), 0),
    ("stairsWood", f"{OBJECTS}/Stairs/Wood/Wood A - Stairs 128x128.png", (128, 128), 0),
]


# --------------------------------------------------------------------------- #
# archive extraction
# --------------------------------------------------------------------------- #

def _find_unrar() -> str | None:
    found = shutil.which("unrar") or shutil.which("UnRAR")
    if found:
        return found
    for candidate in (r"C:\Program Files\WinRAR\UnRAR.exe",
                      r"C:\Program Files (x86)\WinRAR\UnRAR.exe"):
        if os.path.isfile(candidate):
            return candidate
    return None


def extract_archives(archive_dir: str, destination: str) -> str:
    """Extract every .zip/.rar in `archive_dir` into `destination` and return it."""
    os.makedirs(destination, exist_ok=True)
    entries = sorted(os.listdir(archive_dir))
    archives = [e for e in entries
                if e.lower().endswith((".zip", ".rar"))]
    if not archives:
        raise SystemExit(f"no .zip/.rar archives in {archive_dir}")

    unrar = _find_unrar()
    for name in archives:
        source = os.path.join(archive_dir, name)
        target = os.path.join(destination, os.path.splitext(name)[0])
        if os.path.isdir(target) and os.listdir(target):
            print(f"  cached  {name}")
            continue
        os.makedirs(target, exist_ok=True)
        if name.lower().endswith(".zip"):
            with zipfile.ZipFile(source) as zf:
                zf.extractall(target)
        else:
            if not unrar:
                raise SystemExit(
                    f"rpgc: {name} needs UnRAR.exe (WinRAR) or `unrar` on PATH")
            result = subprocess.run([unrar, "x", "-y", "-idq", source, target + os.sep],
                                    capture_output=True, text=True)
            if result.returncode != 0:
                raise SystemExit(f"rpgc: unrar failed on {name}: "
                                 f"{result.stdout}{result.stderr}")
        print(f"  unpack  {name}")
    return destination


# --------------------------------------------------------------------------- #
# image helpers
# --------------------------------------------------------------------------- #

def _border_background(mask: np.ndarray) -> np.ndarray:
    """True where `mask` is connected to the image border (4-connected)."""
    h, w = mask.shape
    visited = np.zeros_like(mask)
    queue: deque = deque()

    def push(y: int, x: int) -> None:
        if mask[y, x] and not visited[y, x]:
            visited[y, x] = True
            queue.append((y, x))

    for x in range(w):
        push(0, x)
        push(h - 1, x)
    for y in range(h):
        push(y, 0)
        push(y, w - 1)
    while queue:
        y, x = queue.popleft()
        if y > 0:
            push(y - 1, x)
        if y < h - 1:
            push(y + 1, x)
        if x > 0:
            push(y, x - 1)
        if x < w - 1:
            push(y, x + 1)
    return visited


def key_to_alpha(image: Image.Image, key: str, tolerance: int = 40) -> Image.Image:
    """Replace a border-connected key colour with real alpha.

    Magenta needs a generous tolerance because the sheets are lossily clean but
    not exact; black uses a small one so that dark interior art survives.
    """
    arr = np.asarray(image.convert("RGB")).astype(np.int16)
    if key == "magenta":
        mask = ((arr[:, :, 0] > 255 - tolerance)
                & (arr[:, :, 1] < tolerance)
                & (arr[:, :, 2] > 255 - tolerance))
    else:
        mask = ((arr[:, :, 0] <= 8) & (arr[:, :, 1] <= 8) & (arr[:, :, 2] <= 8))
    background = _border_background(mask)

    rgb = np.asarray(image.convert("RGB"))
    out = rgb.copy()
    if background.any():
        # Fill the cleared background with the artwork's own mean colour before
        # any resize, so downscaling cannot smear a magenta halo into the edge.
        interior = ~background
        fill = (rgb[interior].mean(axis=0).round().astype(np.uint8)
                if interior.any() else np.zeros(3, np.uint8))
        out[background] = fill
    alpha = np.where(background, 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([out, alpha]), "RGBA")


def grid_cells(image: Image.Image, cell_w: int, cell_h: int) -> list:
    cells = []
    for y in range(0, image.height - cell_h + 1, cell_h):
        for x in range(0, image.width - cell_w + 1, cell_w):
            cells.append(image.crop((x, y, x + cell_w, y + cell_h)))
    return cells


def plain_cell(cells: list, mode: str = "plain"):
    """Pick a full diamond from a sheet.

    A 2:1 diamond inscribed in its bounding box covers exactly half of it, so
    coverage near 0.5 means "keeps the whole diamond".  Within that set, "plain"
    takes the lowest colour deviation (no decoration -- what a tileable base
    material wants) and "decorated" the highest.
    """
    candidates = []
    for index, cell in enumerate(cells):
        arr = np.asarray(cell.convert("RGBA"))
        alpha = arr[:, :, 3] > 8
        cov = float(alpha.mean())
        if cov < 0.44 or cov > 0.56:
            continue
        sd = float(arr[:, :, :3][alpha].std(axis=0).mean())
        candidates.append((sd, index, cell, cov))
    if not candidates:
        raise SystemExit("no full diamond cell found")
    best = min(candidates) if mode == "plain" else max(candidates)
    return best[1], best[2]


def content_box(tile: Image.Image, threshold: int = 8) -> tuple:
    alpha = np.asarray(tile.convert("RGBA"))[:, :, 3]
    ys, xs = np.nonzero(alpha > threshold)
    if len(xs) == 0:
        return (0, 0, tile.width, tile.height)
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


# --------------------------------------------------------------------------- #
# builder
# --------------------------------------------------------------------------- #

class Builder:
    def __init__(self, source: str):
        self.source = source
        self.cache: dict = {}

    def sheet(self, relative: str) -> Image.Image:
        if relative not in self.cache:
            path = os.path.join(self.source, relative)
            if not os.path.isfile(path):
                raise SystemExit(f"missing source sheet: {path}")
            self.cache[relative] = Image.open(path).convert("RGB")
        return self.cache[relative]

    def key_for(self, relative: str) -> str:
        """Which colour the sheet uses for transparency.

        The packs are **not** consistent: the floor sheets key on magenta
        (`trans="ff00ff"`) while the overworld and object sheets key on black
        (`trans="000000"`).  The sibling `.tsx` declares it, so that is read
        first; the corner pixel is the fallback when a sheet has no `.tsx`.
        """
        tsx = os.path.splitext(os.path.join(self.source, relative))[0] + ".tsx"
        if os.path.isfile(tsx):
            with open(tsx, encoding="utf-8", errors="replace") as handle:
                match = re.search(r'trans="([0-9a-fA-F]{6})"', handle.read())
            if match:
                value = match.group(1).lower()
                if value == "ff00ff":
                    return "magenta"
                if value == "000000":
                    return "black"
                raise SystemExit(f"{tsx}: unsupported trans colour #{value}")
        r, g, b = self.sheet(relative).getpixel((0, 0))
        if r > 200 and g < 60 and b > 200:
            return "magenta"
        if r < 20 and g < 20 and b < 20:
            return "black"
        raise SystemExit(f"{relative}: cannot tell which colour is transparent "
                         f"(corner is {r},{g},{b})")

    def ground(self, relative: str, mode: str = "plain") -> Image.Image:
        """One 128x64 ground diamond from a 256x128 sheet."""
        key = self.key_for(relative)
        cells = grid_cells(self.sheet(relative).convert("RGB"), 256, 128)
        keyed = [key_to_alpha(c, key) for c in cells]
        index, cell = plain_cell(keyed, mode)
        return cell.resize((CELL_W, CELL_H), Image.LANCZOS), index

    def prop(self, relative: str, cell: tuple, index: int) -> Image.Image:
        cells = grid_cells(self.sheet(relative).convert("RGB"), cell[0], cell[1])
        if index >= len(cells):
            raise SystemExit(f"{relative}: index {index} beyond {len(cells)} cells")
        return key_to_alpha(cells[index], self.key_for(relative))


def build(source: str) -> tuple:
    b = Builder(source)

    ground_images = []
    for name, sheet, mode in GROUNDS:
        image, index = b.ground(sheet, mode)
        ground_images.append((name, image, index, sheet))
    prop_images = []
    for name, sheet, cell, index in PROPS:
        prop_images.append((name, b.prop(sheet, cell, index), index, sheet))

    # GID contract, not layout order: 1-4 ground, 5-8 props, then the additive
    # remainder.  The two bands are packed separately, so a GID and its atlas
    # position deliberately do not run in lockstep.
    ordered = ([("ground", g) for g in ground_images[:CORE_GROUNDS]]
               + [("prop", p) for p in prop_images[:CORE_PROPS]]
               + [("ground", g) for g in ground_images[CORE_GROUNDS:]]
               + [("prop", p) for p in prop_images[CORE_PROPS:]])

    ground_rows = (len(ground_images) + COLUMNS - 1) // COLUMNS
    prop_band = ground_rows * CELL_H
    prop_rows = (len(prop_images) + COLUMNS - 1) // COLUMNS
    width = COLUMNS * CELL_W
    height = prop_band + prop_rows * PROP_CELL

    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    tiles = []
    ground_slot = prop_slot = 0

    for gid, (kind, item) in enumerate(ordered, start=1):
        name, image, index, sheet = item
        if kind == "ground":
            x = (ground_slot % COLUMNS) * CELL_W
            y = (ground_slot // COLUMNS) * CELL_H
            ground_slot += 1
            assert image.size == (CELL_W, CELL_H), f"{name}: {image.size}"
            atlas.alpha_composite(image, (x, y))
            tiles.append({"gid": gid, "name": name, "kind": "ground",
                          "region": [x, y, CELL_W, CELL_H], "pivot": [0, 0],
                          "source": sheet, "cell": index})
        else:
            x = (prop_slot % COLUMNS) * CELL_W
            y = prop_band + (prop_slot // COLUMNS) * PROP_CELL
            prop_slot += 1
            assert image.width <= CELL_W and image.height <= PROP_CELL, \
                f"{name}: {image.size}"
            atlas.alpha_composite(image, (x, y))
            # Pivot is tile-local (relative to `region`), matching the
            # convention the hand-written atlas used.
            bx0, by0, bx1, by1 = content_box(image)
            tiles.append({"gid": gid, "name": name, "kind": "prop",
                          "region": [x, y, image.width, image.height],
                          "pivot": [bx0 + (bx1 - bx0) / 2.0, by1],
                          "source": sheet, "cell": index})

    return atlas, tiles, width, height


def verify(atlas: Image.Image, tiles: list) -> list:
    """Geometry checks that do not need the engine: bounds, overlap, alpha."""
    problems = []
    for t in tiles:
        x, y, w, h = t["region"]
        if x < 0 or y < 0 or x + w > atlas.width or y + h > atlas.height:
            problems.append(f"gid {t['gid']} {t['name']}: region outside the atlas")
        sub = atlas.crop((x, y, x + w, y + h))
        alpha = np.asarray(sub)[:, :, 3]
        if not (alpha > 8).any():
            problems.append(f"gid {t['gid']} {t['name']}: region is fully transparent")
        if t["kind"] == "prop":
            # `pivot` is relative to the tile's own region (same convention the
            # hand-written sbs-atlas.json used), so it is checked against the
            # region's size, not its atlas position.
            px, py = t["pivot"]
            if not (0 <= px <= w and 0 <= py <= h):
                problems.append(f"gid {t['gid']} {t['name']}: pivot {t['pivot']} "
                                f"outside its {w}x{h} region")
    for i, a in enumerate(tiles):
        ax, ay, aw, ah = a["region"]
        for b in tiles[i + 1:]:
            bx, by, bw, bh = b["region"]
            if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                problems.append(f"gid {a['gid']} overlaps gid {b['gid']}")
    return problems


def write_tileset(tiles: list) -> dict:
    PRICING = {"water": 4.0, "stone": 1.5, "dirt": 1.25}
    PROP_BIAS = {"ruin": 12, "wall": 16, "crate": 6, "stairs": 4,
                 "crateMetal": 6, "stairsStone": 4, "stairsWood": 4}
    doc = {
        "schema": "eve.rpgc.tileset",
        "version": 1,
        "id": TILESET_ID,
        "title": "Screaming Brain Studios 等距地形图集（2:1，128x64，CC0）",
        "image": ATLAS_IMAGE,
        "firstGid": 1,
        "columns": COLUMNS,
        "tileWidth": CELL_W,
        "tileHeight": CELL_H,
        "margin": 0,
        "spacing": 0,
        "tiles": [],
    }
    for t in tiles:
        entry = {
            "gid": t["gid"],
            "name": t["name"],
            "region": t["region"],
            "pivot": [round(float(t["pivot"][0]), 2), round(float(t["pivot"][1]), 2)],
            "footprint": [1, 1],
        }
        if t["kind"] == "ground":
            entry["sortBias"] = -2 if t["name"] == "water" else 0
            entry["walkable"] = t["name"] != "water"
            entry["cost"] = PRICING.get(t["name"], 1.0)
            entry["enterMask"] = 15
            entry["exitMask"] = 15
            entry["opaque"] = False
            entry["tags"] = ["ground", t["name"]]
        else:
            entry["sortBias"] = PROP_BIAS.get(t["name"], 8)
            entry["walkable"] = False
            entry["cost"] = 8.0
            entry["enterMask"] = 15
            entry["exitMask"] = 15
            entry["opaque"] = t["name"] == "wall"
            entry["tags"] = ["blocking", "prop", t["name"]]
        doc["tiles"].append(entry)
    return doc


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--archives", default=os.path.join(WORKFLOW_ROOT, "assets"),
                        help="directory holding the vendored .zip/.rar packs")
    parser.add_argument("--source", default="",
                        help="already-extracted pack directory (skips --archives)")
    parser.add_argument("--check", action="store_true",
                        help="verify the on-disk atlas matches a fresh build; write nothing")
    args = parser.parse_args(argv)

    if args.source:
        source = args.source
    else:
        if not os.path.isdir(args.archives):
            print(f"rpgc: no archive directory at {args.archives}", file=sys.stderr)
            return 2
        staging = os.path.join(args.archives, "extracted")
        print(f"extracting {args.archives} -> {staging}")
        source = extract_archives(args.archives, staging)

    atlas, tiles, width, height = build(source)
    problems = verify(atlas, tiles)
    if problems:
        for p in problems:
            print("rpgc: " + p, file=sys.stderr)
        return 1

    doc = write_tileset(tiles)
    atlas_path = os.path.join(TILESET_DIR, ATLAS_IMAGE)
    doc_path = os.path.join(TILESET_DIR, f"{TILESET_ID}.json")

    if args.check:
        fresh = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
        with open(doc_path, encoding="utf-8") as handle:
            on_disk = handle.read()
        same_doc = fresh == on_disk
        same_img = (os.path.isfile(atlas_path)
                    and Image.open(atlas_path).convert("RGBA").tobytes()
                    == atlas.convert("RGBA").tobytes())
        print(f"check: json {'match' if same_doc else 'DIFFERS'}, "
              f"png {'match' if same_img else 'DIFFERS'}")
        return 0 if (same_doc and same_img) else 1

    os.makedirs(TILESET_DIR, exist_ok=True)
    atlas.save(atlas_path)
    with open(doc_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")

    print(f"atlas {width}x{height} -> content/tilesets/{ATLAS_IMAGE}")
    for t in tiles:
        print(f"  gid {t['gid']:>2} {t['name']:<14} {t['kind']:<6} "
              f"src_cell={t['cell']:<3} region={t['region']} "
              f"pivot={doc['tiles'][t['gid'] - 1]['pivot']}")
    print(f"tileset -> content/tilesets/{TILESET_ID}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
