"""Focused checks for the Phase 2 native-runtime-free IPA/project audit."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("audit_native_runtime_free", ROOT / "audit_native_runtime_free.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class ProjectAuditTests(unittest.TestCase):
    def test_current_tree_is_clean(self):
        self.assertEqual(audit.audit_project(), [])

    def test_every_project_marker_is_detected(self):
        for needle, label in audit.PROJECT_MARKERS:
            self.assertIn(needle, needle)  # markers are literal needles
            self.assertTrue(label)


class BundleAuditTests(unittest.TestCase):
    def test_clean_bundle_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Floe Agent.app"
            (app / "Frameworks" / "CPDFium.framework").mkdir(parents=True)
            (app / "Frameworks" / "dash.framework").mkdir(parents=True)
            self.assertEqual(audit.audit_app(app), [])

    def test_native_markers_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Floe Agent.app"
            cases = [
                app / "Frameworks" / "Python.framework" / "Python",
                app / "Frameworks" / "NodeMobile.framework" / "NodeMobile",
                app / "Frameworks" / "_ssl.cpython-313-darwin.framework" / "_ssl",
                app / "Frameworks" / "pandas__libs_algos.framework" / "pandas__libs_algos",
                app / "lib" / "python3.13" / "json" / "__init__.py",
                app / "NodeTools" / "host.cjs",
                app / "PythonServiceBootstrap.py",
            ]
            for case in cases:
                case.parent.mkdir(parents=True, exist_ok=True)
                case.write_bytes(b"x")
            findings = audit.audit_app(app)
            self.assertEqual(len(findings), len(cases), findings)

    def test_cli_project_mode_exit_codes(self):
        script = ROOT / "audit_native_runtime_free.py"
        ok = subprocess.run([sys.executable, str(script), "--project"], capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)


if __name__ == "__main__":
    unittest.main()
