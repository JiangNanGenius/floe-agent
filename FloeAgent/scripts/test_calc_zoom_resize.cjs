#!/usr/bin/env node
'use strict';

/*
 * Source-extracted replay for the Calc unchanged-height zoom-finalization
 * scroll correction.
 *
 * The harness reads the real frozen browser sources, extracts the real
 * function bodies with brace matching, evaluates them in a Node vm with the
 * real SimplePoint/SimpleRectangle classes from src/core/geometry.ts (loaded
 * through the pinned TypeScript), and replays the two actual App13 callers
 * plus the preserved height-change and explicit-navigation paths.
 *
 * It is not a browser build and not a UI result. It proves only the source
 * behavior described in HANDOFF.md.
 *
 * Usage:
 *   node test_calc_zoom_resize.cjs \
 *     --browser-root <frozen browser root> \
 *     --original <CalcTileLayer.original.js> \
 *     --patched <CalcTileLayer.patched.js>
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

// App13's observed twips/core-pixel transitions:
//   syn 14106 (4150,2060) -> mbr/ndr 14107 (4149,2062), scl (0,570)
//   syn 14108 (3846,1851) -> ucr/ndr 14108 (3845,1852), scl (0,512)
// 512/1852 == 256/926, the pinned tile size / tileWidthTwips pair used by
// CanvasTileLayer._updateTileTwips for zoom 14.
const PX_PER_TWIP = 512 / 1852;

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2);
    out[key] = argv[i + 1];
    i += 1;
  }
  return out;
}

function braceEnd(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  throw new Error('unbalanced braces');
}

// Returns a standalone `function (...) { ... }` text for one object method.
function extractFunction(source, signature) {
  const at = source.indexOf(signature);
  if (at < 0) throw new Error('method not found: ' + signature);
  const open = source.indexOf('{', at + signature.length - 1);
  if (open < 0) throw new Error('method body not found: ' + signature);
  const close = braceEnd(source, open);
  const text = source.slice(at, close + 1);
  const fnAt = text.indexOf('function');
  if (fnAt < 0) throw new Error('function keyword not found: ' + signature);
  return text.slice(fnAt);
}

function loadCool(browserRoot) {
  const ts = require(path.join(browserRoot, 'node_modules/typescript'));
  const source = fs.readFileSync(path.join(browserRoot, 'src/core/geometry.ts'), 'utf8');
  const emitted = ts.transpileModule(source, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2019,
      module: ts.ModuleKind.None,
    },
  }).outputText;
  const sandbox = {
    console,
    Map,
    Set,
    Array,
    Object,
    Math,
    JSON,
    Number,
    String,
    Boolean,
    Error,
    Date,
    app: {
      twipsToPixels: PX_PER_TWIP,
      pixelsToTwips: 1 / PX_PER_TWIP,
      dpiScale: 2,
      LOUtil: {
        _doRectanglesIntersect: (a, b) =>
          !(a[0] + a[2] < b[0] || b[0] + b[2] < a[0] ||
            a[1] + a[3] < b[1] || b[1] + b[3] < a[1]),
      },
    },
    Util: { ensureValue() {} },
  };
  sandbox.globalThis = sandbox;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(emitted + '\n;globalThis.__cool = cool;', sandbox, { timeout: 5000 });
  if (!sandbox.__cool) throw new Error('geometry.ts did not expose cool');
  // Leaflet's Point is a page dependency; only x/y/equals are used here.
  sandbox.__cool.Point = class Point {
    constructor(x, y) {
      this.x = x;
      this.y = y;
    }
    equals(other) {
      return this.x === other.x && this.y === other.y;
    }
    clone() {
      return new Point(this.x, this.y);
    }
  };
  return { cool: sandbox.__cool, sandbox };
}

function compileFunction(sandbox, slot, fnText) {
  vm.runInContext('globalThis.' + slot + ' = ' + fnText + ';', sandbox, { timeout: 5000 });
  const fn = sandbox[slot];
  if (typeof fn !== 'function') throw new Error('failed to compile ' + slot);
  return fn;
}

function loadFunctions(sandbox, calcSource, canvasSource, patched) {
  return {
    sync: compileFunction(sandbox, '__floeSync',
      extractFunction(calcSource, '_syncTileContainerSize: function()')),
    helper: patched
      ? compileFunction(sandbox, '__floeAfterHeight',
        extractFunction(calcSource, '_afterViewportHeightChange: function(heightIncreased)'))
      : null,
    scroll: compileFunction(sandbox, '__floeScroll',
      extractFunction(calcSource, '_scrollCellCursorIntoView: function ()')),
    calcScroll: compileFunction(sandbox, '__floeCalcScroll',
      extractFunction(calcSource, '_calculateScrollForNewCellCursor: function ()')),
    restrict: compileFunction(sandbox, '__floeRestrict',
      extractFunction(calcSource, '_restrictDocumentSize: function ()')),
    mobile: compileFunction(sandbox, '__floeMobile',
      extractFunction(canvasSource, '_mobileChecksAfterResizeEvent: function(heightIncreased)')),
    nonDesktop: compileFunction(sandbox, '__floeNonDesktop',
      extractFunction(canvasSource, '_nonDesktopChecksAfterResizeEvent: function(heightIncreased)')),
    updateTileTwips: compileFunction(sandbox, '__floeUpdateTileTwips',
      extractFunction(canvasSource, '_updateTileTwips: function ()')),
    updateCellCursor: compileFunction(sandbox, '__floeUpdateCellCursor',
      extractFunction(canvasSource, '_onUpdateCellCursor: function (scrollToCursor, sameAddress)')),
  };
}

function makeState(sandbox, cool, fns, opts) {
  const counts = {
    onResize: [],
    scrollTo: [],
    viewTrail: [],
    cellScroll: [],
    scrollCell: [],
    calcScroll: [],
    mobile: [],
    nonDesktop: [],
    onUpdateCursor: [],
    setAcceptInput: [],
    draw: [],
    sizeIncreased: [],
    fire: [],
    addArrow: [],
    removeArrow: [],
    editorgotfocus: [],
    _inCell: 0,
  };

  const view = new cool.SimpleRectangle(
    opts.viewX, opts.viewY, opts.viewWidthTwips, opts.viewHeightTwips);
  const frameWidthPx = opts.frameWidthPx;
  const frameHeightPx = opts.frameHeightPx;
  const newFrameWidthPx = opts.newFrameWidthPx == null ? frameWidthPx : opts.newFrameWidthPx;
  const newFrameHeightPx = opts.newFrameHeightPx == null ? frameHeightPx : opts.newFrameHeightPx;

  const layout = {
    _frameCore: { w: frameWidthPx, h: frameHeightPx },
    _viewedRectangle: view,
    get frameSize() {
      return cool.SimplePoint.fromCorePixels([this._frameCore.w, this._frameCore.h]);
    },
    get viewedRectangle() {
      return this._viewedRectangle;
    },
    set viewedRectangle(rectangle) {
      this._viewedRectangle = rectangle;
    },
    scrollTo(pX, pY) {
      const record = { pX, pY, inCell: counts._inCell > 0 };
      counts.scrollTo.push(record);
      if (record.inCell) counts.cellScroll.push(record);
      this._viewedRectangle = cool.SimpleRectangle.fromCorePixels(
        [pX, pY, this._frameCore.w, this._frameCore.h]);
      counts.viewTrail.push([this._viewedRectangle.x1, this._viewedRectangle.y1]);
    },
  };

  const app = {
    twipsToPixels: PX_PER_TWIP,
    pixelsToTwips: 1 / PX_PER_TWIP,
    dpiScale: 2,
    tile: { size: new cool.SimplePoint(0, 0) },
    file: {
      textCursor: {
        visible: !!opts.textCursorVisible,
        rectangle: opts.textCursorVisible
          ? new cool.SimpleRectangle(0, 5000, 100, 100)
          : new cool.SimpleRectangle(0, 0, 0, 0),
      },
    },
    calc: {
      cellCursorVisible: opts.cellCursorVisible !== false,
      cellAddress: new cool.SimplePoint(0, 0),
      cellCursorRectangle: new cool.SimpleRectangle(0, 0, 1450, 500),
      splitCoordinate: new cool.SimplePoint(0, opts.freezeRow ? 510 : 0),
    },
    activeDocument: {
      fileSize: new cool.SimplePoint(30000, 30000),
      activeLayout: layout,
    },
    sectionContainer: {
      onResize(w, h) {
        counts.onResize.push([w, h]);
        layout._frameCore = { w: newFrameWidthPx, h: newFrameHeightPx };
      },
      requestReDraw() {
        counts.draw.push(1);
      },
    },
    getViewRectangles() {
      if (!opts.freezeRow) return [layout._viewedRectangle.clone()];
      const frozen = new cool.SimpleRectangle(
        layout._viewedRectangle.x1, 0,
        layout._viewedRectangle.width, opts.freezeHeightTwips);
      return [frozen, layout._viewedRectangle.clone()];
    },
    LOUtil: sandbox.app && sandbox.app.LOUtil,
  };

  const layer = {
    _map: {
      _docLoaded: opts.docLoaded !== false,
      options: { zoom: 14 },
      uiManager: { mobileWizard: null },
      setAcceptInput(value) {
        counts.setAcceptInput.push(value);
      },
      calcInputBarHasFocus() {
        return !!opts.inputBarFocused;
      },
      fire(name) {
        counts.fire.push(name);
        if (name === 'sizeincreased') counts.sizeIncreased.push(1);
        if (name === 'editorgotfocus') counts.editorgotfocus.push(1);
      },
      _docLayer: {
        _cursorMarker: opts.textCursorVisible ? { isDomAttached: () => true } : null,
        isCalcRTL: () => false,
      },
    },
    options: { tileWidthTwips: 926 },
    _tileZoom: 14,
    _docType: 'spreadsheet',
    _splitPanesContext: null,
    _scrollFreePaneToTopOnA1: false,
    _lastColumn: 1,
    _lastRow: 1,
    _documentSizeFrozen: false,
    widthShrinked: false,
    heightShrinked: false,
    sheetGeometry: {
      getSize() {
        return new cool.SimplePoint(20000, 20000);
      },
      getCellRect() {
        const corner = new cool.Point(1000, 1000);
        return {
          getBottomLeft: () => corner,
          getBottomRight: () => corner,
        };
      },
    },
    isCalc() {
      return true;
    },
    _updateSpacerSizes() {},
    _updateHeaderSections() {},
    _onUpdateCursor(scroll) {
      counts.onUpdateCursor.push(scroll);
    },
    _addCellDropDownArrow() {
      counts.addArrow.push(1);
    },
    _removeCellDropDownArrow() {
      counts.removeArrow.push(1);
    },
    _twipsToPixels(point) {
      return new cool.Point(
        Math.round(point.x * app.twipsToPixels),
        Math.round(point.y * app.twipsToPixels));
    },
    _corePixelsToTwips(point) {
      return new cool.Point(
        Math.round(point.x * app.pixelsToTwips),
        Math.round(point.y * app.pixelsToTwips));
    },
    _syncTileContainerSize: fns.sync,
    _updateTileTwips: fns.updateTileTwips,
    _restrictDocumentSize: fns.restrict,
  };

  if (fns.helper) layer._afterViewportHeightChange = fns.helper;

  layer._mobileChecksAfterResizeEvent = function (heightIncreased) {
    counts.mobile.push(heightIncreased);
    return fns.mobile.call(this, heightIncreased);
  };
  layer._nonDesktopChecksAfterResizeEvent = function (heightIncreased) {
    counts.nonDesktop.push(heightIncreased);
    return fns.nonDesktop.call(this, heightIncreased);
  };
  layer._scrollCellCursorIntoView = function () {
    counts.scrollCell.push(1);
    counts._inCell += 1;
    try {
      return fns.scroll.call(this);
    } finally {
      counts._inCell -= 1;
    }
  };
  layer._calculateScrollForNewCellCursor = function () {
    const scroll = fns.calcScroll.call(this);
    counts.calcScroll.push([scroll.x, scroll.y]);
    return scroll;
  };
  layer._onUpdateCellCursor = fns.updateCellCursor;

  sandbox.app = app;
  sandbox.mode = {
    isDesktop: () => false,
    isSmallScreenDevice: () => opts.smallScreen !== false,
    isTablet: () => !!opts.tablet,
  };
  sandbox.document = { activeElement: {} };
  sandbox.$ = () => ({ is: () => false });
  sandbox.RenderManager = { tileSize: 256 };
  sandbox.JSDialog = { IsAnyInputFocused: () => false };
  sandbox.CellSelectionMarkers = { update() {} };
  sandbox.URLPopUpSection = { closeURLPopUp() {} };

  return { counts, layout, app, layer };
}

function runScenario(sandbox, cool, fns, mode, opts) {
  const state = makeState(sandbox, cool, fns, opts);
  if (mode === 'zoomEnd') state.layer._updateTileTwips();
  else if (mode === 'restrict') state.layer._restrictDocumentSize();
  else if (mode === 'sync') state.layer._syncTileContainerSize();
  else if (mode === 'explicitScroll') {
    state.layer._syncTileContainerSize();
    state.layer._scrollCellCursorIntoView();
  } else if (mode === 'explicitCellNav') {
    state.layer._syncTileContainerSize();
    state.layer._onUpdateCellCursor(true, false);
  } else {
    throw new Error('unknown mode: ' + mode);
  }
  return {
    mode,
    finalView: [state.layout._viewedRectangle.x1, state.layout._viewedRectangle.y1],
    counts: {
      onResize: state.counts.onResize,
      scrollTo: state.counts.scrollTo,
      viewTrail: state.counts.viewTrail,
      cellScroll: state.counts.cellScroll,
      scrollCell: state.counts.scrollCell,
      calcScroll: state.counts.calcScroll,
      mobile: state.counts.mobile,
      nonDesktop: state.counts.nonDesktop,
      onUpdateCursor: state.counts.onUpdateCursor,
      setAcceptInput: state.counts.setAcceptInput,
      sizeIncreased: state.counts.sizeIncreased,
      fire: state.counts.fire,
      editorgotfocus: state.counts.editorgotfocus,
    },
  };
}

function baseOptions(overrides) {
  return Object.assign({
    viewX: 4149,
    viewY: 2062,
    viewWidthTwips: 7835,
    viewHeightTwips: 3378,
    frameWidthPx: 2166,
    frameHeightPx: 934,
    freezeRow: true,
    freezeHeightTwips: 510,
    smallScreen: true,
    tablet: false,
    inputBarFocused: false,
    textCursorVisible: false,
  }, overrides || {});
}

function normalize(result) {
  return JSON.stringify(result);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const browserRoot = args['browser-root'];
  const originalPath = args.original;
  const patchedPath = args.patched;
  if (!browserRoot || !originalPath || !patchedPath) {
    console.error('usage: test_calc_zoom_resize.cjs --browser-root <root> --original <file> --patched <file>');
    process.exit(2);
  }

  const originalSource = fs.readFileSync(originalPath, 'utf8');
  const patchedSource = fs.readFileSync(patchedPath, 'utf8');
  const canvasSource = fs.readFileSync(
    path.join(browserRoot, 'src/layer/tile/CanvasTileLayer.js'), 'utf8');

  if (originalSource.includes('_afterViewportHeightChange')) {
    throw new Error('original source unexpectedly contains the new helper');
  }
  if (!patchedSource.includes('if (oldFrame.pY !== frame.pY)')) {
    throw new Error('patched source is missing the unchanged-height guard');
  }
  if (!patchedSource.includes('_afterViewportHeightChange: function(heightIncreased)')) {
    throw new Error('patched source is missing the helper');
  }

  const { cool, sandbox } = loadCool(browserRoot);
  const originalFns = loadFunctions(sandbox, originalSource, canvasSource, false);
  const patchedFns = loadFunctions(sandbox, patchedSource, canvasSource, true);

  const zoomEnd = baseOptions({ viewX: 4150, viewY: 2060 });
  const restrict = baseOptions({ viewX: 3846, viewY: 1851 });
  const keyboardDown = baseOptions({ frameHeightPx: 934, newFrameHeightPx: 500 });
  const keyboardUp = baseOptions({ frameHeightPx: 500, newFrameHeightPx: 934 });
  const keyboardDownText = baseOptions({
    frameHeightPx: 934,
    newFrameHeightPx: 500,
    textCursorVisible: true,
  });
  const noFreeze = baseOptions({ freezeRow: false });
  const inputBar = baseOptions({ inputBarFocused: true });
  const notMobile = baseOptions({ smallScreen: false, tablet: false });

  const scenarios = [
    { name: 'zoomEnd caller', mode: 'zoomEnd', options: zoomEnd },
    { name: 'restrict caller', mode: 'restrict', options: restrict },
    { name: 'keyboard height decrease', mode: 'sync', options: keyboardDown },
    { name: 'keyboard height increase', mode: 'sync', options: keyboardUp },
    { name: 'keyboard decrease, text caret', mode: 'sync', options: keyboardDownText },
    { name: 'unchanged height, no freeze', mode: 'sync', options: noFreeze },
    { name: 'unchanged height, input-bar focus', mode: 'sync', options: inputBar },
    { name: 'unchanged height, not mobile', mode: 'sync', options: notMobile },
    { name: 'explicit cell navigation', mode: 'explicitCellNav', options: zoomEnd },
    { name: 'explicit scroll primitive', mode: 'explicitScroll', options: zoomEnd },
  ];

  const results = [];
  const checks = [];
  const check = (label, actual, expected) => {
    const pass = JSON.stringify(actual) === JSON.stringify(expected);
    checks.push({ label, actual, expected, pass });
  };

  for (const scenario of scenarios) {
    const before = runScenario(sandbox, cool, originalFns, scenario.mode, scenario.options);
    const after = runScenario(sandbox, cool, patchedFns, scenario.mode, scenario.options);
    results.push({ name: scenario.name, mode: scenario.mode, before, after });

    if (scenario.name === 'zoomEnd caller') {
      check('zoom-end pre-fix cell scroll', before.counts.cellScroll, [{ pX: 0, pY: 570, inCell: true }]);
      check('zoom-end pre-fix delta', before.counts.calcScroll, [[-4149, 0]]);
      check('zoom-end pre-fix view trail', before.counts.viewTrail, [[4149, 2062], [0, 2062]]);
      check('zoom-end pre-fix final view', before.finalView, [0, 2062]);
      check('zoom-end patched cell scroll', after.counts.cellScroll, []);
      check('zoom-end patched delta', after.counts.calcScroll, []);
      check('zoom-end patched view trail', after.counts.viewTrail, [[4149, 2062]]);
      check('zoom-end patched final view', after.finalView, [4149, 2062]);
    }
    if (scenario.name === 'restrict caller') {
      check('restrict pre-fix cell scroll', before.counts.cellScroll, [{ pX: 0, pY: 512, inCell: true }]);
      check('restrict pre-fix delta', before.counts.calcScroll, [[-3845, 0]]);
      check('restrict pre-fix view trail', before.counts.viewTrail, [[3845, 1852], [0, 1852]]);
      check('restrict pre-fix final view', before.finalView, [0, 1852]);
      check('restrict patched cell scroll', after.counts.cellScroll, []);
      check('restrict patched delta', after.counts.calcScroll, []);
      check('restrict patched view trail', after.counts.viewTrail, [[3845, 1852]]);
      check('restrict patched final view', after.finalView, [3845, 1852]);
    }
    if (scenario.name === 'keyboard height decrease') {
      check('height decrease traces equal', normalize(after.counts), normalize(before.counts));
      check('height decrease still scrolls cell', after.counts.scrollCell, [1]);
      check('height decrease updates cursor', after.counts.onUpdateCursor, [true]);
      check('height decrease calls both resize checks', after.counts.nonDesktop, [false]);
    }
    if (scenario.name === 'keyboard height increase') {
      check('height increase traces equal', normalize(after.counts), normalize(before.counts));
      check('height increase sets accept input', after.counts.setAcceptInput, [false]);
      check('height increase does not scroll cell', after.counts.scrollCell, []);
      check('height increase calls both resize checks', after.counts.nonDesktop, [true]);
    }
    if (scenario.name === 'keyboard decrease, text caret') {
      check('text-caret decrease traces equal', normalize(after.counts), normalize(before.counts));
      check('text-caret decrease updates cursor twice',
        after.counts.onUpdateCursor, [true, true]);
      check('text-caret decrease does not use cell scroll', after.counts.scrollCell, []);
      check('text-caret decrease scrolls view', after.counts.scrollTo.length > 0, true);
    }
    if (scenario.name === 'unchanged height, no freeze') {
      check('no-freeze pre-fix delta', before.counts.calcScroll, [[-4149, -2062]]);
      check('no-freeze pre-fix final view', before.finalView, [0, 0]);
      check('no-freeze patched scroll', after.counts.scrollCell, []);
      check('no-freeze patched final view', after.finalView, [4149, 2062]);
    }
    if (scenario.name === 'unchanged height, input-bar focus') {
      check('input-bar focus pre-fix no cell scroll', before.counts.scrollCell, []);
      check('input-bar focus patched no cell scroll', after.counts.scrollCell, []);
      check('input-bar focus final view unchanged', after.finalView, before.finalView);
    }
    if (scenario.name === 'unchanged height, not mobile') {
      check('not-mobile pre-fix no cell scroll', before.counts.scrollCell, []);
      check('not-mobile patched no cell scroll', after.counts.scrollCell, []);
      check('not-mobile final view unchanged', after.finalView, before.finalView);
    }
    if (scenario.name === 'explicit cell navigation') {
      check('explicit cell navigation still scrolls', after.counts.scrollCell, [1]);
      check('explicit cell navigation delta', after.counts.calcScroll, [[-4149, 0]]);
      check('explicit cell navigation scrollTo', after.counts.cellScroll,
        [{ pX: 0, pY: 570, inCell: true }]);
      check('explicit cell navigation final view', after.finalView, [0, 2062]);
      check('explicit cell navigation fires editor focus', after.counts.editorgotfocus, [1]);
    }
    if (scenario.name === 'explicit scroll primitive') {
      check('explicit scroll primitive still scrolls', after.counts.scrollCell, [1]);
      check('explicit scroll primitive delta', after.counts.calcScroll, [[-4149, 0]]);
      check('explicit scroll primitive final view', after.finalView, [0, 2062]);
    }
  }

  const failed = checks.filter((item) => !item.pass);
  const out = {
    formatVersion: 1,
    kind: 'Floe Calc unchanged-height zoom-finalization source replay',
    browserRoot,
    original: path.basename(originalPath),
    patched: path.basename(patchedPath),
    pxPerTwip: PX_PER_TWIP,
    observed: {
      firstCaller: {
        trigger: '_updateTileTwips -> applyZoom/endZoom',
        synT: 14106,
        frameHeightCore: 934,
        heightIncreased: 0,
        entryViewTwips: [4150, 2060],
        deltaTwips: [-4149, 0],
        scrollToCorePixels: [0, 570, null],
        afterViewTwips: [0, 2062],
      },
      secondCaller: {
        trigger: '_restrictDocumentSize -> _onZoomRowColumns',
        synT: 14108,
        frameHeightCore: 934,
        heightIncreased: 0,
        entryViewTwips: [3846, 1851],
        deltaTwips: [-3845, 0],
        scrollToCorePixels: [0, 512, null],
        afterViewTwips: [0, 1852],
      },
      compatClickT: 14116,
    },
    results,
    checks,
    summary: { total: checks.length, passed: checks.length - failed.length, failed: failed.length },
    ok: failed.length === 0,
  };
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
  if (!out.ok) {
    console.error('FAIL: ' + failed.map((item) => item.label).join(' | '));
    process.exit(1);
  }
}

main();
