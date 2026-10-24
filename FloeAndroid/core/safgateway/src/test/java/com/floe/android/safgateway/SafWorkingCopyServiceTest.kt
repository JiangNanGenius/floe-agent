// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * Working-copy import/export receipts and the two-phase recoverable save:
 * conflict-before-write, native commit-permit gating, save-as fallback,
 * mid-write recovery, and post-write verification honesty.
 */
class SafWorkingCopyServiceTest {

    private class Ctx(
        val fake: FakeSafBackend,
        val tree: SafUriRef,
        val gateway: SafGrantGateway,
        val ops: SafProviderOperations,
        val work: SafWorkingCopyService,
        val staging: File,
    )

    private fun ctx(): Ctx {
        val fake = FakeSafBackend()
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        val gateway = SafGrantGateway(fake.backend)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val accept = gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or SafGrantFlagBits.PERSISTABLE,
        )
        assertTrue(accept is PickAcceptResult.Accepted)
        val limits = SafLimits(chunkBytes = 4096)
        val ops = SafProviderOperations(fake.backend, gateway, limits)
        return Ctx(fake, tree, gateway, ops, SafWorkingCopyService(fake.backend, ops, limits), FakeSafBackend.stagingDir("wc"))
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun replacementFile(c: Ctx, bytes: ByteArray): StagedLocalRef {
        val file = File(c.staging, "replacement.bin")
        file.writeBytes(bytes)
        return StagedLocalRef(file, file.name)
    }

    @Test
    fun importStagesVerifiedBytesUnderSanitizedName() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "../../evil/name.txt", content = ByteArray(9000) { (it % 97).toByte() })
        val import = c.work.importDocument(c.fake.refOf(c.tree, doc), c.staging, byteLimit = 1L shl 20, SafCancelToken())
        assertTrue(import is SafOutcome.Success)
        val receipt = (import as SafOutcome.Success).value
        val staged = receipt.staged.local.file
        assertTrue(staged.isAbsolute)
        assertFalse("no separators in staging name", staged.name.contains("/"))
        assertFalse(staged.name.contains("\\"))
        assertEquals(9000L, staged.length())
        assertEquals(sha(doc.content), staged.readBytes().let { sha(it) })
        assertEquals(sha(doc.content), receipt.fingerprint.sha256)
        // canonical containment under the caller's root
        assertEquals(c.staging.canonicalFile, staged.canonicalFile.parentFile)
    }

    @Test
    fun sameDisplayNameDifferentDocumentsGetDistinctStagingFiles() {
        val c = ctx()
        val a = c.fake.seedDoc(c.tree, "notes.txt", content = "one".toByteArray())
        val b = c.fake.seedDoc(c.tree, "notes.txt", content = "two".toByteArray())
        val ia = c.work.importDocument(c.fake.refOf(c.tree, a), c.staging, null, SafCancelToken()) as SafOutcome.Success
        val ib = c.work.importDocument(c.fake.refOf(c.tree, b), c.staging, null, SafCancelToken()) as SafOutcome.Success
        assertTrue(ia.value.staged.local.file != ib.value.staged.local.file)
        assertEquals("one", ia.value.staged.local.file.readText())
        assertEquals("two", ib.value.staged.local.file.readText())
    }

    @Test
    fun sizeBreachedImportPromotesNothing() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "huge.bin", content = ByteArray(20_000))
        val failed = c.work.importDocument(c.fake.refOf(c.tree, doc), c.staging, byteLimit = 10_000, SafCancelToken())
        assertTrue(failed is SafOutcome.Failure)
        assertTrue((failed as SafOutcome.Failure).failure is SafFailure.SizeLimitExceeded)
        assertEquals(0, c.staging.listFiles()?.size ?: 0)
    }

    @Test
    fun metadataFingerprintHasNoShaUntilBytesObtained() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "hinted.txt", content = "abc".toByteArray())
        doc.sizeRaw = 3
        doc.lastModified = 123L
        val fp = c.work.metadataFingerprint(c.fake.refOf(c.tree, doc), SafCancelToken()) as SafOutcome.Success
        assertNull(fp.value.sha256)
        assertEquals(3L, fp.value.sizeHintBytes)
        assertEquals(123L, fp.value.lastModifiedHintMillis)
    }

    @Test
    fun exportCreatesDistinctDocumentAndNeverOverwritesSameName() {
        val c = ctx()
        val original = c.fake.seedDoc(c.tree, "report.txt", content = "old".toByteArray())
        val import = c.work.importDocument(c.fake.refOf(c.tree, original), c.staging, null, SafCancelToken()) as SafOutcome.Success
        val copy = import.value.staged
        val replacement = File(c.staging, "replacement.bin").apply { writeBytes("new".toByteArray()) }
        val stagedReplacement = StagedLocalRef(replacement, replacement.name)
        // Re-stage the replacement as a StagedCopy so we carry a trusted hash.
        val exported = c.work.exportStagedCopy(
            copy.copy(local = stagedReplacement, sha256 = sha("new".toByteArray()), bytes = 3),
            c.tree,
            null,
            "report.txt",
            SafCancelToken(),
        )
        assertTrue(exported is SafOutcome.Success)
        val receipt = (exported as SafOutcome.Success).value
        assertTrue(receipt.readbackVerified)
        assertNotEqualsUri(original.uriString, receipt.created.uri.uriString)
        assertEquals("old", c.fake.docs[original.uriString]?.content?.let { String(it) })
        assertEquals("new", String(receipt.created.uri.uriString.let { c.fake.docs[it]!!.content }))
    }

    private fun assertNotEqualsUri(a: String, b: String) = assertTrue("uris must differ: $a vs $b", a != b)

    @Test
    fun prepareSavePreservesOriginalThenConflictBlocksWrite() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "current".toByteArray())
        val ref = c.fake.refOf(c.tree, doc)
        // Someone else changed the source between import and save.
        val prepared = c.work.prepareSave(ref, expectedSourceSha256 = sha("imported-long-ago".toByteArray()), c.staging, 1L shl 20, SafCancelToken())
        assertTrue(prepared is SafOutcome.Success)
        val p = (prepared as SafOutcome.Success).value
        assertEquals(PreparedState.SOURCE_CHANGED, p.state)
        assertEquals(sha("current".toByteArray()), p.observedSourceSha256)
        val recoveryFile = p.receipt.file.file
        assertTrue("current bytes preserved before any decision", recoveryFile.exists())
        assertEquals("current", recoveryFile.readText())
        val commit = c.work.commitSave(
            p, replacementFile(c, "mine".toByteArray()), sha("mine".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        )
        assertTrue(commit is SafOutcome.Success)
        val outcome = (commit as SafOutcome.Success).value
        assertTrue(outcome is SaveReceipt.Conflict)
        assertEquals(0, c.fake.writeOpens) // NO destructive write attempted
    }

    @Test
    fun destructiveOverwriteRequiresNativeCommitPermit() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val ref = c.fake.refOf(c.tree, doc)
        val originalSha = sha("orig".toByteArray())
        val prepared = c.work.prepareSave(ref, originalSha, c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val p = prepared.value
        // Missing coordinator: refused, nothing written.
        val refused = c.work.commitSave(
            p, replacementFile(c, "new".toByteArray()), sha("new".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = null, cancel = SafCancelToken(),
        ) as SafOutcome.Success
        assertTrue(refused.value is SaveReceipt.RecoverableFailure)
        assertEquals("commit-permit-coordinator-missing", (refused.value as SaveReceipt.RecoverableFailure).code)
        assertEquals(0, c.fake.writeOpens)
        // Deferred permit: still refused.
        val deferred = c.work.commitSave(
            p, replacementFile(c, "new".toByteArray()), sha("new".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Deferred("journal-write-pending")
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success
        assertTrue((deferred.value as SaveReceipt.RecoverableFailure).code.contains("deferred"))
        assertEquals(0, c.fake.writeOpens)
        assertEquals("orig", String(c.fake.docs[doc.uriString]!!.content))
        assertTrue(p.receipt.file.file.exists())
        assertEquals(originalSha, p.receipt.sha256)
    }

    @Test
    fun permittedDestructiveSaveCommitsOnlyAfterReadbackMatch() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val ref = c.fake.refOf(c.tree, doc)
        val prepared = c.work.prepareSave(ref, sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val p = prepared.value
        val committed = c.work.commitSave(
            p, replacementFile(c, "fresh".toByteArray()), sha("fresh".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success
        val receipt = committed.value
        assertTrue(receipt is SaveReceipt.Committed)
        assertEquals(SaveStrategy.WRITE_TRUNCATE_NON_ATOMIC, (receipt as SaveReceipt.Committed).strategy)
        assertTrue(receipt.readbackVerified)
        // Defect 4 honesty: a generic provider CAS is never claimed.
        assertFalse(receipt.providerCasGuaranteed)
        assertEquals("fresh", String(c.fake.docs[doc.uriString]!!.content))
        // Recovery bytes STAY on disk until the coordinator adopts them.
        assertTrue(receipt.recovery.file.file.exists())
        assertEquals("orig", receipt.recovery.file.file.readText())
        // Adopt transfers the reference; bytes must remain (never delete originals).
        val adopted = c.work.adoptRecovery(receipt.recovery.receiptId)
        assertTrue(adopted is SafOutcome.Success)
        assertTrue(receipt.recovery.file.file.exists())
        assertTrue(c.work.pendingRecoveryReceipts().isEmpty())
    }

    @Test
    fun defaultPolicySavesAsSiblingKeepingOriginalUntouched() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val ref = c.fake.refOf(c.tree, doc)
        val prepared = c.work.prepareSave(ref, sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val committed = c.work.commitSave(
            prepared.value, replacementFile(c, "fresh".toByteArray()), sha("fresh".toByteArray()),
            SavePolicy(), // defaults: non-destructive
            coordinator = null, cancel = SafCancelToken(),
        ) as SafOutcome.Success
        val outcome = committed.value
        assertTrue(outcome is SaveReceipt.SaveAsCreated)
        val created = (outcome as SaveReceipt.SaveAsCreated)
        assertTrue(created.originalUntouched)
        assertTrue(created.created.readbackVerified)
        assertEquals("orig", String(c.fake.docs[doc.uriString]!!.content))
        assertNotEqualsUri(doc.uriString, created.created.created.uri.uriString)
        assertEquals("fresh", String(created.created.created.uri.uriString.let { c.fake.docs[it]!!.content }))
    }

    @Test
    fun unsupportedOverwriteModeFallsBackToSaveAsWhenPermitted() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        c.fake.writeBlockedUris += doc.uriString // only THIS document rejects "wt"; new docs still writable
        val ref = c.fake.refOf(c.tree, doc)
        val prepared = c.work.prepareSave(ref, sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val outcome = (c.work.commitSave(
            prepared.value, replacementFile(c, "fresh".toByteArray()), sha("fresh".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false, allowSaveAsSibling = true),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertTrue(outcome is SaveReceipt.SaveAsCreated)
        assertEquals("orig", String(c.fake.docs[doc.uriString]!!.content))
    }

    @Test
    fun midWriteFailureKeepsRecoveryAndNeverClaimsSuccess() {
        val c = ctx()
        val originalBytes = ByteArray(30_000) { (it % 254).toByte() }
        val doc = c.fake.seedDoc(c.tree, "live.bin", content = originalBytes)
        c.fake.failWriteAfterBytes = 5_000
        val ref = c.fake.refOf(c.tree, doc)
        val prepared = c.work.prepareSave(ref, sha(originalBytes), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val outcome = (c.work.commitSave(
            prepared.value, replacementFile(c, ByteArray(30_000) { 1 }), sha(ByteArray(30_000) { 1 }),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertTrue(outcome is SaveReceipt.RecoverableFailure)
        val failure = outcome as SaveReceipt.RecoverableFailure
        assertTrue(failure.partialWritePossible)
        assertTrue(failure.reconciliationRequired)
        assertNotNull(failure.recoveryPreserved)
        // The recovery holds the FULL original, provider truncation notwithstanding.
        val recovery = failure.recoveryPreserved!!
        assertEquals(sha(originalBytes), recovery.sha256)
        assertArrayEqualsSha(originalBytes, recovery.file.file.readBytes())
        // Provider truncated at close — the failure is visible, not masked.
        assertTrue(c.fake.docs[doc.uriString]!!.content.size < originalBytes.size)
    }

    private fun assertArrayEqualsSha(expected: ByteArray, actual: ByteArray) =
        assertEquals(sha(expected), sha(actual))

    @Test
    fun postWriteProviderDivergenceIsMismatchNotSuccess() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        // After any write commit, the provider "settles" different bytes.
        c.fake.afterWriteCommitHook = { d -> d.content = "drifted".toByteArray() }
        val ref = c.fake.refOf(c.tree, doc)
        val prepared = c.work.prepareSave(ref, sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val outcome = (c.work.commitSave(
            prepared.value, replacementFile(c, "fresh".toByteArray()), sha("fresh".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertTrue(outcome is SaveReceipt.RecoverableFailure)
        val failure = outcome as SaveReceipt.RecoverableFailure
        assertEquals("post-write-verification-mismatch", failure.code)
        assertTrue(failure.reconciliationRequired)
        assertNotNull(failure.recoveryPreserved)
        assertEquals("orig", failure.recoveryPreserved!!.file.file.readText())
    }

    @Test
    fun copiedReceiptCannotRedirectThePreparedWriteToAnotherDocument() {
        val c = ctx()
        val original = c.fake.seedDoc(c.tree, "original.txt", content = "orig".toByteArray())
        val other = c.fake.seedDoc(c.tree, "other.txt", content = "other".toByteArray())
        val prepared = c.work.prepareSave(c.fake.refOf(c.tree, original), sha("orig".toByteArray()),
            c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val forged = prepared.value.copy(target = c.fake.refOf(c.tree, other))
        val result = c.work.commitSave(forged, replacementFile(c, "changed".toByteArray()),
            sha("changed".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt): CommitPermit {
                    throw AssertionError("foreign receipt must be refused before admission")
                }
            }, SafCancelToken())
        assertTrue(result is SafOutcome.Failure)
        assertEquals(0, c.fake.writeOpens)
        assertEquals("other", String(c.fake.docs[other.uriString]!!.content))
    }

    @Test
    fun stalePreparedHandleFromDeadProcessIsRefusedWithReconciliationPointer() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val ghost = PreparedSave(
            receipt = RecoveryReceipt("rec-ghost", StagedLocalRef(File(c.staging, "ghost"), "ghost"), "sha", 1, doc.let { SafUriRef(it.uriString) }, doc.documentIdFromUri(), 0),
            target = c.fake.refOf(c.tree, doc),
            state = PreparedState.AWAITING_COMMIT,
            expectedSourceSha256 = null,
            observedSourceSha256 = "sha",
            mimeType = "text/plain",
            displayName = "live.txt",
        )
        val refused = c.work.commitSave(
            ghost, replacementFile(c, "x".toByteArray()), sha("x".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        )
        assertTrue(refused is SafOutcome.Failure)
        assertTrue((refused as SafOutcome.Failure).detail!!.contains("reconcile"))
        assertEquals(0, c.fake.writeOpens)
    }

    @Test
    fun commitRecheckDetectsDriftAndPreservesBothSidesWithoutWriting() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val ref = c.fake.refOf(c.tree, doc)
        val prepared = c.work.prepareSave(ref, sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        // A third writer changes the source AFTER prepare, BEFORE commit's recheck.
        c.fake.mutateOnNextOpenRead[doc.uriString] = "sneaky".toByteArray()
        val outcome = (c.work.commitSave(
            prepared.value, replacementFile(c, "fresh".toByteArray()), sha("fresh".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertTrue(outcome is SaveReceipt.Conflict)
        val conflict = outcome as SaveReceipt.Conflict
        assertEquals(sha("orig".toByteArray()), conflict.expectedSha256)
        assertEquals(sha("sneaky".toByteArray()), conflict.observedSha256)
        assertEquals(0, c.fake.writeOpens) // recheck blocked the destructive write
        // prepare-time original AND drifted current bytes are both preserved.
        assertEquals("orig", conflict.recovery.file.file.readText())
        assertNotNull(conflict.driftRecovery)
        assertEquals("sneaky", conflict.driftRecovery!!.file.file.readText())
        assertEquals(sha("sneaky".toByteArray()), conflict.driftRecovery!!.sha256)
        // Drift receipt is adoptable and its bytes also survive adoption.
        val adopted = c.work.adoptRecovery(conflict.driftRecovery!!.receiptId)
        assertTrue(adopted is SafOutcome.Success)
        assertTrue(conflict.driftRecovery!!.file.file.exists())
    }

    @Test
    fun commitRecheckUnreadableBlocksWriteAndFlagsReconciliation() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val prepared = c.work.prepareSave(c.fake.refOf(c.tree, doc), sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        // Open sequence: #1 prepare preserve, #2 commit recheck.
        c.fake.throwOnOpenReadNumber = 2
        val outcome = (c.work.commitSave(
            prepared.value, replacementFile(c, "fresh".toByteArray()), sha("fresh".toByteArray()),
            SavePolicy(allowDestructiveOverwrite = true, preferSaveAsWhenReplacementNotProven = false),
            coordinator = object : SafCommitCoordinator {
                override fun requestCommitPermit(receipt: RecoveryReceipt) = CommitPermit.Permitted
            },
            cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertTrue(outcome is SaveReceipt.RecoverableFailure)
        val failure = outcome as SaveReceipt.RecoverableFailure
        assertTrue(failure.code.startsWith("recheck-"))
        assertFalse(failure.partialWritePossible)
        assertTrue(failure.reconciliationRequired)
        assertEquals(0, c.fake.writeOpens)
        assertEquals("orig", failure.recoveryPreserved!!.file.file.readText())
    }

    @Test
    fun releaseRecoveryReferenceNeverTouchesBytes() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.tree, "live.txt", content = "orig".toByteArray())
        val prepared = c.work.prepareSave(c.fake.refOf(c.tree, doc), sha("orig".toByteArray()), c.staging, 1L shl 20, SafCancelToken()) as SafOutcome.Success
        val id = prepared.value.receipt.receiptId
        assertTrue(c.work.releaseRecoveryReference(id))
        assertTrue(prepared.value.receipt.file.file.exists())
        assertEquals(0, c.work.pendingRecoveryReceipts().size)
    }
}
