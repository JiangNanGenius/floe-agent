#!/usr/bin/env python3
"""Load-chain qualification fixtures; these do not execute the Office engine."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import verify_office_app_embedding as verifier


class OfficeAppLoadChainTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / 'Floe Agent.app'
        self.app.mkdir()
        self.main = self.app / 'Floe Agent'
        self.debug = self.app / 'Floe Agent.debug.dylib'
        self.host = self.app / 'Frameworks/FloeOfficeNative.framework/FloeOfficeNative'
        self.host.parent.mkdir(parents=True)
        for path in [self.main, self.debug, self.host]:
            path.write_bytes(path.name.encode())
        self.reference = '@rpath/FloeOfficeNative.framework/FloeOfficeNative'
        self.libs = {self.main: ['@rpath/Floe Agent.debug.dylib'], self.debug: [self.reference]}
        self.paths = {self.main: ['@executable_path', '@executable_path/Frameworks'], self.debug: []}
        for name, mapping in [('linked_libraries', self.libs), ('runtime_paths', self.paths)]:
            mocked = patch.object(verifier, name, side_effect=lambda path, values=mapping: values[path])
            mocked.start()
            self.addCleanup(mocked.stop)

    def verify(self):
        return verifier.verify_office_load_chain(self.app, self.main.name)

    def test_debug_code_requires_real_main_load_reference_and_inherited_rpath(self):
        result = self.verify()
        self.assertEqual(result['officeLoadChain'], [self.main.name, self.debug.name, self.reference])
        self.assertEqual(result['appCodeBinarySHA256'], verifier.digest(self.debug))

    def test_direct_release_load_uses_executable(self):
        self.libs[self.main] = [self.reference]
        self.assertEqual(self.verify()['appCodeBinaryPath'], self.main.name)

    def test_unlinked_debug_file_cannot_qualify(self):
        self.libs[self.main] = []
        with self.assertRaisesRegex(ValueError, 'no resolvable load chain'):
            self.verify()

    def test_wrong_debug_or_framework_search_path_cannot_qualify(self):
        for paths in [['@executable_path/Frameworks'], ['@executable_path']]:
            with self.subTest(paths=paths):
                self.paths[self.main] = paths
                with self.assertRaisesRegex(ValueError, 'no resolvable load chain'):
                    self.verify()

    def test_missing_or_aliased_debug_binary_cannot_qualify(self):
        self.debug.unlink()
        with self.assertRaisesRegex(ValueError, 'missing or aliased'):
            self.verify()
        self.debug.symlink_to(self.main)
        with self.assertRaisesRegex(ValueError, 'missing or aliased'):
            self.verify()

    def test_missing_host_cannot_qualify(self):
        self.host.unlink()
        with self.assertRaisesRegex(ValueError, 'host is missing or aliased'):
            self.verify()


class MachOOutputParsingTests(unittest.TestCase):
    def test_paths_with_spaces_and_non_rpath_commands(self):
        output = '''Load command 1
          cmd LC_RPATH
      cmdsize 48
         path @executable_path/Frameworks (offset 12)
Load command 2
          cmd LC_LOAD_DYLIB
         name @rpath/Floe Agent.debug.dylib (offset 24)
Load command 3
          cmd LC_RPATH
         path @loader_path/Folder With Spaces (offset 12)
'''
        with patch.object(verifier.subprocess, 'check_output', return_value=output):
            self.assertEqual(verifier.runtime_paths(Path('/fixture')), [
                '@executable_path/Frameworks', '@loader_path/Folder With Spaces'])
        output = '''Floe Agent:
\t@rpath/Floe Agent.debug.dylib (compatibility version 1.0.0, current version 1.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
'''
        with patch.object(verifier.subprocess, 'check_output', return_value=output):
            self.assertEqual(verifier.linked_libraries(Path('/fixture')), [
                '@rpath/Floe Agent.debug.dylib', '/usr/lib/libSystem.B.dylib'])


if __name__ == '__main__':
    unittest.main()
