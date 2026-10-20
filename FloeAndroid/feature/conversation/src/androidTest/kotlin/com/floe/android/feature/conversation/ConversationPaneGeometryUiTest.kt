// SPDX-License-Identifier: MPL-2.0
//
// Instrumentation regressions for the G02 measured conversation-pane host.
// The test-only fixture hosts the REAL FloeConversationPaneHost inside an
// exactly-sized pane (a stand-in for the future RB7 split-view binding), so
// these tests exercise actual Compose constraints, the real shared composer,
// the real TextMeasurer overflow rule and the real holder draft/undo/send
// pipeline. No production App route, backend, credential or live model stream is
// involved; the rows/state are the existing labelled synthetic fixture.
//
// Authored NOT run in this source-only package. Expected to run in the
// existing tablet component suite (Floe_G01_Tablet_API37); the full-editor
// width assertion assumes a tablet window wider than the 520dp test pane.

package com.floe.android.feature.conversation

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
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
class ConversationPaneGeometryUiTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ConversationUiFixtureActivity>()

    private lateinit var controller: ConversationFixtureController

    @Before
    fun setUp() {
        controller = composeRule.activity.controller
    }

    private fun localized(id: Int, vararg args: Any): String =
        if (args.isEmpty()) composeRule.activity.getString(id) else composeRule.activity.getString(id, *args)

    private fun applyScenario(scenario: ConversationUiScenario) {
        composeRule.runOnUiThread { controller.applyScenario(scenario) }
        composeRule.waitForIdle()
    }

    private fun setPane(widthDp: Int, heightDp: Int, fontScale: Float = 1f) {
        composeRule.runOnUiThread {
            controller.setPaneGeometry(DpSize(widthDp.dp, heightDp.dp), fontScale)
        }
        composeRule.waitForIdle()
    }

    /** Save the actual wide/narrow/IME-shrunk pane plus its semantics tree. */
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

    /** Hide the IME of the window that actually owns a dialog field. */
    private fun dismissImeOf(field: SemanticsNodeInteraction) {
        val node = field.fetchSemanticsNode("capture: typed field missing")
        val root = node.root as? ViewRootForTest ?: return dismissImeAndWait()
        val view = root.view
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val imm = view.context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.hideSoftInputFromWindow(view.windowToken, 0)
            view.clearFocus()
        }
        composeRule.waitForIdle()
    }

    private fun threadHolder(): ConversationFlowHolder = requireNotNull(controller.threadHolder)

    /**
     * Hide the real soft keyboard started by the actual typed input and wait
     * until the window reports the IME gone. The following width/height
     * assertions describe the no-IME pane; the keyboard-shrunk case is then
     * driven by the measured pane height, exactly like the host's consumed
     * inset. The typed text, caret and shared undo history stay untouched.
     */
    private fun dismissImeAndWait() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val decor = composeRule.activity.window.decorView
            val imm = decor.context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.hideSoftInputFromWindow(decor.windowToken, 0)
            decor.clearFocus()
        }
        composeRule.waitForIdle()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            composeRule.waitUntil(timeoutMillis = 5_000) {
                var visible = true
                instrumentation.runOnMainSync {
                    val decor = composeRule.activity.window.decorView
                    visible = decor.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
                }
                !visible
            }
        }
        composeRule.waitForIdle()
    }


    private fun paneBounds() =
        composeRule.onNodeWithTag(ConversationPaneGeometryFixtureTags.ROOT).getUnclippedBoundsInRoot()

    private fun inlineField() = composeRule.onNode(
        hasSetTextAction() and (
            hasContentDescription(localized(R.string.composer_placeholder)) or
                hasAnyAncestor(hasContentDescription(localized(R.string.composer_placeholder)))
        ),
    )

    private fun expandNodes() =
        composeRule.onAllNodesWithContentDescription(localized(R.string.composer_expand))

    private fun expandVisible(): Boolean =
        expandNodes().fetchSemanticsNodes().any { it.layoutInfo.isPlaced }

    /* ------------------------------ width geometry ----------------------------- */

    @Test
    fun widePaneComposerFillsThePaneWithNoReadingCapOrPhantomGutter() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 900, heightDp = 700)

        val pane = paneBounds()
        val attach = composeRule
            .onNodeWithContentDescription(localized(R.string.composer_attach))
            .getUnclippedBoundsInRoot()
        val send = composeRule
            .onNodeWithContentDescription(localized(R.string.thread_send))
            .getUnclippedBoundsInRoot()

        assertTrue(
            "composer must start at the actual pane edge, not a centred 720dp gutter " +
                "(attach left=${attach.left}, pane left=${pane.left})",
            attach.left - pane.left < 48.dp,
        )
        assertTrue(
            "composer must end at the actual pane edge, not a centred 720dp gutter " +
                "(send right=${send.right}, pane right=${pane.right})",
            pane.right - send.right < 48.dp,
        )
        assertTrue(
            "the control span must cover most of the 900dp pane; a 720dp cap would " +
                "leave a visible centred column",
            send.right - attach.left > pane.width * 0.8f,
        )
        assertFalse("a short empty draft must not open the expand entry", expandVisible())
        capture("23-pane-wide-900")
    }

    @Test
    fun narrowerPaneInTheSameWindowReflowsAndKeepsDraftCaretAndUndo() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 900, heightDp = 700)
        val draftText = "x".repeat(420)
        inlineField().performTextInput(draftText)
        composeRule.waitForIdle()
        dismissImeAndWait()

        val holder = threadHolder()
        assertEquals(draftText, holder.draft.value.text)
        composeRule.runOnUiThread {
            holder.onDraftChange(
                holder.draft.value.copy(selection = TextRange(40, 55)),
            )
        }
        composeRule.waitForIdle()
        assertFalse("a 420-char draft still fits the wide detail pane", expandVisible())

        setPane(widthDp = 520, heightDp = 700)

        assertEquals("resize must not reset the draft text", draftText, holder.draft.value.text)
        assertEquals(
            "resize must not reset the caret/selection",
            TextRange(40, 55),
            holder.draft.value.selection,
        )
        assertTrue("resize must not clear the shared undo history", holder.canUndoDraft)
        assertTrue("the same draft overflows the narrower pane", expandVisible())
        capture("24-pane-narrow-520")

        setPane(widthDp = 900, heightDp = 700)
        assertFalse("rotating back must hide the entry again", expandVisible())
        assertEquals(draftText, holder.draft.value.text)
        assertEquals(TextRange(40, 55), holder.draft.value.selection)
    }

    @Test
    fun shortDraftStaysCalmWhileLongMultilineOffersTheEditor() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 900, heightDp = 700)

        inlineField().performTextInput("short draft")
        composeRule.waitForIdle()
        assertFalse("a short one-line draft must not show the expand entry", expandVisible())

        val multiline = (1..10).joinToString("\n") { "line $it" }
        composeRule.runOnUiThread {
            threadHolder().onDraftChange(TextFieldValue(multiline))
        }
        composeRule.waitForIdle()
        assertEquals("the multiline draft is retained", multiline, threadHolder().draft.value.text)
        assertTrue("ten hard lines exceed the eight-line budget", expandVisible())
    }

    @Test
    fun compactPhonePaneKeepsTheComposerBoundedAndStillOffersTheEditor() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 360, heightDp = 700)

        val pane = paneBounds()
        val attach = composeRule
            .onNodeWithContentDescription(localized(R.string.composer_attach))
            .getUnclippedBoundsInRoot()
        val send = composeRule
            .onNodeWithContentDescription(localized(R.string.thread_send))
            .getUnclippedBoundsInRoot()

        assertTrue(attach.left >= pane.left)
        assertTrue(send.right <= pane.right)
        assertTrue("48dp minimum target survives the compact pane", attach.width >= 48.dp)
        assertTrue(send.width >= 48.dp)

        inlineField().performTextInput("x".repeat(300))
        composeRule.waitForIdle()
        assertTrue("compact phone is not treated as a tablet", expandVisible())
        dismissImeAndWait()
        capture("25-pane-compact-360")
    }

    /* ------------------------- height / typography geometry -------------------- */

    @Test
    fun keyboardShrunkNonFullHeightPaneLowersTheFieldCapAndKeepsDraft() {
        applyScenario(ConversationUiScenario.EMPTY)
        // A full-height pane first, then the same pane reduced the way the
        // host's consumed IME inset reduces it when the keyboard opens. The
        // live software keyboard itself is a Main device-acceptance step.
        setPane(widthDp = 900, heightDp = 760)
        inlineField().performTextInput("x".repeat(420))
        composeRule.waitForIdle()
        dismissImeAndWait()
        assertFalse("the draft fits the full-height pane", expandVisible())

        val holder = threadHolder()
        composeRule.runOnUiThread {
            holder.onDraftChange(holder.draft.value.copy(selection = TextRange(20, 30)))
        }
        composeRule.waitForIdle()

        setPane(widthDp = 900, heightDp = 360)

        val pane = paneBounds()
        val field = inlineField().getUnclippedBoundsInRoot()
        val send = composeRule
            .onNodeWithContentDescription(localized(R.string.thread_send))
            .getUnclippedBoundsInRoot()

        assertTrue(
            "field height must respect the one-third pane cap (field=${field.height})",
            field.height <= 121.dp,
        )
        assertTrue("composer must stay inside the non-full-height pane", send.bottom <= pane.bottom + 1.dp)
        assertTrue("the height-capped field reports real overflow", expandVisible())
        assertEquals(420, holder.draft.value.text.length)
        assertEquals("keyboard-shrink must keep the caret", TextRange(20, 30), holder.draft.value.selection)
        capture("26-pane-ime-shrunk-360")
    }

    @Test
    fun fontScaleChangeRecomputesOverflowWithoutLosingDraftOrUndo() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 900, heightDp = 700)
        val draftText = "x".repeat(420)
        inlineField().performTextInput(draftText)
        composeRule.waitForIdle()
        dismissImeAndWait()
        val holder = threadHolder()
        assertFalse("baseline type fits the wide pane", expandVisible())

        setPane(widthDp = 900, heightDp = 700, fontScale = 2f)

        assertEquals(draftText, holder.draft.value.text)
        assertTrue("font-scale recomposition must not clear undo", holder.canUndoDraft)
        assertTrue("2x type no longer fits the same pane", expandVisible())
        capture("28-pane-fontscale-2x")
    }

    /* ------------------------------ editor geometry ---------------------------- */

    @Test
    fun fullEditorKeepsItsDialogWidthAndSharesTheSameDraftAndUndo() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 520, heightDp = 700)

        inlineField().performTextInput("x".repeat(420))
        composeRule.waitForIdle()
        assertTrue("the draft overflows the 520dp detail pane", expandVisible())
        val pane = paneBounds()
        composeRule.onNodeWithContentDescription(localized(R.string.composer_expand)).performClick()
        composeRule.waitForIdle()

        val title = localized(R.string.composer_editor_title)
        val sheetField = composeRule.onNode(
            hasSetTextAction() and hasContentDescription(title),
        )
        sheetField.assertIsDisplayed()
        val sheetBounds = sheetField.getUnclippedBoundsInRoot()
        assertTrue(
            "the full editor uses its own dialog bounds, not the detail pane " +
                "(sheet=${sheetBounds.width}, pane=${pane.width})",
            sheetBounds.width > pane.width,
        )

        // One draft pipeline: typing inside the sheet lands on the holder.
        sheetField.performTextInput(" more")
        composeRule.waitForIdle()
        val holder = threadHolder()
        assertEquals(425, holder.draft.value.text.length)
        assertTrue(holder.draft.value.text.endsWith(" more"))

        // One shared undo history, still usable after the geometry change.
        composeRule.onNodeWithContentDescription(localized(R.string.composer_editor_undo)).performClick()
        composeRule.waitForIdle()
        assertEquals(420, holder.draft.value.text.length)
        composeRule.onNodeWithContentDescription(localized(R.string.composer_editor_redo)).performClick()
        composeRule.waitForIdle()
        assertEquals(425, holder.draft.value.text.length)
        dismissImeOf(sheetField)
        capture("27-full-editor-dialog-width")

        // Done dismisses only.
        composeRule.onNodeWithContentDescription(localized(R.string.action_done)).performClick()
        composeRule.waitForIdle()
        assertFalse(holder.showsFullEditor)
        assertEquals(425, holder.draft.value.text.length)
        assertEquals(0, controller.host.count("startRun"))
    }

    /* -------------------------------- send guards ------------------------------ */

    @Test
    fun geometryResizeDoesNotDuplicateOrBypassTheCanonicalSendGuard() {
        applyScenario(ConversationUiScenario.EMPTY)
        setPane(widthDp = 900, heightDp = 700)
        inlineField().performTextInput("send after resize")
        composeRule.waitForIdle()
        dismissImeAndWait()

        // An IME marked composition disables the shared send control through
        // ComposerSendPolicy, so a tap cannot reach the launch route. The live
        // software keyboard itself is a Main device-acceptance step.
        val holder = threadHolder()
        composeRule.runOnUiThread {
            holder.onDraftChange(
                TextFieldValue(
                    text = "候选",
                    selection = TextRange(2),
                    composition = TextRange(0, 2),
                ),
            )
        }
        composeRule.waitForIdle()
        val sendLabel = localized(R.string.thread_send)
        composeRule.onNodeWithContentDescription(sendLabel).assertIsNotEnabled()
        assertEquals("marked composition must not reach the launch route", 0, controller.host.count("startRun"))

        // Restore an ordinary draft, then resize the pane: geometry must not
        // create a second send entry or lose the one draft associated with it.
        composeRule.runOnUiThread {
            holder.onDraftChange(TextFieldValue("send after resize"))
        }
        composeRule.waitForIdle()
        setPane(widthDp = 520, heightDp = 700)
        controller.host.resetEffects()
        composeRule.onNodeWithContentDescription(sendLabel).performClick()
        composeRule.waitForIdle()
        assertEquals("exactly one canonical launch after resize", 1, controller.host.count("startRun"))
        val launch = controller.host.lastArgs("startRun")
        assertNotNull("the launch carries the real request", launch)
        assertEquals("conv-1", threadHolder().session.conversationId)
    }

}
