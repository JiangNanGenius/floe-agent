// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesResourceImport
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankKind
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeCreateBlankRequest
import com.floe.android.feature.notes.ui.api.NotesOfficeEditOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficePort
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.unavailableNotesHostPorts
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.InMemoryNotesRecoveryStore
import com.floe.android.feature.notes.ui.state.NotesLibraryController
import com.floe.android.feature.notes.ui.state.NotesResourceAccess
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Stable phase diagnostics for the actual Word/Office create failure. The
 * dialog previously showed only `notes_failure_generic`, so neither the App
 * nor device QA could tell whether preparation, resource import or
 * document.create failed. These codes are content-free and localized.
 */
class NotesOfficeCreateDiagnosticTest {
    private class FakeOffice(
        private val outcome: () -> NotesOfficeBlankOutcome,
    ) : NotesOfficePort {
        override suspend fun createBlank(request: NotesOfficeCreateBlankRequest): NotesOfficeBlankOutcome =
            outcome()

        override suspend fun edit(
            request: com.floe.android.feature.notes.ui.api.NotesOfficeEditRequest,
        ): NotesOfficeEditOutcome = NotesOfficeEditOutcome.ClosedWithoutChanges
    }

    private class FakeImport : NotesResourceImport {
        override val stageID: String = "stage-test"
        override val chunkBytes: Int = 64 * 1024
        override val totalBytes: Long = 4L

        override suspend fun append(chunk: ByteArray): Long = chunk.size.toLong()

        override suspend fun commit(): ImportedResource = ImportedResource(
            resourceID = "11111111-2222-4333-8444-555555555555",
            mediaType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            byteCount = 4,
            fileName = "Doc.docx",
            sha256 = "0".repeat(64),
        )

        override suspend fun abort() = Unit
    }

    private fun picked(): NotesPickedFile = NotesPickedFile(
        fileName = "Doc.docx",
        mediaType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        byteCount = 4,
        read = { _, _ -> byteArrayOf(1, 2, 3, 4) },
        close = {},
    )

    private fun service(
        begin: (() -> Result<Any?>, Continuation<*>) -> Unit = { _, _ -> },
    ): NotesService = Proxy.newProxyInstance(
        NotesService::class.java.classLoader,
        arrayOf(NotesService::class.java),
    ) { _, method, args ->
        val continuation = args?.lastOrNull() as? Continuation<*>
            ?: throw UnsupportedOperationException("not suspend: ${method.name}")
        when (method.name) {
            "beginResourceImport" -> begin({ Result.success(FakeImport()) }, continuation)
            "createDocument" -> (continuation as Continuation<Any?>).resumeWith(
                Result.failure(NotesException("invalidPayload", "officeDocument")),
            )
            else -> throw UnsupportedOperationException("Unexpected service call: ${method.name}")
        }
        COROUTINE_SUSPENDED
    } as NotesService

    private fun controller(
        service: NotesService,
        office: NotesOfficePort,
        scope: CoroutineScope,
    ): NotesLibraryController {
        val base = unavailableNotesHostPorts(
            InMemoryNotesPresentationStore(),
            InMemoryNotesRecoveryStore(),
        )
        val ports = NotesHostPorts(
            media = base.media,
            office = office,
            assistant = base.assistant,
            exchange = base.exchange,
            presentation = base.presentation,
            recovery = base.recovery,
        )
        return NotesLibraryController(
            service = service,
            ports = ports,
            resources = NotesResourceAccess(service),
            scope = scope,
            onOpenDocument = { _, _ -> },
        )
    }

    @Test
    fun officePortRefusalReportsThePreparationPhase() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val library = controller(
                service(),
                FakeOffice {
                    NotesOfficeBlankOutcome.Failed(
                        NotesPortFailure(NotesPortFailure.FAILED, "blankCreateFailed"),
                    )
                },
                scope,
            )
            assertFalse(library.createOfficeBlank(NotesOfficeBlankKind.WORD, "Doc"))
            assertEquals("officeCreatePrepareFailed", library.failure?.code)
            assertEquals("failed", library.failure?.detail)
            assertFalse(library.busy)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun resourceImportFailureReportsTheResourcePhase() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val library = controller(
                service(
                    begin = { _, continuation ->
                        (continuation as Continuation<Any?>).resumeWith(
                            Result.failure(NotesException("storageUnavailable", "stage")),
                        )
                    },
                ),
                FakeOffice { NotesOfficeBlankOutcome.Created(picked()) },
                scope,
            )
            assertFalse(library.createOfficeBlank(NotesOfficeBlankKind.WORD, "Doc"))
            assertEquals("officeCreateResourceFailed", library.failure?.code)
            assertFalse(library.busy)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun documentCreateFailureReportsTheDocumentPhase() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val library = controller(
                service(
                    begin = { result, continuation ->
                        (continuation as Continuation<Any?>).resumeWith(result())
                    },
                ),
                FakeOffice { NotesOfficeBlankOutcome.Created(picked()) },
                scope,
            )
            assertFalse(library.createOfficeBlank(NotesOfficeBlankKind.WORD, "Doc"))
            assertEquals("officeCreateDocumentFailed", library.failure?.code)
            assertFalse(library.busy)
        } finally {
            scope.cancel()
        }
    }
}
