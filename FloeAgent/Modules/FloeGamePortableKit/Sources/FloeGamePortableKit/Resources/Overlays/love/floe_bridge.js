// SPDX-License-Identifier: MPL-2.0
// Floe portable adapter for the upstream love.js 11.4.1 compatibility runtime.
// Original Floe code. LOVE remains a real Lua/WebAssembly game; this shim only
// reports actual load completion and forwards typed keyboard input.
(function () {
    'use strict';
    var runtimeID = 'love.js-11.4.1/love-11.4.0-compat';
    var announced = false;
    function host() { return window.floeGameHost || null; }
    function log(message) { try { if (host()) host().log(String(message)); } catch (e) {} }
    function ready() {
        var loading = document.getElementById('loadingCanvas');
        var canvas = document.getElementById('canvas');
        if (announced || !loading || !canvas) return;
        if (loading.style.display !== 'none' || canvas.style.visibility !== 'visible') return;
        announced = true;
        try { if (host()) host().ready({engine: 'love', runtime: runtimeID, input: true, state: false}); }
        catch (e) { log(e && e.message ? e.message : e); }
    }
    var keys = {left:[37], right:[39], up:[38], down:[40], confirm:[13,32],
        cancel:[27], action1:[65], action2:[83], action3:[68], action4:[70],
        start:[13], select:[9]};
    function input(name, pressed) {
        var codes = keys[name];
        if (!codes) return false;
        for (var i = 0; i < codes.length; i++) {
            var code = codes[i];
            document.dispatchEvent(new KeyboardEvent(pressed ? 'keydown' : 'keyup', {
                key: String.fromCharCode(code), keyCode: code, which: code,
                bubbles: true, cancelable: true
            }));
        }
        return true;
    }
    function key(event) {
        if (!event || typeof event.pressed !== 'boolean') return false;
        var code = Number(event.keyCode || event.which || 0);
        document.dispatchEvent(new KeyboardEvent(event.pressed ? 'keydown' : 'keyup', {
            key: event.key || '', code: event.code || '', keyCode: code,
            which: Number(event.which || code), location: Number(event.location || 0),
            shiftKey: !!event.shiftKey, ctrlKey: !!event.ctrlKey, altKey: !!event.altKey,
            metaKey: !!event.metaKey, repeat: !!event.repeat, bubbles: true, cancelable: true
        }));
        return true;
    }
    function pointer(phase, x, y, button) {
        var canvas = document.getElementById('canvas');
        if (!canvas || !isFinite(x) || !isFinite(y)) return false;
        var event = phase === 'began' ? 'mousedown' : (phase === 'moved' ? 'mousemove' : 'mouseup');
        canvas.dispatchEvent(new MouseEvent(event, {bubbles: true, cancelable: true,
            clientX: Number(x) * innerWidth, clientY: Number(y) * innerHeight,
            button: Number(button) || 0, buttons: phase === 'ended' ? 0 : 1}));
        if (phase === 'ended') canvas.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true,
            clientX: Number(x) * innerWidth, clientY: Number(y) * innerHeight}));
        return true;
    }
    Object.defineProperty(window, 'FloeGame', {
        value: Object.freeze({
            key: key, input: input, pointer: pointer,
            prepareToStop: function () {
                if (!window.Module || typeof window.Module.floePrepareToStop !== 'function') {
                    return Promise.reject(new Error('Runtime has no acknowledged filesystem flush'));
                }
                return window.Module.floePrepareToStop();
            },
            restart: function () { location.reload(); return true; },
            snapshot: function () { return null; },
            restore: function () { return false; }
        }), writable: false, configurable: false
    });
    var poll = setInterval(ready, 100);
    setTimeout(function () { clearInterval(poll); }, 120000);
    addEventListener('error', function (e) { log(e && e.message ? e.message : 'script error'); });
})();
