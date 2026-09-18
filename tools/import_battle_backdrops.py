#!/usr/bin/env python3
"""Vendor the rpg-classic battle backdrops from CC0 upstream packs.

This is the reproducible, auditable half of "where did the battle scenery come
from".  It follows ``tools/import_bestiary_assets.py``: every source is pinned
by SHA-256, the upstream bytes are cached under ``assets/<pack>/``, and
``--check`` re-derives every output in memory and compares it byte-for-byte
with what is on disk.  Drift becomes a failed check, never a silent art swap.

Steps, all idempotent:

  1. **fetch**   download each upstream member into ``assets/<pack>/`` and
                 verify it against the recorded SHA-256;
  2. **extract** unpack the used members from the upstream container (an
                 upstream member that is itself a bare image is its own member);
  3. **build**   crop each source to 16:9 and scale it to :data:`TARGET_SIZE`,
                 then write it under ``content/battles/backdrops/``.

Every source is CC0 1.0 Universal (public domain dedication), the only licence
class this workflow accepts for vendored art: no attribution is legally
required, so a downstream game cannot be put in breach by a missing credits
screen.  Provenance is still recorded, in ``assets/<pack>/SOURCE.json`` and in
``content/battles/backdrops/CREDITS.md`` -- for auditability, not as a licence
condition.

Usage::

    python tools/import_battle_backdrops.py            # fetch + extract + build
    python tools/import_battle_backdrops.py --check    # verify only, never write
    python tools/import_battle_backdrops.py --refresh  # re-download even if cached
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
CONTENT_BACKDROPS = ROOT / "content" / "battles" / "backdrops"

USER_AGENT = "eve-rpgc-backdrop-import/1.0 (+https://github.com/EVEngine/rpg-classic)"

LICENCE_URL = "https://creativecommons.org/publicdomain/zero/1.0/"

# Every output is normalised to this size.  The workflow's battle canvas is
# 1920x1080 (see `canvas` in content/battles/battle.*.json), but the upstream
# paintings are 1000x700 (10:7).  A backdrop set that mixes aspect ratios
# cannot be laid out by one battle scene, so each source is centre-cropped to
# 16:9 and resampled up to the canvas size with Lanczos: cropping preserves the
# composition, while a non-uniform resize would stretch it.  Upscaling invents
# no structure -- it only interpolates existing pixels.
TARGET_SIZE = (1920, 1080)
TARGET_RATIO = TARGET_SIZE[0] / TARGET_SIZE[1]

# --------------------------------------------------------------------------
# Sources.  `sha256`/`bytes` pin the bytes *inside* the upstream container,
# which is what `--check` re-verifies, so a re-upload is caught even when the
# container is served with a different hash.  `backdrop` names the terrain the
# image depicts, because that is how a battle document references it.
# --------------------------------------------------------------------------

SOURCES = [
    {
        "pack": "oga_jap_oil_painting_landscapes",
        "title": "Oil painting landscapes",
        "author": "JAP",
        "licence": "CC0-1.0",
        "licenceUrl": LICENCE_URL,
        "pageUrl": "https://opengameart.org/content/oil-painting-landscapes",
        "container": "image",
        "files": [
            {
                "member": "coldmountain.png",
                "fileUrl": "https://opengameart.org/sites/default/files/coldmountain.png",
                "sha256": "6714ff67f67c3a566756e303161cb47f2abab1ba3a3091e5e7c54a4a9b0377e7",
                "bytes": 783620,
                "backdrop": "backdrop.snow-mountain-pass.png",
            },
            {
                "member": "sunsetintheswamp.png",
                "fileUrl": "https://opengameart.org/sites/default/files/sunsetintheswamp.png",
                "sha256": "f43381c78a89598ab0bbd9837f79ab81ba8916bbb9bd40f6dc60e6f901acd143",
                "bytes": 691476,
                "backdrop": "backdrop.golden-plain.png",
            },
            {
                "member": "cloudsinthedesert.png",
                "fileUrl": "https://opengameart.org/sites/default/files/cloudsinthedesert.png",
                "sha256": "831ea265c85ef5ab508bcbd85517ecac8a5399f865af416288906b4b751c745f",
                "bytes": 606663,
                "backdrop": "backdrop.desert.png",
            },
        ],
    },
    {
        "pack": "oga_rh0_few_water_backgrounds",
        "title": "Few Water Backgrounds (1366x768)",
        "author": "rh0",
        "licence": "CC0-1.0",
        "licenceUrl": LICENCE_URL,
        "pageUrl": "https://opengameart.org/content/few-water-backgrounds-1366%C3%97768",
        "container": "image",
        "files": [
            {
                "member": "water1_1.png",
                "fileUrl": "https://opengameart.org/sites/default/files/water1_1.png",
                "sha256": "c13105015b73461150c0377e5bd3d279eef93baefa112295693b60a047749088",
                "bytes": 612204,
                "backdrop": "backdrop.waterfront.png",
            },
        ],
    },
]


# --------------------------------------------------------------------------
# step 1: fetch
# --------------------------------------------------------------------------

def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(source: dict, entry: dict, refresh: bool, check_only: bool) -> bytes:
    """Return one upstream member's bytes, using the vendor cache if it matches."""
    pack_dir = ASSETS / source["pack"]
    archive = pack_dir / entry["member"]
    expected = entry["sha256"]

    if archive.exists() and not refresh:
        data = archive.read_bytes()
        if expected == "PLACEHOLDER" or sha256_of(data) == expected:
            print("  cached  %s (%d bytes)" % (archive.relative_to(ROOT), len(data)))
            return data
        print("  stale   %s does not match its recorded hash; re-fetching"
              % archive.relative_to(ROOT))

    request = urllib.request.Request(entry["fileUrl"], headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        data = response.read()
    if expected != "PLACEHOLDER" and sha256_of(data) != expected:
        raise SystemExit(
            "refusing to vendor %s::%s: upstream bytes changed (sha256 %s, expected %s). "
            "Re-verify the pack by eye, then update SOURCES." % (
                source["pack"], entry["member"], sha256_of(data), expected))
    print("  fetched %s (%d bytes)" % (entry["fileUrl"], len(data)))
    if not check_only:
        # Cache the verified upstream file so a later run (and a reviewing
        # human) can re-hash it without network access.
        pack_dir.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(data)
    return data


def write_source_record(source: dict) -> None:
    """Record one pack's provenance, including the per-member digests."""
    pack_dir = ASSETS / source["pack"]
    pack_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "schema": "eve.rpgc.asset-source",
        "version": 1,
        "pack": source["pack"],
        "title": source["title"],
        "author": source["author"],
        "licence": source["licence"],
        "licenceUrl": source["licenceUrl"],
        "pageUrl": source["pageUrl"],
        "container": source["container"],
        "files": [dict(entry) for entry in source["files"]],
        "note": ("Vendored verbatim. CC0 1.0 requires no attribution; the record "
                 "exists so the provenance can be audited and the upstream bytes "
                 "re-verified with tools/import_battle_backdrops.py --check."),
    }
    (pack_dir / "SOURCE.json").write_text(
        json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# step 2: extract
# --------------------------------------------------------------------------

def member_bytes(source: dict, entry: dict, data: bytes) -> bytes:
    """Return the raw bytes of one member inside the upstream container."""
    if source["container"] == "zip":
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            return zf.read(entry["member"])
    # A bare image member: the upstream file *is* the member.
    return data


def extract(source: dict, entry: dict, data: bytes, check_only: bool) -> bytes:
    """Cache one member and re-hash it against its recorded digest."""
    payload = member_bytes(source, entry, data)
    digest = sha256_of(payload)
    if digest != entry["sha256"]:
        raise SystemExit("member %s::%s has sha256 %s, expected %s" % (
            source["pack"], entry["member"], digest, entry["sha256"]))
    if len(payload) != entry["bytes"]:
        raise SystemExit("member %s::%s is %d bytes, expected %d" % (
            source["pack"], entry["member"], len(payload), entry["bytes"]))
    target = ASSETS / source["pack"] / entry["member"]
    if check_only:
        if not target.exists() or target.read_bytes() != payload:
            raise SystemExit("drift: %s does not match the upstream file" % target)
        return payload
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    print("  unpack  %s (%d bytes)" % (target.relative_to(ROOT), len(payload)))
    return payload


# --------------------------------------------------------------------------
# step 3: build
# --------------------------------------------------------------------------

def render_backdrop(payload: bytes) -> Image.Image:
    """Centre-crop one source to 16:9 and scale it to :data:`TARGET_SIZE`."""
    with Image.open(io.BytesIO(payload)) as opened:
        image = opened.convert("RGBA")
    width, height = image.size
    if width / height > TARGET_RATIO:
        crop_w = int(round(height * TARGET_RATIO))
        box = ((width - crop_w) // 2, 0, (width - crop_w) // 2 + crop_w, height)
    else:
        crop_h = int(round(width / TARGET_RATIO))
        box = (0, (height - crop_h) // 2, width, (height - crop_h) // 2 + crop_h)
    cropped = image.crop(box)
    if cropped.size != TARGET_SIZE:
        cropped = cropped.resize(TARGET_SIZE, Image.LANCZOS)
    return cropped


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
                        help="verify cached bytes and derived backdrops; write nothing")
    parser.add_argument("--refresh", action="store_true",
                        help="re-download even when the cache still matches")
    parser.add_argument("--print-backdrops", action="store_true",
                        help="print the derived backdrop list as JSON")
    args = parser.parse_args()

    if args.check and args.refresh:
        parser.error("--check and --refresh are mutually exclusive")

    outputs = []
    for source in SOURCES:
        print("[%s] %s (%s)" % (source["pack"], source["title"], source["licence"]))
        for entry in source["files"]:
            data = fetch(source, entry, args.refresh, args.check)
            if entry["sha256"] == "PLACEHOLDER":
                print("  record  sha256 %s  <- paste into SOURCES" % sha256_of(data))
            payload = extract(source, entry, data, args.check)
            image = render_backdrop(payload)
            write_image(CONTENT_BACKDROPS / entry["backdrop"], image, args.check)
            outputs.append({
                "backdrop": entry["backdrop"][:-len(".png")],
                "image": entry["backdrop"],
                "source": entry["member"],
                "pack": source["pack"],
                "width": image.size[0],
                "height": image.size[1],
            })
        if not args.check:
            write_source_record(source)

    if args.print_backdrops:
        print(json.dumps(outputs, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
