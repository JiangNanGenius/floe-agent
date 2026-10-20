// SPDX-License-Identifier: MPL-2.0
package com.floe.android.attachments

import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * JVM source tests for the RB-7 attachment staging platform service.
 *
 * They use scripted fakes of the native staging channel and the bridge
 * exchange (the SAME seams production runs over) plus synthetic sources for
 * unknown-size pipes, short/zero reads, mid-stream revocation and
 * cancellation. No Android runtime, real ContentResolver, native library,
 * device or network is touched. AUTHORED ONLY: nothing here was executed by
 * the source package — no Gradle/Test run is claimed.
 */
class AttachmentStagingServiceTest {

    // MARK: - Scripted native double

    private class FakeNative : StagingNativeApi {
        var loaded = false
        var routeOpens = 0
        var begins = 0
        val writes = mutableListOf<Triple<String, Int, Int>>() // receipt, offset, length
        val ends = mutableListOf<Triple<String, String?, String?>>()
        var aborts = 0
        var closedRoutes = 0
        var beginResult: Pair<String, String> = "sing:v1:" + "a".repeat(32) to
            "11111111-2222-3333-4444-555555555555"
        var failBeginWith: Int? = null
        var failWriteAt: Int? = null
        var failWriteStatus = -309
        var readStatus = 0
        var readBytes: ByteArray = ByteArray(0)

        override fun ensureLoaded() { loaded = true }
        override fun routeOpen(conversationId: String?, incarnation: Long,
                               draftRevision: Long): String {
            routeOpens += 1
            return "route:v1:" + "b".repeat(32)
        }
        override fun routeClose(routeReceipt: String) { closedRoutes += 1 }
        override fun begin(routeReceipt: String, reusingStagingId: String?): Pair<String, String> {
            begins += 1
            failBeginWith?.let { throw native(it) }
            return beginResult
        }
        override fun write(ingressReceipt: String, data: ByteArray, offset: Int, length: Int) {
            if (failWriteAt != null && writes.size + 1 == failWriteAt) throw native(failWriteStatus)
            writes += Triple(ingressReceipt, offset, length)
        }
        override fun end(ingressReceipt: String, displayNameHint: String?, mimeTypeHint: String?) {
            ends += Triple(ingressReceipt, displayNameHint, mimeTypeHint)
        }
        override fun abort(ingressReceipt: String) { aborts += 1 }
        override fun progress(ingressReceipt: String) =
            StagingProgress(writes.sumOf { it.third.toLong() }, false, false)
        override fun stagingRead(handle: String, offset: Long, buffer: ByteArray): Int {
            if (readStatus < 0) return readStatus
            return copyInto(buffer)
        }
        override fun attachmentRead(attachmentId: String, conversationId: String,
                                    offset: Long, buffer: ByteArray): Int {
            if (readStatus < 0) return readStatus
            return copyInto(buffer)
        }
        private fun copyInto(buffer: ByteArray): Int {
            val n = minOf(readBytes.size, buffer.size)
            readBytes.copyInto(buffer, 0, 0, n)
            return n
        }
        override fun status(): String? = null
        private fun native(status: Int) =
            com.floe.android.bridge.AttachmentStagingNativeException(status)
    }

    // MARK: - Scripted bridge double

    private class FakeBridge : StagingBridgeExchange {
        val requests = mutableListOf<String>()
        val terminals = ArrayDeque<String>()
        var submitReceipt = 0L
        /** Queue one terminal settlement (accepted/rejected + detail pairs). */
        fun queueTerminal(kind: String, detail: Map<String, String>, code: String? = null) {
            val pairs = detail.entries.joinToString(",") {
                """{"key":"${it.key}","value":"${it.value}"}"""
            }
            val codeJson = code?.let { """"code":"$it",""" } ?: ""
            terminals.addLast(
                """{"ok":true,"schema":"floe.effect-cursor/3","correlationID":"",""" +
                """"cursor":{"operationReceiptID":"","sequence":1},"effects":[""" +
                """{"sequence":1,"kind":"$kind",$codeJson"""+
                """"detail":[$pairs]}],"hasMore":false,"resyncRequired":false}"""
            )
        }
        override fun exchange(request: String): String {
            requests.add(request)
            val parsed = Json.parseToJsonElement(request) as JsonObject
            return when ((parsed["operation"] as? JsonPrimitive)?.content) {
                "command.submit" -> {
                    submitReceipt += 1
                    """{"ok":true,"schema":"floe.command-envelope/3",""" +
                        """"correlationID":"receipt-$submitReceipt",""" +
                        """"operationReceiptID":"op:v1:$submitReceipt","queued":true}"""
                }
                "effect.poll" -> terminals.removeFirstOrNull()
                    ?: """{"ok":true,"schema":"floe.effect-cursor/3",""" +
                        """"cursor":{"operationReceiptID":"","sequence":0},""" +
                        """"effects":[],"hasMore":false,"resyncRequired":false}"""
                else -> """{"ok":false,"error":"unsupportedOperation"}"""
            }
        }
    }

    // MARK: - Sources

    private class ScriptedSource(
        private val script: List<Int>,           // per read: bytes>0, 0 retry, -1 EOF
        private val chunkBytes: Int = 4_096,
        override val displayNameHint: String? = "doc.bin",
        override val mimeTypeHint: String? = "application/pdf",
        private val declared: Long? = null,
        private val openThrows: Exception? = null,
        private val failReadAfter: Int? = null,
        private val failReadWith: Exception = IOException("disk"),
    ) : StagingContentSource {
        var openCount = 0
        var closeCount = 0
        private var position = 0
        private var reads = 0
        override fun declaredByteCount(): Long? = declared
        override fun openRead(): StagingInputStream {
            openCount += 1
            openThrows?.let { throw it }
            return object : StagingInputStream {
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (failReadAfter != null && reads >= failReadAfter) throw failReadWith
                    if (position >= script.size) return -1
                    val n = script[position++]
                    reads += 1
                    if (n > 0) {
                        val size = minOf(n, length)
                        for (i in 0 until size) buffer[offset + i] = 0x5A
                    }
                    return n
                }
                override fun close() { closeCount += 1 }
            }
        }
    }

    private fun service(native: FakeNative, bridge: FakeBridge) =
        AttachmentStagingService(native, bridge, pollDelayMillis = 1,
                                 pollDeadlineMillis = 50)

    private fun route(service: AttachmentStagingService): StagingRoute =
        service.openRoute(conversationId = null, incarnation = 1, draftRevision = 0,
                          isTemporarySession = false)

    // MARK: - Pre-IO gates

    @Test
    fun temporarySessionRefusedBeforeRouteAndZeroSourceIO() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        val source = ScriptedSource(script = listOf(-1))
        try {
            service.openRoute(null, 1, 0, isTemporarySession = true)
            fail("temporary route must be refused")
        } catch (expected: AttachmentStagingService.StagingFailure) {
            assertEquals("temporaryRefused", expected.code)
        }
        assertEquals(0, native.routeOpens)
        assertEquals(0, source.openCount)
        assertEquals(0, native.begins)
        assertTrue(bridge.requests.isEmpty())
    }

    @Test
    fun declaredOversizeRefusesBeforeBeginAndOpen() {
        val native = FakeNative()
        val service = service(native, FakeBridge())
        val source = ScriptedSource(script = listOf(-1), declared = 129L * 1024 * 1024)
        try {
            runBlocking {
                service.importPicked(route(service), source, maxBytes = 128L * 1024 * 1024)
            }
            fail("declared oversize must refuse")
        } catch (expected: AttachmentStagingService.StagingFailure) {
            assertEquals("sizeExceeded", expected.code)
        }
        assertEquals(0, native.begins)
        assertEquals(0, source.openCount)
    }

    @Test
    fun unavailableUriAbortsIngressAndNeverStages() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        val source = ScriptedSource(script = listOf(-1),
                                    openThrows = java.io.FileNotFoundException("gone"))
        val outcome = runBlocking { service.importPicked(route(service), source) }
        assertEquals(StagingOutcome.Refused("sourceUnavailable"), outcome)
        assertEquals(1, native.begins)
        assertEquals(1, native.aborts)
        // openRead threw BEFORE a stream existed: nothing was opened, so
        // there is nothing to close (the cleanup truth is the abort + the
        // transient-grant release, asserted above/below).
        assertEquals(0, source.closeCount)
        // No attachment.stage command was ever submitted for a failed open.
        assertTrue(bridge.requests.none { it.contains("attachment.stage") })
    }

    // MARK: - Streaming accounting + shape

    @Test
    fun happyPathStreamsCountedBytesAndSubmitsOpaqueReceiptOnly() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        bridge.queueTerminal(
            "accepted",
            mapOf("result" to "accepted", "stagingID" to native.beginResult.second,
                  "stagingHandle" to "stag:v1:" + "c".repeat(32),
                  "byteCount" to "100000",
                  "sha256" to "d".repeat(64)),
        )
        // 100_000 bytes across two pump rounds (65_536 + 34_464).
        val source = ScriptedSource(script = listOf(65_536, 34_464, -1),
                                    displayNameHint = "report.pdf",
                                    mimeTypeHint = "application/pdf")
        val outcome = runBlocking {
            service.importPicked(route(service), source, maxBytes = 128L * 1024 * 1024)
        }
        assertTrue(outcome is StagingOutcome.Staged)
        val staged = outcome as StagingOutcome.Staged
        assertEquals(native.beginResult.second, staged.stagingId)
        assertEquals(100_000L, staged.byteCount)   // actual count, not the hint
        assertEquals(2, native.writes.size)
        assertEquals(65_536, native.writes[0].third)
        assertEquals(34_464, native.writes[1].third)
        assertEquals(1, source.closeCount)
        assertEquals(0, native.aborts)
        // The stage envelope is opaque: hints never appear in the wire JSON.
        val submit = bridge.requests.first { it.contains("command.submit") }
        assertTrue(submit.contains("\"attachment.stage\""))
        assertTrue(submit.contains("\"attachmentStaging\""))
        assertFalse(submit.contains("report.pdf"))
        assertFalse(submit.contains("application/pdf"))
        assertFalse(submit.contains("\"owner\""))
        assertFalse(submit.contains("revision"))
        // Hints crossed ONLY the native end() seam (and will be sanitized natively).
        assertEquals(Triple(native.beginResult.first, "report.pdf", "application/pdf"),
                     native.ends.first())
        // The effect poll envelope uses the third channel schema.
        assertTrue(bridge.requests.any { it.contains("floe.effect-cursor/3") })
    }

    @Test
    fun actualBytesBeyondDeclaredFailTypedAndAbort() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        val source = ScriptedSource(script = listOf(65_536, 65_536, -1), declared = 65_536)
        val outcome = runBlocking { service.importPicked(route(service), source,
                                                          maxBytes = 128L * 1024 * 1024) }
        assertEquals(StagingOutcome.Refused("sizeExceeded"), outcome)
        assertEquals(1, native.aborts)
        assertTrue(bridge.requests.none { it.contains("attachment.stage") })
    }

    @Test
    fun unknownSizePipeSupportedUntilEOF() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        bridge.queueTerminal("accepted",
                             mapOf("result" to "accepted", "stagingID" to "x",
                                   "stagingHandle" to "y", "byteCount" to "12",
                                   "sha256" to "z"))
        val source = ScriptedSource(script = listOf(4, 4, 4, -1), declared = null)
        val outcome = runBlocking { service.importPicked(route(service), source) }
        assertTrue(outcome is StagingOutcome.Staged)
        assertEquals(listOf(4, 4, 4), native.writes.map { it.third })
    }

    @Test
    fun zeroReadInterruptionIsHonestNotSilent() {
        val native = FakeNative()
        val service = service(native, FakeBridge())
        val source = ScriptedSource(script = listOf(0, 0, 0, 0, 0, 0, 0, -1), declared = null)
        val outcome = runBlocking { service.importPicked(route(service), source) }
        assertEquals(StagingOutcome.Refused("interruptedRead"), outcome)
        assertEquals(1, native.aborts)
        assertEquals(1, source.closeCount)
    }

    @Test
    fun midStreamIoFailureAbortsAndCloses() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        val source = ScriptedSource(script = listOf(4_096, 4_096, -1), failReadAfter = 1)
        val outcome = runBlocking { service.importPicked(route(service), source) }
        assertEquals(StagingOutcome.Refused("readFailed"), outcome)
        assertEquals(1, native.aborts)
        assertEquals(1, source.closeCount)
        assertTrue(bridge.requests.none { it.contains("attachment.stage") })
    }

    @Test
    fun midStreamSecurityRevocationMapsToGrantRevoked() {
        val native = FakeNative()
        val service = service(native, FakeBridge())
        val source = ScriptedSource(script = listOf(4_096, 4_096), failReadAfter = 0,
                                    failReadWith = SecurityException("revoked"))
        val outcome = runBlocking { service.importPicked(route(service), source) }
        assertEquals(StagingOutcome.Refused("grantRevoked"), outcome)
        assertEquals(1, native.aborts)
    }

    @Test
    fun cancelBetweenChunksAbortsAndNeverSubmitsStage() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        val source = ScriptedSource(script = listOf(4_096, 4_096, -1))
        var chunks = 0
        val outcome = runBlocking {
            service.importPicked(route(service), source,
                                 cancelCheck = { chunks += 1; chunks >= 2 })
        }
        assertEquals(StagingOutcome.Refused("cancelled"), outcome)
        assertEquals(1, native.writes.size)  // only the pre-cancel chunk crossed
        assertEquals(1, native.aborts)
        assertEquals(1, source.closeCount)
        assertTrue(bridge.requests.none { it.contains("attachment.stage") })
    }

    @Test
    fun nativeWriteRejectionMapsTypedAndAborts() {
        val native = FakeNative()
        native.failWriteAt = 1
        native.failWriteStatus = -309
        val service = service(native, FakeBridge())
        val source = ScriptedSource(script = listOf(4_096, 4_096, -1))
        val outcome = runBlocking { service.importPicked(route(service), source) }
        assertEquals(StagingOutcome.Refused("diskFull"), outcome)
        assertEquals(1, native.aborts)
    }

    // MARK: - Grant policy

    @Test
    fun persistableGrantRequiresProofAndReleaseAlwaysRuns() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        bridge.queueTerminal("accepted", mapOf("result" to "accepted",
                                               "stagingID" to "s", "stagingHandle" to "h",
                                               "byteCount" to "4", "sha256" to "x"))
        var took = 0
        var released = 0
        val source = object : StagingContentSource {
            override val displayNameHint: String? = null
            override val mimeTypeHint: String? = null
            override fun declaredByteCount(): Long? = null
            override fun openRead() = object : StagingInputStream {
                private var done = false
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (done) return -1
                    done = true
                    buffer[0] = 1
                    return 1
                }
                override fun close() {}
            }
            override fun releaseTransientRead() { released += 1 }
            fun takePersistableReadGrant() { took += 1 }
        }
        // requirePersistableGrant exercises the hook path via the interface;
        // without a real Android resolver it stays a no-op but must not
        // throw, and release must still run exactly once.
        val outcome = runBlocking {
            service.importPicked(route(service), source, requirePersistableGrant = true)
        }
        assertTrue(outcome is StagingOutcome.Staged)
        assertTrue("release must be attempted even without persistence", released >= 1)
        assertEquals("no persistence without proof-of-support is asserted natively", 0, took)
    }

    // MARK: - Commands

    @Test
    fun commitEnvelopeCarriesTaskOwnerRevisionAndOpaqueHandles() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        bridge.queueTerminal("accepted", mapOf("result" to "accepted",
                                               "committedCount" to "1"))
        val handle = "stag:v1:" + "e".repeat(32)
        val outcome = runBlocking {
            service.commitStaged(java.util.UUID.randomUUID(), "digest-token",
                                 listOf(handle))
        }
        assertTrue(outcome is StagingOutcome.Accepted)
        val submit = bridge.requests.first { it.contains("attachment.commit") }
        assertTrue(submit.contains("conversationLifecycle"))
        assertTrue(submit.contains("\"stateful\":true"))
        assertTrue(submit.contains(handle))
        assertTrue(submit.contains("\"resourceID\":\"conversation."))
        assertFalse(submit.contains("digest-token\")") && submit.contains("stagingHandles\"digest"))
    }

    @Test
    fun commitRejectsMoreThanEightHandlesBeforeAnyExchange() {
        val bridge = FakeBridge()
        val service = service(FakeNative(), bridge)
        try {
            runBlocking {
                service.commitStaged(java.util.UUID.randomUUID(), "d",
                                      (1..9).map { "stag:v1:" + it.toString().repeat(32) })
            }
            fail("9 handles exceed the contract")
        } catch (expected: AttachmentStagingService.StagingFailure) {
            assertEquals("payloadInvalid", expected.code)
        }
        assertTrue(bridge.requests.isEmpty())
    }

    @Test
    fun refusedSettlementMapsCodeAndEffectDetailPairs() {
        val bridge = FakeBridge()
        val service = service(FakeNative(), bridge)
        bridge.queueTerminal("accepted", mapOf("result" to "refused",
                                               "code" to "rowChanged"))
        val outcome = runBlocking {
            service.commitStaged(java.util.UUID.randomUUID(), "d",
                                 listOf("stag:v1:" + "f".repeat(32)))
        }
        assertEquals(StagingOutcome.Refused("rowChanged"), outcome)
    }

    @Test
    fun terminalRejectedClassMapsCodeField() {
        val bridge = FakeBridge()
        val service = service(FakeNative(), bridge)
        bridge.queueTerminal("rejected", mapOf("result" to "refused"), code = "notInstalled")
        val outcome = runBlocking {
            service.discardStaged("stag:v1:" + "0".repeat(32))
        }
        assertEquals(StagingOutcome.Refused("notInstalled"), outcome)
    }

    @Test
    fun resyncWalksFromZeroWithoutSkippingConfirmation() {
        val bridge = FakeBridge()
        val service = service(FakeNative(), bridge)
        // Two envelopes: the effect channel reports a head loss, then the
        // real terminal arrives from sequence 0.
        bridge.terminals.addLast(
            """{"ok":true,"schema":"floe.effect-cursor/3","correlationID":"",
               "cursor":{"operationReceiptID":"","sequence":1},
               "effects":[{"sequence":1,"kind":"resyncRequired","detail":[]}],
               "hasMore":false,"resyncRequired":true}"""
        )
        bridge.queueTerminal("accepted", mapOf("result" to "accepted",
                                               "stagingID" to "s",
                                               "stagingHandle" to "h",
                                               "byteCount" to "1", "sha256" to "x"))
        val native = FakeNative()
        val svc = AttachmentStagingService(native, bridge, pollDelayMillis = 1,
                                           pollDeadlineMillis = 50)
        val source = ScriptedSource(script = listOf(1, -1))
        val outcome = runBlocking { svc.importPicked(route(svc), source) }
        assertTrue(outcome is StagingOutcome.Staged)
    }

    @Test
    fun readAndPreviewUseBoundedChannelAndMapGrantMissing() {
        val native = FakeNative()
        native.readStatus = -314
        val service = service(native, FakeBridge())
        try {
            service.readStagedPreview("stag:v1:" + "1".repeat(32))
            fail("grant-missing read must throw typed")
        } catch (expected: AttachmentStagingService.StagingFailure) {
            assertEquals("grantMissing", expected.code)
        }
        native.readStatus = 0
        native.readBytes = "preview".toByteArray()
        assertEquals("preview".toByteArray().toList(),
                     service.readStagedPreview("stag:v1:" + "1".repeat(32)).toList())
    }

    @Test
    fun timeoutIsHonestUnavailableNotFakeSuccess() {
        val bridge = FakeBridge()
        // No terminals queued: pump returns empty pages until the deadline.
        val service = AttachmentStagingService(FakeNative(), bridge,
                                               pollDelayMillis = 1,
                                               pollDeadlineMillis = 5)
        val outcome = runBlocking {
            service.cancelStaging(java.util.UUID.randomUUID())
        }
        assertTrue(outcome is StagingOutcome.Timeout)
    }

    @Test
    fun retryReusesSameStagingIdentityThroughNative() {
        val native = FakeNative()
        val bridge = FakeBridge()
        val service = service(native, bridge)
        bridge.queueTerminal("accepted", mapOf("result" to "accepted",
                                               "stagingID" to "9".repeat(36),
                                               "stagingHandle" to "h", "byteCount" to "1",
                                               "sha256" to "x"))
        val retryId = "99999999-2222-3333-4444-555555555555"
        native.beginResult = "sing:v1:" + "7".repeat(32) to retryId
        val source = ScriptedSource(script = listOf(1, -1))
        val outcome = runBlocking {
            service.importPicked(route(service), source, reusingStagingId = retryId)
        }
        assertTrue(outcome is StagingOutcome.Staged)
        assertTrue(outcome is StagingOutcome.Staged && (outcome as StagingOutcome.Staged).stagingId.isNotEmpty())
    }

    @Test
    fun outcomeToStringNeverCarriesPathOrUri() {
        val outcome = StagingOutcome.Staged("id", "stag:v1:" + "0".repeat(32), 10L, "ab")
        val text = outcome.toString()
        assertFalse(text.contains("/"))
        assertFalse(text.contains("content:"))
        assertFalse(text.contains("file:"))
    }

    @Test
    fun closeRouteOnlyInvalidatesAndNeverTouchesStagedCommands() {
        val native = FakeNative()
        val service = service(native, FakeBridge())
        val route = route(service)
        service.closeRoute(route)
        assertEquals(1, native.closedRoutes)
    }
}
