// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notes

import com.floe.android.bridge.SwiftCore
import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.NoteCoverState
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NotesPageOCRState
import com.floe.android.feature.notes.NoteResourceChunk
import com.floe.android.feature.notes.NoteResourceRecord
import com.floe.android.feature.notes.Notebook
import com.floe.android.feature.notes.NotesArchiveChunk
import com.floe.android.feature.notes.NotesArchiveExport
import com.floe.android.feature.notes.NotesArchiveHandle
import com.floe.android.feature.notes.NotesArchiveImport
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesBinding
import com.floe.android.feature.notes.NotesCoverRequest
import com.floe.android.feature.notes.NotesCreateDocument
import com.floe.android.feature.notes.NotesDocumentPage
import com.floe.android.feature.notes.NotesDuplicateDocument
import com.floe.android.feature.notes.NotesEventBatch
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesLibrarySummary
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesProposalSummary
import com.floe.android.feature.notes.NotesResourceImport
import com.floe.android.feature.notes.NotesSaveMessage
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.NotesStatus
import com.floe.android.feature.notes.NotesTextImport
import com.floe.android.feature.notes.NotesTextWrite
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/** One process-wide transport seam; tests can supply a controlled fake. */
interface NotesTransport {
    fun exchange(request: String): String
}

/** The only production transport: the existing frozen bridge C ABI. */
object SwiftNotesTransport : NotesTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

/**
 * Production App-side adapter for the native Notes authority.
 *
 * There is deliberately no in-memory notes fallback and no local database.
 * Every method crosses `floe.notes/4`; binding is epoch-exact and lazily opens
 * the native store only on the first data command.
 */
class NotesHostService(
    private val transport: NotesTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : NotesService {
    private val bindMutex = Mutex()
    private var boundEpoch: Long? = null
    private var binding: NotesBinding? = null

    override suspend fun bind(epoch: Long): NotesBinding = withContext(ioDispatcher) {
        bindMutex.withLock { bindLocked(epoch) }
    }

    override suspend fun status(): NotesStatus = withContext(ioDispatcher) {
        val response = exchange(NotesWireCodec.request(
            operation = "notes.status", requestID = UUID.randomUUID().toString()))
        NotesStatus(
            bound = response.bool("bound") ?: false,
            storeOpen = response.bool("storeOpen") ?: false,
        )
    }

    override suspend fun library(): NotesLibrarySummary = withContext(ioDispatcher) {
        val response = perform("library.summary", null)
        NotesWireCodec.decodeLibrary(response)
    }

    override suspend fun notebooks(): List<Notebook> = withContext(ioDispatcher) {
        val response = perform("notebook.list", null)
        response.array("notebooks")?.map { NotesWireCodec.decodeNotebook(it) }.orEmpty()
    }

    override suspend fun createNotebook(title: String): Notebook = withContext(ioDispatcher) {
        val response = perform("notebook.create", buildJsonObject { put("title", title) })
        NotesWireCodec.decodeNotebook(response.obj("notebook")
            ?: throw NotesException("invalidResponse", "notebook"))
    }

    override suspend fun renameNotebook(notebookID: String, title: String): Unit = withContext(ioDispatcher) {
        perform("notebook.rename", buildJsonObject {
            put("notebookID", notebookID); put("title", title)
        })
        Unit
    }

    override suspend fun deleteNotebook(notebookID: String): Unit = withContext(ioDispatcher) {
        perform("notebook.delete", buildJsonObject { put("notebookID", notebookID) })
        Unit
    }

    override suspend fun documents(includeTrash: Boolean, limit: Int): NotesDocumentPage =
        withContext(ioDispatcher) {
            val response = perform("document.list", buildJsonObject {
                put("includeTrash", includeTrash); put("limit", limit)
            })
            NotesWireCodec.decodeDocumentPage(response)
        }

    override suspend fun recentDocuments(limit: Int): List<NoteDocumentSummary> =
        withContext(ioDispatcher) {
            val response = perform("document.recent", buildJsonObject { put("limit", limit) })
            response.array("documents")?.map { NotesWireCodec.decodeSummary(it) }.orEmpty()
        }

    override suspend fun document(documentID: String): NoteDocument = withContext(ioDispatcher) {
        val response = perform("document.get", buildJsonObject { put("documentID", documentID) })
        NotesWireCodec.decodeDocument(response["document"])
    }

    override suspend fun documentSummary(documentID: String): NoteDocumentSummary =
        withContext(ioDispatcher) {
            val response = perform("document.summary", buildJsonObject { put("documentID", documentID) })
            NotesWireCodec.decodeSummary(response["document"]
                ?: throw NotesException("invalidResponse", "document"))
        }

    override suspend fun createDocument(request: NotesCreateDocument): NoteDocument =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("kind", request.kind.wire)
                put("title", request.title)
                request.notebookID?.let { put("notebookID", it) }
                request.documentID?.let { put("documentID", it) }
                request.resourceID?.let { put("resourceID", it) }
                request.fileName?.let { put("fileName", it) }
            }
            NotesWireCodec.decodeDocument(perform("document.create", payload)["document"])
        }

    override suspend fun duplicateDocument(request: NotesDuplicateDocument): NoteDocument =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("documentID", request.sourceDocumentID)
                request.newDocumentID?.let { put("newDocumentID", it) }
                request.title?.let { put("title", it) }
                request.notebookID?.let { put("notebookID", it) }
            }
            NotesWireCodec.decodeDocument(perform("document.duplicate", payload)["document"])
        }

    override suspend fun saveMessage(request: NotesSaveMessage): NoteDocument =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("text", request.text)
                request.title?.let { put("title", it) }
                request.notebookID?.let { put("notebookID", it) }
                request.documentID?.let { put("documentID", it) }
            }
            NotesWireCodec.decodeDocument(perform("document.saveMessage", payload)["document"])
        }

    override suspend fun createLinkedMindMap(
        documentID: String,
        expectedRevision: Int,
        title: String,
        pageID: String?,
    ): NoteDocument = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("documentID", documentID)
            put("expectedRevision", expectedRevision)
            put("title", title)
            pageID?.let { put("pageID", it) }
        }
        NotesWireCodec.decodeDocument(perform("document.createLinkedMindMap", payload)["document"])
    }

    override suspend fun apply(request: NotesApplyRequest): NoteDocument = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("documentID", request.documentID)
            put("expectedRevision", request.expectedRevision)
            put("title", request.title)
            request.requestID?.let { put("requestID", it) }
            request.baseRevision?.let { put("baseRevision", it) }
            request.conversationID?.let { put("conversationID", it) }
            put("edits", NotesWireCodec.encodeEdits(request.edits))
        }
        NotesWireCodec.decodeDocument(perform("document.apply", payload)["document"])
    }

    override suspend fun undo(documentID: String, expectedRevision: Int, redo: Boolean): NoteDocument =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("documentID", documentID); put("expectedRevision", expectedRevision); put("redo", redo)
            }
            NotesWireCodec.decodeDocument(perform("document.undo", payload)["document"])
        }

    override suspend fun setTrashed(documentID: String, expectedRevision: Int, trashed: Boolean): NoteDocument =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("documentID", documentID); put("expectedRevision", expectedRevision); put("trashed", trashed)
            }
            NotesWireCodec.decodeDocument(perform("document.setTrashed", payload)["document"])
        }

    override suspend fun deletePermanently(documentID: String, expectedRevision: Int): Unit =
        withContext(ioDispatcher) {
            perform("document.permanentlyDelete", buildJsonObject {
                put("documentID", documentID); put("expectedRevision", expectedRevision)
            })
            Unit
        }

    override suspend fun history(documentID: String): NoteHistoryState = withContext(ioDispatcher) {
        NotesWireCodec.decodeHistory(perform("document.history", buildJsonObject {
            put("documentID", documentID)
        }))
    }

    override suspend fun markOpened(documentID: String): Unit = withContext(ioDispatcher) {
        perform("document.markOpened", buildJsonObject { put("documentID", documentID) })
        Unit
    }

    override suspend fun setFavorite(
        documentID: String,
        expectedRevision: Int,
        isFavorite: Boolean,
    ): NoteDocument = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("documentID", documentID); put("expectedRevision", expectedRevision)
            put("isFavorite", isFavorite)
        }
        NotesWireCodec.decodeDocument(perform("document.setFavorite", payload)["document"])
    }

    override suspend fun setTags(
        documentID: String,
        expectedRevision: Int,
        tags: List<String>,
    ): NoteDocument = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("documentID", documentID); put("expectedRevision", expectedRevision)
            putJsonArray("tags") { tags.forEach { add(JsonPrimitive(it)) } }
        }
        NotesWireCodec.decodeDocument(perform("document.setTags", payload)["document"])
    }

    override suspend fun cover(documentID: String): NoteCoverState = withContext(ioDispatcher) {
        NotesWireCodec.decodeCover(perform("document.coverRead", buildJsonObject {
            put("documentID", documentID)
        }))
    }

    override suspend fun applyCover(request: NotesCoverRequest): NoteDocument = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("documentID", request.documentID)
            put("expectedRevision", request.expectedRevision)
            put("expectedCoverRevision", request.expectedCoverRevision)
            if (request.resourceID == null) {
                put("command", "restoreAutomatic")
            } else {
                put("command", "useResource"); put("resourceID", request.resourceID)
            }
        }
        NotesWireCodec.decodeDocument(perform("document.coverApply", payload)["document"])
    }

    override suspend fun cacheOfficePreview(
        documentID: String,
        sourceResourceID: String,
        previewResourceID: String,
        expectedRevision: Int,
    ): NoteDocument = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("documentID", documentID)
            put("sourceResourceID", sourceResourceID)
            put("previewResourceID", previewResourceID)
            put("expectedRevision", expectedRevision)
        }
        NotesWireCodec.decodeDocument(perform("document.cacheOfficePreview", payload)["document"])
    }

    override suspend fun editingSnapshot(documentID: String, revision: Int): NoteDocument? =
        withContext(ioDispatcher) {
            val response = perform("document.editingSnapshot", buildJsonObject {
                put("documentID", documentID); put("revision", revision)
            })
            if (response.bool("found") != true) null else NotesWireCodec.decodeDocument(response["document"])
        }

    override suspend fun search(query: String, limit: Int): List<NoteDocumentSummary> =
        withContext(ioDispatcher) {
            val response = perform("search.query", buildJsonObject {
                put("query", query); put("limit", limit)
            })
            response.array("documents")?.map { NotesWireCodec.decodeSummary(it) }.orEmpty()
        }

    // MARK: - Staged large text

    override suspend fun pageOCRState(documentID: String, pageID: String): NotesPageOCRState =
        withContext(ioDispatcher) {
            val response = perform("document.pageOCRState", buildJsonObject {
                put("documentID", documentID); put("pageID", pageID)
            })
            NotesPageOCRState(
                documentID = response.requiredString("documentID"),
                pageID = response.requiredString("pageID"),
                visualIndexKey = response.requiredString("visualIndexKey"),
                current = response.bool("current") ?: false,
                ocrSourceKey = response.string("ocrSourceKey"),
                ocrText = response.string("ocrText"),
                ocrError = response.string("ocrError"),
            )
        }

    override suspend fun beginTextWrite(request: NotesTextWrite): NotesTextImport =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("mode", request.mode.wire)
                put("byteCount", request.byteCount)
                request.documentID?.let { put("documentID", it) }
                request.pageID?.let { put("pageID", it) }
                request.elementID?.let { put("elementID", it) }
                request.expectedRevision?.let { put("expectedRevision", it) }
                request.baseRevision?.let { put("baseRevision", it) }
                put("title", request.title)
                request.notebookID?.let { put("notebookID", it) }
                request.newDocumentID?.let { put("newDocumentID", it) }
                request.frame?.let { put("frame", NotesWireCodec.encodeRect(it)) }
                request.textFormat?.let { put("textFormat", it) }
                put("fontSize", request.fontSize)
                request.requestID?.let { put("requestID", it) }
            }
            val response = perform("text.stageBegin", payload)
            TextImportSession(
                stageID = response.requiredString("stageID"),
                chunkBytes = response.int("chunkBytes") ?: NotesProtocol.CHUNK_BYTES,
                totalBytes = response.long("totalBytes") ?: request.byteCount,
            )
        }

    // MARK: - Resources

    override suspend fun beginResourceImport(
        fileName: String,
        mediaType: String,
        byteCount: Long,
    ): NotesResourceImport = withContext(ioDispatcher) {
        val response = perform("resource.importBegin", buildJsonObject {
            put("fileName", fileName); put("mediaType", mediaType); put("byteCount", byteCount)
        })
        ResourceImportSession(
            stageID = response.requiredString("stageID"),
            chunkBytes = response.int("chunkBytes") ?: NotesProtocol.CHUNK_BYTES,
            totalBytes = response.long("totalBytes") ?: byteCount,
        )
    }

    override suspend fun resourceMetadata(resourceID: String): NoteResourceRecord =
        withContext(ioDispatcher) {
            val response = perform("resource.metadata", buildJsonObject {
                put("resourceID", resourceID)
            })
            NotesWireCodec.decodeResource(response.obj("resource")
                ?: throw NotesException("invalidResponse", "resource"))
        }

    override suspend fun readResource(resourceID: String, offset: Long, maxBytes: Int): NoteResourceChunk =
        withContext(ioDispatcher) {
            val payload = buildJsonObject {
                put("resourceID", resourceID); put("offset", offset); put("maxBytes", maxBytes)
            }
            NotesWireCodec.decodeResourceChunk(perform("resource.read", payload))
        }

    override suspend fun discardUnreferencedResource(resourceID: String): Boolean =
        withContext(ioDispatcher) {
            val response = perform("resource.discardUnreferenced", buildJsonObject {
                put("resourceID", resourceID)
            })
            response.bool("removed") ?: false
        }

    override suspend fun collectDeletedResources(): Int = withContext(ioDispatcher) {
        perform("resources.collectDeleted", null).int("removed") ?: 0
    }

    // MARK: - Assistant grants

    override suspend fun grantAccess(conversationID: String, documentID: String, canEdit: Boolean): Unit =
        withContext(ioDispatcher) {
            perform("assistant.grantAccess", buildJsonObject {
                put("conversationID", conversationID); put("documentID", documentID); put("canEdit", canEdit)
            })
            Unit
        }

    override suspend fun bindAssistant(conversationID: String, documentID: String, canEdit: Boolean): Unit =
        withContext(ioDispatcher) {
            perform("assistant.bind", buildJsonObject {
                put("conversationID", conversationID); put("documentID", documentID); put("canEdit", canEdit)
            })
            Unit
        }

    override suspend fun revokeAccess(conversationID: String, documentID: String): Unit =
        withContext(ioDispatcher) {
            perform("assistant.revokeAccess", buildJsonObject {
                put("conversationID", conversationID); put("documentID", documentID)
            })
            Unit
        }

    override suspend fun grants(conversationID: String): Map<String, Boolean> =
        withContext(ioDispatcher) {
            val response = perform("assistant.grants", buildJsonObject {
                put("conversationID", conversationID)
            })
            response.obj("grants")?.entries?.mapNotNull { (key, value) ->
                (value as? JsonPrimitive)?.let { key to (it.content == "true") }
            }?.toMap().orEmpty()
        }

    override suspend fun scopedDocuments(conversationID: String): List<NoteDocumentSummary> =
        withContext(ioDispatcher) {
            val response = perform("assistant.scopedDocuments", buildJsonObject {
                put("conversationID", conversationID)
            })
            response.array("documents")?.map { NotesWireCodec.decodeSummary(it) }.orEmpty()
        }

    override suspend fun setAssistantFocus(
        conversationID: String,
        documentID: String,
        pageID: String?,
    ): Unit = withContext(ioDispatcher) {
        val payload = buildJsonObject {
            put("conversationID", conversationID); put("documentID", documentID)
            pageID?.let { put("pageID", it) }
        }
        perform("assistant.setFocus", payload)
        Unit
    }

    override suspend fun runtimeContext(conversationID: String): String? = withContext(ioDispatcher) {
        val response = perform("assistant.runtimeContext", buildJsonObject {
            put("conversationID", conversationID)
        })
        response.string("context")
    }

    // MARK: - Archive

    override suspend fun beginArchiveExport(
        documentID: String,
        expectedRevision: Int,
    ): NotesArchiveExport = withContext(ioDispatcher) {
        val response = perform("archive.export", buildJsonObject {
            put("documentID", documentID); put("expectedRevision", expectedRevision)
        })
        ArchiveExportSession(NotesWireCodec.decodeArchiveHandle(response))
    }

    override suspend fun beginArchiveImport(byteCount: Long): NotesArchiveImport =
        withContext(ioDispatcher) {
            val response = perform("archive.importBegin", buildJsonObject { put("byteCount", byteCount) })
            ArchiveImportSession(
                stageID = response.requiredString("stageID"),
                chunkBytes = response.int("chunkBytes") ?: NotesProtocol.CHUNK_BYTES,
                totalBytes = response.long("totalBytes") ?: byteCount,
            )
        }

    override suspend fun pendingProposals(documentID: String?): List<NotesProposalSummary> =
        withContext(ioDispatcher) {
            val payload = buildJsonObject { documentID?.let { put("documentID", it) } }
            NotesWireCodec.decodeProposals(perform("proposal.list", payload))
        }

    override suspend fun pollEvents(cursor: Long, limit: Int): NotesEventBatch =
        withContext(ioDispatcher) {
            val epoch = ensureBound()
            val requestID = UUID.randomUUID().toString()
            val response = exchange(NotesWireCodec.request(
                operation = "notes.poll", requestID = requestID, epoch = epoch,
                cursor = cursor, limit = limit))
            NotesWireCodec.decodeEventBatch(response)
        }

    override suspend fun close() {
        bindMutex.withLock {
            boundEpoch = null
            binding = null
        }
    }

    // MARK: - Wire

    private suspend fun ensureBound(): Long {
        val epoch = epochProvider()
            ?: throw NotesException("notesNotBound", "acceptedRootNotLive", retryable = true)
        bindMutex.withLock {
            if (boundEpoch == epoch) return epoch
            bindLocked(epoch)
            return epoch
        }
    }

    private fun bindLocked(epoch: Long): NotesBinding {
        if (boundEpoch == epoch && binding != null) return binding!!
        val response = exchange(NotesWireCodec.request(
            operation = "notes.bind", requestID = UUID.randomUUID().toString(), epoch = epoch))
        val value = NotesBinding(
            bound = response.bool("bound") ?: false,
            storeOpen = response.bool("storeOpen") ?: false,
            fingerprint = response.string("fingerprint"),
        )
        if (!value.bound) throw NotesException("notesNotBound", "bindRejected", retryable = true)
        boundEpoch = epoch
        binding = value
        return value
    }

    private suspend fun perform(action: String, payload: JsonObject?): JsonObject {
        val epoch = ensureBound()
        val request = NotesWireCodec.request(
            operation = "notes.command", requestID = UUID.randomUUID().toString(),
            epoch = epoch, action = action, payload = payload)
        return exchange(request)
    }

    private fun exchange(request: JsonObject): JsonObject {
        val text = request.toString()
        if (text.encodeToByteArray().size > NotesProtocol.MAX_REQUEST_BYTES) {
            throw NotesException("requestTooLarge")
        }
        val raw = try {
            transport.exchange(text)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw NotesException("transportFailure", error.message, retryable = true)
        }
        val parsed = try {
            Json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw NotesException("invalidResponse", "malformedJSON")
        if (parsed.bool("ok") != true) {
            throw NotesException(
                code = parsed.string("error") ?: "internal",
                reason = parsed.string("reason"),
                retryable = parsed.bool("retryable") ?: false,
            )
        }
        return parsed
    }

    private inner class TextImportSession(
        override val stageID: String,
        override val chunkBytes: Int,
        override val totalBytes: Long,
    ) : NotesTextImport {
        override suspend fun append(chunk: ByteArray): Long = withContext(ioDispatcher) {
            if (chunk.isEmpty()) throw NotesException("invalidPayload", "emptyChunk")
            if (chunk.size > chunkBytes) throw NotesException("requestTooLarge")
            val response = perform("text.stageAppend", buildJsonObject {
                put("stageID", stageID)
                put("dataBase64", NotesWireCodec.encodeBase64(chunk))
            })
            response.long("receivedBytes") ?: 0L
        }

        override suspend fun commit(): NoteDocument = withContext(ioDispatcher) {
            NotesWireCodec.decodeDocument(perform("text.stageCommit", buildJsonObject {
                put("stageID", stageID)
            })["document"])
        }

        override suspend fun abort() {
            try {
                withContext(ioDispatcher) {
                    perform("text.stageAbort", buildJsonObject { put("stageID", stageID) })
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Same best-effort cleanup contract as the other sessions.
            }
        }
    }

    private inner class ResourceImportSession(
        override val stageID: String,
        override val chunkBytes: Int,
        override val totalBytes: Long,
    ) : NotesResourceImport {
        override suspend fun append(chunk: ByteArray): Long = withContext(ioDispatcher) {
            if (chunk.isEmpty()) throw NotesException("invalidPayload", "emptyChunk")
            if (chunk.size > chunkBytes) throw NotesException("requestTooLarge")
            val response = perform("resource.importAppend", buildJsonObject {
                put("stageID", stageID)
                put("dataBase64", NotesWireCodec.encodeBase64(chunk))
            })
            response.long("receivedBytes") ?: 0L
        }

        override suspend fun commit(): ImportedResource = withContext(ioDispatcher) {
            NotesWireCodec.decodeImportedResource(perform("resource.importCommit", buildJsonObject {
                put("stageID", stageID)
            }))
        }

        override suspend fun abort() {
            try {
                withContext(ioDispatcher) {
                    perform("resource.importAbort", buildJsonObject { put("stageID", stageID) })
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Adapter cleanup is best-effort; the native service also
                // expires abandoned staging files. Never hide the original
                // caller failure with this cleanup error.
            }
        }
    }

    private inner class ArchiveImportSession(
        override val stageID: String,
        override val chunkBytes: Int,
        override val totalBytes: Long,
    ) : NotesArchiveImport {
        override suspend fun append(chunk: ByteArray): Long = withContext(ioDispatcher) {
            if (chunk.isEmpty()) throw NotesException("invalidPayload", "emptyChunk")
            if (chunk.size > chunkBytes) throw NotesException("requestTooLarge")
            val response = perform("archive.importAppend", buildJsonObject {
                put("stageID", stageID)
                put("dataBase64", NotesWireCodec.encodeBase64(chunk))
            })
            response.long("receivedBytes") ?: 0L
        }

        override suspend fun commit(notebookID: String?): List<NoteDocumentSummary> =
            withContext(ioDispatcher) {
                val payload = buildJsonObject {
                    put("stageID", stageID)
                    notebookID?.let { put("notebookID", it) }
                }
                val response = perform("archive.importCommit", payload)
                response.array("documents")?.map { NotesWireCodec.decodeSummary(it) }.orEmpty()
            }

        override suspend fun abort() {
            try {
                withContext(ioDispatcher) {
                    perform("archive.importAbort", buildJsonObject { put("stageID", stageID) })
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Same cleanup contract as the resource session.
            }
        }
    }

    private inner class ArchiveExportSession(
        private val value: NotesArchiveHandle,
    ) : NotesArchiveExport {
        override val handle: String get() = value.handle
        override val totalBytes: Long get() = value.byteCount
        override val fileName: String get() = value.fileName

        override suspend fun read(offset: Long, maxBytes: Int): NotesArchiveChunk =
            withContext(ioDispatcher) {
                NotesWireCodec.decodeArchiveChunk(perform("archive.exportRead", buildJsonObject {
                    put("handle", handle); put("offset", offset); put("maxBytes", maxBytes)
                }))
            }

        override suspend fun close() {
            try {
                withContext(ioDispatcher) {
                    perform("archive.exportClose", buildJsonObject { put("handle", handle) })
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Export staging files are service-owned and expire; closing a
                // failed transfer must not overwrite the caller's error.
            }
        }
    }
}

/**
 * Main wiring point. It holds only the App-side adapter; it never owns a
 * document store. Main starts it after the accepted runtime epoch exists and
 * exposes [service] to the Notes UI/assistant.
 */
class NotesHostController(
    private val epochProvider: () -> Long?,
    transport: NotesTransport = SwiftNotesTransport,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    val service: NotesService = NotesHostService(
        transport = transport,
        epochProvider = epochProvider,
        ioDispatcher = ioDispatcher,
    )

    suspend fun bindCurrent(): NotesBinding {
        val epoch = epochProvider()
            ?: throw NotesException("notesNotBound", "acceptedRootNotLive", retryable = true)
        return service.bind(epoch)
    }

    suspend fun stop() = service.close()
}
