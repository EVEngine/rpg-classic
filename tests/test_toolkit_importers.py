import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from rpgc_toolkit.importers import animation_candidate, inspect_wav, trim_wav


class ImporterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / 'sheet.png'
        self.image.write_bytes(b'\x89PNG\r\n\x1a\n\0\0\0\rIHDR' + struct.pack('>II', 34, 50))
        self.clips = [dict(id='walk', frames=[0, 1, 2, 3], fps=8.0, loop=True,
                           events=[dict(frame=2, name='footstep')])]

    def candidate(self, **options):
        args = dict(document_id='imported-hero', image_reference='sheet.png',
                    frame_width=16, frame_height=24, clips=self.clips, margin=1)
        args.update(options)
        return animation_candidate(self.image, **args)

    def wav(self, width, channels=2):
        source = self.root / f'source-{width}-{channels}.wav'
        data = bytes(range(10 * width * channels))
        with wave.open(str(source), 'wb') as writer:
            writer.setparams((channels, width, 22050, 0, 'NONE', 'not compressed'))
            writer.writeframes(data)
        return source, data

    def test_animation_grid_and_detached_clips(self):
        doc = self.candidate(title='导入角色')
        self.assertEqual((doc['columns'], doc['rows']), (2, 2))
        self.assertEqual(doc['schema'], 'eve.rpgc.anim')
        doc['clips'][0]['frames'].append(0)
        self.assertEqual(len(self.clips[0]['frames']), 4)
        self.assertEqual(len(list(self.root.iterdir())), 1)

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'set RPGC_TEST_EVE for real VM validation')
    def test_animation_candidate_passes_real_vm(self):
        from rpgc_toolkit.runtime import run_headless
        raw = json.dumps(json.dumps(self.candidate(), ensure_ascii=False), ensure_ascii=False)
        source = ('local candidate = RpgcJson.parse(' + raw + ').value;'
                  'RpgcToolkitResult <- RpgcValidate.reportJson('
                  'RpgcValidate.validateDocument("anim", candidate));')
        result = run_headless(os.environ['RPGC_TEST_EVE'], Path(__file__).resolve().parents[1], source)
        self.assertTrue(result['ok'], result)

    def test_animation_rejects_partial_grid_and_bad_fields(self):
        for options in [dict(frame_width=15), dict(frame_width=True), dict(image_reference='/tmp/x'),
                        dict(clips=[dict(id='x', frames=[4], fps=4)]),
                        dict(clips=[dict(id='x', frames=[0], fps=float('nan'))]),
                        dict(clips=[dict(id='x', frames=[0], fps=4, unknown=True)])]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.candidate(**options)

    def test_all_pcm_depths_preserve_exact_frame_bytes(self):
        for width in [1, 2, 3, 4]:
            with self.subTest(width=width):
                source, data = self.wav(width)
                info = inspect_wav(source)
                self.assertEqual(info['bitsPerSample'], width * 8)
                self.assertEqual(info['frames'], 10)
                output = self.root / f'trim-{width}.wav'
                result = trim_wav(source, output, 2, 7)
                self.assertEqual((result['frames'], result['channels'], result['sampleRate']), (5, 2, 22050))
                with wave.open(str(output), 'rb') as reader:
                    self.assertEqual(reader.readframes(20), data[2 * 2 * width:7 * 2 * width])
                with wave.open(str(source), 'rb') as reader:
                    self.assertEqual(reader.readframes(20), data)

    def test_trim_ranges_and_overwrite(self):
        source, _ = self.wav(2, 1)
        for start, end in [(-1, 2), (2, 2), (3, 2), (0, 11), (False, 2), (1, 2.5)]:
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                trim_wav(source, self.root / 'out.wav', start, end)
        trim_wav(source, self.root / 'out.wav', 0, 10)
        with self.assertRaises(ValueError):
            trim_wav(source, self.root / 'out.wav', 0, 10)

    def test_truncated_audio_rejected(self):
        source, _ = self.wav(3)
        source.write_bytes(source.read_bytes()[:-1])
        with self.assertRaises(ValueError):
            inspect_wav(source)
        with self.assertRaises(ValueError):
            trim_wav(source, self.root / 'bad.wav', 0, 1)
        self.assertFalse((self.root / 'bad.wav').exists())

    def test_output_project_protection_and_symlinks(self):
        source, _ = self.wav(1)
        (self.root / 'workflow.json').write_text('{}')
        (self.root / 'content').mkdir()
        with self.assertRaises(ValueError):
            trim_wav(source, self.root / 'content/out.wav', 0, 1)
        (self.root / 'dist').mkdir()
        trim_wav(source, self.root / 'dist/out.wav', 0, 1)
        link = self.root / 'linked.wav'
        link.symlink_to(source)
        with self.assertRaises(ValueError):
            inspect_wav(link)
        (self.root / 'linked-dir').symlink_to(self.root / 'dist', target_is_directory=True)
        with self.assertRaises(ValueError):
            trim_wav(source, self.root / 'linked-dir/other.wav', 0, 1)


if __name__ == '__main__':
    unittest.main()
