// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesResourceReader
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Chunked resource ingress/egress over the real [NotesService]. Bytes never
 * bypass the service CAS and no path is accepted or produced here.
 */
internal class NotesResourceAccess(
    private val service: NotesService,
) {
    fun reader(): NotesResourceReader = NotesResourceReader { resourceID, offset, maxBytes ->
        val safeMax = maxBytes.coerceIn(1, NotesProtocol.MAX_READ_BYTES)
        service.readResource(resourceID, offset, safeMax).data
    }

    suspend fun readAll(
        resourceID: String,
        maxBytes: Long,
        chunkBytes: Int = NotesProtocol.DEFAULT_READ_BYTES,
    ): ByteArray {
        if (maxBytes <= 0L) throw NotesException("resourceUnavailable", "previewLimit")
        val output = java.io.ByteArrayOutputStream()
        var offset = 0L
        var guard = 0
        while (guard++ < 100_000) {
            currentCoroutineContext().ensureActive()
            val remaining = maxBytes - output.size()
            if (remaining <= 0) throw NotesException("resourceUnavailable", "previewTooLarge")
            val request = minOf(
                chunkBytes.toLong(),
                remaining + 1,
                NotesProtocol.MAX_READ_BYTES.toLong(),
            ).toInt().coerceAtLeast(1)
            val chunk = service.readResource(resourceID, offset, request)
            if (chunk.data.isNotEmpty()) {
                if (output.size().toLong() + chunk.data.size > maxBytes) {
                    throw NotesException("resourceUnavailable", "previewTooLarge")
                }
                output.write(chunk.data)
            }
            if (chunk.eof || chunk.nextOffset <= offset || chunk.data.isEmpty()) break
            offset = chunk.nextOffset
        }
        return output.toByteArray()
    }

    suspend fun import(
        fileName: String,
        mediaType: String,
        byteCount: Long,
        onProgress: (received: Long, total: Long) -> Unit = { _, _ -> },
        read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
    ): ImportedResource {
        if (byteCount <= 0L) throw NotesException("invalidPayload", "emptyResource")
        if (byteCount > NotesProtocol.MAX_RESOURCE_BYTES) {
            throw NotesException("requestTooLarge", "resourceLimit")
        }
        val session = service.beginResourceImport(fileName, mediaType, byteCount)
        var committed = false
        try {
            var offset = 0L
            while (offset < byteCount) {
                currentCoroutineContext().ensureActive()
                val request = minOf(
                    session.chunkBytes.toLong(),
                    byteCount - offset,
                ).toInt().coerceAtLeast(1)
                val bytes = read(offset, request)
                if (bytes.isEmpty()) throw NotesException("invalidPayload", "shortRead")
                session.append(bytes)
                offset += bytes.size
                onProgress(offset, byteCount)
            }
            val result = session.commit()
            committed = true
            return result
        } finally {
            if (!committed) {
                // Best effort; never overwrite the original failure.
                runCatching { session.abort() }
            }
        }
    }

    suspend fun importBytes(
        fileName: String,
        mediaType: String,
        bytes: ByteArray,
    ): ImportedResource = import(
        fileName = fileName,
        mediaType = mediaType,
        byteCount = bytes.size.toLong(),
        read = { offset, maxBytes ->
            val start = offset.toInt().coerceIn(0, bytes.size)
            val end = (start + maxBytes).coerceAtMost(bytes.size)
            bytes.copyOfRange(start, end)
        },
    )

    suspend fun discardUnreferenced(resourceID: String) {
        runCatching { service.discardUnreferencedResource(resourceID) }
    }
}
