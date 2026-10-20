// SPDX-License-Identifier: MPL-2.0
//
// Instrumentation fixture for the G02 Skills/MCP administration pages. It
// renders the REAL FloeSkillsSettingsDestination against the labelled
// synthetic controller, checks actual Compose semantics (segments, import
// route distinctness, review/upgrade/form fencing, save latches, credential
// intents, refresh generations, run-scope latches) and saves full-window
// screenshots for Main's rendered inspection. Below-the-fold content is
// reached through real scroll actions on the owning page (never blind
// coordinates), matching the accepted provider fixture methodology.
//
// Run (device/AVD is Main-owned; this class is compiled here and executed by
// the qualification stage):
//   adb install -r integrations-debug-androidTest.apk
//   adb shell am instrument -w -e integrationsUiLocale zh -e integrationsUiTheme light \
//       com.floe.android.feature.integrations.test/androidx.test.runner.AndroidJUnitRunner
// Screenshots land in the test package's files/integrations-ui-screenshots
// and are pulled with run-as. They are synthetic UI evidence, never App or
// backend proof.

package com.floe.android.feature.integrations

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.KeyEvent
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
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
import androidx.compose.ui.test.printToString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.FixMethodOrder
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters

@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class IntegrationsUiFixtureTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<IntegrationsUiFixtureActivity>()

    private lateinit var controller: IntegrationsFixtureController

    @Before
    fun setUp() {
        controller = composeRule.activity.controller
    }

    private fun localized(id: Int): String = composeRule.activity.getString(id)

    private fun localized(id: Int, vararg args: Any?): String =
        composeRule.activity.getString(id, *args)

    private fun applyScenario(scenario: IntegrationsFixtureScenario) {
        composeRule.runOnUiThread { controller.applyScenario(scenario) }
        composeRule.waitForIdle()
    }

    private fun onUi(block: () -> Unit) {
        composeRule.runOnUiThread(block)
        composeRule.waitForIdle()
    }

    private fun sendSystemBack() {
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        composeRule.waitForIdle()
    }

    /** Scroll the owning page's list column until [matcher]'s node is shown.
     * Some pages tag the scroll column itself; others tag an outer Box. */
    private fun scrollIn(pageTag: String, matcher: SemanticsMatcher) {
        val self = composeRule.onAllNodes(hasScrollAction() and hasTestTag(pageTag))
        if (self.fetchSemanticsNodes().isNotEmpty()) {
            self[0].performScrollToNode(matcher)
        } else {
            composeRule
                .onNode(hasScrollAction() and hasAnyAncestor(hasTestTag(pageTag)))
                .performScrollToNode(matcher)
        }
        composeRule.waitForIdle()
    }

    private fun hubScroll(matcher: SemanticsMatcher) = scrollIn("skills.hub", matcher)

    /** Click the last match (used for popup options / dialog buttons that
     * share their label text with the underlying row). */
    private fun clickLast(matcher: SemanticsMatcher) {
        val all = composeRule.onAllNodes(matcher)
        val index = all.fetchSemanticsNodes().size - 1
        all[index].performClick()
    }

    private fun field(label: String) = composeRule.onNodeWithContentDescription(label)

    private fun rowOf(rowContentDescription: String) =
        composeRule.onNode(hasContentDescription(rowContentDescription))

    private fun switchInRow(rowContentDescription: String) = composeRule.onNode(
        isToggleable() and hasAnyAncestor(hasContentDescription(rowContentDescription)),
    )

    /** Hide the platform IME for the window that owns [tag] before capture
     * (same non-destructive recovery the accepted provider fixture used). */
    private fun dismissImeAndWait(tag: String) {
        val node = composeRule.onNodeWithTag(tag).fetchSemanticsNode()
        val root = node.root as? ViewRootForTest ?: return
        val view = root.view
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
                    visible = view.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
                }
                !visible
            }
        }
        composeRule.waitForIdle()
    }

    private fun capture(name: String, imeTag: String? = null) {
        composeRule.waitForIdle()
        if (imeTag != null) dismissImeAndWait(imeTag)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        assertNotNull("UiAutomation.takeScreenshot returned null", bitmap)
        val directory = composeRule.activity.getDir("integrations-ui-screenshots", Context.MODE_PRIVATE)
        val locale = composeRule.activity.runLocale
        val theme = composeRule.activity.runTheme
        val file = File(directory, "$name-$locale-$theme.png")
        FileOutputStream(file).use { out ->
            bitmap!!.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        File(directory, "run-manifest.txt").appendText(
            "${file.name} | locale=$locale theme=$theme " +
                "size=${bitmap.width}x${bitmap.height} " +
                "scenario=${controller.currentScenario}\n",
        )
    }

    /** Scroll the owning page until the row identified by
     * [rowContentDescription] is in view, then assert that SAME row node
     * displays [text]. Merged semantics attach a row's texts to the row
     * container, so this is the strong visibility + reachability proof (a
     * descendant matcher would be semantically wrong here). */
    private fun assertRowShows(pageTag: String, rowContentDescription: String, text: String) {
        scrollIn(pageTag, hasContentDescription(rowContentDescription))
        // 1) The UNIQUE owner row is visible after the real scroll.
        composeRule.onNode(hasContentDescription(rowContentDescription)).assertIsDisplayed()
        // 2) A strictly same-row text-node collection (merged into the row
        //    container or nested inside it) must contain at least one
        //    ACTUALLY displayed node. Matches outside the owner row are
        //    rejected by the scoping matcher; no unscoped global text.
        val nodes = composeRule.onAllNodes(rowScopedMatcher(rowContentDescription, text))
        val count = nodes.fetchSemanticsNodes().size
        assertTrue(
            "row has no node carrying the expected text: $rowContentDescription",
            count > 0,
        )
        var lastError: Throwable? = null
        for (i in 0 until count) {
            try {
                nodes[i].assertIsDisplayed()
                return
            } catch (e: Throwable) {
                lastError = e
            }
        }
        throw AssertionError("no in-row node currently displays '$text'", lastError)
    }

    /** A row's text lives either merged into the row container (MCP rows)
     * or in nested labelled nodes (hub badges/offers). Both branches stay
     * scoped to the SAME owner row. */
    private fun rowScopedMatcher(rowContentDescription: String, text: String) =
        (hasText(text) and hasAnyAncestor(hasContentDescription(rowContentDescription))) or
            (hasText(text) and hasContentDescription(rowContentDescription))

    private fun waitUntilGone(tag: String) {
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isEmpty()
        }
    }

    /* ================================ HUB ================================ */

    @Test
    fun t01_discoverSegmentRendersCardsAndThreeImportRows() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        composeRule.onNodeWithTag("skills.hub").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.plugins_discover)).assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Office Plugin").assertIsDisplayed()
        composeRule.onNodeWithTag("skills.catalogUpdate").assertExists()
        composeRule.onNodeWithTag("skills.catalogInstall").assertExists()
        // Three DISTINCT import destinations (SKL routing).
        composeRule.onNodeWithText(localized(R.string.plugins_import)).assertExists()
        composeRule.onNodeWithText(localized(R.string.skills_import_folder)).assertExists()
        composeRule.onNodeWithText(localized(R.string.skills_creator)).assertExists()
        capture("01-hub-discover")
        // Shared scripted-update preference + connectors entry (scrolled in).
        hubScroll(hasText(localized(R.string.connectors_manage)))
        composeRule.onNodeWithText(localized(R.string.skills_auto_updates_label)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.connectors_manage)).assertIsDisplayed()
        capture("02-hub-discover-bottom")
    }

    @Test
    fun t02_installedSegmentRendersAvailabilityOfferAndOverride() {
        applyScenario(IntegrationsFixtureScenario.HUB_INSTALLED)
        composeRule.runOnUiThread { controller.holder.showingInstalled.value = true }
        composeRule.waitForIdle()
        assertRowShows(
            "skills.hub", localized(R.string.skills_row_cd, "Synthetic Installed Skill"),
            localized(R.string.skills_badge_usable),
        )
        assertRowShows(
            "skills.hub", localized(R.string.skills_row_cd, "Synthetic Needs Setup"),
            "Synthetic: add the missing capability in its settings.",
        )
        composeRule.onNodeWithTag("skills.updateAction").assertIsDisplayed()
        assertRowShows(
            "skills.hub", localized(R.string.skills_row_cd, "Synthetic Environment Skill"),
            "Synthetic: the Linux environment is starting.",
        )
        assertRowShows(
            "skills.hub", localized(R.string.skills_row_cd, "Synthetic Override Skill"),
            "Synthetic note: not offered in this model's task.",
        )
        capture("03-hub-installed-middle")
        // The bundled read-only guide renders its host reason, no toggles.
        assertRowShows(
            "skills.hub", localized(R.string.skills_row_cd, "Synthetic Guide"),
            "Synthetic: update only with the app.",
        )
        capture("04-hub-installed-bottom")
    }

    @Test
    fun t03_emptyInstalledAndHostErrorLines() {
        applyScenario(IntegrationsFixtureScenario.HUB_EMPTY_ERROR)
        composeRule.runOnUiThread { controller.holder.showingInstalled.value = true }
        composeRule.waitForIdle()
        composeRule.onNodeWithText(localized(R.string.skills_empty)).assertIsDisplayed()
        composeRule.runOnUiThread { controller.holder.showingInstalled.value = false }
        composeRule.waitForIdle()
        hubScroll(hasText("Synthetic catalog error"))
        composeRule.onNodeWithTag("skills.catalogError").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic catalog error").assertIsDisplayed()
        composeRule.onNodeWithTag("skills.errorMessage").assertExists()
        composeRule.onNodeWithText("Synthetic host error line").assertExists()
        capture("05-hub-error")
    }

    @Test
    fun t04_searchFiltersHubLocally() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        val search = composeRule.onNode(
            hasSetTextAction() and hasAnyAncestor(hasTestTag("skills.hub")),
        )
        search.performTextInput("PDF")
        composeRule.onNodeWithText("Synthetic PDF Plugin").assertIsDisplayed()
        composeRule.onAllNodesWithText("Synthetic Office Plugin").assertCountEquals(0)
        capture("06-hub-search", imeTag = "skills.hub")
    }

    @Test
    fun t05_enableToggleDispatchesExactlyOneHostEffectPerTap() {
        applyScenario(IntegrationsFixtureScenario.HUB_INSTALLED)
        composeRule.runOnUiThread { controller.holder.showingInstalled.value = true }
        composeRule.waitForIdle()
        val rowCd = localized(R.string.skills_row_cd, "Synthetic Installed Skill")
        hubScroll(hasContentDescription(rowCd))
        switchInRow(rowCd).performClick()
        composeRule.waitForIdle()
        assertEquals(
            listOf(Triple("synthetic-skill-a", "synthetic-digest-a", false)),
            controller.skillToggles,
        )
        // The host echo retracts the offer FOR THIS ROW ONLY (no derived
        // state): row A no longer shows the offered line, and now visibly
        // shows the host's retraction text after a real scroll into view.
        composeRule.onAllNodes(rowScopedMatcher(rowCd, localized(R.string.skills_offered)))
            .assertCountEquals(0)
        composeRule.onAllNodes(rowScopedMatcher(rowCd, localized(R.string.skills_badge_usable)))
            .assertCountEquals(0)
        assertRowShows("skills.hub", rowCd, localized(R.string.skills_not_offered))
    }

    @Test
    fun t06_autoUpdateToggleOneSharedEffect() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasText(localized(R.string.skills_auto_updates_label)))
        // The Discover segment renders exactly one switch: the shared
        // scripted-update preference (one value with Settings → Content
        // updates, never a second copy).
        composeRule.onNode(isToggleable()).performClick()
        composeRule.waitForIdle()
        assertEquals(listOf(true), controller.scriptedUpdates)
    }

    @Test
    fun t07_runStopLatchesCancellingAndBlocksDuplicate() {
        applyScenario(IntegrationsFixtureScenario.HUB_INSTALLED)
        composeRule.runOnUiThread {
            controller.holder.showingInstalled.value = true
            controller.holder.hubSearchQuery.value = "Running"
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(localized(R.string.skills_run_stop))
            .assertIsDisplayed()
            .performClick()
        composeRule.waitForIdle()
        assertEquals(
            listOf<SkillRunScopeUi>(
                SkillRunScopeUi.RunOnly("synthetic-task", "synthetic-run", null, 1),
            ),
            controller.cancelledScopes,
        )
        // Holder latch: the SAME affordance switches to the host-side label
        // and the disabled semantics prove the duplicate guard is not just
        // cosmetic (the holder would also reject the dispatch).
        val cancelling = composeRule.onNodeWithContentDescription(localized(R.string.skills_run_cancelling))
        cancelling.assertIsDisplayed().assertIsNotEnabled()
        capture("07-run-cancelling")
        // Terminal projection clears the latch.
        onUi { controller.emitRunTerminal("synthetic-skill-e") }
        composeRule.onNodeWithContentDescription(localized(R.string.skills_run_cancelling)).assertDoesNotExist()
    }

    /* ============================ IMPORT ROUTES ============================ */

    @Test
    fun t08_finderAndCreatorHeaderActionsAreDistinct() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        composeRule.onNodeWithContentDescription(localized(R.string.skills_finder)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("skills.form").assertIsDisplayed()
        assertEquals(0, controller.folderStagingRequests)
        sendSystemBack()
        composeRule.onNodeWithContentDescription(localized(R.string.skills_creator)).performClick()
        composeRule.waitForIdle()
        // The creator form (its unique first field) opened, not the finder.
        composeRule.onNodeWithTag("skills.form").assertIsDisplayed()
        composeRule.onNodeWithContentDescription(localized(R.string.skills_name)).assertIsDisplayed()
    }

    @Test
    fun t09_folderRowOnlyAsksHostToStageOpensNothing() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasText(localized(R.string.skills_import_folder)))
        composeRule.onNodeWithText(localized(R.string.skills_import_folder)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.folderStagingRequests)
        // Nothing opened inside the module until a staged reference arrives.
        composeRule.onAllNodesWithTag("skills.form").assertCountEquals(0)
    }

    @Test
    fun t10_finderUrlFormDispatchesAndErrorKeepsSheet() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasText(localized(R.string.plugins_import)))
        composeRule.onNodeWithText(localized(R.string.plugins_import)).performClick()
        composeRule.waitForIdle()
        // Finder sheet — NOT the folder picker (distinct route pinned).
        composeRule.onNodeWithTag("skills.form").assertIsDisplayed()
        scrollIn("skills.form", hasContentDescription("https://…"))
        field("https://…").performTextInput("https://synthetic.invalid/repo")
        // Select the rewrite model so install becomes enabled.
        scrollIn("skills.form", hasContentDescription(localized(R.string.skills_finder_model), substring = true))
        composeRule
            .onNode(hasContentDescription(localized(R.string.skills_finder_model), substring = true))
            .performClick()
        composeRule.waitForIdle()
        clickLast(hasText("Synthetic Rewrite Model"))
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("skills.finderInstall").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.finderInstalls.size)
        val (formId, url, modelId) = controller.finderInstalls.first()
        assertEquals("https://synthetic.invalid/repo", url)
        assertEquals("synthetic-model", modelId)
        onUi { controller.emitFormOutcomeFor(formId, succeeded = false, message = "Synthetic finder failure") }
        composeRule.onNodeWithTag("skills.formError").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic finder failure").assertIsDisplayed()
        capture("08-finder-error", imeTag = "skills.form")
        onUi { controller.emitFormOutcomeFor(formId, succeeded = true, message = null) }
        waitUntilGone("skills.form")
    }

    @Test
    fun t11_creatorFormGatesThenDispatchesDraft() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasText(localized(R.string.skills_creator)))
        composeRule.onNodeWithText(localized(R.string.skills_creator)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("skills.creatorInstall").assertIsNotEnabled()
        scrollIn("skills.form", hasContentDescription(localized(R.string.skills_name)))
        field(localized(R.string.skills_name)).performTextInput("Synthetic Created Skill")
        field(localized(R.string.skills_description)).performTextInput("Synthetic when-to-use")
        scrollIn("skills.form", hasContentDescription(localized(R.string.skills_instructions)))
        field(localized(R.string.skills_instructions)).performTextInput("Synthetic instructions")
        composeRule.onNodeWithTag("skills.creatorInstall").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        val (formId, draft) = controller.createdForms.first()
        assertEquals("Synthetic Created Skill", draft.name)
        onUi { controller.emitFormOutcomeFor(formId, succeeded = true, message = null) }
        waitUntilGone("skills.form")
    }

    @Test
    fun t12_stagedFolderArrivalOpensConfirmAndInstallsOpaqueHandle() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasText(localized(R.string.skills_import_folder)))
        composeRule.onNodeWithText(localized(R.string.skills_import_folder)).performClick()
        composeRule.waitForIdle()
        onUi { controller.deliverStagedPackage(syntheticStagedRef) }
        composeRule.onNodeWithTag("skills.form").assertIsDisplayed()
        scrollIn("skills.form", hasText("Synthetic Staged Package"))
        composeRule.onNodeWithText("Synthetic Staged Package").assertIsDisplayed()
        // Opaque handle only: no filesystem path, no bytes, no handle leak.
        composeRule.onNodeWithText("synthetic-handle-7").assertDoesNotExist()
        composeRule.onNodeWithTag("skills.importInstall").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("synthetic-handle-7"), controller.stagedImports.map { it.second })
        capture("09-import-confirm")
        val formId = controller.stagedImports.first().first
        onUi { controller.emitFormOutcomeFor(formId, succeeded = true, message = null) }
        waitUntilGone("skills.form")
    }

    /* ============================= CONNECTORS ============================= */

    private fun openConnectors() {
        hubScroll(hasText(localized(R.string.connectors_manage)))
        composeRule.onNodeWithText(localized(R.string.connectors_manage)).performClick()
        composeRule.waitForIdle()
    }

    private fun openMcpList() {
        openConnectors()
        composeRule.onNodeWithTag("connectors.page").assertIsDisplayed()
        scrollIn("connectors.page", hasText(localized(R.string.connectors_mcp_title)))
        composeRule.onNodeWithText(localized(R.string.connectors_mcp_title)).performClick()
        composeRule.waitForIdle()
    }

    @Test
    fun t13_connectorsSheetRoutesHostDestinationsOnly() {
        applyScenario(IntegrationsFixtureScenario.CONNECTORS)
        openConnectors()
        composeRule.onNodeWithTag("connectors.page").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Mail").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Account").assertExists()
        scrollIn("connectors.page", hasText("Synthetic: sign in to connect."))
        composeRule.onNodeWithText("Synthetic: sign in to connect.").assertIsDisplayed()
        scrollIn("connectors.page", hasText("Synthetic Tool Source"))
        composeRule.onNodeWithText("Synthetic Tool Source").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.connectors_mcp_title)).assertIsDisplayed()
        capture("10-connectors")
        composeRule.onNodeWithText("Synthetic Mail").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("synthetic-mail"), controller.connectorOpens)
        sendSystemBack()
        composeRule.onNodeWithTag("skills.hub").assertIsDisplayed()
    }

    /* ================================ MCP ================================= */

    @Test
    fun t14_mcpListProjectsAllHonestStates() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        composeRule.onNodeWithTag("mcp.servers").assertIsDisplayed()
        // Each state is reached by a real scroll and proven displayed on its
        // OWN row. (The first draft asserted the raw message string; the row
        // actually renders the composed localized label
        // "Connection failed: <message>" / "连接失败：<message>", so the raw
        // exact match was semantically wrong — documented with the retained
        // failure evidence.)
        assertRowShows(
            "mcp.servers", localized(R.string.mcp_row_cd, "Synthetic Ready Server"),
            localized(R.string.mcp_state_tools_available, 4),
        )
        assertRowShows(
            "mcp.servers", localized(R.string.mcp_row_cd, "Synthetic Connecting Server"),
            localized(R.string.mcp_state_reading_tools),
        )
        assertRowShows(
            "mcp.servers", localized(R.string.mcp_row_cd, "Synthetic Failed Server"),
            localized(R.string.mcp_state_failed, "Synthetic failure for layout review"),
        )
        // Absence is host-projected: the four labelled synthetic rows and
        // nothing else (the module adds no rows of its own).
        assertEquals(4, controller.state.value.mcp.servers.size)
        capture("11-mcp-list")
    }

    @Test
    fun t15_mcpRefreshCancelBindsOneGeneration() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        scrollIn("mcp.servers", hasTestTag("mcp.cancelRefresh"))
        composeRule.onNodeWithTag("mcp.cancelRefresh").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("synthetic-server-connecting" to 5L), controller.mcpRefreshCancels)
        composeRule.onNodeWithText(localized(R.string.mcp_state_cancelling)).assertIsDisplayed()
        capture("12-mcp-cancelling")
        onUi {
            controller.emitMcpState(
                "synthetic-server-connecting",
                McpConnectionStateUi.Ready(toolCount = 2),
                tools = listOf(syntheticTool("synthetic_tool", "Synthetic Tool")),
            )
        }
        composeRule.onNodeWithText(localized(R.string.mcp_state_tools_available, 2)).assertIsDisplayed()
    }

    @Test
    fun t16_mcpEnableToggleOneEffectWithHostEcho() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Disabled Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        switchInRow(rowCd).performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("synthetic-server-disabled" to true), controller.mcpServerToggles)
        // The host echo: enabling triggers the host's own refresh projection,
        // displayed on THIS row (the other connecting row is unrelated).
        assertRowShows("mcp.servers", rowCd, localized(R.string.mcp_state_reading_tools))
    }

    @Test
    fun t17_mcpEditorNewServerSectionsPendingTransportAndDisabledSave() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        onUi {
            controller.mcpSeedProvider = { serverId ->
                syntheticNewSeed(serverId).copy(
                    transport = McpTransportUi.PendingEnvironment(
                        remediation = "Synthetic: the Linux stdio transport is temporarily unavailable.",
                    ),
                    networkActionsAvailable = false,
                    networkActionsUnavailableReason = "Synthetic: no network route right now.",
                )
            }
        }
        openMcpList()
        composeRule.onNodeWithContentDescription(localized(R.string.mcp_add)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("mcp.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.mcp_server_section)).assertExists()
        composeRule.onNodeWithText(localized(R.string.mcp_auth_section)).assertExists()
        composeRule.onNodeWithText("Synthetic: the Linux stdio transport is temporarily unavailable.").assertExists()
        scrollIn("mcp.editorPage", hasText("Synthetic: no network route right now."))
        composeRule.onNodeWithText("Synthetic: no network route right now.").assertIsDisplayed()
        // No projection-invented data: Save stays gated while the host cannot
        // serve it (honest disabled state, never a fake success path).
        composeRule.onNodeWithTag("mcp.saveAction").assertIsNotEnabled()
        capture("13-editor-new-unavailable")
    }

    @Test
    fun t18_mcpEditorExistingKeepSetClearIntentsAndMaskedSecret() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Ready Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("mcp.editorPage").assertIsDisplayed()
        // Stored credential: the field offers REPLACE, never shows a secret.
        composeRule.onNodeWithText(localized(R.string.mcp_credential_replace)).assertExists()
        // The projected tools are host-listed; a disabled tool stays disabled.
        scrollIn("mcp.editorPage", hasText("Synthetic Tool Two"))
        composeRule.onNodeWithText("Synthetic Tool Two").assertIsDisplayed()

        // KEEP: empty typed secret + same origin + stored secret.
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        var request = controller.mcpSaveRequests.last()
        assertEquals(CredentialDraftIntent.KEEP_EXISTING, request.credentialIntent)
        onUi { controller.emitSaveError("Synthetic host refused the KEEP save") }

        // SET: type a RAM-only secret; the dispatch carries it but no
        // projection, string or log may contain the value.
        scrollIn("mcp.editorPage", hasContentDescription(localized(R.string.mcp_credential_replace)))
        val secret = "synthetic-secret-do-not-log"
        field(localized(R.string.mcp_credential_replace)).performTextInput(secret)
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        request = controller.mcpSaveRequests.last()
        assertEquals(CredentialDraftIntent.SET, request.credentialIntent)
        assertEquals(secret, request.credentialDraft)
        assertTrue(secret !in request.toString())
        assertTrue(secret !in controller.state.value.toString())
        onUi { controller.emitSaveError("Synthetic host refused the SET save") }

        // Origin change drops the typed secret (MISSING, never re-bound).
        val endpointField = field(localized(R.string.mcp_endpoint_field))
        endpointField.performTextClearance()
        endpointField.performTextInput("https://synthetic-other.invalid/mcp")
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        request = controller.mcpSaveRequests.last()
        assertEquals(CredentialDraftIntent.MISSING, request.credentialIntent)
        assertEquals(null, request.credentialDraft)
        onUi { controller.emitSaveError("Synthetic host refused the MISSING save") }

        // CLEAR: authentication → None deletes the bound secret.
        scrollIn("mcp.editorPage", hasContentDescription(localized(R.string.mcp_auth_method), substring = true))
        composeRule
            .onNode(hasContentDescription(localized(R.string.mcp_auth_method), substring = true))
            .performClick()
        composeRule.waitForIdle()
        clickLast(hasText(localized(R.string.mcp_auth_none)))
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        request = controller.mcpSaveRequests.last()
        assertEquals(CredentialDraftIntent.CLEAR, request.credentialIntent)
        capture("14-editor-existing", imeTag = "mcp.editorPage")
        onUi { controller.emitSaveError("Synthetic CLEAR round complete") }
    }

    @Test
    fun t19_saveFailureShowsInlineErrorAndRetryDispatches() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Ready Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.mcpSaveRequests.size)
        onUi { controller.emitSaveError("Synthetic validation error: server unreachable") }
        scrollIn("mcp.editorPage", hasTestTag("mcp.saveError"))
        composeRule.onNodeWithTag("mcp.saveError").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic validation error: server unreachable").assertIsDisplayed()
        capture("15-save-error")
        // The failed attempt released the dispatch latch: Retry dispatches.
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(2, controller.mcpSaveRequests.size)
        onUi { controller.emitSaveError("Second attempt refused too") }
    }

    @Test
    fun t20_staleEpochSuccessCannotCloseNewerEditor() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Ready Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        val identityA = requireNotNull(controller.currentEditorIdentity())
        // In-flight save on A, then the user CANCELS (discards) and reopens.
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("integration.cancelAction").performClick()
        composeRule.waitForIdle()
        waitUntilGone("mcp.editorPage")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        val identityB = requireNotNull(controller.currentEditorIdentity())
        assertNotEquals(identityA, identityB)

        // LATE success addressed to the OLD identity must not close B:
        // the editor shows the honest waiting line instead.
        onUi {
            controller.emitSaveSucceededFor(
                identity = identityA,
                newServerId = "synthetic-ready",
                newRevision = 4,
            )
        }
        composeRule.onNodeWithTag("mcp.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.integration_waiting_host)).assertIsDisplayed()
        capture("16-stale-epoch-waiting")
        // The CURRENT identity finalizes normally.
        onUi {
            controller.emitSaveSucceededFor(identityB, newServerId = "synthetic-ready", newRevision = 5)
        }
        waitUntilGone("mcp.editorPage")
    }

    /* ============================ INSTALL REVIEW ============================ */

    @Test
    fun t21_installReviewShowsExpansionWithoutAnyGrant() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasTestTag("skills.catalogInstall"))
        composeRule.onNodeWithTag("skills.catalogInstall").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("synthetic-network"), controller.officialInstalls)
        // The host really staged: the card shows the honest busy affordance
        // (a spinner, never a fabricated percentage).
        composeRule.onNodeWithContentDescription(localized(R.string.skills_installing_cd)).assertIsDisplayed()
        onUi { controller.emitInstallReview(syntheticInstallReview(11)) }
        composeRule.onNodeWithTag("skills.installReview").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic Staged Skill").assertIsDisplayed()
        composeRule.onNodeWithText("synthetic.network").assertExists()
        composeRule.onNodeWithText("synthetic-package==1.2.3").assertExists()
        scrollIn("skills.installReview", hasText(localized(R.string.skills_review_no_grant_note)))
        // Honest no-grant note: review renders nothing that grants power.
        composeRule.onNodeWithText(localized(R.string.skills_review_no_grant_note)).assertIsDisplayed()
        capture("17-install-review")
    }

    @Test
    fun t22_installConfirmClosesAndHandledReviewNeverResurrects() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        hubScroll(hasTestTag("skills.catalogInstall"))
        composeRule.onNodeWithTag("skills.catalogInstall").performClick()
        composeRule.waitForIdle()
        onUi { controller.emitInstallReview(syntheticInstallReview(21)) }
        composeRule.onNodeWithTag("skills.installConfirm").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf(21L), controller.confirmedReviews)
        waitUntilGone("skills.installReview")
        // The host re-projects the SAME staged review: the module must not
        // resurrect a handled token.
        onUi { controller.emitInstallReview(syntheticInstallReview(21)) }
        composeRule.onAllNodesWithTag("skills.installReview").assertCountEquals(0)
        // A NEW monotonic token opens exactly one sheet; dismissing it
        // drops only the staged review.
        onUi { controller.emitInstallReview(syntheticInstallReview(22)) }
        composeRule.onNodeWithTag("skills.installReview").assertIsDisplayed()
        composeRule.onNodeWithTag("integration.cancelAction").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf(22L), controller.cancelledReviews)
        waitUntilGone("skills.installReview")
    }

    /* ================================ UPGRADE ================================ */

    private fun openUpgradeSheet() {
        hubScroll(hasTestTag("skills.catalogUpdate"))
        composeRule.onNodeWithTag("skills.catalogUpdate").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("skills.upgrade").assertIsDisplayed()
    }

    @Test
    fun t23_upgradeSheetAutoChecksOnceAndDetailsShowExpansion() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        onUi {
            controller.upgradeSeedProvider = { skillId ->
                if (skillId == "synthetic-pdf") syntheticUpgrade(skillId, candidate = null) else null
            }
        }
        openUpgradeSheet()
        // Auto-check dispatched exactly once for this open session.
        assertEquals(listOf("synthetic-pdf"), controller.upgradeChecks)
        onUi {
            controller.emitUpgradeProjection(
                syntheticUpgrade("synthetic-pdf", candidate = "2.2.0", canRollback = false, isLatest = false),
            )
        }
        composeRule.onNodeWithText("v2.2.0").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.skills_update_permissions_warning)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.skills_update_details)).performClick()
        composeRule.waitForIdle()
        scrollIn("skills.upgrade", hasText("synthetic before"))
        composeRule.onNodeWithText("synthetic before").assertIsDisplayed()
        composeRule.onNodeWithText("Synthetic release notes for the review.").assertExists()
        capture("18-upgrade-details")
        assertEquals(listOf("synthetic-pdf"), controller.upgradeChecks) // still once
    }

    @Test
    fun t24_upgradeFailureKeepsSheetSuccessClosesWithTokenFence() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        onUi {
            controller.upgradeSeedProvider = { skillId ->
                if (skillId == "synthetic-pdf") syntheticUpgrade(skillId, candidate = null) else null
            }
        }
        openUpgradeSheet()
        onUi { controller.emitUpgradeProjection(syntheticUpgrade("synthetic-pdf", candidate = "2.2.0", isLatest = false)) }
        composeRule.onNodeWithTag("skills.upgradeApply").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf(1L), controller.upgradeApplies)
        onUi { controller.emitUpgradeEffect("synthetic-pdf", 1L, UpgradeOutcomeUi.FAILED, "Synthetic apply failed") }
        composeRule.onNodeWithTag("skills.upgrade").assertIsDisplayed()
        scrollIn("skills.upgrade", hasTestTag("skills.upgradeError"))
        composeRule.onNodeWithText("Synthetic apply failed").assertIsDisplayed()
        // A token never dispatched must not close the sheet (fence).
        onUi { controller.emitUpgradeEffect("synthetic-pdf", 0L, UpgradeOutcomeUi.APPLIED) }
        composeRule.onNodeWithTag("skills.upgrade").assertIsDisplayed()
        // Second dispatch gets token 2; only THAT outcome is honoured.
        composeRule.onNodeWithTag("skills.upgradeApply").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf(1L, 2L), controller.upgradeApplies)
        onUi { controller.emitUpgradeEffect("synthetic-pdf", 2L, UpgradeOutcomeUi.APPLIED) }
        waitUntilGone("skills.upgrade")
    }

    @Test
    fun t25_rollbackNeedsExplicitConfirmation() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        onUi {
            controller.upgradeSeedProvider = { skillId ->
                if (skillId == "synthetic-pdf") syntheticUpgrade(skillId, candidate = null, canRollback = true) else null
            }
        }
        openUpgradeSheet()
        // The projection must exist for the effect outcome to attach to
        // (mirrors the real host: outcomes arrive via the projection).
        onUi {
            controller.emitUpgradeProjection(
                syntheticUpgrade("synthetic-pdf", candidate = null, canRollback = true, isLatest = true),
            )
        }
        scrollIn("skills.upgrade", hasText(localized(R.string.skills_update_details)))
        composeRule.onNodeWithText(localized(R.string.skills_update_details)).performClick()
        composeRule.waitForIdle()
        scrollIn("skills.upgrade", hasText(localized(R.string.skills_update_rollback)))
        composeRule.onNodeWithText(localized(R.string.skills_update_rollback)).performClick()
        composeRule.waitForIdle()
        // The confirm dialog is required before any rollback dispatch.
        assertEquals(0, controller.upgradeRollbacks.size)
        composeRule.onNodeWithText(localized(R.string.skills_update_rollback_confirm_title)).assertIsDisplayed()
        capture("19-rollback-confirm")
        clickLast(hasText(localized(R.string.skills_update_rollback)))
        composeRule.waitForIdle()
        assertEquals(listOf(1L), controller.upgradeRollbacks)
        onUi { controller.emitUpgradeEffect("synthetic-pdf", 1L, UpgradeOutcomeUi.ROLLED_BACK) }
        waitUntilGone("skills.upgrade")
    }

    @Test
    fun t26_upgradeWithoutSeedStaysHonestWaiting() {
        applyScenario(IntegrationsFixtureScenario.HUB_DISCOVER)
        onUi { controller.upgradeSeedProvider = { null } }
        hubScroll(hasTestTag("skills.catalogUpdate"))
        composeRule.onNodeWithTag("skills.catalogUpdate").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(localized(R.string.integration_waiting_host)).assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.skills_update_now)).assertDoesNotExist()
        capture("20-upgrade-waiting")
    }

    /* ====================== MCP SAME-FRAME SAVE RETRY ====================== */

    /**
     * Real regression for the reported defect: the retry's begin AND its
     * identical failure are published synchronously inside saveMcpServer, so
     * composition sees one coalesced projection whose text/outcome equal the
     * acknowledged old failure. The monotonic host failure sequence must still
     * release the duplicate-save latch; the draft/secret stay retained, the
     * error stays inline, and each real click dispatches exactly once.
     */
    @Test
    fun t27_sameFrameIdenticalSaveFailureRetryReleasesLatchWithoutDuplicates() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Ready Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("mcp.editorPage").assertIsDisplayed()
        val identity = requireNotNull(controller.currentEditorIdentity())
        val nameField = composeRule.onNodeWithContentDescription(localized(R.string.mcp_name_field))
        val endpointField = composeRule.onNodeWithContentDescription(localized(R.string.mcp_endpoint_field))

        // A RAM-only secret typed once must survive every failed retry.
        scrollIn("mcp.editorPage", hasContentDescription(localized(R.string.mcp_credential_replace)))
        val secret = "synthetic-sameframe-secret-do-not-log"
        field(localized(R.string.mcp_credential_replace)).performTextInput(secret)
        dismissImeAndWait("mcp.editorPage")

        val failure = "Synthetic validation error: server unreachable"

        // FIRST attempt: asynchronous failure with the canonical text.
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.mcpSaveRequests.size)
        assertEquals(CredentialDraftIntent.SET, controller.mcpSaveRequests[0].credentialIntent)
        onUi { controller.emitSaveError(failure) }
        scrollIn("mcp.editorPage", hasTestTag("mcp.saveError"))
        composeRule.onNodeWithTag("mcp.saveError").assertIsDisplayed()
        composeRule.onNodeWithText(failure).assertIsDisplayed()
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled()
        nameField.assertTextContains("Synthetic Ready Server")
        endpointField.assertTextContains("https://synthetic.invalid/mcp")

        // RETRY: begin + SAME failure synchronously inside saveMcpServer.
        // No waitForIdle/idling is inserted between them by the fixture.
        controller.armSameFrameSaveFailure(failure)
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(2, controller.mcpSaveRequests.size)
        // Old code kept saveDispatched=true forever and rendered a spinner
        // instead of the Save action. The new failure event must release it.
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("mcp.saveAction").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled()
        scrollIn("mcp.editorPage", hasTestTag("mcp.saveError"))
        composeRule.onNodeWithTag("mcp.saveError").assertIsDisplayed()
        composeRule.onNodeWithText(failure).assertIsDisplayed()
        composeRule.onNodeWithTag("mcp.editorPage").assertIsDisplayed()
        nameField.assertTextContains("Synthetic Ready Server")
        endpointField.assertTextContains("https://synthetic.invalid/mcp")
        assertEquals(secret, controller.mcpSaveRequests[1].credentialDraft)
        assertEquals(secret, controller.holder.mcpEditors.slot(identity.editorId)?.secureInput?.value)
        assertTrue(secret !in controller.state.value.toString())

        // THIRD retry dispatches exactly once per real click; the holder still
        // rejects a duplicate while that attempt is genuinely in flight.
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(3, controller.mcpSaveRequests.size)
        var duplicate: IntegrationsFlowResult? = null
        composeRule.runOnUiThread {
            duplicate = controller.holder.saveMcpEditor(identity, hostInFlight = false)
        }
        assertEquals(
            RejectedReason.SAVE_IN_FLIGHT,
            (duplicate as IntegrationsFlowResult.Rejected).reason,
        )
        assertEquals(3, controller.mcpSaveRequests.size)

        // Release the third attempt through its own failure event, keeping
        // the editor open with the inline error and no duplicate side effect.
        onUi { controller.emitSaveError(failure) }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("mcp.saveAction").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled()
        assertEquals(3, controller.mcpSaveRequests.size)
        assertEquals(secret, controller.holder.mcpEditors.slot(identity.editorId)?.secureInput?.value)
    }

    /** A failure addressed to another epoch is stale; it cannot release the
     * live attempt's latch or close the editor. */
    @Test
    fun t28_staleEpochSaveFailureCannotReleaseCurrentAttempt() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Ready Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        val identity = requireNotNull(controller.currentEditorIdentity())

        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(1, controller.mcpSaveRequests.size)

        onUi {
            controller.emitSaveFailureFor(
                identity = identity.copy(epoch = identity.epoch + 1),
                message = "Stale same-editor failure",
                failureSequence = 9,
            )
        }
        composeRule.onNodeWithTag("mcp.editorPage").assertIsDisplayed()
        composeRule.onNodeWithText(localized(R.string.integration_waiting_host)).assertIsDisplayed()

        var duplicate: IntegrationsFlowResult? = null
        composeRule.runOnUiThread {
            duplicate = controller.holder.saveMcpEditor(identity, hostInFlight = false)
        }
        assertEquals(
            RejectedReason.SAVE_IN_FLIGHT,
            (duplicate as IntegrationsFlowResult.Rejected).reason,
        )
        assertEquals(1, controller.mcpSaveRequests.size)

        // A real current-epoch failure event still releases the attempt.
        onUi { controller.emitSaveError("Current epoch failure") }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("mcp.saveAction").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled()
    }

    /** Replaying an already-consumed failure while a NEW attempt is in flight
     * is a poll/no-op; only a strictly newer event may release that attempt. */
    @Test
    fun t29_republishedOldFailureCannotUnlockNewInFlightAttempt() {
        applyScenario(IntegrationsFixtureScenario.MCP_LIST)
        openMcpList()
        val rowCd = localized(R.string.mcp_row_cd, "Synthetic Ready Server")
        scrollIn("mcp.servers", hasContentDescription(rowCd))
        rowOf(rowCd).performClick()
        composeRule.waitForIdle()
        val identity = requireNotNull(controller.currentEditorIdentity())
        val failure = "Synthetic repeated failure"

        // First attempt: failure event sequence 1, latch released.
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        onUi { controller.emitSaveError(failure) }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("mcp.saveAction").fetchSemanticsNodes().isNotEmpty()
        }

        // Second attempt is genuinely in flight.
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(2, controller.mcpSaveRequests.size)
        composeRule.onNodeWithTag("mcp.saveAction").assertDoesNotExist()

        // A poll/republish of the OLD consumed failure (same sequence) must
        // not be mistaken for a new attempt outcome.
        onUi {
            controller.emitSaveFailureFor(
                identity = identity,
                message = failure,
                failureSequence = 1,
            )
        }
        composeRule.onNodeWithTag("mcp.saveAction").assertDoesNotExist()
        var duplicate: IntegrationsFlowResult? = null
        composeRule.runOnUiThread {
            duplicate = controller.holder.saveMcpEditor(identity, hostInFlight = false)
        }
        assertEquals(
            RejectedReason.SAVE_IN_FLIGHT,
            (duplicate as IntegrationsFlowResult.Rejected).reason,
        )
        assertEquals(2, controller.mcpSaveRequests.size)

        // A genuinely NEW event with the SAME text releases the second
        // attempt, and the next click dispatches exactly once.
        onUi { controller.emitSaveError(failure) }
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithTag("mcp.saveAction").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("mcp.saveAction").assertIsEnabled()
        composeRule.onNodeWithTag("mcp.saveAction").performClick()
        composeRule.waitForIdle()
        assertEquals(3, controller.mcpSaveRequests.size)
        onUi { controller.emitSaveError(failure) }
    }
}
