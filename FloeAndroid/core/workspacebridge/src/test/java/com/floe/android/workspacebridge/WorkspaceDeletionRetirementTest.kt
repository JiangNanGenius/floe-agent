// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

/**
 * Regression source for the Samsung107 G2 native-deletion resurrection
 * (n05-software-space81/samsung107-g2/DELETED_FILE_RETURNED_ORIGINAL.json):
 * a previously synced guest file whose authoritative Core entry was deleted
 * natively was re-imported as a NEW user file by the next import/export
 * round trip.
 *
 * The engine under test is the REAL production transaction core
 * ([WorkspaceImportSwap.retireAbsent] on the same stable destination and
 * journal grammar used by `RuntimeWorkspaceSession`). No Android, Gradle,
 * device or Swift path is faked. These tests are AUTHORED ONLY by this lane:
 * the primary owner compiles and runs them.
 */
class WorkspaceDeletionRetirementTest {

    private fun tempRoot(): File = Files.createTempDirectory("floe-retirement-test").toFile()
        .apply { deleteOnExit() }

    /** JVM live-input backend: the shared [JvmSwapOps] plus the actual
     *  descriptor-anchored creation surface production implements. */
    private class RetirementJvmOps(
        private val base: JvmSwapOps = JvmSwapOps(),
    ) : WorkspaceSwapOps by base {
        override fun kindNoFollow(root: File, relativePath: String): SwapKind {
            val parts = WorkspaceRelativeValidation.validate(relativePath) ?: return SwapKind.UNREADABLE
            var cursor = root
            for (part in parts.dropLast(1)) {
                cursor = File(cursor, part)
                when (base.kind(cursor)) {
                    SwapKind.MISSING -> return SwapKind.MISSING
                    SwapKind.DIRECTORY -> Unit
                    else -> return SwapKind.UNREADABLE
                }
            }
            return base.kind(File(root, relativePath))
        }

        override fun installNewFile(stage: File, root: File, relativePath: String): Boolean = try {
            val target = File(root, relativePath)
            target.parentFile?.mkdirs()
            Files.createLink(target.toPath(), stage.toPath())
            true
        } catch (_: Exception) {
            false
        }

        override fun createNewDirectory(root: File, relativePath: String): Boolean = try {
            Files.createDirectory(File(root, relativePath).toPath())
            true
        } catch (_: Exception) {
            false
        }

        override fun createNewSymlink(root: File, relativePath: String, target: String): Boolean = try {
            Files.createSymbolicLink(File(root, relativePath).toPath(), File(target).toPath())
            true
        } catch (_: Exception) {
            false
        }
    }

    private class Fixture(
        val parent: File,
        val destination: File,
        val projectID: String,
        val ops: WorkspaceSwapOps,
    )

    private fun fixture(): Fixture {
        val parent = tempRoot()
        val projectID = "A1B2C3D4-0000-4000-9000-00000000A11C"
        val destination = File(parent, "Workspaces/" + projectID.lowercase())
        assertTrue(destination.mkdirs())
        return Fixture(parent, destination, projectID, RetirementJvmOps())
    }

    private fun newSwap(f: Fixture, tag: String,
                        priorProofs: Map<String, List<WorkspaceSyncedProof>>? = null): Pair<WorkspaceImportSwap, File> {
        val journal = File(f.parent, ".floe-wt-$tag")
        assertTrue(journal.mkdirs())
        val stage = File(journal, "stage")
        val preserve = File(journal, "preserve")
        assertTrue(stage.mkdirs() && preserve.mkdirs())
        val swap = WorkspaceImportSwap(
            f.destination, stage, preserve, File(journal, "swap.jsonl"),
            WorkspaceSyncManifest(f.parent, f.projectID, f.ops), f.ops, priorProofs = priorProofs,
        )
        return swap to stage
    }

    private fun proofs(f: Fixture): Map<String, List<WorkspaceSyncedProof>> =
        mergeSyncedProofs(
            emptyList(),
            WorkspaceSyncedLedger(f.parent, f.projectID, f.ops).snapshotOrNull()
                ?: WorkspaceSyncManifest(f.parent, f.projectID, f.ops).snapshot(),
        )

    private fun File.write(text: String) {
        Files.write(toPath(), text.toByteArray(Charsets.UTF_8))
    }

    private fun File.text(): String = String(Files.readAllBytes(toPath()), Charsets.UTF_8)

    private fun sha256(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun stagedFile(stage: File, path: String, content: String,
                           mode: Int = WorkspaceFileModes.FILE_DEFAULT): StagedEntry {
        val target = File(stage, path)
        target.parentFile?.mkdirs()
        target.write(content)
        return StagedEntry(path, "file", mode, null, sha256(content),
            content.toByteArray(Charsets.UTF_8).size.toLong())
    }

    // ---- 1. The actual G2 shape: unchanged synced file, native deletion ----

    @Test
    fun nativeDeletionOfUnchangedSyncedFileIsRetiredNotResurrected() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "0".repeat(32))
        val original = stagedFile(stage1, "qa_report.md", "original")
        swap1.apply(listOf(original)) { false }
        swap1.acknowledge(listOf(original))
        assertEquals("original", File(f.destination, "qa_report.md").text())

        // The native App deleted qa_report.md: the fresh Core snapshot has
        // NO entry for it, while the stable guest destination still does.
        val (swap2, _) = newSwap(f, "1".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }

        assertEquals(1, outcome.retiredSynced)
        assertEquals(0, outcome.retiredModified)
        assertTrue(outcome.conflicts.isEmpty())
        assertFalse(File(f.destination, "qa_report.md").exists())

        val preserve = File(File(f.parent, ".floe-wt-" + "1".repeat(32)), "preserve/qa_report.md")
        swap2.acknowledge(emptyList())
        // An EXACT unchanged synced copy has no independent value after the
        // authoritative native deletion; its journal backup is pruned.
        assertFalse(preserve.exists())
        assertFalse(File(f.destination, "qa_report.md").exists())
    }

    // ---- 2. The actual G2 bytes: guest diverged before the native delete ----

    @Test
    fun nativeDeletionOfDivergedSyncedFilePreservesBytesAndReportsConflict() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "2".repeat(32))
        val original = stagedFile(stage1, "n05-g1-20261112.svg", "red")
        swap1.apply(listOf(original)) { false }
        swap1.acknowledge(listOf(original))

        // G1's real Inkscape save produced different bytes; the import
        // manifest still proves the red baseline. The native App then
        // deleted the file.
        File(f.destination, "n05-g1-20261112.svg").write("blue")
        val (swap2, _) = newSwap(f, "3".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }

        assertEquals(0, outcome.retiredSynced)
        assertEquals(1, outcome.retiredModified)
        assertEquals(listOf("n05-g1-20261112.svg"), outcome.conflicts)
        assertFalse(File(f.destination, "n05-g1-20261112.svg").exists())
        val preserve = File(File(f.parent, ".floe-wt-" + "3".repeat(32)),
            "preserve/n05-g1-20261112.svg")
        assertEquals("blue", preserve.text())

        swap2.acknowledge(emptyList())
        // Diverged/unsynced bytes stay recoverable; only exact synced
        // deletions are pruned.
        assertTrue(preserve.exists())
        assertEquals("blue", preserve.text())
    }

    // ---- 3. Guest-only data without a proof is never retirement material ----

    @Test
    fun guestOnlyFileWithoutAProofIsNeverTouchedByAbsence() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "4".repeat(32))
        val synced = stagedFile(stage1, "qa_report.md", "original")
        swap1.apply(listOf(synced)) { false }
        swap1.acknowledge(listOf(synced))

        File(f.destination, "independent-guest.txt").write("guest output")
        val (swap2, _) = newSwap(f, "5".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), setOf("qa_report.md")) { false }

        assertEquals(0, outcome.retiredSynced)
        assertEquals(0, outcome.retiredModified)
        assertTrue(File(f.destination, "independent-guest.txt").exists())
        assertEquals("guest output", File(f.destination, "independent-guest.txt").text())
        assertEquals("original", File(f.destination, "qa_report.md").text())
    }

    // ---- 4. Guest-created entries proven by a SUCCESSFUL export ledger ----

    @Test
    fun exportedGuestCreationIsRetiredAfterNativeDeletion() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "6".repeat(32))
        val synced = stagedFile(stage1, "qa_report.md", "original")
        swap1.apply(listOf(synced)) { false }
        swap1.acknowledge(listOf(synced))

        // G1 created this INPUT in the guest and its successful stop export
        // committed it to Core; the ledger is the durable proof.
        File(f.destination, "inbox-note.txt").write("created in guest")
        WorkspaceSyncedLedger(f.parent, f.projectID, f.ops).commit(listOf(
            WorkspaceSyncedProof("inbox-note.txt", "file", 16, sha256("created in guest"), null),
        ))
        // Native deletion of the guest-created entry before the next start.
        val (swap2, _) = newSwap(f, "7".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), setOf("qa_report.md")) { false }

        assertEquals(1, outcome.retiredSynced)
        assertEquals(0, outcome.retiredModified)
        assertFalse(File(f.destination, "inbox-note.txt").exists())
    }

    @Test
    fun divergedExportedCreationIsPreservedWithAConflict() {
        val f = fixture()
        val (swap1, _) = newSwap(f, "8".repeat(32))
        swap1.apply(emptyList()) { false }
        swap1.acknowledge(emptyList())

        WorkspaceSyncedLedger(f.parent, f.projectID, f.ops).commit(listOf(
            WorkspaceSyncedProof("inbox-note.txt", "file", 8, sha256("exported"), null),
        ))
        File(f.destination, "inbox-note.txt").write("later edit")
        val (swap2, _) = newSwap(f, "9".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }

        assertEquals(0, outcome.retiredSynced)
        assertEquals(1, outcome.retiredModified)
        assertEquals(listOf("inbox-note.txt"), outcome.conflicts)
        assertEquals("later edit",
            File(File(f.parent, ".floe-wt-" + "9".repeat(32)), "preserve/inbox-note.txt").text())
    }

    // ---- 5. Cancellation reverses every retirement operation ----

    @Test
    fun cancellationAfterFirstRetirementRestoresThePriorWorkspace() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "a".repeat(32))
        val entries = listOf(stagedFile(stage1, "a.md", "A"), stagedFile(stage1, "b.md", "B"))
        swap1.apply(entries) { false }
        swap1.acknowledge(entries)

        val (swap2, _) = newSwap(f, "b".repeat(32))
        var checks = 0
        try {
            swap2.retireAbsent(proofs(f), emptySet()) { ++checks > 1 }
            fail("cancellation must be reported")
        } catch (failure: WorkspaceSwapException) {
            assertEquals("swapCancelled", failure.code)
        }
        val restored = swap2.restoreDetailed()
        assertEquals(0, restored.retainedFailures)
        assertEquals("A", File(f.destination, "a.md").text())
        assertEquals("B", File(f.destination, "b.md").text())
        assertTrue(swap2.openPreserveCount() == 0)
    }

    // ---- 6. Directories: empty synced dir retires, guest descendants stay ----

    @Test
    fun provenDirectoryRetiresOnlyWhenNoGuestOnlyChildRemains() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "c".repeat(32))
        val entries = listOf(
            StagedEntry("docs", "directory", WorkspaceFileModes.DIR_DEFAULT, null, "", 0),
            stagedFile(stage1, "docs/keep.md", "keep"),
        )
        swap1.apply(entries) { false }
        swap1.acknowledge(entries)

        File(f.destination, "docs/guest-only.txt").write("new guest data")
        val (swap2, _) = newSwap(f, "d".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }

        assertEquals(1, outcome.retiredSynced) // docs/keep.md only
        assertFalse(File(f.destination, "docs/keep.md").exists())
        assertTrue(File(f.destination, "docs").isDirectory)
        assertEquals("new guest data", File(f.destination, "docs/guest-only.txt").text())
    }

    @Test
    fun provenEmptyDirectoryIsRetiredWithItsProvenChildren() {
        val f = fixture()
        val (swap1, stage1) = newSwap(f, "e".repeat(32))
        val entries = listOf(
            StagedEntry("docs", "directory", WorkspaceFileModes.DIR_DEFAULT, null, "", 0),
            stagedFile(stage1, "docs/keep.md", "keep"),
        )
        swap1.apply(entries) { false }
        swap1.acknowledge(entries)

        val (swap2, _) = newSwap(f, "f".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }

        assertEquals(2, outcome.retiredSynced)
        assertFalse(File(f.destination, "docs").exists())
        assertFalse(File(f.destination, "docs/keep.md").exists())
    }

    // ---- 7. Symlinks: exact target retires, changed target stays safe ----

    @Test
    fun provenSymlinkRetiresOnlyOnExactTargetMatch() {
        val f = fixture()
        val (swap1, _) = newSwap(f, "1".repeat(32))
        val link = StagedEntry("link.md", "symlink", WorkspaceFileModes.LINK_NOMINAL,
            "missing-target.md", "", 0)
        swap1.apply(listOf(link)) { false }
        swap1.acknowledge(listOf(link))
        assertTrue(Files.isSymbolicLink(File(f.destination, "link.md").toPath()))

        val (swap2, _) = newSwap(f, "2".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }
        assertEquals(1, outcome.retiredSynced)
        assertFalse(File(f.destination, "link.md").exists())
        val preserved = File(File(f.parent, ".floe-wt-" + "2".repeat(32)), "preserve/link.md")
        assertTrue(Files.isSymbolicLink(preserved.toPath()))
        assertEquals("missing-target.md", Files.readSymbolicLink(preserved.toPath()).toString())
    }

    @Test
    fun symlinkTargetChangeIsPreservedAndReportedNotDeleted() {
        val f = fixture()
        val (swap1, _) = newSwap(f, "3".repeat(32))
        val link = StagedEntry("link.md", "symlink", WorkspaceFileModes.LINK_NOMINAL,
            "old-target.md", "", 0)
        swap1.apply(listOf(link)) { false }
        swap1.acknowledge(listOf(link))
        Files.delete(File(f.destination, "link.md").toPath())
        Files.createSymbolicLink(File(f.destination, "link.md").toPath(),
            File("new-target.md").toPath())

        val (swap2, _) = newSwap(f, "4".repeat(32))
        val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }
        assertEquals(0, outcome.retiredSynced)
        assertEquals(1, outcome.retiredModified)
        assertEquals(listOf("link.md"), outcome.conflicts)
        val preserved = File(File(f.parent, ".floe-wt-" + "4".repeat(32)), "preserve/link.md")
        assertTrue(Files.isSymbolicLink(preserved.toPath()))
        assertEquals("new-target.md", Files.readSymbolicLink(preserved.toPath()).toString())
    }

    @Test
    fun symlinkedAncestorIsNeverFollowedOrTreatedAsADirectory() {
        val f = fixture()
        val outside = Files.createTempDirectory("floe-retirement-outside-").toFile()
        try {
            File(outside, "victim.txt").write("victim")
            Files.createSymbolicLink(File(f.destination, "escape").toPath(), outside.toPath())
            WorkspaceSyncManifest(f.parent, f.projectID, f.ops).commit(listOf(
                StagedEntry("escape/victim.txt", "file", WorkspaceFileModes.FILE_DEFAULT,
                    null, sha256("victim"), 6),
            ))
            val (swap2, _) = newSwap(f, "5".repeat(32))
            val outcome = swap2.retireAbsent(proofs(f), emptySet()) { false }

            // The descendant is unreachable without following `escape`; the
            // symlink itself may be preserved as a modified path, but the
            // OUTSIDE victim must never be read, moved or deleted.
            assertEquals("victim", File(outside, "victim.txt").text())
            assertTrue(outcome.conflicts.contains("escape") || outcome.retiredModified == 0)
            assertTrue(Files.isSymbolicLink(File(f.destination, "escape").toPath()) ||
                !File(f.destination, "escape").exists())
        } finally {
            outside.deleteRecursively()
        }
    }

    // ---- 8. Additions-only imports retain the live tree ----

    @Test
    fun additionsOnlyTransferNeverPrunesAnExistingLiveFile() {
        val f = fixture()
        File(f.destination, "old.txt").write("live guest truth")
        val (swap, stage) = newSwap(f, "6".repeat(32))
        val input = stagedFile(stage, "new-input.txt", "from host")
        val outcome = swap.applyMissingOnly(listOf(input)) { false }

        assertEquals(1, outcome.created)
        assertEquals("live guest truth", File(f.destination, "old.txt").text())
        assertEquals("from host", File(f.destination, "new-input.txt").text())
    }

    // ---- 9. Durable proof read/write and union semantics ----

    @Test
    fun manifestAndLedgerRoundTripAllKindsAndKeepFileOnlyPruneLicense() {
        val f = fixture()
        val entries = listOf(
            StagedEntry("docs", "directory", WorkspaceFileModes.DIR_DEFAULT, null, "", 0),
            StagedEntry("docs/a.md", "file", WorkspaceFileModes.FILE_DEFAULT, null, sha256("a"), 1),
            StagedEntry("docs/link", "symlink", WorkspaceFileModes.LINK_NOMINAL, "a.md", "", 0),
        )
        f.manifest().commit(entries)
        val snapshot = f.manifest().snapshot().associateBy { it.path }
        assertEquals("directory", snapshot.getValue("docs").kind)
        assertEquals(sha256("a"), snapshot.getValue("docs/a.md").digest)
        assertEquals("a.md", snapshot.getValue("docs/link").linkTarget)
        assertNotNull(f.manifest().lookup("docs/a.md"))
        assertNull("directory/symlink records never license file pruning",
            f.manifest().lookup("docs/link"))
        assertFalse(f.manifest().snapshot().any { it.path == "missing" })

        f.ledger().commit(listOf(
            WorkspaceSyncedProof("new.txt", "file", 3, sha256("new"), null),
        ))
        assertEquals(listOf("new.txt"), f.ledger().snapshot().map { it.path })
    }

    @Test
    fun proofUnionAddsAncestorDirectoryProofsWithoutDuplicates() {
        val merged = mergeSyncedProofs(
            listOf(WorkspaceSyncedProof("docs/a.md", "file", 1, sha256("a"), null)),
            listOf(WorkspaceSyncedProof("new.txt", "file", 3, sha256("new"), null)),
        )
        assertEquals(setOf("docs", "docs/a.md", "new.txt"), merged.keys)
        assertEquals("directory", merged.getValue("docs").single().kind)
        assertEquals(1, merged.getValue("docs/a.md").size)
    }

    @Test
    fun latestExportDoesNotLicensePruningAnUnsavedReversionToOldImport() {
        val f = fixture()
        f.manifest().commit(listOf(StagedEntry("file.txt", "file", WorkspaceFileModes.FILE_DEFAULT,
            null, sha256("old"), 3)))
        f.ledger().commit(listOf(WorkspaceSyncedProof("file.txt", "file", 3, sha256("new"), null)))
        File(f.destination, "file.txt").write("old") // unsaved reversion after the successful export
        val (swap, _) = newSwap(f, "b".repeat(32))
        val outcome = swap.retireAbsent(proofs(f), emptySet()) { false }
        assertEquals(0, outcome.retiredSynced)
        assertEquals(1, outcome.retiredModified)
        assertEquals("old", File(f.parent, ".floe-wt-${"b".repeat(32)}/preserve/file.txt").text())
    }

    @Test
    fun freshImportAlsoPreservesAnUnsavedReversionToOldBaseline() {
        val f = fixture()
        f.manifest().commit(listOf(StagedEntry("file.txt", "file", WorkspaceFileModes.FILE_DEFAULT,
            null, sha256("old"), 3)))
        f.ledger().commit(listOf(WorkspaceSyncedProof("file.txt", "file", 3, sha256("new"), null)))
        File(f.destination, "file.txt").write("old")
        val (swap, stage) = newSwap(f, "a".repeat(32), proofs(f))
        val current = stagedFile(stage, "file.txt", "new")
        val outcome = swap.apply(listOf(current)) { false }
        swap.acknowledge(listOf(current))
        assertEquals(1, outcome.preservedUnsynced)
        assertEquals(0, outcome.replacedSynced)
        assertEquals("old", File(f.parent, ".floe-wt-${"a".repeat(32)}/preserve/file.txt").text())
        assertEquals("new", File(f.destination, "file.txt").text())
    }

    @Test
    fun newImportGenerationRejectsAnOlderExportEvenWithIdenticalBaselineBytes() {
        val f = fixture()
        val baseline = listOf(StagedEntry("file.txt", "file", WorkspaceFileModes.FILE_DEFAULT,
            null, sha256("old"), 3))
        f.manifest().commit(baseline)
        val first = f.manifest().generation()
        f.ledger().commit(listOf(WorkspaceSyncedProof("file.txt", "file", 3, sha256("new"), null)))
        f.manifest().commit(baseline)
        assertFalse(first == f.manifest().generation())
        assertNull(f.ledger().snapshotOrNull())
        File(f.destination, "file.txt").write("new") // new unsaved change in the new import
        val (swap, _) = newSwap(f, "c".repeat(32))
        assertEquals(1, swap.retireAbsent(proofs(f), emptySet()) { false }.retiredModified)
    }

    @Test
    fun emptyOrUncertainExportNeverRevivesOlderImportProofs() {
        val f = fixture()
        f.manifest().commit(listOf(StagedEntry("file.txt", "file", WorkspaceFileModes.FILE_DEFAULT,
            null, sha256("old"), 3)))
        assertTrue(f.ledger().beginExport())
        assertNotNull(f.ledger().snapshotOrNull())
        assertTrue(proofs(f).isEmpty())
        f.ledger().commit(emptyList())
        assertNotNull(f.ledger().snapshotOrNull())
        File(f.destination, "file.txt").write("new guest creation")
        val (swap, _) = newSwap(f, "d".repeat(32))
        assertEquals(0, swap.retireAbsent(proofs(f), emptySet()) { false }.retiredSynced)
        assertEquals("new guest creation", File(f.destination, "file.txt").text())
    }

    @Test
    fun legacyImportCannotProveNoLaterUnsavedChange() {
        val f = fixture()
        f.manifest().commit(listOf(StagedEntry("legacy.txt", "file", WorkspaceFileModes.FILE_DEFAULT,
            null, sha256("old"), 3)))
        val manifest = File(f.parent, ".floe-ws-${f.projectID.lowercase()}/manifest.jsonl")
        manifest.write(manifest.readLines().drop(1).joinToString("\n", postfix = "\n"))
        assertNull(f.manifest().generation())
        File(f.destination, "legacy.txt").write("old")
        val (swap, _) = newSwap(f, "e".repeat(32))
        val result = swap.retireAbsent(proofs(f), emptySet(), allowSyncedPrune = false) { false }
        swap.acknowledge(emptyList())
        assertEquals(0, result.retiredSynced)
        assertEquals(1, result.retiredModified)
        assertEquals("old", File(f.parent, ".floe-wt-${"e".repeat(32)}/preserve/legacy.txt").text())
    }

    @Test
    fun failedTempUnlinkDoesNotFollowLedgerSymlink() {
        val f = fixture()
        f.manifest().commit(emptyList())
        val victim = File(f.parent, "victim.txt").apply { write("unchanged") }
        val temp = File(f.parent, ".floe-ws-${f.projectID.lowercase()}/exported.tmp")
        Files.createSymbolicLink(temp.toPath(), victim.toPath())
        val refusal = object : WorkspaceSwapOps by f.ops {
            override fun unlink(file: File): Boolean = if (file == temp) false else f.ops.unlink(file)
        }
        assertFalse(WorkspaceSyncedLedger(f.parent, f.projectID, refusal).beginExport())
        assertEquals("unchanged", victim.text())
    }

    // ---- 10. Bounded recovery projection is additive and honest ----

    @Test
    fun recoveryProjectionNamesRetiredCountsAndConflictPaths() {
        val receipt = WorkspaceImportReceipt(
            sessionKey = "a".repeat(32),
            createdCount = 0,
            replacedSyncedCount = 0,
            preservedUnsyncedCount = 0,
            unchangedCount = 1,
            conflictPaths = listOf("n05-g1-20261112.svg"),
            conflictsTruncated = false,
            appliedBytes = 0,
            skippedCount = 0,
            budgets = WorkspaceBudgetsView(1_000_000, 100, 65_536, 100_000, 0, 4_096, 4_096),
            retiredSyncedCount = 1,
            retiredModifiedCount = 1,
        )
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt,
            WorkspaceExportOutcome.Synced("k", 0, 0, 0, 0, 0, 0, "b".repeat(64)),
        )!!
        val section = envelope.getJSONObject("import")
        assertEquals("conflict", section.getString("outcome"))
        assertEquals(1, section.getInt("retiredSynced"))
        assertEquals(1, section.getInt("retiredModified"))
        assertEquals("n05-g1-20261112.svg",
            section.getJSONArray("conflicts").getString(0))
        assertEquals("synced", envelope.getJSONObject("export").getString("result"))
    }

    @Test
    fun cleanReceiptKeepsRetiredFieldsAbsent() {
        val receipt = WorkspaceImportReceipt(
            sessionKey = "a".repeat(32),
            createdCount = 1,
            replacedSyncedCount = 0,
            preservedUnsyncedCount = 0,
            unchangedCount = 0,
            conflictPaths = emptyList(),
            conflictsTruncated = false,
            appliedBytes = 3,
            skippedCount = 0,
            budgets = WorkspaceBudgetsView(1_000_000, 100, 65_536, 100_000, 0, 4_096, 4_096),
        )
        val envelope = RuntimeWorkspaceSession.executionRecoveryJSON(
            receipt,
            WorkspaceExportOutcome.Synced("k", 1, 0, 0, 0, 0, 0, "c".repeat(64)),
        )!!
        val section = envelope.getJSONObject("import")
        assertEquals("clean", section.getString("outcome"))
        assertFalse(section.has("retiredSynced"))
        assertFalse(section.has("retiredModified"))
    }

    private fun Fixture.manifest(): WorkspaceSyncManifest =
        WorkspaceSyncManifest(parent, projectID, ops)

    private fun Fixture.ledger(): WorkspaceSyncedLedger =
        WorkspaceSyncedLedger(parent, projectID, ops)
}
