// SPDX-License-Identifier: MPL-2.0
// Floe optional stopgap overlay for love.js IDBFS persistence.
//
// The current upstream love.js runtime mounts IDBFS at /home/web_user/love and
// only flushes on window.beforeunload. WebKit may tear the player down without
// firing beforeunload. This overlay does NOT make the unpatched runtime
// durable by itself; the supported fix is Root's authoritative
// Module.floePrepareToStop generated-loader patch, plus the Core storage
// lifecycle. This file is a bounded bridge for hosts that cannot take that
// patch yet:
//   - if the runtime exposes Love.floePrepareToStop or Love.flushSave, call it;
//   - otherwise dispatch a synthetic beforeunload and wait a bounded time.
//
// A synthetic event timing pass is not proof of cross-player persistence.
// Root/the Core storage owner must test a real S/write -> stop -> new player ->
// L/read cycle on the actual lifecycle.
(function () {
    'use strict';

    var pending = null;

    function delay(ms) {
        return new Promise(function (resolve) { setTimeout(resolve, ms); });
    }

    function flush() {
        if (pending) { return pending; }
        var love = window.Love;
        // Root's authoritative generated-loader patch exports
        // Module.floePrepareToStop; the source-level alternative exports
        // flushSave. Prefer the Root patch when present.
        var stop = love && (love.floePrepareToStop || love.flushSave);
        if (typeof stop === 'function') {
            pending = new Promise(function (resolve) {
                var done = false;
                function finish() {
                    if (done) { return; }
                    done = true;
                    pending = null;
                    resolve({ flushed: true, method: (love && love.floePrepareToStop) ? 'floePrepareToStop' : 'flushSave' });
                }
                try { stop.call(love, finish); } catch (e) { finish(); }
                setTimeout(finish, 1500);
            });
            return pending;
        }
        // Unpatched runtime: the only hook is its beforeunload listener.
        try {
            window.dispatchEvent(new Event('beforeunload'));
        } catch (e) {
            try { window.dispatchEvent(new Event('pagehide')); } catch (e2) {}
        }
        pending = delay(400).then(function () {
            pending = null;
            return { flushed: true, method: 'beforeunload-event', proof: false };
        });
        return pending;
    }

    Object.defineProperty(window, 'FloePersist', {
        value: Object.freeze({
            flush: flush,
            note: 'A synthetic flush is not proof; verify a real new-player save cycle.'
        }),
        writable: false,
        configurable: false
    });

    window.addEventListener('pagehide', function () { flush(); });
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'hidden') { flush(); }
    });
    setInterval(function () { flush(); }, 5000);
})();
