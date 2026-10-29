// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotesCounts
import com.floe.android.feature.notes.NotesCreateDocument
import com.floe.android.feature.notes.NotesDocumentPage
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesLibrarySummary
import com.floe.android.feature.notes.NotesResourceImport
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesWorkspaceEntry
import com.floe.android.feature.notes.ui.api.NotesWorkspaceImportPort
import com.floe.android.feature.notes.ui.api.NotesWorkspacePage
import com.floe.android.feature.notes.ui.api.NotesWorkspaceScope
import com.floe.android.feature.notes.ui.api.NotesWorkspaceScopePage
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.state.NotesLibraryController
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
import java.io.ByteArrayOutputStream
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused owner/close/cancel contract for the REAL workspace import path.
 *
 * The platform read adapter is covered by the App host binding; this test
 * verifies the consumer contract that can silently corrupt ownership:
 *  - the workspace port is opened once, never the SAF exchange fallback;
 *  - the exact bytes feed the existing independent Notes resource importer;
 *  - the picked read handle is closed exactly once on success, failure and
 *    coroutine cancellation;
 *  - cancellation never becomes a visible failure or a created document.
 */
class NotesWorkspaceImportContractTest {
    private val scopeID = "11111111-2222-4333-8444-555555555555"
    private val scope = NotesWorkspaceScope(id = scopeID, title = "Field Notes")

    private class FakeImport(
        private val bytes: ByteArray,
        private val failOnAppend: Boolean = false,
    ) : NotesResourceImport {
        override val stageID: String = "stage-test"
        override val chunkBytes: Int = 4
        override val totalBytes: Long = bytes.size.toLong()
        val appended = ByteArrayOutputStream()
        var aborts: Int = 0

        override suspend fun append(chunk: ByteArray): Long {
            if (failOnAppend) throw NotesException("storageUnavailable", "stage")
            appended.write(chunk)
            return appended.size().toLong()
        }

        override suspend fun commit(): ImportedResource = ImportedResource(
            resourceID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            mediaType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            byteCount = bytes.size.toLong(),
            fileName = "Report.docx",
            sha256 = "0".repeat(64),
        )

        override suspend fun abort() {
            aborts += 1
        }
    }

    private class FakePort(
        private val file: NotesPickedFile,
    ) : NotesWorkspaceImportPort {
        var opened: Pair<NotesWorkspaceScope, String>? = null

        override suspend fun scopes(pageToken: String?): NotesWorkspaceScopePage =
            NotesWorkspaceScopePage(
                scopes = listOf(
                    NotesWorkspaceScope(
                        id = "11111111-2222-4333-8444-555555555555",
                        title = "Field Notes",
                    ),
                ),
            )

        override suspend fun list(
            scope: NotesWorkspaceScope,
            relativePath: String,
            pageToken: String?,
        ): NotesWorkspacePage = NotesWorkspacePage(
            entries = listOf(
                NotesWorkspaceEntry(
                    name = "Report.docx",
                    relativePath = "Docs/Report.docx",
                    isDirectory = false,
                    byteCount = 8,
                ),
            ),
        )

        override suspend fun open(scope: NotesWorkspaceScope, relativePath: String): NotesPickedFile {
            opened = scope to relativePath
            return file
        }
    }

    private fun picked(
        bytes: ByteArray,
        cancelAfterFirstRead: Boolean = false,
        onClose: () -> Unit = {},
    ): NotesPickedFile {
        var reads = 0
        return NotesPickedFile(
            fileName = "Report.docx",
            mediaType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            byteCount = bytes.size.toLong(),
            read = { offset, maxBytes ->
                if (cancelAfterFirstRead && reads++ > 0) throw CancellationException("test")
                val start = offset.toInt().coerceIn(0, bytes.size)
                val end = (start + maxBytes).coerceAtMost(bytes.size)
                bytes.copyOfRange(start, end)
            },
            close = onClose,
        )
    }

    private fun service(
        imported: FakeImport,
        created: MutableList<NotesCreateDocument>,
    ): NotesService {
        val documentID = "99999999-8888-4777-8666-555555555555"
        val summary = NotesLibrarySummary(
            notebooks = emptyList(),
            counts = NotesCounts(0, 0, 0, 0, 0, 0, 0),
            recent = emptyList(),
        )
        return Proxy.newProxyInstance(
            NotesService::class.java.classLoader,
            arrayOf(NotesService::class.java),
        ) { _, method, args ->
            val continuation = args?.lastOrNull() as? Continuation<Any?>
                ?: throw UnsupportedOperationException("not suspend: ${method.name}")
            when (method.name) {
                "library" -> continuation.resumeWith(Result.success(summary))
                "documents" -> continuation.resumeWith(
                    Result.success(NotesDocumentPage(emptyList(), false, 0)),
                )
                "notebooks" -> continuation.resumeWith(Result.success(emptyList<Any>()))
                "collectDeletedResources" -> continuation.resumeWith(Result.success(0))
                "beginResourceImport" -> continuation.resumeWith(Result.success(imported))
                "createDocument" -> {
                    val request = args[0] as NotesCreateDocument
                    created += request
                    continuation.resumeWith(
                        Result.success(
                            NoteDocument(
                                id = documentID,
                                kind = request.kind,
                                title = request.title,
                                revision = 1,
                                pages = emptyList(),
                                createdAt = 0.0,
                                updatedAt = 0.0,
                                officeResourceID = request.resourceID,
                                officeFileName = request.fileName,
                            ),
                        ),
                    )
                }
                else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
            }
            COROUTINE_SUSPENDED
        } as NotesService
    }

    private fun controller(
        service: NotesService,
        port: NotesWorkspaceImportPort,
        opened: MutableList<String>,
        scope: CoroutineScope,
    ): NotesLibraryController {
        val base = unavailableNotesHostPorts(
            InMemoryNotesPresentationStore(),
            InMemoryNotesRecoveryStore(),
        )
        val ports = NotesHostPorts(
            media = base.media,
            office = base.office,
            assistant = base.assistant,
            exchange = base.exchange,
            presentation = base.presentation,
            recovery = base.recovery,
            workspaceImport = port,
        )
        return NotesLibraryController(
            service = service,
            ports = ports,
            resources = NotesResourceAccess(service),
            scope = scope,
            onOpenDocument = { id, _ -> opened += id },
        )
    }

    @Test
    fun workspaceFileUsesTheExistingNotesImportAndClosesTheHandleOnce() = runBlocking {
        val jobScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val bytes = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
            var closed = 0
            val import = FakeImport(bytes)
            val created = mutableListOf<NotesCreateDocument>()
            val opened = mutableListOf<String>()
            val port = FakePort(picked(bytes) { closed += 1 })
            val library = controller(service(import, created), port, opened, jobScope)

            assertTrue(library.importWorkspaceFile(scope, "Docs/Report.docx"))
            assertEquals("Docs/Report.docx", port.opened?.second)
            assertEquals(1, closed)
            assertTrue(bytes.contentEquals(import.appended.toByteArray()))
            assertEquals(1, created.size)
            assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", created[0].resourceID)
            assertEquals(NoteDocumentKind.OFFICE, created[0].kind)
            assertEquals("99999999-8888-4777-8666-555555555555", opened.single())
            assertFalse(library.busy)
            assertNull(library.failure)
        } finally {
            jobScope.cancel()
        }
    }

    @Test
    fun workspaceCancellationClosesTheHandleAndCreatesNothing() = runBlocking {
        val jobScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val bytes = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
            var closed = 0
            val import = FakeImport(bytes)
            val created = mutableListOf<NotesCreateDocument>()
            val opened = mutableListOf<String>()
            val port = FakePort(picked(bytes, cancelAfterFirstRead = true) { closed += 1 })
            val library = controller(service(import, created), port, opened, jobScope)

            val failure = runCatching {
                library.importWorkspaceFile(scope, "Docs/Report.docx")
            }.exceptionOrNull()
            assertTrue(failure is CancellationException)
            assertEquals(1, closed)
            assertTrue(created.isEmpty())
            assertNull(library.failure)
            assertFalse(library.busy)
            assertEquals(1, import.aborts)
        } finally {
            jobScope.cancel()
        }
    }

    @Test
    fun workspaceFailureClosesTheHandleAndCreatesNothing() = runBlocking {
        val jobScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val bytes = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
            var closed = 0
            val import = FakeImport(bytes, failOnAppend = true)
            val created = mutableListOf<NotesCreateDocument>()
            val opened = mutableListOf<String>()
            val port = FakePort(picked(bytes) { closed += 1 })
            val library = controller(service(import, created), port, opened, jobScope)

            assertFalse(library.importWorkspaceFile(scope, "Docs/Report.docx"))
            assertEquals(1, closed)
            assertTrue(created.isEmpty())
            assertEquals("storageUnavailable", library.failure?.code)
            assertFalse(library.busy)
            assertEquals(1, import.aborts)
        } finally {
            jobScope.cancel()
        }
    }
}
