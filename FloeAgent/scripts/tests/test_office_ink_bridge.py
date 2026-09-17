"""Contract tests for the app-owned Office ink bridge.

These tests execute the real injected JavaScript that ships in
``OfficeExplicitSaveBridge.swift`` (extracted between its explicit source
markers) inside Node with a fake Collabora ``window.app.map``, and run the
typed ``OfficeInkPreferences`` conversion/persistence/sequencing logic as an
actual Swift program when a Swift toolchain is available.

They assert behaviour, not source text:

* the JS harness drives the fake map's ``commandstatechanged`` stream and
  proves that only fresh, correlated, all-attribute events acknowledge a
  dispatch, while the host's cached ``getItemValue`` never can;
* the Swift harness exercises the persisted per-document values, the
  workspace-scoped privacy-safe key, the untrusted-JSON clamping and the
  stale-completion ordering guard;
* a second Swift harness proves the explicit remote document identity
  (workspaceID + relativePath) is stable across the changing remote-preview
  copy directory, separates same-named files in different workspaces, and
  never rebinds local Office or Notes documents to a transient workspace id.
"""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BRIDGE_SWIFT = REPO_ROOT / "FloeAgent/FloeApp/Workspace/OfficeExplicitSaveBridge.swift"
PREFERENCES_SWIFT = REPO_ROOT / "FloeAgent/FloeApp/Workspace/OfficeInkPreferences.swift"
PRIVATE_DIR = REPO_ROOT / "Local/Private/build178-feedback/office-ink-implementation"

JS_BEGIN_MARKER = "// FLOE_OFFICE_INK_BRIDGE_BEGIN"
JS_END_MARKER = "// FLOE_OFFICE_INK_BRIDGE_END"

# Executes the extracted bridge script against controlled window.app.map fakes.
NODE_HARNESS = r"""
'use strict';
const fs = require('fs');
const results = [];
function check(name, pass, detail) {
    results.push({ name, pass: !!pass, detail: detail === undefined ? '' : String(detail) });
}
global.window = {};
let activeApp;
Object.defineProperty(window, 'app', {
    get: () => activeApp,
    set: (value) => {
        activeApp = value;
        if (value && !value.definitions)
            value.definitions = { graphicSelection: { hasActiveSelection: () => false } };
    },
});
const source = fs.readFileSync(process.argv[2], 'utf8');
eval(source);
check('install/sets-functions',
    typeof window.__floeApplyOfficeInk === 'function'
    && typeof window.__floeOfficeInkVerification === 'function');
let reinstallThrew = false;
try { eval(source); } catch (e) { reinstallThrew = true; }
check('install/idempotent', !reinstallThrew && typeof window.__floeApplyOfficeInk === 'function');

// A fake map whose `fire` drives the same `commandstatechanged` stream the
// pinned client's StateChangeHandler listens on.
function makeMap(onDispatch) {
    const handlers = {};
    const calls = [];
    const map = {
        isEditMode: () => true,
        sendUnoCommand: function () {
            calls.push(Array.prototype.slice.call(arguments));
            if (onDispatch) onDispatch(map);
        },
        on: function (name, fn) { (handlers[name] = handlers[name] || []).push(fn); },
        fire: function (name, payload) { (handlers[name] || []).forEach((fn) => fn(payload)); },
        stateChangeHandler: { getItemValue: () => 'STALE-CACHE-VALUE' },
    };
    map.calls = calls;
    return map;
}

// --- readiness -----------------------------------------------------------------
window.app = {};
let r = window.__floeApplyOfficeInk({ color: 0, width: 150, transparency: 0 });
check('not-ready/no-map', r.ok === false && r.reason === 'not-ready', JSON.stringify(r));

window.app = { map: {
    isEditMode: () => false,
    sendUnoCommand: () => {},
    on: () => {},
    stateChangeHandler: { getItemValue: () => 0x0000FF },
} };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 0 });
check('not-ready/read-only', r.ok === false && r.reason === 'not-ready', JSON.stringify(r));

// --- invalid arguments never dispatch ------------------------------------------
let rejectCalls = 0;
window.app = { map: {
    isEditMode: () => true,
    sendUnoCommand: () => { rejectCalls++; },
    on: () => {},
    stateChangeHandler: { getItemValue: () => null },
} };
check('invalid/color-overflow',
    window.__floeApplyOfficeInk({ color: 0x1000000, width: 150, transparency: 0 }).reason === 'invalid');
check('invalid/zero-width',
    window.__floeApplyOfficeInk({ color: 0, width: 0, transparency: 0 }).reason === 'invalid');
check('invalid/transparency-overflow',
    window.__floeApplyOfficeInk({ color: 0, width: 150, transparency: 101 }).reason === 'invalid');
for (const color of [NaN, Infinity, 0x100000000, 1.5, '0']) {
    check('invalid/strict-color-' + color,
        window.__floeApplyOfficeInk({ color, width: 150, transparency: 0 }).reason === 'invalid');
}
check('invalid/never-dispatches', rejectCalls === 0, String(rejectCalls));
window.app.definitions.graphicSelection.hasActiveSelection = () => true;
check('selection/does-not-restyle-existing-object',
    window.__floeApplyOfficeInk({ color: 0, width: 150, transparency: 0 }).reason === 'object-selected'
    && rejectCalls === 0);
window.app.definitions = {};
check('selection/unknown-does-not-dispatch',
    window.__floeApplyOfficeInk({ color: 0, width: 150, transparency: 0 }).reason === 'not-ready'
    && rejectCalls === 0);

// --- exact dispatch encodings --------------------------------------------------
const calls = [];
window.app = { map: {
    isEditMode: () => true,
    sendUnoCommand: function () { calls.push(Array.prototype.slice.call(arguments)); },
    on: () => {},
    stateChangeHandler: { getItemValue: () => null },
} };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
check('dispatch/ok', r.ok === true && r.reason === 'dispatched'
    && typeof r.token === 'number' && r.token > 0, JSON.stringify(r));
check('dispatch/three-commands', calls.length === 3, String(calls.length));
check('dispatch/color',
    calls[0][0] === '.uno:XLineColor'
    && calls[0][1]['XLineColor.Color'].type === 'long'
    && calls[0][1]['XLineColor.Color'].value === 0x0000FF,
    JSON.stringify(calls[0]));
check('dispatch/width',
    calls[1][0] === '.uno:LineWidth'
    && calls[1][1]['LineWidth'].type === 'long'
    && calls[1][1]['LineWidth'].value === 150,
    JSON.stringify(calls[1]));
check('dispatch/transparency-solid',
    calls[2][0] === '.uno:LineTransparence?LineTransparence:short=42' && calls[2][1] === undefined,
    JSON.stringify(calls[2]));

window.app = {
    map: {
        isEditMode: () => true,
        sendUnoCommand: () => { throw new Error('boom'); },
        on: () => {},
        stateChangeHandler: { getItemValue: () => null },
    },
};
r = window.__floeApplyOfficeInk({ color: 1, width: 1, transparency: 0 });
check('dispatch/failure-not-ok', r.ok === false && r.reason === 'dispatch-failed', JSON.stringify(r));

// --- fresh all-attribute acknowledgement ---------------------------------------
window.app = { map: makeMap((map) => {
    map.fire('commandstatechanged', { commandName: '.uno:XLineColor', state: 0x0000FF });
    map.fire('commandstatechanged', { commandName: '.uno:LineWidth', state: 150 });
    map.fire('commandstatechanged', { commandName: '.uno:LineTransparence', state: 42 });
}) };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
let v = window.__floeOfficeInkVerification(r.token);
check('fresh/all-matched', v.known === true && v.allFreshMatched === true, JSON.stringify(v));

// A matching cached getItemValue (stale cache) can never acknowledge.
window.app = { map: {
    isEditMode: () => true,
    sendUnoCommand: () => {},
    on: () => {},
    stateChangeHandler: { getItemValue: () => 0x0000FF },
} };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
v = window.__floeOfficeInkVerification(r.token);
check('stale-cache/never-verified', v.allFreshMatched === false, JSON.stringify(v));

// One missing fresh attribute stays unverified.
window.app = { map: makeMap((map) => {
    map.fire('commandstatechanged', { commandName: '.uno:XLineColor', state: 0x0000FF });
    map.fire('commandstatechanged', { commandName: '.uno:LineWidth', state: 150 });
}) };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
v = window.__floeOfficeInkVerification(r.token);
check('fresh/missing-one-unverified',
    v.allFreshMatched === false && v.transparency.fresh === false, JSON.stringify(v));

// A fresh but non-matching value stays unverified.
window.app = { map: makeMap((map) => {
    map.fire('commandstatechanged', { commandName: '.uno:XLineColor', state: 0x0000FF });
    map.fire('commandstatechanged', { commandName: '.uno:LineWidth', state: 999 });
    map.fire('commandstatechanged', { commandName: '.uno:LineTransparence', state: 42 });
}) };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
v = window.__floeOfficeInkVerification(r.token);
check('fresh/wrong-value-unverified',
    v.allFreshMatched === false && v.width.matched === false, JSON.stringify(v));

// Prefixed names and numeric-string states are normalized.
window.app = { map: makeMap((map) => {
    map.fire('commandstatechanged', { commandName: 'XLineColor', state: '255' });
    map.fire('commandstatechanged', { commandName: 'LineWidth', state: '150' });
    map.fire('commandstatechanged', { commandName: 'LineTransparence', state: '42' });
}) };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
v = window.__floeOfficeInkVerification(r.token);
check('fresh/normalized-names-strings', v.allFreshMatched === true, JSON.stringify(v));

// An event from an earlier dispatch must not verify a later one without new events.
const sharedMap = makeMap(null);
window.app = { map: sharedMap };
const firstDispatch = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
sharedMap.fire('commandstatechanged', { commandName: '.uno:XLineColor', state: 0x0000FF });
sharedMap.fire('commandstatechanged', { commandName: '.uno:LineWidth', state: 150 });
sharedMap.fire('commandstatechanged', { commandName: '.uno:LineTransparence', state: 42 });
check('sequence/first-verified',
    window.__floeOfficeInkVerification(firstDispatch.token).allFreshMatched === true);
const secondDispatch = window.__floeApplyOfficeInk({ color: 0xFF0000, width: 300, transparency: 0 });
const staleCheck = window.__floeOfficeInkVerification(secondDispatch.token);
check('sequence/stale-events-do-not-reverify', staleCheck.allFreshMatched === false, JSON.stringify(staleCheck));

// A host without map.on still dispatches but can never be verified.
window.app = { map: {
    isEditMode: () => true,
    sendUnoCommand: () => {},
    stateChangeHandler: { getItemValue: () => 0x0000FF },
} };
r = window.__floeApplyOfficeInk({ color: 0x0000FF, width: 150, transparency: 42 });
v = window.__floeOfficeInkVerification(r.token);
check('listener/unavailable-dispatches', r.ok === true, JSON.stringify(r));
check('listener/unavailable-unverified',
    v.known === false && v.allFreshMatched === false, JSON.stringify(v));

const failed = results.filter((x) => !x.pass);
console.log(JSON.stringify({ results, failed: failed.length }));
process.exit(failed.length === 0 ? 0 : 1);
"""

# Executes the typed OfficeInkPreferences conversions, persistence, scoping,
# untrusted-JSON clamping and stale-completion ordering.
SWIFT_HARNESS = r"""
import Foundation

@main
enum OfficeInkChecks {
    @MainActor
    static func main() {
        let suite = "office.ink.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }

        // --- typed conversion and clamping ---
        let prefs = OfficeInkPreferences.session(forDocument: "Docs/report.docx", defaults: defaults)
        precondition(prefs.stroke == OfficeInkStroke(), "default stroke")
        precondition(prefs.documentKey == "Docs/report.docx", "document key")

        prefs.setColor(.blue)
        prefs.setWidthMillimeters(2.0)
        prefs.setTransparencyPercent(150)
        precondition(prefs.stroke.colorHex == "#0000FF", "color hex")
        precondition(prefs.stroke.colorValue == 0x0000FF, "color long")
        precondition(prefs.stroke.lineWidthValue == 200, "width mm100")
        precondition(prefs.stroke.transparencyValue == 100, "transparency clamp high")

        prefs.setTransparencyPercent(-5)
        precondition(prefs.stroke.transparencyValue == 0, "transparency clamp low (solid)")

        prefs.setWidthMillimeters(99)
        precondition(prefs.stroke.widthMillimeters == OfficeInkStroke.widthRange.upperBound, "width clamp")
        prefs.setWidthMillimeters(0.01)
        precondition(prefs.stroke.widthMillimeters == OfficeInkStroke.widthRange.lowerBound, "width clamp low")
        precondition(prefs.stroke.lineWidthValue >= 1, "width wire value never zero")

        prefs.setColorHex("not-a-color")
        precondition(prefs.stroke.colorHex == "#0000FF", "invalid hex ignored")

        // --- untrusted JSON: huge/non-finite scalars must not trap ---
        let hugeJSON = ##"{"colorHex":"#0000FF","widthMillimeters":1e308,"transparencyPercent":1e300}"##
        guard let hugeData = hugeJSON.data(using: .utf8) else { fatalError("encode") }
        guard let huge = try? JSONDecoder().decode(OfficeInkStroke.self, from: hugeData) else {
            fatalError("huge decode failed")
        }
        precondition(huge.widthMillimeters == OfficeInkStroke.widthRange.upperBound, "huge width clamp")
        precondition(huge.transparencyPercent == 100, "huge transparency clamp")
        precondition(huge.lineWidthValue == 600, "huge width wire value safe")

        let partialJSON = #"{"widthMillimeters":7.5}"#
        guard let partialData = partialJSON.data(using: .utf8),
              let partial = try? JSONDecoder().decode(OfficeInkStroke.self, from: partialData) else {
            fatalError("partial decode failed")
        }
        precondition(partial.colorHex == "#000000", "missing color default")
        precondition(partial.widthMillimeters == 6.0, "out-of-range width clamp")

        let nonFiniteWidth = OfficeInkStroke(widthMillimeters: .infinity)
        precondition(nonFiniteWidth.widthMillimeters == OfficeInkStroke.defaultWidthMillimeters,
                     "non-finite width default")
        precondition(OfficeInkStroke(widthMillimeters: -.infinity).lineWidthValue >= 1,
                     "non-finite width wire value safe")
        precondition(OfficeInkStroke(widthMillimeters: .nan).widthMillimeters
                     == OfficeInkStroke.defaultWidthMillimeters, "nan width default")
        precondition(OfficeInkStroke(widthMillimeters: 1e308).lineWidthValue == 600,
                     "direct huge width safe")

        // --- persisted per-document isolation ---
        let reloaded = OfficeInkPreferences.session(forDocument: "Docs/report.docx", defaults: defaults)
        precondition(reloaded.stroke == prefs.stroke, "persisted per document")
        let other = OfficeInkPreferences.session(forDocument: "Docs/other.xlsx", defaults: defaults)
        precondition(other.stroke == OfficeInkStroke(), "per-document isolation")
        precondition(OfficeInkPreferences.normalizedDocumentKey("") == "(untitled)", "empty key")

        // --- workspace + document identity: separated, stable, privacy-safe ---
        let keyA = OfficeInkPreferences.scopedDocumentKey(workspaceIdentity: "ws-A",
                                                          documentKey: "Docs/report.docx")
        let keyB = OfficeInkPreferences.scopedDocumentKey(workspaceIdentity: "ws-B",
                                                          documentKey: "Docs/report.docx")
        let keyARepeat = OfficeInkPreferences.scopedDocumentKey(workspaceIdentity: "ws-A",
                                                                documentKey: "Docs/report.docx")
        let unscoped = OfficeInkPreferences.scopedDocumentKey(workspaceIdentity: nil,
                                                              documentKey: "Docs/report.docx")
        precondition(keyA == keyARepeat, "workspace key stable")
        precondition(keyA != keyB, "workspace key separates workspaces")
        precondition(keyA != unscoped, "workspace key separates unscoped scope")
        precondition(!keyA.contains("Docs/report.docx"), "document path not persisted raw")
        precondition(!keyA.contains("ws-A"), "workspace identity not persisted raw")
        precondition(keyA.count <= 32, "workspace key bounded")

        let scoped = OfficeInkPreferences.session(forDocument: keyA, defaults: defaults)
        scoped.setColor(.red)
        scoped.setWidthMillimeters(3.0)
        let scopedReloaded = OfficeInkPreferences.session(forDocument: keyA, defaults: defaults)
        precondition(scopedReloaded.stroke.colorHex == "#FF0000", "scoped key persistence")
        let scopedOther = OfficeInkPreferences.session(forDocument: keyB, defaults: defaults)
        precondition(scopedOther.stroke == OfficeInkStroke(), "scoped keys isolated")

        // --- serialization/coalescing: stale completions can never publish ---
        var sequencer = OfficeInkApplySequencer()
        precondition(sequencer.begin() == true, "first request starts loop")
        precondition(sequencer.next() == 1, "first generation")
        precondition(sequencer.begin() == false, "second request coalesced while running")
        precondition(sequencer.next() == 2, "newest generation wins")
        precondition(sequencer.complete(1) == false, "superseded completion rejected")
        precondition(sequencer.complete(2) == true, "latest completion accepted")
        precondition(sequencer.next() == nil, "loop drains")

        var invalidated = OfficeInkApplySequencer()
        precondition(invalidated.begin() == true, "invalidate request starts")
        precondition(invalidated.next() == 1, "invalidate generation")
        invalidated.invalidate()
        precondition(invalidated.complete(1) == false, "invalidate rejects in-flight completion")
        precondition(invalidated.next() == nil, "invalidate stops loop")

        var coalesced = OfficeInkApplySequencer()
        precondition(coalesced.begin() == true, "coalesce first")
        _ = coalesced.begin()
        _ = coalesced.begin()
        precondition(coalesced.next() == 3, "rapid requests collapse to newest")
        precondition(coalesced.complete(3) == true, "coalesced completion accepted")

        var switched = OfficeInkApplySequencer()
        let oldEpoch = switched.epoch
        precondition(switched.begin())
        let oldGeneration = switched.next(epoch: oldEpoch)!
        switched.invalidate()
        let newEpoch = switched.epoch
        precondition(switched.begin())
        let newGeneration = switched.next(epoch: newEpoch)!
        precondition(!switched.complete(oldGeneration, epoch: oldEpoch))
        precondition(switched.next(epoch: oldEpoch) == nil, "old controller must not drain new document requests")
        precondition(switched.running, "old loop must not stop the new document loop")
        precondition(switched.next(epoch: newEpoch) == newGeneration)
        precondition(switched.complete(newGeneration, epoch: newEpoch))
        precondition(switched.next(epoch: newEpoch) == nil)
        print("OFFICE_INK_SWIFT_CHECKS_OK")
    }
}
"""

# Executes the typed OfficeInkDocumentIdentity resolution: an explicit
# workspaceID+relativePath key must survive the changing remote-preview copy
# directory, must separate same-named files in different workspaces, and must
# never rebind Notes/local Office documents to a transient workspace id.
SWIFT_IDENTITY_HARNESS = r"""
import Foundation

@main
enum OfficeInkIdentityChecks {
    @MainActor
    static func main() {
        let suite = "office.ink.identity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let workspaceA = "11111111-1111-1111-1111-111111111111"
        let workspaceB = "22222222-2222-2222-2222-222222222222"

        // --- explicit remote identity is stable and workspace-scoped ---
        let remoteA1 = OfficeInkDocumentIdentity(workspaceIdentity: workspaceA,
                                                 relativePath: "Cloud/team/report.docx")
        let remoteA2 = OfficeInkDocumentIdentity(workspaceIdentity: workspaceA,
                                                 relativePath: "Cloud/team/report.docx")
        let remoteB = OfficeInkDocumentIdentity(workspaceIdentity: workspaceB,
                                                relativePath: "Cloud/team/report.docx")
        precondition(remoteA1.scopedKey == remoteA2.scopedKey, "remote key stable")
        precondition(remoteA1.scopedKey != remoteB.scopedKey, "same name different workspace separated")
        precondition(!remoteA1.scopedKey.contains("report.docx"), "remote path not persisted raw")
        precondition(!remoteA1.scopedKey.contains(workspaceA), "workspace id not persisted raw")
        precondition(remoteA1.scopedKey.count <= 32, "remote key bounded")

        // --- the fresh preview-copy directory must not change the key ---
        let temp1 = URL(fileURLWithPath: "/tmp/floe-preview-\(UUID())/report.docx")
        let temp2 = URL(fileURLWithPath: "/tmp/floe-preview-\(UUID())/report.docx")
        precondition(temp1 != temp2, "fixture temp copies differ")
        let resolved1 = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: remoteA1, originalURL: temp1,
            fallbackWorkspaceIdentity: nil, fallbackDocumentKey: "ignored")
        let resolved2 = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: remoteA2, originalURL: temp2,
            fallbackWorkspaceIdentity: nil, fallbackDocumentKey: "ignored")
        precondition(resolved1 == resolved2, "preview dir does not change key")
        precondition(resolved1 == remoteA1.scopedKey, "explicit identity wins over session URL")
        precondition(resolved1 != remoteB.scopedKey, "cross-workspace settings cannot merge")

        // --- end-to-end defaults isolation for the resolved keys ---
        let remotePrefs = OfficeInkPreferences.session(forDocument: resolved1, defaults: defaults)
        remotePrefs.setColor(.red)
        remotePrefs.setWidthMillimeters(3.0)
        let remoteReloaded = OfficeInkPreferences.session(forDocument: resolved2, defaults: defaults)
        precondition(remoteReloaded.stroke.colorHex == "#FF0000", "remote settings restored via stable key")
        precondition(remoteReloaded.stroke.widthMillimeters == 3.0, "remote width restored")
        let otherWorkspace = OfficeInkPreferences.session(forDocument: remoteB.scopedKey, defaults: defaults)
        precondition(otherWorkspace.stroke == OfficeInkStroke(), "other workspace has independent settings")

        // --- local Office / Notes keep the physical-URL identity ---
        let localURL = URL(fileURLWithPath: "/Users/x/Workspace/Docs/report.docx")
        let localA = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: nil, originalURL: localURL,
            fallbackWorkspaceIdentity: workspaceA, fallbackDocumentKey: "Docs/report.docx")
        let localB = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: nil, originalURL: localURL,
            fallbackWorkspaceIdentity: workspaceB, fallbackDocumentKey: "unrelated.docx")
        precondition(localA == localB, "local physical key ignores transient workspace id")
        let localOtherDir = URL(fileURLWithPath: "/Users/x/Other/report.docx")
        let localOther = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: nil, originalURL: localOtherDir,
            fallbackWorkspaceIdentity: workspaceA, fallbackDocumentKey: "report.docx")
        precondition(localA != localOther, "different physical directories separated")
        precondition(localA != remoteA1.scopedKey, "local and remote identity spaces differ")

        // --- fallback only before a document URL exists ---
        let fallback = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: nil, originalURL: nil,
            fallbackWorkspaceIdentity: workspaceA, fallbackDocumentKey: "Docs/report.docx")
        precondition(fallback == OfficeInkPreferences.scopedDocumentKey(workspaceIdentity: workspaceA,
                                                                        documentKey: "Docs/report.docx"),
                     "fallback key used before open")
        print("OFFICE_INK_IDENTITY_CHECKS_OK")
    }
}
"""


def extract_bridge_javascript() -> str:
    text = BRIDGE_SWIFT.read_text(encoding="utf-8")
    if JS_BEGIN_MARKER not in text or JS_END_MARKER not in text:
        raise AssertionError("ink bridge source markers are missing")
    begin = text.index(JS_BEGIN_MARKER)
    raw_open = text.index('#"""', begin) + len('#"""')
    raw_close = text.index('"""#', raw_open)
    script = text[raw_open:raw_close]
    if "sendUnoCommand" not in script:
        raise AssertionError("extracted bridge script is empty or wrong")
    return script


def scratch_dir() -> Path:
    try:
        PRIVATE_DIR.mkdir(parents=True, exist_ok=True)
        probe = PRIVATE_DIR / ".write-probe"
        probe.write_text("", encoding="utf-8")
        probe.unlink()
        return PRIVATE_DIR
    except OSError:
        return Path(tempfile.mkdtemp(prefix="office-ink-bridge-"))


class OfficeInkPreferencesSwiftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not PREFERENCES_SWIFT.is_file():
            raise unittest.SkipTest("OfficeInkPreferences.swift is not present")
        cls.script = extract_bridge_javascript()

    def test_bridge_markers_extract_single_script(self):
        self.assertIn("__floeApplyOfficeInk", self.script)
        self.assertIn("__floeOfficeInkVerification", self.script)
        self.assertNotIn(".getItemValue(", self.script)

    def test_javascript_dispatch_contract(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node is not installed")
        work = scratch_dir()
        js_path = work / "office_ink_bridge_extracted.js"
        harness_path = work / "office_ink_bridge_harness.cjs"
        js_path.write_text(self.script, encoding="utf-8")
        harness_path.write_text(NODE_HARNESS, encoding="utf-8")
        proc = subprocess.run([node, str(harness_path), str(js_path)],
                              capture_output=True, text=True)
        output = proc.stdout.strip().splitlines()
        self.assertTrue(output, f"harness produced no output; stderr={proc.stderr}")
        payload = json.loads(output[-1])
        failed = [r for r in payload["results"] if not r["pass"]]
        self.assertEqual(failed, [], f"failed JS contract checks: {failed}\nstderr={proc.stderr}")
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_swift_conversion_and_persistence(self):
        swiftc = shutil.which("swiftc")
        if not swiftc:
            self.skipTest("swiftc is not installed")
        work = scratch_dir()
        harness_path = work / "office_ink_preferences_check.swift"
        binary_path = work / "office_ink_preferences_check"
        harness_path.write_text(SWIFT_HARNESS, encoding="utf-8")
        compile_proc = subprocess.run(
            [swiftc, str(PREFERENCES_SWIFT), str(harness_path), "-o", str(binary_path)],
            capture_output=True, text=True)
        self.assertEqual(compile_proc.returncode, 0, compile_proc.stderr)
        run_proc = subprocess.run([str(binary_path)], capture_output=True, text=True)
        self.assertEqual(run_proc.returncode, 0, run_proc.stderr)
        self.assertIn("OFFICE_INK_SWIFT_CHECKS_OK", run_proc.stdout)

    def test_swift_remote_document_identity_regression(self):
        swiftc = shutil.which("swiftc")
        if not swiftc:
            self.skipTest("swiftc is not installed")
        work = scratch_dir()
        harness_path = work / "office_ink_identity_check.swift"
        binary_path = work / "office_ink_identity_check"
        harness_path.write_text(SWIFT_IDENTITY_HARNESS, encoding="utf-8")
        compile_proc = subprocess.run(
            [swiftc, str(PREFERENCES_SWIFT), str(harness_path), "-o", str(binary_path)],
            capture_output=True, text=True)
        self.assertEqual(compile_proc.returncode, 0, compile_proc.stderr)
        run_proc = subprocess.run([str(binary_path)], capture_output=True, text=True)
        self.assertEqual(run_proc.returncode, 0, run_proc.stderr)
        self.assertIn("OFFICE_INK_IDENTITY_CHECKS_OK", run_proc.stdout)


if __name__ == "__main__":
    unittest.main()
