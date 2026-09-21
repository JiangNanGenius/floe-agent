#!/usr/bin/env python3
"""Exercise the actual shipped fullscreen permission wrapper; UI remains a separate gate.

The wrapper decides whether the host's editable mount follows the engine's own
guarded mobile edit entry. Three properties are load-bearing:

1. a genuine edit grant enters edit mode exactly once, including the mobile
   file-based (endless slide scrolling) startup that Impress/Draw always use on
   a phone or tablet — that startup is a UI mode, not a denied document;
2. readonly/view grants, protected files and PDFs are never elevated;
3. the document type is never guessed: an unknown type defers, bounded.
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
    with tempfile.TemporaryDirectory(prefix='floe-fullscreen-edit-') as directory:
        test = Path(directory) / 'fullscreen.js'
        test.write_text('const source = ' + json.dumps(script) + ';\n' + HARNESS)
        subprocess.run(['node', str(test)], check=True, capture_output=True, text=True, timeout=30)
    return {'checksPassed': ['initial native edit grant uses the normal mobile entry once',
                             'mobile Impress/Draw file-based startup still enters the guarded edit layout',
                             'readonly, view and protected grants cannot be elevated',
                             'PDF and view-mode file-based documents stay unchanged',
                             'unknown document type defers until the engine reports it',
                             'later permission changes remain authoritative',
                             'normal entry retains edit-password challenge',
                             'deferred and repeated script installation is safe'],
            'actualFullscreenUIRetestPassed': False}


HARNESS = r'''const assert = require('node:assert/strict');
const vm = require('node:vm');

// A fresh page context for one session. The host injects the session facts and
// the wrapper once, at document start, exactly as the replaced editor does.
function context(deferred, session = {}) {
    function Map(mapOptions = {}) { this.options = mapOptions; this.entries = 0; this.challenge = 0; }
    Map.prototype.setPermission = function (permission, token) {
        const first = this._permission === undefined;
        // The pinned mobile editor starts every editable document in its
        // viewing-first UI mode.
        this._permission = first && permission === 'edit' ? 'readonly' : permission;
        this.lastToken = token;
        return token;
    };
    Map.prototype._shouldStartReadOnly = function () { return !!this.options.viewingFirst; };
    Map.prototype.getDocType = function () {
        if (this._docLayer && typeof this._docLayer._docType === 'string') return this._docLayer._docType;
        return null;
    };
    Map.prototype._switchToEditMode = function () {
        this.entries++;
        // The engine keeps its own format/password/lock checks: a challenged
        // document stays readonly until the password arrives.
        if (this.options.password) { this.challenge++; return; }
        this._permission = 'edit';
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
    return sandbox;
}

// A fresh map on a fresh session, without applying any permission yet.
function open(deferred, session = {}, mapOptions = {}) {
    const sandbox = context(deferred, session);
    const map = new sandbox.Map(mapOptions);
    map.session = sandbox;
    if (session.docType) map._docLayer = {_docType: session.docType};
    return map;
}

// Opens a fresh editable session and asks for the first edit grant, the exact
// sequence the pinned engine performs when the server reports `perm: edit`.
function enter(deferred, session = {}, mapOptions = {}) {
    const map = open(deferred, session, mapOptions);
    map.setPermission('edit');
    return {sandbox: map.session, map};
}

for (const deferred of [false, true]) {
    const {map} = enter(deferred);
    assert.equal(map.entries, 1); assert.equal(map._permission, 'edit');
    // Later permission changes stay authoritative and never double-enter.
    map.setPermission('readonly'); assert.equal(map._permission, 'readonly'); assert.equal(map.entries, 1);
    map.setPermission('edit'); assert.equal(map.entries, 1);
    for (const grant of ['readonly', 'view', 'comment']) {
        const locked = open(deferred);
        locked.setPermission(grant);
        assert.equal(locked.entries, 0);
        assert.equal(locked._permission, grant);
    }
    // A session the host mounted read-only never carries the editable fact.
    const hostPreview = enter(deferred, {facts: {editable: false, readOnly: true, extension: 'pptx'}});
    assert.equal(hostPreview.map.entries, 0);
    // The engine's backing permission is the only editing authority.
    const engineDenied = enter(deferred, {backendReadOnly: true, docType: 'presentation'});
    assert.equal(engineDenied.map.entries, 0);
    assert.equal(engineDenied.map._permission, 'readonly');
    // The viewing-first startup (`_shouldStartReadOnly`) is a UI mode, not a
    // denied document: the engine's own guarded entry still applies.
    const viewingFirst = enter(deferred, {docType: 'presentation'}, {viewingFirst: true});
    assert.equal(viewingFirst.map.entries, 1);
    assert.equal(viewingFirst.map._permission, 'edit');
    // The engine keeps its edit-password challenge.
    const password = enter(deferred, {docType: 'presentation'}, {password: true});
    assert.equal(password.map.challenge, 1);
    assert.equal(password.map._permission, 'readonly');
    // A non-native context is never touched.
    const external = enter(deferred, {mobile: false});
    assert.equal(external.map.entries, 0);
    // View-only file-based documents (PDF) keep the engine's own behaviour.
    const pdf = enter(deferred, {fileBasedView: true, docType: null});
    assert.equal(pdf.map.entries, 0);
    // Mobile Impress/Draw always start file-based; the guarded entry must run
    // and the engine's own updatepermission switches to the edit layout.
    for (const docType of ['presentation', 'drawing']) {
        const impress = enter(deferred, {fileBasedView: true, docType: docType});
        assert.equal(impress.map.entries, 1, docType);
        assert.equal(impress.map._permission, 'edit', docType);
    }
    // Unknown type: defer through the bounded retry instead of guessing.
    const unknown = enter(deferred, {fileBasedView: true, docType: null});
    assert.equal(unknown.map.entries, 0);
    assert.equal(typeof unknown.sandbox.pending, 'function');
    unknown.map._docLayer = {_docType: 'presentation'};
    const pending = unknown.sandbox.pending;
    unknown.sandbox.pending = undefined;
    pending();
    assert.equal(unknown.map.entries, 1);
    // A type that never arrives is left alone, and the retry stays bounded.
    const stuck = enter(deferred, {fileBasedView: true, docType: null});
    let iterations = 0;
    while (typeof stuck.sandbox.pending === 'function' && iterations < 200) {
        const next = stuck.sandbox.pending;
        stuck.sandbox.pending = undefined;
        next();
        iterations++;
    }
    assert.equal(stuck.map.entries, 0);
    assert.ok(iterations <= 101, 'retry must stay bounded, saw ' + iterations);
}
'''


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
