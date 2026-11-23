// SPDX-License-Identifier: MPL-2.0
//
// Public host API for meeting export and sharing. The UI owns selection and
// composition; this class only acts on the meeting id it is given.
//
// ```kotlin
// val exchange = remember { MeetingExchange(context) }
// val launcher = rememberLauncherForActivityResult(
//     ActivityResultContracts.StartActivityForResult(),
// ) { result ->
//     val request = documentRequest ?: return@rememberLauncherForActivityResult
//     documentRequest = null
//     when (val accepted = exchange.acceptDocumentActivityResult(
//         request = request,
//         resultOk = result.resultCode == Activity.RESULT_OK,
//         resultIntent = result.data,
//         selectedMeetingId = selectedMeetingId,
//     )) {
//         is MeetingDocumentDestinationResult.Ready -> scope.launch {
//             when (val written = exchange.writeDocument(accepted.target, selectedMeetingId)) {
//                 is MeetingDocumentWriteResult.Written -> notice = exchange.savedMessage()
//                 is MeetingDocumentWriteResult.Failed ->
//                     notice = exchange.failureMessage(written.failure)
//             }
//         }
//         MeetingDocumentDestinationResult.Cancelled -> Unit
//         is MeetingDocumentDestinationResult.Rejected ->
//             notice = exchange.failureMessage(accepted.failure)
//     }
// }
// // On the explicit export action:
// when (val prepared = exchange.prepare(meetingId, MeetingExportFormat.MARKDOWN)) {
//     is MeetingExportPreparationResult.Ready -> {
//         val created = exchange.documentRequest(prepared.document)
//         documentRequest = created
//         launcher.launch(exchange.createDocumentIntent(created))
//     }
//     is MeetingExportPreparationResult.Failed -> notice = exchange.failureMessage(prepared.failure)
// }
// // Sharing:
// when (val shared = exchange.shareText(document, context)) {
//     MeetingShareResult.ChooserOpened -> notice = exchange.shareOpenedMessage()
//     is MeetingShareResult.Failed -> notice = exchange.failureMessage(shared.failure)
// }
// ```
package com.floe.android.host.meetingexchange

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.floe.android.R
import com.floe.android.host.meeting.MeetingManager
import java.io.File
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Public, UI-facing entry point. One instance may be reused by a screen. */
class MeetingExchange(
    context: Context,
    manager: MeetingManager = MeetingManager(context),
    private val zoneId: ZoneId = ZoneId.systemDefault(),
) : AutoCloseable {
    private val appContext: Context = context.applicationContext
    private val labels: MeetingExportLabels = meetingExportLabels(appContext)
    private val exporter = MeetingExportService(
        readMeeting = { meetingId -> manager.meeting(meetingId) },
        labels = labels,
        zoneId = zoneId,
        renderDocument = { snapshot, format ->
            MeetingDocumentExport.render(snapshot, format, labels, zoneId)
        },
    )
    private val stager = MeetingExportStager(File(appContext.cacheDir, "meeting-exports"))
    private val writer = MeetingDocumentWriter(stager)

    /**
     * Resolves exactly [meetingId] through the existing meeting store and
     * renders its persisted title, metadata, notes and current transcript.
     * Empty notes/transcript are successful, explicit states; a missing or
     * unreadable meeting is a typed failure. Nothing is written by this call.
     */
    suspend fun prepare(
        meetingId: String,
        format: MeetingExportFormat,
    ): MeetingExportPreparationResult = exporter.prepare(meetingId, format)

    /** Binds one prepared document to a new opaque picker request id. */
    fun documentRequest(document: MeetingExportDocument): MeetingDocumentRequest =
        MeetingDocumentExchange.request(document)

    /** Standard system create-document intent for [request]. */
    fun createDocumentIntent(request: MeetingDocumentRequest): Intent =
        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = request.mimeType
            putExtra(Intent.EXTRA_TITLE, request.suggestedFileName)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }

    /**
     * The raw Activity result flags. Pass the matching result Intent here; a
     * missing/false value rejects the destination before any write. Some
     * providers may return no flag even with a live grant; in that case the
     * user sees a typed permission error rather than an unverified write.
     */
    fun hasDocumentWriteGrant(resultIntent: Intent?): Boolean =
        resultIntent?.flags?.and(Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0

    /** Raw URI from a successful Activity result, or null when cancelled. */
    fun documentUri(resultIntent: Intent?): String? = resultIntent?.dataString

    /**
     * Accepts a picker result only when [selectedMeetingId] still equals the
     * request's meeting. A stale/old result is rejected; it can never export
     * a different meeting.
     */
    fun acceptDocumentResult(
        request: MeetingDocumentRequest,
        resultOk: Boolean,
        uri: String?,
        hasWriteGrant: Boolean,
        selectedMeetingId: String?,
    ): MeetingDocumentDestinationResult = MeetingDocumentExchange.accept(
        request = request,
        resultOk = resultOk,
        uri = uri,
        hasWriteGrant = hasWriteGrant,
        selectedMeetingId = selectedMeetingId,
    )

    /**
     * Convenience overload for the raw Activity result: extracts both the
     * destination URI and its write grant from the same returned Intent so a
     * caller cannot forget either check.
     */
    fun acceptDocumentActivityResult(
        request: MeetingDocumentRequest,
        resultOk: Boolean,
        resultIntent: Intent?,
        selectedMeetingId: String?,
    ): MeetingDocumentDestinationResult = acceptDocumentResult(
        request = request,
        resultOk = resultOk,
        uri = documentUri(resultIntent),
        hasWriteGrant = hasDocumentWriteGrant(resultIntent),
        selectedMeetingId = selectedMeetingId,
    )

    /**
     * Writes the accepted snapshot to its user-selected URI. The destination
     * must be empty, the write is streamed in chunks, and success requires an
     * exact read-back. A partial/failed write returns a typed failure.
     * Coroutine cancellation propagates after staging cleanup and is never a
     * saved result.
     */
    suspend fun writeDocument(
        target: MeetingDocumentTarget,
        selectedMeetingId: String?,
    ): MeetingDocumentWriteResult = withContext(Dispatchers.IO) {
        val uri = try {
            Uri.parse(target.uri)
        } catch (_: Exception) {
            return@withContext MeetingDocumentWriteResult.Failed(
                MeetingExportFailure(MeetingExportFailureCode.INVALID_DESTINATION),
            )
        }
        writer.write(
            target = target,
            selectedMeetingId = selectedMeetingId,
            openOutput = { appContext.contentResolver.openOutputStream(uri, "wt") },
            openReadback = { appContext.contentResolver.openInputStream(uri) },
        )
    }

    /**
     * Launches the system share chooser with text only. No stream, FileProvider
     * URI or content grant is attached. [ChooserOpened] means only that the OS
     * chooser started; it never asserts a recipient saved or received data.
     * Prefer an Activity context; an application context is given NEW_TASK.
     */
    fun shareText(
        document: MeetingExportDocument,
        context: Context = appContext,
    ): MeetingShareResult {
        val plan = when (val result = MeetingSharePlanner.plan(document, labels)) {
            is MeetingSharePlanResult.Ready -> result.plan
            is MeetingSharePlanResult.Failed -> return MeetingShareResult.Failed(result.failure)
        }
        val send = Intent(plan.action).apply {
            type = plan.mimeType
            putExtra(Intent.EXTRA_TEXT, plan.text)
            putExtra(Intent.EXTRA_SUBJECT, plan.subject)
        }
        val chooser = Intent.createChooser(
            send,
            appContext.getString(R.string.meeting_exchange_share_chooser),
        )
        if (context !is Activity) {
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            context.startActivity(chooser)
            MeetingShareResult.ChooserOpened
        } catch (_: Exception) {
            MeetingShareResult.Failed(MeetingExportFailure(MeetingExportFailureCode.SHARE_FAILED))
        }
    }

    fun failureMessage(failure: MeetingExportFailure): String =
        MeetingExportText.message(appContext, failure.code)

    fun formatLabel(format: MeetingExportFormat): String =
        MeetingExportText.formatLabel(appContext, format)

    fun savedMessage(): String = appContext.getString(R.string.meeting_exchange_saved)

    fun shareOpenedMessage(): String = appContext.getString(R.string.meeting_exchange_share_opened)

    /** Discards stale private staging copies; a recent in-flight write is retained. */
    override fun close() {
        stager.sweep()
    }
}
