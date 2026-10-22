// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * G03-R3 (job-7e9db10b801940c2): the REAL production wipe engine exercised
 * against a temporary Workspaces root — no duplicate fake implementation:
 * scope addressing, ownership gating, busy/live deferral, atomic retirement,
 * bounded continuation, no-follow safety, drain-before-ack and honest
 * counters/proofs are the shipped code paths.
 */
class WorkspaceCopyWiperTest {
    private val conversation = "0F66A2F0-6CFA-4B6E-9E5F-3E9D2B5C7A11"
    private val project = "5AA3F1C2-1D2E-4A6B-8C9D-0E1F2A3B4C5D"
    private val otherProject = "9BB00000-0000-4000-8000-000000000000"
    private val journalKey = "0123456789abcdef0123456789abcdef"

    private fun scope(keys: List<String> = listOf(journalKey), truncated: Boolean = false,
                      provenTotal: Int = maxOf(keys.size, 1), targetEpoch: Long = 7) = RuntimeCleanupScope(
        requestID = "a".repeat(32), conversationID = conversation, projectID = project,
        targetEpoch = targetEpoch, workspaceRelativePath = "PrivateTasks/$conversation",
        provenTotal = provenTotal, evidenceSessionKeys = keys, evidenceTruncated = truncated,
    )

    private fun newRoot(): File {
        val root = Files.createTempDirectory("floe-wipe-test").toFile().canonicalFile
        File(root, "Workspaces").mkdirs()
        return File(root, "Workspaces")
    }

    private fun seedTarget(workspaces: File, files: Int = 3) {
        val target = File(workspaces, project)
        File(target, "PrivateTasks/$conversation").mkdirs()
        repeat(files) { index ->
            File(target, "content-$index.txt").writeText("x".repeat(100 + index))
        }
        File(target, "PrivateTasks/$conversation/notes.md").writeText("hello")
        File(workspaces, ".floe-ws-${project.lowercase()}").mkdirs()
        File(workspaces, ".floe-ws-${project.lowercase()}/manifest.jsonl")
            .writeText("{\"record\":\"sync\"}\n")
        val journal = File(workspaces, ".floe-wt-$journalKey")
        journal.mkdirs()
        File(journal, "marker.json").writeText(
            org.json.JSONObject().put("record", "session").put("sessionKey", journalKey)
                .put("runID", conversation).toString())
    }

    private fun seedUnrelated(workspaces: File) {
        val other = File(workspaces, otherProject)
        assertTrue(other.mkdirs())
        File(other, "keep.txt").writeText("unrelated project material")
        File(workspaces, "Environments-NOT-in-scope.txt").writeText("shared roots live OUTSIDE Workspaces")
    }

    private fun wiper(workspaces: File, ownership: Boolean = true, busy: Boolean = false,
                      liveKey: String? = null, drain: Boolean = true,
                      limits: WorkspaceCopyWiper.Limits = WorkspaceCopyWiper.Limits()) =
        WorkspaceCopyWiper(
            workspacesRoot = workspaces,
            ownership = { ownership },
            activeWork = { busy },
            liveSession = { key -> key == liveKey },
            directoryDrain = { drain },
            executorUid = 10123,
            limits = limits,
        )

    @Test fun clearsFullTargetProjectScopeAndPreservesUnrelated() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        seedUnrelated(workspaces)
        val outcome = wiper(workspaces).run(scope())
        assertTrue("expected Cleared, got $outcome", outcome is WorkspaceCopyWiper.Outcome.Cleared)
        outcome as WorkspaceCopyWiper.Outcome.Cleared
        assertTrue(outcome.pathsRemoved > 0)
        // logical bytes of the ACTUAL removed regular files (never a df claim)
        assertTrue(outcome.bytesFreed >= 308L && outcome.bytesFreed < 1L shl 20)
        assertTrue(outcome.proofDigest.matches(Regex("^[0-9a-f]{64}$")))
        assertFalse(File(workspaces, project).exists())
        assertFalse(File(workspaces, ".floe-ws-${project.lowercase()}").exists())
        assertFalse(File(workspaces, ".floe-wt-$journalKey").exists())
        assertTrue(File(workspaces, otherProject).exists())
        assertTrue(File(workspaces, "Environments-NOT-in-scope.txt").exists())
        assertTrue(outcome.bytesFreed > 0 && outcome.bytesFreed < 1L shl 20)
    }

    @Test fun clearedIsIdempotentSecondPassReportsZeroHonestEffect() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val first = wiper(workspaces).run(scope()) as WorkspaceCopyWiper.Outcome.Cleared
        val second = wiper(workspaces).run(scope()) as WorkspaceCopyWiper.Outcome.Cleared
        assertEquals(0L, second.pathsRemoved)
        assertEquals(0L, second.bytesFreed)
        assertNotEquals(first.proofDigest, second.proofDigest) // per-execution proof, never a cached echo
    }

    @Test fun busyRuntimeDefersTargetWhileUnrelatedWorkRuns() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val outcome = wiper(workspaces, busy = true).run(scope())
        assertTrue(outcome is WorkspaceCopyWiper.Outcome.Retained)
        assertEquals("ownedWorkActive", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists()) // target B deferred, workload A never cancelled
    }

    @Test fun unprovenOwnershipNeverDeletes() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val outcome = wiper(workspaces, ownership = false).run(scope())
        assertEquals("ownershipUnproven", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists())
        assertTrue(File(workspaces, ".floe-ws-${project.lowercase()}").exists())
    }

    @Test fun liveGrantForTargetKeyDefersWholeScope() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val outcome = wiper(workspaces, liveKey = journalKey).run(scope())
        assertEquals("grantLive", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists())
    }

    @Test fun symlinkImpostorRefusesAndIsRetained() {
        val workspaces = newRoot()
        File(workspaces, project).mkdirs() // seed a real dir first
        File(workspaces, project).deleteRecursively()
        val outside = File(workspaces.parentFile, "outside-secret")
        outside.mkdirs()
        File(outside, "victim.txt").writeText("must never be followed/deleted")
        Files.createSymbolicLink(File(workspaces, project).toPath(), outside.toPath())
        val outcome = wiper(workspaces).run(scope(keys = emptyList()))
        assertEquals("unsafeproject:symlink", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertEquals("must never be followed/deleted", File(outside, "victim.txt").readText())
    }

    @Test fun oversizedValidJournalMarkerIsRetainedBeforeRetirement() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val marker = File(workspaces, ".floe-wt-$journalKey/marker.json")
        val json = org.json.JSONObject(marker.readText()).put("padding", "x".repeat(4096))
        marker.writeText(json.toString())
        val outcome = wiper(workspaces).run(scope())
        assertEquals("journalMarkerInvalid", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists())
    }

    @Test fun symlinkJournalMarkerIsRetainedWithoutFollowingTarget() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val marker = File(workspaces, ".floe-wt-$journalKey/marker.json")
        val outside = File(workspaces.parentFile, "outside-marker.json")
        val bytes = marker.readBytes()
        outside.writeBytes(bytes)
        assertTrue(marker.delete())
        Files.createSymbolicLink(marker.toPath(), outside.toPath())
        val outcome = wiper(workspaces).run(scope())
        assertEquals("journalMarkerInvalid", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertArrayEquals(bytes, outside.readBytes())
        assertTrue(File(workspaces, project).exists())
    }

    @Test fun unmarkedJournalIsForeignAndRefused() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        File(workspaces, ".floe-wt-$journalKey/marker.json").delete()
        val outcome = wiper(workspaces).run(scope())
        assertEquals("journalMarkerInvalid", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists())
    }

    @Test fun truncatedEvidenceWithRecoverableUnattributedJournalRefuses() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        // a second journal that may belong to the target (truncated evidence)
        // and still carries recoverable material: attribution incomplete
        val foreign = File(workspaces, ".floe-wt-${"f".repeat(32)}")
        File(foreign, "preserve").mkdirs()
        File(foreign, "preserve/unsynced.bin").writeText("recoverable")
        val outcome = wiper(workspaces).run(scope(truncated = true, provenTotal = 40))
        assertEquals("attributionIncomplete", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists())
    }

    @Test fun boundedPassRetainsOnBudgetThenContinuesFromDurableMarker() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val tight = wiper(workspaces, limits = WorkspaceCopyWiper.Limits(maximumUnlinkOps = 3)).run(scope())
        assertTrue(tight is WorkspaceCopyWiper.Outcome.Retained)
        tight as WorkspaceCopyWiper.Outcome.Retained
        assertEquals("wipeBudget", tight.reason)
        assertTrue(tight.progressPaths > 0) // real partial effect stays removed (never rolled back)
        // the active namespace lost the target immediately (atomic retire):
        assertFalse(File(workspaces, project).exists())
        val retire = File(workspaces, ".floe-wipe-${project.lowercase()}-7")
        assertTrue(retire.exists()) // durable owner metadata kept until full commit
        // continuation pass finishes the scope with honest remaining counts
        val done = wiper(workspaces).run(scope())
        assertTrue(done is WorkspaceCopyWiper.Outcome.Cleared)
        assertFalse(retire.exists())
    }

    @Test fun drainFailureBeforeAckRefusesWithoutCleared() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val outcome = wiper(workspaces, drain = false).run(scope())
        assertEquals("drainUnproven", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        // retry with working drain: material already retired+deleted -> cleared
        assertTrue(wiper(workspaces).run(scope()) is WorkspaceCopyWiper.Outcome.Cleared)
    }

    @Test fun otherScopeRetireTreeIsNeverTouched() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        val otherRetire = File(workspaces, ".floe-wipe-${otherProject.lowercase()}-9")
        assertTrue(otherRetire.mkdirs())
        File(otherRetire, "marker.json").writeText("{}")
        File(otherRetire, "project-copy").mkdirs()
        val outcome = wiper(workspaces).run(scope())
        assertTrue(outcome is WorkspaceCopyWiper.Outcome.Cleared)
        assertTrue(otherRetire.exists()) // foreign hidden material retained
    }

    @Test fun mismatchedRetireMarkerRefusesWrongScope() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        // sidecar durable marker bound to a DIFFERENT conversation scope
        File(workspaces, ".floe-wipe-${project.lowercase()}-7.json").writeText(org.json.JSONObject()
            .put("record", "workspace-wipe")
            .put("conversationID", "11111111-1111-4111-8111-111111111111")
            .put("projectID", project).put("targetEpoch", 7).toString())
        val outcome = wiper(workspaces).run(scope())
        assertEquals("retireScopeMismatch", (outcome as WorkspaceCopyWiper.Outcome.Retained).reason)
        assertTrue(File(workspaces, project).exists())
    }

    @Test fun runtimeDataResetMakesTheProvenAbsentScopeSettleHonestly() {
        // The Workspaces root no longer exists (runtime app data wiped after
        // the scope was proven): zero-effect cleared, never a stuck retention
        // (and never a claimed "removed" count).
        val missing = File(newRoot().parentFile, "Workspaces-absent")
        val outcome = wiper(missing).run(scope())
        assertTrue(outcome is WorkspaceCopyWiper.Outcome.Cleared)
        outcome as WorkspaceCopyWiper.Outcome.Cleared
        assertEquals(0L, outcome.pathsRemoved)
        assertEquals(0L, outcome.bytesFreed)
    }

    @Test fun staleTargetEpochScopeStillClearsAgainstCurrentBinding() {        // targetEpoch (stable ledger identity) may be OLDER than the current
        // bound epoch on retries: the engine keys only on the scope tuple.
        val workspaces = newRoot()
        seedTarget(workspaces)
        val outcome = wiper(workspaces).run(scope(targetEpoch = 3))
        assertTrue(outcome is WorkspaceCopyWiper.Outcome.Cleared)
        assertFalse(File(workspaces, project).exists())
    }

    @Test fun pathTraversalAndPrefixGuessesCannotAddressAnything() {
        val workspaces = newRoot()
        seedTarget(workspaces)
        // a scope whose projectID is not the canonical UUID shape fails closed
        val hostile = scope().copy(projectID = "../../Outside")
        assertTrue(wiper(workspaces).run(hostile) is WorkspaceCopyWiper.Outcome.Retained)
        assertTrue(File(workspaces, project).exists())
    }
}
