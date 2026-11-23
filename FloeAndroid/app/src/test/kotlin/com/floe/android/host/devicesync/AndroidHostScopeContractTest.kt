// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import com.floe.android.core.devicelink.DeviceHistoryCatalog
import com.floe.android.core.devicelink.DeviceHistoryOffer
import com.floe.android.core.devicelink.FloeDeviceLinkAddress
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure capability/consent decisions for the frozen v2 extension. */
class AndroidHostScopeContractTest {
    private val task = UUID.fromString("10000000-0000-0000-0000-000000000001")
    private val peer = DeviceHistoryPeer(
        name = "Peer",
        address = FloeDeviceLinkAddress("0".repeat(64)),
        sharedConversations = setOf(task),
        workspaceShares = mapOf(task to "floe.workspace.v1.${"ab".repeat(32)}"),
    )

    private fun offer(workspaceSyncVersion: Int? = null, attachmentTransfer: Boolean? = null) =
        DeviceHistoryOffer(task, "Fixture", workspaceFiles = true, workspaceSyncVersion, attachmentTransfer)

    private fun catalog(attachmentTransfer: Boolean = true, offerFlag: Boolean? = true) =
        DeviceHistoryCatalog(
            offers = listOf(offer(attachmentTransfer = offerFlag)),
            historyPages = true,
            attachmentTransfer = attachmentTransfer,
        )

    private val authority = DeviceSyncAuthority(attachmentRestore = true, workspaceConvergence = true)

    @Test
    fun typedHistoryRequiresEveryAuthorityAndCapability() {
        val catalog = catalog()
        assertTrue(AndroidHostScopeContract.importsAttachments(authority, true, catalog, task))
        // Files not requested: text-only.
        assertFalse(AndroidHostScopeContract.importsAttachments(authority, false, catalog, task))
        // Local native lacks the v2 ABI.
        assertFalse(
            AndroidHostScopeContract.importsAttachments(
                authority.copy(attachmentRestore = false), true, catalog, task,
            ),
        )
        // Peer did not advertise the capability top-level.
        assertFalse(
            AndroidHostScopeContract.importsAttachments(authority, true, catalog(attachmentTransfer = false), task),
        )
        // Peer did not flag the selected offer.
        assertFalse(
            AndroidHostScopeContract.importsAttachments(authority, true, catalog(offerFlag = null), task),
        )
        // Catalog unavailable (never fetched).
        assertFalse(AndroidHostScopeContract.importsAttachments(authority, true, null, task))
    }

    @Test
    fun cursorNamespacesStayIndependentPerSelection() {
        assertEquals("peer", AndroidHostScopeContract.cursorPeer("peer", typedHistory = false))
        assertEquals("peer:attachments-v2", AndroidHostScopeContract.cursorPeer("peer", typedHistory = true))
    }

    @Test
    fun convergenceRequiresBothOptIns() {
        val optedIn = peer.copy(workspaceSyncVersions = mapOf(task to 2))
        // Both granted: converge.
        assertTrue(
            AndroidHostScopeContract.convergesWorkspace(authority, optedIn, task, offer(workspaceSyncVersion = 2)),
        )
        // Local never granted: keep-local even though the peer advertised.
        assertFalse(
            AndroidHostScopeContract.convergesWorkspace(authority, peer, task, offer(workspaceSyncVersion = 2)),
        )
        // Local granted but the peer does not propagate: keep-local.
        assertFalse(
            AndroidHostScopeContract.convergesWorkspace(authority, optedIn, task, offer(workspaceSyncVersion = null)),
        )
        // Consent without the workspace share does not converge.
        val noShare = optedIn.copy(workspaceShares = emptyMap())
        assertFalse(
            AndroidHostScopeContract.convergesWorkspace(authority, noShare, task, offer(workspaceSyncVersion = 2)),
        )
        // Wrong version value never converges.
        assertFalse(
            AndroidHostScopeContract.convergesWorkspace(
                authority, optedIn.copy(workspaceSyncVersions = mapOf(task to 1)), task,
                offer(workspaceSyncVersion = 2),
            ),
        )
    }

    @Test
    fun advertisementFollowsRealAuthorityOnly() {
        assertTrue(AndroidHostScopeContract.advertisesAttachmentTransfer(authority))
        assertFalse(AndroidHostScopeContract.advertisesAttachmentTransfer(authority.copy(attachmentRestore = false)))
    }
}
