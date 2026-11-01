import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from rpgc_toolkit.packaging import package_project, verify_package, _publish_directory, MANIFEST


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rpgc package tests ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.project, self.sdk = self.base / 'source game', self.base / 'SDK input'
        self.project.mkdir()
        self.sdk.mkdir()
        (self.project / 'workflow.json').write_text('{"kinds":{}}')
        (self.project / 'main.nut').write_text('print("stub");')
        (self.project / 'content').mkdir()
        (self.project / 'content/document.json').write_text('{}')
        (self.sdk / 'bin').mkdir()
        for name in ['eve', 'eve.exe']:
            (self.sdk / 'bin' / name).write_bytes(b'not executed')
        (self.sdk / 'share/eve').mkdir(parents=True)
        (self.sdk / 'share/eve/resource.txt').write_text('sdk resource')
        self.output = self.base / 'published game'

    def test_all_platforms_quote_paths_and_verify_without_execution(self):
        for platform in ['linux', 'macos', 'windows']:
            with self.subTest(platform=platform):
                output = self.base / ('published ' + platform)
                result = package_project(self.project, self.sdk, output, platform)
                self.assertFalse(result['validated'])
                self.assertFalse(result['osDependenciesBundled'])
                self.assertTrue(verify_package(output)['ok'])
                self.assertEqual((output / 'engine/share/eve/resource.txt').read_text(), 'sdk resource')
                launcher = Path(result['launcher']).read_text()
                if platform == 'windows':
                    self.assertIn('"%~dp0engine\\bin\\eve.exe" run . %*', launcher)
                    self.assertIn('pushd "%~dp0game"', launcher)
                else:
                    self.assertIn('"$RPGC_PACKAGE_ROOT/engine/bin/eve" run . "$@"', launcher)
                    self.assertIn('cd "$RPGC_PACKAGE_ROOT/game"', launcher)
                    self.assertTrue((output / 'engine/bin/eve').stat().st_mode & stat.S_IXUSR)

    def test_source_exclusions_and_output_contract(self):
        for dirname in ['.git', '__pycache__', 'dist', 'build']:
            (self.project / dirname).mkdir()
            (self.project / dirname / 'ignored').write_text('excluded')
        (self.project / 'eve.log').write_text('excluded')
        first = self.project / 'dist/first'
        package_project(self.project, self.sdk, first, 'linux')
        second = self.project / 'dist/second'
        package_project(self.project, self.sdk, second, 'linux')
        self.assertFalse((second / 'game/dist').exists())
        self.assertFalse((second / 'game/eve.log').exists())
        self.assertFalse((second / 'game/.git').exists())
        with self.assertRaises(ValueError):
            package_project(self.project, self.sdk, self.project / 'content/package', 'linux')
        with self.assertRaises(ValueError):
            package_project(self.project, self.sdk, first, 'linux')

    def test_sdk_symlink_and_wrong_platform_rejected(self):
        (self.sdk / 'share/escape').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):
            package_project(self.project, self.sdk, self.output, 'linux')
        self.assertFalse(self.output.exists())
        (self.sdk / 'share/escape').unlink()
        (self.sdk / 'bin/eve.exe').unlink()
        with self.assertRaises(ValueError):
            package_project(self.project, self.sdk, self.output, 'windows')
        with self.assertRaises(ValueError):
            package_project(self.project, self.sdk, self.output, 'android')

    def test_failure_cleans_staging(self):
        with patch('rpgc_toolkit.packaging.shutil.copy2', side_effect=OSError('disk failure')):
            with self.assertRaises(OSError):
                package_project(self.project, self.sdk, self.output, 'linux')
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.base.glob('.rpgc-package-*')))

    def test_atomic_publish_never_overwrites_existing_directory(self):
        source, dest = self.base / 'ready', self.base / 'existing'
        source.mkdir()
        dest.mkdir()
        with self.assertRaises(OSError):
            _publish_directory(source, dest)
        self.assertTrue(source.exists())
        self.assertTrue(dest.exists())

    def test_verify_tamper_extra_symlink_and_malformed_manifest(self):
        package_project(self.project, self.sdk, self.output, 'linux')
        (self.output / 'game/main.nut').write_text('tampered')
        self.assertFalse(verify_package(self.output)['ok'])
        (self.output / 'game/main.nut').write_text('print("stub");')
        (self.output / 'extra').write_text('unexpected')
        self.assertFalse(verify_package(self.output)['ok'])
        (self.output / 'extra').unlink()
        (self.output / 'extra').symlink_to('/etc/passwd')
        self.assertFalse(verify_package(self.output)['ok'])
        (self.output / 'extra').unlink()
        for malformed in [None, [], {'format': 'rpgc-sdk-package', 'version': 1, 'platform': 'linux', 'validated': False, 'files': [None]}]:
            (self.output / MANIFEST).write_text(json.dumps(malformed))
            self.assertFalse(verify_package(self.output)['ok'])


if __name__ == '__main__':
    unittest.main()
