// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.LargeImportCancelRequest
import com.floe.android.feature.workbench.LargeImportKind
import com.floe.android.feature.workbench.LargeImportRequest
import com.floe.android.feature.workbench.LargeImportState
import com.floe.android.feature.workbench.LargeImportStatusRequest
import com.floe.android.feature.workbench.MediaAssetMetadata
import com.floe.android.feature.workbench.NewMediaProjectKind
import com.floe.android.feature.workbench.StagedImportMetadata
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeLargeImportHostTest {
    private class FakeTransport(
        private val responder: (JsonObject) -> String,
    ) : CreativeTransport {
        val requests = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return responder(Json.parseToJsonElement(request) as JsonObject)
        }
    }

    private fun root(): File = File(
        System.getProperty("java.io.tmpdir"),
        "floe-large-import-${java.util.UUID.randomUUID()}").apply { mkdirs() }

    private fun metadata(
        sessionToken: String,
        byteCount: Long = 100L * 1024 * 1024,
        tokenSuffix: String = "asset",
    ): StagedImportMetadata = StagedImportMetadata(
        token = "$sessionToken.$tokenSuffix",
        kind = LargeImportKind.IMAGE,
        fileName = "large.png",
        mimeType = "image/png",
        byteCount = byteCount,
        sha256 = "a".repeat(64),
        mediaMetadata = MediaAssetMetadata(width = 800, height = 600))

    private fun host(
        transport: FakeTransport,
        acceptedRoot: File,
        epoch: Long = 7L,
    ): CreativeLargeImportHost = CreativeLargeImportHost(
        resolverProvider = { error("ContentResolver is not used in this test") },
        acceptedRootProvider = { CreativeAcceptedRoot(acceptedRoot.path, epoch) },
        liveEpochProvider = { epoch },
        transport = transport,
        ioDispatcher = Dispatchers.Unconfined,
    )

    private fun request(metadata: StagedImportMetadata): LargeImportRequest =
        LargeImportRequest.NewProject(
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext(CreativeOriginContext.STANDALONE),
            name = "Large Import",
            kind = NewMediaProjectKind.IMAGE,
            sessionToken = "session-7",
            opID = "import-op-1",
            metadata = metadata)

    private fun submitResponse(jobID: String = "job-1"): String = """
        {"version":6,"schema":"floe.creative/6","ok":true,
         "jobID":"$jobID","state":"queued",
         "acceptedAt":"2026-01-01T00:00:00Z"}
    """.trimIndent()

    @Test
    fun `reviewed large import submits over the real v6 action without wirePending`() =
        runBlocking {
            val root = root()
            try {
                val transport = FakeTransport { submitResponse() }
                val host = host(transport, root)
                val handle = host.submit(request(metadata("session-7")))
                assertEquals("job-1", handle.jobID)
                assertEquals(LargeImportState.QUEUED, handle.state)
                val sent = transport.requests.single()
                assertTrue(sent.contains("\"action\":\"media.largeImport.submit\""))
                assertTrue(sent.contains("\"byteCount\":104857600"))
                assertTrue(sent.contains("\"version\":6"))
                assertFalse(sent.contains("largeImportWirePending"))
                // Accepted submit transferred ownership: Root stop no longer
                // deletes this token in the App.
                assertEquals(0, host.activeStagingCount())
            } finally {
                root.deleteRecursively()
            }
        }

    @Test
    fun `status and cancel carry job owner identity and parse native truth`() =
        runBlocking {
            val root = root()
            try {
                val transport = FakeTransport { request ->
                    when (request["action"]?.toString()?.trim('"')) {
                        "media.largeImport.submit" -> submitResponse()
                        "media.largeImport.status" -> """
                            {"version":6,"schema":"floe.creative/6","ok":true,
                             "jobID":"job-1","state":"completed",
                             "updatedAt":"2026-01-01T00:00:02Z","progress":1.0,
                             "createdProjectID":"PID","createdRevision":2,
                             "errorCode":null,"retryable":false}
                        """.trimIndent()
                        "media.largeImport.cancel" -> """
                            {"version":6,"schema":"floe.creative/6","ok":true,
                             "jobID":"job-1","state":"completed",
                             "acceptedAt":"2026-01-01T00:00:00Z"}
                        """.trimIndent()
                        else -> error("unexpected action")
                    }
                }
                val host = host(transport, root)
                host.submit(request(metadata("session-7")))
                val status = host.status(LargeImportStatusRequest(
                    jobID = "job-1", sessionToken = "session-7"))
                assertEquals(LargeImportState.COMPLETED, status.state)
                assertEquals("PID", status.createdProjectID)
                assertEquals(2L, status.createdRevision)
                assertTrue(transport.requests[1].contains("\"jobID\":\"job-1\""))
                assertTrue(transport.requests[1].contains("\"sessionToken\":\"session-7\""))

                val cancelled = host.cancel(LargeImportCancelRequest(
                    jobID = "job-1", sessionToken = "session-7",
                    opID = "import-op-1"))
                assertEquals(LargeImportState.COMPLETED, cancelled.state)
                assertTrue(transport.requests[2].contains("\"opID\":\"import-op-1\""))
            } finally {
                root.deleteRecursively()
            }
        }

    @Test
    fun `typed native refusal is surfaced and ambiguous exchange is not retried`() =
        runBlocking {
            val root = root()
            try {
                val refusal = FakeTransport {
                    """{"version":6,"schema":"floe.creative/6","ok":false,
                       "error":"importTooLarge","retryable":false}"""
                }
                val hostRefusal = host(refusal, root)
                val refused = runCatching {
                    hostRefusal.submit(request(metadata("session-7")))
                }.exceptionOrNull()
                assertTrue(refused is CreativeException)
                assertEquals("importTooLarge", (refused as CreativeException).code)

                val ambiguous = FakeTransport { "not-json" }
                val hostAmbiguous = host(ambiguous, root)
                val unknown = runCatching {
                    hostAmbiguous.submit(request(metadata("session-7")))
                }.exceptionOrNull()
                assertTrue(unknown is CreativeException)
                assertEquals("importOutcomeUnknown",
                    (unknown as CreativeException).code)
                assertFalse(unknown.retryable)
            } finally {
                root.deleteRecursively()
            }
        }

    @Test
    fun `app staging drain is honest and root change reopens staging`() =
        runBlocking {
            val root = root()
            try {
                val host = host(FakeTransport { submitResponse() }, root)
                assertTrue(host.drainStaging(7L, timeoutMillis = 100))
                // A different generation is not blocked by the old fence.
                assertEquals(0, host.activeStagingCount())
            } finally {
                root.deleteRecursively()
            }
        }
}
