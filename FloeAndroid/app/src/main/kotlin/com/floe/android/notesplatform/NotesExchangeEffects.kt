// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.feature.notes.ui.api.NotesExchangePort
import com.floe.android.feature.notes.ui.api.NotesImportKind
import com.floe.android.feature.notes.ui.api.NotesOpenAttachmentOutcome
import com.floe.android.feature.notes.ui.api.NotesOpenAttachmentRequest
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesResourceReader
import com.floe.android.feature.notes.ui.api.NotesShareOutcome
import com.floe.android.feature.notes.ui.api.NotesShareStreamRequest
import com.floe.android.feature.notes.ui.api.NotesShareTextRequest
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Real SAF / share / attachment adapter for the Notes workspace.
 *
 * Rules encoded here:
 *  - the system picker is launched from the mounted ActivityResult host; the
 *    returned URI grant is used immediately, the picked bytes are streamed in
 *    bounded chunks into an App-private staged file, and exactly the read
 *    grant we persisted is released again (no long-lived grant accumulation);
 *  - the staged file is the only input to the caller's chunked resource
 *    import — no provider URI or path enters the Notes model;
 *  - share stages a verified file under the App cache and exposes it through
 *    the non-exported read-only [NotesShareProvider]. A successful launch
 *    means the chooser started, never that a recipient consumed the file;
 *  - read-only attachments are staged the same way and opened through the
 *    existing platform handler; a missing handler is typed NOT_CONFIGURED.
 */
internal class NotesExchangeEffects(
    private val context: Context,
    private val broker: NotesPlatformActivityBroker,
    private val attachmentReader: NotesResourceReader?,
    private val stagingRoot: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : NotesExchangePort, AutoCloseable {

    private val picksRoot = File(stagingRoot, "picks")
    private val sharesRoot = File(stagingRoot, "shares")

    override suspend fun pickFile(
        kinds: Set<NotesImportKind>,
        suggestedName: String?,
    ): NotesPickedFile? {
        val intent = openDocumentIntent(kinds)
        val result = kotlinx.coroutines.withTimeoutOrNull(PICKER_TIMEOUT_MILLIS) {
            broker.launch(NotesLaunchLane.OPEN_DOCUMENT, intent)
        } ?: throw NotesPlatformErrors.cancelled("pickerTimeout")
        if (result.resultCode != Activity.RESULT_OK) return null
        val data = result.data ?: return null
        val uri = data.data ?: return null
        val flags = data.flags
        return withContext(ioDispatcher) {
            val resolver = context.contentResolver
            var persisted = false
            if ((flags and Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0) {
                persisted = runCatching {
                    resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    true
                }.getOrDefault(false)
            }
            var work: File? = null
            try {
                val declaredType = runCatching { resolver.getType(uri) }.getOrNull()
                var name = queryDisplayName(uri)
                    ?: uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                    ?: "file"
                val mime = NotesPlatformNames.mimeFor(name, declaredType)
                if (NotesPlatformNames.extensionOf(name) == null) {
                    val ext = NotesPlatformNames.extensionForMime(mime)
                    if (ext != null) name = "$name.$ext"
                }
                name = NotesPlatformNames.safeFileName(name, "file")
                work = NotesPlatformFiles.newWorkDirectory(picksRoot, "pick")
                val destination = File(work, name)
                val staged = NotesPlatformFiles.copyToNewFile(
                    destination = destination,
                    maxBytes = NotesPlatformFiles.MAX_STAGED_PICK_BYTES,
                    open = {
                        resolver.openInputStream(uri)
                            ?: throw NotesPlatformErrors.failed("providerStreamUnavailable")
                    },
                )
                val reader = StagedFileReader(
                    file = staged.file,
                    byteCount = staged.byteCount,
                    onClose = { NotesPlatformFiles.deleteQuietly(work) },
                    ioDispatcher = ioDispatcher,
                )
                NotesPickedFile(
                    fileName = name,
                    mediaType = mime,
                    byteCount = staged.byteCount,
                    read = { offset, maxBytes -> reader.read(offset, maxBytes) },
                    close = { reader.close() },
                )
            } catch (error: Throwable) {
                NotesPlatformFiles.deleteQuietly(work)
                throw NotesPlatformErrors.notes(error, "pickStagingFailed")
            } finally {
                if (persisted) {
                    runCatching {
                        resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                }
            }
        }
    }

    override suspend fun shareStream(request: NotesShareStreamRequest): NotesShareOutcome {
        if (request.totalBytes <= 0L) throw NotesPlatformErrors.failed("emptyExport")
        if (request.totalBytes > NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES) {
            throw NotesPlatformErrors.unsupported("exportTooLarge")
        }
        return withContext(ioDispatcher) {
            val work = NotesPlatformFiles.newWorkDirectory(sharesRoot, "share")
            var registeredToken: String? = null
            try {
                val fileName = NotesPlatformNames.safeFileName(request.fileName, "export")
                val destination = File(work, fileName)
                val staged = NotesPlatformFiles.copyFromReader(
                    destination = destination,
                    maxBytes = NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES,
                    read = request.read,
                )
                if (staged.byteCount != request.totalBytes) {
                    throw NotesPlatformErrors.failed("exportLengthMismatch")
                }
                val mediaType = NotesPlatformNames.mimeFor(fileName, request.mediaType)
                val entry = NotesShareRegistry.register(staged.file, fileName, mediaType)
                registeredToken = entry.token
                val uri = NotesShareRegistry.uriFor(context, entry.token)
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = entry.mimeType
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newUri(context.contentResolver, entry.displayName, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try {
                    broker.launchExternal(
                        Intent.createChooser(send, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    )
                } catch (error: Throwable) {
                    NotesShareRegistry.release(entry.token)
                    registeredToken = null
                    throw NotesPlatformErrors.notes(error, "shareLaunchFailed")
                }
                NotesShareOutcome(launched = true)
            } catch (error: Throwable) {
                NotesShareRegistry.release(registeredToken)
                NotesPlatformFiles.deleteQuietly(work)
                throw NotesPlatformErrors.notes(error, "shareStagingFailed")
            }
        }
    }

    override suspend fun shareText(request: NotesShareTextRequest): NotesShareOutcome {
        if (request.text.isEmpty()) throw NotesPlatformErrors.failed("emptyShareText")
        if (request.text.encodeToByteArray().size > MAX_SHARE_TEXT_BYTES) {
            throw NotesPlatformErrors.unsupported("shareTextTooLarge")
        }
        val type = NotesPlatformNames.mimeFor(request.fileName, request.mediaType)
            .takeIf { it.startsWith("text/") } ?: "text/plain"
        val send = Intent(Intent.ACTION_SEND).apply {
            this.type = type
            putExtra(Intent.EXTRA_TEXT, request.text)
            putExtra(Intent.EXTRA_SUBJECT, NotesPlatformNames.safeFileName(request.fileName, "note"))
        }
        try {
            broker.launchExternal(Intent.createChooser(send, null))
        } catch (error: Throwable) {
            throw NotesPlatformErrors.notes(error, "shareTextLaunchFailed")
        }
        return NotesShareOutcome(launched = true)
    }

    override suspend fun openAttachment(request: NotesOpenAttachmentRequest): NotesOpenAttachmentOutcome {
        val reader = attachmentReader
            ?: return NotesOpenAttachmentOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.NOT_CONFIGURED, "notesReaderUnavailable"),
            )
        if (request.resourceID.isBlank()) {
            return NotesOpenAttachmentOutcome.Failed(NotesPortFailure(NotesPortFailure.NOT_FOUND, "resource"))
        }
        return try {
            val work = withContext(ioDispatcher) {
                val directory = NotesPlatformFiles.newWorkDirectory(sharesRoot, "attach")
                try {
                    val fileName = NotesPlatformNames.safeFileName(request.fileName, "attachment")
                    val destination = File(directory, fileName)
                    val staged = NotesPlatformFiles.copyFromReader(
                        destination = destination,
                        maxBytes = NotesPlatformFiles.MAX_STAGED_PICK_BYTES,
                        read = { offset, maxBytes -> reader.read(request.resourceID, offset, maxBytes) },
                    )
                    val mediaType = NotesPlatformNames.mimeFor(fileName, request.mediaType)
                    val entry = NotesShareRegistry.register(staged.file, fileName, mediaType)
                    Triple(directory, entry, mediaType)
                } catch (error: Throwable) {
                    NotesPlatformFiles.deleteQuietly(directory)
                    throw error
                }
            }
            val (directory, entry, mediaType) = work
            val uri = NotesShareRegistry.uriFor(context, entry.token)
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mediaType)
                clipData = ClipData.newUri(context.contentResolver, entry.displayName, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val handlers = runCatching {
                context.packageManager.queryIntentActivities(view, 0)
            }.getOrNull().orEmpty()
            if (handlers.isEmpty()) {
                NotesShareRegistry.release(entry.token)
                NotesPlatformFiles.deleteQuietly(directory)
                return NotesOpenAttachmentOutcome.Unavailable(
                    NotesPortFailure(NotesPortFailure.NOT_CONFIGURED, "noAttachmentHandler"),
                )
            }
            try {
                broker.launchExternal(view)
            } catch (error: Throwable) {
                NotesShareRegistry.release(entry.token)
                NotesPlatformFiles.deleteQuietly(directory)
                throw error
            }
            NotesOpenAttachmentOutcome.Opened
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = NotesPlatformErrors.notes(error, "attachmentOpenFailed").failure
            NotesOpenAttachmentOutcome.Failed(failure)
        }
    }

    override fun close() {
        NotesShareRegistry.sweep()
        NotesPlatformFiles.sweepOlderThan(picksRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
        NotesPlatformFiles.sweepOlderThan(sharesRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
    }

    private fun openDocumentIntent(kinds: Set<NotesImportKind>): Intent {
        val types = LinkedHashSet<String>()
        var any = kinds.isEmpty()
        kinds.forEach { kind ->
            when (kind) {
                NotesImportKind.PDF -> types += "application/pdf"
                NotesImportKind.IMAGE -> types += "image/*"
                NotesImportKind.TEXT -> types += "text/*"
                NotesImportKind.OFFICE -> types += listOf(
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                    "application/vnd.oasis.opendocument.text",
                    "application/vnd.oasis.opendocument.spreadsheet",
                    "application/vnd.oasis.opendocument.presentation",
                    "application/msword",
                    "application/vnd.ms-excel",
                    "application/vnd.ms-powerpoint",
                )
                NotesImportKind.ARCHIVE -> types += listOf(
                    "application/zip",
                    "application/vnd.floe.notes.archive",
                )
                NotesImportKind.ENGINEERING, NotesImportKind.FILE -> any = true
            }
        }
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (!any && types.isNotEmpty()) {
                putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) cursor.getString(index) else null
                } else null
            }
        }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    private companion object {
        const val MAX_SHARE_TEXT_BYTES = 4 * 1024 * 1024
        const val PICKER_TIMEOUT_MILLIS = 15L * 60 * 1000
    }
}
