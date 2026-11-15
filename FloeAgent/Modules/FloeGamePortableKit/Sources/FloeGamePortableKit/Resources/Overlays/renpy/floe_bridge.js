// SPDX-License-Identifier: MPL-2.0
// Floe portable adapter for the official Ren'Py 8.5.3 Web runtime.
// Original Floe code. Ren'Py remains a real WebAssembly game; this shim reports
// presplash-end readiness and forwards typed keyboard/pointer events.
(function () {
    'use strict';
    var runtimeID = 'renpy-8.5.3-web-official';
    var announced = false;
    function host() { return window.floeGameHost || null; }
    function log(message) { try { if (host()) host().log(String(message)); } catch (e) {} }
    function ready() {
        if (announced || typeof window.renpy_get !== 'function' || document.getElementById('presplash')) return;
        announced = true;
        try { if (host()) host().ready({engine: 'renpy', runtime: runtimeID, input: true, state: false}); }
        catch (e) { log(e && e.message ? e.message : e); }
    }
    var keys = {
        left: {key:'ArrowLeft',code:'ArrowLeft',keyCode:37}, right:{key:'ArrowRight',code:'ArrowRight',keyCode:39},
        up:{key:'ArrowUp',code:'ArrowUp',keyCode:38}, down:{key:'ArrowDown',code:'ArrowDown',keyCode:40},
        confirm:{key:'Enter',code:'Enter',keyCode:13}, cancel:{key:'Escape',code:'Escape',keyCode:27},
        action1:{key:'Control',code:'ControlLeft',keyCode:17,location:1}, action2:{key:'Tab',code:'Tab',keyCode:9},
        action3:{key:'PageUp',code:'PageUp',keyCode:33}, action4:{key:'PageDown',code:'PageDown',keyCode:34},
        start:{key:'Enter',code:'Enter',keyCode:13}, select:{key:'Tab',code:'Tab',keyCode:9}
    };
    function target() {
        var active = document.activeElement;
        if (active && active !== document.body && active !== document.documentElement) return active;
        return document.getElementById('canvas') || document;
    }
    function dispatch(detail, pressed) {
        var init = {key:detail.key, code:detail.code, keyCode:detail.keyCode, which:detail.which || detail.keyCode,
            location:detail.location || 0, shiftKey:!!detail.shiftKey, ctrlKey:!!detail.ctrlKey,
            altKey:!!detail.altKey, metaKey:!!detail.metaKey, repeat:!!detail.repeat,
            bubbles:true, cancelable:true};
        target().dispatchEvent(new KeyboardEvent(pressed ? 'keydown' : 'keyup', init));
    }
    function input(name, pressed) {
        var key = keys[name];
        if (!key) return false;
        dispatch(key, pressed);
        return true;
    }
    function key(event) {
        if (!event || typeof event.pressed !== 'boolean') return false;
        dispatch(event, event.pressed);
        return true;
    }
    function pointer(phase, x, y, button) {
        var canvas = document.getElementById('canvas');
        if (!canvas || !isFinite(x) || !isFinite(y)) return false;
        var type = phase === 'began' ? 'mousedown' : (phase === 'moved' ? 'mousemove' : 'mouseup');
        var init = {bubbles:true, cancelable:true, clientX:Number(x)*innerWidth, clientY:Number(y)*innerHeight,
            button:Number(button)||0, buttons:phase === 'ended' ? 0 : 1};
        canvas.dispatchEvent(new MouseEvent(type, init));
        if (phase === 'ended') canvas.dispatchEvent(new MouseEvent('click', init));
        return true;
    }
    var stopping = null;
    function prepareToStop() {
        if (stopping) return stopping;
        stopping = new Promise(function (resolve, reject) {
            var fs = window.Module && window.Module.FS;
            if (!fs || typeof fs.syncfs !== 'function') {
                reject(new Error('Runtime has no acknowledged filesystem flush'));
                return;
            }
            var deadline = Date.now() + 1500;
            function flushWhenIdle() {
                // Ren'Py also initiates IDBFS sync after an engine save. Avoid
                // overlapping its pending transaction with the close flush.
                if (Number(fs.syncFSRequests || 0) > 0) {
                    if (Date.now() >= deadline) { reject(new Error('Save synchronization is still busy')); return; }
                    setTimeout(flushWhenIdle, 10);
                    return;
                }
                fs.syncfs(false, function (error) {
                    if (error) reject(error); else resolve(true);
                });
            }
            flushWhenIdle();
        });
        return stopping;
    }
    Object.defineProperty(window, 'FloeGame', {
        value: Object.freeze({key:key, input:input, pointer:pointer,
            prepareToStop:prepareToStop,
            restart:function(){ location.reload(); return true; },
            snapshot:function(){ return null; }, restore:function(){ return false; }}),
        writable:false, configurable:false
    });
    var originalPresplashEnd = window.presplashEnd;
    if (typeof originalPresplashEnd === 'function') {
        window.presplashEnd = function () {
            try { return originalPresplashEnd.apply(this, arguments); }
            finally { setTimeout(ready, 0); }
        };
    }
    var poll = setInterval(ready, 100);
    setTimeout(function(){ clearInterval(poll); }, 120000);
    addEventListener('error', function(e){ log(e && e.message ? e.message : 'script error'); });
})();
