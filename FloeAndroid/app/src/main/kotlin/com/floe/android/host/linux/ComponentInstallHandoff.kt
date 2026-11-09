// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes the install-return/UI handoff with callbacks from its exact OS session.
 * The parent supplies its EXISTING operation mutex; this is not another permission registry. */
internal class ComponentInstallHandoff(private val actions: Mutex) {
    private var sessionID: Int? = null
    // Called while the parent holds actions across prepareComponent and busy-state publication.
    fun begin() { sessionID = null }
    fun bind(sessionID: Int?) { this.sessionID = sessionID }
    fun completed() { sessionID = null }
    suspend fun route(sessionID: Int, apply: () -> Unit): Boolean = actions.withLock {
        if (sessionID != this.sessionID) false else { apply(); true }
    }
}
