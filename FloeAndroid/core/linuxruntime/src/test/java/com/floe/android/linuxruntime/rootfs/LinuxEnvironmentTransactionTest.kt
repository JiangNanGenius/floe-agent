// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.nio.file.*
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.attribute.FileTime
import java.util.Properties
import org.junit.Assert.*
import org.junit.Test

class LinuxEnvironmentTransactionTest {
    private fun fixture(test: (Path, Path, LinuxEnvironmentTransaction) -> Unit) {
        val parent = Files.createTempDirectory("floe-env-transaction-").toRealPath()
        try {
            val root = Files.createDirectory(parent.resolve("container"))
            Files.createDirectories(root.resolve("usr/bin"))
            Files.writeString(root.resolve("usr/bin/tool"), "original")
            Files.setAttribute(root.resolve("usr/bin/tool"), "unix:mode", 0x1ED)
            Files.newOutputStream(root.resolve(".floe-linux-rootfs-v1")).use { out ->
                Properties().apply { setProperty("environment", "test-env"); setProperty("base", "base-1") }.store(out, null)
            }
            test(parent, root, LinuxEnvironmentTransaction())
        } finally {
            Files.walk(parent).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } }
        }
    }
    private fun prepare(owner: LinuxEnvironmentTransaction, root: Path) = owner.prepare("test-env", root.toFile()) { false }
    private fun journal(root: Path) = root.parent.resolve(".floe-package-${root.fileName}.journal")
    private fun record(root: Path) = Properties().apply { Files.newInputStream(journal(root)).use { load(it) } }
    private fun snapshot(root: Path, handle: LinuxEnvironmentTransaction.Handle) = root.parent.resolve(".floe-package-${handle.id}.snapshot")

    @Test fun failedCommandRestoresOriginalAndRemovesOnlyItsNewFiles() = fixture { _, root, owner ->
        val handle = prepare(owner, root)
        Files.writeString(root.resolve("usr/bin/tool"), "partial package")
        Files.writeString(root.resolve("new-package"), "new")
        val receipt = owner.finish(handle, false)
        assertEquals(LinuxEnvironmentTransaction.Outcome.ROLLED_BACK, receipt.outcome)
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertFalse(Files.exists(root.resolve("new-package")))
        assertTrue(Files.exists(journal(root))) // retained until real native hand-back
        owner.release(handle)
        assertFalse(Files.exists(journal(root)))
    }
    @Test fun successfulCommandRetainsRealChangesAndCommitAckIsIdempotent() = fixture { _, root, owner ->
        val handle = prepare(owner, root)
        Files.writeString(root.resolve("usr/bin/tool"), "installed")
        val receipt = owner.finish(handle, true)
        assertEquals(receipt, owner.finish(handle, false)) // no replay or late rollback
        assertEquals(LinuxEnvironmentTransaction.Outcome.COMMITTED, receipt.outcome)
        assertEquals("installed", Files.readString(root.resolve("usr/bin/tool")))
        assertFalse(Files.exists(snapshot(root, handle)))
        owner.release(handle)
    }
    @Test fun snapshotHasIndependentBytesAndPreservesItsOwnHardLinkGraph() = fixture { _, root, owner ->
        Files.createLink(root.resolve("usr/bin/tool-link"), root.resolve("usr/bin/tool"))
        val handle = prepare(owner, root)
        val copy = snapshot(root, handle)
        assertFalse(Files.isSameFile(root.resolve("usr/bin/tool"), copy.resolve("usr/bin/tool")))
        assertTrue(Files.isSameFile(copy.resolve("usr/bin/tool"), copy.resolve("usr/bin/tool-link")))
        Files.writeString(root.resolve("usr/bin/tool"), "changed")
        owner.finish(handle, false)
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertTrue(Files.isSameFile(root.resolve("usr/bin/tool"), root.resolve("usr/bin/tool-link")))
        owner.release(handle)
    }
    @Test fun rollbackPreservesModesAndModificationTime() = fixture { _, root, owner ->
        val expected = FileTime.fromMillis(1_700_000_000_000)
        Files.setLastModifiedTime(root.resolve("usr/bin/tool"), expected)
        val handle = prepare(owner, root)
        Files.setAttribute(root.resolve("usr/bin/tool"), "unix:mode", 0x180)
        Files.writeString(root.resolve("usr/bin/tool"), "changed")
        owner.finish(handle, false)
        assertEquals(0x1ED, (Files.getAttribute(root.resolve("usr/bin/tool"), "unix:mode") as Int) and 0xFFF)
        assertEquals(expected, Files.getLastModifiedTime(root.resolve("usr/bin/tool")))
        owner.release(handle)
    }
    @Test fun symlinksRemainLiteralAndOutsideDataIsNeverCopiedOrRemoved() = fixture { parent, root, owner ->
        val outside = Files.writeString(parent.resolve("outside"), "keep")
        Files.createSymbolicLink(root.resolve("outside-link"), outside)
        val handle = prepare(owner, root)
        assertEquals(outside, Files.readSymbolicLink(snapshot(root, handle).resolve("outside-link")))
        owner.finish(handle, false)
        assertEquals(outside, Files.readSymbolicLink(root.resolve("outside-link")))
        assertEquals("keep", Files.readString(outside))
        owner.release(handle)
    }
    @Test fun cancellationBeforeSnapshotLeavesRootAndNoJournal() = fixture { _, root, owner ->
        assertThrows(InterruptedException::class.java) { owner.prepare("test-env", root.toFile()) { true } }
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertFalse(Files.exists(journal(root)))
    }
    @Test fun interruptedCopyRecoveryDiscardsOnlyTheOwnedSnapshot() = fixture { parent, root, _ ->
        val owner = LinuxEnvironmentTransaction(LinuxRootfsMaterializer(durabilityBarrier = { throw java.io.IOException("fixture barrier failure") }))
        assertThrows(java.io.IOException::class.java) { prepare(owner, root) }
        assertEquals("copying", record(root).getProperty("phase"))
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertEquals(1, LinuxEnvironmentTransaction().recover(parent.toFile()))
        assertFalse(Files.exists(journal(root)))
    }
    @Test fun preparedCrashRestoresTheSnapshotBeforeNewExecution() = fixture { parent, root, owner ->
        prepare(owner, root)
        Files.writeString(root.resolve("usr/bin/tool"), "interrupted package")
        assertEquals(1, LinuxEnvironmentTransaction().recover(parent.toFile()))
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertFalse(Files.exists(journal(root)))
    }
    @Test fun crashBetweenRollbackRenamesRecoversTheActualSavedDirectory() = fixture { parent, root, owner ->
        val handle = prepare(owner, root)
        Files.writeString(root.resolve("usr/bin/tool"), "partial")
        val value = record(root).apply { setProperty("phase", "rollback") }
        Files.newOutputStream(journal(root)).use { value.store(it, null) }
        Files.move(root, parent.resolve(".floe-package-${handle.id}.failed"), ATOMIC_MOVE)
        assertFalse(Files.exists(root, NOFOLLOW_LINKS))
        LinuxEnvironmentTransaction().recover(parent.toFile())
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertFalse(Files.exists(journal(root)))
    }
    @Test fun damagedSnapshotCannotBeReportedAsSuccessfulRollback() = fixture { _, root, owner ->
        val handle = prepare(owner, root)
        Files.writeString(root.resolve("usr/bin/tool"), "current")
        Files.writeString(snapshot(root, handle).resolve("usr/bin/tool"), "damaged recovery")
        assertThrows(IllegalArgumentException::class.java) { owner.finish(handle, false) }
        assertEquals("current", Files.readString(root.resolve("usr/bin/tool")))
        assertTrue(Files.exists(journal(root)))
        assertTrue(Files.exists(snapshot(root, handle)))
    }
    @Test fun replacedRootIsPreservedAndRecoveryIsRetained() = fixture { parent, root, owner ->
        val handle = prepare(owner, root)
        Files.move(root, parent.resolve("retained-original"), ATOMIC_MOVE)
        Files.createDirectory(root)
        Files.writeString(root.resolve("foreign"), "keep")
        assertThrows(IllegalArgumentException::class.java) { owner.finish(handle, false) }
        assertEquals("keep", Files.readString(root.resolve("foreign")))
        assertTrue(Files.exists(snapshot(root, handle)))
    }
    @Test fun oldReleaseCannotDeleteANewerTransactionsJournal() = fixture { _, root, owner ->
        val old = prepare(owner, root)
        owner.finish(old, true); owner.release(old)
        val newer = prepare(owner, root)
        assertThrows(IllegalArgumentException::class.java) { owner.release(old) }
        assertEquals(newer.id, record(root).getProperty("nonce"))
        owner.finish(newer, false); owner.release(newer)
    }
    @Test fun byteBudgetRefusesBeforeAnyCommandOrRootMutation() = fixture { _, root, _ ->
        assertThrows(IllegalArgumentException::class.java) { prepare(LinuxEnvironmentTransaction(maxBytes = 2), root) }
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertFalse(Files.exists(journal(root)))
    }
    @Test fun corruptedJournalCannotDeleteRecoveryOrClaimACommit() = fixture { parent, root, owner ->
        val handle = prepare(owner, root)
        val value = record(root).apply { setProperty("digest", "not-a-digest"); setProperty("phase", "committed") }
        Files.newOutputStream(journal(root)).use { value.store(it, null) }
        assertThrows(IllegalArgumentException::class.java) { LinuxEnvironmentTransaction().recover(parent.toFile()) }
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertTrue(Files.exists(snapshot(root, handle)))
    }
    @Test fun changedGuestIdentityCannotCommitEvenWhenCommandExitWasZero() = fixture { _, root, owner ->
        val handle = prepare(owner, root)
        val marker = root.resolve(".floe-linux-rootfs-v1")
        Files.writeString(marker, "environment=foreign\nbase=foreign\n")
        assertEquals(LinuxEnvironmentTransaction.Outcome.ROLLED_BACK, owner.finish(handle, true).outcome)
        val restored = Properties().apply { Files.newInputStream(marker).use { load(it) } }
        assertEquals("test-env", restored.getProperty("environment"))
        assertEquals("base-1", restored.getProperty("base"))
        owner.release(handle)
    }

}
