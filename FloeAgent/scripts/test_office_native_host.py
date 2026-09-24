#!/usr/bin/env python3
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
from build_office_native_host import (EXCLUDED_SOURCES, SYSTEM_FRAMEWORKS, HOST_PUBLIC_HEADER,
                                      SWIFT_IMPORT_PROBE, framework_project,
                                      verify_swift_import_probe)
import build_office_native_host as build_host
import office_render_gate_swift
import office_render_readiness
import office_simulator_guard
from qualify_office_device_capabilities import qualify as device_qualify
from verify_pptx_deck_semantics import DEFAULT_DECK, digest
from office_release_gates import (CAPABILITY_FLAGS, capability_status, false_capabilities,
                                  host_source_matches_pin, validate_capability_claims)
from pin_office_host_artifact import LOCK, check as pin_check

HOST_SOURCE = HOST_PUBLIC_HEADER.parent / 'FloeOfficeNative.mm'


def host_fragment(text, begin, end):
    return text.split(begin, 1)[1].split(end, 1)[0]


def host_raw_literal(text, begin, end):
    """The JavaScript payload of a shipped `R"FLOE_JS(...)FLOE_JS"` fragment."""
    body = host_fragment(text, begin, end)
    return body.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]


class OfficeEditEntryDeferralTests(unittest.TestCase):
    """The shipped host gates the presentation edit entry on the first paint.

    Build 225's device white screen: the host drove the guarded mobile edit
    entry on the open-permission clock — as soon as `app.file.readOnly` was a
    boolean, before the engine's first status delivered the document extent.
    For the file-based presentation formats that switched
    `ImpressTileLayer._switchToPartBasedView` on an empty extent, building an
    edit surface that never painted (while the preview, which keeps the
    file-based view, painted fine). These pins hold the causal repair: the
    entry is paint-gated, the open-permission report settles exactly once, and
    a close owns the pending entry.
    """

    def source(self):
        return HOST_SOURCE.read_text()

    def test_presentation_entry_is_paint_gated_and_word_excel_unchanged(self):
        source = self.source()
        # The permission-probe completion routes file-based formats through the
        # paint-gated deferral and runs every other format directly.
        self.assertIn('if (FloeDocumentRequiresVisibleRender(probed.workingFileURL.pathExtension))',
                      source)
        self.assertIn('[probed deferEditEntryUntilFirstPaint];', source)
        self.assertIn('[probed runEditEntryAndReport];', source)
        # The deferral parks the entry; the first-paint trigger runs it.
        self.assertIn('- (void)deferEditEntryUntilFirstPaint {', source)
        self.assertIn('- (void)runEditEntryAndReport {', source)
        self.assertIn('if (self.editEntryPending) [self runEditEntryAndReport];', source)
        # The probe's finish decision requires the part-based edit surface for
        # an editable session; a file-based startup paint is preview evidence.
        self.assertIn('FloeRenderFactsSatisfySessionReady(renderFacts, probe.readOnlySession, fileBasedView)',
                      source)

    def test_edit_surface_paint_evidence_gates_ready_after_the_entry(self):
        """The shipped gate requires a paint after the edit entry, not a flag."""
        source = self.source()
        # The session-ready threshold consumes the edit-surface paint evidence;
        # the decoded tile count plus the cleared flag are never enough.
        gate = host_fragment(source, '// FLOE_EDIT_ENTRY_GATE_BEGIN', '// FLOE_EDIT_ENTRY_GATE_END')
        self.assertIn('return facts.editSurfacePainted;', gate)
        self.assertNotIn('return readOnly || !fileBasedView;', gate)
        decision = host_fragment(source, '// FLOE_RENDER_DECISION_BEGIN', '// FLOE_RENDER_DECISION_END')
        self.assertIn('bool editSurfacePainted;', decision)
        # The arm runs immediately before the guarded entry for the same
        # file-based formats, and the probe reads the evidence boolean.
        run_entry = source.split('- (void)runEditEntryAndReport {', 1)[1] \
                          .split('- (void)settlePendingEditEntryWithoutEntry {', 1)[0]
        self.assertIn('if (FloeDocumentRequiresVisibleRender(self.workingFileURL.pathExtension))', run_entry)
        self.assertIn('[self armEditSurfaceEvidenceWithCompletion:performEntry];', run_entry)
        # The entry block is handed to the arm completion; the direct call is
        # the non-file-based (Word/Excel) branch only.
        lines = [line.strip() for line in run_entry.splitlines()]
        self.assertEqual(lines.count('performEntry();'), 1)
        self.assertEqual(lines[lines.index('performEntry();') - 1], '} else {')
        arm = source.split('- (void)armEditSurfaceEvidenceWithCompletion:(void (^)(void))completion {', 1)[1] \
                    .split('- (void)deferEditEntryUntilFirstPaint {', 1)[0]
        self.assertIn('FloeEditSurfaceArmScript(token)', arm)
        # The entry proceeds only after the arm eval completed (a page error
        # still calls it; the probe keeps its own last baseline).
        self.assertLess(arm.index('evaluateJavaScript:FloeEditSurfaceArmScript(token)'),
                        arm.rindex('completion();'))
        # The arm script is the token-carrying call into the page helper the
        # shipped probe installs; a missing helper never blocks the entry.
        arm_script = host_fragment(source, '// FLOE_EDIT_SURFACE_ARM_SCRIPT_BEGIN',
                                   '// FLOE_EDIT_SURFACE_ARM_SCRIPT_END')
        self.assertIn("typeof window.__floeArmEditSurface !== 'function'", arm_script)
        self.assertIn('window.__floeArmEditSurface(__FLOE_EDIT_SURFACE_TOKEN__)', arm_script)
        self.assertIn('withString:literal', arm_script)
        # The probe computes the evidence against the last file-based frame and
        # tracks the engine's tile image identities, not a cumulative count.
        self.assertIn('window.__floeArmEditSurface = function (token)', source)
        self.assertIn('baseline.images.get(key) !== image', source)
        self.assertIn('canvasRepainted = changedSamples >= 4;', source)

    def test_render_ready_never_precedes_the_edit_entry_ack(self):
        """The deferred entry's acknowledgement settles before the ready signal."""
        source = self.source()
        # The probe holds the ready decision until the entry/one-shot report
        # settled; an entry that ends in a password prompt or a refusal must
        # not already have declared the edit surface ready.
        self.assertIn('expectsDeferredEditEntry', source)
        self.assertIn('if (ready && probe.expectsDeferredEditEntry && '
                      '![probe.controller hasSettledOpenPermission])', source)
        self.assertIn('- (BOOL)hasSettledOpenPermission {', source)
        settle = source.split('- (BOOL)hasSettledOpenPermission {', 1)[1].split('\n}', 1)[0]
        self.assertIn('return self.openPermissionReported;', settle)
        # The acknowledgement is the one-shot report the entry settles; the
        # ready log records it.
        self.assertIn('@"entrySettled": @(self.openPermissionReported)', source)
        # The probe only reads the acknowledgement for the deferred path: a
        # preview or a Word/Excel session keeps its timing.
        probe_init = source.split('- (instancetype)initWithController:', 1)[1].split('return self;', 1)[0]
        self.assertIn('_expectsDeferredEditEntry = _requiresVisibleRender && !readOnly;', probe_init)

    def test_open_permission_report_settles_exactly_once(self):
        source = self.source()
        # Every report path funnels through the one-shot reporter, which is
        # guarded by the per-generation latch. A late probe/entry completion
        # can never report a second permission over a settled one.
        self.assertIn('- (void)reportOpenPermissionOnce:(BOOL)success readOnly:(BOOL)readOnly {',
                      source)
        self.assertIn('if (self.openPermissionReported) return;', source)
        # The only direct callback invocation lives inside the one-shot
        # reporter; every other report path calls the reporter instead.
        self.assertEqual(
            source.count('self.onWorkingCopyOpenedWithPermission(success, readOnly)'), 1)
        call_sites = [line for line in source.splitlines()
                      if 'reportOpenPermissionOnce:' in line
                      and not line.strip().startswith('- (void)reportOpenPermissionOnce')]
        self.assertGreaterEqual(len(call_sites), 6)
        # No path may invoke the callback directly with a literal result any
        # more: the literal-result invocations were the unguarded duplicates.
        for line in source.splitlines():
            if 'onWorkingCopyOpenedWithPermission(' in line and 'void (^' not in line:
                self.assertIn('self.onWorkingCopyOpenedWithPermission(success, readOnly)', line)

    def test_pending_entry_is_dropped_at_close_and_settles_on_probe_failure(self):
        source = self.source()
        # A close owns the outcome: a paint-gated entry never runs against a
        # surface that is going away.
        begin_close = source.split('- (void)beginClose {', 1)[1].split('- (void)settleCloseWaitersWithError:', 1)[0]
        self.assertIn('self.editEntryPending = NO;', begin_close)
        # The probe-failure path settles a still-pending entry without forcing
        # an entry on an engine that never proved a paint.
        self.assertIn('[self settlePendingEditEntryWithoutEntry];', source)
        settle = source.split('- (void)settlePendingEditEntryWithoutEntry {', 1)[1] \
                     .split('- (void)insertAttachmentFromFileURL:', 1)[0]
        self.assertIn('if (!self.editEntryPending) return;', settle)
        self.assertIn('[self reportOpenPermissionOnce:YES readOnly:self.sessionIsReadOnly];', settle)

    def test_close_and_failure_settle_every_waiter_exactly_once(self):
        """The close waiters, the render probe and the entry each settle once."""
        source = self.source()
        # Close waiters: one drain that copies then empties the list, so a
        # second close (or a late engine ack) can never resume a waiter twice.
        begin_close = source.split('- (void)beginClose {', 1)[1] \
                            .split('- (void)listAttachmentsWithCompletion:', 1)[0]
        self.assertIn('[self settleCloseWaitersWithError:', begin_close)
        drain = source.split('- (void)settleCloseWaitersWithError:(NSError *)error {', 1)[1] \
                      .split('\n}', 1)[0]
        self.assertIn('NSArray *waiters = [self.closeWaiters copy];', drain)
        self.assertIn('[self.closeWaiters removeAllObjects];', drain)
        self.assertIn('completion(error);', drain)
        # The render probe finishes or cancels exactly once: the poll and the
        # deadline timer both bail on the terminal flags.
        probe = source.split('@implementation FloeOfficeRenderProbe {', 1)[1] \
                      .split('// FLOE_RENDER_PROBE_END', 1)[0]
        self.assertIn('if (_finished || _cancelled) return;', probe)
        self.assertIn('if (!probe || probe->_finished || probe->_cancelled) return;', probe)
        self.assertIn('- (void)finishWithStage:(NSString *)stage {', probe)
        self.assertIn('- (void)cancel {', probe)
        # A close also settles the close waiters on the never-opened path, and
        # the engine ack path settles them through floeCloseCompletion.
        calls = [line for line in begin_close.splitlines() if '[self settleCloseWaitersWithError:' in line]
        self.assertEqual(len(calls), 1, calls)
        self.assertIn('[host settleCloseWaitersWithError:success ? nil : OfficeError(10', source)
        # The edit entry reports through the one-shot latch on every path; the
        # completion itself cannot double-report (already asserted above).
        self.assertEqual(source.count('self.onWorkingCopyOpenedWithPermission(success, readOnly)'), 1)

    def test_stage_logs_carry_correlation_ids(self):
        source = self.source()
        # open / permission / edit entry / paint / save stages each carry the
        # per-controller session id and open generation, content-free.
        for event in ('@"open"', '@"permission"', '@"edit-entry-deferred"', '@"edit-entry"',
                      '@"edit-entry-result"', '@"edit-surface-armed"', '@"first-paint"',
                      '@"visible-render"', '@"save-requested"', '@"save-completed"'):
            self.assertIn(event, source)
        self.assertIn('_sessionID = [[NSUUID UUID] UUIDString];', source)
        self.assertIn('self.openGeneration += 1;', source)
        self.assertGreaterEqual(source.count('@"session": self.sessionID'), 6)
        self.assertGreaterEqual(source.count('@"session": host.sessionID'), 1)
        self.assertGreaterEqual(source.count('@"generation": @(self.openGeneration)'), 4)

    def test_extent_bootstrap_fallback_is_bounded_and_never_relaxes_readiness(self):
        """The parked edit entry has a bounded weaker-evidence trigger tier.

        Build 227's distinct Workspace/Notes symptom: the preview paints, but
        pressing Edit leaves the surface on the opening spinner because the
        paint-gated entry waited for a decoded tile that never arrived, and
        only the 25s deadline settled it (without ever building the edit
        surface). The fallback runs the guarded entry once the engine proved
        the document extent (type + loaded document + sized canvas — strictly
        later than the open-permission clock of the Build 225 white screen),
        after a bounded grace. The session-ready threshold is untouched:
        readiness still demands the post-entry paint, so the fallback can
        never ready a session whose edit surface did not really paint.
        """
        source = self.source()
        # The deferral stamps the park time the fallback measures from, and the
        # run/settle paths clear it with the pending flag.
        defer = source.split('- (void)deferEditEntryUntilFirstPaint {', 1)[1] \
                      .split('- (void)runEditEntryAndReport {', 1)[0]
        self.assertIn('self.editEntryDeferredAt = [NSDate date];', defer)
        run = source.split('- (void)runEditEntryAndReport {', 1)[1] \
                    .split('- (void)settlePendingEditEntryWithoutEntry {', 1)[0]
        self.assertIn('self.editEntryDeferredAt = nil;', run)
        settle = source.split('- (void)settlePendingEditEntryWithoutEntry {', 1)[1] \
                       .split('- (BOOL)hasPendingDeferredEditEntry {', 1)[0]
        self.assertIn('self.editEntryDeferredAt = nil;', settle)
        # The fallback consults the parked state and a pure, compiled gate.
        self.assertIn('- (BOOL)hasPendingDeferredEditEntry {', source)
        self.assertIn('- (NSTimeInterval)deferredEditEntryParkedSeconds {', source)
        self.assertIn('FloeDeferredEditEntryExtentBootstrapEligible(', source)
        self.assertIn('static const NSTimeInterval FloeEditEntryExtentBootstrapGraceSeconds = 5.0;',
                      source)
        # It applies to the deferred (editable file-based) entry only. The
        # weaker extent proof must never masquerade as a decoded first paint.
        poll = source.split('- (void)poll {', 1)[1].split('(FloeRenderFacts)renderFactsFromDictionary:', 1)[0]
        self.assertIn('probe.expectsDeferredEditEntry', poll)
        self.assertIn('[probe.controller renderProbeDidProveExtentForEditEntry];', poll)
        self.assertIn('if (paintTrigger && !probe->_firstPaintReported)', poll)
        self.assertIn('[probe.controller renderProbeDidObserveFirstPaint:probe.diagnostics];', poll)
        self.assertIn('- (void)renderProbeDidProveExtentForEditEntry {', source)
        self.assertIn('@"edit-entry-extent-bootstrap"', source)
        # Readiness is unchanged: the shipped session-ready threshold still
        # returns the edit-surface paint evidence, and the ready signal still
        # waits for the entry's own acknowledgement.
        gate = host_fragment(source, '// FLOE_EDIT_ENTRY_GATE_BEGIN', '// FLOE_EDIT_ENTRY_GATE_END')
        self.assertIn('return facts.editSurfacePainted;', gate)
        self.assertIn('FloeDeferredEditEntryExtentBootstrapEligible(BOOL entryPending,', gate)



class OfficeEditEntryGateTests(unittest.TestCase):
    """Compile and exercise the shipped two-threshold render decision.

    The edit-entry trigger and the session-ready threshold are compiled from
    the actual shipped source and driven with synthetic engine states: a
    decoded tile on the file-based startup triggers the entry but never
    readies an editable session; only a paint of the part-based edit surface
    *after* the entry does.
    """

    HARNESS = r'''
static FloeRenderFacts facts(bool type, bool loaded, bool canvas, bool tile, bool editPainted) {
    FloeRenderFacts value;
    value.docTypeKnown = type; value.docLoaded = loaded; value.canvasSized = canvas;
    value.tileDecoded = tile; value.pixelPainted = false; value.vectorRendering = false;
    value.editSurfacePainted = editPainted;
    return value;
}
int main() { @autoreleasepool {
    // A decoded tile on the file-based startup: the edit entry may run, but an
    // editable session is not ready on preview evidence.
    assert(FloeRenderFactsSatisfyEditEntryTrigger(facts(true, true, true, true, false)));
    assert(!FloeRenderFactsSatisfySessionReady(facts(true, true, true, true, false), false, true));
    // The counterexample: the file-based flag was cleared and the preview's
    // decoded tiles are still in the engine's shared tile map, but the edit
    // surface itself never painted. This must never read as ready.
    assert(!FloeRenderFactsSatisfySessionReady(facts(true, true, true, true, false), false, false));
    // The edit surface painted after the switch: only now is the session ready.
    assert(FloeRenderFactsSatisfySessionReady(facts(true, true, true, true, true), false, false));
    // A read-only preview is ready on the same file-based paint.
    assert(FloeRenderFactsSatisfySessionReady(facts(true, true, true, true, false), true, true));
    // Word/Excel keep their contract: not file-based, no preview frame to
    // mistake for the edit surface, so the shipped probe reports painted.
    assert(FloeRenderFactsSatisfySessionReady(facts(true, true, true, true, true), false, false));
    // Skeletons, an unloaded document or an unknown type never trigger either.
    assert(!FloeRenderFactsSatisfyEditEntryTrigger(facts(true, true, true, false, false)));
    assert(!FloeRenderFactsSatisfyEditEntryTrigger(facts(true, false, true, true, false)));
    assert(!FloeRenderFactsSatisfyEditEntryTrigger(facts(false, true, true, true, false)));
    assert(!FloeRenderFactsSatisfySessionReady(facts(true, true, true, false, true), false, false));
    assert(!FloeRenderFactsSatisfySessionReady(facts(true, true, true, true, true), false, true));
    // The extent-bootstrap fallback: a parked entry, a proven document extent
    // and a wait past the bounded grace may run the guarded entry; anything
    // less may not, and the fallback never applies once the entry settled.
    assert(FloeDeferredEditEntryExtentBootstrapEligible(YES, NO, NO, true, 5.0));
    assert(FloeDeferredEditEntryExtentBootstrapEligible(YES, NO, NO, true, 30.0));
    assert(!FloeDeferredEditEntryExtentBootstrapEligible(NO, NO, NO, true, 30.0));
    assert(!FloeDeferredEditEntryExtentBootstrapEligible(YES, YES, NO, true, 30.0));
    assert(!FloeDeferredEditEntryExtentBootstrapEligible(YES, NO, YES, true, 30.0));
    assert(!FloeDeferredEditEntryExtentBootstrapEligible(YES, NO, NO, false, 30.0));
    assert(!FloeDeferredEditEntryExtentBootstrapEligible(YES, NO, NO, true, 4.9));
    assert(!FloeDeferredEditEntryExtentBootstrapEligible(YES, NO, NO, true, 0.0));
    // The paint gate applies to the file-based presentation formats only.
    assert(FloeDocumentRequiresVisibleRender(@"pptx"));
    assert(FloeDocumentRequiresVisibleRender(@"odp"));
    assert(!FloeDocumentRequiresVisibleRender(@"docx"));
    assert(!FloeDocumentRequiresVisibleRender(@"xlsx"));
    puts("edit-entry gate passed");
    return 0;
} }
'''

    def test_shipped_two_threshold_gate_compiles_and_holds(self):
        source = HOST_SOURCE.read_text()
        decision = host_fragment(source, '// FLOE_RENDER_DECISION_BEGIN', '// FLOE_RENDER_DECISION_END')
        gate = host_fragment(source, '// FLOE_EDIT_ENTRY_GATE_BEGIN', '// FLOE_EDIT_ENTRY_GATE_END')
        with tempfile.TemporaryDirectory(prefix='floe-edit-entry-gate-') as folder:
            root = Path(folder)
            program = root / 'gate.mm'
            program.write_text('#import <Foundation/Foundation.h>\n#include <cassert>\n#include <cstdio>\n'
                               + decision + '\n' + gate + '\n' + self.HARNESS)
            subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc',
                            '-Wall', '-Werror', '-framework', 'Foundation', str(program),
                            '-o', str(root / 'gate')], check=True, capture_output=True, text=True)
            result = subprocess.run([str(root / 'gate')], check=True, capture_output=True,
                                    text=True, timeout=20)
        self.assertIn('edit-entry gate passed', result.stdout)
        # A compiled gate proves nothing about the engine or a device.
        self.assertNotIn('deviceRoundtripPassed', result.stdout)


class OfficeEditSurfaceEvidenceTests(unittest.TestCase):
    """Run the shipped probe + arm scripts across the preview → edit flip.

    The pinned engine keeps the file-based startup's decoded tiles in its
    shared tile map across `ImpressTileLayer._switchToPartBasedView` (commit
    27b21dc1: the switch only flips `app.file.fileBasedView`, swaps the active
    layout and updates the scroll limits; `BitmapTileManager.tiles` and the
    `RenderManager` instance survive). A decoded tile plus a cleared flag can
    therefore still be the leftover preview frame. These tests run the real
    shipped probe and arm scripts against a persistent synthetic page and pin
    the counterexample the app gate must reject, plus the paints that count.
    """

    HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
const probeSource = PROBE_SOURCE;
const armSource = ARM_SOURCE;
function paintData(kind) {
    const pixels = 24 * 16;
    const colours = {
        blank: [255, 255, 255],
        skeleton: [255, 255, 255, 221, 227, 234],
        slide: [255, 255, 255, 22, 93, 190, 40, 40, 40],
        edited: [250, 250, 245, 200, 60, 30, 15, 15, 15, 90, 90, 90],
    };
    const opaque = {blank: pixels, skeleton: Math.round(pixels * 0.4),
                    slide: Math.round(pixels * 0.8), edited: Math.round(pixels * 0.7)};
    const data = new Uint8ClampedArray(pixels * 4);
    const palette = colours[kind] || colours.blank;
    const count = palette.length / 3;
    for (let i = 0; i < pixels; i++) {
        const index = (i % count) * 3;
        data[i * 4] = palette[index];
        data[i * 4 + 1] = palette[index + 1];
        data[i * 4 + 2] = palette[index + 2];
        data[i * 4 + 3] = i < opaque[kind] ? 255 : 0;
    }
    return data;
}
function makeCanvas() {
    return {
        width: 1024, height: 768, clientWidth: 1024, clientHeight: 768, paint: 'blank',
        getContext: () => ({
            drawImage(source) { this.paint = source.paint; },
            getImageData: () => ({data: paintData(this.paint)}),
        }),
    };
}
function makePage() {
    const canvases = [makeCanvas()];
    const document = {
        readyState: 'complete',
        querySelectorAll: (selector) => (selector === 'canvas' ? canvases : []),
        createElement: () => ({width: 0, height: 0, getContext: () => ({
            paint: 'blank',
            drawImage(source) { this.paint = source.paint; },
            getImageData() { return {data: paintData(this.paint)}; },
        })}),
    };
    const state = {tiles: new Map()};
    const app = {file: {fileBasedView: true, readOnly: false}};
    const window = {app: app};
    app.map = {
        _docLoaded: true,
        _docLayer: {_docType: 'presentation'},
        isEditMode: () => false,
        _permission: 'readonly',
        getDocType() { return 'presentation'; },
    };
    window.RenderManager = {
        getTiles: () => state.tiles,
        isVectorRendering: () => false,
    };
    const context = vm.createContext({window: window, document: document, console: console});
    return {
        state: state,
        canvases: canvases,
        window: window,
        run: () => vm.runInContext(probeSource, context),
        arm: () => vm.runInContext(armSource, context),
    };
}
function decoded(image) { return {image: image, isReadyToDraw() { return !!this.image; }}; }

// Scenario A: the counterexample. The preview painted a slide, the host armed
// the evidence through the shipped arm script, then the flag flipped while the
// old decoded tile and the preview canvas both remain.
{
    const page = makePage();
    page.state.tiles.set('0:0:8:0:0', decoded({id: 'preview-image'}));
    page.canvases[0].paint = 'slide';
    let facts = page.run();
    assert.equal(facts.editSurfacePainted, false, 'a file-based preview frame is never edit evidence');
    assert.equal(page.arm(), true, 'the shipped arm script must arm the page helper');
    page.window.app.file.fileBasedView = false;
    facts = page.run();
    assert.equal(facts.fileBasedView, false, 'the flag flipped');
    assert.equal(facts.decodedTiles, 1, 'the old preview tile is still decoded in the shared map');
    assert.equal(facts.editSurfaceBaseline, true, 'the preview frame is the baseline');
    assert.equal(facts.editSurfaceArmed, true, 'the edit entry armed the evidence');
    assert.equal(facts.editSurfacePainted, false,
                 'old preview tiles plus an unchanged canvas must not read as edit paint');
    // Real edit-surface paint: the document canvas was repainted after the
    // switch. Only now may the session read as painted.
    page.canvases[0].paint = 'edited';
    facts = page.run();
    assert.equal(facts.editSurfacePainted, true, 'a repainted document canvas is edit-surface paint');
}
// Scenario B: a tile decoded after the switch (a different image object for
// the same tile key) is edit-surface paint even with an unchanged canvas.
{
    const page = makePage();
    page.state.tiles.set('0:0:8:0:0', decoded({id: 'preview-image'}));
    page.canvases[0].paint = 'slide';
    page.run();
    assert.equal(page.arm(), true);
    page.window.app.file.fileBasedView = false;
    assert.equal(page.run().editSurfacePainted, false);
    page.state.tiles.get('0:0:8:0:0').image = {id: 'edit-image'};
    const facts = page.run();
    assert.equal(facts.editSurfaceNewDecodes, 1, 'the same key with a new image object is a new decode');
    assert.equal(facts.editSurfacePainted, true, 'a tile decoded after the entry is edit-surface paint');
}
// Scenario C: no file-based frame was ever observed on this page (a page that
// starts directly in the part-based view). There is no observed pre-edit frame
// to mistake for the edit surface, so the visible-render facts remain the
// evidence, exactly as before this fix.
{
    const page = makePage();
    page.window.app.file.fileBasedView = false;
    page.state.tiles.set('0:0:8:0:0', decoded({id: 'edit-image'}));
    page.canvases[0].paint = 'edited';
    const facts = page.run();
    assert.equal(facts.editSurfaceBaseline, false);
    assert.equal(facts.editSurfacePainted, true);
}
console.log('edit-surface evidence passed');
'''

    def source(self):
        return HOST_SOURCE.read_text()

    def test_shipped_edit_surface_evidence_rejects_the_stale_preview_frame(self):
        text = self.source()
        probe = host_raw_literal(text, '// FLOE_RENDER_PROBE_SCRIPT_BEGIN',
                                 '// FLOE_RENDER_PROBE_SCRIPT_END')
        arm_template = host_raw_literal(text, '// FLOE_EDIT_SURFACE_ARM_SCRIPT_BEGIN',
                                        '// FLOE_EDIT_SURFACE_ARM_SCRIPT_END')
        self.assertIn('__FLOE_EDIT_SURFACE_TOKEN__', arm_template)
        arm = arm_template.replace('__FLOE_EDIT_SURFACE_TOKEN__', json.dumps('session-1:1'))
        with tempfile.TemporaryDirectory(prefix='floe-edit-surface-') as folder:
            harness = Path(folder) / 'evidence.js'
            harness.write_text('const PROBE_SOURCE = ' + json.dumps(probe) + ';\n'
                               'const ARM_SOURCE = ' + json.dumps(arm) + ';\n' + self.HARNESS)
            result = subprocess.run(['node', str(harness)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError('edit-surface harness failed: ' + result.stdout + result.stderr[-2000:])
        self.assertIn('edit-surface evidence passed', result.stdout)
        # The probe still reports only engine facts and counters: no document
        # paths, contents or payload bytes cross the bridge with the evidence.
        for forbidden in ('file_path', 'file:///', 'EDITED_', 'ROUNDTRIP_'):
            self.assertNotIn(forbidden, probe)


class NativeHostProjectTests(unittest.TestCase):
    def project(self):
        objects = {
            'target': {'isa': 'PBXNativeTarget', 'name': 'Mobile', 'productReference': 'product',
                'buildPhases': ['sources', 'resources'], 'buildConfigurationList': 'configs'},
            'product': {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.application'},
            'configs': {'buildConfigurations': ['release']},
            'release': {'buildSettings': {'HEADER_SEARCH_PATHS': ['qualified/engine'],
                'OTHER_LDFLAGS': ['-filelist', 'complete.list'],
                'INFOPLIST_FILE': 'Mobile/Info.plist', 'CODE_SIGN_ENTITLEMENTS': 'upstream.entitlements'}},
            'sources': {'isa': 'PBXSourcesBuildPhase', 'files': []},
            'resources': {'isa': 'PBXResourcesBuildPhase', 'files': []}}
        for name in sorted(EXCLUDED_SOURCES | {'CODocument.mm', 'DocumentViewController.mm', 'Kit.cpp'}):
            objects[name] = {'isa': 'PBXFileReference', 'path': name}
            objects['build-' + name] = {'isa': 'PBXBuildFile', 'fileRef': name}
            objects['sources']['files'].append('build-' + name)
        for name in ['rc', 'program', 'share', 'cool.html', 'bundle.js', 'Assets.xcassets', 'Settings.bundle', 'Templates']:
            objects[name] = {'isa': 'PBXFileReference', 'path': name}
            objects['resource-' + name] = {'fileRef': name}
            objects['resources']['files'].append('resource-' + name)
        return {'objects': objects}

    def test_replaces_application_lifetime_but_retains_real_editor_and_engine(self):
        original = self.project()
        unchanged = copy.deepcopy(original)
        prepared = framework_project(original, Path('/owned host'))['objects']
        files = [prepared[prepared[key]['fileRef']]['path'] for key in prepared['sources']['files']]
        self.assertEqual(set(files), {'CODocument.mm', 'DocumentViewController.mm', 'Kit.cpp',
                                    '/owned host/FloeOfficeNative.mm', '/owned host/FloeOfficeAttachment.cpp'})
        self.assertEqual(original, unchanged)
        self.assertEqual(prepared['target']['productType'], 'com.apple.product-type.framework')

    def test_keeps_runtime_resources_and_complete_link_inputs_without_app_identity(self):
        prepared = framework_project(self.project(), Path('/host'))['objects']
        self.assertEqual(prepared['resources']['files'], ['resource-' + name for name in ['rc', 'program', 'share', 'cool.html', 'bundle.js']])
        settings = prepared['release']['buildSettings']
        self.assertEqual(settings['OTHER_LDFLAGS'], ['-filelist', 'complete.list']
            + [flag for name in SYSTEM_FRAMEWORKS for flag in ['-framework', name]])
        self.assertEqual(settings['HEADER_SEARCH_PATHS'], ['qualified/engine'])
        self.assertNotIn('CODE_SIGN_ENTITLEMENTS', settings)
        self.assertEqual(settings['MACH_O_TYPE'], 'mh_dylib')

    def test_changed_upstream_application_boundary_fails_closed(self):
        project = self.project()
        project['objects']['sources']['files'].remove('build-main.m')
        with self.assertRaisesRegex(ValueError, 'boundaries changed'):
            framework_project(project, Path('/host'))


class SwiftImportProbeContractTests(unittest.TestCase):
    """The generated ImportProbe must match how Swift imports the host header."""

    @staticmethod
    def _iphoneos_sdk():
        result = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'],
                                capture_output=True, text=True)
        path = result.stdout.strip()
        return path if result.returncode == 0 and path else None

    def test_header_and_probe_agree_on_render_diagnostics(self):
        # Static contract: the property the cloud run rejected is imported from
        # NSDictionary<NSString *, id> * into Swift as [String: Any]?. This pins
        # the expectation to the real public declaration even without an SDK.
        header = HOST_PUBLIC_HEADER.read_text()
        self.assertRegex(
            header,
            r'@property[^\n]*nullable\)\s*NSDictionary<NSString \*, id> \*renderDiagnostics;')
        probe = SWIFT_IMPORT_PROBE.read_text()
        self.assertIn('let _: [String: Any]? = editor.renderDiagnostics', probe)
        self.assertNotIn('let _: NSDictionary? = editor.renderDiagnostics', probe)

    def test_build_copies_the_verified_probe_verbatim(self):
        # build_host must generate ImportProbe.swift from the exact fixture this
        # contract checks, not a second, drifting copy.
        source = Path(__file__).resolve().parent / 'build_office_native_host.py'
        text = source.read_text()
        self.assertIn('shutil.copyfile(SWIFT_IMPORT_PROBE, probe)', text)
        self.assertEqual(SWIFT_IMPORT_PROBE.name, 'office_native_host_api.swift')

    def test_generated_probe_compiles_against_the_real_host_header(self):
        sdk = self._iphoneos_sdk()
        if not sdk:
            self.skipTest('iphoneos SDK unavailable; the cloud build runs this gate')
        receipt = verify_swift_import_probe(sdk=sdk)
        self.assertTrue(receipt['swiftImportProbeCompiled'])
        # A header-only type-check must never fabricate an engine/device result.
        self.assertFalse(receipt['engineVisibleRenderPassed'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])
        self.assertEqual(receipt['swiftProbeSHA256'],
                         hashlib.sha256(SWIFT_IMPORT_PROBE.read_bytes()).hexdigest())

    def test_old_nsdictionary_expectation_is_rejected(self):
        # The exact cloud regression: NSDictionary? against a property Swift
        # imports as [String: Any]? must fail the gate rather than be weakened.
        sdk = self._iphoneos_sdk()
        if not sdk:
            self.skipTest('iphoneos SDK unavailable; the cloud build runs this gate')
        buggy = SWIFT_IMPORT_PROBE.read_text().replace(
            'let _: [String: Any]? = editor.renderDiagnostics',
            'let _: NSDictionary? = editor.renderDiagnostics')
        self.assertIn('NSDictionary?', buggy)
        with tempfile.TemporaryDirectory() as folder:
            bad_probe = Path(folder) / 'office_native_host_api.swift'
            bad_probe.write_text(buggy)
            with mock.patch.object(build_host, 'SWIFT_IMPORT_PROBE', bad_probe):
                with self.assertRaisesRegex(AssertionError, r"\[String : Any\]\?.*NSDictionary\?|ImportProbe"):
                    verify_swift_import_probe(sdk=sdk)


class AppSimulatorImportGuardTests(unittest.TestCase):
    """The App keeps compiling where the pinned host is absent.

    `FloeOfficeNative` is linked into iphoneos builds only, so the simulator
    target compiles the Office editor with `canImport(FloeOfficeNative)` false.
    A host-typed reference outside that guard is a hard compile error in the
    CI step that builds the App regression host — the rebuilt presentation host
    added `hostSupportsVisibleRender(_:)` and `startRenderWatchdog(for:)`
    outside it and broke the simulator target while the device path stayed
    correct.
    """

    def test_app_sources_keep_every_host_typed_reference_behind_the_guard(self):
        receipt = office_simulator_guard.check()
        self.assertTrue(receipt['simulatorGuardPassed'])
        self.assertGreater(receipt['appSourcesScanned'], 0)
        self.assertTrue(receipt['visibleRenderGateArmedInGuard'])
        # A static boundary proves nothing about the engine or a device.
        self.assertFalse(receipt['engineVisibleRenderPassed'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])

    def test_detector_rejects_the_watchdog_that_broke_the_simulator(self):
        broken = (
            "    #if canImport(FloeOfficeNative)\n"
            "    private func startOpenWatchdog(for native: FloeOfficeNativeViewController) {}\n"
            "    #endif\n"
            "\n"
            "    private static func hostSupportsVisibleRender(_ native: FloeOfficeNativeViewController) -> Bool {\n"
            "        true\n"
            "    }\n"
        )
        violations = office_simulator_guard.unguarded_host_references(broken, 'regression')
        self.assertEqual(len(violations), 1, violations)
        self.assertTrue(violations[0].startswith('regression:5:'), violations)

        guarded = (
            "    #if canImport(FloeOfficeNative)\n"
            "    private static func hostSupportsVisibleRender(_ native: FloeOfficeNativeViewController) -> Bool {\n"
            "        true\n"
            "    }\n"
            "    #endif\n"
        )
        self.assertEqual(office_simulator_guard.unguarded_host_references(guarded, 'fixed'), [])

    def test_the_absent_framework_branch_counts_as_unguarded(self):
        # The `#else` branch compiles exactly when FloeOfficeNative is absent,
        # so a host-typed reference there still breaks the simulator target.
        text = (
            "    #if canImport(FloeOfficeNative)\n"
            "    let native = FloeOfficeNativeViewController()\n"
            "    #else\n"
            "    private static func wrong(_ native: FloeOfficeNativeViewController) {}\n"
            "    #endif\n"
        )
        violations = office_simulator_guard.unguarded_host_references(text, 'else-branch')
        self.assertEqual(len(violations), 1, violations)
        self.assertTrue(violations[0].startswith('else-branch:4:'), violations)


class OfficeReleaseGateTests(unittest.TestCase):
    def evidenced(self):
        return {
            'capabilityQualification': {
                'embeddedEditorPassed': True,
                'pptxVisibleRenderPassed': True,
                'deviceRoundtripPassed': True,
                'originalFileWritebackPassed': True,
            },
            'embeddedEditorEvidence': {'runID': '1', 'appBuildVersion': '219', 'payloadVerified': True,
                                       'recordedAt': '2026-09-22T00:00:00Z'},
            'pptxVisibleRenderEvidence': {'runID': '2', 'deviceModel': 'iPad14,3', 'osVersion': '26.0',
                                          'documentType': 'presentation', 'readyTiles': 6,
                                          'canvasWidth': 1024, 'canvasHeight': 768, 'elapsedMs': 2400,
                                          'recordedAt': '2026-09-22T00:00:00Z'},
            'deviceRoundtripEvidence': {'runID': '2', 'deviceModel': 'iPad14,3', 'osVersion': '26.0',
                                        'documentTypes': ['docx', 'xlsx', 'pptx'],
                                        'recordedAt': '2026-09-22T00:00:00Z'},
            'originalFileWritebackEvidence': {'runID': '2', 'deviceModel': 'iPad14,3',
                                              'documentType': 'pptx',
                                              'savedSHA256': 'a' * 64, 'recordedAt': '2026-09-22T00:00:00Z'},
        }

    def test_compile_only_receipt_cannot_claim_release_capabilities(self):
        self.assertEqual(validate_capability_claims({'capabilityQualification': false_capabilities()}), [])
        status = capability_status({'capabilityQualification': false_capabilities()})
        self.assertFalse(status['releaseReady'])
        self.assertEqual(sorted(status['unproven']), sorted(CAPABILITY_FLAGS))

    def test_fully_evidenced_capabilities_pass_the_release_gate(self):
        status = capability_status(self.evidenced())
        self.assertEqual(status['failures'], [])
        self.assertTrue(status['releaseReady'])

    def test_true_claim_without_evidence_is_rejected(self):
        claims = self.evidenced()
        del claims['pptxVisibleRenderEvidence']
        failures = validate_capability_claims(claims)
        self.assertTrue(any('pptxVisibleRenderPassed is claimed without pptxVisibleRenderEvidence' in failure
                            for failure in failures))
        self.assertFalse(capability_status(claims)['releaseReady'])

    def test_placeholder_or_impossible_device_facts_are_rejected(self):
        for mutation in ({'readyTiles': 0}, {'canvasWidth': 0}, {'canvasHeight': -4},
                         {'documentType': 'text'}, {'readyTiles': 'many'}):
            claims = self.evidenced()
            claims['pptxVisibleRenderEvidence'].update(mutation)
            self.assertTrue(validate_capability_claims(claims), mutation)
        claims = self.evidenced()
        claims['originalFileWritebackEvidence']['savedSHA256'] = 'not-a-digest'
        self.assertTrue(validate_capability_claims(claims))

    def test_inferred_capabilities_are_never_assumed(self):
        # An absent block or absent flag is unproven, never passed; a rejected
        # true claim is not passed either.
        for claims in ({}, {'capabilityQualification': {'embeddedEditorPassed': True}},
                       {'capabilityQualification': None}):
            status = capability_status(claims)
            self.assertFalse(status['releaseReady'])
            self.assertNotIn('passed', status['capabilities'].values())
        self.assertEqual(len(capability_status({})['unproven']), len(CAPABILITY_FLAGS))

    def test_pin_check_reports_capabilities_read_only(self):
        lock = json.loads(Path(LOCK).read_text())
        pin = lock['qualifiedHostArtifact']
        self.assertFalse(host_source_matches_pin({}, hashlib.sha256))
        status = capability_status(pin)
        self.assertFalse(status['releaseReady'])
        self.assertEqual(capability_status({})['unproven'], status['unproven'])
        with tempfile.TemporaryDirectory() as folder:
            copy_path = Path(folder) / 'engine.lock.json'
            copy_path.write_text(json.dumps(lock))
            # Read-only: reports 0 (matches the pin) or 1 (source ahead);
            # either way the lock content is untouched.
            self.assertIn(pin_check(copy_path), (0, 1))
            self.assertEqual(copy_path.read_text(), json.dumps(lock))

    def test_shipped_render_probe_and_native_decision_qualify_visible_render(self):
        # Runs the actual probe script and the compiled native decision against
        # synthetic engine states: a decoded tile passes, page skeletons and a
        # blank canvas never do.
        receipt = office_render_readiness.check()
        self.assertTrue(receipt['nativeDecisionCompiled'])
        self.assertFalse(receipt['engineVisibleRenderPassed'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])
        self.assertEqual(len(receipt['checksPassed']), 8)

    def test_shipped_swift_visible_render_gate_compiles_and_holds(self):
        receipt = office_render_gate_swift.check()
        self.assertTrue(receipt['swiftGateCompiled'])
        self.assertFalse(receipt['deviceVisibleRenderPassed'])
        self.assertEqual(len(receipt['checksPassed']), 6)

    def synthetic_device_receipts(self, folder):
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True)
        deck_digest = digest(DEFAULT_DECK)
        events = [{'event': 'opened'}, {'event': 'visibleRender'}, {'event': 'saveRequested'},
                  {'event': 'saveCompleted', 'detail': 'success'}, {'event': 'editingClosed'},
                  {'event': 'reopenedReadonly'}]
        (folder / 'render-receipt.json').write_text(json.dumps({
            'docType': 'presentation', 'visibleRender': True, 'readyTiles': 5,
            'canvasWidth': 1024, 'canvasHeight': 768, 'slideCount': 3,
            'deckSHA256': deck_digest, 'elapsedMs': 2100, 'recordedAt': '2026-09-22T00:00:00Z'}))
        (folder / 'events.json').write_text(json.dumps({'events': events}))
        for extension in ('docx', 'xlsx', 'pptx'):
            (folder / f'roundtrip-{extension}.json').write_text(json.dumps({
                'documentType': extension, 'edited': True, 'savedWorkingCopy': True,
                'closed': True, 'reopened': True, 'savedSHA256': 'c' * 64, 'events': events}))
        writeback = folder / 'original-writeback.json'
        writeback.write_text(json.dumps({
            'originalFileWriteback': True, 'documentType': 'pptx', 'savedSHA256': 'd' * 64,
            'deckSHA256': deck_digest, 'recordedAt': '2026-09-22T00:00:00Z'}))
        embedded = folder / 'embedding.json'
        embedded.write_text(json.dumps({
            'unsignedPayloadVerified': True, 'appVersion': '1.7.0', 'appBuild': '219',
            'hostExecutableSHA256': 'e' * 64}))
        return folder, writeback, embedded

    def test_device_capabilities_need_a_complete_roundtrip_and_are_never_inferred(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder, writeback, embedded = self.synthetic_device_receipts(temporary)
            evidence, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                                writeback, embedded)
            self.assertEqual(failures, [])
            self.assertTrue(capability_status(evidence)['releaseReady'])
            # Removing any single receipt, or a single device fact, fails closed.
            (folder / 'roundtrip-pptx.json').unlink()
            _, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                         writeback, embedded)
            self.assertTrue(any('roundtrip-pptx.json' in failure for failure in failures))
            folder, writeback, embedded = self.synthetic_device_receipts(temporary + '/second')
            _, failures = device_qualify(folder, DEFAULT_DECK, None, '26.0', '1234', writeback, embedded)
            self.assertTrue(any('device model' in failure for failure in failures))
            folder, writeback, embedded = self.synthetic_device_receipts(temporary + '/third')
            receipt = json.loads((folder / 'render-receipt.json').read_text())
            receipt['readyTiles'] = 0
            (folder / 'render-receipt.json').write_text(json.dumps(receipt))
            _, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                         writeback, embedded)
            self.assertTrue(any('readyTiles' in failure for failure in failures))
            folder, writeback, embedded = self.synthetic_device_receipts(temporary + '/fourth')
            events = {'events': [{'event': 'opened'}, {'event': 'visibleRender'},
                                 {'event': 'unexpectedClose'}]}
            (folder / 'events.json').write_text(json.dumps(events))
            _, failures = device_qualify(folder, DEFAULT_DECK, 'iPad14,3', '26.0', '1234',
                                         writeback, embedded)
            self.assertTrue(any('unexpectedClose' in failure for failure in failures))


if __name__ == '__main__':
    unittest.main()
