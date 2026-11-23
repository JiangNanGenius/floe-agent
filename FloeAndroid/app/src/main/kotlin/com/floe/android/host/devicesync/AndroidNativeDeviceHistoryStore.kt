// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import com.floe.android.bridge.DeviceHistoryNative
import com.floe.android.bridge.DeviceHistoryNative.DeviceHistoryResult
import com.floe.android.core.devicelink.DeviceHistoryOffer
import com.floe.android.core.devicelink.DeviceHistoryPage
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import java.util.UUID

/** Uses the ordinary native conversation store for the current App-owned generation. */
internal class AndroidNativeDeviceHistoryStore : DeviceHistoryLocalStore {
    override suspend fun localOffers(epoch: Long): List<DeviceHistoryOffer> =
        DeviceHistoryNative.localOffers(epoch).value().map { offer ->
            DeviceHistoryOffer(UUID.fromString(offer.id), offer.title)
        }

    override suspend fun exportHistory(epoch: Long, taskId: UUID): ByteArray =
        DeviceHistoryNative.exportHistory(epoch, taskId.toString()).value()

    override suspend fun importHistory(epoch: Long, taskId: UUID, bytes: ByteArray): Int =
        DeviceHistoryNative.importHistory(epoch, taskId.toString(), bytes).value().addedFor(taskId)

    override suspend fun storedCursor(epoch: Long, peerId: String, taskId: UUID): String? =
        DeviceHistoryNative.storedCursor(epoch, peerId, taskId.toString()).value()

    override suspend fun exportPage(epoch: Long, taskId: UUID, after: String?, through: Long?): DeviceHistoryPage {
        val result = DeviceHistoryNative.exportPage(epoch, taskId.toString(), after, through)
        val error = when (result) {
            is DeviceHistoryResult.Unavailable -> when (result.status) {
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
        epoch: Long, peerId: String, taskId: UUID, page: DeviceHistoryPage,
    ): Int = DeviceHistoryNative.importPage(epoch, peerId, taskId.toString(), page.bytes, page.nextCursor)
        .value().addedFor(taskId)

    private fun DeviceHistoryNative.DeviceHistoryImportReceipt.addedFor(taskId: UUID): Int {
        if (!conversationID.equals(taskId.toString(), ignoreCase = true) || addedMessages < 0) {
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.IMPORT_UNCONFIRMED)
        }
        return addedMessages
    }

    private fun <T> DeviceHistoryResult<T>.value(): T = when (this) {
        is DeviceHistoryResult.Success -> value
        DeviceHistoryResult.Busy -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.BUSY_TASK)
        DeviceHistoryResult.Conflict -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.CONFLICT)
        DeviceHistoryResult.OutcomeUnknown -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.IMPORT_UNCONFIRMED)
        DeviceHistoryResult.CursorExpired -> throw DeviceHistorySyncException(DeviceHistorySyncError.CURSOR_EXPIRED)
        is DeviceHistoryResult.Unavailable -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
    }
}
