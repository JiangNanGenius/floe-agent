// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

/** Production swap policy over real host hard links; Android FD/backend behavior
 * remains a device check. No Android runtime, permission or export is faked. */
class LiveInputImportTest {
    private class LiveOps(private val base: JvmSwapOps = JvmSwapOps()) : WorkspaceSwapOps by base {
        var beforeCreate: ((File) -> Unit)? = null
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
            beforeCreate?.invoke(target)
            target.parentFile.mkdirs()
            Files.createLink(target.toPath(), stage.toPath())
            true
        } catch (_: Exception) { false }
        override fun createNewDirectory(root: File, relativePath: String): Boolean = try {
            Files.createDirectory(File(root, relativePath).toPath()); true
        } catch (_: Exception) { false }
    }
    private fun entry(stage: File, path: String, value: String): StagedEntry {
        File(stage, path).apply { parentFile.mkdirs(); writeText(value) }
        val bytes = value.toByteArray()
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        return StagedEntry(path, "file", 0x180, null, sha, bytes.size.toLong())
    }
    private fun fixture(block: (File, File, WorkspaceImportSwap, LiveOps) -> Unit) {
        val root = Files.createTempDirectory("floe-live-input-").toFile()
        try {
            val destination = File(root, "guest").apply { mkdirs() }
            val stage = File(root, "stage").apply { mkdirs() }
            val preserve = File(root, "preserve").apply { mkdirs() }
            val ops = LiveOps()
            val swap = WorkspaceImportSwap(destination, stage, preserve, File(root, "journal.jsonl"), null, ops)
            block(destination, stage, swap, ops)
        } finally { root.deleteRecursively() }
    }
    @Test fun addsNewInputWithoutReplacingGuestEdit() = fixture { guest, stage, swap, _ ->
        File(guest, "existing.txt").writeText("guest edit")
        val result = swap.applyMissingOnly(listOf(entry(stage, "existing.txt", "older host"),
            entry(stage, "new.pdf", "new input"))) { false }
        assertEquals("guest edit", File(guest, "existing.txt").readText())
        assertEquals("new input", File(guest, "new.pdf").readText())
        assertEquals(1, result.created)
        assertEquals(1, result.retainedExisting)
        assertEquals(0, result.replacedSynced)
        assertEquals(0, result.preservedUnsynced)
    }
    @Test fun concurrentGuestCreationWinsWithoutReplacement() = fixture { guest, stage, swap, ops ->
        ops.beforeCreate = { it.writeText("concurrent guest") }
        val result = swap.applyMissingOnly(listOf(entry(stage, "input.txt", "host"))) { false }
        assertEquals("concurrent guest", File(guest, "input.txt").readText())
        assertEquals(0, result.created)
        assertEquals(1, result.retainedExisting)
    }
    @Test fun onlyActualNewCreationsGainOwnerBaselineProvenance() = fixture { guest, stage, swap, _ ->
        File(guest, "existing.txt").writeText("guest edit")
        val adopted = mutableListOf<String>()
        swap.applyMissingOnly(listOf(entry(stage, "existing.txt", "host"), entry(stage, "new.txt", "input")),
            onCreated = { adopted.add(it.path); assertEquals("input", File(guest, it.path).readText()) }) { false }
        assertEquals(listOf("new.txt"), adopted)
        assertEquals("guest edit", File(guest, "existing.txt").readText())
    }
    @Test fun failedOwnerAdoptionRetainsCommittedInputAndStopsLaterEntries() = fixture { guest, stage, swap, _ ->
        try {
            swap.applyMissingOnly(listOf(entry(stage, "a.txt", "input"), entry(stage, "b.txt", "later")),
                onCreated = { throw WorkspaceBridgeException("inputBaselineAdoptionFailed") }) { false }
            fail("the terminal cannot start on uncertain owner provenance")
        } catch (_: WorkspaceBridgeException) { }
        assertEquals("input", File(guest, "a.txt").readText())
        assertFalse(File(guest, "b.txt").exists())
    }
    @Test fun cancellationRetainsCommittedInputAndSubsequentGuestEdit() = fixture { guest, stage, swap, _ ->
        val entries = listOf(entry(stage, "a.txt", "input"), entry(stage, "b.txt", "other"))
        var checks = 0
        try {
            swap.applyMissingOnly(entries) {
                if (++checks == 2) { File(guest, "a.txt").writeText("guest changed it"); true } else false
            }
            fail("cancellation must be reported")
        } catch (_: WorkspaceSwapException) { }
        assertEquals("guest changed it", File(guest, "a.txt").readText())
        assertFalse(File(guest, "b.txt").exists())
    }
    @Test fun symlinkParentIsRefused() = fixture { guest, stage, swap, _ ->
        val outside = Files.createTempDirectory("floe-outside-").toFile()
        try {
            Files.createSymbolicLink(File(guest, "escape").toPath(), outside.toPath())
            val result = swap.applyMissingOnly(listOf(entry(stage, "escape/input.txt", "host"))) { false }
            assertEquals(listOf("escape/input.txt"), result.conflicts)
            assertFalse(File(outside, "input.txt").exists())
        } finally { outside.deleteRecursively() }
    }
}
