// SPDX-License-Identifier: MPL-2.0
(function() {
    'use strict';
    const send = window.parent.postMessage.bind(window.parent);
    const stringify = JSON.stringify.bind(JSON);
    const parse = JSON.parse.bind(JSON);
    const clone = function(x) { return parse(stringify(x)); };
    let state = { revision: 0, modelContent: null, privateContent: null };
    let initialized = false;
    let nextID = 0;
    let desired = null;
    let busy = false;
    let waiters = [];
    let drainWaiters = [];
    let lastSaveError = null;
    const replies = new Map();
    const readyCallbacks = [];
    const activeCallbacks = [];
    let active = true;
    const request = function(event, extra) {
        return new Promise(function(resolve, reject) {
            const id = ++nextID;
            const timeout = setTimeout(function() { replies.delete(id); reject(new Error('host-timeout')); }, 10000);
            replies.set(id, { resolve: resolve, reject: reject, timeout: timeout });
            send(Object.assign({ channel: 'floe-client-v1', id: id, event: event }, extra || {}), '*');
        });
    };
    const notifyActive = function(value) {
        active = value;
        activeCallbacks.forEach(function(callback) { callback(active); });
    };
    async function flush() {
        if (!initialized || busy || desired === null) return;
        busy = true;
        const batch = desired;
        const listeners = waiters;
        desired = null;
        waiters = [];
        try {
            const receipt = await request('state', batch);
            state.revision = receipt.state.revision;
            if (desired === null) state = clone(receipt.state);
            lastSaveError = null;
            listeners.forEach(function(waiter) { waiter.resolve(clone(receipt.state)); });
        } catch (error) {
            lastSaveError = error;
            listeners.forEach(function(waiter) { waiter.reject(error); });
            window.dispatchEvent(new CustomEvent('floe:save-error'));
        } finally {
            busy = false;
            if (desired !== null) flush();
            else drainWaiters.splice(0).forEach(function(waiter) {
                if (lastSaveError) waiter.reject(lastSaveError); else waiter.resolve();
            });
        }
    }
    function drained() {
        if (!busy && desired === null) return lastSaveError ? Promise.reject(lastSaveError) : Promise.resolve();
        return new Promise(function(resolve, reject) {
            drainWaiters.push({ resolve: resolve, reject: reject }); flush();
        });
    }
    window.addEventListener('message', function(event) {
        if (event.source !== window.parent || !event.data) return;
        const message = event.data;
        if (message.channel === 'floe-host-init-v1' && !initialized) {
            initialized = true;
            state = clone(message.state);
            active = message.active;
            readyCallbacks.splice(0).forEach(function(callback) { callback(clone(state)); });
            request('ready').catch(function() {});
            queueMicrotask(function() {
                const report = function() {
                    const height = Math.min(4096, Math.max(80, Math.ceil(document.documentElement.scrollHeight)));
                    request('resize', { height: height }).catch(function() {});
                };
                new ResizeObserver(report).observe(document.body);
                report();
            });
            flush();
        } else if (message.channel === 'floe-host-active-v1') {
            notifyActive(!!message.active);
        } else if (message.channel === 'floe-host-flush-v1' && Number.isSafeInteger(message.id)) {
            drained().then(function() {
                send({ channel: 'floe-client-flushed-v1', id: message.id, ok: true }, '*');
            }, function() {
                send({ channel: 'floe-client-flushed-v1', id: message.id, ok: false }, '*');
            });
        } else if (message.channel === 'floe-host-v1') {
            const pending = replies.get(message.id);
            if (!pending) return;
            replies.delete(message.id);
            clearTimeout(pending.timeout);
            if (message.body && !message.body.error) pending.resolve(message.body);
            else pending.reject(new Error('save-failed'));
        }
    });
    Object.defineProperty(window, 'floeInteractive', { value: Object.freeze({
        getState: function() { return clone(state); },
        ready: function(callback) {
            if (initialized) callback(clone(state)); else readyCallbacks.push(callback);
        },
        setState: function(update) {
            let snapshot;
            try {
                snapshot = {
                    modelContent: Object.prototype.hasOwnProperty.call(update, 'modelContent') ? clone(update.modelContent) : state.modelContent,
                    privateContent: Object.prototype.hasOwnProperty.call(update, 'privateContent') ? clone(update.privateContent) : state.privateContent
                };
                if (new TextEncoder().encode(stringify(snapshot.modelContent)).length > 32 * 1024 ||
                    new TextEncoder().encode(stringify(snapshot.privateContent)).length > 32 * 1024) throw new Error('state-too-large');
            } catch (error) { return Promise.reject(error); }
            state.modelContent = snapshot.modelContent;
            state.privateContent = snapshot.privateContent;
            desired = snapshot;
            const promise = new Promise(function(resolve, reject) { waiters.push({ resolve: resolve, reject: reject }); });
            queueMicrotask(flush);
            return promise;
        },
        onActive: function(callback) { activeCallbacks.push(callback); callback(active); }
    }), writable: false, configurable: false });
})();
