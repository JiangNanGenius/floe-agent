// SPDX-License-Identifier: MPL-2.0
//
// A text-only share plan. No FileProvider, content URI or stream is used, so
// no app receives a handle into meeting storage. The plan contains exactly the
// two string extras below; the Android adapter must not add a stream or grant.
package com.floe.android.host.meetingexchange

internal data class MeetingSharePlan(
    val action: String,
    val mimeType: String,
    val subject: String,
    val text: String,
    val extras: Map<String, String>,
) {
    val byteCount: Long = text.toByteArray(Charsets.UTF_8).size.toLong()

    override fun toString(): String =
        "MeetingSharePlan(mime=$mimeType, bytes=$byteCount)"

    companion object {
        /** Mirrors android.content.Intent.ACTION_SEND without an Android dependency in tests. */
        const val ACTION_SEND = "android.intent.action.SEND"
        const val EXTRA_TEXT = "android.intent.extra.TEXT"
        const val EXTRA_SUBJECT = "android.intent.extra.SUBJECT"

        /**
         * Text is copied into the chooser's Binder transaction. This is much
         * smaller than the file cap; a larger meeting must be saved as a file
         * instead of risking a truncated/failed share.
         */
        const val MAX_SHARE_TEXT_BYTES = 256L * 1024L
    }
}

internal sealed interface MeetingSharePlanResult {
    data class Ready(val plan: MeetingSharePlan) : MeetingSharePlanResult

    data class Failed(val failure: MeetingExportFailure) : MeetingSharePlanResult
}

internal object MeetingSharePlanner {
    fun plan(
        document: MeetingExportDocument,
        labels: MeetingExportLabels,
    ): MeetingSharePlanResult {
        if (document.text.isBlank()) {
            return MeetingSharePlanResult.Failed(
                MeetingExportFailure(MeetingExportFailureCode.SHARE_FAILED),
            )
        }
        if (document.text.length > MeetingSharePlan.MAX_SHARE_TEXT_BYTES) {
            return MeetingSharePlanResult.Failed(
                MeetingExportFailure(MeetingExportFailureCode.SHARE_TOO_LARGE),
            )
        }
        val actualBytes = document.text.toByteArray(Charsets.UTF_8).size.toLong()
        if (document.byteCount <= 0L ||
            document.byteCount > MeetingSharePlan.MAX_SHARE_TEXT_BYTES ||
            actualBytes > MeetingSharePlan.MAX_SHARE_TEXT_BYTES
        ) {
            return MeetingSharePlanResult.Failed(
                MeetingExportFailure(MeetingExportFailureCode.SHARE_TOO_LARGE),
            )
        }
        val subject = shareSubject(document.title, labels.untitledMeeting)
        val extras = linkedMapOf(
            MeetingSharePlan.EXTRA_TEXT to document.text,
            MeetingSharePlan.EXTRA_SUBJECT to subject,
        )
        return MeetingSharePlanResult.Ready(
            MeetingSharePlan(
                action = MeetingSharePlan.ACTION_SEND,
                mimeType = document.format.mimeType,
                subject = subject,
                text = document.text,
                extras = extras,
            ),
        )
    }

    private fun shareSubject(raw: String, fallback: String): String {
        val cleaned = raw
            .map { if (it.isDisplayControl()) ' ' else it }
            .joinToString("")
            .replace(Regex("\\s+"), " ")
            .trim()
            .take(120)
            .trim()
        return cleaned.ifBlank { fallback }
    }

    private fun Char.isDisplayControl(): Boolean =
        isISOControl() || this in '\u202A'..'\u202E' || this in '\u2066'..'\u2069' ||
            this == '\u2028' || this == '\u2029' || this == '\u0085'
}
