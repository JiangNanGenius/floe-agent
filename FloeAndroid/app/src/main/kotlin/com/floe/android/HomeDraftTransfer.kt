// SPDX-License-Identifier: MPL-2.0
//
// Home launchpad draft handoff — the ONE privacy boundary between the
// durable Home composer state (FloeDraftStore.HOME_DRAFT, process-memory
// today but explicitly a Home-owned draft record) and the RAM-only
// temporary session.
//
// Contract (Main candidate review, 2026-10-20/21):
//   * a temporary start transfers the originating Home text ONLY after the
//     REAL temp.start was admitted (never optimistically);
//   * the transfer consumes the Home draft only when it still holds the
//     EXACT transferred text — a newer edit or a different Home identity is
//     never clobbered by a late admission;
//   * a failed/never-admitted temporary start leaves HOME_DRAFT untouched,
//     so the user can retry from the same Home;
//   * an attempt canceled by an ACTUAL navigation consumes its own exact
//     text so a canceled private prompt cannot seed the next ordinary Home;
//   * ordinary Send keeps its existing clear/restore lifecycle and does not
//     call this helper.
//
// Every access goes through the store's own monitor: the page edits the
// draft on the UI thread while the native admission callback consumes it on
// the IO dispatcher, and the underlying store is a plain process-memory map.
package com.floe.android

import com.floe.android.design.FloeDraftStore

internal object HomeDraftTransfer {
    /** The current Home draft (UI-thread safe). */
    fun draft(store: FloeDraftStore): String = synchronized(store) {
        store.draft(FloeDraftStore.HOME_DRAFT)
    }

    /** Mirror one composer edit into the RAM draft (UI-thread safe). */
    fun update(store: FloeDraftStore, text: String) {
        synchronized(store) { store.update(FloeDraftStore.HOME_DRAFT, text) }
    }

    /**
     * Consume the Home draft only when it is EXACTLY the text that the
     * admitted temporary session took. Returns true when the draft was
     * consumed (the caller may then clear its visible field), false when a
     * newer/different Home draft must survive untouched.
     */
    fun consumeTransferred(
        store: FloeDraftStore,
        transferred: String,
        isOriginCurrent: Boolean,
    ): Boolean = synchronized(store) {
        // Text equality alone is not ownership: the caller must prove the
        // service-owned Home/request generation is still current.
        if (!isOriginCurrent) return@synchronized false
        if (store.draft(FloeDraftStore.HOME_DRAFT) != transferred) {
            return@synchronized false
        }
        store.consume(FloeDraftStore.HOME_DRAFT)
        true
    }
}
