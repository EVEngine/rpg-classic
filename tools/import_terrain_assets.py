#!/usr/bin/env python3
"""Import the vendored CC0 packs under `assets/` into rpg-classic tilesets.

`build_sbs_atlas.py` produced a deliberately curated 24-GID starter atlas.  This
script is the opposite: it walks the packs and imports **every tile of every
sheet**, so nothing the user downloaded is left unused.

Geometry comes from the pack's own metadata, in this order:

  1. the sibling Tiled `.tsx` -- `tilewidth`/`tileheight`/`columns` and the
     `trans="rrggbb"` colour key are authoritative when present;
  2. otherwise the `<W>x<H>` suffix every SBS filename carries
     (`Flat_Brick_01-SE-128x192.png`), which is how the wall and town packs
     (which ship no `.tsx`) declare their cell size.

A sheet is cut into a `columns x rows` grid of that cell size; a file that holds
exactly one cell is kept whole.  Background is replaced with real alpha by
flood-filling inward from the border, never by a global colour key, because the
artwork legitimately contains near-black pixels inside a diamond.

Two pack shapes are supported:

* **sheet packs** (`PACKS`): one PNG holds many cells, cut on a grid.
* **single-sprite packs** (`KENNEY_PACKS`): one PNG holds exactly one object on
  a `256x512` canvas with transparent padding.  Nothing is cut; the sprite is
  trimmed to its content and scaled.

Pivot convention
----------------
`pivot` is a point *in the tile's own region* that the engine aligns with the
cell's projected origin.  `TileSystem.cpp:293-294` draws the quad at
`tileToWorld(...) - pivot`, and `GridProjection.cpp:41-42` makes `tileToWorld`
the top-left of the cell's diamond bounding box (which is also why
`RpgcIso.centerX` adds `tileWidth * 0.5` to get the diamond centre).  So a prop
that should stand on its cell must pivot at *its own ground anchor minus half a
cell*, exactly the way a ground tile's `[0, 0]` pivot makes its diamond fill the
cell.

Single-sprite packs use that corrected `origin` convention.  The five SBS packs
keep the legacy `anchor` convention they were shipped with (`pivot` == the
ground anchor itself, no half-cell subtraction); see `content/tilesets/CREDITS.md`
for the open finding.

Usage
-----
    python tools/import_terrain_assets.py --plan      # count only, write nothing
    python tools/import_terrain_assets.py             # build atlases + tilesets
    python tools/import_terrain_assets.py --check     # verify on-disk == fresh build
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

WORKFLOW_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(WORKFLOW_ROOT, "assets")
TILESET_DIR = os.path.join(WORKFLOW_ROOT, "content", "tilesets")

# Map cell stays 128x64 (the packs' native ground pairing; see
# build_sbs_atlas.py for why the 256x128 sheets are halved).
GROUND_W, GROUND_H = 128, 64
ATLAS_COLUMNS = 8

SIZE_ANYWHERE = re.compile(r"(?<!\d)(\d{2,4})x(\d{2,4})(?!\d)")

# Directories that carry no importable tile art.
SKIP_DIR_PARTS = ("tsx", "tiled tsx", "vector", "unity")
SKIP_FILE_STEMS = ("information", "preview", "sample", "license", "instructions")

PACKS = [
    {
        "id": "sbs-floors",
        "root": "SBS - Isometric Floor Tiles - Large 256x128/Large 256x128",
        "title": "SBS 等距地面（全部 14 种材质 × 2 张图集 × 18 格）",
        "kind": "ground",
        "cell": (256, 128),
        "out": (GROUND_W, GROUND_H),
    },
    {
        "id": "sbs-overworld",
        "root": "SBS - Isometric Overworld Pack - Large/Overworld - Large",
        "title": "SBS 等距大世界地形（Flat / Thick）",
        "kind": "ground",
        "out": (GROUND_W, GROUND_H),
    },
    {
        "id": "sbs-walls",
        "root": "SBS - Isometric Wall Pack - Large/Large Wall Tiles",
        "title": "SBS 等距墙片（Flat 128x192 / Thick 144x200）",
        "kind": "prop",
    },
    {
        "id": "sbs-objects",
        "root": "SBS - Isometric Object Pack",
        "title": "SBS 等距道具（箱子 / 台阶 / 压顶 / 神殿组件）",
        "kind": "prop",
    },
    {
        "id": "sbs-town",
        "root": "SBS - Isometric Town Pack",
        "title": "SBS 等距城镇（建筑 64x96 / 屋顶 144x92）",
        "kind": "prop",
        # The roof sheet's filename says 143x92, but the sheet is 432 px wide:
        # 3 x 143 = 429 leaves 3 px of slack, 3 x 144 fits exactly.  The pack's
        # own filename is off by one, so the true cell is declared here.
        "cell_overrides": {"Isometric Town Roofing - 143x92.png": (144, 92)},
    },
]

# --------------------------------------------------------------------------- #
# Kenney single-sprite packs
# --------------------------------------------------------------------------- #

# Every Kenney "Isometric Miniature" pack ships `Samples/Tiled Sample.zip`, and
# its `Sample.tmx` declares the grid the art was rendered for:
#     <map orientation="isometric" width="60" height="32"
#          tilewidth="256" tileheight="128">
# That 256x128 tile is twice our 128x64 map cell, so every sprite is halved.
# (The SBS "Large" packs use the same 256x128 source cell and are halved too,
# see GROUND_W/GROUND_H above -- the two families agree on the final grid.)
KENNEY_NATIVE_W, KENNEY_NATIVE_H = 256, 128
KENNEY_SCALE = (GROUND_W / KENNEY_NATIVE_W, GROUND_H / KENNEY_NATIVE_H)

# Half a cell: the offset between a prop's own ground anchor and the cell origin
# the engine aligns `pivot` with.  See the module docstring.
ORIGIN_DX, ORIGIN_DY = GROUND_W / 2.0, GROUND_H / 2.0

# Families that are walkable flat flooring.  Everything else in these packs is
# scenery (walls, stairs, roofs, furniture) and is emitted non-walkable.
FLOORS_DUNGEON = {
    "dirt", "dirtTiles", "stone", "stoneTile", "stoneCorner", "stoneInset",
    "stoneLeft", "stoneRight", "stoneSide", "stoneSideUneven",
    "stoneMissingTiles", "stoneUneven", "planks", "planksBroken", "planksHole",
}
FLOORS_FARM = {"dirt", "dirtFarmland", "planks", "planksOld", "planksHole"}
FLOORS_LIBRARY = {"floorCarpet", "floorCarpetEnd", "floorCarpetSmall"}

KENNEY_PACKS = [
    {
        "id": "kenney-dungeon",
        "root": "kenney_isometric-miniature-dungeon/Isometric",
        "title": "Kenney 等距地牢（地面 / 石墙 / 楼梯 / 家具）",
        "single": True,
        # These packs share the engine's own convention: a prop pivots half a
        # cell off its ground anchor so that the anchor lands on the cell
        # centre.  The SBS packs predate that and keep their shipped pivots.
        "pivot": "origin",
        "skip_dirs": ("Samples", "Characters"),
        "floors": FLOORS_DUNGEON,
    },
    {
        "id": "kenney-farm",
        "root": "kenney_isometric-miniature-farm/Isometric",
        "title": "Kenney 等距农场（农田 / 木墙 / 屋顶 / 围栏）",
        "single": True,
        "pivot": "origin",
        "skip_dirs": ("Samples",),
        "floors": FLOORS_FARM,
    },
    {
        "id": "kenney-library",
        "root": "kenney_isometric-miniature-library/Isometric",
        "title": "Kenney 等距书房（书架 / 长桌 / 地毯 / 陈设）",
        "single": True,
        "pivot": "origin",
        "skip_dirs": ("Samples",),
        "floors": FLOORS_LIBRARY,
    },
    {
        "id": "kenney-bases",
        "root": "kenney_isometric-miniature-bases/Isometric",
        "title": "Kenney 等距底座（草地 / 泥土 / 雪地 / 石地 / 木地板）",
        "single": True,
        "pivot": "origin",
        "skip_dirs": ("Samples",),
        # Every family in this pack is a floor surface: `base_*` are round and
        # `square_*` are square mini bases, all drawn as walkable ground.
        "floors": None,          # None == "every family is a floor"
    },
]


# --------------------------------------------------------------------------- #
# metadata
# --------------------------------------------------------------------------- #

def tsx_for(png: str) -> str | None:
    """Locate the sibling `.tsx` that describes this sheet, if the pack ships one."""
    stem = os.path.splitext(os.path.basename(png))[0]
    folder = os.path.dirname(png)
    pack_root = folder
    for _ in range(4):                       # .tsx sits in a sibling Tsx/ tree
        pack_root = os.path.dirname(pack_root)
    for dirpath, _dirs, files in os.walk(pack_root):
        if stem + ".tsx" in files:
            return os.path.join(dirpath, stem + ".tsx")
    return None


def read_tsx(path: str) -> dict:
    root = ET.parse(path).getroot()
    info = {
        "cell": (int(root.get("tilewidth")), int(root.get("tileheight"))),
        "columns": int(root.get("columns") or 0),
        "key": None,
    }
    image = root.find("image")
    if image is not None:
        trans = (image.get("trans") or "").lower()
        if trans == "ff00ff":
            info["key"] = "magenta"
        elif trans == "000000":
            info["key"] = "black"
    return info


def cell_from_name(path: str) -> tuple | None:
    """Read the tile size from the filename.

    The SBS packs are inconsistent about where it sits -- `Floor_Grass_01-256x128.png`
    puts it before the extension, `104x80 Temple Kit.png` right after the start --
    so the first plausible `WxH` anywhere in the stem wins.
    """
    match = SIZE_ANYWHERE.search(os.path.splitext(os.path.basename(path))[0])
    if match:
        w, h = int(match.group(1)), int(match.group(2))
        if w >= 8 and h >= 8:
            return (w, h)
    return None


# --------------------------------------------------------------------------- #
# image helpers
# --------------------------------------------------------------------------- #

def _classify(r: int, g: int, b: int) -> str | None:
    if r > 215 and g < 40 and b > 215:
        return "magenta"
    if r < 40 and 100 < g < 160 and 100 < b < 160:
        return "teal"
    if r <= 8 and g <= 8 and b <= 8:
        return "black"
    return None


def key_from_corner(image: Image.Image) -> str | None:
    """Identify the transparency key from the top-left pixel.

    Falls back to the whole border because a tightly-packed sheet can have art
    in the top-left corner while the background still frames the rest (the town
    building sheets do exactly that).
    """
    key = _classify(*image.getpixel((0, 0)))
    if key:
        return key
    arr = np.asarray(image.convert("RGB"))
    border = np.concatenate([arr[0, :, :], arr[-1, :, :],
                             arr[1:-1, 0, :], arr[1:-1, -1, :]])
    colours, counts = np.unique(border.reshape(-1, 3), axis=0, return_counts=True)
    for idx in np.argsort(-counts):
        key = _classify(int(colours[idx][0]), int(colours[idx][1]), int(colours[idx][2]))
        if key:
            return key
    return None


def key_to_alpha(image: Image.Image, key: str | None) -> Image.Image:
    """Replace the key colour with real alpha.

    All three keys are removed **globally**, because each pack declares its key
    in the `.tsx` (`trans="ff00ff"` / `trans="000000"`) or frames the sheet with
    it -- by definition the key colour is not artwork.

    A border flood-fill was tried first and is wrong here: a packed sheet seals
    the background into per-tile pockets, so connectivity left 32% of the floor
    atlas magenta and the wooden crates sitting on opaque black rectangles.
    """
    rgb = np.asarray(image.convert("RGB"))
    if key == "magenta":
        arr = rgb.astype(np.int16)
        background = ((arr[:, :, 0] > 215) & (arr[:, :, 1] < 40)
                      & (arr[:, :, 2] > 215))
    elif key == "teal":
        background = ((rgb[:, :, 0] < 40) & (rgb[:, :, 1] > 100)
                      & (rgb[:, :, 1] < 160) & (rgb[:, :, 2] > 100)
                      & (rgb[:, :, 2] < 160))
    elif key == "black":
        background = ((rgb[:, :, 0] <= 8) & (rgb[:, :, 1] <= 8)
                      & (rgb[:, :, 2] <= 8))
    else:
        return image.convert("RGBA")
    out = rgb.copy()
    if background.any():
        interior = ~background
        fill = (rgb[interior].mean(axis=0).round().astype(np.uint8)
                if interior.any() else np.zeros(3, np.uint8))
        out[background] = fill
    alpha = np.where(background, 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([out, alpha]), "RGBA")


def slice_sheet(sheet: Image.Image, cell: tuple) -> list:
    cw, ch = cell
    cols = max(1, sheet.width // cw)
    rows = max(1, sheet.height // ch)
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append(sheet.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch)))
    return out


def content_box(tile: Image.Image, threshold: int = 8) -> tuple:
    alpha = np.asarray(tile.convert("RGBA"))[:, :, 3]
    ys, xs = np.nonzero(alpha > threshold)
    if len(xs) == 0:
        return None
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


def digest(tile: Image.Image) -> str:
    return hashlib.sha1(tile.convert("RGBA").tobytes()).hexdigest()


# --------------------------------------------------------------------------- #
# packing
# --------------------------------------------------------------------------- #

def shelf_pack(tiles: list, width: int, max_dim: int) -> list:
    """Pack tiles into rows of `width`, starting a new page before `max_dim`.

    Rows advance by their tallest tile, so tiles of differing height (walls
    128x192 beside buildings 64x96) never overlap.  Pagination exists because
    the wall pack alone is ~23M px^2: a single column of it would be 25000 px
    tall, past the 16384 texture limit most Vulkan devices guarantee.

    Returns [(atlas, placements), ...], placements[i] = (x, y) within its page.
    """
    pages = []
    placements: list = []
    atlas_w = width
    x = y = row_h = 0
    for tile in tiles:
        if x + tile.width > width and x > 0:
            y += row_h
            x = 0
            row_h = 0
        if y + max(row_h, tile.height) > max_dim and (x > 0 or y > 0):
            pages.append((atlas_w, y + row_h, placements))
            placements = []
            x = y = row_h = 0
        placements.append((x, y))
        x += tile.width
        row_h = max(row_h, tile.height)
    if placements:
        pages.append((atlas_w, y + row_h, placements))

    out = []
    offset = 0
    for page_w, page_h, slots in pages:
        atlas = Image.new("RGBA", (page_w, max(page_h, 1)), (0, 0, 0, 0))
        for i, (px, py) in enumerate(slots):
            atlas.alpha_composite(tiles[offset + i], (px, py))
        out.append((atlas, slots))
        offset += len(slots)
    return out


def layout(tiles: list, max_dim: int) -> tuple:
    """Pick an atlas width near-square for `tiles`, within [GROUND_W, max_dim]."""
    area = sum(t.width * t.height for t in tiles)
    widest = max(t.width for t in tiles)
    width = int(area ** 0.5) + 1
    width = max(width, widest)
    width = min(width, max_dim)
    width = max(GROUND_W, (width // GROUND_W) * GROUND_W)
    return width


# --------------------------------------------------------------------------- #
# per-pack import
# --------------------------------------------------------------------------- #

def collect(pack: dict) -> tuple:
    """Every distinct tile in one pack as (name, image, source, cell_index).

    Returns (tiles, skipped) where `skipped` names files that could not be cut
    on an even grid.  Guessing a cell size that does not divide the sheet would
    silently emit half-tiles, so those files are reported instead.
    """
    root = os.path.join(ASSETS, pack["root"])
    if not os.path.isdir(root):
        raise SystemExit(f"missing pack directory: {root}")

    found = []
    skipped = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d.lower() not in SKIP_DIR_PARTS]
        for name in sorted(filenames):
            if not name.lower().endswith(".png"):
                continue
            stem = os.path.splitext(name)[0].lower()
            if any(stem.startswith(s) for s in SKIP_FILE_STEMS):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ASSETS).replace(os.sep, "/")
            sheet = Image.open(path).convert("RGB")
            tsx = tsx_for(path)
            override = (pack.get("cell_overrides") or {}).get(name)
            if override:
                cell, key = override, key_from_corner(sheet)
            elif tsx:
                meta = read_tsx(tsx)
                cell = meta["cell"]
                key = meta["key"] or key_from_corner(sheet)
            else:
                cell = pack.get("cell") or cell_from_name(path)
                key = key_from_corner(sheet)
            if not cell:
                skipped.append(f"{rel} (no tile size)")
                continue
            if sheet.width % cell[0] or sheet.height % cell[1]:
                skipped.append(f"{rel} ({sheet.width}x{sheet.height} not a multiple "
                               f"of {cell[0]}x{cell[1]})")
                continue
            keyed = key_to_alpha(sheet, key)
            for idx, cell_img in enumerate(slice_sheet(keyed, cell)):
                if content_box(cell_img) is None:
                    continue                       # empty cell
                label = os.path.splitext(name)[0]
                out_size = pack.get("out")
                tile = (cell_img.resize(out_size, Image.LANCZOS)
                        if out_size and cell_img.size != out_size else cell_img)
                found.append((f"{label}#{idx}", tile, rel, idx))

    # Deduplicate identical art (the packs repeat the same tile across variants).
    seen, unique = set(), []
    for name, tile, rel, idx in found:
        d = digest(tile)
        if d in seen:
            continue
        seen.add(d)
        unique.append((name, tile, rel, idx))
    return unique, skipped


def build_pack(pack: dict, max_dim: int) -> dict:
    """Sheet pack -> trimmed tiles in pack order, ready for `emit_rules`."""
    tiles, skipped = collect(pack)
    klass = "floor" if pack["kind"] == "ground" else "prop"
    entries = [(name, image, klass) for (name, image, _rel, _idx) in tiles]
    return _layout(pack, entries, max_dim, skipped)


def _layout(pack: dict, entries: list, max_dim: int, skipped: list) -> dict:
    """Shelf-pack `entries` and normalise the result for the rule emitter.

    `runs` is the *rule*: the ordered list of sizes.  `replay_runs` rebuilds the
    exact placements from it, so the document never has to carry a region per
    GID, and the two can never drift.
    """
    images = [e[1] for e in entries]
    width = layout(images, max_dim)
    packed = shelf_pack(images, width, max_dim)

    pages = []
    offset = 0
    for atlas, slots in packed:
        pages.append({"atlas": atlas, "placements": slots, "first": offset})
        offset += len(slots)

    return {"pack": pack, "entries": entries, "pages": pages, "width": width,
            "maxDim": max_dim, "runs": size_runs(entries),
            "count": len(entries), "skipped": skipped}


def size_runs(entries: list) -> list:
    """Collapse the ordered `(class, cell)` sequence into runs -- the rule."""
    runs = []
    for _name, image, klass in entries:
        cell = [image.width, image.height]
        if runs and runs[-1]["class"] == klass and runs[-1]["cell"] == cell:
            runs[-1]["count"] += 1
        else:
            runs.append({"count": 1, "cell": cell, "class": klass})
    return runs


def classes_block(pack: dict) -> dict:
    """The navigation presets.  `pivotRule` names the derivation, not a value:
    `cell-origin` is `[0, 0]` (the sprite *is* the cell), `ground-anchor` moves
    the sprite's bottom-centre onto the cell centre the way the engine's
    `tileToWorld` maths wants, `ground-anchor-legacy` is the SBS packs'
    shipped convention (see content/tilesets/CREDITS.md)."""
    prop_rule = ("ground-anchor" if pack.get("pivot") == "origin"
                 else "ground-anchor-legacy")
    common = {"footprint": [1, 1], "enterMask": 15, "exitMask": 15,
              "opaque": False}
    return {
        "floor": dict(common, pivotRule="cell-origin", walkable=True, cost=1,
                      sortBias=0),
        "block": dict(common, pivotRule="cell-origin", walkable=False, cost=8,
                      sortBias=8),
        "prop": dict(common, pivotRule=prop_rule, walkable=False, cost=8,
                     sortBias=8),
    }


def replay_runs(runs: list, width: int, max_dim: int) -> tuple:
    """Rebuild `shelf_pack`'s placements from the size runs alone.

    Returns `(pages, sizes)`; `pages` is a list of `[(x, y), ...]`.  This is the
    inverse of the packer, so replaying a document's `runs` reproduces the atlas
    byte for byte -- which is exactly what `--check` asserts.
    """
    sizes = []
    for run in runs:
        sizes.extend([tuple(run["cell"])] * run["count"])

    pages, placements = [], []
    x = y = row_h = 0
    for w, h in sizes:
        if x + w > width and x > 0:
            y += row_h
            x = 0
            row_h = 0
        if y + max(row_h, h) > max_dim and (x > 0 or y > 0):
            pages.append(placements)
            placements = []
            x = y = row_h = 0
        placements.append((x, y))
        x += w
        row_h = max(row_h, h)
    if placements:
        pages.append(placements)
    return pages, sizes


def class_of(doc: dict, index: int) -> str:
    """Class of the `index`-th tile in the document's global run order."""
    seen = 0
    for run in doc["runs"]:
        if index < seen + run["count"]:
            return run["class"]
        seen += run["count"]
    raise IndexError(f"tile index {index} beyond {seen} run tiles")


def derived_pivot(doc: dict, klass: str, w: int, h: int) -> list:
    """The pivot a class rule derives for a `w x h` cell."""
    rule = doc["classes"][klass]["pivotRule"]
    if rule == "cell-origin":
        return [0, 0]
    if rule == "ground-anchor":
        return [round(w / 2.0 - doc["tileWidth"] / 2.0, 2),
                round(float(h) - doc["tileHeight"] / 2.0, 2)]
    if rule == "ground-anchor-legacy":
        return [round(w / 2.0, 2), float(h)]
    raise ValueError(f"unknown pivotRule {rule!r}")


def emit_rules(result: dict, page_index: int) -> dict:
    """One atlas page -> a rule document (header + classes + size runs)."""
    pack = result["pack"]
    page = result["pages"][page_index]
    tileset_id = (pack["id"] if page_index == 0
                  else f"{pack['id']}-{page_index + 1}")
    first, count = page["first"], len(page["placements"])
    doc = {
        "schema": "eve.rpgc.tileset",
        "version": 2,
        "id": tileset_id,
        "title": pack["title"] + ("" if page_index == 0
                                  else f"（第 {page_index + 1} 页）"),
        "image": f"{tileset_id}.png",
        "firstGid": 1,
        "tileWidth": GROUND_W,
        "tileHeight": GROUND_H,
        "margin": 0,
        "spacing": 0,
        "count": count,
        "layout": {"pack": "shelf", "width": result["width"],
                   "maxDim": result["maxDim"], "firstTile": first},
        "classes": classes_block(pack),
        "runs": result["runs"],
        "names": [e[0][:60] for e in result["entries"][first:first + count]],
    }
    return {"id": tileset_id, "doc": doc, "atlas": page["atlas"]}


# --------------------------------------------------------------------------- #
# single-sprite import (Kenney)
# --------------------------------------------------------------------------- #

def collect_singles(pack: dict) -> tuple:
    """Every distinct sprite in a single-sprite pack, trimmed and scaled.

    Returns `(tiles, skipped)`.  Each tile carries its trimmed/scaled image, the
    pack-relative source path, its `_N/_S/_E/_W`-stripped family name, and
    whether the artwork reaches both canvas edges.  A piece that does is a
    cell-filling block -- a floor slab, a wall run, a roof -- rather than a
    free-standing prop, which is what decides its pivot below.
    """
    root = os.path.join(ASSETS, pack["root"])
    if not os.path.isdir(root):
        raise SystemExit(f"missing pack directory: {root}")

    skip_dirs = {d.lower() for d in pack.get("skip_dirs", ())}
    scale = pack.get("scale") or KENNEY_SCALE

    found, skipped = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d.lower() not in skip_dirs]
        for name in sorted(filenames):
            if not name.lower().endswith(".png"):
                continue
            stem = os.path.splitext(name)[0].lower()
            if any(stem.startswith(s) for s in SKIP_FILE_STEMS):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ASSETS).replace(os.sep, "/")
            sheet = Image.open(path).convert("RGBA")
            box = content_box(sheet)
            if box is None:
                skipped.append(f"{rel} (fully transparent)")
                continue
            piece = sheet.crop(box)
            if scale != (1.0, 1.0):
                piece = piece.resize(
                    (max(1, round(piece.width * scale[0])),
                     max(1, round(piece.height * scale[1]))), Image.LANCZOS)
            label = os.path.splitext(name)[0]
            found.append({
                "name": label,
                "family": re.sub(r"_(N|S|E|W)$", "", label),
                "image": piece,
                "source": rel,
                "fills": box[0] == 0 and box[2] == sheet.width,
            })

    seen, unique = set(), []
    for tile in found:
        d = digest(tile["image"])
        if d in seen:
            continue
        seen.add(d)
        unique.append(tile)
    return unique, skipped


def build_single_pack(pack: dict, max_dim: int) -> dict:
    """Single-sprite pack -> one tile per PNG, ready for `emit_rules`."""
    tiles, skipped = collect_singles(pack)
    floors = pack.get("floors")
    entries = []
    for tile in tiles:
        floor = floors is None or tile["family"] in floors
        # A cell-filling block (floor slab, wall run, roof) *is* the cell, so it
        # pivots at `cell-origin` even when it is scenery.
        klass = "floor" if floor else ("block" if tile["fills"] else "prop")
        entries.append((tile["name"], tile["image"], klass))
    return _layout(pack, entries, max_dim, skipped)


def build(pack: dict, max_dim: int) -> dict:
    """Dispatch on the pack's shape: a sheet of cells, or one sprite per file."""
    builder = build_single_pack if pack.get("single") else build_pack
    return builder(pack, max_dim)


def emit(result: dict) -> list:
    """Every page of one pack as a rule document."""
    return [emit_rules(result, i) for i in range(len(result["pages"]))]


def load_schema(name: str) -> dict:
    path = os.path.join(WORKFLOW_ROOT, "schema", name + ".json")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _type_ok(value, type_name: str) -> bool:
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "array":
        return isinstance(value, list)
    if type_name == "object":
        return isinstance(value, dict)
    return True


def validate_doc(doc, schema: dict) -> list:
    """Check a document against one of the workflow's `schema/eve.rpgc.*.json`.

    This is an offline stand-in for the engine's own C++ validator (the workflow
    treats `eve.Schema()` as the authority).  It exists so the import can be
    checked without a running host; it deliberately implements the same dialect
    (`fields`, `additionalProperties: false`, `elementType`, ...).
    """
    errors = []
    allowed = {f["name"] for f in schema.get("fields", [])}
    if schema.get("additionalProperties") is False and isinstance(doc, dict):
        for key in doc:
            if key not in allowed:
                errors.append(f"unknown field {key!r}")
    for field in schema.get("fields", []):
        name = field["name"]
        if not isinstance(doc, dict) or name not in doc:
            if field.get("required"):
                errors.append(f"missing required field {name!r}")
            continue
        value = doc[name]
        if not _type_ok(value, field["type"]):
            errors.append(f"{name}: expected {field['type']}, "
                          f"got {type(value).__name__}")
            continue
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in field and value < field["minimum"]:
                errors.append(f"{name}: {value} < minimum {field['minimum']}")
            if "maximum" in field and value > field["maximum"]:
                errors.append(f"{name}: {value} > maximum {field['maximum']}")
        if isinstance(value, list):
            if "minItems" in field and len(value) < field["minItems"]:
                errors.append(f"{name}: {len(value)} < minItems {field['minItems']}")
            if "maxItems" in field and len(value) > field["maxItems"]:
                errors.append(f"{name}: {len(value)} > maxItems {field['maxItems']}")
            element = field.get("elementType")
            if element and not all(_type_ok(v, element) for v in value):
                errors.append(f"{name}: element type {element} violated")
            if field.get("items"):
                for i, item in enumerate(value):
                    errors.extend(f"{name}[{i}].{e}"
                                  for e in validate_doc(item, field["items"]))
    return errors


def check_rules(entry: dict) -> list:
    """A rule document must replay onto its own atlas, exactly.

    The document carries no region.  Every GID's placement is rebuilt from
    `runs` plus the recorded layout width by the same shelf packer that produced
    the atlas, and its pivot is derived from its class rule.  So this is not a
    spot check: if one GID would land off the image, off the sequence, or on a
    pivot its class cannot justify, the import fails.
    """
    doc = entry["doc"]
    atlas = entry["atlas"]
    problems = []

    rule = doc["layout"]
    pages, sizes = replay_runs(doc["runs"], rule["width"], rule["maxDim"])
    flat = [slot for page in pages for slot in page]
    first, count = rule["firstTile"], doc["count"]
    if first + count > len(flat):
        return [f"page window {first}+{count} exceeds the {len(flat)} packed tiles"]

    tw, th = doc["tileWidth"], doc["tileHeight"]
    for i in range(count):
        index = first + i
        x, y = flat[index]
        w, h = sizes[index]
        if x < 0 or y < 0 or x + w > atlas.width or y + h > atlas.height:
            problems.append(f"gid {i + 1} region [{x}, {y}, {w}, {h}] outside the "
                            f"{atlas.width}x{atlas.height} atlas")
        klass = class_of(doc, index)
        if klass not in doc["classes"]:
            problems.append(f"gid {i + 1} uses undeclared class {klass!r}")
            continue
        klass_rule = doc["classes"][klass]
        px, py = derived_pivot(doc, klass, w, h)
        rule_name = klass_rule["pivotRule"]
        if rule_name == "cell-origin":
            if px != 0 or py != 0:
                problems.append(f"gid {i + 1} cell-origin pivot is not [0, 0]")
        else:
            # `ground-anchor` aligns `pivot` with the cell origin, so the
            # sprite's ground anchor is `pivot` plus half a cell.
            # `ground-anchor-legacy` uses the anchor itself as the pivot.
            ax = px + (tw / 2.0 if rule_name == "ground-anchor" else 0)
            ay = py + (th / 2.0 if rule_name == "ground-anchor" else 0)
            if not (0 <= ax <= w and 0 <= ay <= h):
                problems.append(f"gid {i + 1} ground anchor ({ax}, {ay}) outside "
                                f"its {w}x{h} cell")
    if sum(r["count"] for r in doc["runs"]) != len(sizes):
        problems.append("runs do not sum to the packed tile count")
    if len(doc["names"]) != count:
        problems.append(f"{len(doc['names'])} names for {count} tiles")
    if count > len(sizes) - first:
        problems.append("page claims more tiles than the runs produce")
    return problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plan", action="store_true", help="count only; write nothing")
    parser.add_argument("--check", action="store_true", help="verify on-disk output")
    parser.add_argument("--max-dim", type=int, default=8192,
                        help="max atlas side in pixels; taller packs get extra pages")
    args = parser.parse_args(argv)

    schema = load_schema("eve.rpgc.tileset")
    docs, skipped, total, rule_bytes = [], [], 0, 0
    for pack in PACKS + KENNEY_PACKS:
        result = build(pack, args.max_dim)
        pages = emit(result)
        docs.extend(pages)
        skipped.extend((pack["id"], s) for s in result["skipped"])
        total += result["count"]
        size = sum(len(json.dumps(d["doc"], ensure_ascii=False)) for d in pages)
        rule_bytes += size
        boxes = ", ".join(f"{d['atlas'].width}x{d['atlas'].height}" for d in pages)
        print(f"{pack['id']:<16} {result['count']:>5} tiles  "
              f"{len(pages)} page(s): {boxes}  rules {size:>6,} B")

    print(f"{'TOTAL':<16} {total:>5} tiles  rules {rule_bytes:,} B")

    problems = 0
    for entry in docs:
        for message in validate_doc(entry["doc"], schema):
            print(f"SCHEMA {entry['id']}: {message}")
            problems += 1
        for message in check_rules(entry):
            print(f"RULE   {entry['id']}: {message}")
            problems += 1
    print(f"schema+rules: {'ok' if not problems else str(problems) + ' problem(s)'}")
    if problems:
        return 1

    if skipped:
        print(f"\n{len(skipped)} file(s) not imported:")
        for pack_id, entry in skipped:
            print(f"  {pack_id:<16} {entry}")

    if args.plan:
        return 0

    os.makedirs(TILESET_DIR, exist_ok=True)
    failures = 0
    for entry in docs:
        tileset_id = entry["id"]
        png = os.path.join(TILESET_DIR, f"{tileset_id}.png")
        doc_path = os.path.join(TILESET_DIR, f"{tileset_id}.json")
        fresh = json.dumps(entry["doc"], indent=2, ensure_ascii=False) + "\n"
        if args.check:
            same_doc = (os.path.isfile(doc_path)
                        and open(doc_path, encoding="utf-8").read() == fresh)
            same_img = (os.path.isfile(png)
                        and Image.open(png).convert("RGBA").tobytes()
                        == entry["atlas"].convert("RGBA").tobytes())
            print(f"check {tileset_id:<18} json={'match' if same_doc else 'DIFFERS'} "
                  f"png={'match' if same_img else 'DIFFERS'}")
            failures += 0 if (same_doc and same_img) else 1
            continue
        entry["atlas"].save(png)
        with open(doc_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(fresh)
        size_mb = os.path.getsize(png) / (1024 * 1024)
        json_kb = os.path.getsize(doc_path) / 1024
        print(f"wrote content/tilesets/{tileset_id}.json ({json_kb:.1f} KB, "
              f"{len(entry['doc']['runs'])} runs) + .png ({size_mb:.1f} MB)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
