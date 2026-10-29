// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.IBinder
import com.floe.android.core.officeengine.OfficeCloseAck
import com.floe.android.core.officeengine.OfficeEngine
import com.floe.android.core.officeengine.OfficeEngineCommands
import com.floe.android.core.officeengine.OfficeHostSaveChannel
import com.floe.android.core.officeengine.OfficeHostSaveHandoffPolicy
import com.floe.android.core.officeengine.OfficeHostSaveVerdict
import com.floe.android.core.officeengine.OfficePermission
import com.floe.android.core.officeengine.OfficePreviewRequest
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.core.officeengine.OfficeViewerOutcome
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankKind
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeCreateBlankRequest
import com.floe.android.feature.notes.ui.api.NotesOfficeEditOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeEditRequest
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexingPort
import com.floe.android.feature.notes.ui.api.NotesOfficePort
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Real Office effects.
 *
 * `createBlank` authors a validated minimal OOXML container (no host Python,
 * no macro, no model code execution). `edit` copies the immutable Notes
 * resource into an App-private writable working copy, opens the EXISTING
 * `:floe_office` viewer with `OfficePermission.EDIT`, and wires the viewer's
 * own Save-Copy handoff back to a bounded SAF write + readback. The App-side
 * settlement (transaction 26 on the existing engine command binder) is what
 * authorizes the viewer's close-after-save; only then does the port return the
 * saved bytes.
 *
 * It never imports a discarded/autosaved working copy: without a completed
 * App settlement for this exact session, a changed working copy is reported as
 * typed `unsavedAtClose` and retained for recovery. That is the honest
 * consequence of the existing viewer's dirty-close contract.
 */
internal class NotesOfficeEffects(
    private val context: Context,
    private val broker: NotesPlatformActivityBroker,
    private val scope: CoroutineScope,
    private val stagingRoot: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /**
     * The SAME real Notes authority the editor uses. It is required only by
     * the additive full-text indexing capability; the viewer/save-copy routes
     * never read or write the library through it.
     */
    private val notes: NotesService,
) : NotesOfficePort, NotesOfficeIndexingPort, AutoCloseable {

    private val officeRoot = File(stagingRoot, "office")
    private val blankRoot = File(officeRoot, "blank")
    private val editRoot = File(officeRoot, "edit")
    private val outputRoot = File(officeRoot, "output")

    /**
     * Bounded, read-only extraction over the exact immutable resource. It
     * writes ONLY through the native Office-text cache; the original file and
     * the user's saved copy are never modified.
     */
    private val indexer = NotesOfficeIndexer(
        service = notes,
        workRoot = officeRoot,
        ioDispatcher = ioDispatcher,
    )

    private val incarnation = AtomicLong(0L)
    private val activeLock = Any()
    private var activeToken: String? = null
    private var activeIncarnation: Long = 0L
    private var activeViewing: Boolean = false

    private val receipts = ConcurrentHashMap<String, OfficeSaveReceipt>()
    private val settledCopies = ConcurrentHashMap<String, SettledCopy>()
    /** One signal per edit session; completed with the settled copy (or null). */
    private val settlementSignals = ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<SettledCopy?>>()

    private val closeAck = OfficeCloseAck.parentBinder { ack ->
        synchronized(activeLock) {
            activeViewing &&
                ack.sessionToken == activeToken &&
                ack.viewerIncarnation == activeIncarnation
        }
    }

    override suspend fun createBlank(request: NotesOfficeCreateBlankRequest): NotesOfficeBlankOutcome {
        val kind = when (request.kind) {
            NotesOfficeBlankKind.WORD -> NotesOoxmlKind.DOCX
            NotesOfficeBlankKind.SHEET -> NotesOoxmlKind.XLSX
            NotesOfficeBlankKind.SLIDES -> NotesOoxmlKind.PPTX
        }
        return try {
            val bytes = withContext(ioDispatcher) {
                NotesOoxmlTemplates.create(kind, request.title)
            }
            val validation = withContext(ioDispatcher) { NotesOoxmlTemplates.validate(bytes, kind) }
            if (!validation.ok) {
                return NotesOfficeBlankOutcome.Failed(
                    NotesPortFailure(NotesPortFailure.FAILED, "blankInvalid:" + validation.reason),
                )
            }
            withContext(ioDispatcher) {
                val work = NotesPlatformFiles.newWorkDirectory(blankRoot, "blank")
                try {
                    val fileName = NotesPlatformNames.safeFileName(request.title, "Untitled", kind.extension)
                    val file = File(work, fileName)
                    NotesPlatformFiles.writeAtomicDurable(file, bytes)
                    if (file.length() != bytes.size.toLong() || !NotesPlatformFiles.isPlainFile(
                            file,
                            NotesPlatformFiles.MAX_OFFICE_BYTES,
                        )
                    ) {
                        throw NotesPlatformErrors.failed("blankReadback")
                    }
                    NotesOfficeBlankOutcome.Created(
                        pickedFile(file, NotesPlatformNames.safeFileName(fileName), kind.mimeType, work),
                    )
                } catch (error: Throwable) {
                    NotesPlatformFiles.deleteQuietly(work)
                    throw error
                }
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = NotesPlatformErrors.notes(error, "blankCreateFailed").failure
            NotesOfficeBlankOutcome.Failed(failure)
        }
    }

    override suspend fun edit(request: NotesOfficeEditRequest): NotesOfficeEditOutcome {
        val kind = NotesOoxmlKind.forExtension(request.fileName)
            ?: NotesOoxmlKind.forExtension(NotesPlatformNames.extensionOf(request.fileName))
            ?: NotesOoxmlTemplates.kindForMime(request.mediaType)
            ?: return NotesOfficeEditOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.UNSUPPORTED, "officeFormat"),
            )
        if (request.byteCount <= 0L || request.byteCount > NotesPlatformFiles.MAX_OFFICE_BYTES) {
            return NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.UNSUPPORTED, "officeSize"))
        }
        if (request.sha256.length != 64 || request.sha256.any { it !in '0'..'9' && it !in 'a'..'f' }) {
            return NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "invalidDigest"))
        }
        val work = withContext(ioDispatcher) {
            NotesPlatformFiles.newWorkDirectory(editRoot, "edit")
        }
        var commands: OfficeEngineCommands? = null
        var unbind: (() -> Unit)? = null
        var working: File? = null
        return try {
            val staged = withContext(ioDispatcher) {
                val fileName = "document." + kind.extension
                val file = File(work, fileName)
                val staged = NotesPlatformFiles.copyFromReader(
                    destination = file,
                    maxBytes = NotesPlatformFiles.MAX_OFFICE_BYTES,
                    read = { offset, maxBytes -> request.read.read(request.resourceID, offset, maxBytes) },
                )
                if (staged.byteCount != request.byteCount || staged.sha256 != request.sha256) {
                    throw NotesPlatformErrors.failed("sourceChanged")
                }
                if (!file.setWritable(true, true)) throw NotesPlatformErrors.failed("workingCopyReadOnly")
                staged
            }
            working = staged.file
            val canonical = staged.file.canonicalFile
            if (!canonical.isFile || canonical.length() != staged.byteCount) {
                throw NotesPlatformErrors.failed("workingCopyMissing")
            }
            val sessionToken = UUID.randomUUID().toString()
            val activeInc = incarnation.incrementAndGet()
            activeToken = sessionToken
            activeIncarnation = activeInc
            activeViewing = true
            receipts.clear()
            settledCopies.clear()
            settlementSignals.clear()

            val requestResult = OfficePreviewRequest.of(
                sessionToken = sessionToken,
                stagedFilePath = canonical.path,
                sha256 = staged.sha256,
                lengthBytes = staged.byteCount,
                displayName = NotesPlatformNames.safeFileName(request.fileName, "document", kind.extension),
                languageTag = Locale.getDefault().toLanguageTag(),
                permission = OfficePermission.EDIT,
            )
            val previewRequest = requestResult.getOrElse {
                throw NotesPlatformErrors.failed("officeRequestShape")
            }
            val bound = bindCommands()
            commands = bound?.first
            unbind = bound?.second
            if (commands == null) {
                throw NotesPlatformErrors.unavailable("officeCommandChannel")
            }
            val channel = OfficeHostSaveChannel.parentBinder(
                onPrepare = { prepare ->
                    if (prepare.sessionToken != sessionToken) {
                        null
                    } else {
                        createDocumentIntent(prepare)
                    }
                },
                onPickResult = { result ->
                    if (result.sessionToken != sessionToken) {
                        false
                    } else {
                        settlementSignals.getOrPut(sessionToken) { CompletableDeferred() }
                        val boundCommands = commands
                        scope.launch(ioDispatcher) {
                            handlePickResult(
                                sessionToken = sessionToken,
                                result = result,
                                commands = boundCommands,
                            )
                        }
                        true
                    }
                },
                onReceipt = { receipt ->
                    if (receipt.sessionToken == sessionToken &&
                        receipt.state == OfficeSaveState.OUTPUT_READY
                    ) {
                        receipts[receipt.opId] = receipt
                    }
                },
            )
            val intent = OfficeEngine.viewerIntent(
                context = context,
                request = previewRequest,
                closeAck = closeAck,
                viewerIncarnation = activeInc,
                hostSaveChannel = channel,
            )
            val activityResult = try {
                withTimeoutOrNull(EDITOR_TIMEOUT_MILLIS) {
                    broker.launch(NotesLaunchLane.OFFICE_VIEWER, intent)
                } ?: NotesLaunchResult(Activity.RESULT_CANCELED, null)
            } finally {
                synchronized(activeLock) {
                    activeViewing = false
                    activeToken = null
                    activeIncarnation = 0L
                }
            }
            val outcome = OfficeViewerOutcome.fromResultData(activityResult.data)
            val afterSha = withContext(ioDispatcher) {
                if (canonical.isFile) NotesPlatformFiles.sha256(canonical) else null
            }
            val digestChanged = afterSha != null && afterSha != staged.sha256
            val signal = settlementSignals[sessionToken]
            val awaited = if (signal != null) {
                withTimeoutOrNull(5_000L) { signal.await() }
            } else {
                null
            }
            val settled = (awaited ?: settledCopies[sessionToken])?.takeIf { it.verified }
            val validOoxml = if (settled != null) {
                withContext(ioDispatcher) {
                    val source = settled.file?.takeIf { it.isFile } ?: canonical
                    validateOfficeFile(source, kind)
                }
            } else {
                true
            }
            val decision = NotesOfficeReadbackPolicy.decide(
                resultPresent = outcome != null,
                tokenMatches = outcome?.sessionToken == sessionToken,
                closedCleanly = outcome?.closedCleanly == true,
                failureCode = outcome?.failure?.name,
                digestChanged = digestChanged,
                explicitSaveCompleted = settled != null,
                validOoxml = validOoxml,
            )
            when (decision) {
                NotesOfficeReadbackDecision.SAVED -> {
                    val saved = settled
                        ?: return NotesOfficeEditOutcome.Failed(
                            NotesPortFailure(NotesPortFailure.FAILED, "savedCopyMissing"),
                        )
                    withContext(ioDispatcher) {
                        val output = saved.file
                            ?: throw NotesPlatformErrors.failed("savedCopyMissing")
                        if (!NotesPlatformFiles.isPlainFile(output, NotesPlatformFiles.MAX_OFFICE_BYTES) ||
                            NotesPlatformFiles.sha256(output) != saved.sha256 ||
                            output.length() != saved.byteCount
                        ) {
                            throw NotesPlatformErrors.failed("savedCopyChanged")
                        }
                        val fileName = NotesPlatformNames.safeFileName(
                            request.fileName,
                            "document",
                            kind.extension,
                        )
                        output.setReadable(true, true)
                        output.setWritable(false, false)
                        NotesPlatformFiles.deleteQuietly(work)
                        val directory = saved.directory
                            ?: throw NotesPlatformErrors.failed("savedCopyDirectory")
                        NotesOfficeEditOutcome.Saved(
                            file = pickedFile(output, fileName, kind.mimeType, directory),
                            fileName = fileName,
                            mediaType = kind.mimeType,
                            preview = null,
                        )
                    }
                }
                NotesOfficeReadbackDecision.UNCHANGED -> {
                    NotesPlatformFiles.deleteQuietly(work)
                    NotesOfficeEditOutcome.ClosedWithoutChanges
                }
                NotesOfficeReadbackDecision.UNSAVED_AT_CLOSE ->
                    NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "unsavedAtClose"))
                NotesOfficeReadbackDecision.INVALID_SAVED_COPY ->
                    NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "invalidSavedCopy"))
                NotesOfficeReadbackDecision.MISSING_RESULT ->
                    NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "editorResultMissing"))
                NotesOfficeReadbackDecision.STALE_RESULT ->
                    NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "staleEditorResult"))
                NotesOfficeReadbackDecision.EDITOR_UNCLEAN ->
                    NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "editorClosedUncleanly"))
                NotesOfficeReadbackDecision.EDITOR_FAILED -> mapEditorFailure(outcome?.failure?.name)
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (working == null) NotesPlatformFiles.deleteQuietly(work)
            val failure = NotesPlatformErrors.notes(error, "officeEditFailed").failure
            NotesOfficeEditOutcome.Failed(failure)
        } finally {
            synchronized(activeLock) {
                activeViewing = false
                activeToken = null
                activeIncarnation = 0L
            }
            runCatching { unbind?.invoke() }
            // A retained working copy is intentional on failure paths; the
            // sweep below is bounded and only removes week-old files.
            NotesPlatformFiles.sweepOlderThan(editRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
        }
    }

    /* --------------------------- text indexing ---------------------------- */

    /**
     * Format admission for the additive index capability. It never opens the
     * file; a legacy binary or unknown package answers false and the editor
     * simply keeps no index for it (never a fake empty one).
     */
    override fun supports(fileName: String?, mediaType: String?): Boolean =
        NotesOfficeIndex.formatFor(fileName, mediaType) != null

    override suspend fun index(
        documentID: String,
        sourceResourceID: String,
        expectedRevision: Int,
    ): NotesOfficeIndexOutcome = indexer.index(documentID, sourceResourceID, expectedRevision)

    override fun close() {
        NotesPlatformFiles.sweepOlderThan(blankRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
        NotesPlatformFiles.sweepOlderThan(editRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
        NotesPlatformFiles.sweepOlderThan(outputRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
        NotesPlatformFiles.sweepOlderThan(File(officeRoot, "index"), NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
    }

    /* ----------------------------- host save ------------------------------ */

    private suspend fun handlePickResult(
        sessionToken: String,
        result: OfficeHostSaveHandoffPolicy.PickResult,
        commands: OfficeEngineCommands?,
    ) {
        if (commands == null) return
        val opId = result.opId
        if (result.resultCode != Activity.RESULT_OK || result.uriString == null) {
            commands.settleHostSaveCopy(
                opId, sessionToken, result.generation, OfficeHostSaveVerdict.COPY_CANCELLED, "cancelled",
            )
            settlementSignals[sessionToken]?.complete(null)
            return
        }
        val receipt = awaitReceipt(opId, sessionToken)
        if (receipt == null || receipt.outputDocumentPath == null ||
            receipt.outputSha256 == null || receipt.outputBytes <= 0L
        ) {
            commands.settleHostSaveCopy(
                opId, sessionToken, result.generation, OfficeHostSaveVerdict.COPY_FAILED, "outputUnavailable",
            )
            settlementSignals[sessionToken]?.complete(null)
            return
        }
        val uri = runCatching { Uri.parse(result.uriString) }.getOrNull()
        val copied = if (uri != null) copyToSaf(uri, receipt) else false
        if (copied) {
            val source = runCatching { File(receipt.outputDocumentPath!!).canonicalFile }.getOrNull()
            val local = withContext(ioDispatcher) {
                if (source == null) return@withContext null
                val directory = NotesPlatformFiles.newWorkDirectory(outputRoot, "settled")
                try {
                    val name = NotesPlatformNames.safeFileName(
                        receipt.suggestedName,
                        "document",
                        receipt.format ?: "docx",
                    )
                    val target = File(directory, name)
                    val staged = NotesPlatformFiles.copyFileDurable(
                        source,
                        target,
                        NotesPlatformFiles.MAX_OFFICE_BYTES,
                    )
                    target.setReadable(true, true)
                    SettledLocalFile(target, directory, staged.sha256, staged.byteCount)
                } catch (_: Throwable) {
                    NotesPlatformFiles.deleteQuietly(directory)
                    null
                }
            }
            val verified = commands.settleHostSaveCopy(
                opId, sessionToken, result.generation, OfficeHostSaveVerdict.COPY_SAVED, null,
            )
            val accepted = verified && local != null &&
                local.sha256 == receipt.outputSha256 && local.byteCount == receipt.outputBytes
            val copy = SettledCopy(
                opId = opId,
                file = local?.file,
                directory = local?.directory,
                sha256 = receipt.outputSha256!!,
                byteCount = receipt.outputBytes,
                verified = accepted,
            )
            if (copy.verified) {
                settledCopies[sessionToken] = copy
                settlementSignals[sessionToken]?.complete(copy)
            } else {
                settlementSignals[sessionToken]?.complete(null)
            }
        } else {
            commands.settleHostSaveCopy(
                opId, sessionToken, result.generation, OfficeHostSaveVerdict.COPY_FAILED, "copyVerifyFailed",
            )
            settlementSignals[sessionToken]?.complete(null)
        }
    }

    private suspend fun awaitReceipt(opId: String, sessionToken: String): OfficeSaveReceipt? {
        val deadline = System.currentTimeMillis() + 10_000L
        while (System.currentTimeMillis() < deadline) {
            receipts[opId]?.takeIf { it.sessionToken == sessionToken }?.let { return it }
            delay(100L)
        }
        return receipts[opId]
    }

    private suspend fun copyToSaf(
        uri: Uri,
        receipt: OfficeSaveReceipt,
    ): Boolean = withContext(ioDispatcher) {
        val source = runCatching { File(receipt.outputDocumentPath!!).canonicalFile }.getOrNull() ?: return@withContext false
        val dataRoot = runCatching { File(context.applicationInfo.dataDir).canonicalPath }.getOrNull()
            ?: return@withContext false
        if (!source.path.startsWith(dataRoot.trimEnd('/') + "/")) return@withContext false
        if (!NotesPlatformFiles.isPlainFile(source, NotesPlatformFiles.MAX_OFFICE_BYTES)) return@withContext false
        if (source.length() != receipt.outputBytes) return@withContext false
        if (NotesPlatformFiles.sha256(source) != receipt.outputSha256) return@withContext false
        val resolver = context.contentResolver
        try {
            val output = resolver.openOutputStream(uri, "wt")
                ?: resolver.openOutputStream(uri, "w")
                ?: return@withContext false
            try {
                source.inputStream().use { input ->
                    val buffer = ByteArray(NotesPlatformFiles.CHUNK_BYTES)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > NotesPlatformFiles.MAX_OFFICE_BYTES) throw IOException("tooLarge")
                        output.write(buffer, 0, read)
                    }
                }
                output.flush()
                (output as? FileOutputStream)?.fd?.let { runCatching { it.sync() } }
            } finally {
                runCatching { output.close() }
            }
            val readback = resolver.openInputStream(uri) ?: return@withContext false
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            var total = 0L
            readback.use { input ->
                val buffer = ByteArray(NotesPlatformFiles.CHUNK_BYTES)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > NotesPlatformFiles.MAX_OFFICE_BYTES) return@withContext false
                    digest.update(buffer, 0, read)
                }
            }
            total == receipt.outputBytes &&
                NotesPlatformFiles.hex(digest.digest()) == receipt.outputSha256
        } catch (_: Throwable) {
            false
        }
    }

    private fun createDocumentIntent(prepare: OfficeHostSaveHandoffPolicy.PrepareRequest): Intent {
        val mime = NotesPlatformNames.mimeForOfficeExtension(prepare.format)
        return Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(
                Intent.EXTRA_TITLE,
                NotesPlatformNames.safeFileName(
                    prepare.suggestedName,
                    "document",
                    prepare.format,
                ),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    private suspend fun bindCommands(): Pair<OfficeEngineCommands, () -> Unit>? {
        return withTimeoutOrNull(5_000L) { bindCommandsAwait() }
    }

    private suspend fun bindCommandsAwait(): Pair<OfficeEngineCommands, () -> Unit>? {
        return suspendCancellableCoroutine { continuation ->
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                    if (!continuation.isActive) return
                    if (service == null) {
                        continuation.resume(null)
                    } else {
                        continuation.resume(
                            OfficeEngineCommands(service) to {
                                runCatching { context.unbindService(this) }
                            },
                        )
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) = Unit
                override fun onNullBinding(name: ComponentName?) {
                    if (continuation.isActive) continuation.resume(null)
                }
            }
            val bound = runCatching {
                context.bindService(
                    OfficeEngineCommands.bindIntent(context, null),
                    connection,
                    Context.BIND_AUTO_CREATE,
                )
            }.getOrDefault(false)
            if (!bound && continuation.isActive) continuation.resume(null)
            continuation.invokeOnCancellation {
                runCatching { context.unbindService(connection) }
            }
        }
    }

    /* ------------------------------ helpers ------------------------------- */

    private fun pickedFile(file: File, fileName: String, mediaType: String, cleanup: File): NotesPickedFile {
        val reader = StagedFileReader(
            file = file,
            byteCount = file.length(),
            onClose = { NotesPlatformFiles.deleteQuietly(cleanup) },
            ioDispatcher = ioDispatcher,
        )
        return NotesPickedFile(
            fileName = fileName,
            mediaType = mediaType,
            byteCount = file.length(),
            read = { offset, maxBytes -> reader.read(offset, maxBytes) },
            close = { reader.close() },
        )
    }

    private fun validateOfficeFile(file: File, kind: NotesOoxmlKind): Boolean {
        if (!file.isFile || file.length() <= 0L || file.length() > MAX_VALIDATION_BYTES) return false
        return runCatching {
            NotesOoxmlTemplates.validate(file.readBounded(MAX_VALIDATION_BYTES), kind).ok
        }.getOrDefault(false)
    }

    private fun mapEditorFailure(code: String?): NotesOfficeEditOutcome {
        val name = code?.lowercase(Locale.ROOT) ?: "officeFailed"
        return when (code) {
            "UNSUPPORTED_FORMAT" -> NotesOfficeEditOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.UNSUPPORTED, "officeFormat"),
            )
            "ROUTE_UNAVAILABLE" -> NotesOfficeEditOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.UNAVAILABLE, "officeRoute"),
            )
            "ENGINE_BUSY" -> NotesOfficeEditOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.BUSY, "officeBusy"),
            )
            "SESSION_CANCELLED" -> NotesOfficeEditOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.CANCELLED, "officeCancelled"),
            )
            "PAYLOAD_PREPARE_FAILED", "NATIVE_LOAD_FAILED" -> NotesOfficeEditOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.UNAVAILABLE, name),
            )
            else -> NotesOfficeEditOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, name))
        }
    }

    private data class SettledLocalFile(
        val file: File,
        val directory: File,
        val sha256: String,
        val byteCount: Long,
    )

    private data class SettledCopy(
        val opId: String,
        val file: File?,
        val directory: File?,
        val sha256: String,
        val byteCount: Long,
        val verified: Boolean,
    )

    private companion object {
        const val MAX_VALIDATION_BYTES = 64L * 1024 * 1024
        const val EDITOR_TIMEOUT_MILLIS = 60L * 60 * 1000

    }
}
