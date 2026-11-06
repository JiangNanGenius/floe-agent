// SPDX-License-Identifier: MPL-2.0
const frame = document.getElementById('content');
let sequence = 0;
let revision = seed.revision;
let localState = { revision: revision, modelContent: seed.modelContent, privateContent: seed.privateContent };
let queue = Promise.resolve();
let pendingCount = 0;
let active = true;
let flushID = 0;
const flushWaiters = new Map();
const clone = function(x) { return JSON.parse(JSON.stringify(x)); };
const bytes = function(x) { return new TextEncoder().encode(JSON.stringify(x)).length; };
const reply = function(id, body) {
    if (frame.contentWindow) frame.contentWindow.postMessage({ channel: 'floe-host-v1', id: id, body: body }, '*');
};
window.addEventListener('message', function(event) {
    if (event.source !== frame.contentWindow || !event.data) return;
    if (event.data.channel === 'floe-client-flushed-v1') {
        const waiter = flushWaiters.get(event.data.id);
        if (!waiter) return;
        flushWaiters.delete(event.data.id); clearTimeout(waiter.timeout);
        if (event.data.ok === true) waiter.resolve(); else waiter.reject(new Error('save-failed'));
        return;
    }
    if (event.data.channel !== 'floe-client-v1') return;
    const data = event.data;
    if (!Number.isSafeInteger(data.id) || data.id < 1) return;
    try {
        if (bytes(data) > 72 * 1024 || !['ready', 'state', 'resize'].includes(data.event)) throw new Error('invalid-message');
    } catch (_) { reply(data.id, { error: 'invalid-message' }); return; }
    if (pendingCount >= 64) { reply(data.id, { error: 'busy' }); return; }
    pendingCount++;
    queue = queue.then(async function() {
        const message = { version: 1, leaseID: seed.leaseID, sequence: ++sequence, event: data.event };
        if (data.event === 'state') {
            message.expectedRevision = revision;
            message.modelContent = data.modelContent;
            message.privateContent = data.privateContent;
        }
        if (data.event === 'resize') message.height = data.height;
        try {
            let receipt;
            if (seed.native) {
                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.floeInteractive;
                if (!handler) throw new Error('host-unavailable');
                receipt = await handler.postMessage(JSON.stringify(message));
                if (typeof receipt === 'string') receipt = JSON.parse(receipt);
            } else {
                if (data.event === 'state') {
                    if (bytes(data.modelContent) > 32 * 1024 || bytes(data.privateContent) > 32 * 1024) throw new Error('state-too-large');
                    localState = { revision: ++revision, modelContent: data.modelContent, privateContent: data.privateContent };
                }
                receipt = { version: 1, state: clone(localState) };
                if (data.event === 'resize') receipt.height = data.height;
            }
            if (!receipt || receipt.version !== 1 || !receipt.state) throw new Error('invalid-receipt');
            revision = receipt.state.revision;
            localState = clone(receipt.state);
            if (Number.isFinite(receipt.height) && receipt.height >= 80 && receipt.height <= 4096) {
                frame.style.height = Math.ceil(receipt.height) + 'px';
            }
            reply(data.id, receipt);
        } catch (_) { reply(data.id, { error: 'save-failed' }); }
        finally { pendingCount--; }
    });
});
frame.addEventListener('load', function() {
    if (frame.contentWindow) frame.contentWindow.postMessage({
        channel: 'floe-host-init-v1',
        state: { revision: revision, modelContent: seed.modelContent, privateContent: seed.privateContent },
        active: active
    }, '*');
});
// Native-only lifecycle entrypoints live in the trusted main frame.
Object.defineProperty(window, '__floeHost', { value: Object.freeze({
    flush: async function() {
        const id = ++flushID;
        await new Promise(function(resolve, reject) {
            const timeout = setTimeout(function() { flushWaiters.delete(id); reject(new Error('flush-timeout')); }, 1500);
            flushWaiters.set(id, { resolve: resolve, reject: reject, timeout: timeout });
            frame.contentWindow.postMessage({ channel: 'floe-host-flush-v1', id: id }, '*');
        });
        await queue;
    },
    state: function() { return clone(localState); },
    setActive: function(value) {
        active = !!value;
        if (frame.contentWindow) frame.contentWindow.postMessage({ channel: 'floe-host-active-v1', active: active }, '*');
    }
}), writable: false, configurable: false });
frame.srcdoc = childHTML;
