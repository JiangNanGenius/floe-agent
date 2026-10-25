// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOperation
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.UUID

/** Application-owned, offline provider input. No model, Linux, Run or
 * fabricated workspace is needed to read a user-picked Office document.
 * Call only from the trusted system-picker result owner, passing its ACTUAL
 * flags; an Intent to the engine is never a grant. The existing gateway
 * rechecks live OS access and bounds the stream. IO outlives view remounts.
 */
internal class OfficeProviderSnapshotStager(context: Context, private val root: File) : AutoCloseable {
    private val context = context.applicationContext
    private val backend = AndroidSafBackend(this.context)
    private val gateway = SafGatewayService(backend, releaseBroker = SharedUriGrantAuthority.broker)

    data class Snapshot(
        val sessionID: String, val file: File, val sourceUri: String,
        val sourceDocumentID: String?, val displayName: String,
        val bytes: Long, val sha256: String,
    )

    /** Cancel is a request; the controller keeps the returned operation until
     * it actually settles. Do not remove a snapshot while the engine reads
     * it. A successful return is input verification, never a render receipt.
     */
    fun submit(uriString: String?, actualResultFlags: Int,
               isCurrent: () -> Boolean): SafOperation<Snapshot> = gateway.submit readDocument@ { cancel ->
        if (!isCurrent() || cancel.isCancelled) return@readDocument SafOutcome.failure(SafFailure.Cancelled)
        if (uriString == null || !uriString.startsWith("content://") ||
            actualResultFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0) {
            return@readDocument SafOutcome.failure(SafFailure.Failed("document selection has no read grant"))
        }
        if (backend.classifyUri(uriString) != SafUriKind.DOCUMENT) {
            return@readDocument SafOutcome.failure(SafFailure.Failed("selection is not a provider document"))
        }
        val uri = Uri.parse(uriString)
        // Preview only: retain the shared read reference, without taking new
        // persistent or write access. Preexisting grants belong to their
        // owners and the broker preserves them after this IO settles.
        val lease = SharedUriGrantAuthority.acquireRead(context.contentResolver, uri, allowPersistence = false)
        var directory: File? = null
        var published = false
        try {
            cancel.ensureActive()
            if (!isCurrent()) return@readDocument SafOutcome.failure(SafFailure.Cancelled)
            if ((!root.isDirectory && !root.mkdirs()) || Files.isSymbolicLink(root.toPath())) {
                return@readDocument SafOutcome.failure(SafFailure.Io("document staging unavailable"))
            }
            val sessionID = UUID.randomUUID().toString()
            directory = File(root.canonicalFile, sessionID)
            Files.createDirectory(directory.toPath())
            val ref = SafDocumentRef(null, null, null, SafUriRef(uriString))
            val imported = gateway.workingCopy.importDocument(
                ref, directory, WorkspaceOfficeSnapshotStager.MAX_BYTES, cancel)
            when (imported) {
                is SafOutcome.Failure -> SafOutcome.failure(imported.failure, imported.detail)
                is SafOutcome.Success -> {
                    val copy = imported.value.staged
                    val extension = copy.displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
                    if (extension !in setOf("docx", "xlsx", "pptx")) {
                        return@readDocument SafOutcome.failure(SafFailure.Unsupported("choose a DOCX, XLSX or PPTX document"))
                    }
                    cancel.ensureActive()
                    if (!isCurrent()) return@readDocument SafOutcome.failure(SafFailure.Cancelled)
                    val file = File(directory, "document.$extension")
                    Files.move(copy.local.file.toPath(), file.toPath())
                    if (!file.setReadOnly()) {
                        return@readDocument SafOutcome.failure(SafFailure.Io("document snapshot could not be protected"))
                    }
                    cancel.ensureActive()
                    if (!isCurrent()) return@readDocument SafOutcome.failure(SafFailure.Cancelled)
                    published = true
                    SafOutcome.success(Snapshot(sessionID, file, uriString, copy.sourceDocumentId,
                        copy.displayName, copy.bytes, copy.sha256))
                }
            }
        } finally {
            // Cleanup only our never-exposed copy; the provider is never
            // written, deleted or renamed by this read-only input service.
            if (!published) {
                directory?.listFiles()?.forEach { it.delete() }
                directory?.delete()
            }
            lease.close()
        }
    }

    override fun close() = gateway.close()
}
