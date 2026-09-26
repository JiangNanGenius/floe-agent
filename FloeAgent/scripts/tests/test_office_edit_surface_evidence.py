#!/usr/bin/env python3
"""Sequence-level regression for the shipped edit-surface paint evidence.

The pinned host's render probe decides whether an editable presentation's
edit surface really painted after the guarded mobile edit entry. The decision
runs in the page across many polls, so single-state fixtures cannot exercise
it: this harness drives the *actual* shipped `FloeRenderProbeScript`
(extracted from `FloeOfficeNative.mm`) through scripted multi-poll engine
lifecycles and pins the evidence contract:

  - a post-entry layout swap with painted canvas content counts as edit-
    surface paint evidence even when the engine reused its tile cache and the
    downsampled canvas fingerprint is unchanged (the false negative that left
    a healthy, painted editable editor on the permanent "render not verified"
    outcome with saving refused);
  - without the layout-swap receipt the evidence stays strict (tile reuse
    alone never qualifies);
  - a blank canvas never qualifies, swap or not (first-frame evidence is not
    weakened);
  - the pre-existing strict paths (new tile decodes, canvas repaint, and the
    no-baseline escape hatch) are unchanged.

Nothing here claims an engine or device result; `engineEditSurfacePassed`
stays false until a real editable presentation render receipt exists.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[2]
HOST_SOURCE = REPO_ROOT / 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'

HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
function paintData(kind) {
    const pixels = 24 * 16;
    const palettes = {
        blank: [255, 255, 255],
        skeleton: [255, 255, 255, 221, 227, 234],
        slide: [255, 255, 255, 22, 93, 190, 40, 40, 40],
    };
    const opaqueFrac = { blank: 1, skeleton: 0.4, slide: 0.8 };
    const data = new Uint8ClampedArray(pixels * 4);
    const palette = palettes[kind] || palettes.blank;
    const count = palette.length / 3;
    for (let i = 0; i < pixels; i++) {
        const index = (i % count) * 3;
        data[i * 4] = palette[index];
        data[i * 4 + 1] = palette[index + 1];
        data[i * 4 + 2] = palette[index + 2];
        data[i * 4 + 3] = i < Math.round(pixels * (opaqueFrac[kind] ?? 1)) ? 255 : 0;
    }
    return data;
}
function makeWorld(initial) {
    const world = {
        fileBasedView: initial.fileBasedView === true,
        readOnly: initial.readOnly === true,
        docLoaded: initial.docLoaded === true,
        docType: initial.docType || null,
        canvasKind: initial.canvasKind || 'blank',
        layout: initial.layout || 'ViewLayoutFileBased',
        tiles: new Map(),
        nextImage: 0,
    };
    world.addTile = (key, decoded) => {
        world.tiles.set(key, { image: decoded ? { id: ++world.nextImage } : null });
    };
    for (const [key, decoded] of Object.entries(initial.tiles || {})) world.addTile(key, decoded);
    const document = {
        readyState: 'complete',
        addEventListener() {},
        querySelectorAll: (selector) => (selector === 'canvas' ? [world.canvas] : []),
        createElement: () => ({
            width: 0, height: 0,
            getContext: () => ({
                _paint: 'blank',
                drawImage(source) { this._paint = source._kind; },
                getImageData() { return { data: paintData(this._paint) }; },
            }),
        }),
    };
    world.canvas = {
        get width() { return 1024; },
        get height() { return 768; },
        get clientWidth() { return 1024; },
        get clientHeight() { return 768; },
        get _kind() { return world.canvasKind; },
        set _kind(value) { world.canvasKind = value; },
    };
    const app = {
        file: world,
        activeDocument: { get activeLayout() { return { type: world.layout }; } },
        map: {
            _docLoaded: world.docLoaded,
            get _docLayer() { return world.docType ? { _docType: world.docType } : null; },
            isEditMode: () => world.uiEdit === true,
            _permission: world.permission || 'readonly',
            getDocType() { return world.docType; },
        },
    };
    world.window = { app, RenderManager: { getTiles: () => world.tiles, isVectorRendering: () => false } };
    world.document = document;
    return world;
}
function runProbe(world) {
    return vm.runInNewContext(SOURCE, { window: world.window, document: world.document });
}
function arm(world, token) {
    const fn = world.window.__floeArmEditSurface;
    if (typeof fn !== 'function') return false;
    return vm.runInNewContext('__a__(__t__)', { __a__: fn, __t__: token }) === true;
}
function enterEdit(world) {
    world.fileBasedView = false;
    world.uiEdit = true;
    world.permission = 'edit';
    world.layout = 'ViewLayoutImpress';
}

// Each scenario returns the probe facts of every poll. Expected verdicts are
// asserted by the Python side so the fixture stays data-only.
const scenarios = {
    // Regression: the engine switches layouts after the armed entry and the
    // edit surface shows painted content, but the tile cache is reused and the
    // downsampled fingerprint is unchanged. Must now read as painted.
    tileReuseLayoutSwapPainted(world) {
        const image = { id: 1 };
        world.tiles.set('0:0', { image });
        world.canvasKind = 'slide';
        const polls = [runProbe(world)];
        assert.equal(arm(world, 's:1'), true);
        enterEdit(world);
        polls.push(runProbe(world));
        return polls;
    },
    // Control: same reuse case but the layout receipt is absent (no swap).
    // Must stay unpainted — the new evidence never stands alone.
    tileReuseNoLayoutSwap(world) {
        const image = { id: 1 };
        world.tiles.set('0:0', { image });
        world.canvasKind = 'slide';
        const polls = [runProbe(world)];
        assert.equal(arm(world, 's:1'), true);
        world.fileBasedView = false;
        world.uiEdit = true;
        world.permission = 'edit';
        polls.push(runProbe(world));
        return polls;
    },
    // Control: the layout swapped but the canvas is blank. Must stay unpainted.
    layoutSwapBlankCanvas(world) {
        world.canvasKind = 'blank';
        const polls = [runProbe(world)];
        assert.equal(arm(world, 's:1'), true);
        enterEdit(world);
        polls.push(runProbe(world));
        return polls;
    },
    // Strict path unchanged: a new tile decode after the entry is evidence.
    newDecodesAfterEntry(world) {
        world.addTile('0:0', true);
        world.canvasKind = 'slide';
        const polls = [runProbe(world)];
        assert.equal(arm(world, 's:1'), true);
        enterEdit(world);
        world.addTile('1:0', true);
        polls.push(runProbe(world));
        return polls;
    },
    // Strict path unchanged: a real canvas repaint after the entry is evidence.
    canvasRepaintAfterEntry(world) {
        world.canvasKind = 'skeleton';
        const polls = [runProbe(world)];
        assert.equal(arm(world, 's:1'), true);
        enterEdit(world);
        world.canvasKind = 'slide';
        polls.push(runProbe(world));
        return polls;
    },
    // Escape hatch unchanged: the layout switched before the first probe poll
    // (ungated early entry), so no baseline exists and the facts decide.
    earlySwitchBeforeFirstPoll(world) {
        world.fileBasedView = false;
        world.layout = 'ViewLayoutImpress';
        world.canvasKind = 'slide';
        world.addTile('1:0', true);
        return [runProbe(world)];
    },
};

const world = makeWorld({
    fileBasedView: true, docLoaded: true, docType: 'presentation',
});
const results = {};
for (const name of Object.keys(scenarios)) {
    const fresh = makeWorld({
        fileBasedView: true, docLoaded: true, docType: 'presentation',
    });
    results[name] = scenarios[name](fresh);
}
console.log(JSON.stringify(results));
'''


def probe_source():
    host = HOST_SOURCE.read_text()
    script = host.split('// FLOE_RENDER_PROBE_SCRIPT_BEGIN', 1)[1]
    script = script.split('// FLOE_RENDER_PROBE_SCRIPT_END', 1)[0]
    return script.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]


class EditSurfaceEvidence(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix='floe-edit-surface-') as folder:
            harness = Path(folder) / 'sequences.js'
            harness.write_text('const SOURCE = ' + json.dumps(probe_source()) + ';\n' + HARNESS)
            result = subprocess.run(['node', str(harness)],
                                    capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise AssertionError('sequence harness failed: ' + result.stderr[-3000:])
            cls.results = json.loads(result.stdout)

    def verdicts(self, scenario):
        return [bool(poll['editSurfacePainted']) for poll in self.results[scenario]]

    def test_layout_swap_with_painted_content_repairs_the_reuse_false_negative(self):
        # The regression: before the layout-swap receipt this read [false, false]
        # and the session-ready threshold could never fire on a healthy editor.
        self.assertEqual(self.verdicts('tileReuseLayoutSwapPainted'), [False, True])

    def test_tile_reuse_without_the_swap_receipt_stays_strict(self):
        self.assertEqual(self.verdicts('tileReuseNoLayoutSwap'), [False, False])

    def test_a_blank_canvas_never_qualifies(self):
        self.assertEqual(self.verdicts('layoutSwapBlankCanvas'), [False, False])

    def test_new_tile_decodes_after_the_entry_remain_evidence(self):
        self.assertEqual(self.verdicts('newDecodesAfterEntry'), [False, True])

    def test_canvas_repaint_after_the_entry_remains_evidence(self):
        self.assertEqual(self.verdicts('canvasRepaintAfterEntry'), [False, True])

    def test_the_no_baseline_escape_hatch_is_unchanged(self):
        self.assertEqual(self.verdicts('earlySwitchBeforeFirstPoll'), [True])

    def test_diagnostics_expose_the_layout_receipt(self):
        poll = self.results['tileReuseLayoutSwapPainted'][1]
        self.assertEqual(poll['editSurfaceLayoutChanged'], True)
        self.assertEqual(poll['editSurfaceLayout'], 'ViewLayoutImpress')
        strict = self.results['tileReuseNoLayoutSwap'][1]
        self.assertEqual(strict['editSurfaceLayoutChanged'], False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
