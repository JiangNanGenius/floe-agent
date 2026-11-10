// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.workspacebridge.StagedEntry
import com.floe.android.workspacebridge.WorkspaceBridgeException
import com.floe.android.workspacebridge.WorkspaceBudgetsView
import com.floe.android.workspacebridge.WorkspaceImportReceipt
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * N07 R1 repair — the REAL [RuntimeWorkspaceInputSync] executor over its
 * production decision path. A test double stands in ONLY for the
 * grant-bound transfer session (Android Binder) and the live-workspace
 * lookup; every refusal, identity re-proof, cancellation and close decision
 * under test is production code (the RuntimeWorkspacePreflightWarmProofTest
 * precedent). AUTHORED NOT RUN by the authoring lane.
 */
class RuntimeWorkspaceInputSyncTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val projectID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private val runID = "A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D"

    private val budgets = WorkspaceBudgetsView(
        totalBytes = 1_000_000, entryCount = 100, frameBytes = 65_536,
        maximumEntryBytes = 100_000, freeDiskReserveBytes = 0,
        maximumRelativePathBytes = 4_096, maximumLinkTargetBytes = 4_096,
    )

    private fun receipt(
        created: Int = 2,
        retained: Int = 3,
        skipped: Int = 0,
        conflicts: List<String> = emptyList(),
    ) = WorkspaceImportReceipt(
        sessionKey = "3f2504e04f8911d39a0c0305e82c3301",
        createdCount = created,
        replacedSyncedCount = 0,
        preservedUnsyncedCount = 0,
        unchangedCount = 0,
        conflictPaths = conflicts,
        conflictsTruncated = false,
        appliedBytes = 0,
        skippedCount = skipped,
        budgets = budgets,
        retainedExistingCount = retained,
    )

    private class Observed {
        var opened = 0
        var closed = 0
        var imports = 0
        var cancelSignals = mutableListOf<Boolean>()
        var adopted = mutableListOf<Triple<String, Long, String>>()
        var closeFailure: Boolean = false
    }

    private fun workspace(): File {
        val root = temporary.newFolder("Workspaces")
        return File(root, projectID).apply { check(mkdirs()) }
    }

    private fun harness(
        workspace: File,
        observed: Observed,
        receipt: WorkspaceImportReceipt,
        failure: WorkspaceBridgeException? = null,
        live: Boolean = true,
        exclusive: Boolean = false,
        foreignDirectory: File? = null,
    ) = InputSyncHarness(
        workspacesRoot = workspace.parentFile!!,
        liveWorkspace = { pid ->
            if (!live || pid != projectID) null
            else LiveInputSyncWorkspace(
                foreignDirectory ?: workspace,
                InputSyncBaseline { sourceKey, index, entry ->
                    observed.adopted += Triple(sourceKey, index, entry.path)
                })
        },
        openWorkspace = { _, _, _ ->
            observed.opened += 1
            InputSyncWorkspace(
                importNewInputs = { cancel, baseline ->
                    observed.imports += 1
                    observed.cancelSignals += cancel.shouldCancel()
                    // The ORIGINAL swap invokes this per created entry; the
                    // executor must pass the live baseline through.
                    baseline.adopt("source-session-key", 7,
                        StagedEntry(".floe/skills/x@y", "file", 0, null, "d".repeat(64), 1))
                    failure?.let { throw it }
                    receipt
                },
                close = {
                    observed.closed += 1
                    if (observed.closeFailure) throw IllegalStateException("close failed")
                })
        },
        exclusiveWork = { exclusive },
    )

    private fun payload() = JSONObject()
        .put("projectID", projectID)
        .put("runID", runID)

    @Test
    fun `applies missing-only import and reports engine counts`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(created = 2, retained = 5)),
            payload(), cancelled = { false })
        assertEquals("ok", outcome.getString("state"))
        assertEquals(2, outcome.getInt("created"))
        assertEquals(5, outcome.getInt("retained"))
        assertEquals(1, observed.opened)
        assertEquals(1, observed.imports)
        assertEquals(1, observed.closed)
        // The live owner's baseline adoption rode the real callback.
        assertEquals(listOf(Triple("source-session-key", 7L, ".floe/skills/x@y")), observed.adopted)
    }

    @Test
    fun `no live workspace refuses honestly and never opens a session`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(), live = false),
            payload(), cancelled = { false })
        assertEquals("refused", outcome.getString("state"))
        assertEquals("workspaceNotLive", outcome.getString("code"))
        assertEquals(0, observed.opened)
        assertEquals(0, observed.imports)
        assertEquals(0, observed.closed)
    }

    @Test
    fun `a live workspace of a different project is never addressed`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt()),
            payload().put("projectID", "9F2504E0-4F89-11D3-9A0C-0305E82C3301"),
            cancelled = { false })
        assertEquals("refused", outcome.getString("state"))
        assertEquals("workspaceNotLive", outcome.getString("code"))
        assertEquals(0, observed.opened)
    }

    @Test
    fun `a non-canonical workspace directory refuses the identity re-proof`() {
        val workspace = workspace()
        val foreign = File(workspace.parentFile, "not-the-project").apply { mkdirs() }
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(), foreignDirectory = foreign),
            payload(), cancelled = { false })
        assertEquals("refused", outcome.getString("state"))
        assertEquals("workspaceIdentityChanged", outcome.getString("code"))
        assertEquals(0, observed.opened)
    }

    @Test
    fun `skipped unsupported entries refuse the whole answer and close`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(skipped = 1)),
            payload(), cancelled = { false })
        assertEquals("refused", outcome.getString("state"))
        assertEquals("newWorkspaceInputsUnavailable", outcome.getString("code"))
        assertEquals(1, observed.closed)
    }

    @Test
    fun `any conflict refuses the whole answer and closes`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(conflicts = listOf(".floe/skills/x@y"))),
            payload(), cancelled = { false })
        assertEquals("refused", outcome.getString("state"))
        assertEquals("newWorkspaceInputsUnavailable", outcome.getString("code"))
        assertEquals(1, observed.closed)
    }

    @Test
    fun `bounded bridge codes map verbatim and unknown codes collapse`() {
        val workspace = workspace()
        val bounded = RuntimeWorkspaceInputSync.execute(
            harness(workspace, Observed(), receipt(), failure = WorkspaceBridgeException("budgetExceeded")),
            payload(), cancelled = { false })
        assertEquals("refused", bounded.getString("state"))
        assertEquals("budgetExceeded", bounded.getString("code"))
        val unknown = RuntimeWorkspaceInputSync.execute(
            harness(workspace, Observed(), receipt(), failure = WorkspaceBridgeException("stageOpenFailed:13")),
            payload(), cancelled = { false })
        assertEquals("refused", unknown.getString("state"))
        assertEquals("workspaceTransferFailed", unknown.getString("code"))
    }

    @Test
    fun `exclusive install or preflight lane refuses before any session`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(), exclusive = true),
            payload(), cancelled = { false })
        assertEquals("refused", outcome.getString("state"))
        assertEquals("runtimeBusy", outcome.getString("code"))
        assertEquals(0, observed.opened)
    }

    @Test
    fun `cancellation reaches the import signal and the close still runs`() {
        val workspace = workspace()
        val observed = Observed()
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt()),
            payload(), cancelled = { true })
        assertEquals("ok", outcome.getString("state"))
        assertEquals(listOf(true), observed.cancelSignals)
        assertEquals(1, observed.closed)
    }

    @Test
    fun `a close failure never masks a real receipt`() {
        val workspace = workspace()
        val observed = Observed()
        observed.closeFailure = true
        val outcome = RuntimeWorkspaceInputSync.execute(
            harness(workspace, observed, receipt(created = 1, retained = 0)),
            payload(), cancelled = { false })
        assertEquals("ok", outcome.getString("state"))
        assertEquals(1, outcome.getInt("created"))
    }

    @Test
    fun `malformed payloads fail before any live lookup`() {
        val workspace = workspace()
        val observed = Observed()
        // Extra key: a command-shaped field must be structurally impossible.
        try {
            RuntimeWorkspaceInputSync.execute(
                harness(workspace, observed, receipt()),
                payload().put("command", "id"), cancelled = { false })
            fail("extra key must refuse")
        } catch (_: IllegalArgumentException) { }
        // Lowercase (non-canonical Core) identity refuses the grammar.
        try {
            RuntimeWorkspaceInputSync.execute(
                harness(workspace, observed, receipt()),
                payload().put("runID", runID.lowercase()), cancelled = { false })
            fail("lowercase run id must refuse")
        } catch (_: IllegalArgumentException) { }
        assertEquals(0, observed.opened)
    }
}
