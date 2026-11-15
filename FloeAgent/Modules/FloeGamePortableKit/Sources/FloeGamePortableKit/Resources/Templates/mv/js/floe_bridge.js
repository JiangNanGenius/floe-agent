// SPDX-License-Identifier: MPL-2.0
// Floe portable adapter for the official MIT RPG Maker MV CoreScript.
// Original Floe code. This file is loaded before plugins.js/main.js and uses
// only the game's public runtime objects. It exposes no native capability.
(function () {
    'use strict';
    var runtimeID = 'rpg-maker-mv-corescript-1.3b-182e31449707ba7e406db0485c44c2a9d11e2dcd';
    var announced = false;

    function host() { return window.floeGameHost || null; }
    function log(message) { try { if (host()) host().log(String(message)); } catch (e) {} }
    function ready() {
        if (announced) return;
        announced = true;
        try {
            if (host()) host().ready({engine: 'rpgMakerMV', runtime: runtimeID, input: true, state: true});
        } catch (e) { log(e && e.message ? e.message : e); }
    }

    var keyMap = {
        left: [37], right: [39], up: [38], down: [40],
        confirm: [13, 32, 90], cancel: [27, 88],
        action1: [90], action2: [88], action3: [67], action4: [86],
        start: [13], select: [9]
    };

    function dispatchKey(name, pressed) {
        var codes = keyMap[name];
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
        var init = {key: event.key || '', code: event.code || '', keyCode: code,
            which: Number(event.which || code), location: Number(event.location || 0),
            shiftKey: !!event.shiftKey, ctrlKey: !!event.ctrlKey, altKey: !!event.altKey,
            metaKey: !!event.metaKey, repeat: !!event.repeat, bubbles: true, cancelable: true};
        document.dispatchEvent(new KeyboardEvent(event.pressed ? 'keydown' : 'keyup', init));
        return true;
    }

    function pointer(phase, x, y, button) {
        var canvas = document.querySelector('canvas');
        if (!canvas || !isFinite(x) || !isFinite(y)) return false;
        var cx = Math.max(0, Math.min(1, Number(x))) * window.innerWidth;
        var cy = Math.max(0, Math.min(1, Number(y))) * window.innerHeight;
        var name = phase === 'began' ? 'mousedown' : (phase === 'moved' ? 'mousemove' : 'mouseup');
        var init = {bubbles: true, cancelable: true, clientX: cx, clientY: cy,
            button: Number(button) || 0, buttons: phase === 'ended' ? 0 : 1};
        canvas.dispatchEvent(new MouseEvent(name, init));
        if (phase === 'ended') canvas.dispatchEvent(new MouseEvent('click', init));
        return true;
    }

    function snapshot() {
        if (typeof DataManager === 'undefined' || !window.$gameSystem || !window.$gameMap) return null;
        var contents = DataManager.makeSaveContents();
        return JSON.parse(JsonEx.stringify(contents));
    }

    function restore(state) {
        if (!state || typeof DataManager === 'undefined') return false;
        var contents = JsonEx.parse(JSON.stringify(state));
        DataManager.extractSaveContents(contents);
        $gamePlayer.refresh();
        $gameMap.requestRefresh();
        SceneManager.goto(Scene_Map);
        return true;
    }

    function choose(index) {
        var scene = window.SceneManager && SceneManager._scene;
        var win = scene && scene._choiceWindow;
        if (!win || !win.active || !Number.isInteger(index) || index < 0) return false;
        win.select(index);
        win.processOk();
        return true;
    }

    Object.defineProperty(window, 'FloeGame', {
        value: Object.freeze({key: key, input: dispatchKey, pointer: pointer, snapshot: snapshot,
            restore: restore, choose: choose}),
        writable: false, configurable: false
    });

    // Readiness is emitted only after the original runtime reaches Scene_Map,
    // i.e. the title screen has completed and save state actually exists.
    var poll = setInterval(function () {
        try {
            if (window.SceneManager && window.SceneManager._scene &&
                window.SceneManager._scene instanceof Scene_Map) {
                clearInterval(poll);
                ready();
            }
        } catch (e) { log(e && e.message ? e.message : e); }
    }, 100);
    setTimeout(function () { clearInterval(poll); }, 60000);
    addEventListener('error', function (e) { log(e && e.message ? e.message : 'script error'); });
    addEventListener('unhandledrejection', function (e) { log(e && e.reason ? e.reason : 'unhandled rejection'); });
})();
