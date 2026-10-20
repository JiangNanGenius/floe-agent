// SPDX-License-Identifier: MPL-2.0
//
// Instrumentation coverage for the REAL full-editor Find/Replace surface.
//
// The fixture is the existing labelled synthetic ConversationUiFixtureActivity:
// no backend, no network, no credentials, no production App content. This test
// drives the actual Compose semantics (toolbar magnifier, query/replacement
// fields, count, previous/next, Replace/Replace All, undo/redo, Ctrl+F,
// Escape, system Back) against the real holder and records one screenshot for
// Main's rendered review.
//
// AUTHORED, NOT RUN in this source-only lane (no Gradle/compiler/ADB/device was
// used). Main's serial component-host qualification owns execution.

package com.floe.android.feature.conversation

import android.content.Context
import android.graphics.Bitmap
import android.view.KeyEvent
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.withKeyDown
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConversationFindReplaceUiTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ConversationUiFixtureActivity>()

    private lateinit var controller: ConversationFixtureController

    @Before
    fun setUp() {
        controller = composeRule.activity.controller
    }

    private fun localized(id: Int, vararg args: Any): String =
        if (args.isEmpty()) {
            composeRule.activity.getString(id)
        } else {
            composeRule.activity.getString(id, *args)
        }

    private fun applyScenario(scenario: ConversationUiScenario) {
        composeRule.runOnUiThread { controller.applyScenario(scenario) }
        composeRule.waitForIdle()
    }

    private fun threadHolder(): ConversationFlowHolder = requireNotNull(controller.threadHolder)

    /** Cupertino wrappers may keep the label on the container while the
     * editable child owns the text action; match either node. */
    private fun editableLabeledBy(desc: String): SemanticsNodeInteraction = composeRule.onNode(
        hasSetTextAction() and
            (hasContentDescription(desc) or hasAnyAncestor(hasContentDescription(desc))),
    )

    private fun openEditorWith(text: String) {
        applyScenario(ConversationUiScenario.FULL_EDITOR)
        val holder = threadHolder()
        composeRule.runOnUiThread {
            holder.onDraftChange(TextFieldValue(text))
            holder.openFullEditor()
        }
        composeRule.waitForIdle()
        composeRule.onNode(
            hasSetTextAction() and hasContentDescription(localized(R.string.composer_editor_title)),
        ).assertIsDisplayed()
    }

    private fun openFindBar() {
        composeRule.onNodeWithContentDescription(localized(R.string.composer_editor_find))
            .assertIsDisplayed()
            .performClick()
        composeRule.waitForIdle()
        assertTrue(threadHolder().findReplace.isOpen)
    }

    /** Hide the soft keyboard through the WINDOW that owns the field so the
     * next system Back reaches the Find bar instead of the IME. */
    private fun hideImeOf(field: SemanticsNodeInteraction) {
        val node = field.fetchSemanticsNode("typed Find field missing")
        val root = node.root as? androidx.compose.ui.platform.ViewRootForTest ?: return
        val view = root.view
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val imm = view.context.getSystemService(Context.INPUT_METHOD_SERVICE)
                as android.view.inputmethod.InputMethodManager
            imm.hideSoftInputFromWindow(view.windowToken, 0)
            view.clearFocus()
        }
        composeRule.waitForIdle()
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        assertNotNull("UiAutomation.takeScreenshot returned null", bitmap)
        val directory = composeRule.activity.getDir("conversation-ui-screenshots", Context.MODE_PRIVATE)
        val locale = composeRule.activity.runLocale
        val theme = composeRule.activity.runTheme
        val file = File(directory, "$name-$locale-$theme.png")
        FileOutputStream(file).use { out ->
            bitmap!!.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        writeComposeHierarchy(composeRule, File(directory, "$name-$locale-$theme.txt"))
    }

    /* ===================== compact toolbar + navigation ===================== */

    @Test
    fun compactToolbarOpensFindAndPreviousNextWrap() {
        openEditorWith("alpha beta alpha")
        val holder = threadHolder()
        composeRule.onNodeWithText(localized(R.string.action_done)).assertIsDisplayed()
        openFindBar()

        val query = editableLabeledBy(localized(R.string.composer_editor_find_hint))
        query.performTextInput("alpha")
        composeRule.waitForIdle()
        assertEquals(2, holder.findReplace.totalMatches)
        assertEquals(0, holder.findReplace.currentOrdinal)
        assertEquals(androidx.compose.ui.text.TextRange(0, 5), holder.draft.value.selection)
        composeRule.onNodeWithText(localized(R.string.composer_editor_find_position, 1, 2))
            .assertIsDisplayed()

        composeRule.onNodeWithContentDescription(localized(R.string.composer_editor_find_next))
            .performClick()
        composeRule.waitForIdle()
        assertEquals(1, holder.findReplace.currentOrdinal)
        assertEquals(androidx.compose.ui.text.TextRange(11, 16), holder.draft.value.selection)
        composeRule.onNodeWithText(localized(R.string.composer_editor_find_position, 2, 2))
            .assertIsDisplayed()

        // Next from the last match wraps to the first.
        composeRule.onNodeWithContentDescription(localized(R.string.composer_editor_find_next))
            .performClick()
        composeRule.waitForIdle()
        assertEquals(0, holder.findReplace.currentOrdinal)
        assertEquals(androidx.compose.ui.text.TextRange(0, 5), holder.draft.value.selection)

        // Previous from the first match wraps to the last.
        composeRule.onNodeWithContentDescription(localized(R.string.composer_editor_find_previous))
            .performClick()
        composeRule.waitForIdle()
        assertEquals(1, holder.findReplace.currentOrdinal)
        assertEquals(androidx.compose.ui.text.TextRange(11, 16), holder.draft.value.selection)

        capture("12-full-editor-find-replace")
    }

    /* ==================== replace + shared undo/redo ==================== */

    @Test
    fun replaceCurrentAndReplaceAllUseTheSharedUndoHistory() {
        openEditorWith("alpha beta alpha")
        val holder = threadHolder()
        openFindBar()

        editableLabeledBy(localized(R.string.composer_editor_find_hint)).performTextInput("alpha")
        editableLabeledBy(localized(R.string.composer_editor_replace_hint)).performTextInput("X")
        composeRule.waitForIdle()

        composeRule.onNodeWithText(localized(R.string.composer_editor_replace)).performClick()
        composeRule.waitForIdle()
        assertEquals("X beta alpha", holder.draft.value.text)
        assertEquals(androidx.compose.ui.text.TextRange(7, 12), holder.draft.value.selection)

        composeRule.onNodeWithText(localized(R.string.composer_editor_undo)).performClick()
        composeRule.waitForIdle()
        assertEquals("alpha beta alpha", holder.draft.value.text)
        composeRule.onNodeWithText(localized(R.string.composer_editor_redo)).performClick()
        composeRule.waitForIdle()
        assertEquals("X beta alpha", holder.draft.value.text)

        composeRule.onNodeWithText(localized(R.string.composer_editor_replace_all)).performClick()
        composeRule.waitForIdle()
        assertEquals("X beta X", holder.draft.value.text)
        assertEquals(0, holder.findReplace.totalMatches)

        composeRule.onNodeWithText(localized(R.string.composer_editor_undo)).performClick()
        composeRule.waitForIdle()
        // The Replace All edit is one atomic undo entry: the first undo goes
        // back to the pre-Replace-All draft, not the original draft.
        assertEquals("X beta alpha", holder.draft.value.text)
        composeRule.onNodeWithText(localized(R.string.composer_editor_undo)).performClick()
        composeRule.waitForIdle()
        // The Replace Current edit is the second, separate shared undo entry.
        assertEquals("alpha beta alpha", holder.draft.value.text)
    }

    /* ======================= options + no-result safety ======================= */

    @Test
    fun matchOptionsAndNoResultsAreRealAndSafe() {
        openEditorWith("Alpha alpha alphabet")
        val holder = threadHolder()
        openFindBar()
        editableLabeledBy(localized(R.string.composer_editor_find_hint)).performTextInput("alpha")
        composeRule.waitForIdle()
        assertEquals(3, holder.findReplace.totalMatches)

        composeRule.onNodeWithText(localized(R.string.composer_editor_match_case)).performClick()
        composeRule.waitForIdle()
        assertTrue(holder.findReplace.matchCase)
        assertEquals(2, holder.findReplace.totalMatches)

        composeRule.onNodeWithText(localized(R.string.composer_editor_whole_word)).performClick()
        composeRule.waitForIdle()
        assertTrue(holder.findReplace.wholeWord)
        assertEquals(1, holder.findReplace.totalMatches)

        val query = editableLabeledBy(localized(R.string.composer_editor_find_hint))
        query.performTextClearance()
        query.performTextInput("zzz")
        composeRule.waitForIdle()
        assertEquals(0, holder.findReplace.totalMatches)
        composeRule.onNodeWithText(localized(R.string.composer_editor_find_no_results))
            .assertIsDisplayed()

        val before = holder.draft.value
        composeRule.onNodeWithText(localized(R.string.composer_editor_replace)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.composer_editor_replace_all)).assertIsDisplayed()
        composeRule.waitForIdle()
        assertEquals("no-match UI must not touch the draft", before, holder.draft.value)
    }

    /* ======================= guarded send from Find ======================= */

    @Test
    fun sendFromTheFindSurfaceUsesTheCanonicalGuardedPipeline() {
        openEditorWith("send this")
        val holder = threadHolder()
        openFindBar()
        editableLabeledBy(localized(R.string.composer_editor_find_hint)).performTextInput("this")
        composeRule.waitForIdle()
        assertEquals(1, holder.findReplace.totalMatches)
        assertTrue(holder.fullEditorCanSend())

        composeRule.onNodeWithText(localized(R.string.composer_editor_send))
            .assertIsDisplayed()
            .performClick()
        composeRule.waitForIdle()
        // The synthetic host acknowledges the real prepare asynchronously; the
        // durable clear must follow that echo, not the admission boolean.
        composeRule.waitUntil(timeoutMillis = 5_000) {
            controller.host.count("clearDraftAfterSend") == 1
        }
        assertEquals(1, controller.host.count("startRun"))
        assertFalse(holder.showsFullEditor)
        assertFalse("an accepted send closes Find", holder.findReplace.isOpen)
        assertEquals("", holder.draft.value.text)
    }

    /* ======================= hardware shortcuts + Back ======================= */

    @Test
    fun ctrlFEscapeAndBackCloseFindBeforeTheEditor() {
        openEditorWith("alpha beta")
        val holder = threadHolder()
        val editorField = composeRule.onNode(
            hasSetTextAction() and hasContentDescription(localized(R.string.composer_editor_title)),
        )
        editorField.performClick()
        editorField.performKeyInput {
            withKeyDown(Key.CtrlLeft) { pressKey(Key.F) }
        }
        composeRule.waitForIdle()
        assertTrue("Ctrl+F opens Find", holder.findReplace.isOpen)

        val query = editableLabeledBy(localized(R.string.composer_editor_find_hint))
        query.performTextInput("alpha")
        composeRule.waitForIdle()
        assertEquals(1, holder.findReplace.totalMatches)

        // Escape closes ONLY Find; the editor and draft are preserved.
        query.performKeyInput { pressKey(Key.Escape) }
        composeRule.waitForIdle()
        assertFalse(holder.findReplace.isOpen)
        assertTrue(holder.showsFullEditor)
        assertEquals("alpha beta", holder.draft.value.text)

        // Reopen through the toolbar, hide the IME, then Back closes Find first.
        openFindBar()
        hideImeOf(editableLabeledBy(localized(R.string.composer_editor_find_hint)))
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        composeRule.waitForIdle()
        assertFalse("the first Back closes the Find bar", holder.findReplace.isOpen)
        assertTrue("the editor stays open", holder.showsFullEditor)
        assertEquals("alpha beta", holder.draft.value.text)

        // The next Back dismisses the editor without sending. Hiding Find
        // returns focus to the editor, so close that field's IME first: the
        // Back under test targets the editor sheet, not the keyboard.
        hideImeOf(editorField)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        composeRule.waitForIdle()
        assertFalse(holder.showsFullEditor)
        assertEquals("alpha beta", holder.draft.value.text)
        assertEquals(0, controller.host.count("startRun"))
    }
}
