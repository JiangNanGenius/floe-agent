#!/usr/bin/env python3
"""Exercise the app adapter; this does not qualify the native Office UI."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent.parent / 'FloeApp/Workspace/OfficeExplicitSaveBridge.swift'


class EmbeddedControlsTests(unittest.TestCase):
    def test_font_dropdown_and_host_owned_close(self):
        source = SOURCE.read_text().split('// FLOE_EMBEDDED_CONTROLS_SCRIPT_BEGIN', 1)[1]
        script = source.split('#"""', 1)[1].split('"""#', 1)[0]
        with tempfile.TemporaryDirectory(prefix='floe-office-controls-') as folder:
            path = Path(folder) / 'check.js'
            path.write_text('const source = ' + json.dumps(script) + ';\n' + HARNESS)
            result = subprocess.run(['node', str(path)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_modified_status_probe_reports_only_known_values(self):
        source = SOURCE.read_text().split('// FLOE_MODIFIED_STATUS_PROBE_BEGIN', 1)[1]
        script = source.split('#"""', 1)[1].split('"""#', 1)[0]
        with tempfile.TemporaryDirectory(prefix='floe-office-modified-') as folder:
            path = Path(folder) / 'check.js'
            path.write_text('const source = ' + json.dumps(script) + ';\n' + MODIFIED_HARNESS)
            result = subprocess.run(['node', str(path)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
for (const deferred of [false, true]) {
    const styles = [], events = [], controls = [], dropdowns = [];
    const selected = {onSetText(value) { this.value = value; }};
    function Builder() {}
    Builder.prototype._comboboxControl = function (...args) { controls.push(args); return 7; };
    Builder.prototype.onCommandStateChanged = function (event) { events.push(event); return 9; };
    const listeners = [];
    const window = {L: {Params: {closeButtonEnabled: true}, Control: {NotebookbarBuilder: Builder}},
        JSDialog: {combobox(...args) { dropdowns.push(args); return 3; }}};
    const document = {readyState: deferred ? 'loading' : 'complete',
        head: {appendChild(style) { styles.push(style); }},
        createElement(tag) { assert.equal(tag, 'style'); return {}; },
        getElementById(id) { assert.equal(id, 'fontnamecombobox'); return selected; },
        addEventListener(event, fn, options) {
            assert.equal(event, 'DOMContentLoaded'); assert.equal(options.once, true); listeners.push(fn);
        }};
    const context = {window, document};
    vm.runInNewContext(source, context);
    if (deferred) { assert.equal(styles.length, 0); listeners[0](); }
    document.readyState = 'complete';
    vm.runInNewContext(source, context);
    assert.equal(styles.length, 1); // Never stack wrappers on tab rebuild.
    assert.equal(window.L.Params.closeButtonEnabled, false);
    assert.match(styles[0].textContent, /#closebuttonwrapper.*display: none !important/);
    const builder = new Builder();
    const font = {id: 'fontnamecombobox', entries: ['A', 'B'], selectedEntries: ['1']};
    assert.equal(builder._comboboxControl('parent', font, builder), 3);
    assert.equal(dropdowns.length, 1); assert.equal(dropdowns[0][1], font);
    assert.equal(dropdowns[0][2], builder); // Keep engine selection callbacks/permissions.
    assert.equal(controls.length, 0); // No native font picker call.
    assert.equal(builder._comboboxControl('parent', {id: 'fontsize'}, builder), 7);
    assert.equal(controls.length, 1);
    assert.equal(builder.onCommandStateChanged({commandName: '.uno:CharFontName', state: 'B'}), 9);
    assert.equal(selected.value, 'B');
    builder.onCommandStateChanged({commandName: '.uno:ModifiedStatus', state: 'true'});
    assert.equal(events.length, 2); // Save state/other toolbar behavior preserved.
    assert.equal(window.floeModifiedSinceCommit, true);
    builder.onCommandStateChanged({commandName: '.uno:ModifiedStatus', state: 'false'});
    assert.equal(window.floeModifiedSinceCommit, true); // Autosave is not an original-file commit.
    assert.equal(window.floeModificationTrackingInstalled, true);
}
'''

MODIFIED_HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');

function run(handler, modifiedSinceCommit = false) {
    const map = handler === undefined ? {} : {stateChangeHandler: handler};
    return vm.runInNewContext(source, {window: {app: {map}, floeModifiedSinceCommit: modifiedSinceCommit}});
}

// Known clean/modified string and boolean states are authoritative.
assert.equal(run({getItemValue: () => 'true'}), true);
assert.equal(run({getItemValue: () => true}), true);
assert.equal(run({getItemValue: () => 'false'}), false);
assert.equal(run({getItemValue: () => false}), false);
assert.equal(run({getItemValue: () => false}, true), true); // Pending or landed autosave.
assert.equal(run({getItemValue: () => false}, null), null); // No edit tracking installed.
// Unknown, unavailable or throwing accessors never claim a clean document.
assert.equal(run({getItemValue: () => undefined}), null);
assert.equal(run({getItemValue: () => ''}), null);
assert.equal(run({getItemValue: () => 'garbage'}), null);
assert.equal(run({}), null);
assert.equal(run(undefined), null);
assert.equal(vm.runInNewContext(source, {window: {}}), null);
assert.equal(vm.runInNewContext(source,
    {window: {app: {map: {stateChangeHandler: {getItemValue: () => { throw new Error('boom'); }}}}}}), null);
// A clean latch still requires a known clean value from the pinned engine.
let queried = null;
assert.equal(run({getItemValue: (command) => { queried = command; return 'false'; }}), false);
assert.equal(queried, '.uno:ModifiedStatus');
'''

if __name__ == '__main__':
    unittest.main()
