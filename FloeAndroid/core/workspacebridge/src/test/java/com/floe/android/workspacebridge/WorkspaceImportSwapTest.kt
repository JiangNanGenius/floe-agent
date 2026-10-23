// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

/** JVM [WorkspaceSwapOps] for the swap-engine fixtures ONLY (production uses
 *  DefaultSwapOps on android.system.Os). Same no-follow semantics. */
class JvmSwapOps : WorkspaceSwapOps {
    override fun kind(path: File): SwapKind = try {
        val attrs = Files.readAttributes(path.toPath(), BasicFileAttributes::class.java,
                                         LinkOption.NOFOLLOW_LINKS)
        when {
            attrs.isRegularFile -> SwapKind.FILE
            attrs.isDirectory -> SwapKind.DIRECTORY
            attrs.isSymbolicLink -> SwapKind.SYMLINK
            else -> SwapKind.OTHER
        }
    } catch (failure: Exception) {
        if (failure is java.nio.file.NoSuchFileException) SwapKind.MISSING
        else if (failure is java.nio.file.AccessDeniedException) SwapKind.UNREADABLE
        else SwapKind.UNREADABLE
    }

    override fun size(path: File): Long = try {
        Files.readAttributes(path.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS).size()
    } catch (_: Exception) {
        -1
    }

    override fun rename(from: File, to: File): Boolean = try {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        true
    } catch (_: Exception) {
        false
    }

    override fun mkdir(path: File): Boolean = try {
        Files.createDirectory(path.toPath())
        true
    } catch (_: Exception) {
        // EEXIST and every other failure are false, matching Os.mkdir
        // semantics the engine relies on.
        false
    }

    override fun rmdir(path: File): Boolean = try {
        Files.delete(path.toPath())
        true
    } catch (_: Exception) {
        false
    }

    override fun unlink(path: File): Boolean = try {
        Files.delete(path.toPath())
        true
    } catch (_: Exception) {
        false
    }

    override fun symlink(target: String, path: File): Boolean = try {
        Files.createSymbolicLink(path.toPath(), File(target).toPath())
        true
    } catch (_: Exception) {
        false
    }

    override fun streamDigest(path: File): Pair<String, Long>? = try {
        val hasher = MessageDigest.getInstance("SHA-256")
        var total = 0L
        Files.newInputStream(path.toPath()).use { input ->
            val buffer = ByteArray(65_536)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                hasher.update(buffer, 0, count)
                total += count
            }
        }
        hasher.digest().joinToString("") { "%02x".format(it) } to total
    } catch (_: Exception) {
        null
    }

    override fun freeBytes(path: File): Long = Files.getFileStore(path.toPath()).usableSpace

    override fun fsyncDirectory(path: File) = Unit
}

class WorkspaceImportSwapTest {
    private fun tempRoot(): File {
        val root = Files.createTempDirectory("floe-wsbridge-test").toFile()
        root.deleteOnExit()
        return root
    }

    private data class Fixture(val destination: File, val journal: File, val stage: File, val preserve: File,
                               val manifest: WorkspaceSyncManifest, val swap: WorkspaceImportSwap, val ops: JvmSwapOps)

    private fun fixture(projectID: String = "A1B2C3D4-0000-4000-8000-000000000001",
                        onFirstAppliedChange: () -> Unit = {}): Fixture {
        val parent = tempRoot()
        val destination = File(parent, "Workspaces/" + projectID.lowercase())
        assertTrue(destination.mkdirs())
        val ops = JvmSwapOps()
        val journal = File(parent, ".floe-wt-" + "0".repeat(32))
        assertTrue(journal.mkdirs())
        val stage = File(journal, "stage")
        val preserve = File(journal, "preserve")
        assertTrue(stage.mkdirs() && preserve.mkdirs())
        val manifest = WorkspaceSyncManifest(destination.parentFile, projectID, ops)
        val swap = WorkspaceImportSwap(destination, stage, preserve, File(journal, "swap.jsonl"), manifest, ops, onFirstAppliedChange)
        return Fixture(destination, journal, stage, preserve, manifest, swap, ops)
    }

    private fun File.write(text: String) {
        Files.write(toPath(), text.toByteArray(Charsets.UTF_8))
    }
    private fun File.text() = String(Files.readAllBytes(toPath()), Charsets.UTF_8)

    private fun stagedFile(fixture: Fixture, path: String, content: String, mode: Int = 420): StagedEntry {
        val target = File(fixture.stage, path)
        target.parentFile?.mkdirs()
        target.write(content)
        val digest = fixture.ops.streamDigest(target)!!.first
        return StagedEntry(path, "file", mode, null, digest, content.toByteArray(Charsets.UTF_8).size.toLong())
    }

    @Test
    fun progressAfterRealJournaledChangeIsFiniteAndCannotPoisonRestore() {
        var events = 0
        var journaled = false
        var observedBytes: String? = null
        lateinit var f: Fixture
        f = fixture(onFirstAppliedChange = {
            events += 1
            journaled = File(f.journal, "swap.jsonl").readText().contains("created")
            observedBytes = File(f.destination, "a.txt").text()
            error("observational sink failed")
        })
        val outcome = f.swap.apply(listOf(stagedFile(f, "a.txt", "one"),
                                          stagedFile(f, "b.txt", "two"))) { false }
        assertEquals(2, outcome.created)
        assertEquals(1, events)
        assertTrue(journaled)
        assertEquals("one", observedBytes)
        assertEquals(2, f.swap.restoreDetailed().revertedNewEntries)
        assertFalse(File(f.destination, "a.txt").exists())
        assertFalse(File(f.destination, "b.txt").exists())
    }

    @Test
    fun firstImportIntoCleanWorkspaceCreatesEverything() {
        val f = fixture()
        val entries = listOf(
            StagedEntry("docs", "directory", 493, null, "", 0),
            stagedFile(f, "docs/a.txt", "hello"),
            StagedEntry("docs/link", "symlink", 511, "a.txt", "", 0),
        )
        val outcome = f.swap.apply(entries) { false }
        f.swap.acknowledge(entries)
        // docs/, docs/a.txt and docs/link all land on a clean destination.
        assertEquals(3, outcome.created)
        assertEquals(0, outcome.unchanged)
        assertEquals(0, outcome.preservedUnsynced)
        assertEquals("hello", File(f.destination, "docs/a.txt").text())
        assertTrue(File(f.destination, "docs/link").text().let { it.isNotEmpty() })
    }

    @Test
    fun repeatImportReplacesSyncedBytesAndPrunesOnlySyncedBackups() {
        val f = fixture()
        val first = listOf(stagedFile(f, "a.txt", "one"))
        f.swap.apply(first) { false }
        f.swap.acknowledge(first)
        assertEquals("one", File(f.destination, "a.txt").text())
        // Second import into the SAME stable destination with changed bytes.
        val f2stage = File(f.journal.parentFile, "second-stage")
        assertTrue(f2stage.mkdirs())
        val ops = f.ops
        val journal2 = File(f.journal.parentFile, ".floe-wt-" + "1".repeat(32))
        assertTrue(journal2.mkdirs())
        val stage2 = File(journal2, "stage"); val preserve2 = File(journal2, "preserve")
        assertTrue(stage2.mkdirs() && preserve2.mkdirs())
        val manifest2 = WorkspaceSyncManifest(f.destination.parentFile, "A1B2C3D4-0000-4000-8000-000000000001", ops)
        val swap2 = WorkspaceImportSwap(f.destination, stage2, preserve2, File(journal2, "swap.jsonl"), manifest2, ops)
        val target = File(stage2, "a.txt"); target.parentFile.mkdirs(); target.write("two")
        val digest = ops.streamDigest(target)!!.first
        val second = listOf(StagedEntry("a.txt", "file", 420, null, digest, 3))
        val outcome = swap2.apply(second) { false }
        assertEquals(1, outcome.replacedSynced)
        assertEquals("two", File(f.destination, "a.txt").text())
        val preservedOld = File(preserve2, "a.txt")
        assertTrue(preservedOld.exists()) // backup exists BEFORE acknowledge
        swap2.acknowledge(second)
        assertFalse(preservedOld.exists())  // synced backup pruned AFTER acknowledge
    }

    @Test
    fun unsyncedGuestEditsArePreservedNotBlindlyDeleted() {
        val f = fixture()
        val first = listOf(stagedFile(f, "a.txt", "one"))
        f.swap.apply(first) { false }
        f.swap.acknowledge(first)
        // The guest (Linux side) edited the file afterwards: manifest no
        // longer matches the actual bytes.
        File(f.destination, "a.txt").write("guest-edit")
        val journal2 = File(f.journal.parentFile, ".floe-wt-" + "2".repeat(32))
        assertTrue(journal2.mkdirs())
        val stage2 = File(journal2, "stage"); val preserve2 = File(journal2, "preserve")
        assertTrue(stage2.mkdirs() && preserve2.mkdirs())
        val ops = f.ops
        val manifest2 = WorkspaceSyncManifest(f.destination.parentFile, "A1B2C3D4-0000-4000-8000-000000000001", ops)
        val swap2 = WorkspaceImportSwap(f.destination, stage2, preserve2, File(journal2, "swap.jsonl"), manifest2, ops)
        val staged = File(stage2, "a.txt"); staged.write("incoming")
        val digest = ops.streamDigest(staged)!!.first
        val outcome = swap2.apply(listOf(StagedEntry("a.txt", "file", 420, null, digest, 8))) { false }
        assertEquals(1, outcome.preservedUnsynced)
        assertEquals("incoming", File(f.destination, "a.txt").text())
        // The un-synced guest bytes survive acknowledge (recoverable, never
        // blindly removed).
        swap2.acknowledge(listOf(StagedEntry("a.txt", "file", 420, null, digest, 8)))
        val preserved = File(preserve2, "a.txt")
        assertTrue(preserved.exists())
        assertEquals("guest-edit", preserved.text())
    }

    @Test
    fun cancellationMidSwapRestoresPriorWorkspace() {
        val f = fixture()
        File(f.destination, "a.txt").write("prior")
        File(f.destination, "keepme.txt").write("independent")
        val ops = f.ops
        val entries = listOf(
            stagedFile(f, "a.txt", "new-a"),
            stagedFile(f, "b.txt", "new-b"),
            stagedFile(f, "c.txt", "new-c"),
        )
        // Cancel once the first two entries have visibly landed but the
        // third has not (deterministic: the engine checks before EACH entry).
        val cancel = { File(f.destination, "b.txt").exists() }
        try {
            f.swap.apply(entries) { cancel() }
        } catch (failure: WorkspaceSwapException) {
            assertEquals("swapCancelled", failure.code)
        }
        val failures = f.swap.restore()
        assertEquals(0, failures)
        assertEquals("prior", File(f.destination, "a.txt").text())
        assertFalse(File(f.destination, "b.txt").exists())
        assertFalse(File(f.destination, "c.txt").exists())
        assertEquals("independent", File(f.destination, "keepme.txt").text()) // untouched
    }

    @Test
    fun directoryVsFileCollisionKeepsBothSides() {
        val f = fixture()
        File(f.destination, "a.txt").mkdirs() // destination has a DIRECTORY where snapshot has a file
        File(File(f.destination, "a.txt"), "inner").write("inner")
        val entries = listOf(stagedFile(f, "a.txt", "incoming"))
        val outcome = f.swap.apply(entries) { false }
        assertEquals(listOf("a.txt"), outcome.conflicts)
        assertTrue(File(f.destination, "a.txt").isDirectory)  // user directory untouched
        val stashed = File(f.preserve, "stage-conflicts/a.txt")
        assertTrue(stashed.exists())                          // runtime-side copy preserved
        assertEquals("incoming", stashed.text())
    }

    @Test
    fun manifestLookupRoundTrips() {
        val f = fixture()
        val entry = stagedFile(f, "sub/a.txt", "content")
        f.manifest.commit(listOf(entry))
        val record = f.manifest.lookup("sub/a.txt")
        assertNotNull(record)
        assertEquals(entry.digest, record!!.digest)
        assertNull(f.manifest.lookup("sub/missing.txt"))
    }
}
