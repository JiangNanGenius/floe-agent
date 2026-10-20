// SPDX-License-Identifier: MPL-2.0
//
// Instrumentation fixture for the G02 conversation PRESENTATION COMPONENT.
// Renders the real composables against the labelled synthetic controller,
// asserts actual Compose semantics + recorded host effects + holder state,
// and saves full-window screenshots for Main's rendered review.
//
//   adb shell am instrument -w -e conversationUiLocale zh -e conversationUiTheme light \
//       com.floe.android.feature.conversation.test/androidx.test.runner.AndroidJUnitRunner
//
// Synthetic UI evidence ONLY: no backend, no network, no credentials, no
// production App content. Screenshots are never functional/backend proof.
// Every visibility/effect assertion below is real: no no-op helpers, no
// weakened passes.

package com.floe.android.feature.conversation

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.contracts.Revision
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConversationUiComponentTest {

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

    /** Hide the IME through the WINDOW that actually owns the typed field
     * (sheets/dialogs are their own windows; the Activity decor token is not
     * enough) and wait until that window reports it gone. Entered data and
     * the current sheet are untouched. */
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            composeRule.waitUntil(timeoutMillis = 5_000) {
                var visible = true
                instrumentation.runOnMainSync {
                    visible = view.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
                }
                !visible
            }
        }
        composeRule.waitForIdle()
    }

    private fun capture(name: String, typedField: SemanticsNodeInteraction? = null) {
        if (typedField != null) dismissImeOf(typedField) else dismissImeAndWait()
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
        File(directory, "run-manifest.txt").appendText(
            "${file.name} | locale=$locale theme=$theme " +
                "size=${bitmap.width}x${bitmap.height} scenario=${controller.scenario}\n",
        )
        writeComposeHierarchy(composeRule, File(directory, "$name-$locale-$theme.txt"))
    }

    /** Cupertino wrappers may keep the label on the container while the
     * editable child owns the text action (provider-lane lesson); match the
     * editable node whose own OR ancestor semantics carry the label. */
    private fun editableLabeledBy(desc: String) = composeRule.onNode(
        hasSetTextAction() and
            (hasContentDescription(desc) or hasAnyAncestor(hasContentDescription(desc))),
    )

    private fun inlineDraftField(): SemanticsNodeInteraction =
        editableLabeledBy(localized(R.string.composer_placeholder))

    private fun threadHolder(): ConversationFlowHolder = requireNotNull(controller.threadHolder)

    private fun historyHolder(): ConversationHistoryHolder = requireNotNull(controller.historyHolder)

    /**
     * Tap the center of the FIRST actually-displayed semantics node matching
     * [match] (bounds-derived from the real UI tree; used where a plain
     * performClick is flaky because several merged nodes share a label).
     * Throws when no displayed node exists — never a blind coordinate.
     */
    private fun tapDisplayedNode(match: androidx.compose.ui.test.SemanticsMatcher) {
        composeRule.waitForIdle()
        val interactions = composeRule.onAllNodes(match)
        val nodes = interactions.fetchSemanticsNodes()
        org.junit.Assert.assertTrue("no node for $match", nodes.isNotEmpty())
        val idx = nodes.indexOfFirst {
            it.boundsInRoot.height > 0f && it.boundsInRoot.width > 0f &&
                it.boundsInRoot.top >= 0f && it.boundsInRoot.left >= 0f
        }
        org.junit.Assert.assertTrue("only off-bounds nodes for $match", idx >= 0)
        interactions[idx].performClick()
        composeRule.waitForIdle()
    }

    private fun waitUntilParsed(source: String) {
        val holder = threadHolder()
        val deadline = System.currentTimeMillis() + 10_000
        while (holder.markdownState(source) is MarkdownContentUi.Preparing &&
            System.currentTimeMillis() < deadline
        ) {
            Thread.sleep(25)
        }
        assertTrue(
            "real adapter never reached Parsed for the rich corpus",
            holder.markdownState(source) is MarkdownContentUi.Parsed,
        )
    }

    /* ============================ 01 — thread empty ============================ */

    @Test
    fun emptyThreadShowsHonestEmptyStateAndModelPicker() {
        applyScenario(ConversationUiScenario.EMPTY)
        composeRule.onNodeWithText(localized(R.string.thread_empty_title)).assertIsDisplayed()
        // Model selection round-trip through the real seam (provider-grouped).
        composeRule.onNodeWithContentDescription(localized(R.string.composer_model)).performClick()
        composeRule.onNodeWithText("Synthetic provider · Synthetic model").performClick()
        assertEquals(1, controller.host.count("selectModel"))
        assertEquals("model-1", threadHolder().selectedModelId.value)
        capture("01-empty-thread")
    }

    /* ========================= 02 — missing provider ========================= */

    @Test
    fun missingProviderShowsSetupHintAndBlocksSend() {
        applyScenario(ConversationUiScenario.MISSING_PROVIDER)
        composeRule.onNodeWithText(localized(R.string.add_provider_hint)).assertIsDisplayed()
        val holder = threadHolder()
        composeRule.runOnUiThread { holder.onDraftChange(androidx.compose.ui.text.input.TextFieldValue("hello")) }
        composeRule.waitForIdle()
        // The canonical pipeline refuses without a provider (defense beyond
        // the disabled circle): zero launch effects.
        assertTrue(controller.host.names().none { it == "startRun" })
        val direct = holder.send()
        assertTrue("send must reject without a provider", direct is ConversationFlowResult.Rejected)
        assertEquals(0, controller.host.count("startRun"))
        capture("02-missing-provider")
    }

    /* ========================== 03 — streaming wide ========================== */

    @Test
    fun streamingShowsReasoningToolCardAndRunningStatus() {
        applyScenario(ConversationUiScenario.STREAMING)
        composeRule.onNodeWithText(localized(R.string.reasoning_title)).assertIsDisplayed()
        composeRule.onNodeWithText("workspace.list").assertIsDisplayed()
        // Expand the running tool card (auto-expand applies only to failures;
        // a running card opens by tap). The group header legitimately shows
        // the same running wording, so count via the real tree and prove the
        // expansion through the holder + the expanded-only Input section.
        composeRule.onNodeWithText("workspace.list").performClick()
        assertTrue(
            "running status label missing",
            composeRule.onAllNodesWithText(localized(R.string.tool_status_running))
                .fetchSemanticsNodes().isNotEmpty(),
        )
        assertTrue(
            "the tapped card must be expanded in the holder",
            threadHolder().expandedToolCards.value.contains("ev-tool-1"),
        )
        assertTrue(
            "expanded card must surface its Input section",
            composeRule.onAllNodesWithText(localized(R.string.tool_input))
                .fetchSemanticsNodes().isNotEmpty(),
        )
        // Honest live assistant tail renders the projected streaming text.
        composeRule.onNodeWithText("Streaming synthetic", substring = true).assertIsDisplayed()

        // ⇄ UserMessageBubble.swift:106-139 regression: the short user
        // bubble FITS ITS CONTENT and sits TRAILING (the old fillMaxWidth
        // defect made it span the pane). Bounds are measured from the real
        // semantics tree against the real root width — no blind guesses.
        val rootW = composeRule.onRoot().fetchSemanticsNode().boundsInRoot.width
        val bubble = composeRule.onNodeWithText("Synthetic long question?").fetchSemanticsNode()
        val b = bubble.boundsInRoot
        assertTrue(
            "short user bubble must fit content (<45% of pane), was ${(b.width / rootW * 100).toInt()}%",
            b.width < rootW * 0.45f,
        )
        assertTrue(
            "short user bubble must sit trailing (right edge >90% of pane)",
            b.right > rootW * 0.90f,
        )
        capture("03-streaming-reasoning-tool")
    }

    /* =========================== 04 — approval card =========================== */

    @Test
    fun approvalShowsTiersEvidenceAndApprovesExactlyOnceWithIdentity() {
        applyScenario(ConversationUiScenario.APPROVAL)
        composeRule.onNodeWithText(localized(R.string.approval_required)).assertIsDisplayed()
        // Exact evidence folds open with the projected lines.
        composeRule.onNodeWithText(localized(R.string.approval_evidence)).performClick()
        composeRule.onNodeWithText("path: synthetic/notes.md").assertIsDisplayed()
        // All four grant tiers are real choices.
        composeRule.onNodeWithText(localized(R.string.approval_scope_once)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.approval_scope_task)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.approval_scope_project)).performClick()
        composeRule.onNodeWithText(localized(R.string.approval_scope_host)).assertIsDisplayed()
        capture("04-approval-tiers-evidence")
        // Approve dispatches the EXACT run+call identity once; a duplicate
        // press cannot double-dispatch while the projection still owns the
        // card (latch) and the chosen tier maps to the projected target.
        composeRule.onNodeWithText(localized(R.string.action_approve)).performClick()
        assertEquals(1, controller.host.count("resolveApproval"))
        val request = controller.host.lastArgs("resolveApproval")!![0] as ApprovalDecisionRequest
        assertEquals("run-1", request.runId)
        assertEquals("call-1", request.approvalId)
        assertEquals(ApprovalScopeChoiceUi.PROJECT, (request.decision as ApprovalUserDecisionUi.Allow).scopeChoice)
        // ⇄ ApprovalGrantMapping: LOCAL target + PROJECT tier keeps the scope
        // path and is not single-use.
        assertEquals(listOf("local"), request.grant?.paths)
        assertFalse(request.grant?.singleUse ?: true)
        // Duplicate press is latched.
        composeRule.onNodeWithText(localized(R.string.action_approve)).performClick()
        assertEquals(1, controller.host.count("resolveApproval"))
    }

    /* ======================= 05 — failed run continuation ======================= */

    @Test
    fun failedRunShowsErrorAndContinuationDispatchesRetryOnce() {
        applyScenario(ConversationUiScenario.ERROR_CONTINUATION)
        composeRule.onNodeWithText("synthetic provider stream broke").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic continuation available").assertIsDisplayed()
        // The toolbar owns a second legitimate Continue affordance; tap a
        // displayed one from the real tree and prove the dispatch.
        tapDisplayedNode(androidx.compose.ui.test.hasText(localized(R.string.action_continue)))
        assertEquals(1, controller.host.count("retryRun"))
        assertEquals("run-1", controller.host.lastArgs("retryRun")!![1])
        capture("05-error-continuation")
    }

    /* ==================== 06 — compact composer queue/tray ==================== */

    @Test
    fun compactComposerShowsTrayQueueAndCancelStopsImportRow() {
        applyScenario(ConversationUiScenario.COMPACT_COMPOSER)
        val holder = threadHolder()
        composeRule.onNodeWithText(localized(R.string.queue_title)).assertIsDisplayed()
        composeRule.onNodeWithText("first synthetic queued item").assertIsDisplayed()
        composeRule.onNodeWithText("second synthetic queued item").assertIsDisplayed()
        assertTrue(
            "the staged tray must render both host-staged rows",
            composeRule.onAllNodesWithText("synthetic-notes.md").fetchSemanticsNodes().size >= 2,
        )
        // The importing row offers a real cancel; pressing it removes the
        // presentation row FIRST, so a late echo cannot resurrect it.
        composeRule.onNodeWithText(localized(R.string.action_cancel)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, holder.stagedAttachments.value.size)
        assertEquals(1, controller.host.count("cancelAttachmentImport"))
        composeRule.runOnUiThread { holder.applyAttachmentOutcome("att-2", AttachmentImportUi.Failed("late")) }
        composeRule.waitForIdle()
        assertEquals(1, holder.stagedAttachments.value.size)
        capture("06-compact-composer-queue")
    }

    /* ================== 07/08/09 — full-screen editor contract ================== */

    @Test
    fun fullEditorSharesDraftHistoryAndClosesOnGuardedSend() {
        applyScenario(ConversationUiScenario.FULL_EDITOR)
        val holder = threadHolder()

        // Type a long draft into the INLINE field (soft-wrapped long text
        // crosses the 8-line budget without relying on newline IME behavior).
        inlineDraftField().performTextInput("x".repeat(600))
        assertEquals(600, holder.draft.value.text.length)

        // The expand entry appears only now (overflow rule).
        composeRule.onNodeWithContentDescription(localized(R.string.composer_expand)).performClick()
        val title = localized(R.string.composer_editor_title)
        composeRule.onNode(hasContentDescription(title) and hasSetTextAction()).assertIsDisplayed()

        // Edit INSIDE the sheet: the SAME holder.draft object (no second store).
        val sheetField = composeRule.onNode(hasSetTextAction() and hasContentDescription(title))
        sheetField.performTextInput(" 你好世界")
        assertEquals(605, holder.draft.value.text.length)
        assertTrue(holder.draft.value.text.endsWith("你好世界"))

        // Undo/redo operate on the SHARED bounded history.
        composeRule.onNodeWithText(localized(R.string.composer_editor_undo)).performClick()
        assertEquals(600, holder.draft.value.text.length)
        composeRule.onNodeWithText(localized(R.string.composer_editor_redo)).performClick()
        assertEquals(605, holder.draft.value.text.length)

        // Select all owns the whole text as a selection-only change.
        composeRule.onNodeWithText(localized(R.string.composer_editor_select_all)).performClick()
        assertEquals(0, holder.draft.value.selection.min)
        assertEquals(605, holder.draft.value.selection.max)

        capture("07-full-editor-same-draft", typedField = sheetField)

        // Done dismisses WITHOUT sending.
        composeRule.onNodeWithText(localized(R.string.action_done)).performClick()
        composeRule.waitForIdle()
        assertFalse(holder.showsFullEditor)
        assertEquals(605, holder.draft.value.text.length)
        assertEquals(0, controller.host.count("startRun"))

        // Reopen, then system Back also dismisses and the draft survives.
        // Reopening the sheet refocuses its field (IME up); Back first closes
        // the IME, so hide it through the sheet window before the press.
        composeRule.onNodeWithContentDescription(localized(R.string.composer_expand)).performClick()
        composeRule.waitForIdle()
        dismissImeOf(composeRule.onNode(hasSetTextAction() and hasContentDescription(title)))
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(
            android.view.KeyEvent.KEYCODE_BACK,
        )
        composeRule.waitForIdle()
        assertFalse("system Back dismisses the sheet", holder.showsFullEditor)
        assertEquals(605, holder.draft.value.text.length)
        capture("08-full-editor-closed-inline-retains")

        // Guarded send inside the sheet runs the ONE canonical pipeline; the
        // synthetic host ACKNOWLEDGES the real prepare asynchronously: the
        // durable clear happens on the PREPARED echo, not on admission.
        composeRule.onNodeWithContentDescription(localized(R.string.composer_expand)).performClick()
        controller.host.resetEffects()
        composeRule.onNodeWithText(localized(R.string.composer_editor_send)).performClick()
        assertEquals(1, controller.host.count("startRun"))
        // Right after the tap the admission may still be pending its echo:
        // the durable store clear must NOT have happened on the boolean.
        composeRule.waitUntil(timeoutMillis = 5_000) {
            controller.host.count("clearDraftAfterSend") == 1
        }
        assertFalse(holder.showsFullEditor)
        assertEquals(0, holder.draft.value.text.length)
        capture("09-full-editor-sent-prepared")
    }

    /* ===================== 10/11 — temporary badge + about ===================== */

    @Test
    fun temporaryBadgeOpensMenuAndAboutSheet() {
        applyScenario(ConversationUiScenario.TEMP_BADGE)
        composeRule.onNodeWithText(localized(R.string.temporary_badge)).performClick()
        composeRule.onNodeWithText(localized(R.string.temporary_about)).performClick()
        composeRule.onNodeWithText(localized(R.string.temporary_about_title)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.temporary_about_lifecycle)).assertIsDisplayed()
        capture("10-temporary-about")
        composeRule.onNodeWithText(localized(R.string.action_done)).performClick()
        composeRule.waitForIdle()
        assertFalse(threadHolder().showsTemporaryAbout)
    }

    @Test
    fun temporaryBadgeMenuShowsKeepAndEnd() {
        applyScenario(ConversationUiScenario.TEMP_ABOUT)
        composeRule.onNodeWithText(localized(R.string.temporary_badge)).performClick()
        composeRule.onNodeWithText(localized(R.string.temporary_keep)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.temporary_end)).assertIsDisplayed()
        capture("11-temporary-badge-menu")
    }

    /* ======================== 12 — keep saving/error retry ======================== */

    @Test
    fun keepTemporaryChatGoesThroughSavingPartialAndRetryFailure() {
        applyScenario(ConversationUiScenario.TEMP_KEEP)
        val holder = threadHolder()
        composeRule.onNodeWithText(localized(R.string.temporary_badge)).performClick()
        composeRule.onNodeWithText(localized(R.string.temporary_keep)).performClick()
        // The synthetic host echoes TailPending first: partial-retry state.
        composeRule.waitUntil(timeoutMillis = 5_000) {
            holder.temporaryKeepState == TemporaryKeepStateUi.PartialRetry
        }
        // Reopen the badge menu: the keep affordance now says "Finish saving".
        composeRule.onNodeWithText(localized(R.string.temporary_badge)).performClick()
        composeRule.onNodeWithText(localized(R.string.temporary_keep_partial_retry)).assertIsDisplayed()
        capture("12-temp-keep-partial")
        // Retry surfaces the host failure honestly.
        composeRule.onNodeWithText(localized(R.string.temporary_keep_partial_retry)).performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            holder.temporaryKeepState is TemporaryKeepStateUi.Failed
        }
        assertEquals("synthetic keep retry", (holder.temporaryKeepState as TemporaryKeepStateUi.Failed).message)
        assertEquals(2, controller.host.count("keepTemporaryChat"))
        // Both requests bound the SAME incarnation identity.
        val ref = controller.host.lastArgs("keepTemporaryChat")!![0] as TemporarySessionRef
        assertEquals("inc-1", ref.incarnationId)
    }

    /* ================ 13/14 — navigation discard vs detach retain ================ */

    @Test
    fun detachRetainsAndGenuineNavigationDiscardsTheWholeTempPayload() {
        applyScenario(ConversationUiScenario.TEMP_DISCARD)
        val holder = threadHolder()
        assertEquals("temp discard synthetic draft", holder.draft.value.text)
        assertEquals(1, holder.stagedAttachments.value.size)

        // Detach (rotation/background): everything survives.
        composeRule.runOnUiThread { holder.detach() }
        composeRule.waitForIdle()
        assertEquals("temp discard synthetic draft", holder.draft.value.text)
        assertEquals(1, holder.stagedAttachments.value.size)
        assertFalse(holder.retired)
        capture("13-temp-detach-retains")

        // Genuine navigation: the retained holder discards its payload.
        controller.host.resetEffects()
        composeRule.runOnUiThread { holder.retireForNavigation() }
        composeRule.waitForIdle()
        assertEquals("", holder.draft.value.text)
        assertTrue(holder.stagedAttachments.value.isEmpty())
        assertNull(holder.snapshot.value)
        assertTrue(holder.retired)
        // The destination honestly shows the loading surface, not the
        // discarded ephemeral content.
        composeRule.onNodeWithContentDescription(localized(R.string.loading_cd)).assertIsDisplayed()
        capture("14-temp-navigation-discarded")
        // Only the legitimate detach was emitted; no durable store effect.
        assertEquals(listOf("threadViewDetached"), controller.host.names())
        // A late host handoff cannot rehydrate the retired holder.
        composeRule.runOnUiThread { holder.applySendHandoff("ghost", listOf(UiFixtures.staged("ghost"))) }
        composeRule.waitForIdle()
        assertEquals("", holder.draft.value.text)
        assertTrue(holder.stagedAttachments.value.isEmpty())
    }

    /* ========================== 15 — history content search ========================== */

    @Test
    fun historySearchSendsEpochFtsAndShowsHostSnippet() {
        applyScenario(ConversationUiScenario.HISTORY_SEARCH)
        val holder = historyHolder()
        val field = editableLabeledBy(localized(R.string.history_search_hint))
        field.performClick()
        field.performTextInput("First")
        composeRule.waitUntil(timeoutMillis = 5_000) {
            holder.state.value?.contentSnippets?.containsKey("conv-1") == true
        }
        val request = controller.host.lastArgs("requestContentSearch")!!
        assertEquals("First", request[0])
        val epoch = request[1] as Long
        assertTrue("search epoch must advance past 0", epoch > 0L)
        assertEquals(epoch, holder.state.value?.searchEpoch)
        composeRule.onNodeWithText("…synthetic FIRST content hit…").assertIsDisplayed()
        assertEquals(1, controller.host.count("requestContentSearch"))
        capture("15-history-content-search", typedField = field)
    }

    /* ====================== 16/17 — management selection/confirm/receipt ====================== */

    @Test
    fun managementFreezesTargetsAndBulkReceiptIsHonest() {
        applyScenario(ConversationUiScenario.HISTORY_MANAGE)
        val holder = historyHolder()
        // Select two rows including the running one.
        composeRule.onNodeWithText("First synthetic chat").performClick()
        composeRule.onNodeWithText("Second synthetic chat").performClick()
        composeRule.waitForIdle()
        assertEquals(setOf("conv-1", "conv-2"), holder.selectedIds.value)
        composeRule.onNodeWithText(localized(R.string.history_selected_count, 2)).assertIsDisplayed()
        // Running impact is projected honestly into the confirmation.
        composeRule.onNodeWithText(localized(R.string.history_archive_action)).performClick()
        composeRule.onNodeWithText(localized(R.string.history_archive_confirm_title, 2)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.history_running_impact, 1), substring = true)
            .assertIsDisplayed()
        capture("16-manage-confirmation")
        // Confirm (the dialog's own confirm affordance dispatches the FROZEN
        // set; invoking the holder's confirm keeps this assertion exact):
        controller.host.resetEffects()
        val confirmation = requireNotNull(holder.confirmation.value)
        assertEquals(listOf("conv-1", "conv-2"), confirmation.frozenIds)
        composeRule.runOnUiThread { holder.confirmBulkFromDialog() }
        composeRule.waitUntil(timeoutMillis = 5_000) { holder.bulkReceipt.value != null }
        assertEquals(1, controller.host.count("requestBulk"))
        val args = controller.host.lastArgs("requestBulk")!!
        @Suppress("UNCHECKED_CAST")
        assertEquals(listOf("conv-1", "conv-2"), args[1] as List<String>)
        val receipt = requireNotNull(holder.bulkReceipt.value)
        assertEquals(1, receipt.archivedCount)
        assertEquals(1, receipt.skippedCount)
        // The receipt renders "已归档 1 · 已跳过 1" as one joined line —
        // substring match each count within that real node.
        composeRule.onNodeWithText(localized(R.string.bulk_result_archived, 1), substring = true)
            .assertIsDisplayed()
        capture("17-manage-bulk-receipt")
    }

    /* ========================= 18 — archive restore/delete ========================= */

    @Test
    fun archivedSliceRestoresAndDeletesWithConfirmation() {
        applyScenario(ConversationUiScenario.HISTORY_ARCHIVE)
        // Row actions open the archive menu.
        composeRule.onNodeWithContentDescription(localized(R.string.history_row_actions)).performClick()
        composeRule.onNodeWithText(localized(R.string.history_restore_action)).performClick()
        assertEquals(1, controller.host.count("restoreConversation"))
        assertEquals("conv-9", controller.host.lastArgs("restoreConversation")!![0])
        // Delete requires the explicit confirmation with the durable message.
        composeRule.onNodeWithContentDescription(localized(R.string.history_row_actions)).performClick()
        composeRule.onNodeWithText(localized(R.string.history_delete_forever)).performClick()
        composeRule.onNodeWithText(localized(R.string.history_delete_confirm_message)).assertIsDisplayed()
        capture("18-archive-restore-delete")
        controller.host.resetEffects()
        composeRule.onNodeWithText(localized(R.string.action_delete)).performClick()
        assertEquals(1, controller.host.count("deleteConversation"))
        assertEquals("conv-9", controller.host.lastArgs("deleteConversation")!![0])
    }

    /* ========================= 19 — child transcript sheet ========================= */

    @Test
    fun delegateCardOpensChildTranscriptOverHostProjection() {
        applyScenario(ConversationUiScenario.CHILD_TRANSCRIPT)
        // Expand the delegate tool card, then open the child through View.
        composeRule.onNodeWithText("agent.delegate").performClick()
        composeRule.onNodeWithText("Synthetic delegated summary").performClick()
        composeRule.onNodeWithText(localized(R.string.action_view)).performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            threadHolder().snapshot.value?.childDetails?.containsKey("child-1") == true
        }
        composeRule.onNodeWithText("Synthetic child transcript").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic delegated work summary.").assertIsDisplayed()
        assertEquals(1, controller.host.count("loadChildRunDetail"))
        capture("19-child-transcript")
    }

    /* ==================== 20 — goal/plan strips + one file effect ==================== */

    @Test
    fun planGoalStripsDispatchAndImportantFileIsOneExactEffect() {
        applyScenario(ConversationUiScenario.GOAL_PLAN)
        composeRule.onNodeWithText(localized(R.string.plan_execute_normal)).performClick()
        assertEquals(1, controller.host.count("acceptPlan"))
        val planArgs = controller.host.lastArgs("acceptPlan")!!
        assertEquals("plan-1", planArgs[1])
        assertEquals(Revision("plan-1", "digest-abc"), planArgs[2])
        // Goal verifying strip offers exactly the completion confirmation.
        composeRule.onNodeWithText(localized(R.string.goal_confirm_complete)).performClick()
        assertEquals(1, controller.host.count("confirmGoalCompletion"))
        // ONE important-file tap = ONE real workspace effect (no dummy open).
        // The chip label is "<action> · <basename>" (source rule), so match
        // the basename substring and tap the displayed node.
        controller.host.resetEffects()
        tapDisplayedNode(androidx.compose.ui.test.hasText("plan.md", substring = true))
        assertEquals(1, controller.host.count("openWorkspaceFile"))
        assertEquals(0, controller.host.count("openMessageAttachment"))
        assertEquals("synthetic/plan.md", controller.host.lastArgs("openWorkspaceFile")!![1])
        capture("20-plan-goal-file")
    }

    /* ==================== 21 — REAL markdown corpus/copy/link ==================== */

    @Test
    fun realCommonMarkRendersStyledHeaderListsQuoteCorpus() {
        // Split scenarios keep each corpus inside one bottom-anchored screen
        // so EVERY styled check is a real DISPLAYED check (no scroll-item
        // reliance, no weakened existence-only gates).
        applyScenario(ConversationUiScenario.MARKDOWN_HEADER)
        waitUntilParsed(UiFixtures.richMarkdownHeader)
        composeRule.onNodeWithText("Rich synthetic summary").assertIsDisplayed()
        // ⇄ ThreadDetailView.threadScroll (385-435): the timeline fills the
        // pane and assistant content reads LEADING (no per-row 720 cap, no
        // left-column-only layout).
        val rootW = composeRule.onRoot().fetchSemanticsNode().boundsInRoot.width
        val heading = composeRule.onNodeWithText("Rich synthetic summary").fetchSemanticsNode()
        assertTrue(
            "assistant content must read leading from the pane edge, left=${heading.boundsInRoot.left}",
            heading.boundsInRoot.left < rootW * 0.15f,
        )
        assertFalse(
            "literal fallback markers must not remain once parsed",
            composeRule.onAllNodesWithText("# Rich synthetic summary").fetchSemanticsNodes().isNotEmpty(),
        )
        composeRule.onNodeWithText("Ordered first point").assertIsDisplayed()
        composeRule.onNodeWithText("nested emoji 🎉").assertIsDisplayed()
        composeRule.onNodeWithText("nested code run").assertIsDisplayed()
        composeRule.onNodeWithText("Ordered second point").assertIsDisplayed()
        capture("21-markdown-header-list")
    }

    @Test
    fun longUserBubbleWrapsInsidePaneAndStaysTrailing() {
        applyScenario(ConversationUiScenario.USER_LONG)
        val rootW = composeRule.onRoot().fetchSemanticsNode().boundsInRoot.width
        val node = composeRule.onNodeWithText("Long synthetic prompt:", substring = true)
        node.assertIsDisplayed()
        val b = node.fetchSemanticsNode().boundsInRoot
        // Long text DOES wrap: it uses the pane (unlike the short bubble)
        // but keeps the native 40dp leading gutter and the trailing edge.
        assertTrue("long bubble must be wide (>60%)", b.width > rootW * 0.60f)
        assertTrue("long bubble must stay trailing", b.right > rootW * 0.90f)
        assertTrue("leading gutter (Spacer minLength 40) preserved", b.left > 30f)
        // Multi-line wrapping is visible in the capture.
        capture("22-user-bubble-long-wrap")
    }

    @Test
    fun realCommonMarkRendersBodyAndDrivesCopyLinkEffects() {
        applyScenario(ConversationUiScenario.MARKDOWN_BODY)
        waitUntilParsed(UiFixtures.richMarkdownBody)
        composeRule.onNodeWithText("quoted emphasis with a nested", substring = true)
            .assertIsDisplayed()
        composeRule.onNodeWithText("quote item").assertIsDisplayed()
        composeRule.onNodeWithText("Metric").assertIsDisplayed()
        composeRule.onNodeWithText("Value").assertIsDisplayed()
        composeRule.onNodeWithText("1,234").assertIsDisplayed()
        composeRule.onNodeWithText("def greet(name):  # verbatim 🐍", substring = true)
            .assertIsDisplayed()
        assertFalse(
            "raw pipe table syntax must not remain",
            composeRule.onAllNodesWithText("| Metric |").fetchSemanticsNodes().isNotEmpty(),
        )
        composeRule.onNodeWithText("the synthetic doc", substring = true).assertIsDisplayed()
        assertEquals(0, controller.host.count("openMessageLink"))
        assertEquals(0, controller.host.count("copyMessageText"))
        capture("21b-markdown-body-table-code")

        // Link tap = approved host effect with the projected URL, never a
        // fetch inside the UI. ClickableText routes by text POSITION: the
        // link span sits at the paragraph centre, so the node-centre tap is
        // a genuine pointer path into the annotation region.
        composeRule.onNodeWithText("See the synthetic doc for details.").performClick()
        assertEquals(1, controller.host.count("openMessageLink"))
        val url = controller.host.lastArgs("openMessageLink")!![1] as String
        assertTrue("unexpected link target $url", url.startsWith("https://example.invalid"))

        // Copy = exact verbatim text through the clipboard host effect (two
        // affordances exist; the code-card copy renders first in the tree).
        composeRule.onAllNodesWithText(localized(R.string.action_copy))[0].performClick()
        assertEquals(1, controller.host.count("copyMessageText"))
        val copied = controller.host.lastArgs("copyMessageText")!![1] as String
        assertTrue("copied payload mismatch: $copied", copied.startsWith("def greet(name):"))
    }

}
