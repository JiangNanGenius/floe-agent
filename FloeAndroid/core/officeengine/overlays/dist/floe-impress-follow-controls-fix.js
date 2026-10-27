// SPDX-License-Identifier: MPL-2.0
// Floe G05-R2 narrow frontend repair for the pinned Collabora mobile dist
// (APK 26.04.4.2 code937, online source commit
// 2333344185931274f9c49d6c12a408cefcef6844). Referenced by dist/cool.html
// with defer AFTER bundle.js, so it runs once the bundle has defined
// window.SlideShow.SlideShowPresenter and long before any document load can
// construct the presenter (construction happens at UIManager
// initializeSpecializedUI / the welcome-presentation branch, both driven by
// the websocket status flow).
//
// Defect (actual Samsung API33 phone evidence, SAMSUNG_C06_PPT_DIAGNOSTIC,
// synthetic two-slides-preview fixture; document renders, native state
// READY_EDITABLE, exactly two console errors):
//   UIManager: Button with id "slide-presentation-follow" not found.
//   UIManager: Button with id "slide-presentation-follow-me" not found.
//
// Exact control path at this revision:
//  - SlideShowPresenter's constructor ends with this.showFollow(true)
//    (dist/src/slideshow/SlideShowPresenter.js:115), and showFollow asks
//    uiManager.showButton for 'slide-presentation-follow' and
//    'slide-presentation-follow-me' (SlideShowPresenter.js:10-13).
//  - Those two controls are defined ONLY in the Impress notebookbar and are
//    gated there by `!window.ThisIsAMobileApp`
//    (dist/src/control/Control.NotebookbarImpress.js:544-562), so no mobile
//    app UI ever contains them.
//  - On a phone, UIManager.getCurrentMode() returns 'classic' for every
//    small-screen device and initializeSpecializedUI builds only the mobile
//    bars, never a notebookbar (dist/src/control/Control.UIManager.js
//    :212-217, :738-747). showButton then searches the classic toolbar
//    (showButtonInClassicToolbar, whose `toolbars` list is empty and whose
//    map.topToolbar does not carry the ids) and, with this.notebookbar
//    null, logs `UIManager: Button with id "..." not found.`
//    (Control.UIManager.js:1342-1360). Every phone Impress document emits
//    exactly the two observed errors at presenter construction.
//  - On tablet/desktop the notebookbar object exists and its showItem
//    unconditionally reports found (Control.Notebookbar.js:1157-1166), so
//    the stock path never errors there — matching the observed
//    phone-only failure.
//
// Repair: showFollow asks UIManager to toggle the two follow controls ONLY
// when the same lookup UIManager.showButton itself performs would actually
// find them (notebookbar present, or classic topToolbar carrying the id).
// The follow controls are upstream's Present-to-All/Follow-Presenter
// collaboration affordances, deliberately absent from every mobile UI at
// this revision; this changes no behaviour where the buttons exist, adds no
// button, hides no real error, and leaves UIManager.showButton — including
// its error logging for genuinely missing buttons — completely untouched.
(function () {
    'use strict';
    var slideShow = window.SlideShow;
    var presenter = slideShow && slideShow.SlideShowPresenter;
    if (!presenter || !presenter.prototype ||
        typeof presenter.prototype.showFollow !== 'function') {
        return; // Not this bundle shape; leave stock behavior untouched.
    }
    var FOLLOW_ID = 'slide-presentation-follow';
    var FOLLOW_ME_ID = 'slide-presentation-follow-me';

    // Side-effect-free mirror of UIManager.showButton's real lookup at this
    // revision: the notebookbar branch treats notebookbar.showItem/hideItem
    // as authoritative (they always answer found), and the classic branch
    // consults only window.app.map.topToolbar.hasItem.
    function uiProvidesButton(uiManager, buttonId) {
        if (!uiManager) {
            return false;
        }
        try {
            if (uiManager.notebookbar) {
                return true;
            }
            if (typeof uiManager.getCurrentMode === 'function' &&
                uiManager.getCurrentMode() === 'classic') {
                var map = uiManager._map || (window.app && window.app.map);
                var topToolbar = map && map.topToolbar;
                if (topToolbar && typeof topToolbar.hasItem === 'function' &&
                    topToolbar.hasItem(buttonId)) {
                    return true;
                }
            }
        } catch (e) {
            // Fail closed: never claim a button exists when the lookup
            // itself could not run.
            return false;
        }
        return false;
    }

    presenter.prototype.showFollow = function (me) {
        var uiManager = this._map && this._map.uiManager;
        if (!uiManager || typeof uiManager.showButton !== 'function') {
            return;
        }
        if (uiProvidesButton(uiManager, FOLLOW_ID)) {
            uiManager.showButton(FOLLOW_ID, !me);
        }
        if (uiProvidesButton(uiManager, FOLLOW_ME_ID)) {
            uiManager.showButton(FOLLOW_ME_ID, me);
        }
    };
})();
