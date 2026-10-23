// SPDX-License-Identifier: MPL-2.0
// Focused metadata/contract regressions for the scoped recovery receipts
// (job-5b987a08b1df40b2). Author-written against the 951f2f68/bacbaf91
// baseline; intended for the workspacebridge JVM suite (org.json test
// dependency already present). NOT executed by this lane.
package com.floe.android.workspacebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

private fun sha256(text: String): String =
    MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

class WorkspaceRecoveryFactsTest {
    private fun tempRoot(): File = Files.createTempDirectory("floe-recovery-facts").toFile().apply { deleteOnExit() }

    private class Fixture(val destination: File, val journalParent: File, val projectID: String, val ops: JvmSwapOps)

    private fun fixture(): Fixture {
        val parent = tempRoot()
        val projectID = "A1B2C3D4-0000-4000-9000-000000000002"
        val destination = File(parent, "Workspaces/" + projectID.lowercase())
        assertTrue(destination.mkdirs())
        return Fixture(destination, parent, projectID, JvmSwapOps())
    }

    /** Fresh swap engine over the SAME stable destination with its own journal. */
    private fun swapFor(f: Fixture, tag: String): Pair<WorkspaceImportSwap, File> {
        val journal = File(f.journalParent, ".floe-wt-$tag")
        assertTrue(journal.mkdirs())
        val stage = File(journal, "stage")
        val preserve = File(journal, "preserve")
        assertTrue(stage.mkdirs() && preserve.mkdirs())
        val swap = WorkspaceImportSwap(f.destination, stage, preserve, File(journal, "swap.jsonl"),
            WorkspaceSyncManifest(f.destination.parentFile, f.projectID, f.ops), f.ops)
        return swap to stage
    }

    private fun File.write(text: String) { Files.write(toPath(), text.toByteArray(Charsets.UTF_8)) }
    private fun File.text() = String(Files.readAllBytes(toPath()), Charsets.UTF_8)

    private fun stagedFile(stage: File, path: String, content: String): StagedEntry {
        val target = File(stage, path)
        target.parentFile?.mkdirs()
        target.write(content)
        val digest = sha256(content)
        return StagedEntry(path, "file", 420, null, digest, content.toByteArray(Charsets.UTF_8).size.toLong())
    }

    // ---- 1. ACTUAL preserved custody facts come from the real move+install ----

    @Test fun divergedDestinationSwapRecordsMeasuredCustodyFacts() {
        val f = fixture()
        // First import establishes the synced baseline "one".
        val (swap1, stage1) = swapFor(f, "0".repeat(32))
        val first = listOf(stagedFile(stage1, "r3cas/marker.txt", "one"))
        swap1.apply(first) { false }
        swap1.acknowledge(first)
        assertEquals("one", File(f.destination, "r3cas/marker.txt").text())
        // Guest diverges WITHOUT a sync proof (V4-style unsynced bytes).
        File(f.destination, "r3cas/marker.txt").write("R3_FCR_V4_DIVERGED")
        // Next import: digest CAS must preserve V4 and install the baseline "two".
        val (swap2, stage2) = swapFor(f, "1".repeat(32))
        val second = listOf(stagedFile(stage2, "r3cas/marker.txt", "two"))
        val outcome = swap2.apply(second) { false }
        assertEquals(1, outcome.preservedUnsynced)
        assertEquals(1, outcome.preserved.size)
        val fact = outcome.preserved.single()
        assertEquals("r3cas/marker.txt", fact.path)
        assertEquals("swappedPreserved", fact.action)
        assertEquals(sha256("R3_FCR_V4_DIVERGED"), fact.preservedSha256)
        assertEquals("R3_FCR_V4_DIVERGED".toByteArray().size.toLong(), fact.preservedBytes)
        assertEquals(sha256("two"), fact.installedSha256)
        assertEquals(3L, fact.installedBytes)
        // The destination now holds the baseline revision; the diverged bytes
        // are REAL files in the preserve tree (custody, not a counter).
        assertEquals("two", File(f.destination, "r3cas/marker.txt").text())
        val preserved = File(File(f.journalParent, ".floe-wt-" + "1".repeat(32)), "preserve/r3cas/marker.txt")
        assertEquals("R3_FCR_V4_DIVERGED", preserved.text())
        // The journal line carries the same measured facts (audit trail).
        val line = File(File(f.journalParent, ".floe-wt-" + "1".repeat(32)), "swap.jsonl")
            .readLines().last { JSONObject(it).optString("action") == "swappedPreserved" }
        val record = JSONObject(line)
        assertEquals(sha256("R3_FCR_V4_DIVERGED"), record.getString("preservedSha256"))
        assertEquals(sha256("two"), record.getString("installedSha256"))
        assertEquals("R3_FCR_V4_DIVERGED".toByteArray().size.toLong(), record.getLong("preservedBytes"))
        assertEquals(3L, record.getLong("installedBytes"))
    }

    @Test fun syncedReplacePrunesBackupAndKeepsMeasuredFactsInJournalOnly() {
        val f = fixture()
        val (swap1, stage1) = swapFor(f, "2".repeat(32))
        val first = listOf(stagedFile(stage1, "a.txt", "one"))
        swap1.apply(first) { false }
        swap1.acknowledge(first)
        // Second import: destination STILL equals the last acked baseline, so
        // the replaced backup is manifest-proven synced (pruned at ack).
        val (swap2, stage2) = swapFor(f, "3".repeat(32))
        val second = listOf(stagedFile(stage2, "a.txt", "two"))
        val outcome = swap2.apply(second) { false }
        assertEquals(1, outcome.replacedSynced)
        assertEquals(0, outcome.preservedUnsynced)
        val fact = outcome.preserved.single()
        assertEquals("swappedSynced", fact.action)
        assertEquals(sha256("one"), fact.preservedSha256)
        swap2.acknowledge(second)
        // Honest: the synced backup was pruned at acknowledge; the measured
        // journal fact remains an audit record, not a recoverability claim.
        assertFalse(File(File(f.journalParent, ".floe-wt-" + "3".repeat(32)), "preserve/a.txt").exists())
    }

    @Test fun unchangedEntryAndSymlinkPreserveHaveNoMeasuredDigestFacts() {
        val f = fixture()
        // A symlink destination replaced by a staged file is preserved but
        // NEVER hashed by the engine -> no fabricated fact may appear.
        val (swap, stage) = swapFor(f, "4".repeat(32))
        val linkTarget = File(f.destination, "host.txt"); linkTarget.write("host")
        Files.createSymbolicLink(File(f.destination, "link.txt").toPath(), linkTarget.toPath())
        val entries = listOf(stagedFile(stage, "link.txt", "installed"))
        val outcome = swap.apply(entries) { false }
        assertEquals(1, outcome.preservedUnsynced)
        assertTrue("unmeasured custody must stay ABSENT, never zeroed", outcome.preserved.isEmpty())
        val record = JSONObject(File(File(f.journalParent, ".floe-wt-" + "4".repeat(32)), "swap.jsonl")
            .readLines().last { JSONObject(it).optString("action") == "swappedPreserved" })
        assertFalse(record.has("preservedSha256"))
        assertFalse(record.has("installedSha256"))
    }

    // ---- 2. Legacy journals (no custody keys) restore/acknowledge unchanged ----

    @Test fun legacyJournalLinesRestoreAndAcknowledgeByteCompatible() {
        val f = fixture()
        val journal = File(f.journalParent, ".floe-wt-" + "5".repeat(32))
        assertTrue(journal.mkdirs())
        val stage = File(journal, "stage"); val preserve = File(journal, "preserve")
        assertTrue(stage.mkdirs() && preserve.mkdirs())
        // A hand-written LEGACY journal (exactly the pre-feature grammar):
        // created + swappedPreserved with preservedRel but NO digest keys.
        File(f.destination, "keep.txt").write("baseline")
        File(preserve, "keep.txt").write("prior-unsynced")
        File(journal, "swap.jsonl").write(
            """{"record":"s","i":0,"path":"new.txt","kind":"file","action":"created","preservedRel":null}
               |{"record":"s","i":1,"path":"keep.txt","kind":"file","action":"swappedPreserved","preservedRel":"keep.txt"}
               |""".trimMargin())
        val swap = WorkspaceImportSwap(f.destination, stage, preserve, File(journal, "swap.jsonl"), null, f.ops)
        File(f.destination, "new.txt").write("staged")
        val summary = swap.restoreDetailed()
        assertEquals(SwapRestoreSummary(restoredPriorChanges = 1, revertedNewEntries = 1, retainedFailures = 0), summary)
        // Reverse restore truly undid both recorded actions.
        assertFalse(File(f.destination, "new.txt").exists())
        assertEquals("prior-unsynced", File(f.destination, "keep.txt").text())
        // restore() keeps the identical retained-failure return value.
        assertEquals(0, swap.restore())
    }

    @Test fun restoreCountsRetainedFailuresHonestly() {
        val f = fixture()
        val journal = File(f.journalParent, ".floe-wt-" + "6".repeat(32))
        assertTrue(journal.mkdirs())
        val stage = File(journal, "stage"); val preserve = File(journal, "preserve")
        assertTrue(stage.mkdirs() && preserve.mkdirs())
        // Record a swappedPreserved whose restore rename CANNOT land: the
        // destination is a non-empty directory (foreign kind appeared), so
        // the preserved copy must be RETAINED and counted as a failure —
        // never silently reported as restored.
        assertTrue(File(f.destination, "x.txt").mkdirs())
        File(f.destination, "x.txt/foreign.txt").write("foreign")
        File(preserve, "x.txt").write("prior")
        File(journal, "swap.jsonl").write(
            """{"record":"s","i":0,"path":"x.txt","kind":"file","action":"swappedPreserved","preservedRel":"x.txt"}""")
        val swap = WorkspaceImportSwap(f.destination, stage, preserve, File(journal, "swap.jsonl"), null, f.ops)
        val summary = swap.restoreDetailed()
        assertEquals(0, summary.restoredPriorChanges)
        assertEquals(1, summary.retainedFailures)
        assertEquals(1, swap.restore()) // legacy return value: the failure count
    }

    @Test fun restoreOnAckedJournalChangesNothing() {
        val f = fixture()
        val journal = File(f.journalParent, ".floe-wt-" + "7".repeat(32))
        assertTrue(journal.mkdirs())
        val stage = File(journal, "stage"); val preserve = File(journal, "preserve")
        assertTrue(stage.mkdirs() && preserve.mkdirs())
        File(f.destination, "a.txt").write("current")
        File(journal, "swap.jsonl").write(
            """{"record":"s","i":0,"path":"a.txt","kind":"file","action":"swappedPreserved","preservedRel":"a.txt"}
               |{"record":"ack","prunedSynced":0}
               |""".trimMargin())
        val swap = WorkspaceImportSwap(f.destination, stage, preserve, File(journal, "swap.jsonl"), null, f.ops)
        val summary = swap.restoreDetailed()
        assertEquals(SwapRestoreSummary(0, 0, 0), summary)
        assertEquals("current", File(f.destination, "a.txt").text())
    }

    // ---- 3. The bounded recovery envelope projection ----

    private fun receipt(sessionKey: String = "a".repeat(32),
                        runID: String = "A1B2C3D4-0000-4000-9000-000000000003",
                        preservedUnsynced: Int = 0,
                        preservedCopies: List<WorkspacePreservedCopy> = emptyList(),
                        conflicts: List<String> = emptyList(),
                        replacedSynced: Int = 0,
                        created: Int = 1,
                        ) = WorkspaceImportReceipt(
        sessionKey = sessionKey, runID = runID,
        createdCount = created, replacedSyncedCount = replacedSynced,
        preservedUnsyncedCount = preservedUnsynced, unchangedCount = 0,
        conflictPaths = conflicts, conflictsTruncated = false,
        appliedBytes = 128, skippedCount = 0,
        budgets = WorkspaceBudgetsView(4_194_304, 2_048, 65_536, 1_048_576, 67_108_864, 4_096, 512),
        preservedCopies = preservedCopies,
        preservedCopiesTruncated = false,
    )

    private val synced = WorkspaceExportOutcome.Synced("k", 1, 0, 0, 0, 0, 0, sha256("plan"))

    @Test fun cleanSyncedEnvelopeCarriesOnlyRealSections() {
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(receipt(), synced)!!
        val import = envelope.getJSONObject("import")
        assertEquals("clean", import.getString("outcome"))
        assertFalse(import.has("preserved"))
        assertEquals("synced", envelope.getJSONObject("export").getString("result"))
        assertEquals(sha256("plan"), envelope.getJSONObject("export").getString("planDigest"))
        assertEquals("a".repeat(32), envelope.getString("sessionKey"))
        assertEquals("A1B2C3D4-0000-4000-9000-000000000003", envelope.getString("runID"))
    }

    @Test fun swappedPreservedEnvelopeReportsBothRevisions() {
        val copy = WorkspacePreservedCopy("r3cas/marker.txt", sha256("V4"), 30, sha256("V2"), 27)
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt(preservedUnsynced = 1, preservedCopies = listOf(copy), created = 0, replacedSynced = 1),
            WorkspaceExportOutcome.RecoverableFailure("budgetExceeded", true, null),
        )!!
        assertEquals("swappedPreserved", envelope.getJSONObject("import").getString("outcome"))
        val entry = envelope.getJSONObject("import").getJSONArray("preserved").getJSONObject(0)
        assertEquals("r3cas/marker.txt", entry.getString("path"))
        assertEquals(sha256("V4"), entry.getString("preservedSha256"))
        assertEquals(30, entry.getLong("preservedBytes"))
        assertEquals(sha256("V2"), entry.getString("installedBaselineSha256"))
        assertEquals(27, entry.getLong("installedBaselineBytes"))
        val export = envelope.getJSONObject("export")
        assertEquals("budgetExceeded", export.getString("failureCode"))
        assertTrue(export.getBoolean("stagedPreserved"))
        assertFalse(export.has("result"))
    }

    @Test fun unobservedSymlinkPreserveCountsButAddsNoEntries() {
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt(preservedUnsynced = 1, preservedCopies = emptyList()), synced)!!
        assertEquals("swappedPreserved", envelope.getJSONObject("import").getString("outcome"))
        assertEquals(1, envelope.getJSONObject("import").getInt("preservedUnsynced"))
        assertFalse("no verified entries may be fabricated for an unhashed preserve",
            envelope.getJSONObject("import").has("preserved"))
    }

    @Test fun conflictTypedOutcomeSurvives() {
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt(conflicts = listOf("dir/a.txt")),
            WorkspaceExportOutcome.Conflict("k", "conflict", 0, 1, 0, 0, 0,
                listOf(WorkspaceConflictRecord("dir/a.txt", "file", true)), false, 0, 0, "not-a-digest"),
        )!!
        assertEquals("conflict", envelope.getJSONObject("import").getString("outcome"))
        val export = envelope.getJSONObject("export")
        assertEquals("conflict", export.getString("result"))
        assertEquals("dir/a.txt", export.getJSONArray("conflicts").getJSONObject(0).getString("path"))
        assertFalse("invalid index digest stays ABSENT, never forwarded as garbage", export.has("indexDigest"))
    }

    @Test fun malformedSessionKeyRefusesTheWholeProjection() {
        assertNull(RuntimeWorkspaceSession.executionRecoveryJSON(receipt(sessionKey = "nope"), synced))
    }

    @Test fun envelopeStaysBounded() {
        val many = (1..20).map { WorkspacePreservedCopy("p$it/f.txt", sha256("v$it"), 1, sha256("b$it"), 1) }
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt(preservedUnsynced = 20, preservedCopies = many), synced)!!
        val entries = envelope.getJSONObject("import").getJSONArray("preserved")
        assertTrue(entries.length() <= 16)
        assertTrue(envelope.toString().toByteArray(Charsets.UTF_8).size <= 8_192)
    }

    @Test fun recoverableFailureWithoutKeyKeepsIdentityAtTopLevel() {
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt(), WorkspaceExportOutcome.RecoverableFailure("exportResultUncertain", true, null))!!
        val export = envelope.getJSONObject("export")
        assertEquals("exportResultUncertain", export.getString("failureCode"))
        assertFalse(export.has("exportSessionKey"))
        assertEquals("a".repeat(32), envelope.getString("sessionKey"))
    }
}
