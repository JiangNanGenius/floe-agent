// SPDX-License-Identifier: MPL-2.0
// Floe narrow Writer first-paint layout re-sync for the pinned Collabora
// mobile dist (source commit 2333344185931274f9c49d6c12a408cefcef6844).
// Deferred AFTER bundle.js in dist/cool.html; no producer file is edited.
//
// Pinned-source reason: the initial canvas geometry is measured once at
// tile-layer setup (CanvasTileLayer._setup -> _syncTileContainerSize -> the
// live #document-container rect). Writer's status path
// (WriterTileLayer._onStatusMsg) sets the document size but never re-runs
// that measurement, while Calc re-syncs on status and Impress relayouts via
// onResizeImpress. A real viewport change recovers through the existing
// ViewLayoutBase.onResize -> _syncTileContainerSize + single-window rebuild
// (dist/src/app/ViewLayout.js).
//
// Repair: after BOTH genuine lifecycle edges for the same captured Writer
// identities (map, document layer, activeDocument and activeLayout) — the
// real page 'load' event (the bundle's own completion boundary) and the real
// map 'docloaded' status — retire the listeners, capture the live geometry,
// then wait exactly ONE owned requestAnimationFrame before invoking the exact
// onResize path. The socket stack applies Writer status geometry after the
// docloaded dispatch, so this one frame is the real completion boundary; it
// is not a timer, recurring frame, retry, synthetic event, forced readiness
// or permission change. The callback revalidates all captured identities and
// refuses if any went stale. One frame is needed because pinned
// src/app/Socket.js fires docloaded before its document-layer status call,
// and that later call is where Writer applies the first status geometry.
//
// Diagnostics: post one strict numeric-only geometry packet (main/document/
// canvas before>after, viewport/html/body after, outcome label) through the
// existing host bridge into the bounded RAM-only Technical details history.
// The host consumes it; it is never forwarded to native and is never
// evidence of rendering, permission or save success.
(function () {
    'use strict';

    function currentMap() {
        return window.app && window.app.map;
    }

    function usableMap(map) {
        return !!map && typeof map.on === 'function' && typeof map.off === 'function';
    }

    function num(value) {
        return Number.isFinite(value) ? Math.max(0, Math.round(value)) : 0;
    }

    function size(width, height) {
        return num(width) + 'x' + num(height);
    }

    function rectFromElement(element) {
        if (!element || typeof element.getBoundingClientRect !== 'function')
            return size(0, 0);
        var rect = element.getBoundingClientRect();
        return size(rect.width, rect.height);
    }

    function rectSize(id) {
        return rectFromElement(document.getElementById(id));
    }

    function clientSize(element) {
        if (!element) return size(0, 0);
        return size(element.clientWidth, element.clientHeight);
    }

    function canvasSize() {
        var container = window.app && window.app.sectionContainer;
        if (container &&
            typeof container.getWidth === 'function' &&
            typeof container.getHeight === 'function') {
            var width = container.getWidth();
            var height = container.getHeight();
            if (Number.isFinite(width) && Number.isFinite(height))
                return size(width, height);
        }
        var element = document.getElementById('document-canvas');
        return size(element && element.width, element && element.height);
    }

    function geometry() {
        return {
            main: rectSize('main-document-content'),
            doc: rectSize('document-container'),
            canvas: canvasSize(),
            viewport: size(window.innerWidth, window.innerHeight),
            html: clientSize(document.documentElement),
            body: rectFromElement(document.body),
        };
    }

    function post(packet) {
        try {
            if (window.COOLMessageHandler &&
                typeof window.COOLMessageHandler.postMobileMessage === 'function')
                window.COOLMessageHandler.postMobileMessage(packet);
            else if (typeof window.postMobileMessage === 'function')
                window.postMobileMessage(packet);
        } catch (_) {
            /* The host bridge can disappear only during teardown; the one-shot
             * layout attempt belongs to the exact live map captured below. */
        }
    }

    function packet(before, after, result) {
        post('floe-viewport-geometry' +
            ' main=' + before.main + '>' + after.main +
            ' doc=' + before.doc + '>' + after.doc +
            ' canvas=' + before.canvas + '>' + after.canvas +
            ' viewport=' + after.viewport +
            ' html=' + after.html +
            ' body=' + after.body +
            ' sync=' + result);
    }

    function install(initialPageLoaded) {
        var map = currentMap();
        if (!usableMap(map))
            return;

        var attempted = false;
        var pageLoaded = initialPageLoaded === true;
        var documentLoaded = false;
        var loadListenerArmed = false;
        var writerLayer = null;
        var writerDocument = null;
        var writerLayout = null;

        function captureWriterEdges(verifyLoadedState) {
            if (documentLoaded || attempted)
                return;
            var layer = map._docLayer;
            if (!layer || layer._docType !== 'text')
                return; // Calc/Impress already own their post-status re-sync paths.
            if (verifyLoadedState && map._docLoaded !== true)
                return;
            documentLoaded = true;
            writerLayer = layer;
            writerDocument = window.app.activeDocument || null;
            writerLayout = writerDocument && writerDocument.activeLayout || null;
        }

        function onDocLoaded(event) {
            if (attempted || documentLoaded || !event || event.status !== true)
                return;
            // The real event is the edge; the current loaded flag is revalidated
            // before invoking, so a different dispatch order cannot miss it.
            captureWriterEdges(false);
            if (documentLoaded)
                scheduleSync();
        }

        function performSync(before) {
            var stale = map !== currentMap() ||
                map._docLoaded !== true ||
                !writerLayer ||
                writerLayer !== map._docLayer ||
                writerLayer._docType !== 'text' ||
                !writerDocument ||
                writerDocument !== window.app.activeDocument ||
                !writerLayout ||
                writerLayout !== writerDocument.activeLayout;
            if (stale) {
                packet(before, geometry(), 'stale');
                return;
            }
            if (typeof writerLayout.onResize !== 'function') {
                packet(before, geometry(), 'absent');
                return;
            }

            try {
                writerLayout.onResize();
            } catch (error) {
                packet(before, geometry(), 'failed');
                throw error; // surface the real failure to the host; never hide it
            }
            packet(before, geometry(), 'applied');
        }

        function scheduleSync() {
            if (attempted || !pageLoaded || !documentLoaded)
                return;
            attempted = true;
            if (loadListenerArmed) {
                loadListenerArmed = false;
                window.removeEventListener('load', onLoad);
            }
            map.off('docloaded', onDocLoaded);

            var before = geometry();
            if (typeof window.requestAnimationFrame !== 'function') {
                packet(before, geometry(), 'absent');
                return;
            }
            // Exactly one owned frame after both real edges. The socket status
            // stack applies Writer geometry after the docloaded dispatch.
            window.requestAnimationFrame(function () {
                performSync(before);
            });
        }

        function onLoad() {
            pageLoaded = true;
            scheduleSync();
        }

        if (!pageLoaded) {
            window.addEventListener('load', onLoad);
            loadListenerArmed = true;
        }
        map.on('docloaded', onDocLoaded);

        // Deferred ordering normally leaves the document edges ahead; this
        // read-once fallback handles an install after the real load edge.
        captureWriterEdges(true);
        if (pageLoaded)
            scheduleSync();
    }

    if (currentMap() || document.readyState === 'complete') {
        install(document.readyState === 'complete');
    } else {
        // The shipped bundle constructs app.map before any later deferred
        // script. If that ordering is ever violated, this remains tied to the
        // same real load edge once; there is no timer or poll.
        window.addEventListener('load', function () {
            install(true);
        }, { once: true });
    }
})();
