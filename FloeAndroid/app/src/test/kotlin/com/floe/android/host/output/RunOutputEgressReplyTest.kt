// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic reply-grammar tests for the owned run-output lane: identity
 * re-derivation, canonical path enforcement, strict decode, and the typed
 * dynamic-absence mapping (LinkageError of an older Core never becomes a
 * success or a silently empty page). */
class RunOutputEgressReplyTest {

    private val conversation = "11111111-2222-3333-4444-555555555555"
    private val run = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE".lowercase()
    private val output = "a".repeat(64)

    private fun reply(json: String): RunOutputReply {
        val bytes = json.toByteArray()
        return RunOutputReply.call { buffer -> bytes.copyInto(buffer); bytes.size }
    }

    @Test
    fun listParsesOwnedItemsAndFlags() {
        val json = """{"ok":1,"schema":"floe.run-output.list.v1","conversationID":"$conversation","runID":"$run",
            "items":[{"outputID":"$output","producerCallID":"call-1","producerTool":"workspace.publishOutput",
            "slot":"document","displayName":"report.docx","mimeType":"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "byteCount":17,"availability":"available"}],
            "scanTruncated":0,"truncatedItems":0,"rejectedCount":0}"""
        val result = RunOutputReply.list(reply(json), conversation, run)
        assertTrue(result is RunOutputListResult.Ok)
        val ok = result as RunOutputListResult.Ok
        assertEquals(1, ok.items.size)
        assertEquals(output, ok.items[0].outputID)
        assertEquals(17L, ok.items[0].byteCount)
        assertEquals("available", ok.items[0].availabilityRaw)
    }

    @Test
    fun listRejectsForeignIdentityPageWhole() {
        val json = """{"ok":1,"schema":"floe.run-output.list.v1","conversationID":"$conversation","runID":"$run",
            "items":[],"scanTruncated":0,"truncatedItems":0,"rejectedCount":0}"""
        val result = RunOutputReply.list(reply(json), conversation, "9".repeat(32) + "-0000-0000-0000-000000000000")
        assertTrue(result is RunOutputListResult.Refused)
        assertEquals(RunOutputStatus.INTERNAL, (result as RunOutputListResult.Refused).status)
    }

    @Test
    fun malformedItemsAreDroppedNotTrusted() {
        val json = """{"ok":1,"schema":"floe.run-output.list.v1","conversationID":"$conversation","runID":"$run",
            "items":[{"outputID":"not-hex","producerCallID":"c","producerTool":"t","slot":"s",
            "displayName":"a.docx","mimeType":"x/y","byteCount":3,"availability":"available"},
            {"outputID":"$output","producerCallID":"c2","producerTool":"t","slot":"s",
            "displayName":"b.docx","mimeType":"x/y","byteCount":-5,"availability":"available"}],
            "scanTruncated":0,"truncatedItems":0,"rejectedCount":0}"""
        val ok = RunOutputReply.list(reply(json), conversation, run) as RunOutputListResult.Ok
        assertTrue(ok.items.isEmpty())
    }

    @Test
    fun egressInfoRequiresCanonicalRelativePathAndIdentity() {
        val canonical = """{"ok":1,"schema":"floe.run-output.egress.v1","conversationID":"$conversation",
            "runID":"$run","outputID":"$output","producerCallID":"call-1","producerTool":"t","slot":"document",
            "displayName":"report.docx","mimeType":"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "byteCount":17,"sha256":"${"b".repeat(64)}","relativePath":"RunOutputs/$run/$output/report.docx"}"""
        val good = RunOutputReply.egressInfo(reply(canonical), conversation, run, output)
        assertNotNull(good)
        val escaped = canonical.replace(
            "\"relativePath\":\"RunOutputs/$run/$output/report.docx\"",
            "\"relativePath\":\"/data/absolute/report.docx\"")
        assertNull(RunOutputReply.egressInfo(reply(escaped), conversation, run, output))
        val renamed = canonical.replace("report.docx\",", "other.docx\",")
        assertNull(RunOutputReply.egressInfo(reply(renamed), conversation, run, output))
        val foreignConv = canonical.replace(conversation, "2".repeat(8) +
            "-2222-3333-4444-555555555555")
        assertNull(RunOutputReply.egressInfo(reply(foreignConv), conversation, run, output))
        val badSha = canonical.replace("b".repeat(64), "Z".repeat(64))
        assertNull(RunOutputReply.egressInfo(reply(badSha), conversation, run, output))
    }

    @Test
    fun linkagedErrorMapsToTypedNotInstalled() {
        val refused = RunOutputReply.call { throw NoClassDefFoundError("floe_run_output_open") }
        assertEquals(RunOutputStatus.NOT_INSTALLED, refused.status)
        val channel = object : RunOutputEgressChannel {
            override fun list(epoch: Long, conversationID: String, runID: String,
                              reply: ByteArray): Int = throw UnsatisfiedLinkError("missing export")
            override fun open(epoch: Long, conversationID: String, runID: String,
                              outputID: String): Long = throw UnsatisfiedLinkError("missing export")
            override fun info(ticket: Long, reply: ByteArray) = throw UnsatisfiedLinkError()
            override fun read(ticket: Long, offset: Long, target: ByteArray) =
                throw UnsatisfiedLinkError()
            override fun close(ticket: Long) = throw UnsatisfiedLinkError()
        }
        val list = RunOutputReply.list(
            RunOutputReply.call { channel.list(1, conversation, run, it) }, conversation, run)
        assertTrue(list is RunOutputListResult.Refused)
        assertEquals(RunOutputStatus.NOT_INSTALLED, (list as RunOutputListResult.Refused).status)
    }

    @Test
    fun typedNegativeStatusPassesThroughUnchanged() {
        for (status in listOf(RunOutputStatus.NOT_OWNER, RunOutputStatus.SCAN_TRUNCATED,
                RunOutputStatus.LEASE_REFUSED, RunOutputStatus.FILE_CHANGED)) {
            val result = RunOutputReply.list(
                RunOutputReply.call { _ -> status }, conversation, run)
            assertEquals(status, (result as RunOutputListResult.Refused).status)
        }
    }
}
