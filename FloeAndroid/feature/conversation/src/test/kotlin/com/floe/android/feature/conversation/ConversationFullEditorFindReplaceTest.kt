// SPDX-License-Identifier: MPL-2.0
//
// Holder-level tests for the full-editor Find/Replace surface.
//
// Everything here is pure-JVM: the REAL ConversationFlowHolder, the REAL
// [FindScanner], and the synthetic RecordingHost fixture. There is no Compose
// runtime, device, provider, network or file system. The tests pin the
// important contracts:
//  - query navigation is selection-only (no generation/undo entry);
//  - replacements go through the ONE shared draft/undo/save pipeline;
//  - Replace All is one atomic undoable edit and never silently truncates;
//  - Match Case/Whole Word recompute counts;
//  - a stale query/draft/session snapshot cannot reselect;
//  - a real rebind/temporary retirement clears the RAM-only presentation state;
//  - the existing send guard/pipeline is unchanged.
//
// AUTHORED, NOT RUN in this source-only lane (no Gradle/compiler was used).

package com.floe.android.feature.conversation

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationFullEditorFindReplaceTest {

    private fun holder(host: RecordingHost = RecordingHost()): ConversationFlowHolder {
        val h = ConversationFlowHolder(host, "conv-1")
        h.applyHostSnapshot(threadState(h.session))
        return h
    }

    private fun openFind(
        text: String,
        host: RecordingHost = RecordingHost(),
    ): ConversationFlowHolder {
        val h = holder(host)
        h.onDraftChange(TextFieldValue(text))
        h.openFullEditor()
        h.openFindInFullEditor()
        return h
    }

    /* ------------------------------ opening state ------------------------------ */

    @Test
    fun openingFindIsRamOnlyPresentationAndNeverEditsOrSends() {
        val host = RecordingHost()
        val h = openFind("alpha beta alpha", host)
        val generation = h.draftGeneration
        val history = h.editorHistorySize()
        val saves = host.count("saveDraft")

        assertTrue(h.showsFullEditor)
        assertTrue(h.findReplace.isOpen)
        assertEquals("", h.findReplace.query)
        assertEquals(0, h.findReplace.totalMatches)
        assertNull(h.findReplace.currentMatch)
        assertEquals("alpha beta alpha", h.draft.value.text)
        assertEquals(generation, h.draftGeneration)
        assertEquals(history, h.editorHistorySize())
        assertEquals(saves, host.count("saveDraft"))
        assertEquals(0, host.count("startRun"))
    }

    /* --------------------------- navigation semantics --------------------------- */

    @Test
    fun querySelectionAndNavigationAreSelectionOnly() {
        val h = openFind("alpha beta alpha")
        val generation = h.draftGeneration
        val history = h.editorHistorySize()

        h.setFindQuery("alpha")
        assertEquals(2, h.findReplace.totalMatches)
        assertEquals(0, h.findReplace.currentOrdinal)
        assertEquals(FindMatch(0, 5), h.findReplace.currentMatch)
        assertEquals(TextRange(0, 5), h.draft.value.selection)
        assertEquals(generation, h.draftGeneration)
        assertEquals(history, h.editorHistorySize())

        assertTrue(h.findNext())
        assertEquals(1, h.findReplace.currentOrdinal)
        assertEquals(FindMatch(11, 16), h.findReplace.currentMatch)
        assertEquals(TextRange(11, 16), h.draft.value.selection)

        // Next wraps to the first match.
        assertTrue(h.findNext())
        assertEquals(0, h.findReplace.currentOrdinal)
        assertEquals(TextRange(0, 5), h.draft.value.selection)

        // Previous wraps to the last match from the first.
        assertTrue(h.findPrevious())
        assertEquals(1, h.findReplace.currentOrdinal)
        assertEquals(TextRange(11, 16), h.draft.value.selection)

        assertEquals("navigation never edits text", generation, h.draftGeneration)
        assertEquals("navigation never records undo", history, h.editorHistorySize())
    }

    @Test
    fun emptyAndNoMatchQueriesKeepTheCaretAndReturnNoMatch() {
        val h = openFind("alpha beta")
        h.setFindQuery("alpha")
        val selected = h.draft.value.selection
        val generation = h.draftGeneration
        val history = h.editorHistorySize()

        h.setFindQuery("zzz")
        assertEquals(0, h.findReplace.totalMatches)
        assertEquals(-1, h.findReplace.currentOrdinal)
        assertNull(h.findReplace.currentMatch)
        assertEquals("no-match leaves the real selection alone", selected, h.draft.value.selection)

        assertEquals(FindReplaceEditResult.NoMatch, h.replaceCurrentFindMatch())
        assertEquals(FindReplaceEditResult.NoMatch, h.replaceAllFindMatches())
        assertEquals(generation, h.draftGeneration)
        assertEquals(history, h.editorHistorySize())

        h.setFindQuery("")
        assertEquals(0, h.findReplace.totalMatches)
        assertNull(h.findReplace.currentMatch)
        assertEquals(selected, h.draft.value.selection)
    }

    /* ------------------------------- replacement ------------------------------- */

    @Test
    fun replaceCurrentUsesTheSharedUndoAndSelectsTheNextRealMatch() {
        val host = RecordingHost()
        val h = openFind("alpha beta alpha", host)
        val sharedDraft = h.draft
        h.setFindQuery("alpha")
        h.setFindReplacement("X")
        val history = h.editorHistorySize()
        val generation = h.draftGeneration
        val saves = host.count("saveDraft")

        assertEquals(FindReplaceEditResult.Replaced(1), h.replaceCurrentFindMatch())
        assertEquals("X beta alpha", h.draft.value.text)
        assertEquals(
            "the replacement updated the inline/full-editor shared state",
            "X beta alpha",
            sharedDraft.value.text,
        )
        assertSame("one shared draft state object", sharedDraft, h.draft)
        assertEquals(TextRange(7, 12), h.draft.value.selection)
        assertEquals(1, h.findReplace.totalMatches)
        assertEquals(0, h.findReplace.currentOrdinal)
        assertEquals(FindMatch(7, 12), h.findReplace.currentMatch)
        assertEquals(history + 1, h.editorHistorySize())
        assertTrue(h.draftGeneration > generation)
        assertEquals(saves + 1, host.count("saveDraft"))
        assertEquals("X beta alpha", host.lastArgs("saveDraft")?.get(1))

        // One shared undo restores the exact pre-replacement value.
        h.undoDraft()
        assertEquals("alpha beta alpha", h.draft.value.text)
        assertEquals(TextRange(0, 5), h.draft.value.selection)
        assertTrue(h.canRedoDraft)

        h.redoDraft()
        assertEquals("X beta alpha", h.draft.value.text)
        assertEquals(TextRange(7, 12), h.draft.value.selection)
    }

    @Test
    fun replaceAllIsOneAtomicUndoableEdit() {
        val host = RecordingHost()
        val h = openFind("alpha beta alpha", host)
        h.setFindQuery("alpha")
        h.setFindReplacement("X")
        val history = h.editorHistorySize()
        val generation = h.draftGeneration
        val saves = host.count("saveDraft")

        assertEquals(FindReplaceEditResult.Replaced(2), h.replaceAllFindMatches())
        assertEquals("X beta X", h.draft.value.text)
        // The pre-replace caret was at the start of the first match; the
        // documented mapping keeps it after that replacement (offset 1).
        assertEquals(TextRange(1), h.draft.value.selection)
        assertEquals(0, h.findReplace.totalMatches)
        assertNull(h.findReplace.currentMatch)
        assertEquals("one atomic edit", history + 1, h.editorHistorySize())
        assertTrue(h.draftGeneration > generation)
        assertEquals("one shared save effect", saves + 1, host.count("saveDraft"))
        assertEquals("X beta X", host.lastArgs("saveDraft")?.get(1))

        // A single undo restores the complete original draft.
        h.undoDraft()
        assertEquals("alpha beta alpha", h.draft.value.text)
        assertEquals(TextRange(0, 5), h.draft.value.selection)
        assertTrue(h.canRedoDraft)
        h.redoDraft()
        assertEquals("X beta X", h.draft.value.text)
    }

    @Test
    fun literalReplacementKeepsDollarBackslashAndN() {
        val h = openFind("price \$1 and \\path")
        h.setFindQuery("\$1")
        h.setFindReplacement("\$2\\n")
        assertEquals(FindReplaceEditResult.Replaced(1), h.replaceAllFindMatches())
        assertEquals("price \$2\\n and \\path", h.draft.value.text)

        // A backslash query is literal too (not a regex word boundary).
        h.setFindQuery("\\n")
        assertEquals(1, h.findReplace.totalMatches)
    }

    @Test
    fun matchOptionsRecomputeCountAndSelection() {
        val h = openFind("Alpha alpha alphabet")
        h.setFindQuery("alpha")
        assertEquals(3, h.findReplace.totalMatches)
        assertEquals(FindMatch(0, 5), h.findReplace.currentMatch)

        h.setFindMatchCase(true)
        assertEquals(2, h.findReplace.totalMatches)
        assertEquals(FindMatch(6, 11), h.findReplace.currentMatch)

        h.setFindWholeWord(true)
        assertEquals(1, h.findReplace.totalMatches)
        assertEquals(FindMatch(6, 11), h.findReplace.currentMatch)
        assertEquals(TextRange(6, 11), h.draft.value.selection)

        h.setFindMatchCase(false)
        assertEquals(2, h.findReplace.totalMatches)
    }

    @Test
    fun largeButReasonableReplaceAllIsCompleteAndNotTruncated() {
        val h = openFind("a ".repeat(200))
        h.setFindQuery("a")
        assertEquals(200, h.findReplace.totalMatches)
        h.setFindReplacement("b")
        assertEquals(FindReplaceEditResult.Replaced(200), h.replaceAllFindMatches())
        assertEquals("b ".repeat(200), h.draft.value.text)
        assertFalse(h.draft.value.text.contains('a'))
    }

    @Test
    fun replaceAllRefusalPreservesTheDraftSelectionUndoAndSaveEffects() {
        val host = RecordingHost()
        val h = openFind("a".repeat(1_000), host)
        h.setFindQuery("a")
        h.setFindReplacement("x".repeat(9_000))
        val before = h.draft.value
        val generation = h.draftGeneration
        val history = h.editorHistorySize()
        val saves = host.count("saveDraft")

        val result = h.replaceAllFindMatches()
        assertTrue(result is FindReplaceEditResult.RefusedTooLarge)
        assertTrue(
            (result as FindReplaceEditResult.RefusedTooLarge).attemptedUtf16Length >=
                FindScanner.MAX_REPLACE_ALL_OUTPUT_UTF16,
        )
        assertEquals("input and selection are preserved", before, h.draft.value)
        assertEquals(generation, h.draftGeneration)
        assertEquals(history, h.editorHistorySize())
        assertEquals(saves, host.count("saveDraft"))
        assertEquals(1_000, h.findReplace.totalMatches)
        assertTrue("the refusal is visible to the UI", h.findReplace.replaceAllRefused)

        // Editing the replacement clears the stale refusal message; the real
        // draft/selection remain untouched throughout.
        h.setFindReplacement("x")
        assertFalse(h.findReplace.replaceAllRefused)
        assertEquals(before, h.draft.value)
    }

    /* -------------------------------- fencing -------------------------------- */

    @Test
    fun staleFindSnapshotCannotReselectAfterQueryDraftOrSessionChange() {
        val h = openFind("alpha beta alpha")
        h.setFindQuery("alpha")
        val key = h.findSearchKey()
        val first = h.findReplace.currentMatch!!
        assertTrue("the live snapshot may select its own real match", h.applyFindSelection(key, first))

        // A newer query rejects the older snapshot.
        h.setFindQuery("beta")
        assertFalse(h.applyFindSelection(key, first))

        // A newer draft revision rejects even the newer query's snapshot.
        val betaKey = h.findSearchKey()
        h.onDraftChange(TextFieldValue("alpha beta alpha!"))
        assertFalse(h.applyFindSelection(betaKey, FindMatch(6, 10)))

        // A range that is not an exact live match is rejected too.
        val liveKey = h.findSearchKey()
        val live = h.findReplace.currentMatch!!
        assertFalse(h.applyFindSelection(liveKey, FindMatch(live.start, live.end - 1)))

        // A genuine new session rejects every earlier snapshot.
        val beforeRebind = h.findSearchKey()
        h.rebind("conv-2")
        h.openFullEditor()
        h.openFindInFullEditor()
        h.setFindQuery("alpha")
        assertFalse(h.applyFindSelection(beforeRebind, FindMatch(0, 5)))
    }

    /* --------------------------- lifecycle boundaries --------------------------- */

    @Test
    fun sameHolderKeepsFindStateThroughASameSessionSnapshot() {
        val h = openFind("alpha beta alpha")
        h.setFindQuery("alpha")
        h.setFindReplacement("X")
        h.setFindMatchCase(true)
        h.setFindWholeWord(true)
        val before = h.findReplace

        // A host echo for the same session is not a rebind/configuration
        // recreation: the retained holder keeps its RAM-only presentation.
        h.applyHostSnapshot(threadState(h.session))
        assertEquals(before, h.findReplace)

        h.closeFindInFullEditor()
        assertFalse(h.findReplace.isOpen)
        assertEquals("alpha", h.findReplace.query)
        assertEquals("X", h.findReplace.replacement)
        assertTrue(h.findReplace.matchCase)
        assertTrue(h.findReplace.wholeWord)
        assertEquals(0, h.findReplace.totalMatches)
        assertTrue("closing Find keeps the editor open", h.showsFullEditor)
        assertEquals("alpha beta alpha", h.draft.value.text)

        h.openFindInFullEditor()
        assertTrue(h.findReplace.isOpen)
        assertEquals(2, h.findReplace.totalMatches)
    }

    @Test
    fun replacedTemporaryIncarnationClearsTheFindSurface() {
        val h = holder()
        h.applyHostSnapshot(
            threadState(
                h.session,
                isTemporary = true,
                temporaryIncarnationId = "temp-1",
            ),
        )
        h.onDraftChange(TextFieldValue("temporary text"))
        h.openFullEditor()
        h.openFindInFullEditor()
        h.setFindQuery("temporary")
        assertEquals(1, h.findReplace.totalMatches)
        assertEquals(FindMatch(0, 9), h.findReplace.currentMatch)
        val staleKey = h.findSearchKey()

        h.applyHostSnapshot(
            threadState(
                h.session,
                isTemporary = true,
                temporaryIncarnationId = "temp-2",
            ),
        )
        assertFalse(h.findReplace.isOpen)
        assertEquals("", h.findReplace.query)
        assertEquals("", h.findReplace.replacement)
        assertEquals(0, h.findReplace.totalMatches)
        assertNull(h.findReplace.currentMatch)

        // Even if the visible draft/query happen to match again in the new
        // temporary incarnation, the old key is fenced on the incarnation id.
        h.openFindInFullEditor()
        h.setFindQuery("temporary")
        assertEquals(1, h.findReplace.totalMatches)
        assertFalse(h.applyFindSelection(staleKey, FindMatch(0, 9)))
    }

    @Test
    fun rebindAndTemporaryRetirementClearTheFindSurface() {
        val h = openFind("alpha beta alpha")
        h.setFindQuery("alpha")
        h.setFindReplacement("X")
        h.rebind("conv-2")
        assertFalse(h.findReplace.isOpen)
        assertEquals("", h.findReplace.query)
        assertEquals("", h.findReplace.replacement)
        assertEquals(0, h.findReplace.totalMatches)
        assertNull(h.findReplace.currentMatch)
        assertEquals("", h.draft.value.text)

        val temp = holder()
        temp.applyHostSnapshot(
            threadState(
                temp.session,
                isTemporary = true,
                temporaryIncarnationId = "temp-1",
            ),
        )
        temp.onDraftChange(TextFieldValue("temporary text"))
        temp.openFullEditor()
        temp.openFindInFullEditor()
        temp.setFindQuery("temporary")
        assertEquals(1, temp.findReplace.totalMatches)

        temp.retireForNavigation()
        assertFalse(temp.findReplace.isOpen)
        assertEquals("", temp.findReplace.query)
        assertEquals(0, temp.findReplace.totalMatches)
        assertEquals("", temp.draft.value.text)
        assertFalse(temp.showsFullEditor)
    }

    /* ------------------------------- send safety ------------------------------- */

    @Test
    fun findNavigationNeverSendsAndTheCanonicalSendPipelineStillWorks() {
        val host = RecordingHost()
        val h = openFind("send this text", host)
        h.setFindQuery("this")
        assertTrue(h.findNext())
        assertEquals("find navigation never starts a run", 0, host.count("startRun"))

        assertTrue(h.fullEditorCanSend())
        assertEquals(ConversationFlowResult.Accepted, h.sendFromFullEditor())
        assertFalse(h.showsFullEditor)
        assertFalse("an accepted send closes the Find surface", h.findReplace.isOpen)
        assertEquals(1, host.count("startRun"))
    }

    @Test
    fun rejectedSendKeepsTheFindSurfaceAndDraftOpen() {
        val host = RecordingHost()
        val h = ConversationFlowHolder(host, "conv-1")
        h.applyHostSnapshot(threadState(h.session, needsProvider = true))
        h.onDraftChange(TextFieldValue("cannot send yet"))
        h.openFullEditor()
        h.openFindInFullEditor()
        h.setFindQuery("send")

        assertFalse(h.fullEditorCanSend())
        assertTrue(h.sendFromFullEditor() is ConversationFlowResult.Rejected)
        assertTrue(h.showsFullEditor)
        assertTrue(h.findReplace.isOpen)
        assertEquals("cannot send yet", h.draft.value.text)
        assertEquals(0, host.count("startRun"))
    }
}
