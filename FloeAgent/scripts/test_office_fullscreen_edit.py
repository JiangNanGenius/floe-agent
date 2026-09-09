#!/usr/bin/env python3
"""Exercise the actual shipped fullscreen permission wrapper; UI remains a separate gate."""
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
        subprocess.run(['node', str(test)], check=True, capture_output=True, text=True, timeout=20)
    return {'checksPassed': ['initial native edit grant uses the normal mobile entry once',
                             'readonly and view grants cannot be elevated',
                             'later permission changes remain authoritative',
                             'protected format, PDF view and non-native context stay unchanged',
                             'normal entry retains edit-password challenge',
                             'deferred and repeated script installation is safe'],
            'actualFullscreenUIRetestPassed': False}


HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
for (const deferred of [false, true]) {
    function Map(options = {}) { this.options = options; this.entries = 0; this.challenge = 0; }
    Map.prototype.setPermission = function (permission, token) {
        const first = this._permission === undefined;
        this._permission = first && permission === 'edit' ? 'readonly' : permission;
        this.lastToken = token;
        return token;
    };
    Map.prototype._shouldStartReadOnly = function () { return !!this.options.protected; };
    Map.prototype._switchToEditMode = function () {
        this.entries++;
        if (this.options.password) this.challenge++;
        else this._permission = 'edit';
    };
    const listeners = [];
    const window = {ThisIsAMobileApp: true, app: {file: {fileBasedView: false}}};
    if (!deferred) window.L = {Map};
    const context = {window, document: {
        readyState: deferred ? 'loading' : 'complete',
        addEventListener(name, listener, options) {
            assert.equal(name, 'DOMContentLoaded'); assert.equal(options.once, true); listeners.push(listener);
        }
    }};
    vm.runInNewContext(source, context);
    if (deferred) { window.L = {Map}; assert.equal(listeners.length, 1); listeners[0](); }
    context.document.readyState = 'complete';
    vm.runInNewContext(source, context);
    const editor = new Map();
    assert.equal(editor.setPermission('edit', 42), 42);
    assert.equal(editor.lastToken, 42); assert.equal(editor.entries, 1); assert.equal(editor._permission, 'edit');
    editor.setPermission('readonly'); assert.equal(editor._permission, 'readonly'); assert.equal(editor.entries, 1);
    editor.setPermission('edit'); assert.equal(editor.entries, 1);
    for (const grant of ['readonly', 'view', 'comment']) {
        const locked = new Map(); locked.setPermission(grant); assert.equal(locked.entries, 0);
        assert.equal(locked._permission, grant);
    }
    const protectedFile = new Map({protected: true}); protectedFile.setPermission('edit');
    assert.equal(protectedFile.entries, 0); assert.equal(protectedFile._permission, 'readonly');
    const password = new Map({password: true}); password.setPermission('edit');
    assert.equal(password.challenge, 1); assert.equal(password._permission, 'readonly');
    window.app.file.fileBasedView = true;
    const pdf = new Map(); pdf.setPermission('edit'); assert.equal(pdf.entries, 0);
    window.app.file.fileBasedView = false; window.ThisIsAMobileApp = false;
    const external = new Map(); external.setPermission('edit'); assert.equal(external.entries, 0);
}
'''


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
