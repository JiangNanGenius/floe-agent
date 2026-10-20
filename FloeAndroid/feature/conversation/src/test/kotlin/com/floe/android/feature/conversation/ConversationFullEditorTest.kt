// SPDX-License-Identifier: MPL-2.0
//
// Full-screen composer editor tests (Main's required repair #1): the expand
// destination binds the SAME holder draft state — one text/caret/generation
// and ONE send pipeline — with the source's guarded rules: Done/Back only
// dismisses, the send guard mirrors the inline ComposerSendPolicy (blank,
// IME marked composition, provider, attachments processing), the shared
// bounded edit history is RAM-only, and the entry rule follows the "no
// longer fits the inline cap" trigger. Pure JVM: no Compose runtime, no
// device. The sheet composable itself is verified on the component UI host;
// everything decidable without a view tree is pinned here.

package com.floe.android.feature.conversation

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationFullEditorTest {

    private fun holder(host: RecordingHost): ConversationFlowHolder {
        val h = ConversationFlowHolder(host, "conv-1")
        h.applyHostSnapshot(threadState(h.session))
        return h
    }

    /* ------------------------------ entry policy ------------------------------ */

    @Test
    fun entryAppearsOnlyWhenDraftExceedsInlineCap() {
        val maxLines = FloeLayoutProbe.regularMaxLines
        val width = 480f // approx field width on a compact window
        assertFalse(
            FullEditorPolicy.shouldOfferFullEditor("short one-liner", maxLines, width),
        )
        val manyLines = List(maxLines + 1) { "line $it" }.joinToString("\n")
        assertTrue(FullEditorPolicy.shouldOfferFullEditor(manyLines, maxLines, width))
        // Soft wrapping counts too: one long paragraph beyond the cap.
        val longParagraph = "x".repeat(maxLines * 60 + 60)
        assertTrue(FullEditorPolicy.shouldOfferFullEditor(longParagraph, maxLines, width))
        // Exactly at the cap: hidden (⇄ "short prompts keep the calm row").
        val exactlyCap = "x".repeat(maxLines * 55)
        assertFalse(FullEditorPolicy.shouldOfferFullEditor(exactlyCap, maxLines, width))
    }

    @Test
    fun footerCountsMatchTheOriginalEstimator() {
        // ⇄ ComposerTokenEstimator: CJK ≈ 1 scalar per token, rest ≈ 4.
        assertEquals(0, FullEditorPolicy.estimatedTokens(""))
        assertEquals(1, FullEditorPolicy.estimatedTokens("abcd")) // 4/4
        assertEquals(1, FullEditorPolicy.estimatedTokens("abc")) // ceil(3/4)
        assertEquals(2, FullEditorPolicy.estimatedTokens("中文")) // 2 CJK
        assertEquals(3, FullEditorPolicy.estimatedTokens("中文abcd")) // 2 + 4/4
        // 100_000 Latin scalars: still an estimate, never exact.
        assertEquals(25_000, FullEditorPolicy.estimatedTokens("a".repeat(100_000)))
        // Grapheme counting (characters, not UTF-16 units).
        assertEquals(1, FullEditorPolicy.characterCount("👨‍👩‍👧"))
        assertEquals(3, FullEditorPolicy.characterCount("中文é"))
    }

    /* --------------------------- one shared draft --------------------------- */

    @Test
    fun editorAndInlineShareOneDraftStateAndGeneration() {
        val host = RecordingHost()
        val h = holder(host)
        h.openFullEditor()
        assertTrue(h.showsFullEditor)

        // "Editor typing" is literally the same holder.onDraftChange edge the
        // inline field calls: one state object, one generation counter.
        h.onDraftChange(TextFieldValue("hello "))
        val generationAfterFirst = h.draftGeneration
        h.onDraftChange(TextFieldValue("hello world"))
        assertTrue(h.draftGeneration > generationAfterFirst)
        assertEquals("hello world", h.draft.value.text)

        // Done only dismisses: no submit effect, draft retained.
        val effectsBefore = host.effects.size
        h.closeFullEditor()
        assertFalse(h.showsFullEditor)
        assertEquals(effectsBefore, host.effects.size)
        assertEquals("hello world", h.draft.value.text)
    }

    @Test
    fun editorSendRunsTheOneCanonicalPipelineAndClosesOnlyOnAccept() {
        val host = RecordingHost()
        val h = holder(host)
        h.openFullEditor()
        h.onDraftChange(TextFieldValue("   "))

        // Blank draft can never send and the sheet stays open.
        assertFalse(h.fullEditorCanSend())
        assertTrue(h.sendFromFullEditor() is ConversationFlowResult.Rejected)
        assertTrue(h.showsFullEditor)
        assertEquals(0, host.count("startRun"))

        h.onDraftChange(TextFieldValue("launch this"))
        assertTrue(h.fullEditorCanSend())
        assertEquals(ConversationFlowResult.Accepted, h.sendFromFullEditor())
        assertFalse("⇄ performSend closes after a real send", h.showsFullEditor)
        assertEquals(1, host.count("startRun"))
        // Exactly one send pipeline: the same retained commit machinery.
        assertEquals(0, host.count("clearDraftAfterSend")) // admission, not durable start
    }

    @Test
    fun sendGuardMirrorsTheInlinePolicyIncludingCompositionAndProvider() {
        val host = RecordingHost()
        val h = holder(host)
        h.openFullEditor()

        // IME marked composition (unconfirmed candidate) never sends.
        val marked = TextFieldValue(
            text = "候选",
            selection = TextRange(2),
            composition = TextRange(0, 2),
        )
        h.onDraftChange(marked)
        assertFalse("marked text must not send (⇄ requestSend guard)", h.fullEditorCanSend())

        // No provider → disabled (honest inline parity).
        val noProvider = RecordingHost()
        val h2 = ConversationFlowHolder(noProvider, "conv-1")
        h2.applyHostSnapshot(threadState(h2.session, needsProvider = true))
        h2.onDraftChange(TextFieldValue("text"))
        assertFalse(h2.fullEditorCanSend())

        // Attachment still importing → disabled.
        val h3 = holder(RecordingHost())
        h3.applySendHandoff(null, listOf(stagedAttachment(lifecycle = AttachmentImportUi.InProgress(null))))
        h3.onDraftChange(TextFieldValue("text"))
        assertFalse(h3.fullEditorCanSend())
    }

    /* ------------------------- shared bounded history ------------------------- */

    @Test
    fun sharedHistoryCoversUndoRedoRedBranchAndBounds() {
        val host = RecordingHost()
        val h = holder(host)
        h.openFullEditor()
        assertFalse(h.canUndoDraft)

        h.onDraftChange(TextFieldValue("a"))
        h.onDraftChange(TextFieldValue("ab"))
        h.onDraftChange(TextFieldValue("abc"))
        assertTrue(h.canUndoDraft)

        h.undoDraft()
        assertEquals("ab", h.draft.value.text)
        h.undoDraft()
        assertEquals("a", h.draft.value.text)
        assertTrue(h.canRedoDraft)
        h.redoDraft()
        assertEquals("ab", h.draft.value.text)

        // A new edit after undo truncates the redo branch (UndoManager rule).
        h.onDraftChange(TextFieldValue("abd"))
        assertFalse(h.canRedoDraft)

        // Undo/redo are real edits: generation advanced and the durable save
        // effect saw the restored text.
        val saves = host.effects.filter { it.name == "saveDraft" }
        assertTrue(saves.isNotEmpty())
        assertEquals("abd", (saves.last().args[1] as String))

        // Bounded history: MAX_EDITOR_HISTORY snapshots kept, oldest evicted.
        repeat(ConversationFlowHolder.MAX_EDITOR_HISTORY + 20) { i ->
            h.onDraftChange(TextFieldValue("x".repeat(i % 5 + 1) + "-$i"))
        }
        assertEquals(ConversationFlowHolder.MAX_EDITOR_HISTORY, h.editorHistorySize())
    }

    @Test
    fun caretOnlyChangesAndProgrammaticSetsNeverRecordHistory() {
        val h = holder(RecordingHost())
        h.onDraftChange(TextFieldValue("hello"))
        val gen = h.draftGeneration
        val size = h.editorHistorySize()
        // Caret-only move through the same pipeline.
        h.onDraftChange(TextFieldValue("hello", TextRange(2, 4)))
        assertEquals(gen, h.draftGeneration) // no text change, no generation bump
        assertEquals(size, h.editorHistorySize()) // no history entry either

        // Send consumption (programmatic) records nothing: the field clear
        // bypasses the recorder by design.
        val host = RecordingHost()
        val h2 = holder(host)
        h2.onDraftChange(TextFieldValue("send me"))
        val afterType = h2.editorHistorySize()
        h2.send()
        assertEquals(afterType, h2.editorHistorySize())
    }

    @Test
    fun selectAllMovesSelectionWithoutOwningNewText() {
        val h = holder(RecordingHost())
        h.onDraftChange(TextFieldValue("long draft text"))
        val gen = h.draftGeneration
        h.selectAllDraft()
        assertEquals(TextRange(0, 15), h.draft.value.selection)
        assertEquals("selection is not a text edit", gen, h.draftGeneration)
    }

    @Test
    fun retiredHolderClosesTheEditorAndRejectsReopening() {
        val h = holder(RecordingHost())
        h.onDraftChange(TextFieldValue("draft"))
        h.openFullEditor()
        h.retireForNavigation()
        assertFalse(h.showsFullEditor)
        assertEquals("", h.draft.value.text)
        h.openFullEditor()
        assertFalse("a retired holder never re-opens presentation", h.showsFullEditor)
    }
}

/** Stable access to the composer line budget the entry rule mirrors. */
private object FloeLayoutProbe {
    val regularMaxLines: Int = com.floe.android.design.FloeLayout.ComposerMaxLinesRegular
}
