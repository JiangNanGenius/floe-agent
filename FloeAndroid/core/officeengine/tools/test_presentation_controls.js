#!/usr/bin/env node
/*
 * Focused semantic checks for floe-impress-follow-controls-fix.js.
 *
 * WHAT THIS IS: a deterministic stub-sandbox check of the overlay's
 * showFollow gating decision against faithful stubs of the pinned
 * UIManager.showButton lookup (Control.UIManager.js:1342-1360), the
 * notebookbar found-quirk (Control.Notebookbar.js:1157-1166) and the stock
 * SlideShowPresenter.showFollow (SlideShowPresenter.js:10-13). It proves:
 *   - the STOCK path reproduces exactly the two observed phone errors
 *     ("UIManager: Button with id slide-presentation-follow[-me] not
 *     found." — SAMSUNG_C06_PPT_DIAGNOSTIC evidence),
 *   - the patched path emits no error and no showButton call on UIs that
 *     do not provide the controls,
 *   - the patched path preserves stock behaviour (same ids, same show
 *     flags, same order) on every UI shape that DOES provide them,
 *   - the overlay never touches UIManager itself: genuinely missing
 *     buttons elsewhere still log their real error,
 *   - a lookup that throws fails closed (skip, never guess).
 * It is NOT device evidence and does not prove rendering, tiles,
 * permissions or readiness.
 *
 * Run: node core/officeengine/tools/test_presentation_controls.js
 *      (exit 0 = every authored check passed)
 */
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SNIPPET_PATH = path.join(__dirname, '../overlays/dist/floe-impress-follow-controls-fix.js');
const SNIPPET_SRC = fs.readFileSync(SNIPPET_PATH, 'utf8');

let checks = 0;
function ok(condition, name) {
  checks++;
  if (!condition) throw new Error('FAIL: ' + name);
}
function eq(actual, expected, name) {
  ok(actual === expected, name + ' (got ' + JSON.stringify(actual) + ', want ' + JSON.stringify(expected) + ')');
}
function eqSeq(actual, expected, name) {
  eq(JSON.stringify(actual), JSON.stringify(expected), name);
}

// Faithful stub of the pinned UIManager.showButton lookup semantics:
// classic -> empty toolbars list + map.topToolbar.hasItem; notebookbar ->
// showItem/hideItem always answer found; otherwise console.error.
function makeUiManager(options) {
  const opts = options || {};
  const errors = [];
  const calls = [];
  const topToolbar = opts.topToolbar === undefined ? undefined : {
    hasItem: function (id) { return opts.topToolbar.indexOf(id) !== -1; },
    showItem: function () { return true; },
  };
  const notebookbar = opts.notebookbar
    ? { showItem: function () { return true; }, hideItem: function () { return true; } }
    : null;
  const uiManager = {
    _map: { topToolbar: topToolbar },
    notebookbar: notebookbar,
    hiddenButtons: {},
    getCurrentMode: function () {
      if (opts.throwInGetCurrentMode) throw new Error('simulated-lookup-error');
      return opts.mode || 'classic';
    },
    showButtonInClassicToolbar: function (buttonId, show) {
      const toolbars = [];
      let found = false;
      toolbars.forEach(function (toolbar) {
        if (toolbar && toolbar.get(buttonId)) {
          found = true;
          toolbar.showItem(buttonId, show);
        }
      });
      if (!uiManager._map.topToolbar) return found;
      const topToolbarHas = uiManager._map.topToolbar.hasItem(buttonId);
      found = found || topToolbarHas;
      if (topToolbarHas) uiManager._map.topToolbar.showItem(buttonId, show);
      return found;
    },
    showButton: function (buttonId, show) {
      calls.push([buttonId, !!show]);
      let found = false;
      if (show) delete uiManager.hiddenButtons[buttonId];
      else uiManager.hiddenButtons[buttonId] = true;
      if (uiManager.getCurrentMode() === 'classic') {
        found = uiManager.showButtonInClassicToolbar(buttonId, show);
      }
      if (uiManager.notebookbar) {
        found = show
          ? uiManager.notebookbar.showItem(buttonId)
          : uiManager.notebookbar.hideItem(buttonId);
      }
      if (!found) {
        errors.push('UIManager: Button with id "' + buttonId + '" not found.');
      }
    },
  };
  return { uiManager: uiManager, errors: errors, calls: calls };
}

// Stock SlideShowPresenter.showFollow exactly as the pinned bundle defines
// it (SlideShowPresenter.js:10-13).
function stockShowFollow(me) {
  this._map.uiManager.showButton('slide-presentation-follow', !me);
  this._map.uiManager.showButton('slide-presentation-follow-me', me);
}

function makeSandbox(options) {
  const opts = options || {};
  const harness = makeUiManager(opts);
  const presenterPrototype = {
    showFollow: stockShowFollow,
    addHooks: function () {},
    removeHooks: function () {},
  };
  const sandbox = {
    window: {
      ThisIsAMobileApp: opts.mobileApp !== false,
      app: { console: { error: function () {}, debug: function () {}, log: function () {} } },
    },
  };
  if (opts.bundleShape !== false) {
    sandbox.window.SlideShow = { SlideShowPresenter: function () {} };
    sandbox.window.SlideShow.SlideShowPresenter.prototype = presenterPrototype;
  }
  sandbox.window.app.map = { uiManager: harness.uiManager };
  vm.createContext(sandbox);
  return {
    sandbox: sandbox,
    prototype: presenterPrototype,
    errors: harness.errors,
    calls: harness.calls,
    inject: function () {
      vm.runInContext(SNIPPET_SRC, sandbox, { filename: 'floe-impress-follow-controls-fix.js' });
    },
    makePresenter: function () { return { _map: { uiManager: harness.uiManager } }; },
  };
}

// -----------------------------------------------------------------------
// 1. The STOCK path reproduces the exact observed phone defect.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ mode: 'classic', topToolbar: undefined });
  const presenter = env.makePresenter();
  stockShowFollow.call(presenter, true);
  eqSeq(env.errors, [
    'UIManager: Button with id "slide-presentation-follow" not found.',
    'UIManager: Button with id "slide-presentation-follow-me" not found.',
  ], 'stock phone path reproduces the two diagnosed errors');
}

// -----------------------------------------------------------------------
// 2. Phone (classic, no notebookbar, no topToolbar): patched showFollow is
//    silent — no showButton calls, no errors — for both follow states.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ mode: 'classic', topToolbar: undefined });
  env.inject();
  const presenter = env.makePresenter();
  env.prototype.showFollow.call(presenter, true);
  env.prototype.showFollow.call(presenter, false);
  eq(env.calls.length, 0, 'phone: patched showFollow never toggles absent controls');
  eq(env.errors.length, 0, 'phone: no UIManager not-found errors remain');
}

// -----------------------------------------------------------------------
// 3. Phone WITH a classic topToolbar that lacks the ids: still silent.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ mode: 'classic', topToolbar: ['zoomin', 'zoomout'] });
  env.inject();
  env.prototype.showFollow.call(env.makePresenter(), true);
  eq(env.calls.length, 0, 'classic toolbar without the ids stays silent');
  eq(env.errors.length, 0, 'classic toolbar without the ids logs nothing');
}

// -----------------------------------------------------------------------
// 4. Notebookbar UIs (tablet/desktop): stock behaviour preserved exactly.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ mode: 'notebookbar', notebookbar: true });
  env.inject();
  const presenter = env.makePresenter();
  env.prototype.showFollow.call(presenter, true);
  eqSeq(env.calls, [
    ['slide-presentation-follow', false],
    ['slide-presentation-follow-me', true],
  ], 'notebookbar me=true keeps stock ids/flags/order');
  env.prototype.showFollow.call(presenter, false);
  eqSeq(env.calls.slice(2), [
    ['slide-presentation-follow', true],
    ['slide-presentation-follow-me', false],
  ], 'notebookbar me=false keeps stock ids/flags/order');
  eq(env.errors.length, 0, 'notebookbar path logs no errors (as stock)');
}

// -----------------------------------------------------------------------
// 5. Desktop classic whose topToolbar really carries the ids: preserved,
//    and per-button gating honours a partial toolbar.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({
    mode: 'classic',
    topToolbar: ['slide-presentation-follow', 'slide-presentation-follow-me'],
  });
  env.inject();
  env.prototype.showFollow.call(env.makePresenter(), true);
  eqSeq(env.calls, [
    ['slide-presentation-follow', false],
    ['slide-presentation-follow-me', true],
  ], 'classic toolbar carrying both ids keeps stock behaviour');

  const partial = makeSandbox({ mode: 'classic', topToolbar: ['slide-presentation-follow'] });
  partial.inject();
  partial.prototype.showFollow.call(partial.makePresenter(), false);
  eqSeq(partial.calls, [['slide-presentation-follow', true]],
    'per-button gating toggles only the id the UI actually provides');
  eq(partial.errors.length, 0, 'partial toolbar logs no errors');
}

// -----------------------------------------------------------------------
// 6. The overlay never suppresses GENERAL UIManager errors: showButton is
//    untouched, so a genuinely missing other button still logs.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ mode: 'classic', topToolbar: undefined });
  env.inject();
  env.prototype.showFollow.call(env.makePresenter(), true);
  env.sandbox.window.app.map.uiManager.showButton('some-other-missing-button', true);
  eqSeq(env.errors, ['UIManager: Button with id "some-other-missing-button" not found.'],
    'general missing-button error logging is fully preserved');
}

// -----------------------------------------------------------------------
// 7. Fail-closed guards: foreign bundle shape is a no-op; a throwing
//    lookup skips instead of guessing.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ bundleShape: false });
  env.inject(); // must not throw without window.SlideShow
  ok(true, 'foreign bundle shape is a silent no-op');

  const throwing = makeSandbox({ mode: 'classic', topToolbar: undefined, throwInGetCurrentMode: true });
  throwing.inject();
  let raised = null;
  try {
    throwing.prototype.showFollow.call(throwing.makePresenter(), true);
  } catch (error) { raised = error; }
  eq(raised, null, 'a throwing lookup never propagates out of showFollow');
  eq(throwing.calls.length, 0, 'a throwing lookup fails closed (no toggle)');
}

// -----------------------------------------------------------------------
// 8. Only showFollow is replaced; sibling prototype members are untouched.
// -----------------------------------------------------------------------
{
  const env = makeSandbox({ mode: 'classic', topToolbar: undefined });
  const before = {
    addHooks: env.prototype.addHooks,
    removeHooks: env.prototype.removeHooks,
  };
  env.inject();
  ok(env.prototype.showFollow !== stockShowFollow, 'showFollow is patched');
  eq(env.prototype.addHooks, before.addHooks, 'addHooks untouched');
  eq(env.prototype.removeHooks, before.removeHooks, 'removeHooks untouched');
}

console.log('PASS: ' + checks + ' presentation follow-controls checks');
