#!/usr/bin/env python3
"""Generate original procedural development fallback sprites (not final art).

No external images, downloads, fonts, or image libraries are used. These simple
single-facing RGBA sprites fill the five existing animation contracts; they do
not provide multidirectional production character artwork. Replace them with
commissioned/approved art when ready. The animation JSON and clips are unchanged.

Run `python tools/build_placeholder_anims.py` to generate, or `--check` to compare
all five files against the exact reproducible output without writing anything.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import tempfile
import zlib

NAMES = ('hero', 'blade', 'palm', 'fireball', 'thunder')
ROOT = Path(__file__).resolve().parents[1]


class Pixels:
    def __init__(self, width, height):
        self.width, self.height = width, height
        self.data = bytearray(width * height * 4)

    def dot(self, x, y, color):
        if 0 <= x < self.width and 0 <= y < self.height:
            offset = (y * self.width + x) * 4
            self.data[offset:offset + 4] = bytes(color)

    def box(self, x0, y0, x1, y1, color):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.dot(x, y, color)

    def circle(self, cx, cy, radius, color, ring=False):
        for y in range(cy - radius, cy + radius + 1):
            for x in range(cx - radius, cx + radius + 1):
                distance = (x - cx) ** 2 + (y - cy) ** 2
                if distance <= radius * radius and (not ring or distance >= (radius - 1) ** 2):
                    self.dot(x, y, color)

    def line(self, x0, y0, x1, y1, color, thickness=1):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        error = dx + dy
        while True:
            self.box(x0, y0, x0 + thickness - 1, y0 + thickness - 1, color)
            if x0 == x1 and y0 == y1:
                break
            doubled = 2 * error
            if doubled >= dy:
                error += dy
                x0 += sx
            if doubled <= dx:
                error += dx
                y0 += sy


OUTLINE = (25, 31, 50, 255)
SKIN = (244, 189, 136, 255)
LIGHT = (255, 246, 209, 255)


def _character(name, frame):
    image = Pixels(32, 48)
    bob = frame % 2
    # Every pose keeps a stable foot origin; limb endpoints show the action.
    body = {'hero': (56, 116, 187, 255), 'blade': (174, 57, 69, 255), 'palm': (37, 151, 136, 255)}[name]
    hip_y = 32 + bob
    stride = (0, 2, 4, -2, 3, -3, 1, -1)[frame]
    image.line(13, hip_y, 11 + stride, 42, OUTLINE, 3)
    image.line(18, hip_y, 20 - stride, 42, OUTLINE, 3)
    image.box(10 + stride, 43, 14 + stride, 44, OUTLINE)
    image.box(19 - stride, 43, 23 - stride, 44, OUTLINE)
    image.box(9, 18 + bob, 22, 34 + bob, OUTLINE)
    image.box(10, 19 + bob, 21, 32 + bob, body)
    image.box(10, 29 + bob, 21, 30 + bob, LIGHT)
    image.circle(16, 12 + bob, 7, OUTLINE)
    image.circle(16, 12 + bob, 5, SKIN)
    image.box(10, 6 + bob, 21, 9 + bob, OUTLINE)
    image.dot(18, 12 + bob, OUTLINE)
    image.line(7, 20 + bob, 5 + frame % 3, 28 - frame % 2, body, 3)
    image.circle(6 + frame % 3, 29 - frame % 2, 2, SKIN)
    if name == 'hero':
        hand = [(24, 28), (25, 27), (25, 24), (23, 30), (25, 20), (29, 24), (23, 14), (25, 12)][frame]
        image.line(21, 20 + bob, *hand, body, 2)
        image.circle(*hand, 2, SKIN)
        if frame in (4, 5):
            image.line(hand[0], hand[1], 30, 11 + (frame - 4) * 17, LIGHT, 2)
        if frame >= 6:
            image.circle(25, 8, 3 + frame % 2, (110, 206, 255, 170), ring=True)
            image.dot(25, 8, LIGHT)
    elif name == 'blade':
        hand = [(24, 28), (25, 27), (24, 24), (25, 18), (22, 15), (28, 23), (22, 29), (23, 27)][frame]
        tip = [(27, 12), (28, 11), (28, 9), (23, 4), (12, 3), (31, 13), (30, 39), (28, 11)][frame]
        image.line(21, 20 + bob, *hand, body, 2)
        image.line(*hand, *tip, (166, 219, 235, 255), 2)
        image.circle(*hand, 2, SKIN)
        if 4 <= frame <= 6:
            image.line(25, 5 + (frame - 4) * 12, 30, 10 + (frame - 4) * 12, (255, 211, 132, 180), 2)
    else:
        hand = [(24, 28), (25, 27), (24, 22), (25, 20), (27, 19), (29, 18), (24, 13), (25, 12)][frame]
        image.line(21, 20 + bob, *hand, body, 2)
        image.circle(*hand, 2, SKIN)
        if frame >= 2:
            image.circle(*hand, 3 + frame % 3, (100, 255, 190, 150), ring=True)
            image.dot(hand[0] + 1, hand[1] - 1, LIGHT)
        if frame >= 6:
            image.line(3, 7 + frame % 2, 7, 7 + frame % 2, (100, 255, 190, 180))
            image.line(5, 5, 5, 10, (100, 255, 190, 180))
    return image


def _effect(name, frame):
    image = Pixels(32, 32)
    if name == 'fireball':
        radius = (4, 6, 6, 7, 9, 11, 13, 7)[frame]
        cx = 17 if frame in (2, 3) else 16
        image.circle(cx, 16, radius, (236, 70 + frame * 9, 24, 180))
        image.circle(cx + 1, 16, max(2, radius - 3), (255, 176, 39, 255))
        image.circle(cx + 2, 15, max(1, radius - 5), (255, 244, 163, 255))
        for spark in range(5):
            x = 3 + ((spark * 7 + frame * 3) % 26)
            y = 3 + ((spark * 11 + frame * 5) % 26)
            image.line(x, y, x + 1, y - 2, (255, 207, 81, 200))
        if frame in (2, 3):
            image.line(1, 12 + frame, 12, 16, (255, 102, 32, 160), 2)
    else:
        shift = frame % 3 - 1
        points = [(19 + shift, 2), (12 - shift, 12), (20 + shift, 12), (10 + shift, 28)]
        for a, b in zip(points, points[1:]):
            image.line(*a, *b, (119, 118, 255, 130), 4)
            image.line(*a, *b, (200, 236, 255, 255), 2)
        image.line(16, 14, 5 + frame % 4, 7 + frame, (137, 197, 255, 220))
        if frame < 2:
            image.circle(17, 15, 8 + frame * 2, (144, 169, 255, 160), ring=True)
        elif frame >= 5:
            image.circle(14, 24, 5 + frame - 5, (194, 223, 255, 180), ring=True)
            image.line(4, 28 - frame % 2, 26, 28 - frame % 2, (150, 190, 255, 190))
    return image


def _chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def encode_png(image):
    """RGBA8, non-interlaced, filter 0; no timestamps or external metadata."""
    raw = b''.join(b'\0' + bytes(image.data[y * image.width * 4:(y + 1) * image.width * 4]) for y in range(image.height))
    # Stored DEFLATE blocks avoid compressor-version-dependent byte changes.
    compressed = bytearray(b'\x78\x01')
    for start in range(0, len(raw), 65535):
        block = raw[start:start + 65535]
        compressed.append(1 if start + len(block) == len(raw) else 0)
        compressed.extend(struct.pack('<HH', len(block), 65535 - len(block)))
        compressed.extend(block)
    compressed.extend(struct.pack('>I', zlib.adler32(raw) & 0xffffffff))
    return (b'\x89PNG\r\n\x1a\n'
            + _chunk(b'IHDR', struct.pack('>IIBBBBB', image.width, image.height, 8, 6, 0, 0, 0))
            + _chunk(b'tEXt', b'Description\0Original procedural development fallback; not final artwork.')
            + _chunk(b'IDAT', bytes(compressed)) + _chunk(b'IEND', b''))


def generate(name, document):
    if name not in NAMES:
        raise ValueError('unknown fallback animation')
    height = 48 if name in ('hero', 'blade', 'palm') else 32
    expected = {'image': name + '.png', 'frameWidth': 32, 'frameHeight': height,
                'columns': 4, 'rows': 2, 'margin': 0, 'spacing': 0}
    if any(document.get(key, 0 if key in ('margin', 'spacing') else None) != value for key, value in expected.items()):
        raise ValueError(f'{name}: animation grid changed; review fallback generator before regenerating')
    atlas = Pixels(128, height * 2)
    for index in range(8):
        frame = _character(name, index) if height == 48 else _effect(name, index)
        ox, oy = index % 4 * 32, index // 4 * height
        for y in range(height):
            start = ((oy + y) * atlas.width + ox) * 4
            atlas.data[start:start + 128] = frame.data[y * 128:(y + 1) * 128]
    return encode_png(atlas)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    directory = args.root / 'content/anims'
    failed = False
    for name in NAMES:
        document = json.loads((directory / (name + '.json')).read_text(encoding='utf-8'))
        data = generate(name, document)
        target = directory / document['image']
        if args.check:
            current = target.is_file() and target.read_bytes() == data
            print(f'{name}: {"current" if current else "MISSING/STALE"}')
            failed |= not current
        else:
            with tempfile.NamedTemporaryFile(dir=directory, prefix='.fallback-', suffix='.tmp', delete=False) as handle:
                temporary = Path(handle.name)
                handle.write(data)
            try:
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
            print(f'{name}: generated original procedural development fallback')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
