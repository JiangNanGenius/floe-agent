// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.floe.android.core.notesmedia.pdf.PdfDocumentSession
import com.floe.android.core.officeengine.pdf.OfficePdfPrintFlow
import com.floe.android.core.officeengine.pdf.PrintFinish
import com.floe.android.core.officeengine.pdf.PrintStartOutcome

/**
 * Printing adapter over the EXISTING system-print path.
 *
 * The module does not compose a second print pipeline: it hands the verified
 * source snapshot to `:core:officeengine`'s qualified
 * [OfficePdfPrintFlow]/[com.floe.android.core.officeengine.pdf.OfficePdfPrintAdapter],
 * which pins one no-follow descriptor, copies the verified PDF bytes unchanged
 * (no rasterization) and settles exactly one terminal. The only work here is:
 *  - refusing while the session is closed,
 *  - hopping to the main thread (the platform dialog belongs to the
 *    foreground Activity),
 *  - mapping outcomes to the module's path-free vocabulary.
 *
 * "Dialog opened" is NOT "printed": the caller must not report a physical print
 * job from [NotesPrintStart.DIALOG_OPENED].
 */
enum class NotesPrintStart {
    DIALOG_OPENED,
    NO_PRINT_SERVICE,
    SOURCE_UNAVAILABLE,
    ACTIVITY_RETIRED,
    SESSION_CLOSED,
}

enum class NotesPrintFinish {
    /** The framework finished the job and the adapter released its descriptor. */
    ADAPTER_FINISHED,

    /** The dialog never started; the given start outcome names why. */
    START_ABORTED,
}

object NotesPrintBridge {

    /**
     * Requests the system print dialog for [session]'s verified source.
     * Safe to call from any thread; everything real runs on the main thread.
     */
    fun print(
        context: Context,
        session: PdfDocumentSession,
        documentLabel: String,
        onResult: (NotesPrintStart) -> Unit,
        onFinished: ((NotesPrintFinish) -> Unit)? = null,
    ) {
        val appContext = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        main.post {
            if (session.isClosed) {
                onResult(NotesPrintStart.SESSION_CLOSED)
                onFinished?.invoke(NotesPrintFinish.START_ABORTED)
                return@post
            }
            OfficePdfPrintFlow.requestPrint(
                context = appContext,
                source = session.source,
                pageCount = session.pageCount,
                documentLabel = documentLabel,
                onFinished = { finish ->
                    onFinished?.invoke(
                        when (finish) {
                            is PrintFinish.AdapterFinished -> NotesPrintFinish.ADAPTER_FINISHED
                            is PrintFinish.StartAborted -> NotesPrintFinish.START_ABORTED
                        },
                    )
                },
                onResult = { outcome ->
                    onResult(
                        when (outcome) {
                            is PrintStartOutcome.DialogOpened -> NotesPrintStart.DIALOG_OPENED
                            is PrintStartOutcome.NoPrintService -> NotesPrintStart.NO_PRINT_SERVICE
                            is PrintStartOutcome.SourceUnavailable -> NotesPrintStart.SOURCE_UNAVAILABLE
                            is PrintStartOutcome.ActivityRetired -> NotesPrintStart.ACTIVITY_RETIRED
                        },
                    )
                },
            )
        }
    }
}
