#!/usr/bin/env python3
"""Exercise the actual shipped fullscreen handoff wrapper; UI remains a separate gate.

The wrapper is deliberately no longer an edit-intent owner: the native host
drives the single readiness-gated edit entry. Five properties are load-bearing:

1. the wrapper NEVER calls `map._switchToEditMode()` itself, at any grant or
   timing — no early entry against a missing/half-initialised document layer
   (Calc) and no entry before the file-based presentation painted a tile;
2. the engine's own viewing-first mobile startup keeps working: the first
   `setPermission('edit')` still enters readonly through the unmodified
   upstream `setPermission`, so Permission.js's mobile startup is intact;
3. the in-page mobile edit button is hidden on a fullscreen editable mount so
   the page cannot own a second, racing edit intent;
4. the initial grant is recorded content-free for host diagnostics only;
5. installation is idempotent and works before/after DOMContentLoaded.
"""
import json
from pathlib import Path
import subprocess
import tempfile

HOST = Path(__file__).resolve().parent.parent / 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'


def check():
    host = HOST.read_text()
    source = host.split('// FLOE_FULLSCREEN_EDIT_SCRIPT_BEGIN', 1)[1].split('// FLOE_FULLSCREEN_EDIT_SCRIPT_END', 1)[0]
    script = source.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]
    # The wrapper source must contain no edit entry call: owning the switch is
    # the host's job.
    assert '_switchToEditMode' not in script and '_proceedEditMode' not in script, \
        'the handoff wrapper must never drive the edit entry itself'
    with tempfile.TemporaryDirectory(prefix='floe-fullscreen-edit-') as directory:
        test = Path(directory) / 'fullscreen.js'
        test.write_text('const source = ' + json.dumps(script) + ';\n' + HARNESS)
        subprocess.run(['node', str(test)], check=True, capture_output=True, text=True, timeout=30)
    return {'checksPassed': ['the page wrapper never drives the edit entry at any grant timing',
                             'the engine viewing-first mobile startup stays untouched',
                             'the in-page mobile edit button is hidden on fullscreen mounts',
                             'the initial grant is recorded content-free for diagnostics',
                             'deferred and repeated script installation is safe and idempotent'],
            'actualFullscreenUIRetestPassed': False}


HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');

// A fresh page context for one session. The host injects the session facts and
// the wrapper once, at document start, exactly as the replaced editor does.
function context(deferred, session = {}) {
    let hiddenCount = 0;
    function Map(mapOptions = {}) { this.options = mapOptions; this.entries = 0; }
    // The real upstream Permission.js behavior the wrapper must preserve:
    // on mobile the first edit grant enters the viewing-first readonly mode.
    Map.prototype.setPermission = function (permission, token) {
        const first = this._permission === undefined;
        this._permission = first && permission === 'edit' ? 'readonly' : permission;
        this.lastToken = token;
        return token;
    };
    Map.prototype._shouldStartReadOnly = function () { return true; };
    Map.prototype.getDocType = function () {
        if (this._docLayer && typeof this._docLayer._docType === 'string') return this._docLayer._docType;
        return null;
    };
    // If the wrapper ever (wrongly) drives an entry, this counter moves.
    Map.prototype._switchToEditMode = function () {
        this.entries++;
        this._permission = 'edit';
    };
    const editButton = {
        hidden: false,
        attrs: {},
        setAttribute(key, value) { this.attrs[key] = value; },
    };
    const listeners = [];
    const window = {
        ThisIsAMobileApp: session.mobile !== false,
        __floeOfficeSession: session.facts || {editable: true, readOnly: false, extension: 'pptx'},
        app: {file: {fileBasedView: session.fileBasedView === true, readOnly: session.backendReadOnly === true}},
    };
    if (!deferred) window.L = {Map};
    const sandbox = {window, document: {
        readyState: deferred ? 'loading' : 'complete',
        getElementById(id) { assert.equal(id, 'mobile-edit-button'); return editButton; },
        createElement() { return {textContent: ''}; },
        head: { appendChild() {} },
        addEventListener(name, listener, options) {
            assert.equal(name, 'DOMContentLoaded'); assert.equal(options.once, true); listeners.push(listener);
        }
    }};
    sandbox.setTimeout = (callback) => { sandbox.pending = callback; };
    vm.runInNewContext(source, sandbox);
    if (deferred) { window.L = {Map}; assert.equal(listeners.length, 1); listeners[0](); }
    sandbox.document.readyState = 'complete';
    vm.runInNewContext(source, sandbox);
    sandbox.Map = Map;
    return {sandbox, editButton, Map};
}

// Opens a fresh session and asks for the first edit grant, the exact sequence
// the pinned engine performs when the server reports `perm: edit`.
// A fresh map on a fresh session without applying any permission yet.
function open(deferred, session = {}, mapOptions = {}) {
    const contextState = context(deferred, session);
    const {sandbox} = contextState;
    const map = new contextState.Map(mapOptions);
    map.session = sandbox;
    if (session.docType) map._docLayer = {_docType: session.docType};
    return {sandbox, map, editButton: contextState.editButton};
}

function enter(deferred, session = {}, mapOptions = {}) {
    const state = open(deferred, session, mapOptions);
    state.map.setPermission('edit');
    return state;
}

for (const deferred of [false, true]) {
    // 1. The editable mount never enters edit from the page: the engine's
    //    viewing-first readonly startup is preserved and the button is hidden.
    const {sandbox, map, editButton} = enter(deferred);
    assert.equal(map.entries, 0, 'the page wrapper must not drive the edit entry');
    assert.equal(map._permission, 'readonly', 'the engine viewing-first startup must be preserved');
    assert.equal(editButton.hidden, true);
    assert.equal(editButton.attrs['aria-hidden'], 'true');
    // 2. The initial grant was recorded content-free for host diagnostics.
    const grant = sandbox.window.__floeInitialGrant;
    assert.ok(grant);
    assert.equal(grant.permission, 'edit');
    assert.equal(grant.hostEditable, true);
    assert.equal(typeof grant.at, 'number');
    // 3. Later grant changes also never enter from the page; the host owns the
    //    single entry, and readonly/view grants are never elevated.
    for (const grantName of ['readonly', 'view', 'comment', 'edit']) {
        const other = open(deferred);
        other.map.setPermission(grantName);
        assert.equal(other.map.entries, 0, grantName);
        // A fresh map's first edit grant is the viewing-first readonly start;
        // other grants apply verbatim.
        assert.equal(other.map._permission, grantName === 'edit' ? 'readonly' : grantName);
    }
    // 4. Presentation/Calc startup variants and read-only mounts behave the
    //    same: zero page-owned entries at any timing.
    for (const options of [
        {facts: {editable: false, readOnly: true, extension: 'pptx'}},
        {backendReadOnly: true, docType: 'presentation'},
        {fileBasedView: true, docType: 'presentation'},
        {fileBasedView: true, docType: null},
        {mobile: false},
    ]) {
        const variant = enter(deferred, options);
        assert.equal(variant.map.entries, 0, JSON.stringify(options));
    }
    // 5. Re-running the installer (reload/DOM ready churn) is idempotent: the
    //    wrapper still never enters and no duplicate state is created.
    const again = enter(deferred);
    vm.runInNewContext(source, again.sandbox);
    assert.equal(again.map.entries, 0);
}
'''


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
