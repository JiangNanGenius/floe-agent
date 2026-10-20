// SPDX-License-Identifier: MPL-2.0
//
// Instrumentation fixture for the NEW G02 provider/model pages. It renders the
// real Compose pages against the labelled synthetic controller, checks actual
// Compose semantics (sections, menus, manual-add gate, save retry, nested back)
// and saves full-window screenshots for Main's rendered inspection.
//
// Run (device/AVD is Main-owned; this class is compiled but not executed by the
// worker):
//   adb install -r FloeAndroid/feature/providers/build/.../providers-debug-androidTest.apk
//   adb shell am instrument -w -e providerUiLocale zh -e providerUiTheme light \
//       com.floe.android.feature.providers.test/androidx.test.runner.AndroidJUnitRunner
// Screenshots land in the test package's files/provider-ui-screenshots and are
// pulled with run-as. They are synthetic UI evidence, never App/backend proof.

package com.floe.android.feature.providers

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.KeyEvent
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.platform.ViewRootForTest
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProviderUiFixtureTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<ProviderUiFixtureActivity>()

    private lateinit var controller: ProviderFixtureController

    @Before
    fun setUp() {
        controller = composeRule.activity.controller
    }

    private fun localized(id: Int): String = composeRule.activity.getString(id)

    /**
     * The labeled Cupertino search surface wraps the editable text node, so the
     * content-description node itself has no text action. Select the actual
     * editable descendant of that labeled field instead of its container.
     */
    private fun supplierSearchField() = composeRule.onNode(
        hasSetTextAction() and hasAnyAncestor(
            hasContentDescription(localized(R.string.catalog_search_hint)),
        ),
    )

    /**
     * Hide the real platform IME for the window that actually owns [tag] and
     * wait until that window's insets report it gone. The nested model editor
     * and supplier popover are their own windows, so the Activity decor token
     * is not sufficient. Used only immediately before full-view snapshots
     * whose fields were just typed into; entered data and the current sheet are
     * untouched.
     */
    private fun dismissImeAndWait(tag: String) {
        val node = composeRule.onNodeWithTag(tag).fetchSemanticsNode()
        val root = node.root as? ViewRootForTest
            ?: error("dismissImeAndWait: no Android view root for $tag")
        val view = root.view
        // Let the IME consume one Back while it is genuinely visible. On this
        // tablet's floating IME, hideSoftInputFromWindow can leave the
        // minimized keyboard toolbar above the gesture bar; Back closes the
        // IME surface itself without reaching the app/dialog. The visibility
        // guard prevents Back from closing the retained sheet when no IME is
        // shown.
        var imeVisible = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            composeRule.runOnUiThread {
                imeVisible = view.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
            }
        }
        if (imeVisible) {
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            composeRule.waitForIdle()
        }
        composeRule.runOnUiThread {
            val imm = view.context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.hideSoftInputFromWindow(view.windowToken, 0)
            view.clearFocus()
        }
        composeRule.waitForIdle()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            composeRule.waitUntil(timeoutMillis = 5_000) {
                var visible = true
                composeRule.runOnUiThread {
                    visible = view.rootWindowInsets
                        ?.isVisible(WindowInsets.Type.ime()) == true
                }
                !visible
            }
        }
        composeRule.waitForIdle()
    }

    private fun applyScenario(scenario: ProviderFixtureScenario) {
        composeRule.runOnUiThread { controller.applyScenario(scenario) }
        composeRule.waitForIdle()
    }

    private fun sendSystemBack() {
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        composeRule.waitForIdle()
    }

    private fun capture(name: String) {
        composeRule.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        assertNotNull("UiAutomation.takeScreenshot returned null", bitmap)
        val directory = composeRule.activity.getDir("provider-ui-screenshots", Context.MODE_PRIVATE)
        val locale = composeRule.activity.runLocale
        val theme = composeRule.activity.runTheme
        val file = File(directory, "$name-$locale-$theme.png")
        FileOutputStream(file).use { out ->
            bitmap!!.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        File(directory, "run-manifest.txt").appendText(
            "${file.name} | locale=$locale theme=$theme " +
                "size=${bitmap.width}x${bitmap.height} " +
                "scenario=${controller.scenario.name}\n",
        )
        // Same rendered snapshot as a real semantics tree for Main's review.
        writeProviderComposeHierarchy(
            composeRule,
            File(directory, "$name-$locale-$theme.txt"),
        )
    }

    private fun waitUntilGone(tag: String) {
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isEmpty()
        }
    }

    @Test
    fun emptyListRendersSyntheticEmptyState() {
        applyScenario(ProviderFixtureScenario.EMPTY_LIST)
        composeRule.onNodeWithTag("provider.list").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.provider_empty_hint)).assertIsDisplayed()
        composeRule.onNodeWithContentDescription(localized(R.string.provider_add)).assertIsDisplayed()
        capture("01-empty-list")
    }

    @Test
    fun populatedListShowsAwaitingKeyDisabledRowsAndHostError() {
        applyScenario(ProviderFixtureScenario.POPULATED_LIST)
        composeRule.onNodeWithText("Synthetic Chat Provider (fixture)").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.row_waiting_key)).assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Image Provider (fixture)").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.row_disabled)).assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic list error (fixture).").assertIsDisplayed()
        capture("02-populated-list")
    }

    @Test
    fun loadingListShowsProgress() {
        applyScenario(ProviderFixtureScenario.LIST_LOADING)
        composeRule.onNodeWithTag("provider.list").assertIsDisplayed()
        composeRule.onNodeWithContentDescription(localized(R.string.loading_cd)).assertIsDisplayed()
        capture("03-loading-list")
    }

    @Test
    fun compactPurposeChooserOpensWithAllThreeRoles() {
        applyScenario(ProviderFixtureScenario.PURPOSE_COMPACT)
        composeRule.onNodeWithText(localized(R.string.role_chooser_message)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.role_conversation_provider)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.role_image_provider)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.role_video_provider)).assertIsDisplayed()
        capture("04-purpose-compact")
    }

    @Test
    fun widePurposeChooserOpensAnchoredAndChoosesTheRealRole() {
        applyScenario(ProviderFixtureScenario.PURPOSE_WIDE)
        composeRule.onNodeWithTag("provider.addAction").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("provider.purposeMenu").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.role_chooser_message)).assertIsDisplayed()
        // Scope the role labels to the popup: the populated list behind it
        // legitimately shows the same section labels. The test tags prove the
        // three real choice controls are present, not just duplicate text.
        listOf(
            ProviderServiceRoleUi.CONVERSATION to R.string.role_conversation_provider,
            ProviderServiceRoleUi.IMAGE to R.string.role_image_provider,
            ProviderServiceRoleUi.VIDEO to R.string.role_video_provider,
        ).forEach { (role, labelRes) ->
            composeRule.onNode(
                hasText(localized(labelRes)) and
                    hasAnyAncestor(hasTestTag("provider.purposeMenu")),
            ).assertIsDisplayed()
            composeRule.onNodeWithTag("provider.purposeOption.${role.name}").assertIsDisplayed()
        }
        // Standalone component fallback: no Settings host geometry is
        // available here, so the content-fit card uses the measured + trigger.
        // The actual two-pane category-boundary capture is 16 below; this
        // capture remains the component-only fallback proof.
        capture("15-purpose-wide-anchored")

        composeRule.onNodeWithTag("provider.purposeOption.IMAGE").performClick()
        waitUntilGone("provider.purposeMenu")
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.purpose_image)).assertIsDisplayed()
    }

    @Test
    fun widePurposeChooserBackDismissesWithoutOpeningTheEditor() {
        applyScenario(ProviderFixtureScenario.PURPOSE_WIDE)
        composeRule.onNodeWithTag("provider.addAction").performClick()
        composeRule.onNodeWithTag("provider.purposeMenu").assertIsDisplayed()

        sendSystemBack()
        waitUntilGone("provider.purposeMenu")
        composeRule.onNodeWithTag("provider.editorPage").assertDoesNotExist()
        composeRule.onNodeWithTag("provider.list").assertIsDisplayed()
    }

    @Test
    fun wideHostPurposeUsesMeasuredCategoryBoundaryAndChoosesExactlyOnce() {
        applyScenario(ProviderFixtureScenario.PURPOSE_WIDE_HOST)
        composeRule.onNodeWithTag("providerHost.categoryPane").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.addAction").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("provider.purposeMenu").assertIsDisplayed()
        composeRule.onNodeWithTag("floe.hostPopover.arrow.right").assertExists()
        composeRule.onNodeWithTag("floe.hostPopover.arrow.up").assertDoesNotExist()
        listOf(
            ProviderServiceRoleUi.CONVERSATION to R.string.role_conversation_provider,
            ProviderServiceRoleUi.IMAGE to R.string.role_image_provider,
            ProviderServiceRoleUi.VIDEO to R.string.role_video_provider,
        ).forEach { (role, labelRes) ->
            composeRule.onNode(
                hasText(localized(labelRes)) and
                    hasAnyAncestor(hasTestTag("provider.purposeMenu")),
            ).assertIsDisplayed()
            composeRule.onNodeWithTag("provider.purposeOption.${role.name}").assertIsDisplayed()
        }
        capture("16-purpose-wide-host")

        composeRule.onNodeWithTag("provider.purposeOption.IMAGE").performClick()
        waitUntilGone("provider.purposeMenu")
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.purpose_image)).assertIsDisplayed()
        assertEquals(1, controller.host.requestNewProviderCalls)
        assertEquals(1, controller.host.editorOpenedCalls)
    }

    @Test
    fun wideHostPurposeBackDismissesWithoutChoosingOrOpeningAnEditor() {
        applyScenario(ProviderFixtureScenario.PURPOSE_WIDE_HOST)
        composeRule.onNodeWithTag("provider.addAction").performClick()
        composeRule.onNodeWithTag("provider.purposeMenu").assertIsDisplayed()

        sendSystemBack()
        waitUntilGone("provider.purposeMenu")
        composeRule.onNodeWithTag("provider.editorPage").assertDoesNotExist()
        composeRule.onNodeWithTag("provider.list").assertIsDisplayed()
        assertEquals(0, controller.host.requestNewProviderCalls)
        assertEquals(0, controller.host.editorOpenedCalls)
    }

    @Test
    fun wideCollapsedHostPurposeUsesMeasuredTriggerFallbackNotAPhantomCategory() {
        applyScenario(ProviderFixtureScenario.PURPOSE_WIDE_HOST_COLLAPSED)
        composeRule.onNodeWithTag("providerHost.categoryPane").assertDoesNotExist()
        composeRule.onNodeWithTag("provider.addAction").performClick()
        composeRule.onNodeWithTag("provider.purposeMenu").assertIsDisplayed()
        composeRule.onNodeWithTag("floe.hostPopover.arrow.right").assertDoesNotExist()
        composeRule.onNodeWithTag("floe.hostPopover.arrow.up").assertExists()
        composeRule.onNodeWithTag("provider.purposeOption.CONVERSATION").assertIsDisplayed()
        capture("17-purpose-wide-fallback")

        composeRule.onNodeWithTag("provider.purposeOption.VIDEO").performClick()
        waitUntilGone("provider.purposeMenu")
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        assertEquals(1, controller.host.requestNewProviderCalls)
        assertEquals(1, controller.host.editorOpenedCalls)
    }

    @Test
    fun wideHostLargeFontKeepsAllThreeRoleActionsReachableInTheBoundedScroll() {
        applyScenario(ProviderFixtureScenario.PURPOSE_WIDE_HOST_LARGE_FONT)
        composeRule.onNodeWithTag("provider.addAction").performClick()
        composeRule.onNodeWithTag("provider.purposeMenu").assertIsDisplayed()
        composeRule.onNodeWithTag("floe.hostPopover.arrow.right").assertExists()
        composeRule.onNodeWithTag("floe.hostPopover.scroll").performScrollToNode(
            hasTestTag("provider.purposeOption.VIDEO"),
        )
        composeRule.onNodeWithTag("provider.purposeOption.CONVERSATION").assertExists()
        composeRule.onNodeWithTag("provider.purposeOption.IMAGE").assertExists()
        composeRule.onNodeWithTag("provider.purposeOption.VIDEO").assertIsDisplayed()
        capture("18-purpose-wide-host-large-font")
    }

    @Test
    fun editorTopKeepsCancelSaveAndLeadingTitleHierarchy() {
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.editor_edit_title)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.action_cancel)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.action_save)).assertIsDisplayed()
        composeRule.onNodeWithTag("provider.supplierRow").assertIsDisplayed()
        capture("05-editor-top-wide")
    }

    @Test
    fun editorBottomScrollsToModelsWhileSaveStaysVisible() {
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        composeRule.onNodeWithTag("provider.editorForm")
            .performScrollToNode(hasText(localized(R.string.providers_manage_models)))
        composeRule.onNodeWithText(localized(R.string.providers_manage_models)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.action_save)).assertIsDisplayed()
        capture("06-editor-bottom-wide")
    }

    @Test
    fun supplierChooserIsAnchoredAndShowsFiltersSearchAndCustom() {
        applyScenario(ProviderFixtureScenario.SUPPLIER_ANCHORED)
        composeRule.onNodeWithTag("provider.supplierPopover").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.supplierChooser").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.catalog_title)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.catalog_filter_all)).assertIsDisplayed()
        composeRule.onNodeWithText("Manual / Custom Endpoint (fixture)").assertIsDisplayed()
        capture("07-supplier-anchored-wide")
    }

    @Test
    fun supplierSearchFiltersTheLocalCatalog() {
        applyScenario(ProviderFixtureScenario.SUPPLIER_ANCHORED)
        supplierSearchField().performTextInput("official alpha")
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Synthetic Official Alpha").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Official Beta").assertDoesNotExist()
        dismissImeAndWait("provider.supplierPopover")
        composeRule.onNodeWithText("Synthetic Official Alpha").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Official Beta").assertDoesNotExist()
        capture("08-supplier-search-wide")

        supplierSearchField().performTextClearance()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Manual / Custom Endpoint (fixture)").assertIsDisplayed()
    }

    @Test
    fun protocolMenuListsTheThreeRealProtocols() {
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        composeRule.onNodeWithTag("provider.protocolField").performClick()
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText("OpenAI Responses").assertCountEquals(1)
        composeRule.onAllNodesWithText("OpenAI Chat Completions").assertCountEquals(2)
        composeRule.onAllNodesWithText("Anthropic Messages").assertCountEquals(1)
        composeRule.onNodeWithTag("provider.protocolMenu").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.protocolOption.OPENAI_CHAT_COMPLETIONS")
            .assertIsSelected()
        capture("09-protocol-menu-wide")
    }

    @Test
    fun protocolMenuSelectionAndBackPreserveTheDraftAndEditor() {
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        assertEquals(WireProtocolUi.OPENAI_CHAT_COMPLETIONS, controller.currentDraftProtocol())
        composeRule.onNodeWithTag("provider.protocolField").performClick()
        composeRule.onNodeWithTag("provider.protocolMenu").assertIsDisplayed()

        composeRule.onNodeWithTag("provider.protocolOption.ANTHROPIC_MESSAGES").performClick()
        waitUntilGone("provider.protocolMenu")
        assertEquals(WireProtocolUi.ANTHROPIC_MESSAGES, controller.currentDraftProtocol())
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText("Anthropic Messages").assertIsDisplayed()

        // Reopen and dismiss with system back: only the menu closes.
        composeRule.onNodeWithTag("provider.protocolField").performClick()
        composeRule.onNodeWithTag("provider.protocolMenu").assertIsDisplayed()
        sendSystemBack()
        waitUntilGone("provider.protocolMenu")
        assertEquals(WireProtocolUi.ANTHROPIC_MESSAGES, controller.currentDraftProtocol())
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
    }

    @Test
    fun singleAvailableProtocolLocksTheMenu() {
        applyScenario(ProviderFixtureScenario.EDITOR_LOCKED_PROTOCOL)
        composeRule.onNodeWithTag("provider.protocolField").assertIsNotEnabled()
        composeRule.onNodeWithText("Anthropic Messages").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.protocolMenu").assertDoesNotExist()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
    }

    @Test
    fun modelManagerKeepsCapturedHeaderAndManualAddGate() {
        applyScenario(ProviderFixtureScenario.MODEL_MANAGER)
        composeRule.onNodeWithTag("provider.modelManager").assertIsDisplayed()
        composeRule.onNodeWithContentDescription(localized(R.string.providers_refresh_models))
            .assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.action_done)).assertIsDisplayed()
        composeRule.onNodeWithTag("provider.addModelAction").assertIsNotEnabled()

        composeRule.onNodeWithContentDescription(localized(R.string.manager_model_id))
            .performTextInput("synthetic-manual-model")
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("provider.addModelAction").assertIsEnabled()
        dismissImeAndWait("provider.modelManager")
        composeRule.onNodeWithTag("provider.modelManager").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.addModelAction").assertIsEnabled()
        capture("10-model-manager-wide")
    }

    @Test
    fun modelEditorShowsIdentityCapabilitiesAndLimits() {
        applyScenario(ProviderFixtureScenario.MODEL_EDITOR)
        composeRule.onNodeWithTag("provider.modelEditor").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.model_editor_title)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.model_section_identity)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.model_section_capabilities)).assertIsDisplayed()
        // The limits section sits below the initial viewport of this scrollable
        // form; scroll with the real scroll action, then prove the section and
        // its editable token field are actually visible and usable.
        val modelEditorForm = composeRule.onNodeWithTag("provider.modelEditorForm")
        modelEditorForm.performScrollToNode(hasText(localized(R.string.model_section_limits)))
        composeRule.onNodeWithText(localized(R.string.model_section_limits)).assertIsDisplayed()
        modelEditorForm.performScrollToNode(
            hasContentDescription(localized(R.string.model_context_tokens)),
        )
        val contextTokens = composeRule.onNodeWithContentDescription(
            localized(R.string.model_context_tokens),
        )
        contextTokens.assertIsDisplayed().assertIsEnabled()
        contextTokens.performTextClearance()
        contextTokens.performTextInput("65536")
        composeRule.waitForIdle()
        contextTokens.assertTextContains("65536")
        dismissImeAndWait("provider.modelEditor")
        contextTokens.assertTextContains("65536")
        composeRule.onNodeWithText(localized(R.string.model_section_limits)).assertIsDisplayed()
        // The outer provider editor and this nested model editor both expose a
        // Save capsule; select the nested one by its model-editor ancestor.
        composeRule.onNode(
            hasText(localized(R.string.action_save)) and
                hasAnyAncestor(hasTestTag("provider.modelEditor")),
        ).assertIsDisplayed().assertIsEnabled()
        capture("11-model-editor-wide")
    }

    @Test
    fun saveFailureAlertAcknowledgesAndRetryReAlertsWithTheSameMessage() {
        applyScenario(ProviderFixtureScenario.SAVE_RETRY)
        val nameField = composeRule.onNodeWithContentDescription(
            localized(R.string.providers_display_name),
        )
        nameField.performTextClearance()
        nameField.performTextInput("Synthetic Retained Name")
        composeRule.waitForIdle()
        // The draft is what matters here; do not leave the IME over the
        // retained editor/alert capture.
        dismissImeAndWait("provider.editorPage")

        composeRule.onNodeWithTag("provider.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.host.saveCalls)

        composeRule.runOnUiThread {
            controller.publishSaveError("Synthetic save failed (fixture).")
        }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText(localized(R.string.providers_save_failed_cd))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic save failed (fixture).").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_ok)).assertIsDisplayed()
        // The intentional capture state is now the immediate alert, not the
        // former inline banner.
        capture("12-save-error-retry-wide")

        composeRule.onNodeWithText(localized(R.string.providers_save_failed_ok)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertDoesNotExist()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        nameField.assertTextContains("Synthetic Retained Name")

        // A retry releases the holder latch and dispatches again.
        composeRule.onNodeWithTag("provider.saveAction").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(2, controller.host.saveCalls)

        // Host attempt boundary (in-flight, old error cleared), then the SAME
        // message fails again: the alert must open again.
        composeRule.runOnUiThread { controller.beginSaveAttempt() }
        composeRule.waitForIdle()
        composeRule.runOnUiThread {
            controller.publishSaveError("Synthetic save failed (fixture).")
        }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText(localized(R.string.providers_save_failed_cd))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic save failed (fixture).").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()

        // Back on the alert acknowledges it; it must not dismiss the retained
        // editor or discard the draft.
        sendSystemBack()
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText(localized(R.string.providers_save_failed_cd))
                .fetchSemanticsNodes().isEmpty()
        }
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        nameField.assertTextContains("Synthetic Retained Name")
    }

    @Test
    fun sameFrameSaveRetryReAlertsAfterAcknowledgement() {
        applyScenario(ProviderFixtureScenario.SAVE_RETRY)
        val nameField = composeRule.onNodeWithContentDescription(
            localized(R.string.providers_display_name),
        )
        nameField.performTextClearance()
        nameField.performTextInput("Synthetic Retained Name")
        composeRule.waitForIdle()
        dismissImeAndWait("provider.editorPage")

        // First attempt fails asynchronously, then the user acknowledges it.
        composeRule.onNodeWithTag("provider.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.host.saveCalls)
        composeRule.runOnUiThread {
            controller.publishSaveError("Synthetic save failed (fixture).")
        }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText(localized(R.string.providers_save_failed_cd))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_ok)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertDoesNotExist()
        nameField.assertTextContains("Synthetic Retained Name")

        // The retry's begin and failure projections are both published inside
        // the save dispatch with the SAME message. The composition can only
        // see the coalesced final state, so this is the real regression that
        // a distinct beginSaveAttempt/publishSaveError sequence cannot cover.
        controller.armSameFrameSaveFailure("Synthetic save failed (fixture).")
        composeRule.onNodeWithTag("provider.saveAction").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(2, controller.host.saveCalls)

        // The new attempt must surface its own immediate alert, not be
        // suppressed as the already-acknowledged old failure.
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText(localized(R.string.providers_save_failed_cd))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic save failed (fixture).").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        nameField.assertTextContains("Synthetic Retained Name")
        // The same failure outcome released the duplicate-save latch, so the
        // user can retry again rather than being stuck in a permanent spinner.
        composeRule.onNodeWithTag("provider.saveAction").assertIsEnabled()

        // OK hides only the alert; the editor and draft stay retained.
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_ok)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertDoesNotExist()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        nameField.assertTextContains("Synthetic Retained Name")
    }

    @Test
    fun stalePreviousEditorFailureCannotAlertTheNewEditor() {
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        val staleIdentity = requireNotNull(controller.currentIdentity())
        composeRule.runOnUiThread {
            controller.publishSaveError("Stale save failure (fixture).")
        }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText("Stale save failure (fixture).")
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("Stale save failure (fixture).").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_ok)).performClick()
        composeRule.waitForIdle()

        // A genuinely new editor has a different editor id; a late projection
        // for the old one must not raise an alert over it.
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        val newIdentity = requireNotNull(controller.currentIdentity())
        assertNotEquals(staleIdentity.editorId, newIdentity.editorId)
        composeRule.runOnUiThread {
            controller.publishStaleSaveFailure(staleIdentity, "Stale save failure (fixture).")
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertDoesNotExist()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
    }

    @Test
    fun connectionFailureStaysInlineAndDoesNotOpenTheSaveAlert() {
        applyScenario(ProviderFixtureScenario.EDITOR_TOP)
        val reason = "Synthetic connection failed (fixture)."
        composeRule.runOnUiThread { controller.publishConnectionFailure(reason) }
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("provider.editorForm")
            .performScrollToNode(hasText(reason))
        composeRule.onNodeWithText(reason).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.providers_save_failed_cd)).assertDoesNotExist()
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
    }

    @Test
    fun systemBackClosesModelEditorThenManagerThenProviderEditor() {
        applyScenario(ProviderFixtureScenario.MODEL_EDITOR)
        composeRule.onNodeWithTag("provider.modelEditor").assertIsDisplayed()

        sendSystemBack()
        waitUntilGone("provider.modelEditor")
        composeRule.onNodeWithTag("provider.modelManager").assertIsDisplayed()

        sendSystemBack()
        waitUntilGone("provider.modelManager")
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()

        sendSystemBack()
        waitUntilGone("provider.editorPage")
        composeRule.onNodeWithTag("provider.list").assertIsDisplayed()
    }

    @Test
    fun secureFieldRevealTogglesWithoutCapturingTheRevealedSecret() {
        applyScenario(ProviderFixtureScenario.SECURE_FIELD)
        composeRule.onNodeWithContentDescription(localized(R.string.providers_api_key))
            .performTextInput("sk-synthetic-fixture-not-a-key")
        composeRule.onNodeWithContentDescription(localized(R.string.providers_show_api_key))
            .performClick()
        composeRule.onNodeWithContentDescription(localized(R.string.providers_hide_api_key))
            .assertIsDisplayed()
        // Deliberately no screenshot in the revealed state: never export a
        // visible synthetic-sentinel secret, even one that cannot authenticate.
        composeRule.onNodeWithContentDescription(localized(R.string.providers_hide_api_key))
            .performClick()
        composeRule.onNodeWithContentDescription(localized(R.string.providers_show_api_key))
            .assertIsDisplayed()
        capture("13-secure-field-masked")
    }

    @Test
    fun compactEditorUsesCompactSheetAndBackReturnsToList() {
        applyScenario(ProviderFixtureScenario.EDITOR_COMPACT)
        composeRule.onNodeWithTag("provider.editorPage").assertIsDisplayed()
        composeRule.onNodeWithTag("provider.supplierRow").assertIsDisplayed()
        capture("14-editor-compact")

        sendSystemBack()
        waitUntilGone("provider.editorPage")
        composeRule.onNodeWithTag("provider.list").assertIsDisplayed()
    }
}
