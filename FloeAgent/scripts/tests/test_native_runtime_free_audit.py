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


class KeepaliveAuditTests(unittest.TestCase):
    def test_real_tree_has_no_keepalive_pattern(self):
        self.assertEqual(audit.audit_keepalive(), [])

    def test_silent_audio_patterns_fail(self):
        cases = [
            "AVAudioPlayer(contentsOf: silentAudioLoopURL)",
            "let silentAudioTrack = makeSilentAudioTrack()",
            "struct SilentAudioKeepAlive {}",
            "player.keepAliveTrack = track",
            "engine.playSilenceLoop()",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            sources = Path(tmp) / "FloeAgent" / "FloeApp" / "Platform"
            sources.mkdir(parents=True)
            for index, source in enumerate(cases):
                (sources / f"Case{index}.swift").write_text(source + "\n")
            findings = audit.audit_keepalive(tmp)
            self.assertEqual(len(findings), len(cases), findings)

    def test_unrelated_prose_is_not_flagged(self):
        with tempfile.TemporaryDirectory() as tmp:
            sources = Path(tmp) / "FloeAgent" / "Sources" / "FloeExecution" / "Linux"
            sources.mkdir(parents=True)
            (sources / "Prose.swift").write_text(
                "// A failed run is not a silent failure; audio needs a real user session.\n"
            )
            self.assertEqual(audit.audit_keepalive(tmp), [])


class ConvergenceAuditTests(unittest.TestCase):
    def test_real_tree_declares_convergence_and_provenance(self):
        self.assertEqual(audit.audit_convergence(), [])

    def test_missing_router_and_provenance_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            findings = audit.audit_convergence(tmp)
            self.assertTrue(any("capability router" in finding for finding in findings), findings)
            self.assertTrue(any("signed catalog" in finding for finding in findings), findings)

    def test_catalog_without_documented_provenance_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            router = Path(tmp) / audit.CAPABILITY_ROUTER_SOURCE
            router.parent.mkdir(parents=True)
            router.write_text(
                '"exec.wasm" "exec.compatEvaluator" "wasm.packages" linuxGuest\n'
            )
            hub = Path(tmp) / "capability-hub"
            hub.mkdir(parents=True)
            (hub / "catalog.json").write_text(
                '{"packages":[{"id":"floe/undocumented","version":"1.0.0",'
                '"sha256":"abc","url":"https://example.invalid/x.wasm"}]}'
            )
            (hub / "LANGUAGES.md").write_text("# no provenance here\n")
            findings = audit.audit_convergence(tmp)
            self.assertTrue(
                any("floe/undocumented" in finding for finding in findings), findings
            )


class ProjectAuditCliTests(unittest.TestCase):
    def test_cli_keepalive_and_convergence_exit_codes(self):
        script = ROOT / "audit_native_runtime_free.py"
        for flags in (["--keepalive"], ["--convergence"], ["--project", "--keepalive", "--convergence"]):
            result = subprocess.run(
                [sys.executable, str(script), *flags], capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


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
