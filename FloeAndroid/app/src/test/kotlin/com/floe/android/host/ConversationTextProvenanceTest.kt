// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Regression for the original journal's single intro rendered twice. */
class ConversationTextProvenanceTest {
    private val task = "11111111-1111-1111-1111-111111111111"
    private val run = "22222222-2222-2222-2222-222222222222"
    private fun builder() = ThreadProjectionBuilder(task).also { it.selectedRunId = run }
    private fun event(b: ThreadProjectionBuilder, sequence: Long, text: String, reasoning: Boolean = false) {
        b.applyRunEvent(HostRunEventFrame(run, sequence, if (reasoning) "reasoning" else "assistantText",
            buildJsonObject { put("text", text) }, text.length))
    }
    private fun snapshot(base: Long, through: Long, text: String, revision: Long,
                         reasoning: Boolean = false, watermark: Long = 0): ConversationWire.SnapshotPage {
        val kind = if (reasoning) "reasoning" else "answer"
        return checkNotNull(ConversationWire.decodeSnapshotPage(buildJsonObject {
            put("runID", run); put("conversationID", task); put("durableState", "streamingModel")
            putJsonObject("revision") { put("resourceID", "run.$run"); put("version", "streamingModel") }
            put("isTerminal", false); put("liveOwner", true); put("textRevision", revision)
            put("durableWatermark", watermark)
            put("${kind}Text", text); put("${kind}BaseSequence", base); put("${kind}DurableSequence", through)
        }))
    }

    @Test fun oldPrefixAfterLaterDurableParagraphIsNotAppendedAgain() {
        val b = builder(); event(b, 1, "Alpha"); event(b, 2, "BetaBeta")
        b.applySnapshotLiveText(snapshot(0, 1, "Alpha", 1))
        assertEquals("AlphaBetaBeta", b.build().liveAssistantText)
    }

    @Test fun newStepMayLegitimatelyRepeatTheOriginalWords() {
        val b = builder(); event(b, 1, "Alpha"); event(b, 2, "BetaBeta")
        b.applySnapshotLiveText(snapshot(2, 2, "Alpha", 3))
        assertEquals("AlphaBetaBetaAlpha", b.build().liveAssistantText)
    }

    @Test fun actualStepOverlayReplacesOnlyItsOwnFlushedPrefix() {
        val b = builder(); event(b, 1, "Alpha"); event(b, 2, "Beta")
        b.applySnapshotLiveText(snapshot(0, 2, "AlphaBetaGamma", 3))
        assertEquals("AlphaBetaGamma", b.build().liveAssistantText)
        event(b, 3, "Gamma")
        assertEquals("AlphaBetaGamma", b.build().liveAssistantText)
        b.applySnapshotLiveText(snapshot(0, 3, "AlphaBetaGammaDelta", 5))
        assertEquals("AlphaBetaGammaDelta", b.build().liveAssistantText)
    }

    @Test fun olderSnapshotCannotReplaceANewerStepEvenWithALaterReadWatermark() {
        val b = builder(); event(b, 1, "Alpha"); event(b, 2, "Beta")
        b.applySnapshotLiveText(snapshot(2, 2, "Alpha", 10))
        b.applySnapshotLiveText(snapshot(0, 1, "Alpha", 9, watermark = 999))
        assertEquals("AlphaBetaAlpha", b.build().liveAssistantText)
    }

    @Test fun boundedSnapshotPrefixNeverErasesFullDurableText() {
        val b = builder(); val text = "汉字🌍".repeat(1000); event(b, 1, text)
        b.applySnapshotLiveText(snapshot(0, 1, "汉字", 3))
        assertEquals(text, b.build().liveAssistantText)
    }

    @Test fun realRepeatedWordsAndDuplicateEventReplayHaveDifferentIdentities() {
        val b = builder(); event(b, 1, "Alpha")
        b.applySnapshotLiveText(snapshot(0, 1, "AlphaAlpha", 2))
        event(b, 1, "Alpha")
        assertEquals("AlphaAlpha", b.build().liveAssistantText)
    }

    @Test fun retiredRunCannotBeRevivedByALateTextSnapshot() {
        val b = builder(); event(b, 1, "Alpha"); b.closeLiveTail(run)
        b.applySnapshotLiveText(snapshot(0, 1, "AlphaLater", 99))
        assertEquals("", b.build().liveAssistantText)
    }
}
