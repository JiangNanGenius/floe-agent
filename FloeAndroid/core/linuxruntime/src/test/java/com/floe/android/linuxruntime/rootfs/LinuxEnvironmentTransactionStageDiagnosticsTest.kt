// SPDX-License-Identifier: MPL-2.0
// Authored fixtures for the N02 A5 Samsung environmentTransaction start
// failure (job-46036bc8e99f4602). The device evidence (A5_ORIGINAL.jsonl
// seq#29) showed a 13.6 s transactional start failing as the fully generic
// `runtime_start_failed` with an empty sanitized logcat: every throw point at
// the tail of LinuxEnvironmentTransaction.prepare used to be a plain require
// or a raw IOException. These fixtures pin, against the real prepare path:
//   - every refusal/failure class now carries its bounded typed stage code;
//   - the verify stage reports the bounded divergence axis (never a path);
//   - the original exception stays on the cause chain (debugger-only);
//   - the durable journal/snapshot stay recoverable after a typed failure
//     and recover() settles them exactly as before;
//   - cancellation stays an honest (untyped) lifecycle refusal;
//   - the healthy snapshot/commit path is unchanged by the refactor.
// Author-written; NOT executed by this lane (primary owns builds/tests).
package com.floe.android.linuxruntime.rootfs

import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.util.Properties
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxEnvironmentTransactionStageDiagnosticsTest {
    private val marker = ".floe-linux-rootfs-v1"

    private fun fixture(test: (Path, Path, LinuxEnvironmentTransaction) -> Unit) {
        val parent = Files.createTempDirectory("floe-env-transaction-stage-").toRealPath()
        try {
            val root = Files.createDirectory(parent.resolve("container"))
            Files.createDirectories(root.resolve("usr/bin"))
            Files.writeString(root.resolve("usr/bin/tool"), "original")
            Files.setAttribute(root.resolve("usr/bin/tool"), "unix:mode", 0x1ED)
            storeMarker(root, "test-env")
            test(parent, root, LinuxEnvironmentTransaction())
        } finally {
            Files.walk(parent).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
        }
    }

    private fun storeMarker(root: Path, environment: String) {
        Files.newOutputStream(root.resolve(marker)).use { out ->
            Properties().apply { setProperty("environment", environment) }.store(out, null)
        }
    }

    private fun journal(root: Path) = root.parent.resolve(".floe-package-${root.fileName}.journal")

    @Test fun journalPresentRefusesWithTypedStageAndLeavesRootUntouched() = fixture { _, root, _ ->
        // Any durable journal names the recovery obligation; the prepare must
        // refuse with the typed stage instead of the old untyped require.
        Files.writeString(journal(root), "phase=copying\n")
        val failure = try {
            LinuxEnvironmentTransaction().prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_JOURNAL_PRESENT, failure!!.code)
        assertNull(failure.detail)
        assertTrue(Files.exists(root.resolve("usr/bin/tool"), NOFOLLOW_LINKS))
        // Removing the stale journal restores admission unchanged.
        Files.delete(journal(root))
        val handle = LinuxEnvironmentTransaction().prepare("test-env", root.toFile()) { false }
        LinuxEnvironmentTransaction().finish(handle, success = true)
        LinuxEnvironmentTransaction().release(handle)
    }

    @Test fun sourceMutationDuringCopyReportsVerifyStageWithContentAxis() = fixture { parent, root, _ ->
        // The exact A5-shaped defect: the environment changed while the
        // snapshot was being taken. The durability barrier runs inside the
        // copy tail; use it to append one byte to the live layer, then the
        // post-copy verification must fail with the typed stage and the
        // bounded "content" axis — never a path.
        val owner = LinuxEnvironmentTransaction(LinuxRootfsMaterializer(
            durabilityBarrier = {
                Files.writeString(root.resolve("usr/bin/tool"), "original+")
            }))
        val failure = try {
            owner.prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_SNAPSHOT_VERIFY_CHANGED, failure!!.code)
        assertEquals("content", failure.detail)
        // The retained journal/snapshot stay recoverable and settle to the
        // pre-transaction state (no command could have started).
        assertTrue(Files.exists(journal(root), NOFOLLOW_LINKS))
        assertEquals(1, owner.recover(parent.toFile()))
        assertTrue(!Files.exists(journal(root), NOFOLLOW_LINKS))
    }

    @Test fun copyTailIoFailureIsTypedAndKeepsOriginalCause() = fixture { parent, root, _ ->
        // Barrier/marker/attribute failures in the copy tail used to escape as
        // raw IOExceptions; they now carry the typed stage and keep the
        // original error on the cause chain (debugger inspection only).
        val original = IOException("simulated device writeback failure")
        val owner = LinuxEnvironmentTransaction(LinuxRootfsMaterializer(
            durabilityBarrier = { throw original }))
        val failure = try {
            owner.prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_SNAPSHOT_COPY_IO, failure!!.code)
        assertSame(original, failure.cause)
        // The journal was durably published before the copy: recovery settles
        // it and removes the snapshot, exactly like the legacy contract.
        assertTrue(Files.exists(journal(root), NOFOLLOW_LINKS))
        assertEquals(1, owner.recover(parent.toFile()))
        assertTrue(!Files.exists(journal(root), NOFOLLOW_LINKS))
    }

    @Test fun guestIdentityChangeDuringCopyIsTyped() = fixture { _, root, _ ->
        // A writable layer whose marker is replaced mid-snapshot must refuse
        // with the identity stage instead of the old untyped require.
        val owner = LinuxEnvironmentTransaction(LinuxRootfsMaterializer(
            durabilityBarrier = { storeMarker(root, "foreign-env") }))
        val failure = try {
            owner.prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_IDENTITY_CHANGED, failure!!.code)
        // The durable journal stays recoverable, and recovery itself refuses
        // (legacy contract, unchanged): the layer's identity is genuinely
        // foreign, so the snapshot and journal are retained for repair
        // instead of being silently discarded.
        assertTrue(Files.exists(journal(root), NOFOLLOW_LINKS))
        try {
            owner.recover(root.parent.toFile())
            throw AssertionError("recovery must refuse a foreign identity")
        } catch (expected: IllegalArgumentException) {
            // Expected: identity unknown, recovery data retained.
        }
        assertTrue(Files.exists(journal(root), NOFOLLOW_LINKS))
    }

    @Test fun unverifiableOwnedSourceAccessIsTypedAsImageIo() = fixture { _, root, _ ->
        // Production runs the snapshot copier with ownerUid = myUid(); a
        // source tree that cannot be verified against that owner used to
        // surface as a raw IOException inside image(). The typed stage now
        // names the image walk, and the original refusal stays as cause.
        val wrongUid = androidUid() + 4096
        val owner = LinuxEnvironmentTransaction(LinuxRootfsMaterializer(
            ownerUid = wrongUid, sourceMutationsAllowed = { true }))
        val failure = try {
            owner.prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_IMAGE_IO, failure!!.code)
        assertTrue(failure.cause is IOException)
    }

    @Test fun spaceProbeReceivesOnlyTheValidatedGuestRoot() = fixture { _, root, _ ->
        var observed: java.io.File? = null
        val owner = LinuxEnvironmentTransaction(availableSpace = {
            observed = it
            Long.MAX_VALUE
        })
        val handle = owner.prepare("test-env", root.toFile()) { false }
        assertEquals(root.toFile(), observed)
        owner.finish(handle, success = false)
        owner.release(handle)
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
    }

    @Test fun insufficientSpaceLeavesNoJournalOrSnapshotAndKeepsSource() = fixture { parent, root, _ ->
        val owner = LinuxEnvironmentTransaction(availableSpace = { 0L })
        val failure = try {
            owner.prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_INSUFFICIENT_SPACE, failure!!.code)
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
        assertTrue(!Files.exists(journal(root), NOFOLLOW_LINKS))
        Files.newDirectoryStream(parent, ".floe-package-*.snapshot").use {
            assertTrue(!it.iterator().hasNext())
        }
    }

    @Test fun deniedSpaceProbeIsTypedAndCannotAdmitTheTransaction() = fixture { _, root, _ ->
        val cause = SecurityException("synthetic private path")
        val owner = LinuxEnvironmentTransaction(availableSpace = { throw cause })
        val failure = try {
            owner.prepare("test-env", root.toFile()) { false }
            null
        } catch (expected: Exception) {
            expected.environmentTransactionDiagnostic() ?: throw expected
        }
        assertEquals(EnvironmentTransactionException.CODE_TRANSACTION_IMAGE_IO, failure!!.code)
        assertSame(cause, failure.cause)
        assertTrue(!failure.message.orEmpty().contains("private path"))
        assertTrue(!Files.exists(journal(root), NOFOLLOW_LINKS))
        assertEquals("original", Files.readString(root.resolve("usr/bin/tool")))
    }

    @Test fun healthySnapshotCommitPathIsUnchanged() = fixture { _, root, _ ->
        // Regression guard for the imageNodes/digest refactor: a healthy
        // snapshot must still verify byte-equal and commit.
        val owner = LinuxEnvironmentTransaction(LinuxRootfsMaterializer(
            durabilityBarrier = { }))
        val handle = owner.prepare("test-env", root.toFile()) { false }
        Files.writeString(root.resolve("usr/bin/tool"), "installed package")
        val receipt = owner.finish(handle, success = true)
        assertEquals(LinuxEnvironmentTransaction.Outcome.COMMITTED, receipt.outcome)
        owner.release(handle)
        assertEquals("installed package", Files.readString(root.resolve("usr/bin/tool")))
    }

    @Test fun cancellationDuringSnapshotStaysAnHonestLifecycleRefusal() = fixture { parent, root, _ ->
        // Cancellation is not a defect: it must keep the legacy untyped
        // InterruptedException mapping so it is never misreported as a
        // transaction stage, and it must leave no journal behind.
        var calls = 0
        val owner = LinuxEnvironmentTransaction()
        val failure = try {
            owner.prepare("test-env", root.toFile()) {
                calls += 1
                calls > 2
            }
            null
        } catch (expected: InterruptedException) {
            expected
        }
        assertTrue(failure is InterruptedException)
        assertTrue(failure !is EnvironmentTransactionException)
        assertTrue(!Files.exists(journal(root), NOFOLLOW_LINKS))
        assertEquals(0, owner.recover(parent.toFile()))
    }

    private fun androidUid(): Int = runCatching {
        // The unit tests run against an android.jar stub whose
        // Process.myUid() is not implemented; any deterministic non-negative
        // uid works for the ownership refusal below.
        android.os.Process.myUid()
    }.getOrElse { 1000 }
}
