#!/usr/bin/env python3
"""Run the shipped native drain script; optionally compare pinned ProxySocket."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HOST = Path(__file__).resolve().parent.parent / 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'


def check(upstream=None):
    source = HOST.read_text().split('// FLOE_NATIVE_DRAIN_SCRIPT_BEGIN', 1)[1].split('// FLOE_NATIVE_DRAIN_SCRIPT_END', 1)[0]
    script = source.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]
    proxy = ''
    if upstream:
        text = Path(upstream).read_text()
        proxy = 'global.proxySocketCounter' + text.split('global.proxySocketCounter', 1)[1].split('global.iterateCSSImages', 1)[0]
        proxy += '\nglobal.MobileSocket = MobileSocket;'
    with tempfile.TemporaryDirectory(prefix='floe-native-drain-') as directory:
        test = Path(directory) / 'drain.js'
        test.write_text('const script = ' + json.dumps(script) + ';\nconst proxy = ' + json.dumps(proxy) + ';\n' + HARNESS)
        result = subprocess.run(['node', str(test)], check=True, capture_output=True, text=True, timeout=20)
    report = json.loads(result.stdout)
    report.update(actualFullAppAttachmentRetestPassed=False, nativeCompilationPassed=False,
                  scriptSHA256=hashlib.sha256(script.encode()).hexdigest())
    if upstream:
        report['upstreamSHA256'] = hashlib.sha256(Path(upstream).read_bytes()).hexdigest()
    return report


HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
function setup(useProxy = false, ios = true) {
    const requests = [], timers = [], received = [], sent = [];
    let now = 0, failures = 0;
    class Request {
        constructor() { this.listeners = {}; this.status = 0; requests.push(this); }
        addEventListener(event, fn) { (this.listeners[event] ||= []).push(fn); }
        open(method, url) { this.method = method; this.url = url; }
        send(body) { this.body = body; }
        emit(event) { for (const fn of this.listeners[event] || []) fn.call(this); }
        complete(data = new Uint8Array(), status = 200) {
            this.status = status; this.response = data.buffer;
            this.emit('load'); this.emit('loadend');
        }
    }
    const window = {
        ThisIsTheiOSApp: ios, app: {console: {debug() {}, error() {}, warn() {}}},
        postMobileMessage(data) { sent.push(data); }
    };
    const context = vm.createContext({window, global: window, XMLHttpRequest: Request,
        TextDecoder, TextEncoder, Uint8Array, performance: {now: () => now},
        setTimeout: fn => timers.push(fn), clearTimeout() {}, setInterval() {}, clearInterval() {}});
    let socket;
    if (useProxy) {
        vm.runInContext(proxy, context);
        socket = new window.MobileSocket('/test');
        requests[0].status = 200; requests[0].responseText = 'mobile';
        socket.onopen = () => {};
        requests[0].emit('load'); requests[0].emit('loadend');
        requests.length = 0;
        socket.onmessage = event => received.push(event.data);
        socket.onclose = () => failures++;
    } else {
        socket = {uri: 'cool:/cool/mobilesocket/test', readyState: 1, msgInflight: 0,
            getEndPoint: command => 'cool:/cool/mobilesocket/test/' + command,
            parseIncomingArray: data => received.push(...data),
            _signalErrorClose() { this.readyState = 3; this.msgInflight = 0; failures++; }};
    }
    window.socket = socket;
    window.createWebSocket = () => socket;
    return {socket, requests, timers, received, sent, window, context,
        install: () => vm.runInContext(script, context), setNow: value => now = value,
        failures: () => failures};
}

// Notifications arriving while native response bytes are already in flight
// must be drained after completion, including a burst after a long idle.
{
    const s = setup(); s.install(); s.setNow(40000);
    for (let i = 0; i < 1000; i++) s.socket.doSend();
    assert.equal(s.requests.length, 1);
    s.requests[0].complete(new Uint8Array([1, 2]));
    assert.equal(s.requests.length, 2);
    s.requests[1].complete(new Uint8Array([3, 4]));
    assert.deepEqual(s.received, [1, 2, 3, 4]);
    assert.equal(s.socket.msgInflight, 0); assert.equal(s.failures(), 0);
    assert.equal(s.socket.floeNativeDrainState.active, false);
    assert.equal(s.socket.floeNativeDrainState.pending, false);
    assert.equal(s.requests.length, 2);
    assert.ok(s.requests.every(r => r.method === 'POST' && r.body === '.'));
    const method = s.socket.doSend; s.install(); assert.equal(s.socket.doSend, method);
}
// Actual transport failures remain failures; no automatic resubmission of
// native bytes which might already have been removed from the native queue.
for (const kind of ['http', 'error', 'abort', 'timeout']) {
    const s = setup(); s.install(); s.socket.doSend(); s.socket.doSend();
    if (kind === 'http') s.requests[0].complete(new Uint8Array(), 500);
    else { s.requests[0].emit(kind); s.requests[0].emit('loadend'); }
    s.socket.doSend();
    assert.equal(s.failures(), 1); assert.equal(s.requests.length, 1);
    assert.equal(s.socket.msgInflight, 0); assert.equal(s.socket.floeNativeDrainState.pending, false);
}
{
    const s = setup(); s.install(); s.socket.doSend(); s.socket.unloading = true;
    s.requests[0].emit('abort'); s.requests[0].emit('loadend');
    assert.equal(s.failures(), 0); assert.equal(s.requests.length, 1);
}
// Pending notifications before open, and an old request at document-end.
{
    const s = setup(); let opened = 0;
    s.socket.readyState = 0; s.socket.onopen = () => ++opened;
    s.install(); s.socket.doSend(); assert.equal(s.requests.length, 0);
    s.socket.readyState = 1; assert.equal(s.socket.onopen(), 1);
    assert.equal(opened, 1); assert.equal(s.requests.length, 1);
    s.requests[0].complete();
}
{
    const s = setup(); s.socket.msgInflight = 1;
    s.install(); s.socket.doSend(); assert.equal(s.requests.length, 0);
    s.socket.msgInflight = 0; s.timers.shift()();
    assert.equal(s.requests.length, 1); s.requests[0].complete();
}
for (const native of [false, true]) {
    const s = setup(false, native);
    if (native) s.socket.uri = 'wss://example.invalid/editor';
    s.install(); assert.equal(s.socket.floeNativeDrainState, undefined);
}
{
    const s = setup(); delete s.window.socket; s.install();
    assert.equal(s.socket.floeNativeDrainState, undefined);
    assert.equal(s.window.createWebSocket(), s.socket);
    assert.ok(s.socket.floeNativeDrainState);
}
let upstreamFalseDisconnectReproduced = false;
if (proxy) {
    const old = setup(true); old.setNow(40000);
    // Empty drains after an idle bring the inherited poll throttle to 500 ms.
    for (let i = 0; i < 30; i++) { old.socket.doSend(); old.requests.at(-1).complete(); }
    assert.ok(old.socket.curPollMs >= old.socket.maxPollMs);
    for (let i = 0; i < 5; i++) old.socket.doSend();
    assert.equal(old.failures(), 1);
    upstreamFalseDisconnectReproduced = true;
    const fixed = setup(true); fixed.install(); fixed.setNow(40000);
    for (let i = 0; i < 1000; i++) fixed.socket.doSend();
    assert.equal(fixed.requests.length, 1);
    fixed.requests[0].complete(new TextEncoder().encode('T0x1\n0x3\none\n'));
    fixed.requests[1].complete(new TextEncoder().encode('T0x2\n0x3\ntwo\n'));
    assert.deepEqual(fixed.received, ['one', 'two']); assert.equal(fixed.failures(), 0);
    fixed.socket.send('useractive'); assert.deepEqual(fixed.sent, ['useractive']);
}
console.log(JSON.stringify({checksPassed: [
    '1000 idle-burst notifications coalesce without dropping response bytes',
    'notifications during an active response trigger a subsequent drain',
    'HTTP, error, abort and timeout fail without automatic replay',
    'unload does not report a spurious failure',
    'initial open and in-flight preinstallation requests retain notifications',
    'remote sockets stay untouched and installation is idempotent',
    'future native sockets receive the same protection'
], upstreamFalseDisconnectReproduced}));
'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--upstream', type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.upstream), indent=2))
