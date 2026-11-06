// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.components

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.util.concurrent.CancellationException
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class ComponentDirectoryCommitTest {
    private val repository = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
        .first { File(it, ".git").exists() }
    private val scratch = File(repository, "Local/Scratch/android-component-recovery-tests").apply { mkdirs() }
    private val root = Files.createTempDirectory(scratch.toPath(), "case-").toFile()
    private val current = File(root, "cad-v1")
    private val previous = File(root, "cad-v1.previous")
    private fun pack(file: File, text: String): File = file.apply {
        mkdirs(); File(this, "viewer.js").writeText(text); File(this, ".ready").writeText("a".repeat(64))
    }
    private fun stage() = pack(File(root, "cad-v1.install-test"), "new")
    private fun move(from: File, to: File) { Files.move(from.toPath(), to.toPath(), ATOMIC_MOVE) }
    @After fun cleanup() { root.deleteRecursively() }

    @Test fun failedPromotionRestoresOriginalBytes() {
        pack(current, "old"); val prepared = stage()
        val commit = ComponentDirectoryCommit(root, "cad-v1", move = { from, to ->
            if (from == prepared) throw IOException("injected promotion failure")
            move(from, to)
        })
        try { commit.promote(prepared); fail("promotion must fail") } catch (_: IOException) { }
        assertEquals("old", File(current, "viewer.js").readText())
        assertFalse(previous.exists()); assertTrue(prepared.exists())
    }

    @Test fun cancelledPromotionRestoresOriginalBytes() {
        pack(current, "old"); val prepared = stage()
        val commit = ComponentDirectoryCommit(root, "cad-v1", move = { from, to ->
            if (from == prepared) throw CancellationException("injected cancellation")
            move(from, to)
        })
        try { commit.promote(prepared); fail("must cancel") } catch (_: CancellationException) { }
        assertEquals("old", File(current, "viewer.js").readText())
    }

    @Test fun failedRollbackKeepsBackupForNextProcess() {
        pack(current, "old"); val prepared = stage()
        val commit = ComponentDirectoryCommit(root, "cad-v1", move = { from, to ->
            if (from == prepared || from == previous) throw IOException("injected storage refusal")
            move(from, to)
        })
        try { commit.promote(prepared); fail("must report pending restore") }
        catch (_: ComponentDirectoryCommit.RestorePending) { }
        assertFalse(current.exists()); assertEquals("old", File(previous, "viewer.js").readText())
        ComponentDirectoryCommit(root, "cad-v1").recover()
        assertEquals("old", File(current, "viewer.js").readText()); assertFalse(previous.exists())
    }

    @Test fun interruptionBeforePromotionRestoresPreviousAndClearsOnlyOwnedStage() {
        pack(previous, "old"); stage()
        val unrelated = pack(File(root, "user-documents"), "keep")
        val commit = ComponentDirectoryCommit(root, "cad-v1")
        commit.recover(); commit.discardStaleStages()
        assertEquals("old", File(current, "viewer.js").readText())
        assertFalse(File(root, "cad-v1.install-test").exists())
        assertEquals("keep", File(unrelated, "viewer.js").readText())
    }

    @Test fun interruptionAfterPromotionKeepsNewComponent() {
        pack(previous, "old"); pack(current, "new")
        ComponentDirectoryCommit(root, "cad-v1").recover()
        assertEquals("new", File(current, "viewer.js").readText()); assertFalse(previous.exists())
    }

    @Test fun invalidPromotedDirectoryDoesNotDiscardPrevious() {
        pack(previous, "old"); current.mkdir(); File(current, "partial").writeText("incomplete")
        ComponentDirectoryCommit(root, "cad-v1").recover()
        assertEquals("old", File(current, "viewer.js").readText())
        assertFalse(File(current, "partial").exists())
    }

    @Test fun backupCleanupFailureKeepsNewComponentAndRetryableOldBytes() {
        pack(current, "old"); val prepared = stage()
        val commit = ComponentDirectoryCommit(root, "cad-v1", removeTree = { throw IOException("injected cleanup failure") })
        try { commit.promote(prepared); fail("must report pending cleanup") }
        catch (_: ComponentDirectoryCommit.CleanupPending) { }
        assertEquals("new", File(current, "viewer.js").readText())
        assertEquals("old", File(previous, "viewer.js").readText())
        ComponentDirectoryCommit(root, "cad-v1").recover()
        assertFalse(previous.exists()); assertEquals("new", File(current, "viewer.js").readText())
    }

    @Test fun uninstallRemovesFallbackAndCannotResurrectIt() {
        pack(current, "new"); pack(previous, "old"); stage()
        val commit = ComponentDirectoryCommit(root, "cad-v1")
        commit.uninstall(); commit.recover()
        assertFalse(current.exists()); assertFalse(previous.exists()); assertEquals(0L, commit.storedBytes())
    }

    @Test fun symlinkBackupIsRejectedWithoutTouchingItsTarget() {
        val outside = pack(File(root, "outside"), "keep")
        Files.createSymbolicLink(previous.toPath(), outside.toPath())
        try { ComponentDirectoryCommit(root, "cad-v1").recover(); fail("link must be refused") }
        catch (_: IllegalStateException) { }
        assertEquals("keep", File(outside, "viewer.js").readText())
        Files.delete(previous.toPath())
    }

    @Test fun usageIncludesRetainedAndPartialFilesWithoutFollowingLinks() {
        pack(current, "new"); pack(previous, "old"); val partial = stage()
        val outside = pack(File(root, "documents"), "not component bytes")
        Files.createSymbolicLink(File(partial, "external").toPath(), File(outside, "viewer.js").toPath())
        val commit = ComponentDirectoryCommit(root, "cad-v1")
        assertEquals(3L * (64 + 3), commit.storedBytes())
        commit.discardStaleStages()
        assertEquals("not component bytes", File(outside, "viewer.js").readText())
    }
}
