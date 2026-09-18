#!/usr/bin/env python3
"""Vendor the rpg-classic bestiary art and build its sprite atlases.

This is the reproducible, auditable half of "where did the enemy art come
from".  It performs three steps, all idempotent:

  1. **fetch**   download each upstream archive into ``assets/<pack>/`` and
                 verify it against a recorded SHA-256;
  2. **extract** unpack only the members the workflow uses;
  3. **build**   composite those frames into the flat atlases stored under
                 ``content/anims/``.

Every source is CC0 1.0 Universal (public domain dedication), which is the
only licence class this workflow accepts for vendored art: no attribution is
legally required, so a downstream game cannot be put in breach by a missing
credits screen.  The provenance is still recorded, in
``assets/<pack>/SOURCE.json`` and in ``content/anims/CREDITS.md``.

Usage::

    python tools/import_bestiary_assets.py            # fetch + extract + build
    python tools/import_bestiary_assets.py --check    # verify only, never write
    python tools/import_bestiary_assets.py --refresh  # re-download even if cached

``--check`` is the mode CI and a reviewing human should run: it re-hashes the
vendored archives and re-derives every atlas in memory, comparing against the
bytes on disk.  It reports drift instead of silently rewriting art.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
CONTENT_ANIMS = ROOT / "content" / "anims"

USER_AGENT = "eve-rpgc-bestiary-import/1.0 (+https://github.com/EVEngine/rpg-classic)"

# --------------------------------------------------------------------------
# Sources.  `sha256` is the hash of the upstream archive as fetched; `--check`
# refuses to proceed when the upstream bytes no longer match, which is the
# signal that a pack was re-uploaded and the atlas needs re-verifying by eye.
# --------------------------------------------------------------------------

SOURCES = [
    {
        "pack": "oga_antumdeluge_skeletons",
        "title": "Skeletons Rework",
        "version": "1.4",
        "author": "Jordan Irwin (AntumDeluge), artisticdude, LordNeo",
        "licence": "CC0-1.0",
        "licenceUrl": "https://creativecommons.org/publicdomain/zero/1.0/",
        "pageUrl": "https://opengameart.org/content/skeletons-rework",
        "fileUrl": "https://opengameart.org/sites/default/files/skeleton-1.4.zip",
        "archive": "skeleton-1.4.zip",
        "sha256": "d21ddd4a047185e8dcde83128abd0b4d410b74c36c29a45f9bf799cc017f334f",
        "members": [
            "LICENSE.txt",
            "README.txt",
            "PNG/48x64_scale2x/skeleton-NESW.png",
            "PNG/48x64_scale2x/skeleton-red_eyes-NESW.png",
            "PNG/48x64_scale2x/warrior_skeleton-NESW.png",
            "PNG/48x64_scale2x/demon_skeleton-NESW.png",
        ],
    },
    {
        "pack": "oga_darkagent_dawnbringer_monsters",
        "title": "Basic Green Monster Collection",
        "version": "1",
        "author": "darkagent (recolours of Dungeon Crawl Stone Soup tiles)",
        "licence": "CC0-1.0",
        "licenceUrl": "https://creativecommons.org/publicdomain/zero/1.0/",
        "pageUrl": "https://opengameart.org/content/basic-green-monster-collection",
        "fileUrl": "https://opengameart.org/sites/default/files/"
                   "Basic%20Green%20Monster%20Colection%20Batch%201-3_0.zip",
        "archive": "basic-green-monster-collection.zip",
        "sha256": "11a110f3ea9610a1d73ed302a6348c7bab3fd0e73bef46683aec7450894979ce",
        "members": [
            "Basic Green Monster Colection/READ ME.txt",
        ] + ["Basic Green Monster Colection/%s.png" % name for name in [
            "Bat", "Bee", "Centaur", "Death Mage Elf", "Death-Cob",
            "Dragoon", "Ghost", "Goblin", "Hell Knight", "Naga",
            "Naga Mage", "Shadow", "Soul-Eater", "Spectral-Warrior", "Vault Guard",
            "Worm", "Wraith", "Yaktaur",
        ]],
    },
]

# The undead sheets are 3 columns x 4 rows of 48x64 frames, in N/E/S/W row
# order (see the pack's README.txt: "N/E/S/W format for Stendhal", "walking:
# 12 frames (3 per direction)").  `build` therefore slices one row per facing.
UNDEAD_FRAME = (48, 64)
UNDEAD_COLUMNS = 3
UNDEAD_ROWS = ["n", "e", "s", "w"]

# Every monster the DawnBringer-palette pack names, in a fixed order so the
# atlas GID for a given monster never moves.  `Untitled-8.png` is deliberately
# omitted: it is an unnamed leftover duplicate in the source pack.
BEAST_ORDER = [
    "Bat", "Bee", "Centaur", "Death Mage Elf", "Death-Cob",
    "Dragoon", "Ghost", "Goblin", "Hell Knight", "Naga",
    "Naga Mage", "Shadow", "Soul-Eater", "Spectral-Warrior", "Vault Guard",
    "Worm", "Wraith", "Yaktaur",
]
BEAST_FRAME = (32, 32)
BEAST_COLUMNS = 5  # 18 monsters on a 5x4 grid; the last two cells stay empty.


# --------------------------------------------------------------------------
# step 1: fetch
# --------------------------------------------------------------------------

def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(source: dict, refresh: bool, check_only: bool) -> bytes:
    """Return the archive bytes, using the vendor cache when it still matches."""
    pack_dir = ASSETS / source["pack"]
    archive = pack_dir / source["archive"]
    expected = source["sha256"]

    if archive.exists() and not refresh:
        data = archive.read_bytes()
        if expected == "PLACEHOLDER" or sha256_of(data) == expected:
            print("  cached  %s (%d bytes)" % (archive.relative_to(ROOT), len(data)))
            return data
        print("  stale   %s does not match its recorded hash; re-fetching"
              % archive.relative_to(ROOT))

    request = urllib.request.Request(source["fileUrl"], headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if expected != "PLACEHOLDER" and sha256_of(data) != expected:
        raise SystemExit(
            "refusing to vendor %s: upstream bytes changed (sha256 %s, expected %s). "
            "Re-verify the pack by eye, then update SOURCES." % (
                source["pack"], sha256_of(data), expected))
    print("  fetched %s (%d bytes)" % (source["fileUrl"], len(data)))
    if not check_only:
        # Cache the verified archive so a later run (and a reviewing human) can
        # re-hash it without network access.
        pack_dir.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(data)
    return data


def write_source_record(source: dict, digest: str) -> None:
    pack_dir = ASSETS / source["pack"]
    pack_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "schema": "eve.rpgc.asset-source",
        "version": 1,
        "pack": source["pack"],
        "title": source["title"],
        # Not `version`: `version` is this record's own schema version.
        "upstreamVersion": source["version"],
        "author": source["author"],
        "licence": source["licence"],
        "licenceUrl": source["licenceUrl"],
        "pageUrl": source["pageUrl"],
        "fileUrl": source["fileUrl"],
        "archive": source["archive"],
        "sha256": digest,
        "note": ("Vendored verbatim. CC0 1.0 requires no attribution; the record "
                 "exists so the provenance can be audited and the archive "
                 "re-verified with tools/import_bestiary_assets.py --check."),
    }
    (pack_dir / "SOURCE.json").write_text(
        json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# step 2: extract
# --------------------------------------------------------------------------

def extract(source: dict, data: bytes, check_only: bool) -> None:
    pack_dir = ASSETS / source["pack"]
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        for member in source["members"]:
            target = pack_dir / member
            payload = zf.read(member)
            if check_only:
                if not target.exists() or target.read_bytes() != payload:
                    raise SystemExit("drift: %s does not match the archive" % target)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            print("  unpack  %s" % target.relative_to(ROOT))


# --------------------------------------------------------------------------
# step 3: build
# --------------------------------------------------------------------------

def _open(pack: str, member: str) -> Image.Image:
    return Image.open(ASSETS / pack / member).convert("RGBA")


def build_undead_atlas(source: dict, variant: str, check_only: bool) -> dict:
    """One atlas per skeleton variant: the source sheet is already a clean grid."""
    member = "PNG/48x64_scale2x/%s-NESW.png" % variant
    image = _open(source["pack"], member)
    width, height = image.size
    if (width, height) != (UNDEAD_FRAME[0] * UNDEAD_COLUMNS, UNDEAD_FRAME[1] * len(UNDEAD_ROWS)):
        raise SystemExit("%s has size %sx%s, expected %sx%s" % (
            member, width, height,
            UNDEAD_FRAME[0] * UNDEAD_COLUMNS, UNDEAD_FRAME[1] * len(UNDEAD_ROWS)))

    stem = "enemy-" + variant.replace("_", "-")
    write_image(CONTENT_ANIMS / (stem + ".png"), image, check_only)
    return {
        "anim": stem,
        "image": stem + ".png",
        "frame": list(UNDEAD_FRAME),
        "columns": UNDEAD_COLUMNS,
        "rows": len(UNDEAD_ROWS),
        "clips": _undead_clips(),
    }


def _undead_clips() -> list:
    """Clips for a 3x4 N/E/S/W walk sheet (see the pack README)."""
    clips = []
    for index, facing in enumerate(UNDEAD_ROWS):
        base = index * UNDEAD_COLUMNS
        clips.append({
            "id": "walk." + facing,
            "frames": [base, base + 1, base + 2],
            "fps": 6.0,
            "loop": True,
        })
    # The centre frame of each row is the pack's idle pose ("idle (center
    # frames)" in README.txt), so idle is a one-frame clip, not a re-used walk.
    clips.append({"id": "idle.s", "frames": [2 * UNDEAD_COLUMNS + 1], "fps": 1.0, "loop": True})
    clips.append({"id": "idle.n", "frames": [1], "fps": 1.0, "loop": True})
    return clips


def build_beast_atlas(source: dict, check_only: bool) -> dict:
    """Composite every named 32x32 monster into one flat grid atlas."""
    rows = (len(BEAST_ORDER) + BEAST_COLUMNS - 1) // BEAST_COLUMNS
    sheet = Image.new("RGBA", (BEAST_FRAME[0] * BEAST_COLUMNS, BEAST_FRAME[1] * rows),
                      (0, 0, 0, 0))
    clips = []
    for index, name in enumerate(BEAST_ORDER):
        image = _open(source["pack"],
                      "Basic Green Monster Colection/%s.png" % name)
        if image.size != BEAST_FRAME:
            raise SystemExit("%s is %s, expected %s" % (name, image.size, BEAST_FRAME))
        sheet.paste(image, ((index % BEAST_COLUMNS) * BEAST_FRAME[0],
                            (index // BEAST_COLUMNS) * BEAST_FRAME[1]))
        clips.append({
            "id": _clip_id(name),
            "title": name,
            "frames": [index],
            "fps": 1.0,
            "loop": True,
        })
    stem = "enemy-beasts"
    write_image(CONTENT_ANIMS / (stem + ".png"), sheet, check_only)
    return {
        "anim": stem,
        "image": stem + ".png",
        "frame": list(BEAST_FRAME),
        "columns": BEAST_COLUMNS,
        "rows": rows,
        "clips": clips,
    }


def _clip_id(name: str) -> str:
    out = []
    for char in name.lower():
        if char.isalnum():
            out.append(char)
        elif out and out[-1] != "-":
            out.append("-")
    return "".join(out).strip("-")


def write_image(path: Path, image: Image.Image, check_only: bool) -> None:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    payload = buffer.getvalue()
    if check_only:
        if not path.exists() or path.read_bytes() != payload:
            raise SystemExit("drift: %s is not what the sources produce" % path)
        print("  ok      %s (%d bytes)" % (path.relative_to(ROOT), len(payload)))
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    print("  build   %s (%dx%d, %d bytes)"
          % (path.relative_to(ROOT), image.size[0], image.size[1], len(payload)))


# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify vendored bytes and atlases; write nothing")
    parser.add_argument("--refresh", action="store_true",
                        help="re-download even when the cache still matches")
    parser.add_argument("--print-atlases", action="store_true",
                        help="print the derived atlas geometry as JSON")
    args = parser.parse_args()

    if args.check and args.refresh:
        parser.error("--check and --refresh are mutually exclusive")

    atlases = []
    for source in SOURCES:
        print("[%s] %s (%s)" % (source["pack"], source["title"], source["licence"]))
        data = fetch(source, args.refresh, args.check)
        digest = sha256_of(data)
        if source["sha256"] == "PLACEHOLDER":
            print("  record  sha256 %s  <- paste into SOURCES" % digest)
        extract(source, data, args.check)
        if not args.check:
            write_source_record(source, digest)

        if source["pack"] == "oga_antumdeluge_skeletons":
            for variant in ["skeleton", "skeleton-red_eyes", "warrior_skeleton", "demon_skeleton"]:
                atlases.append(build_undead_atlas(source, variant, args.check))
        else:
            atlases.append(build_beast_atlas(source, args.check))

    if args.print_atlases:
        print(json.dumps(atlases, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
