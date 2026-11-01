// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.RenderTicketDescriptor
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeR2HostAuthorityTest {
    private class FakeNative(
        private val responder: (String, JsonObject) -> String,
    ) : MediaFoundationNativeTransport {
        val calls = CopyOnWriteArrayList<Pair<String, String>>()
        var rootStopStatus = 0
        var drainPending = 0

        override fun status(epoch: Long): ByteArray = responder(
            "status", Json.parseToJsonElement("{}") as JsonObject
        ).toByteArray()

        override fun verify(epoch: Long, action: String, request: ByteArray): ByteArray {
            val body = Json.parseToJsonElement(request.toString(Charsets.UTF_8))
                as JsonObject
            calls.add(action to request.toString(Charsets.UTF_8))
            return responder(action, body).toByteArray()
        }

        override fun prepare(epoch: Long, request: ByteArray): ByteArray {
            calls.add("prepare" to request.toString(Charsets.UTF_8))
            return responder("prepare",
                Json.parseToJsonElement(request.toString(Charsets.UTF_8)) as JsonObject)
                .toByteArray()
        }

        override fun rootStop(epoch: Long): Int = rootStopStatus
        override fun drainPending(epoch: Long): Int = drainPending
    }

    private val context = CreativeProjectContext(
        projectID = UUID.randomUUID().toString(),
        sessionToken = "session-7",
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext(CreativeOriginContext.STANDALONE))

    private fun leaseJson(root: String = "/accepted/p1"): String = """
        {"leaseID":"lease-1","mediaRootPath":"$root",
         "relativePath":"Workbench/Snapshots/lease-1.json",
         "sha256":"${"b".repeat(64)}","byteCount":128,
         "expiresAt":"2026-01-01T00:10:00Z"}
    """.trimIndent()

    private fun prepared(root: String = "/accepted/p1"): String = """
        {"version":6,"ok":true,
         "context":{"projectID":"${context.projectID}",
                    "sessionToken":"session-7","storage":{"kind":"appOwned"}},
         "mediaRootPath":"$root","projectRevision":1,
         "timelineDigest":"digest-1","attemptID":"attempt-1",
         "snapshot":${leaseJson(root)}}
    """.trimIndent()

    private fun authority(
        responder: (String, JsonObject) -> String,
        native: FakeNative? = null,
    ): Pair<CreativeR2HostAuthority, FakeNative> {
        val fake = native ?: FakeNative(responder)
        return CreativeR2HostAuthority(
            epochProvider = { 7L },
            acceptedRootProvider = { CreativeAcceptedRoot("/accepted", 7L) },
            native = fake,
            ioDispatcher = Dispatchers.Unconfined) to fake
    }

    @Test
    fun `epoch and base root read from the accepted root and native status`() =
        runBlocking {
            val (host, _) = authority({ action, _ ->
                if (action == "status") {
                    """{"ok":true,"epoch":7,"live":true,"baseRootPath":"/accepted"}"""
                } else error("unexpected")
            })
            assertEquals(7L, host.currentEpoch())
            assertTrue(host.isEpochLive(7L))
            assertFalse(host.isEpochLive(8L))
            assertEquals("/accepted", host.acceptedBaseRootPath())
            val status = host.nativeStatus()
            assertTrue(status.live)
            assertEquals("/accepted", status.baseRootPath)
        }

    @Test
    fun `prepare image or video binding returns the native digest and lease`() =
        runBlocking {
            val (host, fake) = authority({ action, _ ->
                if (action == "prepare") prepared() else error("unexpected")
            })
            val binding = host.prepareRenderBinding(context, 1, "attempt-1")
            assertEquals("/accepted/p1", binding.mediaRootPath)
            assertEquals(1L, binding.projectRevision)
            assertEquals("digest-1", binding.timelineDigest)
            assertEquals("lease-1", binding.snapshot.leaseID)
            assertEquals(128L, binding.snapshot.byteCount)
            assertTrue(fake.calls.single().second.contains("\"expectedRevision\":1"))
        }

    @Test
    fun `retain release resolve and decisions are plain native-proof mappings`() =
        runBlocking {
            val (host, _) = authority({ action, _ ->
                when (action) {
                    "renderBinding" -> """
                        {"ok":true,"accepted":true,"retryable":false,
                         "grant":{"epoch":7,"mediaRootPath":"/accepted/p1",
                                  "projectID":"${context.projectID}",
                                  "revision":1,"timelineDigest":"digest-1"}}
                    """.trimIndent()
                    "retainBinding" -> """
                        {"ok":true,"pinHandle":"pin-1","epoch":7,
                         "leaseID":"lease-1","mediaRootPath":"/accepted/p1",
                         "projectID":"${context.projectID}","revision":1,
                         "timelineDigest":"digest-1",
                         "expiresAt":"2026-01-01T01:00:00Z"}
                    """.trimIndent()
                    "pinLifecycle" -> """
                        {"ok":true,"pinHandle":"pin-2","epoch":7,
                         "leaseID":"lease-1","mediaRootPath":"/accepted/p1",
                         "projectID":"${context.projectID}","revision":1,
                         "timelineDigest":"digest-1","attemptID":"attempt-1",
                         "kind":"export","expiresAt":"2026-01-01T01:00:00Z"}
                    """.trimIndent()
                    "releasePin" -> """{"ok":true,"released":true}"""
                    "resolveRoot" -> """
                        {"ok":true,"epoch":7,"mediaRootPath":"/accepted/p1",
                         "projectID":"${context.projectID}","revision":1,
                         "timelineDigest":"digest-1","storage":{"kind":"appOwned"},
                         "ownerKind":"standalone","ownerID":null,
                         "ownerProof":"${"c".repeat(64)}",
                         "storageKey":"appOwned","originKey":"standalone||",
                         "writable":true}
                    """.trimIndent()
                    else -> error("unexpected $action")
                }
            })
            val binding = R2PreparedRenderBinding(
                context = context,
                mediaRootPath = "/accepted/p1",
                projectRevision = 1,
                timelineDigest = "digest-1",
                attemptID = "attempt-1",
                snapshot = com.floe.android.feature.workbench.RenderSnapshotLease(
                    leaseID = "lease-1", mediaRootPath = "/accepted/p1",
                    relativePath = "Workbench/Snapshots/lease-1.json",
                    sha256 = "b".repeat(64), byteCount = 128,
                    expiresAt = "2026-01-01T00:10:00Z"))
            val decision = host.validateRenderBinding(binding)
            assertTrue(decision.accepted)
            assertEquals("/accepted/p1", decision.grant?.mediaRootPath)

            val pin = host.retainRenderBinding(binding, "export-1")
            assertEquals("pin-1", pin.pinHandle)
            assertTrue(host.releaseRenderBindingPin(pin))

            val lifecycle = host.pinMediaLifecycle(
                context = context, kind = "export", epoch = 7L,
                mediaRootPath = "/accepted/p1", attemptID = "attempt-1",
                jobID = "job-1")
            assertEquals("pin-2", lifecycle.pinHandle)
            assertEquals("export", lifecycle.kind)
            assertEquals("attempt-1", lifecycle.attemptID)
            assertTrue(host.releaseRenderBindingPin(lifecycle.pinHandle))

            val root = host.resolveProjectMediaRoot(context)
            assertEquals("/accepted/p1", root.mediaRootPath)
            assertEquals("standalone", root.ownerKind)
            assertEquals("appOwned", root.storageKey)
            assertEquals("standalone||", root.originKey)
            assertTrue(root.writable)
        }

    @Test
    fun `ticket decision encodes the exact descriptor and token`() = runBlocking {
        val (host, fake) = authority({ action, _ ->
            if (action == "ticket") {
                """{"ok":true,"accepted":false,"error":"renderTicketNotFound",
                    "retryable":false}"""
            } else error("unexpected")
        })
        val descriptor = RenderTicketDescriptor(
            ticketID = "ticket-1", descriptorVersion = 1, kind = MediaExportKind.PREVIEW,
            projectID = context.projectID, attemptID = "attempt-1",
            mediaRootPath = "/accepted/p1", storage = CreativeStorageLayer.AppOwned,
            origin = null, projectRevision = 1, timelineDigest = "digest-1",
            leaseID = "lease-1", ownerReference = "owner", epoch = 7,
            snapshotRelativePath = "Workbench/Snapshots/lease-1.json",
            snapshotSHA256 = "b".repeat(64), snapshotByteCount = 128,
            snapshotLeaseExpiresAt = "2026-01-01T00:10:00Z",
            outputRelativePath = "Workbench/Exports/attempt-1.png",
            videoSettings = null, imageSettings = null, previewWindow = null,
            expiresAt = "2026-01-01T00:05:00Z", descriptorByteCount = 512)
        val decision = host.validateTicket(descriptor, "claim-1")
        assertFalse(decision.accepted)
        assertEquals("renderTicketNotFound", decision.code)
        val body = fake.calls.single().second
        assertTrue(body.contains("\"ticketID\":\"ticket-1\""))
        assertTrue(body.contains("\"claimToken\":\"claim-1\""))
        assertTrue(body.contains("\"snapshotSHA256\":\"${"b".repeat(64)}\""))
    }

    @Test
    fun `root stop and drain are real native status mappings`() = runBlocking {
        val (host, fake) = authority({ _, _ -> error("unexpected") })
        fake.rootStopStatus = 1
        fake.drainPending = 3
        assertFalse(host.rootStop())
        assertEquals(3, host.drainPending())
        fake.rootStopStatus = 0
        fake.drainPending = 0
        assertTrue(host.rootStop())
        assertEquals(0, host.drainPending())
    }

    @Test
    fun `transport failure maps to a typed refusal not a fake acceptance`() =
        runBlocking {
            val (host, _) = authority({ _, _ -> "not-json" })
            val decision = host.validateProbeRoot(
                context, "/accepted/p1", "Workbench/Assets/a.png")
            assertFalse(decision.accepted)
            assertEquals("rendererUnavailable", decision.code)
            assertTrue(decision.retryable)
            assertNull(decision.grant)
        }
}
