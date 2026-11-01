// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaProject
import com.floe.android.feature.workbench.MediaProjectEnvelope
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeSourceCreateControllerTest {
    private val canvasEnvelope = CanvasProjectEnvelope(
        project = CanvasProject(
            id = "11111111-1111-1111-1111-111111111111",
            name = "Board",
            documents = listOf(CanvasDocument(
                id = "22222222-2222-2222-2222-222222222222",
                name = "Document", createdAt = "2026-01-01T00:00:00Z",
                updatedAt = "2026-01-01T00:00:00Z")),
            selectedDocumentID = "22222222-2222-2222-2222-222222222222",
            revision = 1,
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z"),
        assetsBasePath = "/accepted/FloeAgent/Materials",
        writable = true)

    private val mediaEnvelope = MediaProjectEnvelope(
        project = MediaProject(
            id = "33333333-3333-3333-3333-333333333333",
            kind = "image",
            name = "Photo",
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
            revision = 2,
            ownerKind = "standalone"),
        mediaRootPath = "/accepted/FloeAgent/WorkbenchRoot/3333",
        storage = CreativeStorageLayer.AppOwned,
        writable = true)

    private data class Fixture(
        val controller: CreativeSourceCreateController<String>,
        val staged: CreativeStagedAsset,
        val directory: File,
        val canvasRequests: MutableList<CreativeCanvasSourceRequest>,
        val mediaRequests: MutableList<CreativeMediaSourceRequest>,
        val discarded: MutableList<String>,
        val stagedCalls: () -> Int,
    )

    private fun pngBytes(width: Int, height: Int): ByteArray {
        val bytes = ByteArray(33)
        bytes[0] = 0x89.toByte(); bytes[1] = 0x50; bytes[2] = 0x4E; bytes[3] = 0x47
        bytes[4] = 0x0D; bytes[5] = 0x0A; bytes[6] = 0x1A; bytes[7] = 0x0A
        bytes[11] = 13
        "IHDR".toByteArray(Charsets.US_ASCII).copyInto(bytes, 12)
        bytes[16] = (width ushr 24).toByte(); bytes[17] = (width ushr 16).toByte()
        bytes[18] = (width ushr 8).toByte(); bytes[19] = width.toByte()
        bytes[20] = (height ushr 24).toByte(); bytes[21] = (height ushr 16).toByte()
        bytes[22] = (height ushr 8).toByte(); bytes[23] = height.toByte()
        bytes[24] = 8; bytes[25] = 6
        return bytes
    }

    private fun videoBytes(): ByteArray {
        // Minimal ISO BMFF with moov/mvhd + one tkhd.
        fun box(type: String, payload: ByteArray): ByteArray {
            val header = ByteArray(8)
            val size = payload.size + 8
            header[0] = (size ushr 24).toByte(); header[1] = (size ushr 16).toByte()
            header[2] = (size ushr 8).toByte(); header[3] = size.toByte()
            type.toByteArray(Charsets.US_ASCII).copyInto(header, 4)
            return header + payload
        }
        fun u32(target: ByteArray, offset: Int, value: Int) {
            target[offset] = (value ushr 24).toByte()
            target[offset + 1] = (value ushr 16).toByte()
            target[offset + 2] = (value ushr 8).toByte()
            target[offset + 3] = value.toByte()
        }
        val mvhd = ByteArray(108)
        u32(mvhd, 12, 1000)
        u32(mvhd, 16, 12_500)
        val tkhd = ByteArray(84)
        u32(tkhd, 40, 0x00010000)
        u32(tkhd, 76, 1920 shl 16)
        u32(tkhd, 80, 1080 shl 16)
        val moov = box("moov", box("mvhd", mvhd) + box("trak", box("tkhd", tkhd)))
        return box("ftyp", "isom".toByteArray(Charsets.US_ASCII) + ByteArray(4)) + moov
    }

    private fun fixture(
        bytes: ByteArray = pngBytes(640, 480),
        fileName: String = "photo.png",
        mimeType: String? = "image/png",
        inspect: (File) -> CreativeSourceMetadata? = { CreativeSourceInspector.inspect(it) },
        canvasCommit: (suspend (CreativeCanvasSourceRequest) -> CanvasProjectEnvelope)? = null,
        mediaCommit: (suspend (CreativeMediaSourceRequest) -> MediaProjectEnvelope)? = null,
    ): Fixture {
        val directory = File(
            System.getProperty("java.io.tmpdir"),
            "floe-source-create-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val file = File(directory, "staged")
        file.writeBytes(bytes)
        val token = "session-1.${java.util.UUID.randomUUID()}"
        val staged = CreativeStagedAsset(
            token = token,
            fileName = fileName,
            mimeType = mimeType,
            byteCount = bytes.size.toLong(),
            sha256 = sha256(bytes),
            file = file)
        val canvasRequests = CopyOnWriteArrayList<CreativeCanvasSourceRequest>()
        val mediaRequests = CopyOnWriteArrayList<CreativeMediaSourceRequest>()
        val discarded = CopyOnWriteArrayList<String>()
        var stageCalls = 0
        val controller = CreativeSourceCreateController<String>(
            stage = { _, _ -> stageCalls++; staged },
            inspect = inspect,
            discard = { value -> discarded.add(value); file.delete() },
            canvasCommit = { request ->
                canvasRequests.add(request)
                canvasCommit?.invoke(request) ?: canvasEnvelope
            },
            mediaCommit = { request ->
                mediaRequests.add(request)
                mediaCommit?.invoke(request) ?: mediaEnvelope
            },
            ioDispatcher = Dispatchers.Unconfined)
        return Fixture(controller, staged, directory, canvasRequests,
                       mediaRequests, discarded) { stageCalls }
    }

    private fun sha256(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }

    private fun close(fixture: Fixture) {
        fixture.directory.deleteRecursively()
    }

    @Test
    fun `canvas create dispatches measured kind and discards the staged copy`() = runBlocking {
        val fixture = fixture()
        try {
            val result = fixture.controller.createCanvas(
                source = "content://file/1", name = "  Imported Board  ",
                workspaceID = null, sessionToken = "session-1", opID = "op-canvas-1")
            assertEquals(canvasEnvelope, result)
            assertEquals(1, fixture.canvasRequests.size)
            val request = fixture.canvasRequests.single()
            assertEquals("op-canvas-1", request.opID)
            assertEquals("Imported Board", request.name)
            assertEquals("session-1", request.sessionToken)
            assertEquals(fixture.staged.token, request.token)
            assertEquals("image", request.sourceKind)
            assertEquals(640, request.width)
            assertEquals(480, request.height)
            assertEquals(fixture.staged.sha256, request.sha256)
            assertEquals(listOf(fixture.staged.token), fixture.discarded)
            assertFalse(fixture.staged.file.exists())
            assertEquals(1, fixture.stagedCalls())
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `canvas unmeasured source still creates a file node without inventing dimensions`() =
        runBlocking {
            val fixture = fixture(inspect = { null }, mimeType = "application/pdf")
            try {
                fixture.controller.createCanvas(
                    "content://file/2", "Doc", null, "session-1", "op-canvas-2")
                val request = fixture.canvasRequests.single()
                assertEquals("file", request.sourceKind)
                assertNull(request.width)
                assertNull(request.height)
                assertEquals("application/pdf", request.mimeType)
            } finally {
                close(fixture)
            }
        }

    @Test
    fun `media image uses measured dimensions and the byte mime`() = runBlocking {
        val fixture = fixture(mimeType = "application/octet-stream")
        try {
            val result = fixture.controller.createMedia(
                source = "content://file/3", name = "Photo", kind = "image",
                storage = CreativeStorageLayer.AppOwned, origin = null,
                sessionToken = "session-1", opID = "op-media-1")
            assertEquals(mediaEnvelope, result)
            val request = fixture.mediaRequests.single()
            assertEquals("image", request.kind)
            assertEquals(640, request.width)
            assertEquals(480, request.height)
            assertEquals("image/png", request.mimeType)
            assertNull(request.durationSeconds)
            assertEquals(CreativeStorageLayer.AppOwned, request.storage)
            assertEquals(listOf(fixture.staged.token), fixture.discarded)
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `media video carries measured duration and rotation`() = runBlocking {
        val fixture = fixture(bytes = videoBytes(), fileName = "clip.mp4", mimeType = "video/mp4")
        try {
            fixture.controller.createMedia(
                "content://file/4", "Clip", "video",
                CreativeStorageLayer.AppOwned,
                CreativeOriginContext(CreativeOriginContext.FILES),
                "session-1", "op-media-2")
            val request = fixture.mediaRequests.single()
            assertEquals("video", request.kind)
            assertEquals(1920, request.width)
            assertEquals(1080, request.height)
            assertEquals(12.5, request.durationSeconds!!, 0.0001)
            assertEquals(0.0, request.rotationDegrees!!, 0.0001)
            assertEquals("video/mp4", request.mimeType)
            assertEquals(CreativeOriginContext.FILES, request.origin?.kind)
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `media refuses an unmeasured source without dispatching`() = runBlocking {
        val fixture = fixture(inspect = { null }, fileName = "mystery.bin")
        try {
            val error = runCatching {
                fixture.controller.createMedia(
                    "content://file/5", "Mystery", "image",
                    CreativeStorageLayer.AppOwned, null, "session-1", "op-media-3")
            }.exceptionOrNull()
            assertTrue(error is CreativeException)
            assertEquals("unsupportedSourceFormat", (error as CreativeException).code)
            assertTrue(fixture.mediaRequests.isEmpty())
            assertEquals(listOf(fixture.staged.token), fixture.discarded)
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `media refuses a declared kind that disagrees with the bytes`() = runBlocking {
        val fixture = fixture() // PNG bytes, declared video
        try {
            val error = runCatching {
                fixture.controller.createMedia(
                    "content://file/6", "Wrong", "video",
                    CreativeStorageLayer.AppOwned, null, "session-1", "op-media-4")
            }.exceptionOrNull()
            assertEquals("sourceKindMismatch", (error as CreativeException).code)
            assertTrue(fixture.mediaRequests.isEmpty())
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `invalid operation id never stages bytes`() = runBlocking {
        val fixture = fixture()
        try {
            val error = runCatching {
                fixture.controller.createCanvas(
                    "content://file/7", "Board", null, "session-1", "bad op id")
            }.exceptionOrNull()
            assertEquals("invalidRequest", (error as CreativeException).code)
            assertEquals("invalidOperationID", (error as CreativeException).reason)
            assertEquals(0, fixture.stagedCalls())
            assertTrue(fixture.canvasRequests.isEmpty())
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `staged bytes replaced after staging are refused before dispatch`() = runBlocking {
        val fixture = fixture()
        try {
            fixture.staged.file.writeBytes(ByteArray(3))
            val error = runCatching {
                fixture.controller.createCanvas(
                    "content://file/8", "Board", null, "session-1", "op-canvas-8")
            }.exceptionOrNull()
            assertEquals("assetStagingInvalid", (error as CreativeException).code)
            assertTrue(fixture.canvasRequests.isEmpty())
            assertEquals(listOf(fixture.staged.token), fixture.discarded)
        } finally {
            close(fixture)
        }
    }

    @Test
    fun `a scope cancelled after staging dispatches nothing and discards the copy`() =
        runBlocking {
            val job = Job()
            lateinit var fixture: Fixture
            fixture = fixture(inspect = { file ->
                job.cancel()
                CreativeSourceInspector.inspect(file)
            })
            try {
                launch(job + Dispatchers.Unconfined) {
                    runCatching {
                        fixture.controller.createCanvas(
                            "content://file/9", "Board", null, "session-1", "op-canvas-9")
                    }
                }
                job.join()
                assertTrue(fixture.canvasRequests.isEmpty())
                assertEquals(listOf(fixture.staged.token), fixture.discarded)
            } finally {
                close(fixture)
            }
        }

    @Test
    fun `commit completes and discards staging when the caller is cancelled mid-commit`() =
        runBlocking {
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            var committed = false
            lateinit var fixture: Fixture
            fixture = fixture(canvasCommit = {
                started.complete(Unit)
                release.await()
                committed = true
                canvasEnvelope
            })
            val job = Job()
            try {
                launch(job + Dispatchers.Unconfined) {
                    runCatching {
                        fixture.controller.createCanvas(
                            "content://file/10", "Board", null, "session-1", "op-canvas-10")
                    }
                }
                started.await()
                job.cancel()
                release.complete(Unit)
                job.join()
                // The native commit was not abandoned mid-flight; its durable
                // receipt makes any later retry exact.
                assertTrue(committed)
                assertEquals(listOf(fixture.staged.token), fixture.discarded)
                assertNotNull(fixture.canvasRequests.single())
            } finally {
                close(fixture)
            }
        }
}
