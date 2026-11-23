// SPDX-License-Identifier: MPL-2.0
//
// Preparation reads exactly one meeting through the existing MeetingManager
// facade. It never lists the catalog and never accepts a caller-supplied path.
package com.floe.android.host.meetingexchange

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingErrorCode
import com.floe.android.host.meeting.MeetingException
import com.floe.android.host.meeting.MeetingIds
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal class MeetingExportService(
    private val readMeeting: suspend (String) -> MeetingDetail,
    private val labels: MeetingExportLabels,
    private val zoneId: ZoneId = ZoneId.systemDefault(),
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val renderDocument: (MeetingExportSnapshot, MeetingExportFormat) -> MeetingExportDocument =
        { _, _ -> throw MeetingExportSizeException() },
) {
    suspend fun prepare(
        meetingId: String,
        format: MeetingExportFormat,
    ): MeetingExportPreparationResult {
        val id = try {
            MeetingIds.require(meetingId)
        } catch (_: MeetingException) {
            return MeetingExportPreparationResult.Failed(
                MeetingExportFailure(MeetingExportFailureCode.INVALID_IDENTIFIER),
            )
        }
        return withContext(dispatcher) {
            val detail = try {
                readMeeting(id)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: MeetingException) {
                return@withContext MeetingExportPreparationResult.Failed(readFailure(error))
            } catch (_: Exception) {
                return@withContext MeetingExportPreparationResult.Failed(
                    MeetingExportFailure(MeetingExportFailureCode.READ_FAILED, retryable = true),
                )
            }
            if (detail.id != id) {
                return@withContext MeetingExportPreparationResult.Failed(
                    MeetingExportFailure(MeetingExportFailureCode.IDENTITY_MISMATCH),
                )
            }
            try {
                val snapshot = MeetingExportSnapshot.from(detail)
                MeetingExportPreparationResult.Ready(
                    if (format.isText) {
                        MeetingExportFormatter.format(
                            snapshot = snapshot,
                            format = format,
                            labels = labels,
                            zoneId = zoneId,
                        )
                    } else {
                        renderDocument(snapshot, format)
                    },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: MeetingExportSizeException) {
                MeetingExportPreparationResult.Failed(
                    MeetingExportFailure(MeetingExportFailureCode.TOO_LARGE),
                )
            } catch (_: Exception) {
                MeetingExportPreparationResult.Failed(
                    MeetingExportFailure(MeetingExportFailureCode.READ_FAILED, retryable = true),
                )
            }
        }
    }

    private fun readFailure(error: MeetingException): MeetingExportFailure = when (error.code) {
        MeetingErrorCode.INVALID_IDENTIFIER ->
            MeetingExportFailure(MeetingExportFailureCode.INVALID_IDENTIFIER)
        MeetingErrorCode.NOT_FOUND ->
            MeetingExportFailure(MeetingExportFailureCode.NOT_FOUND)
        MeetingErrorCode.TOO_LARGE ->
            MeetingExportFailure(MeetingExportFailureCode.TOO_LARGE)
        else -> MeetingExportFailure(
            MeetingExportFailureCode.READ_FAILED,
            retryable = error.error.retryable,
        )
    }
}
