#!/usr/bin/env python3
"""Fixture for the App-owned embedded Office chrome controls.

The pinned engine's own page chrome conflicts with Floe's hosting model: the
engine's close button bypasses Floe's save/commit tab-close owner, and its
floating mobile edit entry duplicates the App's host-level Edit action. This
fixture extracts the actually shipped `embeddedControlsScript` and the
readonly lock script from their source files and runs them on a documented DOM
model:

1. the injected style hides the engine's close chrome and floating edit entry;
2. `L.Params.closeButtonEnabled` is disabled so the close button never renders;
3. modification tracking installs and latches `.uno:ModifiedStatus`;
4. the font-name combobox keeps the engine's anchored dropdown while every
   other combobox keeps upstream behavior;
5. the install is idempotent (a second evaluation changes nothing);
6. the readonly lock script keeps hiding the edit entry and refuses edit.

Run: python3 run_office_embedded_controls_fixture.py
This is a script-level fixture; it does not replace real editor/device checks.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "FloeApp/Workspace/OfficeExplicitSaveBridge.swift"
HOST = ROOT / "ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm"

JS_HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');

function makeDom() {
    const styles = [];
    const button = { hidden: false, attributes: {}, setAttribute(k, v) { this.attributes[k] = v; } };
    const listeners = {};
    const document = {
        readyState: 'complete',
        styles,
        button,
        head: { appendChild(node) { styles.push(node); } },
        createElement(tag) { return { tag, textContent: '' }; },
        getElementById(id) { return id === 'mobile-edit-button' ? button : null; },
        addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    };
    return { document, styles, button, listeners };
}

function makeEngine() {
    const { document, styles, button } = makeDom();
    const calls = { combobox: 0, original: 0, stateChanged: 0 };
    const builderProto = {
        _comboboxControl(parent, data) { calls.original++; return 'original:' + data.id; },
        onCommandStateChanged(event) { calls.stateChanged++; },
    };
    const window = {
        L: {
            Params: { closeButtonEnabled: true },
            Control: { NotebookbarBuilder: { prototype: builderProto } },
        },
        JSDialog: { combobox(parent, data) { calls.combobox++; return 'engine:' + data.id; } },
    };
    return { window, document, styles, button, calls, builderProto };
}

function install(script, env) {
    vm.runInNewContext(script, { window: env.window, document: env.document });
}

// 1 + 2. Close chrome and floating edit entry are hidden; close never renders.
{
    const env = makeEngine();
    install(EMBEDDED, env);
    const css = env.styles.map((s) => s.textContent).join('\n');
    for (const selector of ['#closebuttonwrapper', '#closebuttonwrapperseparator', '#closebutton',
                            '#mobile-edit-button', '#mobile-edit-buttonwrapper', '.mobile-edit-button']) {
        assert.ok(css.includes(selector), 'style hides ' + selector);
    }
    assert.equal(env.window.L.Params.closeButtonEnabled, false, 'engine close button disabled');
}

// 3. Modification tracking latches .uno:ModifiedStatus; unknown events pass through.
{
    const env = makeEngine();
    install(EMBEDDED, env);
    assert.equal(env.window.floeModificationTrackingInstalled, true, 'tracking installed');
    assert.equal(env.window.floeModifiedSinceCommit, false, 'starts clean');
    env.builderProto.onCommandStateChanged({ commandName: '.uno:ModifiedStatus', state: true });
    assert.equal(env.window.floeModifiedSinceCommit, true, 'modified status latched');
    assert.equal(env.calls.stateChanged, 1, 'original handler still runs');
    env.builderProto.onCommandStateChanged({ commandName: '.uno:Other', state: true });
    assert.equal(env.calls.stateChanged, 2, 'unrelated events pass through');
}

// 4. Only the font-name combobox is rerouted to the engine dropdown.
{
    const env = makeEngine();
    install(EMBEDDED, env);
    const font = env.builderProto._comboboxControl(null, { id: 'fontnamecombobox' }, null);
    assert.equal(font, 'engine:fontnamecombobox', 'font combo uses the anchored engine dropdown');
    const other = env.builderProto._comboboxControl(null, { id: 'fontsizecombobox' }, null);
    assert.equal(other, 'original:fontsizecombobox', 'other combos keep upstream behavior');
    assert.equal(env.calls.combobox, 1);
    assert.equal(env.calls.original, 1);
}

// 5. Installation is idempotent.
{
    const env = makeEngine();
    install(EMBEDDED, env);
    const first = env.window.L.Control.NotebookbarBuilder.prototype._comboboxControl;
    install(EMBEDDED, env);
    const second = env.window.L.Control.NotebookbarBuilder.prototype._comboboxControl;
    assert.equal(first, second, 're-installation does not re-wrap controls');
    assert.equal(env.styles.length, 1, 'style injected once');
}

// 6. The readonly lock script hides the edit entry and refuses every edit path.
{
    const env = makeEngine();
    env.window.L.Map = function () {};
    const proto = env.window.L.Map.prototype;
    proto.setPermission = function (permission) { this._permission = permission; };
    proto._enterReadOnlyMode = function (permission) { this._permission = permission; };
    install(READONLY, env);
    const map = new env.window.L.Map();
    map.setPermission('edit');
    assert.equal(map._permission, 'readonly', 'readonly mount never elevates');
    assert.equal(map._switchToEditMode(), false, 'guarded entry refused');
    assert.equal(env.button.hidden, true, 'edit entry hidden');
    const css = env.styles.map((s) => s.textContent).join('\n');
    assert.ok(css.includes('#mobile-edit-button'), 'readonly style hides the edit entry');
}

console.log(JSON.stringify({ checks: [
    'engine close chrome and floating edit entry hidden',
    'closeButtonEnabled disabled',
    'modification tracking latches .uno:ModifiedStatus',
    'only the font-name combobox is rerouted',
    'embedded controls install is idempotent',
    'readonly lock refuses every edit path',
] }));
'''


def _bridge_block(source: str, begin: str, end: str) -> str:
    block = source.split(begin, 1)[1].split(end, 1)[0]
    return block.split('#"""', 1)[1].split('"""#', 1)[0]


def _host_block(source: str, begin: str, end: str) -> str:
    block = source.split(begin, 1)[1].split(end, 1)[0]
    return block.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]


def main() -> int:
    embedded = _bridge_block(
        BRIDGE.read_text(),
        "FLOE_EMBEDDED_CONTROLS_SCRIPT_BEGIN",
        "FLOE_EMBEDDED_CONTROLS_SCRIPT_END",
    )
    readonly = _host_block(
        HOST.read_text(),
        "FLOE_READONLY_SCRIPT_BEGIN",
        "FLOE_READONLY_SCRIPT_END",
    )
    with tempfile.TemporaryDirectory(prefix="floe-embedded-controls-") as folder:
        program = pathlib.Path(folder) / "fixture.js"
        program.write_text(
            "const EMBEDDED = %s;\nconst READONLY = %s;\n" % (json.dumps(embedded), json.dumps(readonly))
            + JS_HARNESS
        )
        subprocess.run(["node", str(program)], check=True, text=True, timeout=30)
    print("Script-level fixture only; real editor/device chrome checks remain separate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
