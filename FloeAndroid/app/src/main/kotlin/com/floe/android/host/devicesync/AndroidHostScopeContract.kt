// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import com.floe.android.core.devicelink.DeviceHistoryCatalog
import com.floe.android.core.devicelink.DeviceHistoryOffer
import java.util.UUID

/**
 * The explicit authority record for the v2 device-sync extensions. A
 * capability is only ever advertised — or requested — when the local
 * authority behind it is real; every field defaults to the safe v1 state.
 *
 *  * [attachmentRestore] — the installed native library exports the v2
 *    device-history ABI and the App store is ready. Without it the endpoint
 *    never advertises `attachmentTransfer` and never requests
 *    `historyVersion:2`.
 *  * [workspaceConvergence] — the rooted native workspace bridge is present
 *    (it is on every current build). The wire still only advertises
 *    `workspaceSyncVersion:2` per conversation when the user explicitly
 *    opted in AND the workspace share is live.
 */
internal data class DeviceSyncAuthority(
    val attachmentRestore: Boolean = false,
    val workspaceConvergence: Boolean = true,
)

/**
 * Pure capability/consent decisions shared by the host and its tests. These
 * mirror the frozen Apple `DeviceHistorySyncCenter`/`DeviceHistorySync`
 * rules so both ends converge on the same opt-in semantics.
 */
internal object AndroidHostScopeContract {
    /** Cursor namespace: a text-only cursor must never skip attachment-bearing messages. */
    const val ATTACHMENT_CURSOR_SUFFIX = ":attachments-v2"

    /**
     * Whether this receive selection imports the typed (v2) archive: the user
     * asked for files, the local restore authority is real, and the peer
     * advertised attachment transfer both top-level and for the selected
     * offer.
     */
    fun importsAttachments(
        authority: DeviceSyncAuthority,
        includeWorkspace: Boolean,
        catalog: DeviceHistoryCatalog?,
        taskId: UUID,
    ): Boolean = authority.attachmentRestore && includeWorkspace && catalog != null &&
        catalog.attachmentTransfer &&
        catalog.offers.firstOrNull { it.id == taskId }?.attachmentTransfer == true

    /** The receiver cursor namespace for this selection. */
    fun cursorPeer(peerId: String, typedHistory: Boolean): String =
        if (typedHistory) peerId + ATTACHMENT_CURSOR_SUFFIX else peerId

    /**
     * The convergence mode for a workspace receive: the peer advertised
     * `workspaceSyncVersion:2` for the selected conversation AND this device
     * explicitly consented for the same peer/conversation. Both opt-ins are
     * required; either missing keeps the v1 keep-local behavior.
     */
    fun convergesWorkspace(
        authority: DeviceSyncAuthority,
        peer: DeviceHistoryPeer?,
        taskId: UUID,
        offer: DeviceHistoryOffer?,
    ): Boolean = authority.workspaceConvergence && peer != null && offer != null &&
        offer.workspaceSyncVersion == 2 && peer.convergesWorkspace(taskId)

    /** Whether the local endpoint may advertise the v2 history surface at all. */
    fun advertisesAttachmentTransfer(authority: DeviceSyncAuthority): Boolean =
        authority.attachmentRestore
}
