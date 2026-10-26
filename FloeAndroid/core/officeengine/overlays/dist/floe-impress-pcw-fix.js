// SPDX-License-Identifier: MPL-2.0
// Floe G05-R1 narrow frontend repair for the pinned Collabora mobile dist
// (APK 26.04.4.2 code937, online source commit
// 2333344185931274f9c49d6c12a408cefcef6844). Referenced by dist/cool.html
// with defer AFTER bundle.js, so it runs once the bundle has defined
// window.L.ImpressTileLayer and long before the first websocket status
// message can reach the tile layer.
//
// Defect (actual Samsung API33 phone evidence, candidate07 technical
// details, synthetic two-slides-preview fixture):
//   NotFoundError: Failed to execute 'insertBefore' on 'Node': the
//   reference node is not a child of this node
//   ImpressTileLayer._putPCWInsideFlex -> onResizeImpress ->
//   _syncTileContainerSize -> _setup -> _initContainer -> onAdd ->
//   _onStatusMsg (bundle.js 80087:61/80102:39; unbundled
//   dist/src/layer/tile/ImpressTileLayer.js lines 157-165), emitted while
//   processing "status: type=presentation" although native loaded view 0.
//
// Exact root DOM relation at this revision: the shipped
// _putPCWInsideFlex() detaches #presentation-controls-wrapper from
// document.body (correct: _putPCWOutsideFlex() places it there, as a
// sibling of #main-document-content) but re-inserts it with
//   document.getElementById('document-container').parentNode
//       .insertBefore(pcw, main-document-content.children[0]);
// #document-container's real parent is #document-and-notes, while the
// reference node is a child of #main-document-content — the reference is
// not a child of the insertion parent, so the DOM contract throws. Every
// isSmallScreenDevice() Impress document whose tile-layer construction
// already ran _putPCWOutsideFlex() hits this on the first landscape
// evaluation of onResizeImpress, before the first paint. Tablets and
// desktop never take the small-screen branch, which matches the observed
// phone-only PPTX failure with the same document rendering on the tablet
// and DOCX still working on the same phone.
//
// Repair: keep upstream's intended placement — after being moved outside,
// the presentation-controls-wrapper returns as the FIRST CHILD of the
// #main-document-content flex (exactly the node the shipped reference
// expression pointed at) — with a structurally valid DOM move: detach
// from the wrapper's ACTUAL parent first, so the insertBefore reference
// is always a child of the same node being inserted into. This mirrors
// the parent/child contract the working _putPCWOutsideFlex() already
// uses. No desktop forcing, no error swallowing, no feature disabled;
// _isPCWInsideFlex() keeps both directions idempotent round-trips.
(function () {
    'use strict';
    var impress = window.L && window.L.ImpressTileLayer;
    if (!impress || !impress.prototype ||
        typeof impress.prototype._putPCWInsideFlex !== 'function') {
        return; // Not this bundle shape; leave stock behavior untouched.
    }
    impress.prototype._putPCWInsideFlex = function () {
        if (this._isPCWInsideFlex())
            return;
        var pcw = document.getElementById('presentation-controls-wrapper');
        var flexContainer = document.getElementById('main-document-content');
        if (!pcw || !flexContainer)
            return;
        if (pcw.parentNode)
            pcw.parentNode.removeChild(pcw);
        flexContainer.insertBefore(pcw, flexContainer.children[0] || null);
    };
})();
