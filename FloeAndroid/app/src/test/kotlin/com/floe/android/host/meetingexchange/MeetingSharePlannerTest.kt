// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeetingSharePlannerTest {
    private val document = MeetingExportTestFixtures.document(
        MeetingExportTestFixtures.detail(
            title = "Share plan",
            notes = "Shared notes",
            segments = listOf(
                MeetingExportTestFixtures.segment(1_000L, 2_000L, "Shared transcript"),
            ),
        ),
    )

    private fun planned(document: MeetingExportDocument): MeetingSharePlan {
        val result = MeetingSharePlanner.plan(document, MeetingExportTestFixtures.LABELS)
        assertTrue(result is MeetingSharePlanResult.Ready)
        return (result as MeetingSharePlanResult.Ready).plan
    }

    @Test
    fun sharePlanIsTextOnlyAndCarriesExactlyTextAndSubject() {
        val plan = planned(document)
        assertEquals(MeetingSharePlan.ACTION_SEND, plan.action)
        assertEquals("text/plain", plan.mimeType)
        assertEquals(document.text, plan.text)
        assertEquals(document.title, plan.subject)
        assertEquals(
            setOf(MeetingSharePlan.EXTRA_TEXT, MeetingSharePlan.EXTRA_SUBJECT),
            plan.extras.keys,
        )
        assertFalse(plan.extras.containsKey("android.intent.extra.STREAM"))
        assertFalse(plan.extras.keys.any { it.contains("STREAM") })
        assertFalse(plan.toString().contains("Shared notes"))
        assertFalse(plan.toString().contains("Shared transcript"))
    }

    @Test
    fun markdownUsesMarkdownMimeAndStillHasNoAttachment() {
        val markdown = MeetingExportTestFixtures.document(
            MeetingExportTestFixtures.detail(title = "Markdown share"),
            MeetingExportFormat.MARKDOWN,
        )
        val plan = planned(markdown)
        assertEquals("text/markdown", plan.mimeType)
        assertEquals(
            setOf(MeetingSharePlan.EXTRA_TEXT, MeetingSharePlan.EXTRA_SUBJECT),
            plan.extras.keys,
        )
    }

    @Test
    fun shareSubjectRemovesControlsAndBidirectionalOverrides() {
        val unsafe = MeetingExportTestFixtures.document(
            MeetingExportTestFixtures.detail(
                title = "Line\nBreak \u202Eevil\u2066",
            ),
        )
        val plan = planned(unsafe)
        assertFalse(plan.subject.contains('\n'))
        assertFalse(plan.subject.contains('\u202E'))
        assertFalse(plan.subject.contains('\u2066'))
        assertTrue(plan.subject.contains("Line Break"))
    }

    @Test
    fun oversizedTextIsRefusedInsteadOfRiskingATruncatedShare() {
        val large = MeetingExportTestFixtures.document(
            MeetingExportTestFixtures.detail(
                notes = "a".repeat((MeetingSharePlan.MAX_SHARE_TEXT_BYTES + 1).toInt()),
            ),
        )
        val result = MeetingSharePlanner.plan(large, MeetingExportTestFixtures.LABELS)
        assertEquals(
            MeetingExportFailureCode.SHARE_TOO_LARGE,
            (result as MeetingSharePlanResult.Failed).failure.code,
        )
    }

    @Test
    fun planByteCountMatchesTheActualUtf8Payload() {
        val plan = planned(document)
        assertEquals(plan.text.toByteArray(Charsets.UTF_8).size.toLong(), plan.byteCount)
        assertEquals(document.byteCount, plan.byteCount)
    }

    @Test
    fun anInconsistentByteCountCannotBypassTheShareLimit() {
        val text = "x".repeat((MeetingSharePlan.MAX_SHARE_TEXT_BYTES + 1).toInt())
        val inconsistent = MeetingExportDocument(
            meetingId = MeetingExportTestFixtures.MEETING_ID,
            meetingRevision = 1L,
            title = "Inconsistent",
            format = MeetingExportFormat.TXT,
            suggestedFileName = "Inconsistent.txt",
            text = text,
            binary = null,
            byteCount = 1L,
            hasNotes = true,
            hasTranscript = false,
        )
        val result = MeetingSharePlanner.plan(inconsistent, MeetingExportTestFixtures.LABELS)
        assertEquals(
            MeetingExportFailureCode.SHARE_TOO_LARGE,
            (result as MeetingSharePlanResult.Failed).failure.code,
        )
    }
}
