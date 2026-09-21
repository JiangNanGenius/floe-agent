#!/usr/bin/env python3
"""Contract tests for the Office host's font discovery and Pencil gating.

Device feedback (2026-09-21) reported CJK glyphs rendering as boxes and finger
touches drawing instead of navigating while annotating. The fixes live in the
native host sources, which the app build compiles and pins:

* ``FloeOfficeNative.mm`` fingerprints the staged font catalog and folds it
  into the engine profile identity, so a font-set change re-runs the engine's
  discovery instead of reusing a stale cached catalog;
* the host injects a pointer gate that lets only Apple Pencil ('pen') start a
  stroke while annotation mode is on, leaving finger input to navigation;
* ``engine.lock.json`` records the exact source hash and states that the
  pinned framework must be rebuilt before distribution.

These tests execute the real extracted JavaScript in Node (when available)
and check the staging/pin contracts by value, not by prose.
"""

import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HOST_SOURCE = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm"
LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json"
EMBED_SCRIPT = REPO_ROOT / "FloeAgent/scripts/embed_office_host.py"

FONT_BEGIN = "// FLOE_FONT_CATALOG_BEGIN"
FONT_END = "// FLOE_FONT_CATALOG_END"
GATING_BEGIN = "// FLOE_INK_GATING_SCRIPT_BEGIN"
GATING_END = "// FLOE_INK_GATING_SCRIPT_END"

NODE_HARNESS = r"""
'use strict';
const fs = require('fs');
const results = [];
function check(name, pass, detail) {
    results.push({ name, pass: !!pass, detail: detail === undefined ? '' : String(detail) });
}
const listeners = {};
global.window = {
    __floePencilOnly: undefined,
    addEventListener(type, handler, options) {
        (listeners[type] = listeners[type] || []).push({ handler, options });
    },
};
global.document = {
    readyState: 'complete',
    head: { appendChild() {} },
    addEventListener() {},
};
const source = fs.readFileSync(process.argv[1], 'utf8');
eval(source);
check('install/flag-default-false', window.__floePencilOnly === false);
check('install/idempotent-marker', window.__floeInkGatingInstalled === true);
check('install/registers-pointerdown', Array.isArray(listeners.pointerdown) && listeners.pointerdown.length > 0);
const handler = listeners.pointerdown[0].handler;
function dispatch(pointerType) {
    const state = { stopped: 0, prevented: 0, propagated: 0 };
    handler({
        pointerType,
        stopImmediatePropagation() { state.stopped += 1; },
        stopPropagation() { state.propagated += 1; },
        preventDefault() { state.prevented += 1; },
    });
    return state;
}
// Annotation mode off: nothing is filtered.
window.__floePencilOnly = false;
let touch = dispatch('touch');
check('idle/finger-not-blocked', touch.stopped === 0 && touch.prevented === 0);
let pen = dispatch('pen');
check('idle/pen-not-blocked', pen.stopped === 0 && pen.prevented === 0);
// Annotation mode on: only the pencil draws.
window.__floePencilOnly = true;
touch = dispatch('touch');
check('drawing/finger-blocked', touch.stopped === 1 && touch.prevented === 1 && touch.propagated === 1);
pen = dispatch('pen');
check('drawing/pen-passes', pen.stopped === 0 && pen.prevented === 0);
const mouse = dispatch('mouse');
check('drawing/mouse-passes', mouse.stopped === 0 && mouse.prevented === 0);
// A re-install must not double-register the gate.
eval(source);
check('install/does-not-duplicate', listeners.pointerdown.length === 1);
for (const result of results) {
    console.log(JSON.stringify(result));
}
"""


def extract(source: str, begin: str, end: str) -> str:
    start = source.index(begin) + len(begin)
    stop = source.index(end, start)
    return source[start:stop]


def extract_objective_c_js(source: str, begin: str, end: str) -> str:
    """The gating script ships inside an Objective-C raw string literal."""
    block = extract(source, begin, end)
    start = block.index('R"FLOE_JS(') + len('R"FLOE_JS(')
    stop = block.index(')FLOE_JS"', start)
    return block[start:stop]


class OfficeFontDiscoveryContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = HOST_SOURCE.read_text(encoding="utf-8")
        cls.lock = json.loads(LOCK.read_text(encoding="utf-8"))

    def test_font_catalog_fingerprint_scans_both_staged_locations(self) -> None:
        block = extract(self.source, FONT_BEGIN, FONT_END)
        self.assertIn('@"Fonts"', block, "the app-level staged font folder must be scanned")
        self.assertIn('@"share/fonts"', block, "the engine's own font resources must be scanned")
        self.assertIn("NSURLFileSizeKey", block)
        self.assertIn("sortUsingSelector", block, "the fingerprint must be order-independent")
        self.assertIn("FNV", block.replace("FNV-1a", "FNV"))

    def test_profile_identity_depends_on_the_font_catalog(self) -> None:
        # Discovery is cached inside the engine profile; a changed catalog must
        # produce a different profile instead of reusing stale discovery.
        self.assertIn("FloeBundledFontCatalogFingerprint(bundle)", self.source)
        self.assertIn("27b21dc1-fonts-%@", self.source)
        self.assertIn("FloeOffice font catalog fingerprint=", self.source)
        # The engine still initializes against the final bundle resource path.
        self.assertIn("cok_init_2(bundle.resourcePath.UTF8String", self.source)

    def test_embed_script_stages_fonts_into_the_app_bundle(self) -> None:
        script = EMBED_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("Fonts", script, "the embed step must create app/Fonts")
        self.assertIn(".ttf", script)
        self.assertIn(".otf", script)
        self.assertIn("is_symlink", script, "a symlinked font file must never be embedded")


class OfficePencilGatingContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = HOST_SOURCE.read_text(encoding="utf-8")

    def test_host_arms_and_scopes_the_gate(self) -> None:
        # The gate is installed only for editable documents...
        self.assertIn("if (!self.readOnly)", self.source)
        self.assertIn("FloeInkInputGatingScript()", self.source)
        # ...and annotation mode arms it together with the freehand tool.
        self.assertIn("window.__floePencilOnly = %@", self.source)
        self.assertIn(".uno:Freeline_Unfilled", self.source)
        # The freehand tool is the engine's editable vector shape tool, so the
        # strokes are document content that saves and reopens with the file.
        self.assertIn("weakSelf.drawingModeEnabled = enabled.boolValue", self.source)

    def test_gating_javascript_behaviour(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is unavailable; JS behaviour runs in CI")
        script = extract_objective_c_js(self.source, GATING_BEGIN, GATING_END)
        with tempfile.TemporaryDirectory() as folder:
            js_path = Path(folder) / "gating.js"
            js_path.write_text(script, encoding="utf-8")
            completed = subprocess.run(
                [node, "-e", NODE_HARNESS, str(js_path)],
                capture_output=True, text=True, check=False, timeout=60,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        results = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        self.assertTrue(results, "the harness produced no results")
        failures = [entry for entry in results if not entry["pass"]]
        self.assertEqual([], failures, f"gating behaviour failed: {failures}")


class OfficeHostPinContract(unittest.TestCase):
    def test_source_hash_matches_the_recorded_pin(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        pin = lock["qualifiedHostArtifact"]
        digest = hashlib.sha256(HOST_SOURCE.read_bytes()).hexdigest()
        self.assertEqual(
            digest,
            pin["hostSourceSHA256"]["FloeOfficeNative.mm"],
            "the host source and its recorded pin must stay consistent",
        )

    def test_lock_records_the_required_rebuild(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        pin = lock["qualifiedHostArtifact"]
        note = pin.get("note", "")
        self.assertIn("SOURCE AHEAD OF ARTIFACT", note)
        self.assertIn("rebuild", note.lower())
        # Machine-readable: the build must fail closed until a rebuilt and
        # verified artifact replaces this pin (cleared by
        # scripts/pin_office_host_artifact.py --apply).
        self.assertIs(pin.get("pendingHostRebuild"), True)
        # The artifact hashes still describe the previously qualified binary.
        self.assertIn("archiveSHA256", pin)


if __name__ == "__main__":
    unittest.main(verbosity=2)
