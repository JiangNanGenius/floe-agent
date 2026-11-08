// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.floe.android.host.dataexchange.C08TaskTranscriptExport
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One OS picker, identified independently of the selected conversation or Activity instance. */
internal class TaskExportPickerSlot<T> {
    data class Request(val id: String, val name: String)
    private data class Ticket<T>(
        val request: Request,
        val result: CompletableDeferred<T>,
        var launched: Boolean = false,
        var abandoned: Boolean = false,
    )

    private var ticket: Ticket<T>? = null
    private val mutableRequests = MutableStateFlow<Request?>(null)
    val requests = mutableRequests.asStateFlow()
    fun hasListener(): Boolean = mutableRequests.subscriptionCount.value > 0

    @Synchronized fun admit(name: String): Pair<Request, CompletableDeferred<T>> {
        check(ticket == null) { "pickerBusy" }
        val request = Request(UUID.randomUUID().toString(), name)
        val result = CompletableDeferred<T>()
        ticket = Ticket(request, result)
        mutableRequests.value = request
        return request to result
    }

    /** A recreated Activity observes the same request but never launches it twice. */
    @Synchronized fun claimLaunch(id: String): Boolean {
        val active = ticket?.takeIf { it.request.id == id && !it.launched && !it.abandoned }
            ?: return false
        active.launched = true
        return true
    }

    @Synchronized fun complete(id: String, value: T): Boolean {
        val active = ticket?.takeIf { it.request.id == id } ?: return false
        ticket = null
        mutableRequests.value = null
        if (!active.abandoned) active.result.complete(value)
        return true
    }

    @Synchronized fun fail(id: String, failure: Exception): Boolean {
        val active = ticket?.takeIf { it.request.id == id } ?: return false
        ticket = null
        mutableRequests.value = null
        if (!active.abandoned) active.result.completeExceptionally(failure)
        return true
    }

    /** A cancelled launched picker remains a tombstone until its own OS callback returns. */
    @Synchronized fun abandon(id: String) {
        val active = ticket?.takeIf { it.request.id == id } ?: return
        active.abandoned = true
        active.result.cancel()
        if (!active.launched) {
            ticket = null
            mutableRequests.value = null
        }
    }
}

internal data class TaskExportDestination(val uri: Uri, val flags: Int)
internal data class TaskExportSaveReceipt(val bytes: Long, val sha256: String)

/** Application-owned handoff. The Activity transports only an opaque picker id and OS result. */
internal object ConversationTaskExportController {
    private val picker = TaskExportPickerSlot<TaskExportDestination?>()
    val requests = picker.requests

    suspend fun chooseDestination(suggestedName: String): TaskExportDestination? {
        check(picker.hasListener()) { "activityUnavailable" }
        val (request, result) = picker.admit(suggestedName)
        return try { result.await() } finally { picker.abandon(request.id) }
    }

    fun claimLaunch(id: String): Boolean = picker.claimLaunch(id)
    fun complete(id: String, destination: TaskExportDestination?): Boolean = picker.complete(id, destination)
    fun launchFailed(id: String) { picker.fail(id, IOException("pickerUnavailable")) }
    fun invalidResult(id: String): Boolean = picker.fail(id, IOException("destinationMissing"))
    fun activityFinished(id: String) { picker.fail(id, IOException("activityClosed")) }

    suspend fun save(
        context: Context,
        source: File,
        destination: TaskExportDestination,
        current: () -> Boolean,
    ): TaskExportSaveReceipt {
        require(destination.uri.scheme == "content") { "invalidDestination" }
        val required = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        require((destination.flags and required) == required) { "destinationGrantMissing" }
        val resolver = context.contentResolver
        // CREATE_DOCUMENT must not let an unexpected existing document be truncated.
        resolver.openInputStream(destination.uri)?.use { require(it.read() == -1) { "destinationNotEmpty" } }
            ?: throw IOException("destinationReadUnavailable")
        return TaskTranscriptDocumentWriter.write(
            source = source,
            openOutput = { resolver.openOutputStream(destination.uri, "wt") ?: throw IOException("destinationWriteUnavailable") },
            openReadback = { resolver.openInputStream(destination.uri) ?: throw IOException("destinationReadUnavailable") },
            current = current,
        )
    }
}

/** Bounded streaming and read-back; uncertain provider files are never deleted or called saved. */
internal object TaskTranscriptDocumentWriter {
    suspend fun write(
        source: File,
        openOutput: () -> OutputStream,
        openReadback: () -> InputStream,
        current: () -> Boolean,
    ): TaskExportSaveReceipt {
        val expectedBytes = source.length()
        require(source.isFile && expectedBytes in 1..C08TaskTranscriptExport.MAX_BYTES) { "invalidSize" }
        fun checkOwner() {
            check(current()) { "superseded" }
        }
        currentCoroutineContext().ensureActive()
        checkOwner()
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var count = 0L
        source.inputStream().use { input ->
            openOutput().use { output ->
                while (true) {
                    currentCoroutineContext().ensureActive()
                    checkOwner()
                    val read = input.read(buffer)
                    if (read < 0) break
                    count += read
                    require(count <= expectedBytes) { "sourceChanged" }
                    output.write(buffer, 0, read)
                    digest.update(buffer, 0, read)
                }
                require(count == expectedBytes) { "sourceChanged" }
                output.flush()
            }
        }
        val expectedDigest = digest.digest()
        val readbackDigest = MessageDigest.getInstance("SHA-256")
        var readbackCount = 0L
        var zeroReads = 0
        openReadback().use { input ->
            while (true) {
                currentCoroutineContext().ensureActive()
                checkOwner()
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) {
                    if (++zeroReads > 3) throw IOException("readStalled")
                    continue
                }
                zeroReads = 0
                readbackCount += read
                require(readbackCount <= expectedBytes) { "receiptMismatch" }
                readbackDigest.update(buffer, 0, read)
            }
        }
        require(readbackCount == expectedBytes && MessageDigest.isEqual(expectedDigest, readbackDigest.digest())) {
            "receiptMismatch"
        }
        currentCoroutineContext().ensureActive()
        checkOwner()
        return TaskExportSaveReceipt(count, expectedDigest.joinToString("") { "%02x".format(it.toInt() and 0xff) })
    }
}
