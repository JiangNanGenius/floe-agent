// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.entryflow

import com.floe.android.host.RuntimeHostReadiness
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/** Wait for the existing bootstrap owner, never poll/retry a task command
 * against an uninitialized bridge or manufacture domain availability. */
internal suspend fun awaitC07EntryReadiness(
    readiness: StateFlow<RuntimeHostReadiness>,
    conversation: Boolean,
): Boolean {
    fun admitted(state: RuntimeHostReadiness): Boolean =
        if (conversation) state.conversationDomainAdmitted else state.storeReady

    val state = withTimeoutOrNull(20_000L) {
        readiness.first {
            admitted(it) ||
                it.gateway is RuntimeHostReadiness.GatewayReadiness.Failed ||
                it.store is RuntimeHostReadiness.StoreReadiness.Failed ||
                it.store is RuntimeHostReadiness.StoreReadiness.Stopped
        }
    } ?: return false
    return admitted(state)
}
