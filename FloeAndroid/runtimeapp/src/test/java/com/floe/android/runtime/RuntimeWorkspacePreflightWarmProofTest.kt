// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.linuxruntime.supervision.CensusSnapshot
import com.floe.android.workspacebridge.WorkspaceBudgetsView
import com.floe.android.workspacebridge.WorkspaceExportOutcome
import com.floe.android.workspacebridge.WorkspaceImportReceipt
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/**
 * G03-R3 warm-preparation regression against the REAL preflight executor.
 *
 * The previous executor treated a preparation receipt (even one written by a
 * prior successful preflight in this process generation) as a valid mapping
 * proof and returned `ready/cached` WITHOUT a session/import/export. The host
 * then could not read a Core-owned EXPORT_FINISH terminal index and honestly
 * refused `mapping_unsynced` forever.
 *
 * These tests seed a genuinely REUSABLE receipt through the same production
 * receipt store and run [RuntimeWorkspacePreflight.execute] with the real
 * authority/census/session seams. They assert a fresh import AND the real
 * faithful export still run, no `cached` reply exists, and only a Synced
 * export can become ready. A test double stands in ONLY for the grant-bound
 * RuntimeWorkspaceSession (Android Binder) and the native authority/census;
 * every decision under test is production code.
 */
class RuntimeWorkspacePreflightWarmProofTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val projectID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private val runID = "A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D"
    private val conversationID = "0F8FAD5B-D9CB-469F-A165-70867728950E"
    private val environmentID = "env-1"
    private val baseRevision = "debian-bookworm-test"
    private val bootToken = "a".repeat(32)
    private val planDigest = "b".repeat(64)

    private val budgets = WorkspaceBudgetsView(
        totalBytes = 1_000_000, entryCount = 100, frameBytes = 65_536,
        maximumEntryBytes = 100_000, freeDiskReserveBytes = 0,
        maximumRelativePathBytes = 4_096, maximumLinkTargetBytes = 4_096,
    )

    private fun importReceipt(entries: Int) = WorkspaceImportReceipt(
        sessionKey = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        createdCount = entries,
        replacedSyncedCount = 0,
        preservedUnsyncedCount = 0,
        unchangedCount = 0,
        conflictPaths = emptyList(),
        conflictsTruncated = false,
        appliedBytes = 0,
        skippedCount = 0,
        budgets = budgets,
    )

    private fun cleanCensus() = CensusSnapshot(
        servicePid = 4_242,
        ownLive = emptyList(),
        ownZombies = emptyList(),
        ambiguous = emptyList(),
        serviceThreads = emptyList(),
        foreignCount = 0,
        unreadableForeignCount = 0,
        scannedCount = 17,
        inventoryFailure = null,
    )

    private class Observed {
        val imports = mutableListOf<String>()
        val exports = mutableListOf<String>()
        var abandoned = 0
        var closed = 0
    }

    private fun harness(
        workspace: File,
        preparation: WorkspacePreparationReceipts,
        observed: Observed,
        exportOutcome: WorkspaceExportOutcome,
        mirroredEntries: Int = 2,
    ): PreflightHarness {
        val lease = LinuxAuthorityClient.Lease("lease-1", JSONObject()
            .put("workspaceRoot", workspace.canonicalPath)
            .put("environmentID", environmentID)
            .put("baseRevision", baseRevision)
            .put("runID", runID))
        return PreflightHarness(
            acquire = { lease },
            abandon = { observed.abandoned += 1 },
            snapshot = { cleanCensus() },
            ensureConfigured = { },
            ownedPath = { File(it) },
            heldLease = AtomicReference(),
            installID = AtomicReference(),
            openWorkspace = { _, _, _ ->
                PreflightWorkspace(
                    importBeforeLaunch = {
                        observed.imports += "import"
                        importReceipt(mirroredEntries)
                    },
                    exportAfterQuiescence = {
                        observed.exports += "export"
                        exportOutcome
                    },
                    close = { observed.closed += 1 },
                )
            },
            preparation = preparation,
            processIdentity = { 7_777 to bootToken },
        )
    }

    private fun payload() = JSONObject()
        .put("projectID", projectID)
        .put("runID", runID)
        .put("conversationID", conversationID)
        .put("environmentID", environmentID)

    private fun seedWarmReceipt(workspace: File): WorkspacePreparationReceipts {
        val receipts = WorkspacePreparationReceipts(
            temporary.newFolder("prepare"),
            runtimePid = { 7_777 },
            runtimeBootToken = { bootToken },
        )
        assertTrue(receipts.record(projectID, environmentID, baseRevision, workspace, 2, 0))
        assertTrue(receipts.reusable(projectID, environmentID, baseRevision, workspace))
        return receipts
    }

    @Test fun warmReceiptStillPerformsFreshImportAndCoreOwnedExport() {
        val workspace = temporary.newFolder("workspace")
        val preparation = seedWarmReceipt(workspace)
        val observed = Observed()
        val synced = WorkspaceExportOutcome.Synced(
            sessionKey = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            created = 2, replaced = 0, directories = 0, deleted = 0, links = 0,
            stagedRefusals = 0, planDigest = planDigest,
        )
        val harness = harness(workspace, preparation, observed, synced)

        val reply = RuntimeWorkspacePreflight.execute(harness, payload()) { false }

        assertEquals("ready", reply.getString("status"))
        // The old cached-ready shortcut is gone: no cached flag and the REAL
        // session round trip ran exactly once, producing a real mirror count
        // and process identity bound to the live peer.
        assertFalse(reply.has("cached"))
        assertEquals(2, reply.getInt("mirroredEntries"))
        assertEquals(planDigest, reply.getString("enginePlanDigest"))
        assertEquals(64, reply.getString("leaseProofDigest").length)
        assertEquals(7_777, reply.getInt("runtimePid"))
        assertEquals(bootToken, reply.getString("runtimeBootToken"))
        assertEquals(listOf("import"), observed.imports)
        assertEquals(listOf("export"), observed.exports)
        assertEquals(1, observed.abandoned)
        assertEquals(1, observed.closed)
        assertNull(harness.heldLease.get())
    }

    @Test fun warmReceiptCannotReturnReadyWithoutAFreshSyncedExport() {
        // Same genuinely reusable receipt, but the real export did not settle
        // as Synced: no mapping proof exists, so the executor must abort and
        // no ready reply (and no new receipt) may be published.
        val workspace = temporary.newFolder("workspace")
        val preparation = seedWarmReceipt(workspace)
        val observed = Observed()
        val conflict = WorkspaceExportOutcome.Conflict(
            sessionKey = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            status = "conflict",
            created = 1, replaced = 0, directories = 0, deleted = 0, links = 0,
            conflicts = emptyList(), conflictsTruncated = false, failed = 0,
            stagedRefusals = 0, indexDigest = "c".repeat(64),
        )
        val harness = harness(workspace, preparation, observed, conflict)

        val reply = RuntimeWorkspacePreflight.execute(harness, payload()) { false }

        assertEquals("aborted", reply.getString("status"))
        assertEquals("mapping_conflict", reply.getString("reason"))
        assertEquals(listOf("import"), observed.imports)
        assertEquals(listOf("export"), observed.exports)
        assertEquals(1, observed.abandoned)
        assertEquals(1, observed.closed)
        assertNull(harness.heldLease.get())
        // The failed attempt invalidated the earlier receipt, exactly like the
        // production failure path: a later run must re-prove instead of
        // trusting a success this attempt could not reproduce.
        assertFalse(preparation.reusable(projectID, environmentID, baseRevision, workspace))
    }
}
