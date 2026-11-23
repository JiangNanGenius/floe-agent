// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import com.floe.android.bridge.DeviceHistoryNative
import com.floe.android.bridge.DeviceHistoryNative.DeviceHistoryResult
import com.floe.android.core.devicelink.DeviceHistoryOffer
import java.util.UUID

/** Uses the ordinary native conversation store for the current App-owned generation. */
internal class AndroidNativeDeviceHistoryStore : DeviceHistoryLocalStore {
    override suspend fun localOffers(epoch: Long): List<DeviceHistoryOffer> =
        DeviceHistoryNative.localOffers(epoch).value().map { offer ->
            DeviceHistoryOffer(UUID.fromString(offer.id), offer.title)
        }

    override suspend fun exportHistory(epoch: Long, taskId: UUID): ByteArray =
        DeviceHistoryNative.exportHistory(epoch, taskId.toString()).value()

    override suspend fun importHistory(epoch: Long, taskId: UUID, bytes: ByteArray): Int {
        val receipt = DeviceHistoryNative.importHistory(epoch, taskId.toString(), bytes).value()
        if (!receipt.conversationID.equals(taskId.toString(), ignoreCase = true) || receipt.addedMessages < 0) {
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.IMPORT_UNCONFIRMED)
        }
        return receipt.addedMessages
    }

    private fun <T> DeviceHistoryResult<T>.value(): T = when (this) {
        is DeviceHistoryResult.Success -> value
        DeviceHistoryResult.Busy -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.BUSY_TASK)
        DeviceHistoryResult.Conflict -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.CONFLICT)
        DeviceHistoryResult.OutcomeUnknown -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.IMPORT_UNCONFIRMED)
        is DeviceHistoryResult.Unavailable -> throw DeviceHistoryLocalFailure(DeviceHistoryStatus.TRANSFER_FAILED)
    }
}
