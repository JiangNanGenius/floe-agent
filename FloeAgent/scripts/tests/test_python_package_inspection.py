"""Run the exact trusted inspection program with a real metadata fixture."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


class InspectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        package = self.root / 'floe_inspection_fixture-1.2.3.dist-info'
        package.mkdir()
        (package / 'METADATA').write_text('Metadata-Version: 2.1\nName: floe-inspection-fixture\nVersion: 1.2.3\n')
        swift = Path(__file__).resolve().parents[2] / 'Sources/FloeExecution/ManagedPythonInstallService.swift'
        source = swift.read_text().split('public func inspect(', 1)[1].split('let source = """', 1)[1].split('"""', 1)[0]
        self.source = textwrap.dedent(source)

    def run_inspection(self, command, arguments):
        # -S excludes unrelated host distributions while retaining stdlib
        # importlib.metadata; no fixture replaces the production inspector.
        program = 'import json; input = json.loads(' + repr(json.dumps({'command': command, 'arguments': arguments})) + ')\n' + self.source
        return subprocess.run([sys.executable, '-S', '-c', program], text=True, capture_output=True,
                              env=dict(os.environ, PYTHONPATH=str(self.root)), timeout=10)

    def test_show_and_json_inventory_read_actual_distribution_metadata(self):
        shown = self.run_inspection('show', ['floe-inspection-fixture'])
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertIn('Version: 1.2.3', shown.stdout)
        listed = self.run_inspection('list', ['--format=json'])
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual(json.loads(listed.stdout), [{'name': 'floe-inspection-fixture', 'version': '1.2.3'}])
        frozen = self.run_inspection('freeze', [])
        self.assertEqual(frozen.returncode, 0, frozen.stderr)
        self.assertEqual(frozen.stdout, 'floe-inspection-fixture==1.2.3\n')

    def test_missing_package_returns_failure(self):
        result = self.run_inspection('show', ['missing-floe-fixture'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Package is not installed', result.stderr)


if __name__ == '__main__':
    unittest.main()
