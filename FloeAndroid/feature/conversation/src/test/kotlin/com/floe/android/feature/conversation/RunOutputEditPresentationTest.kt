// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Editor routing and exact session/card admission. */
class RunOutputEditPresentationTest {

    private val docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    private val xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    private val pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation"

    private fun supports(mime: String, name: String, bytes: Long = 128): Boolean =
        RunOutputEditPresentation.editableExtension(mime, name, bytes) != null

    @Test
    fun officeAgreementTableMatchesTheViewerGate() {
        assertTrue(supports(docx, "report.docx"))
        assertTrue(supports(xlsx, "sheet.xlsx"))
        assertTrue(supports(pptx, "deck.pptx"))
        // The publisher's documented octet-stream fallback stays usable.
        assertTrue(supports("application/octet-stream", "report.docx"))
        // Legacy trailing annotation keeps the real extension.
        assertTrue(supports(docx, "报告.docx（终稿）"))

        assertTrue(supports("text/markdown", "notes.md"))
        assertFalse(supports(xlsx, "report.docx"))
        assertFalse(supports("application/pdf", "paper.pdf"))
        assertFalse(supports(docx, "report.pdf"))
        assertFalse(supports("image/png", "poster.png"))
        assertFalse(supports("", "report.docx"))
        assertFalse(supports(docx, ""))
    }

    @Test
    fun lightweightTextStaysBoundedAndOfficeUsesAnExternalEditor() {
        assertTrue(supports("text/csv", "table.csv"))
        assertFalse(supports("text/plain", "large.txt", RunOutputEditPresentation.MAX_TEXT_BYTES + 1))
        assertFalse(RunOutputEditPresentation.opensExternally("md"))
        assertTrue(RunOutputEditPresentation.opensExternally("docx"))
    }

    @Test
    fun editRunOutputRejectsWithoutASession() {
        val holder = ConversationFlowHolder(RecordingHost(), "edit-fixture")
        val card = card()
        assertEquals(
            ConversationFlowResult.Rejected(ConversationRejectedReason.NO_SESSION),
            holder.editRunOutput(card),
        )
    }

    @Test
    fun editRunOutputAdmitsOnlyActionableCardsThroughTheWiredHost() {
        val calls = mutableListOf<Triple<String, String, String>>()
        val host = object : ConversationUiCallbacks by RecordingHost() {
            override val supportsRunOutputEditableCopy = true
            override fun editRunOutputCopy(session: ConversationSessionToken, runId: String, outputId: String): Boolean {
                calls += Triple(session.conversationId, runId, outputId)
                return true
            }
        }
        val holder = ConversationFlowHolder(host, "edit-fixture").also {
            it.applyHostSnapshot(threadState(it.session, rows = listOf(group(card()))))
        }
        assertEquals(ConversationFlowResult.Accepted, holder.editRunOutput(card()))
        assertEquals(listOf(Triple("edit-fixture", "run-1", "out-1")), calls)

        // A PDF is preview-only.
        val before = calls.size
        val textCard = card(mimeType = "application/pdf", displayName = "notes.pdf")
        val textHolder = ConversationFlowHolder(host, "edit-fixture").also {
            it.applyHostSnapshot(threadState(it.session, rows = listOf(group(textCard))))
        }
        assertEquals(
            ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE),
            textHolder.editRunOutput(textCard),
        )
        assertEquals(before, calls.size)

        // Unavailable card: refused even for an office type.
        val staleCard = card(availabilityRaw = "changed")
        val staleHolder = ConversationFlowHolder(host, "edit-fixture").also {
            it.applyHostSnapshot(threadState(it.session, rows = listOf(group(staleCard))))
        }
        assertEquals(
            ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE),
            staleHolder.editRunOutput(staleCard),
        )
        assertEquals(before, calls.size)
    }

    @Test
    fun editRunOutputRejectsWhenTheHostSeamIsNotWired() {
        val holder = ConversationFlowHolder(RecordingHost(), "edit-fixture").also {
            it.applyHostSnapshot(threadState(it.session, rows = listOf(group(card()))))
        }
        assertEquals(
            ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE),
            holder.editRunOutput(card()),
        )
    }

    private fun group(card: RunOutputCardUi) = TimelineRowUi.RunOutputGroup("run-1", listOf(card))

    private fun card(
        mimeType: String = docx,
        displayName: String = "report.docx",
        availabilityRaw: String = "available",
    ) = RunOutputCardUi(
        runId = "run-1",
        outputId = "out-1",
        producerCallId = "call-1",
        displayName = displayName,
        mimeType = mimeType,
        byteCount = 128,
        availabilityRaw = availabilityRaw,
    )
}
