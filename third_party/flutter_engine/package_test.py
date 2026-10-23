"""预编译包完整性与装配门禁回归。"""
import gzip
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prebuilt_engine', Path(__file__).with_name('package.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.addCleanup(patch.stopall)
        patch.object(package, 'ROOT', self.root).start()
        source = self.root / 'prebuilt/android-arm64'
        source.mkdir(parents=True)
        library = self.root / 'libflutter.so'
        header = bytearray(64)
        header[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', header, 18, 183)
        library.write_bytes(header)
        with patch.object(package.protocol, 'validate_sdk'):
            self.identity = package.protocol.create_identity(library, profile='androidFramePlan',
                architecture='arm64', mode='release', sdk=self.root, native_tests_passed=True)
        self.manifest = source / 'engine-identity.json'
        package.protocol.write_json(self.manifest, self.identity)
        self.archive = source / 'libflutter.so.gz'
        self.archive.write_bytes(gzip.compress(header))

    def test_round_trip_preserves_binary_and_identity(self):
        output = self.root / 'output'
        self.assertEqual(package.unpack('android-arm64', output), self.identity)
        self.assertEqual(package.protocol.sha256(output / 'libflutter.so'), self.identity['binarySha256'])

    def test_corruption_does_not_replace_existing_output(self):
        output = self.root / 'output'
        output.mkdir()
        (output / 'libflutter.so').write_bytes(b'existing')
        self.archive.write_bytes(gzip.compress(b'corrupted'))
        with self.assertRaises(ValueError):
            package.unpack('android-arm64', output)
        self.assertEqual((output / 'libflutter.so').read_bytes(), b'existing')

    def test_untested_or_stale_materials_are_rejected(self):
        for field, value in [('nativeTestsPassed', False), ('patchSha256', 'stale'), ('mode', 'profile')]:
            with self.subTest(field=field):
                package.protocol.write_json(self.manifest, {**self.identity, field: value})
                with self.assertRaises(ValueError):
                    package.unpack('android-arm64', self.root / 'output')


if __name__ == '__main__':
    unittest.main()
