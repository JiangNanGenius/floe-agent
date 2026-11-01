// SPDX-License-Identifier: MPL-2.0
//
// Android platform adapters for C07 App entry. Intent decoding and content
// sniffing are bounded and never treat incoming MIME/name/size as authority.
// Notes import uses the EXISTING NotesService staging/document API; it does not
// create a second notes store, path scheme or grant cache.
package com.floe.android.host.entryflow

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotesCreateDocument
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesSaveMessage
import com.floe.android.feature.notes.NotesService
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** One already-bounded share/VIEW input before any provider IO. */
internal class C07RawShare(
    val action: String,
    val subject: String?,
    val text: String?,
    val uriStrings: List<String>,
    val persistable: Boolean,
) {
    val itemHint: Int get() = uriStrings.size + if (text.isNullOrBlank()) 0 else 1

    /** In-memory identity for rotation redelivery; never persisted. */
    val signature: String by lazy {
        val digest = MessageDigest.getInstance("SHA-256")
        fun field(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            digest.update(bytes)
            digest.update(0.toByte())
        }
        field(action)
        field(subject.orEmpty())
        field(text.orEmpty())
        uriStrings.forEach(::field)
        digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}

internal object C07ShareIntentReader {
    fun read(intent: Intent): C07RawShare? {
        val action = intent.action ?: return null
        if (action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE &&
            action != Intent.ACTION_VIEW
        ) {
            return null
        }
        val subject = runCatching { intent.getStringExtra(Intent.EXTRA_SUBJECT) }
            .getOrNull()?.take(200)
        val directText = runCatching {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        }.getOrNull()
        val clipText = runCatching {
            intent.clipData?.let { clip ->
                (0 until clip.itemCount).firstNotNullOfOrNull { index ->
                    clip.getItemAt(index).text?.toString()?.takeIf { it.isNotBlank() }
                }
            }
        }.getOrNull()
        val text = (directText ?: clipText)?.take(1_100_000)

        val uris = LinkedHashSet<String>()
        if (action == Intent.ACTION_VIEW || action == Intent.ACTION_SEND) {
            intent.data?.toString()?.takeIf { it.isNotEmpty() }?.let(uris::add)
        }
        runCatching {
            intent.clipData?.let { clip ->
                for (index in 0 until clip.itemCount) {
                    clip.getItemAt(index).uri?.toString()?.takeIf { it.isNotEmpty() }
                        ?.let(uris::add)
                }
            }
        }
        @Suppress("DEPRECATION")
        runCatching {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.toString()
                ?.takeIf { it.isNotEmpty() }?.let(uris::add)
        }
        @Suppress("DEPRECATION")
        runCatching {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?.forEach { uri -> uri.toString().takeIf { it.isNotEmpty() }?.let(uris::add) }
        }
        if (text.isNullOrBlank() && uris.isEmpty()) return null
        val persistable =
            intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0
        return C07RawShare(
            action = action,
            subject = subject,
            text = text,
            uriStrings = uris.toList(),
            persistable = persistable,
        )
    }
}

internal enum class C07ProbeKind { PDF, PNG, JPEG, WEBP, GIF, ZIP, TEXT, UNKNOWN }

internal data class C07MimeDecision(
    val mimeType: String?,
    val refusal: C07EntryRefusal? = null,
)

internal object C07ContentSniffer {
    private const val PROBE_BYTES = 4_096
    private val officeMimes = setOf(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )

    fun probe(stream: InputStream): C07ProbeKind {
        val header = ByteArray(PROBE_BYTES)
        var length = 0
        while (length < header.size) {
            val read = stream.read(header, length, header.size - length)
            if (read <= 0) break
            length += read
        }
        if (length <= 0) return C07ProbeKind.UNKNOWN
        if (startsWith(header, length, "%PDF-".toByteArray(Charsets.US_ASCII))) {
            return C07ProbeKind.PDF
        }
        if (length >= 8 &&
            (header[0].toInt() and 0xff) == 0x89 &&
            header[1].toInt() == 'P'.code &&
            header[2].toInt() == 'N'.code &&
            header[3].toInt() == 'G'.code
        ) {
            return C07ProbeKind.PNG
        }
        if (length >= 3 &&
            (header[0].toInt() and 0xff) == 0xFF &&
            (header[1].toInt() and 0xff) == 0xD8 &&
            (header[2].toInt() and 0xff) == 0xFF
        ) {
            return C07ProbeKind.JPEG
        }
        if (length >= 12 &&
            header.copyOfRange(0, 4).contentEquals("RIFF".toByteArray(Charsets.US_ASCII)) &&
            header.copyOfRange(8, 12).contentEquals("WEBP".toByteArray(Charsets.US_ASCII))
        ) {
            return C07ProbeKind.WEBP
        }
        if (length >= 6 &&
            header.copyOfRange(0, 6).contentEquals("GIF87a".toByteArray(Charsets.US_ASCII))
        ) {
            return C07ProbeKind.GIF
        }
        if (length >= 6 &&
            header.copyOfRange(0, 6).contentEquals("GIF89a".toByteArray(Charsets.US_ASCII))
        ) {
            return C07ProbeKind.GIF
        }
        if (length >= 4 &&
            header[0].toInt() == 'P'.code &&
            header[1].toInt() == 'K'.code &&
            ((header[2].toInt() == 3 && header[3].toInt() == 4) ||
                (header[2].toInt() == 5 && header[3].toInt() == 6) ||
                (header[2].toInt() == 7 && header[3].toInt() == 8))
        ) {
            return C07ProbeKind.ZIP
        }
        if (validUtf8Prefix(header, length) && header.copyOf(length).none { it.toInt() == 0 }) {
            return C07ProbeKind.TEXT
        }
        return C07ProbeKind.UNKNOWN
    }

    /**
     * Reconciles the provider's untrusted type with the actual bytes. A known
     * concrete type must match its magic; a ZIP container may be declared as
     * docx/xlsx/pptx/zip; an unknown declaration is resolved from magic.
     */
    fun reconcile(
        declaredRaw: String?,
        kind: C07ProbeKind,
        displayName: String,
    ): C07MimeDecision {
        val declared = C07SharePolicy.normalizeMime(declaredRaw)
        val detected = detectedMime(kind, displayName)
        val finalMime = when {
            declared.isEmpty() || declared == "application/octet-stream" -> detected
            declared == "text/plain" -> "text/plain".takeIf { kind == C07ProbeKind.TEXT }
            declared == "application/pdf" -> "application/pdf".takeIf { kind == C07ProbeKind.PDF }
            declared == "image/png" -> "image/png".takeIf { kind == C07ProbeKind.PNG }
            declared == "image/jpeg" -> "image/jpeg".takeIf { kind == C07ProbeKind.JPEG }
            declared == "image/webp" -> "image/webp".takeIf { kind == C07ProbeKind.WEBP }
            declared == "image/gif" -> "image/gif".takeIf { kind == C07ProbeKind.GIF }
            declared == "application/zip" -> {
                if (kind == C07ProbeKind.ZIP) {
                    zipMime(C07SharePolicy.extension(displayName)) ?: "application/zip"
                } else {
                    null
                }
            }
            declared in officeMimes -> declared.takeIf { kind == C07ProbeKind.ZIP }
            else -> null
        }
        if (finalMime == null) {
            val refusal = if (kind == C07ProbeKind.UNKNOWN) {
                C07EntryRefusal.UNSUPPORTED
            } else {
                C07EntryRefusal.CONTENT_MISMATCH
            }
            return C07MimeDecision(null, refusal)
        }
        if (!C07SharePolicy.isSupported(finalMime, displayName)) {
            return C07MimeDecision(null, C07EntryRefusal.UNSUPPORTED)
        }
        return C07MimeDecision(finalMime)
    }

    private fun detectedMime(kind: C07ProbeKind, displayName: String): String? = when (kind) {
        C07ProbeKind.PDF -> "application/pdf"
        C07ProbeKind.PNG -> "image/png"
        C07ProbeKind.JPEG -> "image/jpeg"
        C07ProbeKind.WEBP -> "image/webp"
        C07ProbeKind.GIF -> "image/gif"
        C07ProbeKind.TEXT -> "text/plain"
        C07ProbeKind.ZIP -> zipMime(C07SharePolicy.extension(displayName))
            ?: "application/zip"
        C07ProbeKind.UNKNOWN -> null
    }

    /** ZIP bytes can only refine to the ZIP-container family. A ZIP renamed
     * .pdf is never accepted as a PDF. */
    private fun zipMime(extension: String): String? = when (extension) {
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "zip" -> "application/zip"
        else -> null
    }

    private fun startsWith(bytes: ByteArray, length: Int, prefix: ByteArray): Boolean {
        if (length < prefix.size) return false
        for (index in prefix.indices) {
            if (bytes[index] != prefix[index]) return false
        }
        return true
    }

    private fun validUtf8Prefix(bytes: ByteArray, length: Int): Boolean {
        var index = 0
        while (index < length) {
            val value = bytes[index].toInt() and 0xff
            if (value < 0x80) {
                index += 1
                continue
            }
            val continuation = when {
                value in 0xC2..0xDF -> 1
                value in 0xE0..0xEF -> 2
                value in 0xF0..0xF4 -> 3
                else -> return false
            }
            if (index + continuation >= length) return true
            for (offset in 1..continuation) {
                if (bytes[index + offset].toInt() and 0xC0 != 0x80) return false
            }
            index += continuation + 1
        }
        return true
    }
}

internal class C07EntryImportException(
    val refusal: C07EntryRefusal,
    cause: Throwable? = null,
) : Exception(null, cause)

internal class C07EntryByteBudget(private var remaining: Long) {
    fun consume(bytes: Long) {
        if (bytes < 0L || bytes > remaining) {
            throw C07EntryImportException(C07EntryRefusal.TOO_LARGE)
        }
        remaining -= bytes
    }
}

internal object C07EntryMerge {
    /** Returns null only when the merged Home draft would exceed the same
     * 1 MiB text ceiling the share intake enforces. */
    fun text(existing: String, incoming: String): String? {
        val addition = incoming.trim()
        if (addition.isEmpty()) return existing
        val merged = when {
            existing.isBlank() -> addition
            existing.endsWith("\n\n") -> existing + addition
            existing.endsWith("\n") -> existing + "\n" + addition
            else -> existing + "\n\n" + addition
        }
        return merged.takeIf {
            it.toByteArray(Charsets.UTF_8).size <= ENTRY_MAX_TEXT_BYTES
        }
    }
}

internal fun c07StableDocumentID(intakeID: String, key: String): String =
    UUID.nameUUIDFromBytes("floe-entry:$intakeID:$key".toByteArray(Charsets.UTF_8)).toString()

internal data class C07EntryImportRequest(
    val intakeID: String,
    val subject: String?,
    val items: List<C07EntryCapturedItem>,
    val defaultTextTitle: String = "Shared content",
)

/**
 * Real Notes destination over the existing `NotesService` import/create API.
 * Each item has a deterministic planned document id, so a retry after a
 * process restart skips an already-committed note instead of duplicating it.
 */
internal class C07EntryNotesImporter(
    private val resolver: ContentResolver,
    private val cacheDir: File,
) {
    private val officeMimes = setOf(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )

    suspend fun import(request: C07EntryImportRequest, notes: NotesService): Int {
        var saved = 0
        val budget = C07EntryByteBudget(ENTRY_MAX_TOTAL_BYTES)
        val text = request.items.filter { it.kind == C07EntryItemKind.TEXT }
            .mapNotNull { it.text }
            .joinToString("\n\n")
            .trim()
        if (text.isNotEmpty()) {
            val documentID = c07StableDocumentID(request.intakeID, "text")
            if (!noteExists(notes, documentID)) {
                val created = try {
                    notes.saveMessage(
                        NotesSaveMessage(
                            text = text,
                            title = textTitle(request.subject, request.defaultTextTitle),
                            documentID = documentID,
                        ),
                    )
                } catch (error: Throwable) {
                    throw mapNotesError(error)
                }
                if (created.id != documentID) {
                    throw C07EntryImportException(C07EntryRefusal.FAILED)
                }
            }
            saved += 1
        }
        for (item in request.items.filter { it.kind == C07EntryItemKind.FILE }) {
            currentCoroutineContext().ensureActive()
            val documentID = c07StableDocumentID(request.intakeID, "file:${item.index}")
            if (noteExists(notes, documentID)) {
                saved += 1
                continue
            }
            val resource = importResource(notes, item, budget)
            try {
                val created = notes.createDocument(
                    NotesCreateDocument(
                        kind = kindFor(item.mimeType),
                        title = C07SharePolicy.noteTitle(item.displayName),
                        documentID = documentID,
                        resourceID = resource.resourceID,
                        fileName = item.displayName,
                    ),
                )
                if (created.id != documentID) {
                    throw C07EntryImportException(C07EntryRefusal.FAILED)
                }
            } catch (error: Throwable) {
                try { notes.discardUnreferencedResource(resource.resourceID) } catch (_: Throwable) { }
                throw mapNotesError(error)
            }
            saved += 1
        }
        return saved
    }

    private suspend fun noteExists(notes: NotesService, documentID: String): Boolean {
        return try {
            notes.documentSummary(documentID).deletedAt == null
        } catch (error: NotesException) {
            when (error.code) {
                "notFound", "documentNotFound" -> false
                "notesNotBound", "staleGeneration" ->
                    throw C07EntryImportException(C07EntryRefusal.NOTES_UNAVAILABLE, error)
                else -> throw C07EntryImportException(C07EntryRefusal.FAILED, error)
            }
        } catch (error: Throwable) {
            throw mapNotesError(error)
        }
    }

    private suspend fun importResource(
        notes: NotesService,
        item: C07EntryCapturedItem,
        budget: C07EntryByteBudget,
    ): ImportedResource {
        val uri = item.uriString?.let { runCatching { Uri.parse(it) }.getOrNull() }
            ?: throw C07EntryImportException(C07EntryRefusal.UNREADABLE)
        if (uri.scheme != "content") {
            throw C07EntryImportException(C07EntryRefusal.INVALID_URI)
        }
        if (item.declaredBytes > ENTRY_MAX_ITEM_BYTES) {
            throw C07EntryImportException(C07EntryRefusal.TOO_LARGE)
        }
        return try {
            if (item.declaredBytes > 0L) {
                importKnownSize(notes, item, uri, budget)
            } else {
                importUnknownSize(notes, item, uri, budget)
            }
        } catch (error: C07EntryImportException) {
            throw error
        } catch (error: SecurityException) {
            throw C07EntryImportException(C07EntryRefusal.GRANT_REVOKED, error)
        } catch (error: FileNotFoundException) {
            throw C07EntryImportException(C07EntryRefusal.UNREADABLE, error)
        } catch (error: IOException) {
            throw C07EntryImportException(C07EntryRefusal.UNREADABLE, error)
        } catch (error: NotesException) {
            throw mapNotesError(error)
        }
    }

    private suspend fun importKnownSize(
        notes: NotesService,
        item: C07EntryCapturedItem,
        uri: Uri,
        budget: C07EntryByteBudget,
    ): ImportedResource {
        val declared = item.declaredBytes
        val session = try {
            notes.beginResourceImport(item.displayName, item.mimeType, declared)
        } catch (error: Throwable) {
            throw mapNotesError(error)
        }
        var committed = false
        try {
            val input = resolver.openInputStream(uri)
                ?: throw C07EntryImportException(C07EntryRefusal.UNREADABLE)
            input.use { stream ->
                val buffer = ByteArray(minOf(session.chunkBytes, MAX_COPY_CHUNK).coerceAtLeast(1))
                var remaining = declared
                while (remaining > 0L) {
                    currentCoroutineContext().ensureActive()
                    val request = minOf(buffer.size.toLong(), remaining).toInt().coerceAtLeast(1)
                    val read = stream.read(buffer, 0, request)
                    if (read <= 0) throw C07EntryImportException(C07EntryRefusal.UNREADABLE)
                    budget.consume(read.toLong())
                    session.append(buffer.copyOf(read))
                    remaining -= read
                }
                // A provider that declared a smaller size must not silently
                // truncate the original. One EOF probe is bounded for a
                // file-like content stream; a short/extra stream is refused.
                if (stream.read() != -1) {
                    throw C07EntryImportException(C07EntryRefusal.UNREADABLE)
                }
            }
            val resource = session.commit()
            committed = true
            if (resource.byteCount != declared) {
                try { notes.discardUnreferencedResource(resource.resourceID) } catch (_: Throwable) { }
                throw C07EntryImportException(C07EntryRefusal.FAILED)
            }
            return resource
        } finally {
            if (!committed) {
                try { session.abort() } catch (_: Throwable) { }
            }
        }
    }

    /**
     * A provider that cannot report a size is copied once into a bounded
     * App-private temp file (64 MiB per-item, 128 MiB intake total), then read
     * through the SAME Notes staging API. The temp file is deleted on every
     * path and is never a durable second store.
     */
    private suspend fun importUnknownSize(
        notes: NotesService,
        item: C07EntryCapturedItem,
        uri: Uri,
        budget: C07EntryByteBudget,
    ): ImportedResource {
        val dir = File(cacheDir, "entryflow").apply { mkdirs() }
        val temp = File(dir, "spool-" + UUID.randomUUID() + ".tmp")
        try {
            var total = 0L
            val input = resolver.openInputStream(uri)
                ?: throw C07EntryImportException(C07EntryRefusal.UNREADABLE)
            input.use { stream ->
                temp.outputStream().use { output ->
                    val buffer = ByteArray(MAX_COPY_CHUNK)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = stream.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        total += read
                        if (total > ENTRY_MAX_ITEM_BYTES) {
                            throw C07EntryImportException(C07EntryRefusal.TOO_LARGE)
                        }
                        budget.consume(read.toLong())
                        output.write(buffer, 0, read)
                    }
                }
            }
            if (total <= 0L) throw C07EntryImportException(C07EntryRefusal.EMPTY)
            val session = try {
                notes.beginResourceImport(item.displayName, item.mimeType, total)
            } catch (error: Throwable) {
                throw mapNotesError(error)
            }
            var committed = false
            try {
                temp.inputStream().use { stream ->
                    val buffer = ByteArray(minOf(session.chunkBytes, MAX_COPY_CHUNK).coerceAtLeast(1))
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = stream.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        session.append(buffer.copyOf(read))
                    }
                }
                val resource = session.commit()
                committed = true
                if (resource.byteCount != total) {
                    try { notes.discardUnreferencedResource(resource.resourceID) } catch (_: Throwable) { }
                    throw C07EntryImportException(C07EntryRefusal.FAILED)
                }
                return resource
            } finally {
                if (!committed) {
                    try { session.abort() } catch (_: Throwable) { }
                }
            }
        } finally {
            temp.delete()
        }
    }

    private fun kindFor(mimeType: String): NoteDocumentKind =
        if (mimeType in officeMimes) NoteDocumentKind.OFFICE else NoteDocumentKind.ENGINEERING

    private fun textTitle(subject: String?, fallback: String): String {
        val cleaned = subject.orEmpty()
            .filter { it.code >= 0x20 && it.code != 0x7F }
            .trim()
            .take(120)
        return cleaned.ifBlank { fallback.take(120).ifBlank { "Shared content" } }
    }

    private fun mapNotesError(error: Throwable): C07EntryImportException {
        if (error is kotlinx.coroutines.CancellationException) throw error
        if (error is C07EntryImportException) return error
        if (error is SecurityException) {
            return C07EntryImportException(C07EntryRefusal.GRANT_REVOKED, error)
        }
        if (error is NotesException) {
            return when (error.code) {
                "notesNotBound", "staleGeneration" ->
                    C07EntryImportException(C07EntryRefusal.NOTES_UNAVAILABLE, error)
                else -> C07EntryImportException(C07EntryRefusal.FAILED, error)
            }
        }
        return C07EntryImportException(C07EntryRefusal.FAILED, error)
    }

    private companion object {
        const val MAX_COPY_CHUNK = 64 * 1024
    }
}
