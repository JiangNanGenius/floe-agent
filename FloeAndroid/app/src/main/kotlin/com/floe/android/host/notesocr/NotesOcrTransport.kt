// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesocr

import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.host.notes.NotesWireCodec
import com.floe.android.host.notes.bool
import com.floe.android.host.notes.string
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** One process-wide bridge seam; tests supply a controlled fake. */
public fun interface NotesOcrTransport {
    public fun exchange(request: String): String
}

/**
 * Minimal `floe.notes/4` command client for the closed additive OCR actions.
 * It reuses the EXISTING wire codec and C ABI transport; it is not a second
 * HTTP/provider stack and never carries a document path or secret.
 */
internal class NotesOcrBridge(
    private val transport: NotesOcrTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val bindMutex = Mutex()
    private var boundEpoch: Long? = null

    suspend fun perform(
        action: String,
        payload: JsonObject? = null,
        epochOverride: Long? = null,
    ): JsonObject = withContext(ioDispatcher) {
        val epoch = ensureBound(epochOverride)
        exchange(
            NotesWireCodec.request(
                operation = "notes.command",
                requestID = UUID.randomUUID().toString(),
                epoch = epoch,
                action = action,
                payload = payload,
            ),
        )
    }

    suspend fun reset() {
        bindMutex.withLock { boundEpoch = null }
    }

    private suspend fun ensureBound(override: Long?): Long {
        val epoch = override ?: epochProvider()
            ?: throw NotesException("notesNotBound", "acceptedRootNotLive", retryable = true)
        bindMutex.withLock {
            if (boundEpoch == epoch) return epoch
            val response = exchange(
                NotesWireCodec.request(
                    operation = "notes.bind",
                    requestID = UUID.randomUUID().toString(),
                    epoch = epoch,
                ),
            )
            if (response.bool("bound") != true) {
                throw NotesException("notesNotBound", "bindRejected", retryable = true)
            }
            boundEpoch = epoch
            return epoch
        }
    }

    private fun exchange(request: JsonObject): JsonObject {
        val text = request.toString()
        if (text.encodeToByteArray().size > NotesProtocol.MAX_REQUEST_BYTES) {
            throw NotesException("requestTooLarge")
        }
        val raw = try {
            transport.exchange(text)
        } catch (cancelled: CancellationException) {
            throw cancelled
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
}

internal object NotesOcrActions {
    const val STATUS = "ocr.status"
    const val STAGE_BEGIN = "ocr.stageBegin"
    const val STAGE_APPEND = "ocr.stageAppend"
    const val RECOGNIZE = "ocr.recognize"
    const val STAGE_ABORT = "ocr.stageAbort"
    const val CANCEL = "ocr.cancel"
    const val DRAIN = "ocr.drain"
    const val PREPARE_ROOT_STOP = "ocr.prepareRootStop"
    const val ABORT_ROOT_STOP = "ocr.abortRootStop"
    const val RESUME_AFTER_ROOT_CHANGE = "ocr.resumeAfterRootChange"
}

internal fun JsonObject.requiredString(name: String): String =
    string(name)?.takeIf { it.isNotEmpty() }
        ?: throw NotesException("invalidResponse", "missing:$name")
