// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.OfficeSaveOriginalHandoffPolicy
import com.floe.android.host.OfficeOriginalCommitFacts
import com.floe.android.host.OfficeOriginalCommitOutcome
import com.floe.android.host.OfficeOriginalCommitPort
import com.floe.android.host.OfficeSaveOriginalHost
import com.floe.android.host.OfficeSaveOriginalOperation
import com.floe.android.host.OfficeSaveOriginalVerification
import com.floe.android.host.OfficeSaveOriginalVerifiedCopy
import com.floe.android.host.WorkspaceSourceResult
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Per-operation regressions over the REAL manual-original-save host
 * (OFC-SAVE-REOPEN, job-4c314431dd8348d4 + receipt follow-up job-5c864499175b4df1;
 * AUTHORED NOTRUN — Main runs the composed batch). Fake ports/operation joins
 * drive the exact production decision chain: owner/epoch/session/engine-
 * generation mismatch refuses, exact byte/hash checks refuse on any mismatch,
 * an unchanged working copy answers UNCHANGED (or the correlated
 * UNCHANGED_SOURCE_* verdicts when a provider binding is attached), one
 * proven commit answers ACCEPTED and advances the durable baseline (repeat
 * saves bind the fresh expectation), a native Committed receipt naming
 * anything other than the App-verified working copy is REJECTED (invalid /
 * unknown, never a successful requested save), conflict/cancel/unknown
 * answer REJECTED with the baseline and every retained copy untouched
 * (never a silent retry), and the attached provider push runs AT MOST ONCE
 * per explicit action on the handoff lane — "ok" correlates the plain
 * positive verdict while pending / unavailable / permission / unknown /
 * conflict verdicts never look wholly saved in the module.
 */
class OfficeSaveOriginalHostTest {

    private val task = UUID.randomUUID().toString()
    private val workspace = UUID.randomUUID().toString()
    private val session = "sess-abcdef0123456789"
    private val baseline = "0".repeat(64)
    private val workingSha = "1".repeat(64)
    private val committedSha = "2".repeat(64)

    private class FakeCommitPort(
        var outcome: OfficeOriginalCommitOutcome = OfficeOriginalCommitOutcome.Unknown("unset"),
    ) : OfficeOriginalCommitPort {
        val calls = AtomicReference<List<Triple<OfficeOriginalCommitFacts, OfficeSaveOriginalVerifiedCopy, String>>>(emptyList())
        override fun commit(
            facts: OfficeOriginalCommitFacts,
            source: OfficeSaveOriginalVerifiedCopy,
            sourcePath: String,
        ): OfficeOriginalCommitOutcome {
            calls.set(calls.get() + Triple(facts, source, sourcePath))
            return outcome
        }
    }

    private class FakeOperation {
        val released = AtomicBoolean(false)
        val committed = AtomicReference<Pair<String, Long>?>(null)
        var owned = true
    }

    private fun notice(
        sha256: String = workingSha,
        bytes: Long = 128L,
    ): OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice =
        OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice(
            opId = "original-1-abc",
            sessionToken = session,
            generation = 42L,
            format = "docx",
            workingCopySha256 = sha256,
            workingCopyBytes = bytes,
        )

    private fun facts(
        fake: FakeOperation,
        baselineSha: String = baseline,
        push: (suspend () -> WorkspaceSourceResult?)? = null,
    ): OfficeSaveOriginalOperation = OfficeSaveOriginalOperation(
        baselineSha256 = baselineSha,
        baselineBytes = 64L,
        commit = OfficeOriginalCommitFacts(
            taskID = task,
            workspaceID = workspace,
            nativeEpoch = 7L,
            hostGeneration = 3L,
            logicalPath = "Documents/report.docx",
            sourceID = null,
            sourceRevision = "rev-1",
            expectedOriginalSHA256 = baselineSha,
            sourcePath = "/data/abc/working/doc.docx",
        ),
        stillOwned = { fake.owned },
        markCommitted = { sha, bytes -> fake.committed.set(sha to bytes) },
        releaseInFlight = { fake.released.set(true) },
        pushOriginal = push,
    )

    @Test
    fun ownerEpochSessionOrGenerationMismatchRefusesWithoutAnyWork() {
        val port = FakeCommitPort()
        val fake = FakeOperation()
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> null },
            verifyWorkingCopy = { _, _ -> throw AssertionError("no verification on refusal") },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(notice()) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED, answer)
        assertTrue(port.calls.get().isEmpty())
        assertNull(fake.committed.get())
        assertFalse(fake.released.get(), "no facts acquired -> nothing to release")
    }

    @Test
    fun workingCopyDigestMismatchRefusesBeforeAnyCommit() {
        val port = FakeCommitPort()
        val fake = FakeOperation()
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> facts(fake) },
            verifyWorkingCopy = { _, _ -> null },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(notice()) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED, answer)
        assertTrue(port.calls.get().isEmpty())
        assertTrue(fake.released.get(), "the in-flight fence releases on every path")
    }

    @Test
    fun unchangedWorkingCopyAnswersUnchangedAndNeverCommits() {
        val port = FakeCommitPort()
        val fake = FakeOperation()
        val unchanged = OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice(
            opId = "original-1-abc", sessionToken = session, generation = 42L,
            format = "docx", workingCopySha256 = baseline, workingCopyBytes = 64L,
        )
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> facts(fake) },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(unchanged) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED, answer)
        assertTrue(port.calls.get().isEmpty())
        assertNull(fake.committed.get())
        assertTrue(fake.released.get())
    }

    @Test
    fun unchangedAfterOwnerLossRefuses() {
        val port = FakeCommitPort()
        val fake = FakeOperation()
        fake.owned = false
        val unchanged = OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice(
            opId = "original-1-abc", sessionToken = session, generation = 42L,
            format = "docx", workingCopySha256 = baseline, workingCopyBytes = 64L,
        )
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> facts(fake) },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(unchanged) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED, answer)
        assertTrue(port.calls.get().isEmpty())
    }

    @Test
    fun provenCommitAnswersAcceptedAdvancesBaselineAndBindsCommitFacts() {
        // The native authority answers with the EXACT App-verified working
        // copy (the production contract guarantees the exact source).
        val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
        val fake = FakeOperation()
        val pushRan = AtomicBoolean(false)
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ ->
                facts(fake, push = { pushRan.set(true); WorkspaceSourceResult("ok") })
            },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(notice()) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED, answer)
        assertEquals(workingSha to 128L, fake.committed.get())
        assertTrue(fake.released.get())
        // The commit bound the VERIFIED source facts, not the controller's
        // open-time claims: expectation = baseline, source = measured bytes.
        val call = port.calls.get().single()
        assertEquals(baseline, call.first.expectedOriginalSHA256)
        assertEquals(workingSha, call.second.sha256)
        assertEquals(128L, call.second.bytes)
        assertTrue(call.third.endsWith("doc.docx"))
    }

    @Test
    fun repeatSaveBindsTheFreshBaselineNotTheOpenTimeDigest() {
        // After one proven commit the durable baseline advances; the SECOND
        // commit must expect the FIRST commit's bytes as the original. Each
        // native receipt names the exact verified copy of its own action.
        val first = OfficeOriginalCommitOutcome.Committed(workingSha, 128L)
        val second = OfficeOriginalCommitOutcome.Committed("9".repeat(64), 256L)
        val outcomes = mutableListOf(first, second)
        val port = object : OfficeOriginalCommitPort {
            val expectations = mutableListOf<String>()
            override fun commit(
                facts: OfficeOriginalCommitFacts,
                source: OfficeSaveOriginalVerifiedCopy,
                sourcePath: String,
            ): OfficeOriginalCommitOutcome {
                expectations += facts.expectedOriginalSHA256
                return outcomes.removeFirst()
            }
        }
        val fake = FakeOperation()
        var baselineNow = baseline
        fun op(): OfficeSaveOriginalOperation = OfficeSaveOriginalOperation(
            baselineSha256 = baselineNow,
            baselineBytes = 64L,
            commit = OfficeOriginalCommitFacts(
                taskID = task, workspaceID = workspace, nativeEpoch = 7L, hostGeneration = 3L,
                logicalPath = "Documents/report.docx", sourceID = null, sourceRevision = "rev-1",
                expectedOriginalSHA256 = baselineNow,
                sourcePath = "/data/abc/working/doc.docx",
            ),
            stillOwned = { true },
            markCommitted = { sha, _ -> baselineNow = sha },
            releaseInFlight = {},
            pushOriginal = null,
        )
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> op() },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        val edit1 = notice()
        val edit2 = notice(sha256 = "9".repeat(64), bytes = 256L)
        assertEquals(
            OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED,
            runBlocking { host.accept(edit1) },
        )
        assertEquals(
            OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED,
            runBlocking { host.accept(edit2) },
        )
        assertEquals(listOf(baseline, workingSha), port.expectations)
    }

    @Test
    fun sourceConflictAnswersRejectedAndRetainsEverything() {
        for (outcome in listOf(
            OfficeOriginalCommitOutcome.Conflict("originalIntactPerReadback"),
            OfficeOriginalCommitOutcome.Cancelled("nativeCancelled"),
            OfficeOriginalCommitOutcome.Unknown("originalDriftedPerReadback"),
        )) {
            val port = FakeCommitPort(outcome)
            val fake = FakeOperation()
            val pushRan = AtomicBoolean(false)
            val host = OfficeSaveOriginalHost(
                commitPort = port,
                operation = { _, _ ->
                    facts(fake, push = { pushRan.set(true); WorkspaceSourceResult("ok") })
                },
                verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
                workingCopyFile = { File(it) },
            )
            val answer = runBlocking { host.accept(notice()) }
            assertEquals("outcome=$outcome", OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED, answer)
            assertNull("baseline must never move without a proven commit", fake.committed.get())
            assertFalse("no provider push on a non-committed outcome", pushRan.get())
            assertTrue(fake.released.get())
        }
    }

    @Test
    fun committedReceiptMatchingTheVerifiedCopyAdvancesBaseline() {
        // A contract-honest native receipt names exactly the bytes the App
        // measured; only then does the durable baseline advance.
        val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
        val fake = FakeOperation()
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> facts(fake) },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(notice()) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED, answer)
        assertEquals(workingSha to 128L, fake.committed.get())
        assertTrue(fake.released.get())
    }

    @Test
    fun mismatchedCommittedReceiptIsRejectedAndNeverAdvancesBaseline() {
        // The production native contract guarantees the exact source. A
        // receipt naming ANY other digest or size proves nothing about this
        // save: invalid/unknown, never a successful requested save, and the
        // baseline/working copy/recovery stay exactly where they were.
        val mismatched = listOf(
            OfficeOriginalCommitOutcome.Committed(committedSha, 128L), // digest differs
            OfficeOriginalCommitOutcome.Committed(workingSha, 999L),   // size differs
            OfficeOriginalCommitOutcome.Committed(committedSha, 999L), // both differ
        )
        for (outcome in mismatched) {
            val port = FakeCommitPort(outcome)
            val fake = FakeOperation()
            val pushRan = AtomicBoolean(false)
            val host = OfficeSaveOriginalHost(
                commitPort = port,
                operation = { _, _ ->
                    facts(fake, push = { pushRan.set(true); WorkspaceSourceResult("ok") })
                },
                verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
                workingCopyFile = { File(it) },
            )
            val answer = runBlocking { host.accept(notice()) }
            assertEquals("outcome=$outcome", OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED, answer)
            assertNull("a mismatched receipt must never move the baseline", fake.committed.get())
            assertFalse("no provider push without a proven requested save", pushRan.get())
            assertTrue(fake.released.get())
        }
    }

    @Test
    fun commitAfterOwnerLossNeverReportsSuccessButKeepsTheProvenBaseline() {
        val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
        val fake = FakeOperation()
        var owned = true
        val op = OfficeSaveOriginalOperation(
            baselineSha256 = baseline, baselineBytes = 64L,
            commit = OfficeOriginalCommitFacts(
                taskID = task, workspaceID = workspace, nativeEpoch = 7L, hostGeneration = 3L,
                logicalPath = "Documents/report.docx", sourceID = null, sourceRevision = "rev-1",
                expectedOriginalSHA256 = baseline, sourcePath = "/data/abc/working/doc.docx",
            ),
            stillOwned = { owned },
            markCommitted = { sha, bytes -> fake.committed.set(sha to bytes) },
            releaseInFlight = { fake.released.set(true) },
            pushOriginal = null,
        )
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> op },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        // The owner retires DURING the commit (close/task switch): the
        // commit's bytes stay proven (the workspace file is the authority),
        // but the dead mount is never told "saved".
        owned = false
        val answer = runBlocking { host.accept(notice()) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED, answer)
        assertEquals(workingSha to 128L, fake.committed.get())
        assertTrue(fake.released.get())
    }

    // ------------------------------------------------------------------
    // Provider-leg correlation (receipt follow-up job-5c864499175b4df1)
    // ------------------------------------------------------------------

    @Test
    fun providerPushPendingAfterProvenCommitAnswersAcceptedSourcePending() {
        // The local commit is proven and the baseline advanced; the attached
        // provider ladder answers anything but "ok" -> the action must NOT
        // look wholly saved: ACCEPTED_SOURCE_PENDING, never ACCEPTED.
        val pendingStatuses = listOf(
            WorkspaceSourceResult("providerOffline", facts = mapOf("recoveryID" to "rec-42")),
            WorkspaceSourceResult("revoked"),
            WorkspaceSourceResult("readOnly"),
            WorkspaceSourceResult("runtimeUnavailable"),
            WorkspaceSourceResult("failed"),
            WorkspaceSourceResult("unbound"),
            null, // the lane itself was missing
        )
        for (pushResult in pendingStatuses) {
            val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
            val fake = FakeOperation()
            val pushCalls = AtomicReference(0)
            val host = OfficeSaveOriginalHost(
                commitPort = port,
                operation = { _, _ ->
                    facts(fake, push = {
                        pushCalls.set(pushCalls.get() + 1)
                        pushResult
                    })
                },
                verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
                workingCopyFile = { File(it) },
            )
            val answer = runBlocking { host.accept(notice()) }
            assertEquals("push=$pushResult", OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING, answer)
            // The LOCAL save stands and the baseline is proven.
            assertEquals(workingSha to 128L, fake.committed.get())
            // The push ran EXACTLY ONCE on the handoff lane — never a retry.
            assertEquals(1, pushCalls.get())
            assertTrue(fake.released.get())
        }
    }

    @Test
    fun providerPushConflictAfterProvenCommitAnswersAcceptedSourceConflict() {
        // A provider-side conflict (incl. drift-at-claim / changed since
        // import) after a proven local commit -> ACCEPTED_SOURCE_CONFLICT:
        // locally saved, provider needs a human reconcile.
        val conflictResults = listOf(
            WorkspaceSourceResult("conflict"),
            WorkspaceSourceResult("sourceChangedSinceImport"),
        )
        for (pushResult in conflictResults) {
            val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
            val fake = FakeOperation()
            val host = OfficeSaveOriginalHost(
                commitPort = port,
                operation = { _, _ -> facts(fake, push = { pushResult }) },
                verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
                workingCopyFile = { File(it) },
            )
            val answer = runBlocking { host.accept(notice()) }
            assertEquals("push=$pushResult", OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_CONFLICT, answer)
            assertEquals(workingSha to 128L, fake.committed.get())
            assertTrue(fake.released.get())
        }
    }

    @Test
    fun throwingPushAfterProvenCommitIsSourcePendingNotFailure() {
        // A push that throws leaves the local commit proven; the provider
        // outcome is unknown -> source-pending, everything retained.
        val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
        val fake = FakeOperation()
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ ->
                facts(fake, push = { throw IllegalStateException("lane exploded") })
            },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        val answer = runBlocking { host.accept(notice()) }
        assertEquals(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING, answer)
        assertEquals(workingSha to 128L, fake.committed.get())
        assertTrue(fake.released.get())
    }

    @Test
    fun unchangedCopyWithAttachedSourceCorrelatesTheProviderLeg() {
        // The verified working copy already equals the authoritative local
        // original; an explicit save with an attached source must still
        // correlate the provider leg ONCE — "ok" answers plain UNCHANGED,
        // anything else answers UNCHANGED_SOURCE_* and never commits.
        data class Case(val result: WorkspaceSourceResult?, val verdict: Int)
        val cases = listOf(
            Case(WorkspaceSourceResult("ok"), OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED),
            Case(null, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING),
            Case(WorkspaceSourceResult("providerOffline"), OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING),
            Case(WorkspaceSourceResult("revoked"), OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING),
            Case(WorkspaceSourceResult("conflict"), OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT),
            Case(WorkspaceSourceResult("sourceChangedSinceImport"), OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT),
        )
        for (case in cases) {
            val port = FakeCommitPort()
            val fake = FakeOperation()
            val pushCalls = AtomicReference(0)
            val unchanged = OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice(
                opId = "original-1-abc", sessionToken = session, generation = 42L,
                format = "docx", workingCopySha256 = baseline, workingCopyBytes = 64L,
            )
            val host = OfficeSaveOriginalHost(
                commitPort = port,
                operation = { _, _ ->
                    facts(fake, push = {
                        pushCalls.set(pushCalls.get() + 1)
                        case.result
                    })
                },
                verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
                workingCopyFile = { File(it) },
            )
            val answer = runBlocking { host.accept(unchanged) }
            assertEquals("result=${case.result}", case.verdict, answer)
            assertTrue("an unchanged copy never commits", port.calls.get().isEmpty())
            assertNull(fake.committed.get())
            assertEquals(1, pushCalls.get())
            assertTrue(fake.released.get())
        }
    }

    @Test
    fun noSourceBindingSkipsThePushEntirely() {
        // Documents without a provider binding answer the plain positive
        // verdicts with no push at all.
        val port = FakeCommitPort(OfficeOriginalCommitOutcome.Committed(workingSha, 128L))
        val fake = FakeOperation()
        val host = OfficeSaveOriginalHost(
            commitPort = port,
            operation = { _, _ -> facts(fake) },
            verifyWorkingCopy = { _, n -> OfficeSaveOriginalVerifiedCopy(n.workingCopySha256, n.workingCopyBytes) },
            workingCopyFile = { File(it) },
        )
        assertEquals(
            OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED,
            runBlocking { host.accept(notice()) },
        )
        assertEquals(workingSha to 128L, fake.committed.get())
        assertTrue(fake.released.get())
    }

    // ------------------------------------------------------------------
    // Working-copy verification over real temporary files
    // ------------------------------------------------------------------

    private val tempFiles = ArrayList<File>()

    @org.junit.After
    fun deleteTempArtifacts() {
        for (file in tempFiles) {
            runCatching { Files.deleteIfExists(file.toPath()) }
        }
        tempFiles.clear()
    }

    private fun workingRoot(): File {
        val root = Files.createTempDirectory("floe-save-original-verify-").toFile()
        tempFiles.add(root)
        return root
    }

    private fun writeWorkingCopy(root: File, name: String, content: ByteArray): File {
        val file = File(root, name)
        FileOutputStream(file).use { it.write(content) }
        tempFiles.add(file)
        return file
    }

    private fun digestOf(content: ByteArray): String {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        return md.digest(content).joinToString("") { "%02x".format(it) }
    }

    @Test
    fun plainWorkingCopyUnderTheRootVerifies() {
        // Positive control: a real plain file under the working root with
        // honest digest/size/format facts passes the SAME verifier.
        val root = workingRoot()
        val content = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4)
        val file = writeWorkingCopy(root, "doc.docx", content)
        val notice = notice(sha256 = digestOf(content), bytes = content.size.toLong())
        val verified = OfficeSaveOriginalVerification.verify(file, root, notice)
        assertNotNull(verified)
        assertEquals(digestOf(content), verified!!.sha256)
        assertEquals(content.size.toLong(), verified.bytes)
    }

    @Test
    fun symlinkedWorkingCopyInputIsRefusedEvenInsideTheRoot() {
        // The ACTUAL supplied input is a symlink (the file may have been
        // swapped after the controller canonicalized its path). Even with
        // perfectly matching digest/size facts and an in-root target, the
        // verifier must refuse BEFORE following the link.
        val root = workingRoot()
        val content = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 5, 6, 7, 8)
        val real = writeWorkingCopy(root, "real.docx", content)
        val link = File(root, "linked.docx")
        Files.createSymbolicLink(link.toPath(), real.toPath())
        tempFiles.add(link)
        val notice = notice(sha256 = digestOf(content), bytes = content.size.toLong())
        assertNull(
            "a symlinked working-copy input must never verify",
            OfficeSaveOriginalVerification.verify(link, root, notice),
        )
        // The plain target itself still verifies (the refusal is about the
        // link, not the bytes).
        assertNotNull(OfficeSaveOriginalVerification.verify(real, root, notice))
    }

    @Test
    fun workingCopyOutsideTheRootIsRefused() {
        val root = workingRoot()
        val outside = Files.createTempDirectory("floe-save-original-outside-").toFile()
        tempFiles.add(outside)
        val content = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 9)
        val file = File(outside, "doc.docx")
        FileOutputStream(file).use { it.write(content) }
        tempFiles.add(file)
        val notice = notice(sha256 = digestOf(content), bytes = content.size.toLong())
        assertNull(OfficeSaveOriginalVerification.verify(file, root, notice))
    }
}
