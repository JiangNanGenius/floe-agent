#!/usr/bin/env python3
"""Deterministic visible-render qualification for the shipped Office host.

The presentation bug this guards against: the engine's `docloaded` event, a
non-empty canvas and the mobile file-based view's page skeletons are all
available while no document tile has ever been decoded — a surface that reports
ready there is a blank editor. This module runs the *actual* shipped probe
script (extracted from `FloeOfficeNative.mm`) against synthetic engine states
and compiles the *actual* native decision function, so the JavaScript facts and
the native readiness rule are exercised by the same fixtures:

  - a decoded document tile is visible-render evidence;
  - page skeletons and a blank canvas are not;
  - a presentation must never report ready from `docloaded` alone;
  - the host's mirrored format list matches the App's Swift gate.

Nothing here claims engine or device success: `engineVisibleRenderPassed` and
`deviceVisibleRenderPassed` stay false until a real document render receipt
exists.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HOST_SOURCE = ROOT / 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'
SWIFT_GATE = ROOT / 'FloeApp/Workspace/OfficeDocumentEditorView.swift'


def fragment(text, begin, end):
    return text.split(begin, 1)[1].split(end, 1)[0]


def extraction():
    host = HOST_SOURCE.read_text()
    decision = fragment(host, '// FLOE_RENDER_DECISION_BEGIN', '// FLOE_RENDER_DECISION_END')
    script_source = fragment(host, '// FLOE_RENDER_PROBE_SCRIPT_BEGIN', '// FLOE_RENDER_PROBE_SCRIPT_END')
    script = fragment(script_source, 'R"FLOE_JS(', ')FLOE_JS"')
    return decision, script


# Synthetic engine states. `pixels` names a deterministic downsampled paint.
CASES = {
    # A real slide tile was decoded: visible-render evidence even though the
    # file-based view painted only page skeletons around it.
    'presentationDecodedTile': {'docType': 'presentation', 'docLoaded': True, 'fileBasedView': True,
                                'canvases': [{'width': 1024, 'height': 768, 'pixels': 'skeleton'}],
                                'tiles': [{'image': True}, {'image': False}]},
    # The regression: skeletons, docloaded, a sized canvas, tiles created but
    # never decoded. This must not qualify as a rendered presentation.
    'presentationSkeletonOnly': {'docType': 'presentation', 'docLoaded': True, 'fileBasedView': True,
                                 'canvases': [{'width': 1024, 'height': 768, 'pixels': 'skeleton'}],
                                 'tiles': [{'image': False}, {'image': False}]},
    'presentationBlankCanvas': {'docType': 'presentation', 'docLoaded': True,
                                'canvases': [{'width': 1024, 'height': 768, 'pixels': 'blank'}],
                                'tiles': []},
    'presentationNotLoaded': {'docType': 'presentation', 'docLoaded': False,
                              'canvases': [{'width': 1024, 'height': 768, 'pixels': 'slide'}],
                              'tiles': [{'image': True}]},
    'presentationNoCanvas': {'docType': 'presentation', 'docLoaded': True, 'canvases': [],
                             'tiles': [{'image': True}]},
    'presentationUnknownType': {'docType': None, 'docLoaded': True,
                                'canvases': [{'width': 1024, 'height': 768, 'pixels': 'slide'}],
                                'tiles': [{'image': True}]},
    'presentationZeroCanvas': {'docType': 'presentation', 'docLoaded': True,
                               'canvases': [{'width': 0, 'height': 0, 'pixels': 'slide'}],
                               'tiles': [{'image': True}]},
    'vectorPainted': {'docType': 'presentation', 'docLoaded': True, 'vector': True,
                      'canvases': [{'width': 1024, 'height': 768, 'pixels': 'slide'}], 'tiles': []},
    'writerDecodedTile': {'docType': 'text', 'docLoaded': True,
                          'canvases': [{'width': 1024, 'height': 768, 'pixels': 'slide'}],
                          'tiles': [{'image': True}]},
    'writerNoTileYet': {'docType': 'text', 'docLoaded': True,
                        'canvases': [{'width': 1024, 'height': 768, 'pixels': 'skeleton'}],
                        'tiles': [{'image': False}]},
    'mapMissing': {'map': False},
}

EXPECTED = {
    'presentationDecodedTile': True,
    'presentationSkeletonOnly': False,
    'presentationBlankCanvas': False,
    'presentationNotLoaded': False,
    'presentationNoCanvas': False,
    'presentationUnknownType': False,
    'presentationZeroCanvas': False,
    'vectorPainted': True,
    'writerDecodedTile': True,
    'writerNoTileYet': False,
    'mapMissing': False,
}


PAGE_HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
function paintData(kind) {
    const pixels = 24 * 16;
    const colours = {blank: [255, 255, 255], skeleton: [255, 255, 255, 221, 227, 234], slide: [255, 255, 255, 22, 93, 190, 40, 40, 40]};
    const opaque = {blank: pixels, skeleton: Math.round(pixels * 0.4), slide: Math.round(pixels * 0.8)};
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
function canvas(spec) {
    return {
        width: spec.width, height: spec.height,
        clientWidth: spec.width, clientHeight: spec.height,
        getContext: () => ({
            drawImage(source) { this.paint = source.paint; },
            getImageData: () => ({data: paintData(this.paint)}),
        }),
    };
}
function run(session) {
    const canvases = (session.canvases || []).map(canvas);
    for (let i = 0; i < canvases.length; i++) canvases[i].paint = session.canvases[i].pixels;
    const document = {
        readyState: 'complete',
        addEventListener() {},
        querySelectorAll: (selector) => (selector === 'canvas' ? canvases : []),
        createElement: () => ({width: 0, height: 0, getContext: () => ({
            paint: 'blank',
            drawImage(source) { this.paint = source.paint; },
            getImageData() { return {data: paintData(this.paint)}; },
        })}),
    };
    const app = {file: {fileBasedView: session.fileBasedView === true, readOnly: session.readOnly === true}};
    const window = {app: app};
    if (session.map !== false) {
        app.map = {
            _docLoaded: session.docLoaded === true,
            _docLayer: session.docType ? {_docType: session.docType} : null,
            isEditMode: () => session.uiEdit === true,
            _permission: session.permission || 'readonly',
            getDocType() { return this._docLayer ? this._docLayer._docType : null; },
        };
    }
    if (session.tiles) {
        const tiles = new Map();
        session.tiles.forEach((tile, index) => tiles.set('t' + index, {
            image: tile.image ? {} : null,
            isReadyToDraw() { return !!this.image; },
        }));
        window.RenderManager = {getTiles: () => tiles, isVectorRendering: () => session.vector === true};
    }
    return vm.runInNewContext(source, {window: window, document: document});
}
const cases = JSON.parse(process.argv[2]);
const results = {};
for (const name of Object.keys(cases)) results[name] = run(cases[name]);
console.log(JSON.stringify(results));
'''


DECISION_HARNESS = r'''
static FloeRenderFacts facts(bool type, bool loaded, bool canvas, bool tile, bool painted, bool vector) {
    FloeRenderFacts value;
    value.docTypeKnown = type; value.docLoaded = loaded; value.canvasSized = canvas;
    value.tileDecoded = tile; value.pixelPainted = painted; value.vectorRendering = vector;
    return value;
}
int main() { @autoreleasepool {
    assert(FloeRenderFactsSatisfyVisibleRender(facts(true, true, true, true, false, false)));
    assert(!FloeRenderFactsSatisfyVisibleRender(facts(true, true, true, false, true, false)));
    assert(FloeRenderFactsSatisfyVisibleRender(facts(true, true, true, false, true, true)));
    assert(!FloeRenderFactsSatisfyVisibleRender(facts(true, true, true, false, false, true)));
    assert(!FloeRenderFactsSatisfyVisibleRender(facts(true, false, true, true, true, false)));
    assert(!FloeRenderFactsSatisfyVisibleRender(facts(false, true, true, true, true, false)));
    assert(!FloeRenderFactsSatisfyVisibleRender(facts(true, true, false, true, true, false)));
    const char *impressFormats[] = {"ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
                                    "odp", "otp", "fodp", "odg", "otg", "fodg"};
    for (const char *name : impressFormats)
        assert(FloeDocumentRequiresVisibleRender([NSString stringWithUTF8String:name]));
    const char *otherFormats[] = {"docx", "xlsx", "doc", "xls", "odt", "ods", "rtf", "txt", "pdf"};
    for (const char *name : otherFormats)
        assert(!FloeDocumentRequiresVisibleRender([NSString stringWithUTF8String:name]));
    assert(!FloeDocumentRequiresVisibleRender(nil));
    puts("native visible-render decision and format classification passed");
    return 0;
} }
'''


def native_decision(fact):
    canvas = fact.get('canvas') or {}
    pixels = fact.get('pixels') or {}
    samples = pixels.get('samples') or 0
    return (bool(fact.get('docType')) and fact.get('docLoaded') is True
            and bool(canvas.get('width', 0) > 1 and canvas.get('height', 0) > 1)
            and ((fact.get('decodedTiles') or 0) > 0
                 or (fact.get('vectorRendering') is True and bool(pixels)
                     and pixels.get('distinctColours', 0) >= 2
                     and 0 < samples <= pixels.get('opaque', 0) * 8)))


def check():
    decision, script = extraction()
    with tempfile.TemporaryDirectory(prefix='floe-render-readiness-') as folder:
        root = Path(folder)
        harness = root / 'probe.js'
        harness.write_text('const source = ' + json.dumps(script) + ';\n' + PAGE_HARNESS)
        result = subprocess.run(['node', str(harness), json.dumps(CASES)],
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise AssertionError('probe harness failed: ' + result.stderr[-2000:])
        facts = json.loads(result.stdout)
        program = root / 'decision.mm'
        program.write_text('#import <Foundation/Foundation.h>\n#include <cassert>\n#include <cstdio>\n'
                           + decision + '\n' + DECISION_HARNESS)
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc',
                        '-Wall', '-Werror', '-framework', 'Foundation', str(program),
                        '-o', str(root / 'decision')], check=True, capture_output=True, text=True)
        subprocess.run([str(root / 'decision')], check=True, capture_output=True, text=True, timeout=20)
    verdicts = {name: native_decision(fact) for name, fact in facts.items()}
    for name, want in EXPECTED.items():
        if verdicts[name] != want:
            raise AssertionError(f'{name}: probe/native decision {verdicts[name]} != expected {want} ({facts[name]})')
    # No document contents, paths or bytes may ever leave the probe.
    for name, fact in facts.items():
        serialized = json.dumps(fact)
        for forbidden in ('file_path', 'file:///', 'EDITED_', 'ROUNDTRIP_'):
            if forbidden in serialized:
                raise AssertionError(f'{name}: probe leaked {forbidden}')
    if parsed_visible_render_formats(decision) != swift_visible_render_formats():
        raise AssertionError('host and App visible-render format lists differ')
    return {
        'checksPassed': [
            'a decoded document tile qualifies as visible render for presentation and writer formats',
            'docloaded plus file-based page skeletons never qualifies a presentation',
            'a blank, zero-size or missing canvas never qualifies',
            'an unloaded document or unknown document type never qualifies',
            'vector-rendered documents qualify only through a real painted surface',
            'the native decision function compiles from the shipped source and agrees with the probe',
            'the probe reports only engine state and counters, never document contents',
            'the host and App visible-render format lists are identical',
        ],
        'hostImplementationSHA256': sha256(HOST_SOURCE),
        'nativeDecisionCompiled': True,
        'engineVisibleRenderPassed': False,
        'deviceVisibleRenderPassed': False,
    }


def parsed_visible_render_formats(decision):
    match = re.search(r'\[NSSet setWithArray:@\[(.*?)\]\]', decision, re.S)
    if not match:
        raise AssertionError('cannot find the host visible-render format list')
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def swift_visible_render_formats():
    text = SWIFT_GATE.read_text()
    match = re.search(r'renderRequiredExtensions[^=]*=\s*\[(.*?)\]', text, re.S)
    if not match:
        raise AssertionError('cannot find the App visible-render format list')
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def sha256(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
