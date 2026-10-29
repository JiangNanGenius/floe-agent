// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesocr

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesPageOCRState
import com.floe.android.feature.notes.ui.api.NotesExportedStream
import com.floe.android.feature.notes.ui.api.NotesIndexingAvailability
import com.floe.android.feature.notes.ui.api.NotesIndexingRequest
import com.floe.android.feature.notes.ui.api.NotesPageImageExportRequest
import com.floe.android.feature.notes.ui.api.NotesResourceReader
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * App-host OCR tests. They exercise the REAL host control flow and bridge
 * codec against scripted `floe.notes/4` replies; native image validation and
 * the provider request are covered by the Swift package tests. No device,
 * cloud provider or paid call is made.
 */
class NotesOcrHostTest {
    private val documentID = "11111111-1111-4111-8111-111111111111"
    private val pageID = "22222222-2222-4222-8222-222222222222"
    private val elementID = "33333333-3333-4333-8333-333333333333"
    private val sourceKey = "a".repeat(64)

    private val png: ByteArray = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    )

    private fun makeDocument(
        revision: Int = 3,
        ocrText: String? = null,
        ocrSourceKey: String? = null,
    ): NoteDocument = NoteDocument(
        id = documentID,
        kind = NoteDocumentKind.NOTEBOOK,
        title = "Stored note",
        revision = revision,
        pages = listOf(
            NotePage(
                id = pageID,
                width = 768.0,
                height = 1024.0,
                ocrText = ocrText,
                ocrSourceKey = ocrSourceKey,
                elements = listOf(
                    NoteElement(
                        id = elementID,
                        kind = NoteElementKind.TEXT,
                        frame = NoteRect(x = 10.0, y = 20.0, width = 300.0, height = 80.0),
                        text = "stored body",
                    ),
                ),
            ),
        ),
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    private fun makeState(
        current: Boolean,
        text: String? = null,
        key: String = sourceKey,
    ): NotesPageOCRState = NotesPageOCRState(
        documentID = documentID,
        pageID = pageID,
        visualIndexKey = key,
        current = current,
        ocrSourceKey = if (current) key else null,
        ocrText = text,
    )

    private fun request(): NotesIndexingRequest = NotesIndexingRequest(
        documentID = documentID,
        pageID = pageID,
        pageNumber = 1,
        pageWidthPt = 768f,
        pageHeightPt = 1024f,
        backgroundResourceID = null,
        drawingResourceID = null,
        elementTexts = listOf("STALE UI TEXT MUST NOT BE USED"),
        read = NotesResourceReader { _, _, _ -> ByteArray(0) },
    )

    private class FakeSource(
        private val state: NotesPageOCRState,
        private val document: NoteDocument,
    ) : NotesOcrNotesSource {
        var resourceReads = 0
        override suspend fun pageOCRState(
            documentID: String,
            pageID: String,
        ): NotesPageOCRState = state

        override suspend fun document(documentID: String): NoteDocument = document

        override suspend fun readResource(
            resourceID: String,
            offset: Long,
            maxBytes: Int,
        ): ByteArray {
            resourceReads += 1
            return ByteArray(0)
        }
    }

    private class FakeRenderer(
        private val bytes: ByteArray,
    ) : NotesOcrPageRenderer {
        var request: NotesPageImageExportRequest? = null
        var closed = false
        override suspend fun exportPageImage(
            request: NotesPageImageExportRequest,
        ): NotesExportedStream {
            this.request = request
            return NotesExportedStream(
                fileName = "page.png",
                mediaType = "image/png",
                totalBytes = bytes.size.toLong(),
                read = { offset, maxBytes ->
                    val start = offset.toInt().coerceAtLeast(0)
                    if (start >= bytes.size) ByteArray(0)
                    else bytes.copyOfRange(start, minOf(bytes.size, start + maxBytes))
                },
                close = { closed = true },
            )
        }
    }

    private inner class ScriptedTransport(
        private val pngSize: Int,
        var status: String = "ready",
        var recognizeText: String? = "recognized text",
        var cacheStatus: String = "applied",
        var prepareCanRetire: Boolean = true,
        val requests: MutableList<JsonObject> = mutableListOf(),
    ) : NotesOcrTransport {
        override fun exchange(request: String): String {
            val value = Json.parseToJsonElement(request) as JsonObject
            requests += value
            return when (value.string("operation")) {
                "notes.bind" -> """{"ok":true,"bound":true,"storeOpen":false}"""
                "notes.command" -> command(value)
                else -> """{"ok":false,"error":"invalidRequest"}"""
            }
        }

        private fun command(request: JsonObject): String {
            val action = request.string("action")
            val payload = request["payload"] as? JsonObject
            return when (action) {
                NotesOcrActions.STATUS -> if (status == "ready") {
                    """{"ok":true,"availability":"ready","providerLabel":"Fixture · Vision"}"""
                } else {
                    """{"ok":true,"availability":"$status","reason":"visionModelMissing"}"""
                }
                NotesOcrActions.STAGE_BEGIN ->
                    """{"ok":true,"stageID":"stage-1","chunkBytes":44000,"totalBytes":$pngSize}"""
                NotesOcrActions.STAGE_APPEND -> {
                    val offset = payload?.get("offset")?.let { (it as JsonPrimitive).intOrNull } ?: 0
                    val data = payload?.get("dataBase64")?.let {
                        (it as JsonPrimitive).contentOrNull
                    } ?: ""
                    val received = offset + Base64.getDecoder().decode(data).size
                    """{"ok":true,"stageID":"stage-1","receivedBytes":$received}"""
                }
                NotesOcrActions.RECOGNIZE -> {
                    val text = recognizeText
                    if (text == null) {
                        """{"ok":false,"error":"ocrProviderFailure","reason":"server","retryable":true}"""
                    } else {
                        """{"ok":true,"result":{"state":"recognized","text":"$text",
                           "providerLabel":"Fixture · Vision","sourceKey":"$sourceKey",
                           "documentID":"$documentID","pageID":"$pageID",
                           "documentRevision":3,"cache":{"status":"$cacheStatus",
                           "documentID":"$documentID","documentRevision":3,
                           "sourceKey":"$sourceKey","indexed":true,"retryable":false,
                           "textLength":${text.length},"reason":"sourceChanged"}}}"""
                    }
                }
                NotesOcrActions.STAGE_ABORT -> """{"ok":true,"aborted":true}"""
                NotesOcrActions.CANCEL ->
                    """{"ok":true,"cancelRequested":true,"activeCount":0}"""
                NotesOcrActions.PREPARE_ROOT_STOP ->
                    """{"ok":true,"cancelRequestedCount":1,"pendingCount":1,
                       "canRetire":$prepareCanRetire,"retainedStageCount":1}"""
                NotesOcrActions.ABORT_ROOT_STOP -> """{"ok":true,"aborted":true}"""
                NotesOcrActions.RESUME_AFTER_ROOT_CHANGE -> """{"ok":true,"resumed":true}"""
                NotesOcrActions.DRAIN ->
                    """{"ok":true,"drained":true,"pendingCount":0,"retainedStageCount":0}"""
                else -> """{"ok":false,"error":"unsupportedAction"}"""
            }
        }
    }

    private fun host(
        source: FakeSource,
        renderer: FakeRenderer,
        transport: ScriptedTransport,
        epoch: Long = 7L,
    ): NotesOcrHost = NotesOcrHost(
        source = source,
        renderer = renderer,
        bridge = NotesOcrBridge(transport, { epoch }, Dispatchers.Unconfined),
        ioDispatcher = Dispatchers.Unconfined,
    )

    @Test
    fun statusIsReadyOnlyWhenTheNativeRouteResolves() = runBlocking {
        val transport = ScriptedTransport(png.size)
        val host = host(FakeSource(makeState(false), makeDocument()), FakeRenderer(png), transport)
        val status = host.status()
        assertEquals(NotesIndexingAvailability.READY, status.availability)
        assertEquals("Fixture · Vision", status.providerLabel)

        transport.status = "notConfigured"
        val unavailable = host.status()
        assertEquals(NotesIndexingAvailability.NOT_CONFIGURED, unavailable.availability)
        assertEquals("visionModelMissing", unavailable.message)
    }

    @Test
    fun recognizeRendersOnlyTheStoredPageAndStreamsTheBoundedStage() = runBlocking {
        val transport = ScriptedTransport(png.size)
        val renderer = FakeRenderer(png)
        val host = host(FakeSource(makeState(false), makeDocument()), renderer, transport)

        val result = host.recognize(request())

        assertEquals("recognized text", result.text)
        assertEquals("Fixture · Vision", result.providerLabel)
        assertTrue(renderer.closed)
        val exported = renderer.request ?: error("render request")
        assertEquals(documentID, exported.documentID)
        val element = exported.page.elements.single()
        assertEquals("stored body", element.text)
        assertFalse(element.text.contains("STALE UI TEXT"))
        assertEquals(768f, exported.page.widthPt)
        assertTrue(exported.targetWidthPx in 64..4096)

        val actions = transport.requests.mapNotNull { it.string("action") }
        assertEquals(1, actions.count { it == NotesOcrActions.STAGE_BEGIN })
        assertEquals(1, actions.count { it == NotesOcrActions.RECOGNIZE })
        assertTrue(actions.count { it == NotesOcrActions.STAGE_APPEND } >= 1)
        assertEquals(0, actions.count { it == NotesOcrActions.STAGE_ABORT })
    }

    @Test
    fun currentNativeCacheIsReusedWithoutRenderOrProvider() = runBlocking {
        val transport = ScriptedTransport(png.size)
        val renderer = FakeRenderer(png)
        val cached = "cached native text"
        val host = host(
            FakeSource(
                makeState(current = true, text = cached),
                makeDocument(ocrText = cached, ocrSourceKey = sourceKey),
            ),
            renderer,
            transport,
        )

        val result = host.recognize(request())
        assertEquals(cached, result.text)
        assertTrue(transport.requests.isEmpty())
        assertEquals(null, renderer.request)
        assertFalse(renderer.closed)
    }

    @Test
    fun staleCacheReceiptIsTypedAndAbortsTheStage() = runBlocking {
        val transport = ScriptedTransport(png.size, cacheStatus = "stale")
        val host = host(FakeSource(makeState(false), makeDocument()), FakeRenderer(png), transport)
        try {
            host.recognize(request())
            fail("a stale cache receipt must not return recognized text")
        } catch (error: NotesException) {
            assertEquals("ocrStale", error.code)
        }
        assertTrue(transport.requests.any { it.string("action") == NotesOcrActions.STAGE_ABORT })
    }

    @Test
    fun unconfiguredStatusRefusesBeforeRendering() = runBlocking {
        val transport = ScriptedTransport(png.size, status = "notConfigured")
        val renderer = FakeRenderer(png)
        val host = host(FakeSource(makeState(false), makeDocument()), renderer, transport)
        try {
            host.recognize(request())
            fail("an unconfigured vision route must not render or dispatch")
        } catch (error: NotesException) {
            assertEquals("notConfigured", error.code)
        }
        assertEquals(null, renderer.request)
        assertFalse(transport.requests.any { it.string("action") == NotesOcrActions.STAGE_BEGIN })
    }

    @Test
    fun malformedPngIsRejectedBeforeAnyStageCommand() = runBlocking {
        val transport = ScriptedTransport(png.size)
        val host = host(
            FakeSource(makeState(false), makeDocument()),
            FakeRenderer(byteArrayOf(1, 2, 3, 4)),
            transport,
        )
        try {
            host.recognize(request())
            fail("a non-PNG export must not be staged")
        } catch (error: NotesException) {
            assertEquals("invalidPayload", error.code)
            assertEquals("ocrImageFormat", error.reason)
        }
        assertFalse(transport.requests.any { it.string("action") == NotesOcrActions.STAGE_BEGIN })
    }

    @Test
    fun largeImageIsSplitAtTheProtocolChunkBound() = runBlocking {
        val header = png.copyOfRange(0, 33)
        val large = header + ByteArray(100_000) { 0x42 }
        val transport = ScriptedTransport(large.size)
        val host = host(FakeSource(makeState(false), makeDocument()), FakeRenderer(large), transport)
        val result = host.recognize(request())
        assertEquals("recognized text", result.text)
        val appends = transport.requests.filter { it.string("action") == NotesOcrActions.STAGE_APPEND }
        assertEquals(3, appends.size)
        for (append in appends) {
            val payload = append["payload"] as JsonObject
            val encoded = (payload["dataBase64"] as JsonPrimitive).content
            assertTrue(Base64.getDecoder().decode(encoded).size <= 44_000)
        }
    }


    @Test
    fun epochWithoutALiveRootIsAlreadyRetired() = runBlocking {
        val transport = ScriptedTransport(png.size)
        val host = host(FakeSource(makeState(false), makeDocument()), FakeRenderer(png), transport)
        val report = host.prepareForRootStop(0L)
        assertTrue(report.canRetire)
        assertEquals(0, report.pendingCount)
        val drained = host.drain(0L)
        assertTrue(drained.drained)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun rootStopUsesTheRequestedEpochAndReportsRetirementTruthfully() = runBlocking {
        val transport = ScriptedTransport(png.size, prepareCanRetire = false)
        val host = host(FakeSource(makeState(false), makeDocument()), FakeRenderer(png), transport)
        val report = host.prepareForRootStop(42L, deadlineMillis = 250)
        assertFalse(report.canRetire)
        assertEquals(1, report.pendingCount)
        assertEquals(1, report.cancelRequestedCount)
        assertEquals(1, report.retainedStageCount)

        val bind = transport.requests.first { it.string("operation") == "notes.bind" }
        assertEquals(42L, (bind["epoch"] as JsonPrimitive).content.toLong())

        val drained = host.drain(42L)
        assertTrue(drained.drained)
    }
}

private fun JsonObject.string(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it !is kotlinx.serialization.json.JsonNull }?.contentOrNull
