import contextlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build_placeholder_anims import NAMES, generate, main


def decode(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, chunks, compressed = 8, [], bytearray()
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        assert crc == zlib.crc32(kind + payload) & 0xffffffff
        chunks.append(kind)
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
        if kind == b'IDAT':
            compressed.extend(payload)
        offset += length + 12
    assert offset == len(data) and chunks[0] == b'IHDR' and chunks[-1] == b'IEND'
    raw = zlib.decompress(compressed)
    assert len(raw) == (width * 4 + 1) * height
    rows = []
    for y in range(height):
        begin = y * (width * 4 + 1)
        assert raw[begin] == 0
        rows.append(raw[begin + 1:begin + 1 + width * 4])
    return width, height, rows


class PlaceholderTests(unittest.TestCase):
    def test_png_crc_dimensions_frames_and_reproducibility(self):
        for name in NAMES:
            with self.subTest(name=name):
                document = json.loads((ROOT / 'content/anims' / (name + '.json')).read_text())
                data = generate(name, document)
                self.assertEqual(data, generate(name, document))
                self.assertEqual(data, (ROOT / 'content/anims' / document['image']).read_bytes())
                width, height, rows = decode(data)
                fw, fh = document['frameWidth'], document['frameHeight']
                self.assertEqual((width, height), (fw * 4, fh * 2))
                frames = []
                for index in range(8):
                    x, y = index % 4 * fw, index // 4 * fh
                    frame = b''.join(row[x * 4:(x + fw) * 4] for row in rows[y:y + fh])
                    alphas = frame[3::4]
                    self.assertTrue(any(alphas), f'{name} frame {index} is empty')
                    self.assertIn(0, alphas, f'{name} frame {index} needs transparent background')
                    frames.append(frame)
                self.assertEqual(len(set(frames)), 8, f'{name} needs distinct poses/effect phases')

    def test_check_is_read_only_and_detects_stale(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory = root / 'content/anims'
            directory.mkdir(parents=True)
            for name in NAMES:
                (directory / (name + '.json')).write_bytes((ROOT / 'content/anims' / (name + '.json')).read_bytes())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--root', str(root), '--check']), 1)
                self.assertFalse(list(directory.glob('*.png')))
                self.assertEqual(main(['--root', str(root)]), 0)
                self.assertEqual(main(['--root', str(root), '--check']), 0)
                path = directory / 'hero.png'
                path.write_bytes(b'stale')
                self.assertEqual(main(['--root', str(root), '--check']), 1)
                self.assertEqual(path.read_bytes(), b'stale')

    def test_contract_change_requires_review(self):
        document = json.loads((ROOT / 'content/anims/hero.json').read_text())
        for key, value in [('columns', 5), ('frameWidth', 64), ('image', '../other.png')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                generate('hero', dict(document, **{key: value}))


if __name__ == '__main__':
    unittest.main()
