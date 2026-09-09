#!/usr/bin/env python3
"""Exercise the shipped native URL helper and readonly script, not an imitation.

These checks do not replace native backend and real editor acceptance.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent / 'ThirdParty/Collabora'


def check():
    patch = (ROOT / 'patches/ios-embedding-boundaries.patch').read_text()
    added = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+'))
    helper = added.split('// FLOE_READONLY_HANDSHAKE_BEGIN', 1)[1].split('// FLOE_READONLY_HANDSHAKE_END', 1)[0]
    host = (ROOT / 'FloeOfficeNative/FloeOfficeNative.mm').read_text()
    script = host.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]
    with tempfile.TemporaryDirectory(prefix='floe-readonly-') as folder:
        root = Path(folder)
        program = root / 'permissions.mm'
        program.write_text('#import <Foundation/Foundation.h>\n#include <cassert>\n' + helper + URL_HARNESS)
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc',
                        '-Wall', '-Werror', '-framework', 'Foundation', str(program),
                        '-o', str(root / 'permissions')], check=True, capture_output=True, text=True)
        subprocess.run([str(root / 'permissions')], check=True, capture_output=True, timeout=20)
        js = root / 'readonly.js'
        js.write_text('const source = ' + json.dumps(script) + ';\n' + SCRIPT_HARNESS)
        subprocess.run(['node', str(js)], check=True, capture_output=True, text=True, timeout=20)
    return {'checksPassed': ['native URL preserves special file names and unrelated query values',
                            'readonly permission is unique; editable sessions clear stale permission',
                            'later permission messages cannot enable editing',
                            'all mobile edit entry points remain readonly',
                            'readonly selection and copy methods remain available',
                            'document-start installation waits for the editor prototype'],
            'nativeBackendEnforcementPassed': False, 'realEditorReadonlyPassed': False}


URL_HARNESS = r'''
int main() { @autoreleasepool {
    for (NSString *path in @[@"/private/work/普通文档.docx", @"/private/work/a b%?#&.xlsx"]) {
        NSURL *file = [NSURL fileURLWithPath:path];
        for (NSNumber *readOnly in @[@YES, @NO]) {
            NSURL *result = FloeDocumentHandshakeURL(file, readOnly.boolValue);
            assert([result.path isEqualToString:path]);
            NSURLComponents *parts = [NSURLComponents componentsWithURL:result resolvingAgainstBaseURL:NO];
            assert(parts.queryItems.count == (readOnly.boolValue ? 1 : 0));
            if (readOnly.boolValue) assert([parts.queryItems.firstObject.value isEqualToString:@"readonly"]);
        }
    }
    NSURL *stale = [NSURL URLWithString:@"file:///private/doc.pptx?permission=edit&x=a%26b&permission=readonly"];
    NSURLComponents *read = [NSURLComponents componentsWithURL:FloeDocumentHandshakeURL(stale, YES) resolvingAgainstBaseURL:NO];
    assert(read.queryItems.count == 2);
    assert([read.queryItems.firstObject.name isEqualToString:@"x"]);
    assert([read.queryItems.firstObject.value isEqualToString:@"a&b"]);
    assert([read.queryItems.lastObject.value isEqualToString:@"readonly"]);
    NSURLComponents *edit = [NSURLComponents componentsWithURL:FloeDocumentHandshakeURL(stale, NO) resolvingAgainstBaseURL:NO];
    assert(edit.queryItems.count == 1 && [edit.queryItems.firstObject.name isEqualToString:@"x"]);
} }
'''


SCRIPT_HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
for (const deferred of [false, true]) {
    const listeners = [];
    const styles = [];
    const button = { hidden: false, attributes: {}, setAttribute(k, v) { this.attributes[k] = v; } };
    function Map() { this.permission = 'readonly'; }
    const copy = function () { return 'selected text'; };
    const select = function () { return true; };
    Map.prototype = {
        setPermission(value) { this.permission = value; return value; },
        _enterReadOnlyMode(value) { this.permission = value; },
        _enterEditMode() { this.permission = 'edit'; },
        _switchToEditMode() { this.permission = 'edit'; },
        _proceedEditMode() { this.permission = 'edit'; },
        copy, select
    };
    const context = { window: deferred ? {} : { L: { Map } }, document: {
        readyState: deferred ? 'loading' : 'complete',
        head: { appendChild(style) { styles.push(style.textContent); } },
        getElementById(id) { assert.equal(id, 'mobile-edit-button'); return button; },
        createElement(tag) { assert.equal(tag, 'style'); return {}; },
        addEventListener(event, listener, options) {
            assert.equal(event, 'DOMContentLoaded'); assert.equal(options.once, true); listeners.push(listener);
        }
    }};
    vm.runInNewContext(source, context);
    if (deferred) { context.window.L = { Map }; assert.equal(listeners.length, 1); listeners[0](); }
    const map = new Map();
    for (const permission of ['edit', 'comment', 'readonly']) {
        map.setPermission(permission); assert.equal(map.permission, 'readonly');
        for (const entry of ['_enterEditMode', '_switchToEditMode', '_proceedEditMode']) {
            map[entry](); assert.equal(map.permission, 'readonly');
        }
    }
    assert.equal(map.copy, copy); assert.equal(map.copy(), 'selected text');
    assert.equal(map.select, select); assert.equal(map.select(), true);
    assert.equal(button.hidden, true); assert.equal(button.attributes['aria-hidden'], 'true');
    assert.equal(button.attributes.tabindex, '-1');
    assert.equal(styles.length, 1); assert.match(styles[0], /display: none !important/);
}
'''


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
