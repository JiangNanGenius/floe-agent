#!/usr/bin/env python3
"""Fixture for the pinned editor's real permission semantics.

The mobile editor forces startreadonly=true for its viewing-first startup, so
_shouldStartReadOnly() describes the initial UI mode and must not be used as a
denial check. app.file.readOnly is the backing permission (handshake
`permission` query, WOPI props, real edit grants) and map._permission is the UI
mode. This fixture extracts the actually shipped scripts from
FloeOfficeNative.mm and runs them on that documented model:

1. an editable document whose UI starts readonly (mobile startreadonly) follows
   the normal guarded edit entry exactly once;
2. a readonly/view grant is never elevated;
3. an editable document that first reports permission=readonly follows the
   host's guarded entry once;
4. a document that needs the edit password stays readonly and reports
   pendingPassword instead of claiming edit;
5. a readonly-mounted FloeReadOnlyScript session blocks every edit entry;
6. the permission observer reports the backing permission on changes.

Run: python3 run_readonly_permission_fixture.py [path/to/FloeOfficeNative.mm]
This is a script-level fixture; it does not replace real editor/device checks.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

DEFAULT_HOST = pathlib.Path(__file__).resolve().parents[2] / "ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm"

JS_HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');

function makeDocument() {
    const button = { hidden: false, attributes: {}, setAttribute(k, v) { this.attributes[k] = v; } };
    return {
        readyState: 'complete',
        head: { appendChild() {} },
        createElement() { return {}; },
        getElementById() { return button; },
        addEventListener() {},
        button,
    };
}

function makeEngine(options = {}) {
    function Map() {}
    Map.prototype.setPermission = function (permission) {
        const first = this._permission === undefined;
        this._permission = first && permission === 'edit' && this._shouldStartReadOnly()
            ? 'readonly' : permission;
        return permission;
    };
    Map.prototype._shouldStartReadOnly = function () { return options.startReadOnly === true; };
    Map.prototype.isEditMode = function () { return this._permission === 'edit'; };
    Map.prototype._enterReadOnlyMode = function (permission) { this._permission = permission; };
    Map.prototype._enterEditMode = function () { this._permission = 'edit'; };
    Map.prototype._switchToEditMode = function () {
        this.entries = (this.entries || 0) + 1;
        if (options.password) return;              // the engine shows its password prompt
        if (options.engineRefuses) return;         // protected format/backend refusal
        this._permission = 'edit';
    };
    Map.prototype._proceedEditMode = function () { this._switchToEditMode(); };
    const map = new Map();
    if (options.initialUiReadOnly !== false) map._permission = 'readonly';
    map._docHasPasswordToModify = !!options.password;
    map._modifyPasswordProvided = false;
    const app = {
        file: { permission: options.backendReadOnly ? 'readonly' : 'edit',
                readOnly: !!options.backendReadOnly, fileBasedView: false },
        setPermission(permission) {
            app.file.permission = permission;
            app.file.readOnly = permission !== 'edit';
        },
    };
    app.map = map;
    const handlers = { floePermission: { messages: [], postMessage(message) { this.messages.push(message); } } };
    const document = makeDocument();
    const window = { ThisIsAMobileApp: true, app, L: { Map }, webkit: { messageHandlers: handlers }, document };
    return { Map, map, app, document, window, handlers };
}

function install(script, env) {
    vm.runInNewContext(script, { window: env.window, document: env.document });
}

function call(script, env) {
    // The shipped snippets are already invoked IIFEs; evaluate them directly.
    return vm.runInNewContext(script, { window: env.window, document: env.document });
}

// 1. Editable document, mobile viewing-first UI.
{
    const env = makeEngine({ startReadOnly: true, backendReadOnly: false });
    install(FULLSCREEN, env);
    const map = new env.Map();
    map.setPermission('edit');                     // the editor's first grant
    assert.equal(map.entries, 1, 'editable + startreadonly must follow the guarded entry once');
    assert.equal(map.isEditMode(), true, 'editable session ends in edit mode');
}

// 2. readonly grant must never be elevated.
{
    const env = makeEngine({ startReadOnly: true, backendReadOnly: true });
    install(FULLSCREEN, env);
    const map = new env.Map();
    map.setPermission('readonly');
    assert.equal(map.entries || 0, 0, 'readonly grant stays readonly');
    assert.equal(env.app.file.readOnly, true, 'backing permission stays readonly');
}

// 3. Editable backend that first reports permission=readonly uses the host entry.
{
    const env = makeEngine({ startReadOnly: true, backendReadOnly: false });
    const probe = call(PROBE, env);
    assert.equal(probe.backendReadOnly, false, 'probe reads the editable backing permission');
    assert.equal(probe.uiEdit, false, 'probe reports the current viewing UI');
    const result = call(ENTRY, env);
    assert.equal(result.ok, true, 'host entry runs');
    assert.equal(env.map.entries, 1, 'normal guarded entry used once');
    assert.equal(result.uiEdit, true, 'engine UI reports edit after the entry');
    assert.equal(result.backendReadOnly, false, 'backing permission remains editable');
}

// 4. Edit-password document stays readonly and reports pendingPassword.
{
    const env = makeEngine({ startReadOnly: true, backendReadOnly: false, password: true });
    const result = call(ENTRY, env);
    assert.equal(env.map.entries, 1, 'engine is asked for the password through its own entry');
    assert.equal(result.pendingPassword, true, 'pendingPassword is reported');
    assert.equal(result.uiEdit, false, 'UI is not claimed editable before the password');
    assert.equal(result.backendReadOnly, false, 'the document itself is not denied');
}

// 5. readonly-mounted FloeReadOnlyScript session blocks every entry.
{
    const env = makeEngine({ startReadOnly: true, backendReadOnly: true });
    install(READONLY, env);
    const map = new env.Map();
    map.setPermission('edit');
    for (const entry of ['_enterEditMode', '_switchToEditMode', '_proceedEditMode']) map[entry]();
    assert.equal(map.isEditMode(), false, 'readonly-mounted session cannot enter edit');
    assert.equal(env.document.button.hidden, true, 'edit entry stays hidden');
}

// 6. Permission observer reports the backing permission changes.
{
    const env = makeEngine({ startReadOnly: true, backendReadOnly: false });
    install(OBSERVER, env);
    const messages = env.handlers.floePermission.messages;
    env.app.setPermission('readonly');
    assert.equal(messages[messages.length - 1].readOnly, true, 'readonly grant reported');
    env.app.setPermission('edit');
    assert.equal(messages[messages.length - 1].readOnly, false, 'edit grant reported');
}

console.log(JSON.stringify({ checks: [
    'editable + mobile startreadonly follows the guarded entry once',
    'readonly grant is never elevated',
    'editable backend first reporting readonly follows the guarded entry once',
    'edit-password document reports pendingPassword and stays readonly',
    'readonly-mounted script session blocks every edit entry',
    'permission observer reports backing permission changes',
] }));
'''


def _block(source: str, begin: str, end: str) -> str:
    block = source.split(begin, 1)[1].split(end, 1)[0]
    return block.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]


def _function_script(engine_block: str, function_name: str) -> str:
    after = engine_block.split(function_name, 1)[1]
    return after.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]


def main() -> int:
    host = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_HOST
    source = host.read_text()
    scripts = {
        "FULLSCREEN": _block(source, "FLOE_FULLSCREEN_EDIT_SCRIPT_BEGIN", "FLOE_FULLSCREEN_EDIT_SCRIPT_END"),
        "READONLY": _block(source, "FLOE_READONLY_SCRIPT_BEGIN", "FLOE_READONLY_SCRIPT_END"),
    }
    engine_block = source.split("FLOE_ENGINE_PERMISSION_BEGIN", 1)[1].split("FLOE_ENGINE_PERMISSION_END", 1)[0]
    scripts["PROBE"] = _function_script(engine_block, "FloeEnginePermissionProbeScript()")
    scripts["ENTRY"] = _function_script(engine_block, "FloeEngineEditEntryScript()")
    scripts["OBSERVER"] = _function_script(engine_block, "FloeEnginePermissionObserverScript()")
    with tempfile.TemporaryDirectory(prefix="floe-permission-fixture-") as folder:
        program = pathlib.Path(folder) / "fixture.js"
        program.write_text(
            "".join("const %s = %s;\n" % (name, json.dumps(script)) for name, script in scripts.items())
            + JS_HARNESS
        )
        subprocess.run(["node", str(program)], check=True, text=True, timeout=30)
    print("Script-level fixture only; real editor/device permission checks remain separate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
