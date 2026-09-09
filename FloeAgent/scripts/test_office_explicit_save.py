#!/usr/bin/env python3
"""Exercise the shipped save bridge; native UI and original-file CAS stay separate gates."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent.parent / 'FloeApp/Workspace/OfficeExplicitSaveBridge.swift'


class ExplicitSaveTests(unittest.TestCase):
    def test_actual_bridge_routes_explicit_requests_and_waits_for_original_commit(self):
        source = SOURCE.read_text().split('// FLOE_EXPLICIT_SAVE_SCRIPT_BEGIN', 1)[1]
        script = source.split('#"""', 1)[1].split('"""#', 1)[0]
        with tempfile.TemporaryDirectory(prefix='floe-explicit-save-') as folder:
            path = Path(folder) / 'check.js'
            path.write_text('const source = ' + json.dumps(script) + ';\n' + HARNESS)
            result = subprocess.run(['node', str(path)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
for (const deferred of [false, true]) {
    const calls = [], forwarded = [], listeners = [];
    let failTransport = false;
    function Map() {
        this.readonly = false;
        this.saveState = {
            saved: 0, failed: 0, modified: 0,
            showSavedStatus() { this.saved++; },
            showSaveFailedStatus() { this.failed++; },
            showModifiedStatus() { this.modified++; }
        };
    }
    Map.prototype.fire = function (...args) { forwarded.push(args); return this; };
    Map.prototype.isReadOnlyMode = function () { return this.readonly; };
    const window = { app: {file: {modified: false}}, webkit: {messageHandlers: {floeCommitDocument: {
        postMessage(value) { if (failTransport) throw Error('transport gone'); calls.push(value); }
    }}}};
    if (!deferred) window.L = {Map};
    const context = {window, document: {
        readyState: deferred ? 'loading' : 'complete',
        addEventListener(event, listener, options) {
            assert.equal(event, 'DOMContentLoaded'); assert.equal(options.once, true); listeners.push(listener);
        }
    }};
    vm.runInNewContext(source, context);
    if (deferred) { window.L = {Map}; assert.equal(listeners.length, 1); listeners[0](); }
    context.document.readyState = 'complete';
    vm.runInNewContext(source, context); // Never double-wrap or reset a pending request.
    const map = new Map();
    const originalSaved = map.saveState.showSavedStatus;
    // Autosave results and unrelated events do not request original writeback.
    map.fire('commandresult', {commandName: '.uno:Save', success: true});
    map.fire('postMessage', {msgId: 'Doc_ModifiedStatus'});
    assert.equal(calls.length, 0); assert.equal(forwarded.length, 2);
    for (const source of ['toolbar', 'notebookbar', 'filemenu', 'keyboard']) {
        const before = calls.length;
        assert.equal(map.fire('postMessage', {msgId: 'UI_Save', args: {source}}), map);
        assert.equal(map._disableDefaultAction.UI_Save, true);
        assert.equal(calls.length, before + 1);
        assert.equal(calls.at(-1), 'save');
        map.fire('postMessage', {msgId: 'UI_Save'}); // Coalesce rapid repeated taps.
        assert.equal(calls.length, before + 1);
        const saved = map.saveState.saved;
        map.saveState.showSavedStatus(); // Engine persisted only its private copy.
        assert.equal(map.saveState.saved, saved);
        window.floeCompleteOriginalSave(true);
        assert.equal(map.saveState.saved, saved + 1);
        assert.equal(map.saveState.showSavedStatus, originalSaved);
        window.floeCompleteOriginalSave(true); // Late duplicate acknowledgement is inert.
        assert.equal(map.saveState.saved, saved + 1);
    }
    const beforeFailure = map.saveState.saved;
    map.fire('postMessage', {msgId: 'UI_Save'});
    window.floeCompleteOriginalSave(false); // CAS conflict or damaged export.
    assert.equal(map.saveState.saved, beforeFailure); assert.equal(map.saveState.failed, 1);
    assert.equal(map.saveState.showSavedStatus, originalSaved);
    map.fire('postMessage', {msgId: 'UI_Save'});
    window.app.file.modified = true; // New edit between commit and its UI acknowledgement.
    window.floeCompleteOriginalSave(true);
    assert.equal(map.saveState.saved, beforeFailure);
    assert.equal(map.saveState.modified, 1);
    window.app.file.modified = false;
    const count = calls.length;
    map.readonly = true;
    map.fire('postMessage', {msgId: 'UI_Save'});
    assert.equal(calls.length, count);
    map.readonly = false;
    failTransport = true;
    map.fire('postMessage', {msgId: 'UI_Save'});
    assert.equal(calls.length, count); assert.equal(map.saveState.failed, 2);
    failTransport = false;
    map.fire('postMessage', {msgId: 'UI_Save'}); // User may explicitly retry after a failure.
    assert.equal(calls.length, count + 1);
    window.floeCompleteOriginalSave(false);
    assert.equal(map.saveState.failed, 3);
    assert.equal(forwarded.length, 2); // No default Save or unrelated WOPI notification leaks.
}
'''

if __name__ == '__main__':
    unittest.main()
