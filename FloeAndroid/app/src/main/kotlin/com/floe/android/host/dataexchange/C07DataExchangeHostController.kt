// SPDX-License-Identifier: MPL-2.0
//
// App-scoped C07 controller. It owns SAF source/destination access, bounded
// streaming to the native staging/read API, progress/cancel and the byte/hash
// read-back receipt. Job work lives in the Swift domain; this controller keeps
// the active job IDs so a sheet dismissal does not orphan a download.
package com.floe.android.host.dataexchange

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.feature.dataexchange.DataExchangeCanvasUi
import com.floe.android.feature.dataexchange.DataExchangeCapabilitiesUi
import com.floe.android.feature.dataexchange.DataExchangePhase
import com.floe.android.feature.dataexchange.DataExchangePlanUi
import com.floe.android.feature.dataexchange.DataExchangeReceiptUi
import com.floe.android.feature.dataexchange.DataExchangeScopeRow
import com.floe.android.feature.dataexchange.DataExchangeUiState
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class C07DataExchangeHostController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val currentNativeEpoch: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val client: C07DataExchangeClient = C07DataExchangeClient(),
) {
    private val resolver: ContentResolver get() = context.contentResolver
    private val ownerToken = UUID.randomUUID().toString()
    private val _state = MutableStateFlow(DataExchangeUiState())
    val state: StateFlow<DataExchangeUiState> = _state.asStateFlow()

    private val entered = AtomicBoolean(false)
    @Volatile private var lastEpoch: Long = 0
    @Volatile private var cancelRequested = false
    private var activeWork: Job? = null
    private var activeJobID: String? = null
    private var activeStageID: String? = null
    @Volatile private var activeDestinationUri: Uri? = null

    fun enter() {
        if (entered.compareAndSet(false, true)) {
            refresh()
        } else if (!state.value.busy &&
                   state.value.phase != DataExchangePhase.REVIEWING) {
            refresh()
        }
    }

    fun refresh() {
        if (state.value.busy ||
            state.value.phase == DataExchangePhase.REVIEWING) return
        activeWork = scope.launch {
            _state.update {
                it.copy(loading = true, coreReady = false, errorCode = null,
                    noticeCode = null, phase = DataExchangePhase.IDLE)
            }
            try {
                val owner = owner()
                val result = withContext(ioDispatcher) {
                    val capabilities = client.capabilities(owner)
                    val pending = client.pending(owner)
                    capabilities to pending
                }
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = true,
                        capabilities = result.first.toUi(),
                        pendingRecoveries = result.second,
                        phase = DataExchangePhase.IDLE,
                        errorCode = null,
                    )
                }
            } catch (failure: C07ClientFailure) {
                fail(failure)
            } catch (error: Throwable) {
                fail(C07ClientFailure("unknown", error.javaClass.simpleName))
            }
        }
    }

    fun beginBackup(uri: Uri) {
        if (state.value.busy ||
            state.value.phase == DataExchangePhase.REVIEWING) return
        cancelRequested = false
        val owner = try {
            owner()
        } catch (failure: Throwable) {
            fail(failure as? C07ClientFailure
                ?: C07ClientFailure("runtimeNotInstalled", "runtimeNotInstalled"))
            return
        }
        activeWork = scope.launch {
            var jobID: String? = null
            var destinationTouched = false
            try {
                _state.update {
                    it.copy(phase = DataExchangePhase.BACKING_UP, progressDone = 0,
                        progressTotal = 0, errorCode = null, noticeCode = null,
                        backupBytes = null, backupSha256 = null,
                        backupWarnings = emptyList(), resultWarnings = emptyList(),
                        receipt = null)
                }
                val createdJob = withContext(ioDispatcher) {
                    client.backupBegin(owner, includeRetainedProjects = true)
                }
                jobID = createdJob
                activeJobID = createdJob
                val job = awaitJob(owner, createdJob) { progress ->
                    _state.update {
                        it.copy(
                            progressDone = progress.doneBytes,
                            progressTotal = progress.totalBytes,
                        )
                    }
                }
                val bytes = job.fileByteCount
                val sha = job.fileSha256
                if (bytes == null || sha == null) {
                    throw C07ClientFailure("invalidReply", "missingFileReceipt")
                }
                destinationTouched = true
                activeDestinationUri = uri
                writeDestination(owner, createdJob, uri, bytes, sha)
                activeDestinationUri = null
                runCatching {
                    withContext(ioDispatcher) { client.close(owner, createdJob) }
                }
                activeJobID = null
                _state.update {
                    it.copy(
                        phase = DataExchangePhase.IDLE,
                        backupBytes = bytes,
                        backupSha256 = sha,
                        backupWarnings = job.warnings,
                        noticeCode = "backupSaved",
                        progressDone = bytes,
                        progressTotal = bytes,
                    )
                }
            } catch (cancelled: CancellationException) {
                jobID?.let {
                    runCatching {
                        withContext(NonCancellable + ioDispatcher) { client.cancel(owner, it) }
                    }
                }
                if (destinationTouched) deleteDestination(uri)
                _state.update {
                    it.copy(phase = DataExchangePhase.IDLE,
                        noticeCode = if (destinationTouched) "partialFile" else "cancelled",
                        errorCode = null)
                }
            } catch (failure: C07ClientFailure) {
                jobID?.let { runCatching { withContext(ioDispatcher) { client.cancel(owner, it) } } }
                if (destinationTouched) deleteDestination(uri)
                fail(failure, notice = if (destinationTouched) "partialFile" else null)
            } catch (error: Throwable) {
                jobID?.let { runCatching { withContext(ioDispatcher) { client.cancel(owner, it) } } }
                if (destinationTouched) deleteDestination(uri)
                fail(C07ClientFailure("unknown", error.javaClass.simpleName),
                    notice = if (destinationTouched) "partialFile" else null)
            } finally {
                activeJobID = null
                activeStageID = null
                activeDestinationUri = null
            }
        }
    }

    fun cancelBackup() {
        cancelRequested = true
        activeWork?.cancel()
        val owner = runCatching { owner() }.getOrNull() ?: return
        val jobID = activeJobID ?: return
        scope.launch {
            runCatching { withContext(ioDispatcher) { client.cancel(owner, jobID) } }
        }
    }

    fun loadCanvases() {
        if (state.value.busy) return
        val owner = runCatching { owner() }.getOrNull() ?: return
        scope.launch {
            try {
                val choices = withContext(ioDispatcher) { client.canvases(owner) }
                _state.update {
                    it.copy(canvases = choices.map {
                        DataExchangeCanvasUi(it.canvasID, it.name)
                    })
                }
            } catch (_: Throwable) {
                _state.update { it.copy(canvases = emptyList()) }
            }
        }
    }

    fun beginCanvasExport(uri: Uri, canvasID: String) {
        if (state.value.busy ||
            state.value.phase == DataExchangePhase.REVIEWING) return
        cancelRequested = false
        val owner = try {
            owner()
        } catch (failure: Throwable) {
            fail(failure as? C07ClientFailure
                ?: C07ClientFailure("runtimeNotInstalled", "runtimeNotInstalled"))
            return
        }
        activeWork = scope.launch {
            var jobID: String? = null
            var destinationTouched = false
            try {
                _state.update {
                    it.copy(phase = DataExchangePhase.BACKING_UP, progressDone = 0,
                        progressTotal = 0, errorCode = null, noticeCode = null,
                        backupBytes = null, backupSha256 = null,
                        backupWarnings = emptyList(), resultWarnings = emptyList(),
                        receipt = null)
                }
                val createdJob = withContext(ioDispatcher) {
                    client.canvasExportBegin(owner, canvasID)
                }
                jobID = createdJob
                activeJobID = createdJob
                val job = awaitJob(owner, createdJob) { progress ->
                    _state.update {
                        it.copy(progressDone = progress.doneBytes,
                            progressTotal = progress.totalBytes)
                    }
                }
                val bytes = job.fileByteCount
                val sha = job.fileSha256
                if (bytes == null || sha == null) {
                    throw C07ClientFailure("invalidReply", "missingFileReceipt")
                }
                destinationTouched = true
                activeDestinationUri = uri
                writeDestination(owner, createdJob, uri, bytes, sha)
                activeDestinationUri = null
                runCatching {
                    withContext(ioDispatcher) { client.close(owner, createdJob) }
                }
                activeJobID = null
                _state.update {
                    it.copy(
                        phase = DataExchangePhase.IDLE,
                        backupBytes = bytes,
                        backupSha256 = sha,
                        noticeCode = "canvasExported",
                        progressDone = bytes,
                        progressTotal = bytes,
                    )
                }
            } catch (cancelled: CancellationException) {
                jobID?.let {
                    runCatching {
                        withContext(NonCancellable + ioDispatcher) { client.cancel(owner, it) }
                    }
                }
                if (destinationTouched) deleteDestination(uri)
                _state.update {
                    it.copy(phase = DataExchangePhase.IDLE,
                        noticeCode = if (destinationTouched) "partialFile" else "cancelled",
                        errorCode = null)
                }
            } catch (failure: C07ClientFailure) {
                jobID?.let { runCatching { withContext(ioDispatcher) { client.cancel(owner, it) } } }
                if (destinationTouched) deleteDestination(uri)
                fail(failure, notice = if (destinationTouched) "partialFile" else null)
            } catch (error: Throwable) {
                jobID?.let { runCatching { withContext(ioDispatcher) { client.cancel(owner, it) } } }
                if (destinationTouched) deleteDestination(uri)
                fail(C07ClientFailure("unknown", error.javaClass.simpleName),
                    notice = if (destinationTouched) "partialFile" else null)
            } finally {
                activeJobID = null
                activeStageID = null
                activeDestinationUri = null
            }
        }
    }

    fun beginRestore(uri: Uri, restoreKind: String = "auto") {
        if (state.value.busy ||
            state.value.phase == DataExchangePhase.REVIEWING) return
        cancelRequested = false
        val rawDisplayName = queryDisplayName(uri)
        val displayName = ensureDocumentExtension(
            rawDisplayName, runCatching { resolver.getType(uri) }.getOrNull(),
            restoreKind)
        val kind = if (restoreKind == "auto") {
            classifyDocument(displayName)
        } else {
            restoreKind
        }
        val importNote = kind == "note"
        val owner = try {
            owner()
        } catch (failure: Throwable) {
            fail(failure as? C07ClientFailure
                ?: C07ClientFailure("runtimeNotInstalled", "runtimeNotInstalled"))
            return
        }
        activeWork = scope.launch {
            var stageID: String? = null
            var upload: UploadSource? = null
            try {
                _state.update {
                    it.copy(phase = DataExchangePhase.INSPECTING, importMode = importNote,
                        documentKind = kind,
                        plan = null, progressDone = 0, progressTotal = 0,
                        errorCode = null, noticeCode = null, receipt = null,
                        resultWarnings = emptyList())
                }
                val prepared = withContext(ioDispatcher) { prepareUpload(uri) }
                upload = prepared
                val total = prepared.size
                val started = withContext(ioDispatcher) { client.stageBegin(owner, total) }
                val createdStage = started.stageID
                stageID = createdStage
                activeStageID = createdStage
                streamToStage(owner, createdStage, prepared, started.chunkBytes)
                withContext(ioDispatcher) { client.stageCommit(owner, createdStage) }
                val jobID = withContext(ioDispatcher) {
                    client.inspect(owner, createdStage, kind, displayName)
                }
                activeJobID = jobID
                activeStageID = null
                val job = awaitJob(owner, jobID) { progress ->
                    _state.update {
                        it.copy(progressDone = progress.doneBytes,
                            progressTotal = progress.totalBytes)
                    }
                }
                val plan = job.plan
                    ?: throw C07ClientFailure("invalidReply", "missingPlan")
                if (kind == "note" &&
                    (plan.projects > 0 || plan.settingsKeys > 0 ||
                        plan.noteDocuments == 0)) {
                    withContext(ioDispatcher) { client.abort(owner, jobID) }
                    activeJobID = null
                    throw C07ClientFailure("invalidFormat", "notNotePackage")
                }
                if (kind == "canvas" && plan.canvasProjects == 0) {
                    withContext(ioDispatcher) { client.abort(owner, jobID) }
                    activeJobID = null
                    throw C07ClientFailure("invalidFormat", "notCanvasPackage")
                }
                if (kind == "document" && plan.projects == 0) {
                    withContext(ioDispatcher) { client.abort(owner, jobID) }
                    activeJobID = null
                    throw C07ClientFailure("invalidFormat", "notDocument")
                }
                _state.update {
                    it.copy(
                        phase = DataExchangePhase.REVIEWING,
                        plan = plan.toUi(job.warnings),
                        progressDone = job.totalBytes,
                        progressTotal = job.totalBytes,
                    )
                }
            } catch (cancelled: CancellationException) {
                stageID?.let {
                    runCatching {
                        withContext(NonCancellable + ioDispatcher) { client.stageAbort(owner, it) }
                    }
                }
                activeJobID?.let {
                    runCatching {
                        withContext(NonCancellable + ioDispatcher) { client.abort(owner, it) }
                    }
                }
                _state.update {
                    it.copy(phase = DataExchangePhase.IDLE, plan = null,
                        noticeCode = "cancelled", errorCode = null)
                }
            } catch (failure: C07ClientFailure) {
                stageID?.let { runCatching { withContext(ioDispatcher) { client.stageAbort(owner, it) } } }
                activeJobID?.let { runCatching { withContext(ioDispatcher) { client.abort(owner, it) } } }
                fail(failure)
            } catch (error: Throwable) {
                stageID?.let { runCatching { withContext(ioDispatcher) { client.stageAbort(owner, it) } } }
                fail(C07ClientFailure("unknown", error.javaClass.simpleName))
            } finally {
                upload?.cleanup()
                activeStageID = null
            }
        }
    }

    fun confirmRestore() {
        val jobID = activeJobID ?: return
        if (state.value.phase != DataExchangePhase.REVIEWING) return
        val owner = try {
            owner()
        } catch (failure: Throwable) {
            fail(failure as? C07ClientFailure
                ?: C07ClientFailure("runtimeNotInstalled", "runtimeNotInstalled"))
            return
        }
        val importMode = state.value.importMode
        val documentKind = state.value.documentKind
        activeWork = scope.launch {
            try {
                _state.update {
                    it.copy(phase = DataExchangePhase.RESTORING,
                        progressDone = 0, progressTotal = 0,
                        errorCode = null, noticeCode = null)
                }
                withContext(ioDispatcher) { client.commit(owner, jobID) }
                val job = awaitJob(owner, jobID) { progress ->
                    _state.update {
                        it.copy(progressDone = progress.doneBytes,
                            progressTotal = progress.totalBytes)
                    }
                }
                val receipt = job.receipt
                    ?: throw C07ClientFailure("invalidReply", "missingReceipt")
                runCatching {
                    withContext(ioDispatcher) { client.close(owner, jobID) }
                }
                activeJobID = null
                _state.update {
                    it.copy(
                        phase = DataExchangePhase.COMPLETE,
                        plan = null,
                        receipt = receipt.toUi(),
                        resultWarnings = job.warnings,
                        noticeCode = when (documentKind) {
                            "note" -> "imported"
                            "canvas" -> "canvasImported"
                            "document" -> "documentImported"
                            else -> "restored"
                        },
                        pendingRecoveries = 0,
                    )
                }
            } catch (cancelled: CancellationException) {
                runCatching {
                    withContext(NonCancellable + ioDispatcher) { client.cancel(owner, jobID) }
                }
                runCatching {
                    withContext(NonCancellable + ioDispatcher) { client.close(owner, jobID) }
                }
                activeJobID = null
                _state.update {
                    it.copy(phase = DataExchangePhase.IDLE, noticeCode = "cancelled")
                }
            } catch (failure: C07ClientFailure) {
                activeJobID?.let {
                    runCatching {
                        withContext(NonCancellable + ioDispatcher) { client.close(owner, it) }
                    }
                }
                activeJobID = null
                fail(failure)
            } catch (error: Throwable) {
                activeJobID?.let {
                    runCatching {
                        withContext(NonCancellable + ioDispatcher) { client.close(owner, it) }
                    }
                }
                activeJobID = null
                fail(C07ClientFailure("unknown", error.javaClass.simpleName))
            }
        }
    }

    fun cancelReview() {
        val jobID = activeJobID ?: run {
            _state.update { it.copy(phase = DataExchangePhase.IDLE, plan = null) }
            return
        }
        val owner = runCatching { owner() }.getOrNull() ?: return
        activeJobID = null
        _state.update { it.copy(phase = DataExchangePhase.IDLE, plan = null) }
        scope.launch {
            runCatching { withContext(ioDispatcher) { client.abort(owner, jobID) } }
        }
    }

    fun cancelActive() {
        cancelRequested = true
        activeWork?.cancel()
        val owner = runCatching { owner() }.getOrNull()
        val jobID = activeJobID
        val stageID = activeStageID
        if (owner != null) {
            scope.launch {
                if (jobID != null) runCatching { withContext(ioDispatcher) { client.cancel(owner, jobID) } }
                if (stageID != null) runCatching { withContext(ioDispatcher) { client.stageAbort(owner, stageID) } }
            }
        }
        _state.update {
            it.copy(phase = DataExchangePhase.IDLE, plan = null, errorCode = null,
                noticeCode = "cancelled", progressDone = 0, progressTotal = 0)
        }
    }

    fun recover() {
        if (state.value.busy) return
        val owner = try {
            owner()
        } catch (failure: Throwable) {
            fail(failure as? C07ClientFailure
                ?: C07ClientFailure("runtimeNotInstalled", "runtimeNotInstalled"))
            return
        }
        activeWork = scope.launch {
            try {
                _state.update { it.copy(phase = DataExchangePhase.RESTORING) }
                val report = withContext(ioDispatcher) { client.recover(owner) }
                val pending = withContext(ioDispatcher) { client.pending(owner) }
                if (report.second > 0 || pending > 0) {
                    throw C07ClientFailure("rollbackFailed", "recoveryPending")
                }
                _state.update {
                    it.copy(
                        phase = DataExchangePhase.IDLE,
                        pendingRecoveries = pending,
                        noticeCode = "recovered",
                    )
                }
            } catch (failure: C07ClientFailure) {
                fail(failure)
            } catch (error: Throwable) {
                fail(C07ClientFailure("unknown", error.javaClass.simpleName))
            }
        }
    }

    fun dismissStatus() {
        _state.update {
            it.copy(errorCode = null, noticeCode = null, receipt = null,
                backupBytes = null, backupSha256 = null, backupWarnings = emptyList(),
                resultWarnings = emptyList(),
                phase = if (it.phase == DataExchangePhase.FAILED ||
                    it.phase == DataExchangePhase.COMPLETE) DataExchangePhase.IDLE else it.phase)
        }
    }

    fun onOwnedStoreReady() {
        // A real accepted generation re-admits an already-created settings
        // controller after a root stop/rebind; the page keeps its place.
        refresh()
    }

    fun onRootStopped() {
        activeDestinationUri?.let { deleteDestination(it) }
        activeDestinationUri = null
        cancelActive()
        entered.set(false)
        _state.update {
            DataExchangeUiState(loading = false, coreReady = false)
        }
    }

    // MARK: - Job polling / IO

    private suspend fun awaitJob(
        owner: C07ExchangeOwner,
        jobID: String,
        onProgress: (C07Job) -> Unit,
    ): C07Job {
        while (true) {
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if (cancelRequested) throw CancellationException("cancelled")
            val job = withContext(ioDispatcher) { client.status(owner, jobID) }
            onProgress(job)
            when (job.phase) {
                "ready", "complete" -> return job
                "failed" -> throw C07ClientFailure(
                    job.errorCode ?: "internal",
                    job.warnings.lastOrNull() ?: "jobFailed",
                    retryable = job.errorCode == "restoreIncomplete",
                )
                "cancelled" -> throw CancellationException("cancelled")
                else -> delay(180)
            }
        }
    }

    private suspend fun writeDestination(
        owner: C07ExchangeOwner,
        jobID: String,
        uri: Uri,
        expectedBytes: Long,
        expectedSha256: String,
    ) {
        val output = withContext(ioDispatcher) {
            resolver.openOutputStream(uri, "w")
                ?: throw C07ClientFailure("storageUnavailable", "destinationOpen")
        }
        var offset = 0L
        try {
            while (true) {
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                if (cancelRequested) throw CancellationException("cancelled")
                val chunk = withContext(ioDispatcher) {
                    client.read(owner, jobID, offset, C07DataExchangeClient.MAX_CHUNK)
                }
                if (chunk.data.isNotEmpty()) {
                    withContext(ioDispatcher) { output.write(chunk.data) }
                    offset = chunk.nextOffset
                    _state.update {
                        it.copy(progressDone = offset, progressTotal = chunk.totalBytes)
                    }
                }
                if (chunk.eof) break
                if (chunk.data.isEmpty()) {
                    throw C07ClientFailure("storageUnavailable", "emptyRead")
                }
            }
            withContext(ioDispatcher) { output.flush() }
        } finally {
            runCatching { output.close() }
        }
        val (actualBytes, actualSha) = withContext(ioDispatcher) { readDestinationDigest(uri) }
        if (actualBytes != expectedBytes || actualSha != expectedSha256) {
            throw C07ClientFailure("receiptMismatch", "destinationReadback")
        }
    }

    private fun readDestinationDigest(uri: Uri): Pair<Long, String> {
        val input = resolver.openInputStream(uri)
            ?: throw C07ClientFailure("storageUnavailable", "destinationReadbackOpen")
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        var zeroReads = 0
        val buffer = ByteArray(1 shl 20)
        input.use {
            while (true) {
                val read = it.read(buffer)
                if (read < 0) break
                if (read == 0) {
                    zeroReads += 1
                    if (zeroReads > 3) {
                        throw C07ClientFailure("storageUnavailable", "readStalled")
                    }
                    continue
                }
                zeroReads = 0
                count += read
                digest.update(buffer, 0, read)
                if (count > C07DataExchangeClient.MAX_CHUNK.toLong() * 1_000_000L) {
                    throw C07ClientFailure("receiptMismatch", "destinationTooLarge")
                }
            }
        }
        return count to digest.digest().joinToString("") {
            byte -> "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun deleteDestination(uri: Uri) {
        runCatching { resolver.delete(uri, null, null) }
    }

    private fun prepareUpload(uri: Uri): UploadSource {
        val size = querySize(uri)
        if (size != null && size > MAX_STAGE_BYTES) {
            throw C07ClientFailure("totalTooLarge", "uploadTooLarge")
        }
        if (size != null && size in 1..MAX_STAGE_BYTES) {
            return UploadSource(
                size = size,
                open = {
                    resolver.openInputStream(uri)
                        ?: throw C07ClientFailure("storageUnavailable", "sourceOpen")
                },
                cleanup = { })
        }
        // Provider did not expose a trustworthy size: make one bounded
        // app-cache copy so the native stage still has a known byte budget.
        val directory = File(context.cacheDir, "c07-upload")
        if (!directory.exists() && !directory.mkdirs()) {
            throw C07ClientFailure("storageUnavailable", "cacheDirectory")
        }
        // No upload is live here (the controller serializes restores); clear
        // copies left by a process death or a cancelled picker.
        directory.listFiles()?.forEach { stale -> if (stale.isFile) stale.delete() }
        val file = File(directory, "${UUID.randomUUID()}.bin")
        val input = resolver.openInputStream(uri)
            ?: throw C07ClientFailure("storageUnavailable", "sourceOpen")
        var count = 0L
        var zeroReads = 0
        try {
            FileOutputStream(file).use { output ->
                val buffer = ByteArray(1 shl 20)
                input.use {
                    while (true) {
                        val read = it.read(buffer)
                        if (read < 0) break
                        if (read == 0) {
                            zeroReads += 1
                            if (zeroReads > 3) {
                                throw C07ClientFailure("storageUnavailable", "readStalled")
                            }
                            continue
                        }
                        zeroReads = 0
                        count += read
                        if (count > MAX_STAGE_BYTES) {
                            throw C07ClientFailure("totalTooLarge", "uploadTooLarge")
                        }
                        output.write(buffer, 0, read)
                    }
                }
            }
        } catch (error: Throwable) {
            file.delete()
            throw error
        }
        if (count <= 0L) {
            file.delete()
            throw C07ClientFailure("invalidScope", "emptySource")
        }
        return UploadSource(
            size = count,
            open = { file.inputStream() },
            cleanup = { file.delete() })
    }

    private fun queryDisplayName(uri: Uri): String {
        return runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index < 0 || cursor.isNull(index)) null else cursor.getString(index)
            }
        }.getOrNull()?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
            ?: "package"
    }

    private fun ensureDocumentExtension(
        displayName: String,
        mimeType: String?,
        kind: String,
    ): String {
        val lower = displayName.lowercase()
        if (Regex("\\.[a-z0-9]{1,8}$").containsMatchIn(lower)) return displayName
        val extension = when {
            kind == "note" -> "floenote"
            kind == "canvas" -> "flocanvas"
            kind == "document" && mimeType == "application/pdf" -> "pdf"
            kind == "document" -> "docx"
            else -> return displayName
        }
        return "$displayName.$extension"
    }

    private fun classifyDocument(displayName: String): String {
        val lower = displayName.lowercase()
        return when {
            lower.endsWith(".floenote") -> "note"
            lower.endsWith(".flocanvas") -> "canvas"
            lower.endsWith(".docx") || lower.endsWith(".pdf") -> "document"
            else -> "backup"
        }
    }

    private fun querySize(uri: Uri): Long? {
        return runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index < 0 || cursor.isNull(index)) null else cursor.getLong(index)
            }
        }.getOrNull()
    }

    private suspend fun streamToStage(
        owner: C07ExchangeOwner,
        stageID: String,
        upload: UploadSource,
        chunkBytes: Int,
    ) {
        val input = withContext(ioDispatcher) { upload.open() }
        var sent = 0L
        var zeroReads = 0
        try {
            input.use { stream ->
                while (true) {
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (cancelRequested) throw CancellationException("cancelled")
                    val buffer = ByteArray(minOf(chunkBytes, C07DataExchangeClient.MAX_CHUNK))
                    val read = withContext(ioDispatcher) { stream.read(buffer) }
                    if (read < 0) break
                    if (read == 0) {
                        zeroReads += 1
                        if (zeroReads > 3) {
                            throw C07ClientFailure("storageUnavailable", "readStalled")
                        }
                        continue
                    }
                    zeroReads = 0
                    sent += read
                    if (sent > upload.size) {
                        throw C07ClientFailure("sizeMismatch", "uploadOverflow")
                    }
                    val data = if (read == buffer.size) buffer else buffer.copyOf(read)
                    withContext(ioDispatcher) { client.stageAppend(owner, stageID, data) }
                    _state.update {
                        it.copy(progressDone = sent, progressTotal = upload.size)
                    }
                }
            }
            if (sent != upload.size) {
                throw C07ClientFailure("sizeMismatch", "uploadIncomplete")
            }
        } finally {
            runCatching { input.close() }
        }
    }

    private fun owner(): C07ExchangeOwner {
        val epoch = currentNativeEpoch() ?: lastEpoch.takeIf { it > 0 }
            ?: throw C07ClientFailure("runtimeNotInstalled", "runtimeNotInstalled",
                retryable = true)
        lastEpoch = epoch
        return C07ExchangeOwner(token = ownerToken, nativeEpoch = epoch)
    }

    private fun fail(failure: C07ClientFailure, notice: String? = null) {
        _state.update {
            it.copy(
                loading = false,
                phase = DataExchangePhase.FAILED,
                errorCode = failure.code,
                noticeCode = notice,
                plan = null,
                resultWarnings = emptyList(),
            )
        }
    }

    private fun C07CapabilitiesUi.toUi(): DataExchangeCapabilitiesUi =
        DataExchangeCapabilitiesUi(
            formatVersion = formatVersion,
            backupExtension = backupExtension,
            notesExtension = notesExtension,
            canvasExtension = canvasExtension,
            documentExtensions = documentExtensions,
            chunkBytes = chunkBytes,
            included = included,
            excluded = excluded.map { DataExchangeScopeRow(it.first, it.second) },
            databaseCopied = databaseCopied,
        )

    private fun C07Plan.toUi(warnings: List<String>): DataExchangePlanUi =
        DataExchangePlanUi(
            projects = projects,
            projectFiles = projectFiles,
            noteDocuments = noteDocuments,
            noteResources = noteResources,
            notebooks = notebooks,
            settingsKeys = settingsKeys,
            providerAdvisories = providerAdvisories,
            trashedNotesExcluded = trashedNotesExcluded,
            skippedProjects = skippedProjects,
            conversations = conversations,
            messages = messages,
            runs = runs,
            toolCalls = toolCalls,
            workspaces = workspaces,
            canvasProjects = canvasProjects,
            mediaProjects = mediaProjects,
            mediaAssets = mediaAssets,
            schedules = schedules,
            actionReceipts = actionReceipts,
            mailReceipts = mailReceipts,
            providerConfigs = providerConfigs,
            executionEvidence = executionEvidence,
            warnings = warnings,
        )

    private fun C07Receipt.toUi(): DataExchangeReceiptUi =
        DataExchangeReceiptUi(
            projects = projects,
            noteDocuments = noteDocuments,
            notebooks = notebooks,
            settings = settings,
            skippedProjects = skippedProjects,
            conversations = conversations,
            messages = messages,
            runs = runs,
            toolCalls = toolCalls,
            workspaces = workspaces,
            schedules = schedules,
            providers = providers,
            canvasProjects = canvasProjects,
            mediaProjects = mediaProjects,
            evidenceRows = evidenceRows,
        )

    private data class UploadSource(
        val size: Long,
        val open: () -> InputStream,
        val cleanup: () -> Unit,
    )

    private companion object {
        const val MAX_STAGE_BYTES = 16L * 1024L * 1024L * 1024L + 512L * 1024L * 1024L
    }
}
