// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import com.floe.android.bridge.DeviceHistoryNative
import com.floe.android.core.devicelink.DeviceHistoryAttachmentSource
import com.floe.android.core.devicelink.DeviceHistoryOffer
import com.floe.android.core.devicelink.DeviceHistoryPage
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import java.util.UUID

/**
 * Uses the ordinary native conversation store for the current App-owned
 * generation. Versioned lanes route through [AndroidHostBridgeClient]; the
 * legacy v1 byte path stays on the original `DeviceHistoryNative` wrappers so
 * old-peer behavior is untouched.
 */
internal class AndroidNativeDeviceHistoryStore(
    private val bridge: AndroidHostBridgeClient = AndroidHostBridgeClient(),
) : DeviceHistoryLocalStore {

    override suspend fun localOffers(epoch: Long): List<DeviceHistoryOffer> =
        DeviceHistoryNative.localOffers(epoch).value().map { offer ->
            DeviceHistoryOffer(UUID.fromString(offer.id), offer.title)
        }

    override suspend fun exportHistory(epoch: Long, taskId: UUID, version: Int): ByteArray =
        if (version == 2) {
            when (val result = bridge.exportHistory(epoch, taskId, version)) {
                is AndroidHostBridgeClient.Result.Success -> result.value
                AndroidHostBridgeClient.Result.CapabilityMissing ->
                    throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
                is AndroidHostBridgeClient.Result.Unavailable -> throw failureFor(result.status)
            }
        } else {
            DeviceHistoryNative.exportHistory(epoch, taskId.toString()).value()
        }

    override suspend fun importHistory(epoch: Long, taskId: UUID, bytes: ByteArray, version: Int): Int =
        if (version == 2) {
            when (val result = bridge.importWhole(epoch, taskId, bytes, version)) {
                is AndroidHostBridgeClient.Result.Success -> result.value
                AndroidHostBridgeClient.Result.CapabilityMissing ->
                    throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
                is AndroidHostBridgeClient.Result.Unavailable -> throw failureFor(result.status)
            }
        } else {
            DeviceHistoryNative.importHistory(epoch, taskId.toString(), bytes).value().addedFor(taskId)
        }

    override suspend fun storedCursor(epoch: Long, peerId: String, taskId: UUID): String? =
        DeviceHistoryNative.storedCursor(epoch, peerId, taskId.toString()).value()

    override suspend fun exportPage(
        epoch: Long, taskId: UUID, after: String?, through: Long?, version: Int,
    ): DeviceHistoryPage {
        if (version == 2) {
            return when (val result = bridge.exportPage(epoch, taskId, after, through, version)) {
                is AndroidHostBridgeClient.Result.Success -> result.value
                AndroidHostBridgeClient.Result.CapabilityMissing ->
                    throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
                is AndroidHostBridgeClient.Result.Unavailable -> throw failureFor(result.status)
            }
        }
        val result = DeviceHistoryNative.exportPage(epoch, taskId.toString(), after, through)
        val error = when (result) {
            is DeviceHistoryNative.DeviceHistoryResult.Unavailable -> when (result.status) {
                -805 -> DeviceHistorySyncError.NOT_SHARED
                -808 -> DeviceHistorySyncError.TOO_LARGE
                else -> null
            }
            else -> null
        }
        if (error != null) throw DeviceHistorySyncException(error)
        val page = result.value()
        return DeviceHistoryPage(page.bytes, page.nextCursor, page.through, page.hasMore)
    }

    override suspend fun importPage(
        epoch: Long, peerId: String, taskId: UUID, page: DeviceHistoryPage, version: Int,
    ): Int = if (version == 2) {
        when (val result = bridge.importPage(epoch, peerId, taskId, page.bytes, page.nextCursor, version)) {
            is AndroidHostBridgeClient.Result.Success -> result.value
            AndroidHostBridgeClient.Result.CapabilityMissing ->
                throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
            is AndroidHostBridgeClient.Result.Unavailable -> throw failureFor(result.status)
        }
    } else {
        DeviceHistoryNative.importPage(epoch, peerId, taskId.toString(), page.bytes, page.nextCursor)
            .value().addedFor(taskId)
    }

    // ------------------------------------------------------------------
    // Verified attachment lanes (frozen v2 extension)
    // ------------------------------------------------------------------

    /** Opens one attachment byte ticket for the serving session. */
    suspend fun attachmentOpen(epoch: Long, taskId: UUID, attachmentId: UUID): Long =
        when (val result = bridge.attachmentOpen(epoch, taskId, attachmentId)) {
            is AndroidHostBridgeClient.Result.Success -> result.value
            AndroidHostBridgeClient.Result.CapabilityMissing ->
                throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
            is AndroidHostBridgeClient.Result.Unavailable -> throw failureFor(result.status)
        }

    /** Reads exactly [count] bytes at [offset] from an open attachment ticket. */
    suspend fun attachmentRead(ticket: Long, offset: Long, count: Int): ByteArray =
        when (val result = bridge.attachmentRead(ticket, offset, count)) {
            is AndroidHostBridgeClient.Result.Success -> result.value
            AndroidHostBridgeClient.Result.CapabilityMissing ->
                throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
            is AndroidHostBridgeClient.Result.Unavailable -> throw failureFor(result.status)
        }

    fun attachmentClose(ticket: Long) = bridge.attachmentClose(ticket)

    suspend fun pendingAttachments(epoch: Long, taskId: UUID): List<AndroidHostBridgeClient.PendingAttachment> =
        when (val result = bridge.pendingAttachments(epoch, taskId)) {
            is AndroidHostBridgeClient.Result.Success -> result.value
            AndroidHostBridgeClient.Result.CapabilityMissing -> emptyList()
            is AndroidHostBridgeClient.Result.Unavailable ->
                throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
        }

    suspend fun restoreAttachment(
        epoch: Long, taskId: UUID, item: AndroidHostBridgeClient.PendingAttachment, bytes: ByteArray,
    ): Boolean = when (val result = bridge.restoreAttachment(epoch, taskId, item, bytes)) {
        is AndroidHostBridgeClient.Result.Success -> result.value
        AndroidHostBridgeClient.Result.CapabilityMissing -> false
        is AndroidHostBridgeClient.Result.Unavailable -> {
            android.util.Log.w("FloeWorkspaceSync", "stage=attachmentRestore status=${result.status}")
            false
        }
    }

    private fun failureFor(status: Int): DeviceHistoryLocalFailure = when (status) {
        -806 -> DeviceHistoryLocalFailure(DeviceHistoryStatus.CONFLICT)
        -808 -> DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
        -815 -> DeviceHistoryLocalFailure(DeviceHistoryStatus.CURSOR_EXPIRED)
        -810 -> DeviceHistoryLocalFailure(DeviceHistoryStatus.BUSY_TASK)
        else -> DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
    }

    private fun DeviceHistoryNative.DeviceHistoryImportReceipt.addedFor(taskId: UUID): Int {
        if (!conversationID.equals(taskId.toString(), ignoreCase = true) || addedMessages < 0) {
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.IMPORT_UNCONFIRMED)
        }
        return addedMessages
    }

    private fun <T> DeviceHistoryNative.DeviceHistoryResult<T>.value(): T = when (this) {
        is DeviceHistoryNative.DeviceHistoryResult.Success -> value
        DeviceHistoryNative.DeviceHistoryResult.Busy -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.BUSY_TASK)
        DeviceHistoryNative.DeviceHistoryResult.Conflict -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.CONFLICT)
        DeviceHistoryNative.DeviceHistoryResult.OutcomeUnknown ->
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.IMPORT_UNCONFIRMED)
        DeviceHistoryNative.DeviceHistoryResult.CursorExpired ->
            throw DeviceHistorySyncException(DeviceHistorySyncError.CURSOR_EXPIRED)
        is DeviceHistoryNative.DeviceHistoryResult.Unavailable ->
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
    }
}
