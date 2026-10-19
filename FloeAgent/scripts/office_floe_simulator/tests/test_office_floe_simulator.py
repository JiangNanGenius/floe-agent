#!/usr/bin/env python3
"""Lightweight, network-free checks for the real Floe simulator qualification.

Run: python3 -m unittest discover -s scripts/office_floe_simulator/tests
or:  python3 scripts/office_floe_simulator/tests/test_office_floe_simulator.py

These validate pinned inputs and local logic only; they never execute a build
and must not claim a simulator result.
"""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

PKG_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = PKG_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent.parent
sys.path.insert(0, str(PKG_DIR))
sys.path.insert(0, str(SCRIPTS_DIR))
sys.path.insert(0, str(SCRIPTS_DIR / 'office_real_simulator'))

import bootstrap_office_host  # noqa: E402
import embed_office_host  # noqa: E402
import build_simulator_framework  # noqa: E402
import check_floe_render  # noqa: E402
import check_saved_document  # noqa: E402
import install_simulator_host  # noqa: E402
import make_fixture  # noqa: E402
import provision_owned_simulator  # noqa: E402
import release_owned_simulator  # noqa: E402
import resolve_attachments  # noqa: E402
import sim_host_paths  # noqa: E402
import sim_paths  # noqa: E402
import verify_real_engine_trace  # noqa: E402

LOCK = json.loads((REPO_ROOT / 'FloeAgent/ThirdParty/Collabora/engine.lock.json').read_text())
FIXTURE_SHA = sim_paths.FIXTURE_SHA256

WORKFLOW = REPO_ROOT / '.github/workflows/office-floe-simulator.yml'


def make_pptx_bytes(slide_count, marker='Floe SIM QUAL'):
    """Minimal valid OOXML-ish zip the gates accept (slide entries + marker)."""
    import io
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        archive.writestr('[Content_Types].xml', '<Types/>')
        archive.writestr('_rels/.rels', '<Relationships/>')
        archive.writestr('ppt/presentation.xml', '<p:presentation/>')
        for index in range(1, slide_count + 1):
            text = marker if index == 1 else f'Slide {index}'
            archive.writestr(f'ppt/slides/slide{index}.xml',
                             f'<p:sld><p:txBody><a:t>{text}</a:t></p:txBody></p:sld>')
    return buffer.getvalue()


def write_trace(path, events):
    Path(path).write_text('\n'.join(json.dumps(event) for event in events) + '\n')


_AT_COUNTER = [0.0]


def event(session, generation, stage, detail=None, at=None):
    # The real recorder persists Foundation Date as a JSON number; synthetic
    # events mirror that shape (monotonic seconds).
    if at is None:
        _AT_COUNTER[0] += 1.0
        at = _AT_COUNTER[0]
    return {'session': session, 'generation': generation, 'stage': stage,
            'detail': detail or {}, 'at': at}


def reset_clock():
    _AT_COUNTER[0] = 0.0


def preview_generation(session, gen, tiles):
    return [
        event(session, gen, 'render.gate', {'requirement': 'visibleRenderRequired'}),
        event(session, gen, 'controller.mounted',
              {'generation': str(gen), 'readOnly': 'true'}),
        event(session, gen, 'engine.open', {'success': 'true'}),
        event(session, gen, 'engine.visibleRender',
              {'decodedTiles': str(tiles), 'tiles': str(tiles)}),
        event(session, gen, 'notes.open.ready', {'readOnly': 'true'}),
    ]


def edit_generation(session, gen, tiles, *, auto=False, save=True, paint=True,
                    ack=True, confirmed=True, close=True, zero_tile=False,
                    unpainted_g1=False, staged=None, commit=None,
                    stage_g0=True):
    events = []
    if stage_g0 and staged is not None:
        events.append(event(session, 0, 'notes.staged',
                            {'revision': str(staged), 'format': 'pptx'}))
    if auto and unpainted_g1:
        events += [
            event(session, 1, 'controller.mounted',
                  {'generation': '1', 'readOnly': 'true'}),
            event(session, 1, 'close.skippedUnmounted'),
        ]
    events += [
        event(session, gen, 'render.gate', {'requirement': 'visibleRenderRequired'}),
        event(session, gen, 'controller.mounted',
              {'generation': str(gen), 'readOnly': 'false'}),
        event(session, gen, 'engine.open', {'success': 'true'}),
    ]
    if auto:
        events.append(event(session, gen, 'notes.edit.requested', {'entered': 'true'}))
    if paint:
        tiles_value = 0 if zero_tile else tiles
        events.append(event(session, gen, 'engine.visibleRender',
                            {'decodedTiles': str(tiles_value), 'tiles': str(tiles_value)}))
    if ack:
        events.append(event(session, gen, 'edit.entry', {'readOnly': 'false'}))
    if confirmed:
        events.append(event(session, gen, 'edit.acknowledged', {'readOnly': 'false'}))
    if save:
        events.append(event(session, gen, 'save.ok'))
        if commit is not None:
            events.append(event(session, gen, 'notes.commit.ok',
                                {'revision': str(commit)}))
    if close:
        events += [event(session, gen, 'close.started'),
                   event(session, gen, 'close.acked'),
                   event(session, gen, 'session.release')]
    return events


def valid_scenario_trace():
    """The real one-document scenario across three native opens:

    main1: painted preview g1 host-closed -> editable g2 (explicit handoff);
    main2: remembered reopen, unpainted read-only g1 torn down -> editable g2;
    main3: remembered reopen #2 painting its own editable generation.
    """
    events = [
        event('app-launch', 0, 'engine.linked', {'simulator': 'true'}),
        event('qualification', 0, 'qualification.fixture.imported',
              {'sha256': FIXTURE_SHA, 'format': 'pptx'}),
    ]
    events.append(event('main1', 0, 'notes.staged',
                        {'revision': '1', 'format': 'pptx'}))
    events += preview_generation('main1', 1, 12)
    events += [event('main1', 1, 'close.started'),
               event('main1', 1, 'close.acked')]
    events += edit_generation('main1', 2, 14, staged=1, commit=2, stage_g0=False)
    events += edit_generation('main2', 2, 15, auto=True, unpainted_g1=True,
                              staged=2, commit=3)
    events += edit_generation('main3', 2, 15, auto=True, unpainted_g1=True,
                              staged=3, commit=3)
    return events


def valid_receipt():
    receipt = {'phases': [
        {'phase': name, 'ok': True, 'startedAt': float(index),
         'finishedAt': float(index) + 1.0}
        for index, name in enumerate(verify_real_engine_trace.SCENARIO_PHASES)
    ]}
    idle = next(phase for phase in receipt['phases']
                if phase['phase'] == 'idle-120s')
    idle['startedAt'] = 1000.0
    idle['finishedAt'] = 1120.0
    return receipt


def write_receipt(path, receipt):
    Path(path).write_text(json.dumps(receipt))


class TraceGateTests(unittest.TestCase):
    def run_gate(self, events, receipt=None, sha=FIXTURE_SHA):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        trace = Path(tmp.name) / 't.jsonl'
        write_trace(trace, events)
        receipt_path = None
        if receipt is not None:
            receipt_path = Path(tmp.name) / 'receipt.json'
            write_receipt(receipt_path, receipt)
        return verify_real_engine_trace.verify(str(trace), receipt_path,
                                               fixture_sha256=sha)

    def test_valid_trace_passes(self):
        result = self.run_gate(valid_scenario_trace(), valid_receipt())
        self.assertTrue(result['tracePassed'], result['failures'])
        self.assertEqual(result['mainChain'], ['main1', 'main2', 'main3'])
        self.assertEqual(len(result['editWindows']), 3)
        self.assertEqual(result['explicitHandoffSessions'], ['main1'])
        self.assertEqual(len(result['rememberedEditWindows']), 2)

    def test_missing_engine_linked_fails(self):
        events = [e for e in valid_scenario_trace() if e['stage'] != 'engine.linked']
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('engine.linked' in f for f in result['failures']))

    def test_engine_unavailable_fails(self):
        events = valid_scenario_trace() + [
            event('main1', 1, 'engine.unavailable', {'host': 'native-office'})]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('engine.unavailable' in f for f in result['failures']))

    def test_device_linked_flag_fails(self):
        events = valid_scenario_trace()
        for item in events:
            if item['stage'] == 'engine.linked':
                item['detail'] = {'simulator': 'false'}
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])

    def test_missing_fixture_import_fails(self):
        events = [e for e in valid_scenario_trace()
                  if e['stage'] != 'qualification.fixture.imported']
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])

    def test_wrong_fixture_sha_fails(self):
        result = self.run_gate(valid_scenario_trace(), valid_receipt(),
                               sha='0' * 64)
        self.assertFalse(result['tracePassed'])

    def test_failure_stage_fails(self):
        events = valid_scenario_trace() + [
            event('main1', 2, 'runtime.failed', {'phase': 'ready'})]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('runtime.failed' in f for f in result['failures']))

    def test_reopen_edit_generation_blank_fails(self):
        events = [e for e in valid_scenario_trace()
                  if not (e['session'] == 'main2' and e['generation'] == 2
                          and e['stage'] == 'engine.visibleRender')]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('main2' in f for f in result['failures']))

    def test_reopen_zero_tile_paint_fails(self):
        events = valid_scenario_trace()
        for item in events:
            if item['session'] == 'main3' and item['generation'] == 2 \
                    and item['stage'] == 'engine.visibleRender':
                item['detail'] = {'decodedTiles': '0'}
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('decodedTiles=0' in f for f in result['failures']))

    def test_reopen_edit_acknowledgement_missing_fails(self):
        events = [e for e in valid_scenario_trace()
                  if not (e['session'] == 'main2' and e['generation'] == 2
                          and e['stage'] == 'edit.entry')]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])

    def test_reopen_save_missing_fails(self):
        events = [e for e in valid_scenario_trace()
                  if not (e['session'] == 'main2' and e['stage'] == 'save.ok')]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])

    def test_save_parked_on_other_generation_fails(self):
        events = valid_scenario_trace()
        for item in events:
            if item['session'] == 'main2' and item['generation'] == 2 \
                    and item['stage'] == 'save.ok':
                item['generation'] = 1
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])

    def test_predecessor_not_closed_fails(self):
        events = [e for e in valid_scenario_trace()
                  if not (e['session'] == 'main1' and e['stage'] == 'close.acked')]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('save.ok -> close.acked' in f for f in result['failures']))

    def test_predecessor_closed_before_save_fails(self):
        rebuilt = []
        inserted = False
        dropped_trailing_close = False
        saw_save = False
        for item in valid_scenario_trace():
            if item['session'] == 'main1' and item['generation'] == 2 \
                    and item['stage'] == 'save.ok':
                # A close.acked placed BEFORE the save cannot prove a saved
                # reopen lifecycle; drop the trailing close as well.
                rebuilt.append(event('main1', 2, 'close.acked'))
                rebuilt.append(item)
                saw_save = True
                inserted = True
            elif item['session'] == 'main1' and item['generation'] == 2 \
                    and item['stage'] in ('close.started', 'close.acked',
                                          'session.release'):
                if saw_save:
                    dropped_trailing_close = True
                    continue
                rebuilt.append(item)
            else:
                rebuilt.append(item)
        self.assertTrue(inserted and dropped_trailing_close)
        # Events are pre-built with a global clock; re-stamp in file order so
        # the inserted close actually precedes the save in trace time.
        for index, item in enumerate(rebuilt, start=1):
            item['at'] = float(index)
        result = self.run_gate(rebuilt, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('precedes its save.ok' in f for f in result['failures']))

    def test_no_explicit_handoff_fails(self):
        events = [e for e in valid_scenario_trace()
                  if not (e['session'] == 'main1' and e['generation'] == 1)]
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('handoff' in f for f in result['failures']))

    def test_second_handoff_document_fails(self):
        events = valid_scenario_trace()
        events += preview_generation('other', 1, 7)
        events += [event('other', 1, 'close.started'),
                   event('other', 1, 'close.acked')]
        events += edit_generation('other', 2, 8, staged=1, commit=2)
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('ONE imported document' in f for f in result['failures']))

    def test_missing_revision_continuity_fails(self):
        for missing in ('notes.staged', 'notes.commit.ok'):
            with self.subTest(missing=missing):
                events = [e for e in valid_scenario_trace()
                          if e['stage'] != missing]
                result = self.run_gate(events, valid_receipt())
                self.assertFalse(result['tracePassed'])
                self.assertTrue(any('revision continuity' in f for f in result['failures']))

    def test_revision_break_across_reopen_fails(self):
        events = []
        for item in valid_scenario_trace():
            if item['session'] == 'main2' and item['stage'] == 'notes.staged':
                item = event('main2', item['generation'], 'notes.staged',
                             {'revision': '9', 'format': 'pptx'})
            events.append(item)
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('not the same saved document' in f
                            for f in result['failures']))

    def test_missing_second_same_document_reopen_fails(self):
        events = [e for e in valid_scenario_trace() if e['session'] != 'main3']
        result = self.run_gate(events, valid_receipt())
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('chain stops' in f for f in result['failures']))

    def test_absent_receipt_fails(self):
        result = self.run_gate(valid_scenario_trace(), receipt=None)
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('receipt' in f for f in result['failures']))

    def test_missing_receipt_phase_fails(self):
        receipt = valid_receipt()
        receipt['phases'] = receipt['phases'][:-1]
        result = self.run_gate(valid_scenario_trace(), receipt)
        self.assertFalse(result['tracePassed'])

    def test_duplicate_receipt_phase_fails(self):
        receipt = valid_receipt()
        receipt['phases'].append(dict(receipt['phases'][-1]))
        result = self.run_gate(valid_scenario_trace(), receipt)
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('duplicate' in f for f in result['failures']))

    def test_out_of_order_receipt_fails(self):
        receipt = valid_receipt()
        first = receipt['phases'].pop(0)
        receipt['phases'].insert(3, first)
        result = self.run_gate(valid_scenario_trace(), receipt)
        self.assertFalse(result['tracePassed'])
        self.assertTrue(any('out of order' in f for f in result['failures']))

    def test_short_idle_fails(self):
        receipt = valid_receipt()
        idle = next(phase for phase in receipt['phases']
                    if phase['phase'] == 'idle-120s')
        idle['startedAt'] = 1000.0
        idle['finishedAt'] = 1100.0
        result = self.run_gate(valid_scenario_trace(), receipt)
        self.assertFalse(result['tracePassed'])

    def test_receipt_phase_not_ok_fails(self):
        receipt = valid_receipt()
        receipt['phases'][4]['ok'] = False
        result = self.run_gate(valid_scenario_trace(), receipt)
        self.assertFalse(result['tracePassed'])

    def test_malformed_trace_line_fails_closed(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        trace = Path(tmp.name) / 't.jsonl'
        trace.write_text(
            '{"session": "main1", "generation": 1, "stage": "engine.visibleRender",'
            ' "detail": {"decodedTiles": "9"}, "at": "t"}\nnot-json\n')
        result = verify_real_engine_trace.verify(str(trace), None,
                                                 fixture_sha256=FIXTURE_SHA)
        self.assertFalse(result['tracePassed'])

    def test_empty_trace_fails_closed(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        trace = Path(tmp.name) / 't.jsonl'
        trace.write_text('\n')
        result = verify_real_engine_trace.verify(str(trace), None,
                                                 fixture_sha256=FIXTURE_SHA)
        self.assertFalse(result['tracePassed'])

    def test_missing_trace_fails_closed(self):
        result = verify_real_engine_trace.verify('/nonexistent/office-stage.jsonl',
                                                 None, fixture_sha256=FIXTURE_SHA)
        self.assertFalse(result['tracePassed'])

    def test_phase_list_matches_uitest_source(self):
        """The Python phase tuple must match the Swift expectedPhases list."""
        text = (REPO_ROOT
                / 'FloeAgent/Tests/FloeAgentUITests/OfficeRealEngineUITests.swift').read_text()
        for name in verify_real_engine_trace.SCENARIO_PHASES:
            self.assertIn(f'"{name}"', text)



class SanitizerSurvivalTests(unittest.TestCase):
    """Compile the real OfficeStageRecorder and prove the qualification
    facts survive its actual sanitizer/persistence path (the hostile path
    detail must be dropped). Skipped when no Swift toolchain is available."""

    def test_recorder_facts_survive_real_sanitizer(self):
        import shutil
        import subprocess
        swiftc = shutil.which('swiftc')
        if not swiftc:
            self.skipTest('swiftc unavailable')
        recorder_source = (REPO_ROOT / 'FloeAgent/FloeApp/Workspace/OfficeStageDiagnostics.swift')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            shutil.copyfile(recorder_source, tmp / 'OfficeStageDiagnostics.swift')
            (tmp / 'main.swift').write_text(
                'import Foundation\n'
                'MainActor.assumeIsolated {\n'
                '    let recorder = OfficeStageRecorder(fileURL: URL(fileURLWithPath: CommandLine.arguments[1]),\n'
                '        eventLimit: 512, fileLimit: 262_144)\n'
                '    recorder.record(session: "app-launch", generation: 0, stage: "engine.linked",\n'
                '        detail: ["simulator": "true"])\n'
                '    recorder.record(session: "qualification", generation: 0,\n'
                '        stage: "qualification.fixture.imported",\n'
                '        detail: ["sha256": "' + FIXTURE_SHA + '", "format": "pptx"])\n'
                '    recorder.record(session: "s1", generation: 1, stage: "engine.visibleRender",\n'
                '        detail: ["decodedTiles": "12", "tiles": "12", "docType": "presentation"])\n'
                '    recorder.record(session: "s1", generation: 1, stage: "qualification.hostile",\n'
                '        detail: ["path": "/private/var/mobile/secret.pptx"])\n'
                '}\n')
            binary = tmp / 'probe'
            compile_result = subprocess.run(
                ['xcrun', 'swiftc', '-swift-version', '5',
                 '-Xfrontend', '-disable-availability-checking',
                 'OfficeStageDiagnostics.swift', 'main.swift', '-o', str(binary)],
                cwd=tmp, capture_output=True, text=True, timeout=600)
            if compile_result.returncode != 0:
                self.skipTest('recorder probe does not compile on this host: '
                              + compile_result.stderr.strip()[:200])
            output = tmp / 'out.jsonl'
            run = subprocess.run([str(binary), str(output)], capture_output=True,
                                 text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stderr)
            import verify_real_engine_trace as gate
            events, malformed = gate.load_events(output)
            self.assertEqual(malformed, 0)
            linked = [e for e in events if e['stage'] == 'engine.linked']
            self.assertTrue(any(gate.detail(e, 'simulator') == 'true' for e in linked))
            imported = [e for e in events if e['stage'] == 'qualification.fixture.imported']
            self.assertTrue(any(gate.detail(e, 'sha256') == FIXTURE_SHA for e in imported))
            # The hostile path detail must have been dropped by the real sanitizer.
            hostile = [e for e in events if e['stage'] == 'qualification.hostile'][0]
            self.assertEqual(hostile['detail'], {})
            # And the surviving trace must pass the gate's structural checks.
            self.assertIsNotNone(gate.at_value(events[0]))


def _manifest_entry(exported, suggested):
    return {'exportedFileName': exported,
            'suggestedHumanReadableName': suggested,
            'configurationName': 'Standard', 'deviceId': 'D1'}


class AttachmentResolverTests(unittest.TestCase):
    RECEIPT_NAME = resolve_attachments.RECEIPT_ATTACHMENT_NAME

    def _export(self, root, files, manifest):
        root = Path(root)
        (root / 'manifest.json').write_text(json.dumps(manifest))
        for name, body in files.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)

    def _manifest(self, mapping):
        return [{'testIdentifier': 'FloeAgentUITests/OfficeRealEngineUITests/test',
                 'attachments': [_manifest_entry(name, human)
                                 for human, name in mapping.items()]}]

    def test_guid_export_names_resolved_from_manifest(self):
        import uuid
        frames = {}
        files = {}
        for token in resolve_attachments.FRAME_TOKENS:
            exported = f'{uuid.uuid4()}.png'
            frames[f'{token}.png'] = exported
            files[exported] = _png_with_document_content()
        receipt_exported = f'{uuid.uuid4()}.json'
        frames[f'{self.RECEIPT_NAME}.json'] = receipt_exported
        files[receipt_exported] = b'{"phases": []}'
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            self._export(exports, files, self._manifest(frames))
            curated = Path(tmp) / 'curated'
            report = resolve_attachments.resolve(exports, curated)
            self.assertTrue(report['resolved'], report['failures'])
            self.assertTrue((curated / resolve_attachments.RECEIPT_FILENAME).is_file())
            for token in resolve_attachments.FRAME_TOKENS:
                self.assertTrue((curated / f'{token}.png').is_file())

    def test_missing_receipt_fails_closed(self):
        frames = {f'{token}.png': f'{token}.png'
                  for token in resolve_attachments.FRAME_TOKENS}
        files = {name: _png_with_document_content() for name in frames.values()}
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            self._export(exports, files, self._manifest(frames))
            curated = Path(tmp) / 'curated'
            report = resolve_attachments.resolve(exports, curated)
            self.assertFalse(report['resolved'])
            self.assertTrue(any('receipt' in f.lower() for f in report['failures']))

    def test_xcode_occurrence_uuid_names_resolve(self):
        identifier = '01234567-89AB-CDEF-0123-456789ABCDEF'
        mapping = {f'{token}_0_{identifier}.png': f'frame-{index}.png'
                   for index, token in enumerate(resolve_attachments.FRAME_TOKENS)}
        mapping[f'{self.RECEIPT_NAME}_12_{identifier.lower()}.json'] = 'receipt.json'
        files = {name: _png_with_document_content() for name in mapping.values()
                 if name.endswith('.png')}
        files['receipt.json'] = b'{"phases": []}'
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            self._export(exports, files, self._manifest(mapping))
            report = resolve_attachments.resolve(exports, Path(tmp) / 'curated')
            self.assertTrue(report['resolved'], report['failures'])
            self.assertEqual(report['receipt']['source'], 'xcresult-attachment')

    def test_export_suffix_does_not_accept_similar_or_malformed_names(self):
        identifier = '01234567-89AB-CDEF-0123-456789ABCDEF'
        for name in [f'01-preview-extra_0_{identifier}.png',
                     f'01-preview_0_{identifier}-extra.png',
                     f'01-preview_x_{identifier}.png',
                     '01-preview_0_not-a-uuid.png',
                     f'prefix01-preview_0_{identifier}.png']:
            with self.subTest(name=name):
                self.assertFalse(resolve_attachments._name_matches(name, '01-preview'))

    def test_suffixed_duplicate_receipt_cannot_use_container_fallback(self):
        from unittest.mock import patch
        identifier = '01234567-89AB-CDEF-0123-456789ABCDEF'
        manifest = self._manifest({f'{self.RECEIPT_NAME}.json': 'first.json',
                                  f'{self.RECEIPT_NAME}_0_{identifier}.json': 'second.json'})
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            self._export(exports, {'first.json': b'{}', 'second.json': b'{}'}, manifest)
            with patch.object(resolve_attachments, 'runner_receipt_path') as fallback:
                report = resolve_attachments.resolve(exports, Path(tmp) / 'curated',
                                                     simulator='owned', runner_bundle_id='runner')
            fallback.assert_not_called()
            self.assertFalse(report['resolved'])
            self.assertTrue(any('ambiguous' in failure for failure in report['failures']))

    def test_suffixed_and_bare_frame_names_are_ambiguous(self):
        identifier = '01234567-89AB-CDEF-0123-456789ABCDEF'
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp)
            manifest = self._manifest({'01-preview.png': 'first.png',
                                      f'01-preview_0_{identifier}.png': 'second.png'})
            self._export(exports, {'first.png': b'image', 'second.png': b'image'}, manifest)
            entries = resolve_attachments.load_manifest(exports)
            path, errors = resolve_attachments.find_named(entries, exports, '01-preview')
            self.assertIsNone(path)
            self.assertTrue(any('ambiguous' in error for error in errors))

    def test_missing_frame_fails_closed(self):
        frames = {f'{token}.png': f'{token}.png'
                  for token in resolve_attachments.FRAME_TOKENS[1:]}
        frames[f'{self.RECEIPT_NAME}.json'] = 'receipt.json'
        files = {name: _png_with_document_content()
                 for name in frames.values() if name.endswith('.png')}
        files['receipt.json'] = b'{}'
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            self._export(exports, files, self._manifest(frames))
            report = resolve_attachments.resolve(exports, Path(tmp) / 'curated')
            self.assertFalse(report['resolved'])
            self.assertIn('01-preview', report['missingFrames'])

    def test_duplicate_attachment_name_is_ambiguous(self):
        manifest = [
            {'testIdentifier': 'g1', 'attachments': [
                _manifest_entry('a.png', '01-preview.png'),
                _manifest_entry('b.png', '01-preview.png')]},
            {'testIdentifier': 'g2', 'attachments': [
                _manifest_entry('receipt.json', f'{self.RECEIPT_NAME}.json')]},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            (exports / 'manifest.json').write_text(json.dumps(manifest))
            (exports / 'a.png').write_bytes(_png_with_document_content())
            (exports / 'b.png').write_bytes(_png_with_document_content())
            (exports / 'receipt.json').write_bytes(b'{}')
            for token in resolve_attachments.FRAME_TOKENS[1:]:
                (exports / f'{token}.png').write_bytes(_png_with_document_content())
                manifest.append({'testIdentifier': token, 'attachments': [
                    _manifest_entry(f'{token}.png', f'{token}.png')]})
            (exports / 'manifest.json').write_text(json.dumps(manifest))
            report = resolve_attachments.resolve(exports, Path(tmp) / 'curated')
            self.assertFalse(report['resolved'])
            self.assertTrue(any('ambiguous' in f for f in report['failures']))

    def test_path_escape_export_rejected(self):
        manifest = [{'testIdentifier': 'g', 'attachments': [
            _manifest_entry('../../evil.png', '01-preview.png')]}]
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            (exports / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaises(resolve_attachments.AttachmentResolveError):
                resolve_attachments.resolve(exports, Path(tmp) / 'curated')

    def test_absolute_export_rejected(self):
        manifest = [{'testIdentifier': 'g', 'attachments': [
            _manifest_entry('/tmp/evil.png', '01-preview.png')]}]
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            (exports / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaises(resolve_attachments.AttachmentResolveError):
                resolve_attachments.resolve(exports, Path(tmp) / 'curated')

    def test_symlink_export_rejected(self):
        manifest = [{'testIdentifier': 'g', 'attachments': [
            _manifest_entry('link.png', '01-preview.png')]}]
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            outside = Path(tmp) / 'outside.png'
            outside.write_bytes(_png_with_document_content())
            (exports / 'link.png').symlink_to(outside)
            (exports / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaises(resolve_attachments.AttachmentResolveError):
                resolve_attachments.resolve(exports, Path(tmp) / 'curated')

    def test_malformed_manifest_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            (exports / 'manifest.json').write_text('{not json')
            with self.assertRaises(resolve_attachments.AttachmentResolveError):
                resolve_attachments.resolve(exports, Path(tmp) / 'curated')

    def test_missing_manifest_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            with self.assertRaises(resolve_attachments.AttachmentResolveError):
                resolve_attachments.resolve(exports, Path(tmp) / 'curated')

    def test_non_array_manifest_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            exports = Path(tmp) / 'exports'
            exports.mkdir()
            (exports / 'manifest.json').write_text(
                json.dumps({'attachments': []}))
            with self.assertRaises(resolve_attachments.AttachmentResolveError):
                resolve_attachments.resolve(exports, Path(tmp) / 'curated')


def _png_with_document_content(*, chrome_only=False, uniform=None,
                               include_markers=True, variant='editor'):
    """Synthesize a 1000x700 frame with per-frame slideshow variants.

    The excluded top/side bands always carry dense colored chrome to prove
    chrome cannot satisfy the document-region gate. Presentation variants add
    the real slideshow letterbox (black bands) so the gate's still-presenting
    / exited rules can be exercised; page identity uses the pinned fixture
    markers inside the document region: blue title + orange bar (slide 1),
    green oval (slide 2). The edited deck order is
    [fixture slide 1, inserted blank, fixture slide 2].
    """
    from PIL import Image
    width, height = 1000, 700
    if uniform is not None:
        image = Image.new('RGB', (width, height), uniform)
    else:
        image = Image.new('RGB', (width, height), (255, 255, 255))
    pixels = image.load()
    # Dense colored chrome across the top 22% and the left 20% band.
    for y in range(0, int(height * 0.22)):
        for x in range(width):
            pixels[x, y] = (40, 44, 52)
    for y in range(height):
        for x in range(0, int(width * 0.20)):
            pixels[x, y] = (234, 88, 12)
    if uniform is None and not chrome_only:
        # Real drawn content inside the document region: text-like dark
        # glyphs plus the variant's fixture markers. The inserted blank
        # intermediate deliberately has NO ink: it is the one token allowed
        # to be empty because it is explicitly asserted marker-free.
        if variant != 'presenting-blank':
            for y in range(int(height * 0.35), int(height * 0.80), 6):
                for x in range(int(width * 0.30), int(width * 0.72)):
                    pixels[x, y] = (30, 30, 30)
        if include_markers and variant != 'presenting-blank':
            if variant in ('preview', 'editor', 'fixture-slide1', 'presenting-page1',
                           'presenting-blueonly'):
                for y in range(int(height * 0.30), int(height * 0.34)):
                    for x in range(int(width * 0.30), int(width * 0.55)):
                        pixels[x, y] = (29, 78, 216)
            if variant in ('editor', 'fixture-slide1', 'presenting-page1'):
                for y in range(int(height * 0.36), int(height * 0.39)):
                    for x in range(int(width * 0.30), int(width * 0.55)):
                        pixels[x, y] = (234, 88, 12)
            if variant in ('fixture-slide2', 'presenting-page2'):
                cy, cx, radius = int(height * 0.55), int(width * 0.50), 60
                for y in range(cy - radius, cy + radius):
                    for x in range(cx - radius, cx + radius):
                        if (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2:
                            pixels[x, y] = (16, 160, 64)
    if variant in ('presenting-page1', 'presenting-blank', 'presenting-page2',
                   'presenting-blueonly'):
        # Real slideshow letterbox bands (top/bottom of the whole frame).
        for y in range(0, int(height * 0.05)):
            for x in range(width):
                pixels[x, y] = (0, 0, 0)
        for y in range(int(height * 0.95), height):
            for x in range(width):
                pixels[x, y] = (0, 0, 0)
    buffer = io.BytesIO()
    image.save(buffer, format='PNG')
    return buffer.getvalue()


class FloeRenderGateTests(unittest.TestCase):
    def _curated(self, root, frame_bytes):
        root = Path(root)
        for token, body in frame_bytes.items():
            (root / f'{token}.png').write_bytes(body)
        return root

    SLIDESHOW_VARIANTS = {
        '01-preview': 'preview',
        '02-edit': 'editor',
        '10-slideshow-page1': 'presenting-page1',
        '11-slideshow-blank-page': 'presenting-blank',
        '12-slideshow-page2': 'presenting-page2',
        '13-slideshow-exit': 'editor',
        '03-idle-120s': 'editor',
        '04-reopen': 'editor',
        '05-persisted': 'editor',
    }

    def _all_frames(self, **kwargs):
        return {token: _png_with_document_content(
                    variant=self.SLIDESHOW_VARIANTS.get(token, 'editor'), **kwargs)
                for token in check_floe_render.EXPECTED_FRAMES}

    def test_real_fixture_frames_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            curated = self._curated(Path(tmp), self._all_frames())
            result = check_floe_render.check_floe_render(curated)
            self.assertTrue(result['renderPassed'], result['failures'])

    def test_solid_toolbar_empty_document_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames(chrome_only=True)
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('blank document' in f for f in result['failures']))

    def test_uniform_grey_document_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames(uniform=(128, 128, 128))
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('flat fill' in f for f in result['failures']))

    def test_uniform_dark_document_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames(uniform=(24, 24, 28))
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('flat fill' in f for f in result['failures']))

    def test_missing_frame_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            del frames['03-idle-120s']
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('missing frame' in f for f in result['failures']))

    def test_preview_requires_markers_in_document_region(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames(include_markers=False)
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('marker colors absent' in f
                                for f in result['failures']))

    def test_slideshow_page1_requires_both_fixture_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            frames['10-slideshow-page1'] = _png_with_document_content(
                variant='presenting-blueonly')
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('fixture slide 1 markers incomplete' in f
                                for f in result['failures']))

    def test_slideshow_blank_intermediate_with_markers_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            frames['11-slideshow-blank-page'] = _png_with_document_content(
                variant='presenting-page1')
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('inserted blank page carries fixture markers' in f
                                for f in result['failures']))

    def test_slideshow_page2_requires_green_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            frames['12-slideshow-page2'] = _png_with_document_content(
                variant='presenting-blank')
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('green oval absent' in f
                                for f in result['failures']))

    def test_slideshow_page2_wrong_page_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            frames['12-slideshow-page2'] = frames['10-slideshow-page1']
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('are the same frame' in f
                                for f in result['failures']))

    def test_slideshow_exit_still_presenting_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            frames['13-slideshow-exit'] = frames['12-slideshow-page2']
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertFalse(result['renderPassed'])
            self.assertTrue(any('slideshow letterbox still present' in f
                                for f in result['failures']))

    def test_slideshow_blank_intermediate_not_required_to_have_ink(self):
        # The inserted blank page is the explicit expected-blank intermediate:
        # it is accepted for that ONE token when it is marker-free, still
        # letterboxed and different from both content pages.
        with tempfile.TemporaryDirectory() as tmp:
            frames = self._all_frames()
            curated = self._curated(Path(tmp), frames)
            result = check_floe_render.check_floe_render(curated)
            self.assertTrue(result['renderPassed'], result['failures'])


class OwnedSimulatorSafetyTests(unittest.TestCase):
    def test_owned_name_roundtrip(self):
        name = provision_owned_simulator.owned_name('12345', 'kit')
        self.assertTrue(provision_owned_simulator.is_owned_name(name))
        self.assertIn('12345', name)
        self.assertIn('kit', name)

    def test_existing_device_names_are_not_owned(self):
        for name in ('iPad Pro (13-inch)', 'Floe Office Real SIM',
                     'iPhone 17', 'Floe Office Real SIMX 1 kit abcdef12'):
            self.assertFalse(provision_owned_simulator.is_owned_name(name))

    def test_release_refuses_foreign_device(self):
        inventory = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
            {'udid': 'UDID-1', 'name': 'iPad Pro', 'state': 'Shutdown'}]}}
        original = release_owned_simulator._list_devices
        release_owned_simulator._list_devices = lambda: inventory
        try:
            with self.assertRaises(release_owned_simulator.SimulatorReleaseError):
                release_owned_simulator.release('UDID-1')
        finally:
            release_owned_simulator._list_devices = original

    def test_release_refuses_run_variant_mismatch(self):
        name = provision_owned_simulator.owned_name('111', 'kit')
        inventory = {'devices': {'r': [{'udid': 'UDID-9', 'name': name,
                                        'state': 'Shutdown'}]}}
        original = release_owned_simulator._list_devices
        commands = []
        release_owned_simulator._list_devices = lambda: inventory

        def fake_run(command, capture_output=True, text=True):
            commands.append(command)

            class Result:
                returncode = 0
                stderr = ''
            return Result()
        import subprocess
        original_run = subprocess.run
        subprocess.run = fake_run
        try:
            with self.assertRaises(release_owned_simulator.SimulatorReleaseError):
                release_owned_simulator.release('UDID-9', run_id='222',
                                                variant='nokit')
        finally:
            release_owned_simulator._list_devices = original
            subprocess.run = original_run
        self.assertFalse(any('delete' in part for command in commands
                             for part in command))

    def test_provision_guard_honours_single_device_policy(self):
        import os
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            config = {'policy': 'single-existing-device',
                      'deviceUDID': 'canon-udid-1', 'deviceName': 'Synthetic Canonical iPad'}
            path = Path(tmp) / 'device.json'
            path.write_text(json.dumps(config))
            with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': str(path)}):
                blocker = provision_owned_simulator.single_device_policy_blocker()
                self.assertIn('single-simulator policy pins device', blocker)
                self.assertIn('CANON-UDID-1', provision_owned_simulator.canonical_pinned_udid().upper())
                self.assertEqual(provision_owned_simulator.canonical_pinned_udid(),
                                 'CANON-UDID-1')
            absent = str(Path(tmp) / 'absent-device.json')
            with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': absent}):
                self.assertIsNone(provision_owned_simulator.single_device_policy_blocker())
                self.assertIsNone(provision_owned_simulator.canonical_pinned_udid())
            path.write_text(json.dumps({'policy': 'other', 'deviceUDID': 'x'}))
            with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': str(path)}):
                self.assertIsNone(provision_owned_simulator.single_device_policy_blocker())
            path.write_text('{not json')
            with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': str(path)}):
                self.assertIn('unreadable',
                              provision_owned_simulator.single_device_policy_blocker())
            path.write_text('[{"policy": "single-existing-device"}]')
            with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': str(path)}):
                self.assertIn('JSON object',
                              provision_owned_simulator.single_device_policy_blocker())
                self.assertIsNone(provision_owned_simulator.canonical_pinned_udid())

    def test_provision_main_refuses_creation_under_policy(self):
        import os
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            config = {'policy': 'single-existing-device',
                      'deviceUDID': 'canon-udid-1', 'deviceName': 'Synthetic Canonical iPad'}
            path = Path(tmp) / 'device.json'
            path.write_text(json.dumps(config))
            attempted = []

            def fake_run(command):
                attempted.append(command)
                raise AssertionError('must not reach simctl under the policy')
            original = provision_owned_simulator._run
            provision_owned_simulator._run = fake_run
            try:
                argv = ['provision_owned_simulator.py', '--run-id', '9',
                        '--variant', 'kit']
                with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': str(path)}), \
                        mock.patch('sys.argv', argv), \
                        mock.patch('sys.stderr', new_callable=io.StringIO):
                    with self.assertRaises(SystemExit) as exit_state:
                        provision_owned_simulator.main()
                    self.assertEqual(exit_state.exception.code, 1)
                self.assertEqual(attempted, [])
            finally:
                provision_owned_simulator._run = original

    def test_release_refuses_canonical_device_even_with_owned_name(self):
        import os
        from unittest import mock
        pinned = 'CANON-UDID-9'
        owned = provision_owned_simulator.owned_name('777', 'kit')
        inventory = {'devices': {'r': [{'udid': pinned, 'name': owned,
                                        'state': 'Shutdown'}]}}
        commands = []
        original_list = release_owned_simulator._list_devices
        release_owned_simulator._list_devices = lambda: inventory

        def fake_run(command, capture_output=True, text=True):
            commands.append(command)

            class Result:
                returncode = 0
                stderr = ''
            return Result()
        original_run = subprocess.run
        subprocess.run = fake_run
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'device.json'
                path.write_text(json.dumps({'policy': 'single-existing-device',
                                            'deviceUDID': pinned}))
                with mock.patch.dict(os.environ, {'FLOE_SIMULATOR_CONFIG': str(path)}):
                    with self.assertRaisesRegex(
                            release_owned_simulator.SimulatorReleaseError,
                            'canonical single device'):
                        release_owned_simulator.release(pinned, expected_name=owned)
        finally:
            release_owned_simulator._list_devices = original_list
            subprocess.run = original_run
        self.assertEqual(commands, [])


class NokitLockPathContractTests(unittest.TestCase):
    def test_kit_uses_tracked_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, applied = build_simulator_framework.variant_lock('kit', tmp)
            self.assertTrue(applied)
            self.assertEqual(path, build_simulator_framework.LOCK_PATH)

    def test_nokit_stages_verified_adjacent_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, applied = build_simulator_framework.variant_lock('nokit', tmp)
            self.assertFalse(applied)
            lock = json.loads(path.read_text())
            self.assertNotIn('kitCallbackLifecycleOverlay', lock)
            facts = build_simulator_framework.validate_lock_resources(path)
            # The nokit build phases resolve three overlay patches
            # (embedding, scheme, forwarding) plus the compiled member/archive
            # patches and the deployment-target source patch. The embedded
            # lifecycle parent patch is applied during prepared-source staging,
            # not here, so it is not part of this count. Declare the identities
            # explicitly instead of deriving them from the function under test.
            required = {
                'patches/ios-embedding-boundaries.patch',
                'patches/ios-scheme-task-lifecycle.patch',
                'patches/ios-forwarding-lifecycle.patch',
                'patches/ios-embedded-lifecycle-compiled.patch',
                'patches/ios-notebookbar-lifetime.patch',
                'patches/ios-aqua-chart-path-probe.patch',
                'patches/ios-foreign-bitmap-readback.patch',
                'patches/ios-jsdialog-treeview-utf8.patch',
                'patches/ios-deployment-target.patch',
            }
            self.assertEqual(len(required), 9)
            self.assertEqual(facts['patchCount'], len(required))
            self.assertEqual(set(build_simulator_framework.overlay_patch_refs(lock)), required)
            # Every referenced overlay input resolves next to the copied lock.
            tracked = json.loads(build_simulator_framework.LOCK_PATH.read_text())
            tracked_root = build_simulator_framework.LOCK_PATH.parent
            for ref in build_simulator_framework.overlay_patch_refs(lock):
                self.assertTrue((path.parent / ref).is_file())
                self.assertEqual(
                    build_simulator_framework.digest(path.parent / ref),
                    build_simulator_framework.digest(tracked_root / ref))

    def test_tracked_lock_is_unchanged_after_nokit(self):
        before = build_simulator_framework.LOCK_PATH.read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            build_simulator_framework.variant_lock('nokit', tmp)
        self.assertEqual(before, build_simulator_framework.LOCK_PATH.read_bytes())


    def _seed_resources(self, root):
        resources = Path(root)
        original = make_fixture.build_bytes()
        original_hash = hashlib.sha256(original).hexdigest()
        (resources / original_hash).write_bytes(original)
        edited = make_pptx_bytes(4)
        edited_hash = hashlib.sha256(edited).hexdigest()
        (resources / edited_hash).write_bytes(edited)
        receipt = {'originalResourceSHA256': original_hash}
        return original_hash, edited_hash, receipt

    def test_persisted_edit_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            resources = Path(tmp) / 'Resources'
            resources.mkdir()
            original_hash, edited_hash, receipt = self._seed_resources(resources)
            receipt_path = Path(tmp) / 'import.json'
            receipt_path.write_text(json.dumps(receipt))
            result = check_saved_document.check_saved_document(resources, receipt_path)
            self.assertTrue(result['persistencePassed'], result['failures'])
            self.assertEqual(result['editedCandidates'][0]['hash'], edited_hash)
            self.assertNotEqual(edited_hash, original_hash)

    def test_missing_edit_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            resources = Path(tmp) / 'Resources'
            resources.mkdir()
            original_hash, _, receipt = self._seed_resources(resources)
            (resources / hashlib.sha256(make_pptx_bytes(4)).hexdigest()).unlink()
            receipt_path = Path(tmp) / 'import.json'
            receipt_path.write_text(json.dumps(receipt))
            result = check_saved_document.check_saved_document(resources, receipt_path)
            self.assertFalse(result['persistencePassed'])

    def test_name_content_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            resources = Path(tmp) / 'Resources'
            resources.mkdir()
            _, _, receipt = self._seed_resources(resources)
            (resources / ('f' * 64)).write_bytes(make_pptx_bytes(4))
            receipt_path = Path(tmp) / 'import.json'
            receipt_path.write_text(json.dumps(receipt))
            result = check_saved_document.check_saved_document(resources, receipt_path)
            self.assertFalse(result['persistencePassed'])
            self.assertTrue(any('mismatch' in f for f in result['failures']))

    def test_missing_original_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            resources = Path(tmp) / 'Resources'
            resources.mkdir()
            original_hash, _, receipt = self._seed_resources(resources)
            (resources / original_hash).unlink()
            receipt_path = Path(tmp) / 'import.json'
            receipt_path.write_text(json.dumps(receipt))
            result = check_saved_document.check_saved_document(resources, receipt_path)
            self.assertFalse(result['persistencePassed'])


# Explicit fixture contract for the current compiled lifecycle member. These
# identities are declared independently so a silent lock shape change cannot
# quietly rewrite the receipt fixture; update them only with the lock contract.
SIM_COMPILED_MEMBER_SOURCES = {
    'svdata.o': 'engine/vcl/source/app/svdata.cxx',
    'AquaGraphicsBackend.o': 'engine/vcl/quartz/AquaGraphicsBackend.cxx',
    'salios.o': 'engine/vcl/ios/salios.cxx',
    'executor.o': 'engine/vcl/jsdialog/executor.cxx',
}
SIM_COMPILED_ARCHIVE_MEMBER_SOURCES = {
    'libsallo.a': {'thread.o': 'engine/sal/osl/unx/thread.cxx'},
    'libsfxlo.a': {'SfxNotebookBar.o': 'engine/sfx2/source/notebookbar/SfxNotebookBar.cxx'},
}


def fixture_sha256(label):
    return hashlib.sha256(label.encode()).hexdigest()


def fixture_member_sources(selected):
    base = {key: selected[key] for key in
            ('sourceFile', 'originalSHA256', 'patchedSHA256', 'patch', 'patchSHA256')}
    if selected.get('compileOverrides'):
        base['compileOverrides'] = json.loads(json.dumps(selected['compileOverrides']))
    sources = {name: json.loads(json.dumps(base)) for name in selected['members']}
    sources.update(json.loads(json.dumps(selected.get('additionalMembers', {}))))
    return sources


def fixture_schema_version(selected):
    if selected.get('additionalMembers'):
        return 3
    if any(fixture_schema_version(child) == 3
           for child in selected.get('additionalArchives', {}).values()):
        return 3
    return 2 if selected.get('additionalArchives') else 1


def compiled_lifecycle_fixture(selected, platform):
    """Synthetic receipt for the lock's current compiled member contract.

    Archive/object/linker hashes are deterministic fixture bytes, never build
    evidence. Only the lock-declared original member digests are copied
    verbatim because the production validator compares them exactly.
    """
    sources = fixture_member_sources(selected)
    archive_name = Path(selected['archive']).name
    version = fixture_schema_version(selected)
    objects = {name: fixture_sha256(f'fixture {archive_name} object {name}')
               for name in sources}
    originals = {name: (sources[name].get('originalMemberSHA256')
                        or fixture_sha256(f'fixture {archive_name} original {name}'))
                 for name in sources}
    block = {
        'schemaVersion': version,
        'platform': platform,
        'archive': selected['archive'],
        'members': {name: spec['sourceFile'] for name, spec in sources.items()},
        'sourceCommit': LOCK['commit'],
        'patchSHA256': LOCK['embeddedLifecycleOverlay']['sha256'],
        'compiledPatchSHA256': selected['patchSHA256'],
        'sourceFile': selected['sourceFile'],
        'originalSourceSHA256': selected['originalSHA256'],
        'patchedSourceSHA256': selected['patchedSHA256'],
        'compilePassed': True,
        'archiveReplacementPassed': True,
        'originalArchiveSHA256': fixture_sha256(f'fixture {archive_name} original archive'),
        'archiveSHA256': fixture_sha256(f'fixture {archive_name} compiled archive'),
        'linkerListSHA256': fixture_sha256(f'fixture {archive_name} linker list'),
        'objectSHA256ByMember': objects,
    }
    if selected.get('compileOverrides'):
        block['compileOverrides'] = json.loads(json.dumps(selected['compileOverrides']))
    if version == 3:
        block['memberSources'] = sources
        block['originalObjectSHA256ByMember'] = originals
        block['objectABIByMember'] = {name: {'arch': 'arm64', 'platform': platform}
                                      for name in objects}
    return block


def make_fake_host_bundle(root, *, variant='kit', kit_applied=True):
    bundle = Path(root) / 'OfficeNativeHostSimulator'
    framework = bundle / 'FloeOfficeNative.framework'
    (framework / 'Headers').mkdir(parents=True)
    (framework / 'Modules').mkdir(parents=True)
    (framework / 'FloeOfficeNative').write_bytes(b'\x00mach-o')
    (framework / 'Info.plist').write_bytes(b'<plist/>')
    (framework / 'Headers/FloeOfficeNative.h').write_text('// header')
    (framework / 'Modules/module.modulemap').write_text('module')
    resources = bundle / 'OfficeRuntimeResources'
    resources.mkdir()
    (resources / 'cool.html').write_text('<html/>')
    (resources / 'rc').mkdir()
    (resources / 'ICU.dat').write_bytes(b'dat')
    (resources / 'program').mkdir()
    (resources / 'share').mkdir()
    aux = {str(path.relative_to(framework)): hashlib.sha256(path.read_bytes()).hexdigest()
           for path in framework.rglob('*') if path.is_file() and path.name != 'FloeOfficeNative'}
    resource_hashes = {str(path.relative_to(resources)): hashlib.sha256(path.read_bytes()).hexdigest()
                       for path in resources.rglob('*') if path.is_file()}
    resource_dirs = [str(path.relative_to(resources)) for path in resources.rglob('*') if path.is_dir()]
    receipt = {
        'kind': 'Floe native Office simulator host qualification',
        'variant': variant,
        'kitCallbackOverlayApplied': kit_applied,
        'platform': 'iphonesimulator',
        'arch': 'arm64',
        'deploymentTarget': '26.0',
        'sourceCommit': LOCK['commit'],
        'overlaySHA256': LOCK['embeddingOverlay']['sha256'],
        'schemeTaskLifecycle': {'patchSHA256': LOCK['schemeTaskLifecycleOverlay']['sha256'],
                                'sourceCommit': LOCK['commit'],
                                'files': {n: s['preparedSHA256'] for n, s in
                                          LOCK['schemeTaskLifecycleOverlay']['files'].items()}},
        'forwardingLifecycle': {'patchSHA256': LOCK['forwardingLifecycleOverlay']['sha256'],
                                'sourceCommit': LOCK['commit'],
                                'files': {n: s['preparedSHA256'] for n, s in
                                          LOCK['forwardingLifecycleOverlay']['files'].items()}},
        'stagedEngine': {'runID': '36704184429',
                         'artifactSHA256': 'a' * 64,
                         'sourceCommit': LOCK['commit']},
        'sdkVersion': '27.0', 'sdkBuildVersion': '27A123', 'xcodeVersion': 'Xcode 27.0',
        'nativeCompilePassed': True, 'nativeLinkPassed': True,
        'swiftModuleImportPassed': True,
        'filterOverlay': {'applied': False},
        'hostSourceSHA256': {n: bootstrap_office_host.digest(
            REPO_ROOT / 'FloeAgent/ThirdParty/Collabora/FloeOfficeNative' / n)
            for n in LOCK['qualifiedHostArtifact']['hostSourceSHA256']},
        'executableSHA256': hashlib.sha256((framework / 'FloeOfficeNative').read_bytes()).hexdigest(),
        'frameworkAuxiliarySHA256': aux,
        'runtimeResourceSHA256': resource_hashes,
        'runtimeResourceDirectories': resource_dirs,
    }
    receipt['embeddedLifecycle'] = {
        'patchSHA256': LOCK['embeddedLifecycleOverlay']['sha256'],
        'sourceCommit': LOCK['commit'],
        'files': {n: spec['preparedSHA256'] for n, spec in
                  LOCK['embeddedLifecycleOverlay']['files'].items()}}
    selected = (LOCK.get('embeddedLifecycleOverlay', {}).get('compiledMembers') or {}).get('IOSSIMULATOR')
    if selected:
        sources = fixture_member_sources(selected)
        declared_members = {name: spec['sourceFile'] for name, spec in sources.items()}
        if declared_members != SIM_COMPILED_MEMBER_SOURCES:
            raise AssertionError('compiled lifecycle fixture member identities changed: '
                                 + repr(sorted(declared_members.items())))
        declared_archives = {
            name: dict(child['members'])
            for name, child in selected.get('additionalArchives', {}).items()}
        if declared_archives != SIM_COMPILED_ARCHIVE_MEMBER_SOURCES:
            raise AssertionError('compiled lifecycle fixture archive identities changed: '
                                 + repr(sorted(declared_archives)))
        member = compiled_lifecycle_fixture(selected, 'IOSSIMULATOR')
        member['additionalArchives'] = {
            name: compiled_lifecycle_fixture(spec, 'IOSSIMULATOR')
            for name, spec in selected.get('additionalArchives', {}).items()}
        member['linkOwnership'] = {
            'linkMapSHA256': fixture_sha256('fixture simulator link map'),
            'linkerListSHA256': fixture_sha256('fixture simulator linker list'),
            'archives': {
                name: {'archiveSHA256': block['archiveSHA256'],
                       'objectSHA256ByMember': dict(block['objectSHA256ByMember'])}
                for name, block in {Path(member['archive']).name: member,
                                    **member['additionalArchives']}.items()},
            'preparedObjects': {
                name: {'preparedSourceSHA256': spec['preparedSHA256'],
                       'objectSHA256': fixture_sha256('fixture prepared object ' + name),
                       'objectName': Path(name).stem + '.o'}
                for name, spec in LOCK['embeddedLifecycleOverlay']['files'].items()},
        }
        receipt['embeddedLifecycleMember'] = member
        receipt['platformOriginalArchives'] = {
            'sdk': 'iphonesimulator',
            'archives': {Path(block['archive']).name: block['originalArchiveSHA256']
                         for block in [member, *member['additionalArchives'].values()]},
        }
    else:
        receipt['platformOriginalArchives'] = {'sdk': 'iphonesimulator',
                                               'archives': {'libvcllo.a': '6' * 64}}
    if kit_applied:
        receipt['kitCallbackLifecycle'] = {
            'patchSHA256': LOCK['kitCallbackLifecycleOverlay']['sha256'],
            'sourceCommit': LOCK['commit'],
            'files': {n: s['preparedSHA256'] for n, s in
                      LOCK['kitCallbackLifecycleOverlay']['files'].items()}}
    import office_engine_repair
    repair_lock, repair_section = office_engine_repair.tracked_contract(
        platform='IOSSIMULATOR')
    if repair_section is not None:
        # Once the tracked engine repair contract exists, every verified
        # simulator host receipt must carry its exact identity.
        receipt['engineRepair'] = office_engine_repair.expected_manifest_block(
            repair_lock, repair_section)
    (bundle / 'native-host-simulator.json').write_text(json.dumps(receipt, indent=2))
    return bundle


class SimulatorHostVerifyTests(unittest.TestCase):
    def test_missing_embedded_lifecycle_provenance_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            path = bundle / 'native-host-simulator.json'
            receipt = json.loads(path.read_text())
            del receipt['embeddedLifecycle']
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'embedded lifecycle'):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_false_and_stale_embedded_lifecycle_rejected(self):
        for mutate in (lambda r: r['embeddedLifecycle'].update({'patchSHA256': '0' * 64}),
                       lambda r: r['embeddedLifecycle'].update({'sourceCommit': 'f' * 40}),
                       lambda r: r['embeddedLifecycle']['files'].update(
                           {'net/FakeSocket.cpp': '1' * 64}),
                       lambda r: r['embeddedLifecycle'].update({'files': {}})):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as tmp:
                bundle = make_fake_host_bundle(tmp)
                path = bundle / 'native-host-simulator.json'
                receipt = json.loads(path.read_text())
                mutate(receipt)
                path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, 'embedded lifecycle'):
                    bootstrap_office_host.verify_simulator_host(bundle)

    def test_missing_platform_archive_identity_rejected(self):
        for mutate in (lambda r: r.pop('platformOriginalArchives'),
                       lambda r: r['platformOriginalArchives'].update({'sdk': 'iphoneos'}),
                       lambda r: r['platformOriginalArchives'].update({'archives': {}})):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as tmp:
                bundle = make_fake_host_bundle(tmp)
                path = bundle / 'native-host-simulator.json'
                receipt = json.loads(path.read_text())
                mutate(receipt)
                path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, 'platform original archive'):
                    bootstrap_office_host.verify_simulator_host(bundle)

    def test_stale_host_sources_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            path = bundle / 'native-host-simulator.json'
            receipt = json.loads(path.read_text())
            receipt['hostSourceSHA256']['FloeOfficeNative.h'] = '0' * 64
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'implementation sources'):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_changed_prepared_overlay_files_rejected(self):
        for block in ('schemeTaskLifecycle', 'forwardingLifecycle', 'kitCallbackLifecycle'):
            with self.subTest(block=block), tempfile.TemporaryDirectory() as tmp:
                bundle = make_fake_host_bundle(tmp)
                path = bundle / 'native-host-simulator.json'
                receipt = json.loads(path.read_text())
                receipt[block]['files'] = {}
                path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, 'overlay provenance'):
                    bootstrap_office_host.verify_simulator_host(bundle)

    def test_contradictory_kit_variant_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp, variant='kit', kit_applied=False)
            with self.assertRaisesRegex(ValueError, 'variant contradicts'):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_missing_staged_source_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            path = bundle / 'native-host-simulator.json'
            receipt = json.loads(path.read_text())
            receipt['stagedEngine'].pop('sourceCommit')
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'staged engine source'):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_fake_bundle_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            facts = bootstrap_office_host.verify_simulator_host(bundle)
            self.assertEqual(facts['variant'], 'kit')
            self.assertTrue(facts['kitCallbackOverlayApplied'])

    def test_nokit_bundle_passes_without_kit_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp, variant='nokit', kit_applied=False)
            facts = bootstrap_office_host.verify_simulator_host(bundle)
            self.assertEqual(facts['variant'], 'nokit')
            self.assertFalse(facts['kitCallbackOverlayApplied'])

    def test_kit_variant_requires_kit_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp, variant='kit', kit_applied=True)
            receipt_path = bundle / 'native-host-simulator.json'
            receipt = json.loads(receipt_path.read_text())
            receipt.pop('kitCallbackLifecycle')
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_tampered_executable_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            (bundle / 'FloeOfficeNative.framework/FloeOfficeNative').write_bytes(b'\x01tampered')
            with self.assertRaises(ValueError):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_wrong_platform_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            receipt_path = bundle / 'native-host-simulator.json'
            receipt = json.loads(receipt_path.read_text())
            receipt['platform'] = 'iphoneos'
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_missing_pass_flag_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            receipt_path = bundle / 'native-host-simulator.json'
            receipt = json.loads(receipt_path.read_text())
            receipt['swiftModuleImportPassed'] = False
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                bootstrap_office_host.verify_simulator_host(bundle)


    def test_compiled_lifecycle_missing_or_forged_never_downgrades(self):
        for field, value in [('schemaVersion', 0), ('compiledPatchSHA256', '0' * 64),
                             ('patchedSourceSHA256', '0' * 64), ('platform', 'IOS'),
                             ('members', {}), ('compilePassed', 1)]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                bundle = make_fake_host_bundle(tmp)
                path = bundle / 'native-host-simulator.json'
                receipt = json.loads(path.read_text())
                receipt['embeddedLifecycleMember'][field] = value
                path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, 'Compiled embedded lifecycle'):
                    bootstrap_office_host.verify_simulator_host(bundle)
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            path = bundle / 'native-host-simulator.json'
            receipt = json.loads(path.read_text());receipt.pop('embeddedLifecycleMember')
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'Compiled embedded lifecycle'):
                bootstrap_office_host.verify_simulator_host(bundle)

    def test_historical_receipt_cannot_downgrade_multisource_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = make_fake_host_bundle(tmp)
            path = bundle / 'native-host-simulator.json'
            receipt = json.loads(path.read_text())
            keys = {'platform', 'archive', 'originalArchiveSHA256', 'archiveSHA256',
                    'objectSHA256ByMember', 'members', 'linkerListSHA256', 'patchSHA256', 'sourceCommit'}
            receipt['embeddedLifecycleMember'] = {k: v for k, v in receipt['embeddedLifecycleMember'].items() if k in keys}
            path.write_text(json.dumps(receipt))
            # The current contract has several members/archives, so the
            # historical single-member compatibility path is not permitted.
            with self.assertRaisesRegex(
                    ValueError, 'multi-source contracts cannot use historical compatibility'):
                bootstrap_office_host.verify_simulator_host(bundle)
            # A versioned receipt is validated against the canonical contract;
            # it cannot smuggle the historical shape in through a field.
            receipt['embeddedLifecycleMember']['schemaVersion'] = 0
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'Compiled embedded lifecycle'):
                bootstrap_office_host.verify_simulator_host(bundle)


class InstallSimulatorHostTests(unittest.TestCase):
    def test_xcconfig_rewrite_preserves_device_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            office = Path(tmp) / 'FloeAgent/Vendor/Office'
            office.mkdir(parents=True)
            xcconfig = office / 'native-host.xcconfig'
            xcconfig.write_text('// Generated.\nFLOE_OFFICE_HOST_DIR = $(PROJECT_DIR)/Vendor/Office/35668651442/OfficeNativeHost\n')
            host = office / 'simulator-1-kit/OfficeNativeHostSimulator'
            host.mkdir(parents=True)
            install_simulator_host.rewrite_xcconfig(xcconfig, host, repo_root=Path(tmp))
            text = xcconfig.read_text()
            self.assertIn('FLOE_OFFICE_HOST_DIR = $(PROJECT_DIR)/Vendor/Office/35668651442/OfficeNativeHost', text)
            self.assertIn('FLOE_OFFICE_SIM_HOST_DIR = $(PROJECT_DIR)/Vendor/Office/simulator-1-kit/OfficeNativeHostSimulator', text)
            self.assertIn('FLOE_OFFICE_SIM_LDFLAG = -framework FloeOfficeNative', text)

    def test_xcconfig_without_device_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            office = Path(tmp) / 'FloeAgent/Vendor/Office'
            office.mkdir(parents=True)
            xcconfig = office / 'native-host.xcconfig'
            xcconfig.write_text('// Generated.\n')
            host = office / 'simulator-1-kit/OfficeNativeHostSimulator'
            host.mkdir(parents=True)
            install_simulator_host.rewrite_xcconfig(xcconfig, host, repo_root=Path(tmp))
            text = xcconfig.read_text()
            self.assertNotIn('FLOE_OFFICE_HOST_DIR', text)
            self.assertIn('FLOE_OFFICE_SIM_HOST_DIR', text)

    def test_install_rejects_wrong_bundle_root(self):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / 'bad.zip'
            with zipfile.ZipFile(bad, 'w') as archive:
                archive.writestr('SomethingElse/file.txt', 'x')
            with self.assertRaises(install_simulator_host.InstallSimulatorHostError):
                install_simulator_host.install(bad, REPO_ROOT, set_xcconfig=False)

    def test_install_places_and_verifies(self):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / 'repo'
            bundle = make_fake_host_bundle(Path(tmp) / 'stage')
            zip_path = Path(tmp) / 'OfficeNativeHostSimulator.zip'
            with zipfile.ZipFile(zip_path, 'w') as archive:
                for path in sorted(bundle.rglob('*')):
                    if path.is_dir():
                        archive.write(path, path.relative_to(bundle.parent).as_posix() + '/')
                for path in sorted(bundle.rglob('*')):
                    if path.is_file():
                        archive.write(path, path.relative_to(bundle.parent))
            # Use the real lock from the checkout for verification.
            facts = install_simulator_host.install(zip_path, repo, set_xcconfig=False)
            execsha = hashlib.sha256(
                (bundle / 'FloeOfficeNative.framework' / 'FloeOfficeNative').read_bytes()
            ).hexdigest()[:12]
            expected = f'simulator-36704184429-kit-{execsha}'
            self.assertEqual(facts['installKey'], expected)
            self.assertFalse(facts['alreadyInstalled'])
            self.assertTrue((repo / 'FloeAgent/Vendor/Office' / expected
                             / 'OfficeNativeHostSimulator/FloeOfficeNative.framework/FloeOfficeNative').is_file())
            # The exact same component re-installs into the verified target.
            bundle2 = make_fake_host_bundle(Path(tmp) / 'stage2')
            zip2 = Path(tmp) / 'second.zip'
            with zipfile.ZipFile(zip2, 'w') as archive:
                for path in sorted(bundle2.rglob('*')):
                    if path.is_dir():
                        archive.write(path, path.relative_to(bundle2.parent).as_posix() + '/')
                for path in sorted(bundle2.rglob('*')):
                    if path.is_file():
                        archive.write(path, path.relative_to(bundle2.parent))
            facts2 = install_simulator_host.install(zip2, repo, set_xcconfig=False)
            self.assertTrue(facts2['alreadyInstalled'])
            self.assertEqual(facts2['installedAt'], facts['installedAt'])
            installed = list((repo / 'FloeAgent/Vendor/Office').iterdir())
            self.assertEqual([d.name for d in installed], [expected])


class EmbedSimulatorPathTests(unittest.TestCase):
    def _fake_app(self, root):
        app = Path(root) / 'Floe Agent.app'
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleIdentifier': 'org.floeagent.ios'}))
        return app

    def test_embed_simulator_copies_and_verifies(self):
        import plistlib
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bundle = make_fake_host_bundle(tmp / 'stage')
            # Real font/language payload checks need the engine registry; stub
            # them to isolate the copy/verify path.
            original = embed_office_host.verify_font_and_language_payload
            embed_office_host.verify_font_and_language_payload = lambda app, res: {'stubbed': True}
            original_fonts = embed_office_host.embed_bundled_fonts
            embed_office_host.embed_bundled_fonts = lambda app: 0
            try:
                app = self._fake_app(tmp / 'app')
                result = embed_office_host.embed_simulator(bundle, app)
            finally:
                embed_office_host.verify_font_and_language_payload = original
                embed_office_host.embed_bundled_fonts = original_fonts
            self.assertTrue(result['embeddedFramework'])
            self.assertTrue((app / 'Frameworks/FloeOfficeNative.framework/FloeOfficeNative').is_file())
            self.assertTrue((app / 'cool.html').is_file())
            self.assertTrue((app / 'OfficeRuntimeResources').is_dir() is False)  # copied flat

    def test_embed_simulator_rejects_foreign_bundle_id(self):
        import plistlib
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bundle = make_fake_host_bundle(tmp / 'stage')
            app = Path(tmp) / 'Other.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps(
                {'CFBundleIdentifier': 'com.example.other'}))
            with self.assertRaises(ValueError):
                embed_office_host.embed_simulator(bundle, app)


class DeviceConfigPreservationTests(unittest.TestCase):
    def test_device_bootstrap_preserves_simulator_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            office = Path(tmp) / 'FloeAgent/Vendor/Office'
            office.mkdir(parents=True)
            xcconfig = office / 'native-host.xcconfig'
            host = office / 'simulator-1-kit/OfficeNativeHostSimulator'
            host.mkdir(parents=True)
            install_simulator_host.rewrite_xcconfig(xcconfig, host, repo_root=Path(tmp))
            # The device bootstrap rewrites the file later; simulator lines survive.
            device_dir = office / '12345/OfficeNativeHost'
            device_dir.mkdir(parents=True)
            (device_dir / 'native-host.json').write_text(json.dumps({
                'sourceCommit': LOCK['commit'],
                'overlaySHA256': LOCK['embeddingOverlay']['sha256'],
                'hostSourceSHA256': {}, 'hostCompilePassed': True,
                'hostLinkPassed': True, 'swiftModuleImportPassed': True,
            }))
            (device_dir / 'FloeOfficeNative.framework').mkdir()
            (device_dir / 'FloeOfficeNative.framework/FloeOfficeNative').write_bytes(b'x')
            (device_dir / 'OfficeRuntimeResources').mkdir()
            # The preservation under test is the file rewrite; device pin
            # verification itself is covered by the pinned harness suite.
            original_checked = bootstrap_office_host.checked_lock
            original_verify = bootstrap_office_host.verify_installed
            bootstrap_office_host.checked_lock = lambda lock_path: (
                LOCK, {'runID': '12345', 'manifestSHA256': 'x'})
            bootstrap_office_host.verify_installed = lambda folder, lock, pin: {}
            try:
                bootstrap_office_host.write_project_configuration(
                    device_dir, xcconfig, project_root=Path(tmp) / 'FloeAgent',
                    lock_path=REPO_ROOT / 'FloeAgent/ThirdParty/Collabora/engine.lock.json')
            finally:
                bootstrap_office_host.checked_lock = original_checked
                bootstrap_office_host.verify_installed = original_verify
            text = xcconfig.read_text()
            self.assertIn('FLOE_OFFICE_HOST_DIR = $(PROJECT_DIR)/Vendor/Office/12345/OfficeNativeHost', text)
            self.assertIn('FLOE_OFFICE_SIM_HOST_DIR', text)
            self.assertIn('FLOE_OFFICE_SIM_LDFLAG = -framework FloeOfficeNative', text)


class VariantLockTests(unittest.TestCase):
    def test_kit_uses_tracked_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, applied = build_simulator_framework.variant_lock('kit', tmp)
            self.assertTrue(applied)
            self.assertEqual(path, build_simulator_framework.LOCK_PATH)

    def test_nokit_drops_kit_overlay(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, applied = build_simulator_framework.variant_lock('nokit', tmp)
            self.assertFalse(applied)
            lock = json.loads(path.read_text())
            self.assertNotIn('kitCallbackLifecycleOverlay', lock)
            self.assertIn('forwardingLifecycleOverlay', lock)

    def test_unknown_variant_rejected(self):
        with self.assertRaises(build_simulator_framework.SimulatorHostBuildError):
            build_simulator_framework.build_framework(
                Path('/nonexistent-restored'), Path(tempfile.mkdtemp()) / 'out',
                variant='bogus', base_run_id='1')


class SimulatorBuildArgumentTests(unittest.TestCase):
    """Input/wiring fixtures only: never invoke native build, SDK or Simulator."""
    def setUp(self):
        from unittest import mock
        self.mock = mock
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name); self.source = self.root / 'source'; self.source.mkdir()
        (self.source / '.git').mkdir()
        source = self.source / 'engine/vcl/source/app/svdata.cxx'; source.parent.mkdir(parents=True)
        source.write_text('synthetic original')
        selected = {'sourceFile':str(source.relative_to(self.source)), 'originalSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
                    'patchedSHA256':'2'*64, 'patchSHA256':'3'*64, 'patch':'patches/compiled.patch',
                    'archive':'source/engine/instdir/program/libvcllo.a', 'members':{'svdata.o':str(source.relative_to(self.source))}}
        self.lock = {'commit':'a'*40, 'embeddedLifecycleOverlay':{'sha256':'b'*64, 'compiledMembers':{'IOSSIMULATOR':selected}}}
        self.lock_path = self.root / 'engine.lock.json'; self.lock_path.write_text(json.dumps(self.lock))
        self.filter_lock = self.root / 'filter.lock.json'
        self.filter_lock.write_text(json.dumps({'simulator':{'archive':'fixture'}, 'patchSHA256':'c'*64}))
        self.overlay = self.root / 'filter'; self.overlay.mkdir()
        (self.overlay / 'libscfiltlo.a').write_bytes(b'synthetic archive, never linked')
        self.filter_receipt = {'platform':'IOSSIMULATOR','sdk':'iphonesimulator','sourceCommit':'a'*40,
                               'patchSHA256':'c'*64,'compilePassed':True,'archiveReplacementPassed':True}
        self.receipt = self.overlay / 'filter-overlay.json'; self.receipt.write_text(json.dumps(self.filter_receipt))
        import build_office_filter_overlay
        patcher = mock.patch.object(build_office_filter_overlay, 'FILTER_LOCK', self.filter_lock)
        patcher.start(); self.addCleanup(patcher.stop)
        patcher = mock.patch.object(build_simulator_framework.subprocess, 'check_output', return_value='a'*40)
        self.git = patcher.start(); self.addCleanup(patcher.stop)

    def inputs(self, **kwargs):
        return build_simulator_framework.validate_build_inputs(self.lock_path, **kwargs)

    def test_missing_engine_source_is_actionable_and_no_sdk_or_build(self):
        with self.assertRaisesRegex(ValueError, '--engine-source is required'):
            self.inputs(filter_overlay=self.overlay)
        self.git.assert_not_called()

    def test_wrong_git_or_modified_source_is_rejected(self):
        self.git.return_value = 'd'*40
        with self.assertRaisesRegex(ValueError, 'HEAD differs'):
            self.inputs(engine_source=self.source, filter_overlay=self.overlay)
        self.git.return_value = 'a'*40
        (self.source / 'engine/vcl/source/app/svdata.cxx').write_text('modified')
        with self.assertRaisesRegex(ValueError, 'missing/modified lifecycle source'):
            self.inputs(engine_source=self.source, filter_overlay=self.overlay)

    def test_missing_device_or_forged_filter_receipt_is_rejected(self):
        with self.assertRaisesRegex(ValueError, '--filter-overlay is required'):
            self.inputs(engine_source=self.source)
        for field, value in [('platform','IOS'),('sdk','iphoneos'),('sourceCommit','d'*40),
                             ('patchSHA256','0'*64),('compilePassed',1),('archiveReplacementPassed',False)]:
            with self.subTest(field=field):
                bad={**self.filter_receipt,field:value}; self.receipt.write_text(json.dumps(bad))
                with self.assertRaisesRegex(ValueError, 'not a successful current-source iphonesimulator'):
                    self.inputs(engine_source=self.source, filter_overlay=self.overlay)

        self.receipt.write_text(json.dumps(self.filter_receipt))
        (self.overlay / 'libscfiltlo.a').unlink()
        with self.assertRaisesRegex(ValueError, 'missing a regular simulator replacement archive'):
            self.inputs(engine_source=self.source, filter_overlay=self.overlay)

    def test_wrapper_forwards_explicit_inputs_and_records_real_input_identity(self):
        m=self.mock; output=self.root/'output'; fake_zip=self.root/'fixture.zip'; fake_zip.write_bytes(b'fixture')
        with m.patch.object(build_simulator_framework,'variant_lock',return_value=(self.lock_path,True)), \
             m.patch.object(build_simulator_framework,'sdk_identity',return_value={}), \
             m.patch.object(build_simulator_framework,'build_host',return_value={}) as build, \
             m.patch.object(build_simulator_framework,'package_host',return_value=(self.root/'bundle',{'kind':'fixture'})) as package, \
             m.patch.object(build_simulator_framework,'zip_bundle',return_value=fake_zip):
            build_simulator_framework.build_framework(self.root/'restored',output,variant='kit',base_run_id='123',
                                                      engine_source=self.source,filter_overlay=self.overlay)
        args=build.call_args.kwargs
        self.assertEqual(args['engine_source'],self.source.resolve())
        self.assertEqual(args['filter_overlay'],self.overlay.resolve())
        self.assertEqual(args['sdk'],'iphonesimulator')
        self.assertEqual(args['lock_path'],self.lock_path)
        expected={'engineSourceCommit':'a'*40,'filterOverlayReportSHA256':hashlib.sha256(self.receipt.read_bytes()).hexdigest()}
        self.assertEqual(package.call_args.args[0]['buildInputs'],expected)
        saved=json.loads((output/'native-host-build-report.json').read_text()); self.assertEqual(saved['buildInputs'],expected)

    def test_cli_passes_explicit_arguments_to_existing_wrapper(self):
        m=self.mock
        with m.patch.object(sys,'argv',['build_simulator_framework.py','--restored',str(self.root/'restored'),
                         '--output',str(self.root/'out'),'--base-run-id','123','--engine-source',str(self.source),
                         '--filter-overlay',str(self.overlay)]), \
             m.patch.object(build_simulator_framework,'build_framework',return_value={}) as build, \
             m.patch('sys.stdout',new_callable=io.StringIO):
            build_simulator_framework.main()
        self.assertEqual(build.call_args.kwargs['engine_source'],self.source)
        self.assertEqual(build.call_args.kwargs['filter_overlay'],self.overlay)


class BuiltModuleReceiptTests(unittest.TestCase):
    def probe(self, output, framework, sdk, returncode=0):
        from unittest import mock
        import build_office_native_host as producer
        with mock.patch.object(producer.subprocess, 'check_output', return_value='/fixture/sdk'), \
             mock.patch.object(producer.subprocess, 'run',
                 return_value=subprocess.CompletedProcess([], returncode)) as run:
            facts = producer.check_built_framework_import(output, framework, sdk)
        command = run.call_args.args[0]
        self.assertEqual(facts['swiftImportTarget'], command[command.index('-target') + 1])
        self.assertEqual(facts['swiftProbeSHA256'], producer.digest(output / 'ImportProbe.swift'))
        return facts

    def test_actual_producer_probe_reports_platform_and_failure(self):
        for sdk, target in [('iphoneos', 'arm64-apple-ios26.0'),
                            ('iphonesimulator', 'arm64-apple-ios26.0-simulator')]:
            for code in (0, 1):
                with self.subTest(sdk=sdk, code=code), tempfile.TemporaryDirectory() as tmp:
                    output = Path(tmp)
                    facts = self.probe(output, output / 'FloeOfficeNative.framework', sdk, code)
                    self.assertEqual(facts['swiftImportTarget'], target)
                    self.assertEqual(facts['swiftModuleImportPassed'], code == 0)

    def test_producer_receipt_packages_and_verifies_without_invented_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            seed = make_fake_host_bundle(root)
            report = json.loads((seed / 'native-host-simulator.json').read_text())
            output = root / 'output'
            build = output / 'build'
            products = build / 'products/Release-iphonesimulator'
            products.mkdir(parents=True)
            framework = products / 'FloeOfficeNative.framework'
            shutil.move(seed / framework.name, framework)
            shutil.move(seed / 'OfficeRuntimeResources', build / 'OfficeRuntimeResources')
            probe_facts = self.probe(build, framework, 'iphonesimulator')
            report.update(probe_facts, sdk='iphonesimulator', platformLoadCommands='fixture')
            restored = root / 'restored'
            restored.mkdir()
            (restored / 'restore-report.json').write_text(json.dumps({
                'sourceCommit': LOCK['commit'], 'provenanceArtifactSHA256': 'a' * 64}))
            import office_engine_repair
            repair_lock, repair_section = office_engine_repair.tracked_contract(
                platform='IOSSIMULATOR')
            if repair_section is not None:
                block = office_engine_repair.expected_manifest_block(
                    repair_lock, repair_section)
                (restored / 'engine-repair.json').write_text(json.dumps({
                    'platform': block['platform'],
                    'lock': {'sha256': block['lockSHA256']},
                    'repair': {'patchSHA256': block['patchSHA256'],
                               'upstreamCommit': block['upstreamCommit'],
                               'sourceFile': block['sourceFile'],
                               'originalSourceSHA256': block['originalSourceSHA256'],
                               'patchedSourceSHA256': block['patchedSourceSHA256']},
                    'compile': {'sdk': block['sdk'], 'target': block['target']},
                    'archive': {'bundlePath': block['archiveBundlePath'],
                                'originalSHA256': block['originalArchiveSHA256'],
                                'patchedSHA256': block['patchedArchiveSHA256'],
                                'memberCount': block['member']['count'],
                                'member': block['member']},
                }, indent=2))
            bundle, receipt = build_simulator_framework.package_host(report, restored, output,
                variant='kit', kit_applied=True, base_run_id='fixture-run',
                identity={'sdkVersion': '27.0', 'sdkBuildVersion': 'fixture', 'xcodeVersion': 'fixture'})
            self.assertEqual(receipt['swiftImportTarget'], probe_facts['swiftImportTarget'])
            self.assertTrue(bootstrap_office_host.verify_simulator_host(bundle)['kitCallbackOverlayApplied'])
            self.assertFalse(receipt['nativeEditorRuntimeVerified'])


class RestoreApiContractTests(unittest.TestCase):
    def test_actual_restore_api_rejects_bad_provenance(self):
        from unittest import mock
        import restore_staged_engine as adapter
        import restore_simulator_bundle as actual
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / 'staged'
            staged.mkdir()
            (staged / sim_paths.STAGED_ENGINE_TAR).write_bytes(b'invalid archive')
            provenance = dict(sourceCommit=LOCK['commit'], repository=LOCK['repository'],
                deploymentPatchSHA256=LOCK['sourcePatchSHA256'], platform='iphonesimulator',
                arch='arm64', sdkVersion='27.0', sdkBuildVersion='24A430',
                xcodeVersion='Xcode 27.0; Build version 27A266a', deploymentTarget='26.0',
                artifactSHA256='invalid', artifactSize=15, platformSampleSize=1,
                allSampledObjectsIOSSIMULATOR=True)
            (staged / sim_paths.STAGED_PROVENANCE).write_text(json.dumps(provenance))
            with mock.patch.object(adapter, 'download_artifact', return_value=staged), \
                 mock.patch.object(adapter, 'current_toolchain',
                     return_value=('Xcode 27.0; Build version 27A266a', '27.0')):
                # Calls the real default restore function: an unexpected
                # keyword must never be hidden by a generic mock accepting it.
                with self.assertRaisesRegex(actual.RestoreError, 'provenance binding failed'):
                    adapter.restore_staged_engine('fixture-run', staged, Path(tmp) / 'restore')

    def test_adapter_binds_to_actual_restore_signature(self):
        from unittest import mock
        import restore_staged_engine as adapter
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp)
            for name in (sim_paths.STAGED_ENGINE_TAR, sim_paths.STAGED_PROVENANCE):
                (staged / name).write_text('fixture')
            with mock.patch.object(adapter, 'download_artifact', return_value=staged), \
                 mock.patch.object(adapter, 'current_toolchain', return_value=('Xcode fixture', 'fixture')), \
                 mock.patch.object(adapter.restore_simulator_bundle, 'restore',
                     autospec=True, return_value={}) as restore:
                result = adapter.restore_staged_engine('fixture-run', staged, staged / 'restored')
            restore.assert_called_once_with(str((staged / sim_paths.STAGED_ENGINE_TAR).resolve()),
                staged / 'restored', provenance_path=str((staged / sim_paths.STAGED_PROVENANCE).resolve()),
                reuse=True, expect_xcode='Xcode fixture', expect_sdk='fixture',
                rewrite_engine_list=False)
            self.assertEqual(result['baseEngineRunID'], 'fixture-run')


if __name__ == '__main__':
    unittest.main()
