// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Scripted-channel tests for the owned run-output Office snapshot stager:
 * the immutable snapshot only commits after EXACT streamed size + digest +
 * EOF; the ticket is closed exactly once on every path (including owner
 * retirement mid-copy), and only the stager's own random directory is ever
 * removed. */
class RunOutputOfficeSnapshotStagerTest {

    private val conversation = "11111111-2222-3333-4444-555555555555"
    private val run = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private val output = "f".repeat(64)
    private val payload = ByteArray(300_000) { (it % 251).toByte() }

    private fun sha(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun infoJson(name: String = "report.docx", bytes: Long = payload.size.toLong(),
                         digest: String = sha(payload),
                         conv: String = conversation, runId: String = run,
                         outputId: String = output,
                         relative: String? = null): String {
        val rel = relative ?: "RunOutputs/$runId/$outputId/$name"
        return """{"ok":1,"schema":"floe.run-output.egress.v1","conversationID":"$conv",
            "runID":"$runId","outputID":"$outputId","producerCallID":"call-1",
            "producerTool":"workspace.publishOutput","slot":"document","displayName":"$name",
            "mimeType":"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "byteCount":$bytes,"sha256":"$digest","relativePath":"$rel"}"""
    }

    private class ScriptedChannel(
        var info: String,
        val data: ByteArray,
        var shortReadAt: Long? = null,       // reads at/after this offset return 0 early
        var extraByteAtEof: Boolean = false, // read at exact EOF answers 1 (length drift)
        var refuseOpen: Long? = null,
        var linkagedError: Boolean = false,
    ) : RunOutputEgressChannel {
        var closes = 0
        var reads = 0
        override fun list(epoch: Long, conversationID: String, runID: String,
                          reply: ByteArray) = -701
        override fun open(epoch: Long, conversationID: String, runID: String,
                          outputID: String): Long {
            if (linkagedError) throw UnsatisfiedLinkError("absent lane")
            return refuseOpen ?: 42L
        }
        override fun info(ticket: Long, reply: ByteArray): Int {
            val bytes = info.toByteArray()
            bytes.copyInto(reply)
            return bytes.size
        }
        override fun read(ticket: Long, offset: Long, target: ByteArray): Int {
            reads++
            if (shortReadAt != null && offset >= shortReadAt!!) return 0
            if (offset >= data.size) return if (extraByteAtEof) 1 else 0
            val count = minOf(target.size.toLong(), data.size - offset).toInt()
            data.copyInto(target, 0, offset.toInt(), offset.toInt() + count)
            return count
        }
        override fun close(ticket: Long): Int {
            closes++
            return 0
        }
    }

    private fun owner() = RunOutputOfficeSnapshotStager.Owner(
        conversation, run, output, nativeEpoch = 7, hostGeneration = 1)

    private fun tempRoot(): File =
        File(System.getProperty("java.io.tmpdir"), "ro-stager-${System.nanoTime()}")
            .also { it.mkdirs() }

    @Test
    fun successStagesImmutableReadOnlySnapshotAndClosesOnce() {
        val root = tempRoot()
        try {
            val channel = ScriptedChannel(infoJson(), payload)
            val stager = RunOutputOfficeSnapshotStager(root, channel)
            val snapshot = stager.stage(owner()) { true }
            assertEquals(payload.size.toLong(), snapshot.bytes)
            assertEquals(sha(payload), snapshot.sha256)
            assertEquals("report.docx", snapshot.displayName)
            assertEquals(payload.size.toLong(), snapshot.file.length())
            assertTrue(snapshot.file.readBytes().contentEquals(payload))
            assertFalse("snapshot must be read-only", snapshot.file.canWrite())
            assertEquals(1, channel.closes)
            // Lease release is EXACT-once even when the consumer later closes
            // the ticket again via close(): the stager already did it.
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun digestMismatchFailsClosedAndClosesTicket() {
        val root = tempRoot()
        try {
            val corrupted = payload.clone(); corrupted[0] = (corrupted[0] + 1).toByte()
            val channel = ScriptedChannel(infoJson(digest = sha(payload)), corrupted)
            val stager = RunOutputOfficeSnapshotStager(root, channel)
            val failure = runCatching { stager.stage(owner()) { true } }.exceptionOrNull()
            assertTrue(failure is RunOutputOfficeSnapshotStager.Failure)
            assertTrue((failure as Exception).message!!.contains("DigestMismatch", true) ||
                failure.message!!.contains("digest"))
            assertEquals(1, channel.closes)
            assertEquals("own dir cleaned", 0, root.walk().filter { it != root && it.isFile }.count())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun shortReadAndEofDriftAreRefused() {
        val root = tempRoot()
        try {
            val short = ScriptedChannel(infoJson(), payload, shortReadAt = 1000)
            val failure = runCatching {
                RunOutputOfficeSnapshotStager(root, short).stage(owner()) { true }
            }.exceptionOrNull()
            assertTrue(failure is RunOutputOfficeSnapshotStager.Failure)
            assertEquals(1, short.closes)

            val extra = ScriptedChannel(infoJson(), payload, extraByteAtEof = true)
            val failure2 = runCatching {
                RunOutputOfficeSnapshotStager(root, extra).stage(owner()) { true }
            }.exceptionOrNull()
            assertTrue(failure2 is RunOutputOfficeSnapshotStager.Failure)
            assertEquals(1, extra.closes)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun invalidInfoIdentityRefusesStage() {
        val root = tempRoot()
        try {
            // relativePath not canonical for the sealed identity.
            val wrongPath = ScriptedChannel(
                infoJson(relative = "RunOutputs/$run/$output/renamed.docx"), payload)
            assertTrue(runCatching {
                RunOutputOfficeSnapshotStager(root, wrongPath).stage(owner()) { true }
            }.exceptionOrNull() is RunOutputOfficeSnapshotStager.Failure)
            // Foreign conversation inside the reply.
            val foreign = ScriptedChannel(
                infoJson(conv = "2".repeat(8) + "-2222-3333-4444-555555555555"), payload)
            assertTrue(runCatching {
                RunOutputOfficeSnapshotStager(root, foreign).stage(owner()) { true }
            }.exceptionOrNull() is RunOutputOfficeSnapshotStager.Failure)
            assertEquals(2, wrongPath.closes + foreign.closes)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun nonOfficeFormatAndOversizedRefuseBeforeStaging() {
        val root = tempRoot()
        try {
            val txt = ScriptedChannel(infoJson(name = "notes.txt"), payload)
            val e1 = runCatching {
                RunOutputOfficeSnapshotStager(root, txt).stage(owner()) { true }
            }.exceptionOrNull()
            assertTrue((e1 as RunOutputOfficeSnapshotStager.Failure).code.contains("Format"))
            val tooBig = ScriptedChannel(infoJson(bytes = 300L * 1024 * 1024), payload)
            val e2 = runCatching {
                RunOutputOfficeSnapshotStager(root, tooBig).stage(owner()) { true }
            }.exceptionOrNull()
            assertEquals("contentTooLarge", (e2 as RunOutputOfficeSnapshotStager.Failure).code)
            assertEquals(2, txt.closes + tooBig.closes)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun ownerRetirementMidCopyReleasesTicketAndKeepsNothing() {
        val root = tempRoot()
        try {
            val channel = ScriptedChannel(infoJson(), payload)
            val stager = RunOutputOfficeSnapshotStager(root, channel)
            var ticks = 0
            val failure = runCatching {
                stager.stage(owner()) { ++ticks < 3 } // owner goes away after two checks
            }.exceptionOrNull()
            assertTrue(failure is RunOutputOfficeSnapshotStager.Failure)
            assertEquals("ownerChanged", (failure as RunOutputOfficeSnapshotStager.Failure).code)
            assertEquals(1, channel.closes)
            assertEquals(0, root.walk().filter { it != root }.count())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun refusalAndLinkageErrorsAreTypedNotStaged() {
        val root = tempRoot()
        try {
            val refused = ScriptedChannel(infoJson(), payload, refuseOpen = -705)
            val e = runCatching {
                RunOutputOfficeSnapshotStager(root, refused).stage(owner()) { true }
            }.exceptionOrNull()
            assertTrue((e as RunOutputOfficeSnapshotStager.Failure).code.startsWith("sourceRefused"))
            assertEquals(0, refused.closes) // never opened, never closed
            val absent = ScriptedChannel(infoJson(), payload, linkagedError = true)
            val e2 = runCatching {
                RunOutputOfficeSnapshotStager(root, absent).stage(owner()) { true }
            }.exceptionOrNull()
            assertEquals("sourceUnavailable", (e2 as RunOutputOfficeSnapshotStager.Failure).code)
        } finally {
            root.deleteRecursively()
        }
    }
}
