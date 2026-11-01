// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C05 SFTP controller.
//
// The Swift `floe.sftp/18` domain remains the authority for host trust,
// credentials, remote paths and the workspace commit ladder. This controller
// only runs the trusted bridge calls, fences every reply by the live native
// epoch/task generation, streams SAF bytes in bounded chunks and polls the
// domain's real transfer state. It is closed by RuntimeHost's root-stop gate.

package com.floe.android.host.sftp

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.floe.android.feature.sftp.SftpBrowserUiState
import com.floe.android.feature.sftp.SftpChallengeUi
import com.floe.android.feature.sftp.SftpEntryUi
import com.floe.android.feature.sftp.SftpErrorUi
import com.floe.android.feature.sftp.SftpHostUi
import com.floe.android.feature.sftp.SftpLaneUi
import com.floe.android.feature.sftp.SftpPendingDownloadUi
import com.floe.android.feature.sftp.SftpTransferUi
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal class C05SFTPHostController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentNativeEpoch: () -> Long?,
    private val client: C05SFTPClient = C05SFTPClient(),
    private val log: (String) -> Unit = { message ->
        Log.println(Log.DEBUG, "FloeC05SFTP", message)
    },
) {
    private val ownerToken = UUID.randomUUID().toString()
    private val _state = MutableStateFlow(SftpBrowserUiState())
    val state: StateFlow<SftpBrowserUiState> = _state.asStateFlow()
    private var taskID: String? = null
    private var requestGeneration = 0L
    private var lastKnownEpoch = 0L
    private var transferPoller: Job? = null

    fun open(taskID: String) {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        val previous = _state.value.lane
        if (previous != null && epoch != null) {
            scope.launch(ioDispatcher) {
                runCatching { client.disconnect(previous.id, owner(epoch)) }
            }
        }
        this.taskID = taskID
        requestGeneration += 1
        transferPoller?.cancel()
        transferPoller = null
        _state.value = SftpBrowserUiState(loading = true)
        loadHosts()
    }

    fun close() {
        requestGeneration += 1
        transferPoller?.cancel()
        transferPoller = null
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: lastKnownEpoch
        val lane = _state.value.lane
        if (lane != null && epoch > 0) {
            val owner = owner(epoch)
            scope.launch(ioDispatcher) {
                runCatching { client.disconnect(lane.id, owner) }
            }
        }
        taskID = null
        _state.value = SftpBrowserUiState()
    }

    fun refresh() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            fail(C05SFTPFailure("staleEpoch", "nativeEpochUnavailable"))
            return
        }
        lastKnownEpoch = epoch
        val lane = _state.value.lane
        if (lane == null) loadHosts() else listPath(_state.value.path, lane)
    }

    fun selectHost(profileID: String) {
        connect(profileID)
    }

    fun loadPath(path: String) {
        val lane = _state.value.lane ?: return
        listPath(path, lane)
    }

    fun openDirectory(entry: SftpEntryUi) {
        if (entry.isDirectory) loadPath(entry.path)
    }

    fun goUp() {
        loadPath(parentPath(_state.value.path))
    }

    fun download(entry: SftpEntryUi) {
        if (entry.isDirectory || _state.value.transfer?.state in setOf("running", "completing")) return
        val lane = _state.value.lane ?: return
        val task = taskID ?: return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        val token = nextToken()
        val localPath = defaultLocalPath(entry)
        _state.update { it.copy(busy = "download", error = null, notice = null) }
        scope.launch {
            try {
                val revision = withContext(ioDispatcher) {
                    client.destinationRevision(task, localPath, owner(epoch))
                }
                if (!isLive(token, epoch)) return@launch
                if (revision.exists) {
                    _state.update {
                        it.copy(
                            busy = null,
                            pendingDownload = SftpPendingDownloadUi(
                                entry = entry,
                                localPath = localPath,
                                existingRevision = revision.revision,
                                bytes = entry.bytes,
                            ),
                        )
                    }
                } else {
                    startDownload(
                        lane = lane, entry = entry, task = task, localPath = localPath,
                        overwrite = false, expectedRevision = null, token = token, epoch = epoch,
                    )
                }
            } catch (failure: C05SFTPFailure) {
                if (isLive(token, epoch)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (isLive(token, epoch)) fail(C05SFTPFailure("unknown", detail = error.message), busy = null)
            }
        }
    }

    fun confirmDownload() {
        val pending = _state.value.pendingDownload ?: return
        val lane = _state.value.lane ?: return
        val task = taskID ?: return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        val token = nextToken()
        _state.update { it.copy(pendingDownload = null, busy = "download") }
        startDownload(
            lane = lane, entry = pending.entry, task = task, localPath = pending.localPath,
            overwrite = true, expectedRevision = pending.existingRevision,
            token = token, epoch = epoch,
        )
    }

    fun cancelPendingDownload() {
        _state.update { it.copy(pendingDownload = null) }
    }

    fun upload(uri: Uri) {
        if (_state.value.transfer?.state in setOf("running", "completing")) return
        val lane = _state.value.lane ?: return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        val token = nextToken()
        _state.update { it.copy(busy = "upload", error = null, notice = null) }
        scope.launch {
            var transfer: C05SFTPTransfer? = null
            try {
                val document = withContext(ioDispatcher) { documentInfo(uri) }
                val base = joinRemote(_state.value.path, uniqueName(document.displayName))
                val remote = withContext(ioDispatcher) {
                    availableRemotePath(lane, base, owner(epoch))
                }
                if (!isLive(token, epoch)) return@launch
                transfer = withContext(ioDispatcher) {
                    client.startUpload(
                        laneID = lane.id,
                        remotePath = remote,
                        displayName = document.displayName,
                        totalBytes = document.bytes,
                        sha256 = null,
                        owner = owner(epoch),
                    )
                }
                if (!isLive(token, epoch)) {
                    runCatching { client.cancelTransfer(transfer!!.id, owner(epoch)) }
                    return@launch
                }
                _state.update {
                    it.copy(busy = null, transfer = transfer!!.toUi())
                }
                val digest = MessageDigest.getInstance("SHA-256")
                var offset = 0L
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val buffer = ByteArray(C05_SFTP_MAX_CHUNK)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        if (offset + read > document.bytes) {
                            throw C05SFTPFailure("sizeMismatch", "uploadSourceGrew")
                        }
                        digest.update(buffer, 0, read)
                        val chunk = buffer.copyOf(read)
                        val snapshot = withContext(ioDispatcher) {
                            client.writeUpload(transfer!!.id, offset, chunk, owner(epoch))
                        }
                        offset += read
                        _state.update { it.copy(transfer = snapshot.toUi()) }
                    }
                } ?: throw C05SFTPFailure("invalidRequest", "uploadSourceUnavailable")
                if (offset != document.bytes) {
                    throw C05SFTPFailure("sizeMismatch", "uploadSourceChanged")
                }
                if (!isLive(token, epoch)) {
                    runCatching { client.cancelTransfer(transfer!!.id, owner(epoch)) }
                    return@launch
                }
                val digestHex = digest.digest().joinToString("") { "%02x".format(it) }
                val done = withContext(ioDispatcher) {
                    client.finishUpload(transfer!!.id, digestHex, owner(epoch))
                }
                if (!isLive(token, epoch)) return@launch
                _state.update {
                    it.copy(
                        transfer = done.toUi(),
                        notice = if (done.state == "completed") "uploaded" else null,
                        busy = null,
                    )
                }
                runCatching { withContext(ioDispatcher) {
                    client.releaseTransfer(done.id, owner(epoch))
                } }
                listPath(_state.value.path, lane)
            } catch (failure: C05SFTPFailure) {
                transfer?.let { value ->
                    runCatching {
                        withContext(ioDispatcher) {
                            client.cancelTransfer(value.id, owner(epoch))
                        }
                    }
                    runCatching {
                        withContext(ioDispatcher) {
                            client.releaseTransfer(value.id, owner(epoch))
                        }
                    }
                }
                if (isLive(token, epoch)) fail(failure, busy = null)
            } catch (error: Throwable) {
                transfer?.let { value ->
                    runCatching {
                        withContext(ioDispatcher) {
                            client.cancelTransfer(value.id, owner(epoch))
                        }
                    }
                    runCatching {
                        withContext(ioDispatcher) {
                            client.releaseTransfer(value.id, owner(epoch))
                        }
                    }
                }
                if (isLive(token, epoch)) {
                    fail(C05SFTPFailure("unknown", detail = error.message), busy = null)
                }
            }
        }
    }

    fun cancelTransfer() {
        val transfer = _state.value.transfer ?: return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        val token = nextToken()
        scope.launch(ioDispatcher) {
            runCatching {
                val value = client.cancelTransfer(transfer.id, owner(epoch))
                runCatching { client.releaseTransfer(value.id, owner(epoch)) }
                if (isLive(token, epoch)) {
                    _state.update {
                        it.copy(transfer = value.toUi(), notice = "cancelled", busy = null)
                    }
                }
            }.onFailure { error ->
                if (isLive(token, epoch)) {
                    fail(
                        if (error is C05SFTPFailure) error
                        else C05SFTPFailure("unknown", detail = error.message),
                        busy = null,
                    )
                }
            }
        }
    }

    fun approveChallenge(accept: Boolean, replaceChanged: Boolean) {
        val challenge = _state.value.challenge ?: return
        val profileID = _state.value.selectedProfileID ?: challenge.profileID
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        val token = nextToken()
        _state.update { it.copy(busy = "approve") }
        scope.launch {
            try {
                val trusted = withContext(ioDispatcher) {
                    client.hostKeyApprove(challenge.id, accept, replaceChanged, owner(epoch))
                }
                if (!isLive(token, epoch)) return@launch
                _state.update { it.copy(challenge = null, busy = null) }
                if (trusted && accept && profileID != null) connect(profileID)
            } catch (failure: C05SFTPFailure) {
                if (isLive(token, epoch)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (isLive(token, epoch)) fail(C05SFTPFailure("unknown", detail = error.message), busy = null)
            }
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    suspend fun prepareForRootStop(timeoutMillis: Long = 8_000): Boolean {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
            ?: lastKnownEpoch.takeIf { it > 0 }
            ?: return true
        requestGeneration += 1
        transferPoller?.cancel()
        transferPoller = null
        val drained = try {
            val result = withTimeoutOrNull(maxOf(1_000L, timeoutMillis)) {
                withContext(ioDispatcher) { client.rootStop(epoch) }
            }
            result != null
        } catch (failure: C05SFTPFailure) {
            failure.code == "needsCoreUpdate" ||
                failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }
        if (drained) {
            _state.update {
                it.copy(lane = null, entries = emptyList(), transfer = null,
                    pendingDownload = null, challenge = null, busy = null)
            }
        }
        return drained
    }

    fun onRootStopped() {
        requestGeneration += 1
        transferPoller?.cancel()
        transferPoller = null
        _state.value = SftpBrowserUiState()
    }

    // MARK: - Lane/list

    private fun loadHosts() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            fail(C05SFTPFailure("staleEpoch", "nativeEpochUnavailable"))
            return
        }
        lastKnownEpoch = epoch
        val token = nextToken()
        _state.update { it.copy(loading = true, error = null) }
        scope.launch {
            try {
                val coreReady = withContext(ioDispatcher) { client.capabilities() }
                if (!isLive(token, epoch)) return@launch
                if (!coreReady) {
                    _state.update { it.copy(loading = false, coreReady = false) }
                    return@launch
                }
                val hosts = withContext(ioDispatcher) { client.hosts(owner(epoch)) }
                if (!isLive(token, epoch)) return@launch
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = true,
                        hosts = hosts.map { host ->
                            SftpHostUi(host.id, host.displayName, host.address, host.port, host.user)
                        },
                    )
                }
            } catch (failure: C05SFTPFailure) {
                if (isLive(token, epoch)) fail(failure, loading = false)
            } catch (error: Throwable) {
                if (isLive(token, epoch)) {
                    fail(C05SFTPFailure("unknown", detail = error.message), loading = false)
                }
            }
        }
    }

    private fun connect(profileID: String) {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        lastKnownEpoch = epoch
        val token = nextToken()
        val previous = _state.value.lane
        if (previous != null) {
            scope.launch(ioDispatcher) { runCatching { client.disconnect(previous.id, owner(epoch)) } }
        }
        _state.update {
            it.copy(
                selectedProfileID = profileID,
                lane = null,
                loading = true,
                busy = "connect",
                challenge = null,
                error = null,
                entries = emptyList(),
            )
        }
        scope.launch {
            try {
                val lane = withContext(ioDispatcher) {
                    client.connect(profileID, owner(epoch))
                }
                if (!isLive(token, epoch)) {
                    runCatching { withContext(ioDispatcher) { client.disconnect(lane.id, owner(epoch)) } }
                    return@launch
                }
                _state.update {
                    it.copy(
                        loading = false,
                        busy = null,
                        lane = SftpLaneUi(
                            lane.id, lane.profileID, lane.displayName, lane.address,
                            lane.port, lane.user, lane.state, lane.homePath,
                        ),
                        path = lane.homePath,
                    )
                }
                listPath(lane.homePath, lane)
            } catch (failure: C05SFTPFailure) {
                if (!isLive(token, epoch)) return@launch
                val challenge = failure.challenge
                if (challenge != null) {
                    _state.update {
                        it.copy(
                            loading = false,
                            busy = null,
                            challenge = SftpChallengeUi(
                                id = challenge.id,
                                address = challenge.address,
                                port = challenge.port,
                                keyType = challenge.keyType,
                                fingerprint = challenge.fingerprintSHA256,
                                expectedFingerprint = challenge.expectedFingerprintSHA256,
                                changed = challenge.changed,
                            ),
                        )
                    }
                } else {
                    fail(failure, loading = false, busy = null)
                }
            } catch (error: Throwable) {
                if (isLive(token, epoch)) {
                    fail(C05SFTPFailure("unknown", detail = error.message), loading = false, busy = null)
                }
            }
        }
    }

    private fun listPath(path: String, lane: C05SFTPLane) {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        val token = nextToken()
        _state.update { it.copy(busy = "list", error = null, pendingDownload = null) }
        scope.launch {
            try {
                val page = withContext(ioDispatcher) {
                    client.list(lane.id, path, 0, 200, owner(epoch))
                }
                if (!isLive(token, epoch)) return@launch
                _state.update {
                    it.copy(
                        busy = null,
                        path = page.canonicalPath,
                        entries = page.entries.map { entry ->
                            SftpEntryUi(
                                name = entry.name,
                                path = entry.path,
                                isDirectory = entry.isDirectory,
                                isSymbolicLink = entry.isSymbolicLink,
                                bytes = entry.bytes,
                                modifiedAt = entry.modifiedAt,
                                revision = entry.revision,
                            )
                        },
                        truncated = page.truncated,
                    )
                }
            } catch (failure: C05SFTPFailure) {
                if (isLive(token, epoch)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (isLive(token, epoch)) fail(C05SFTPFailure("unknown", detail = error.message), busy = null)
            }
        }
    }

    private fun startDownload(
        lane: C05SFTPLane,
        entry: SftpEntryUi,
        task: String,
        localPath: String,
        overwrite: Boolean,
        expectedRevision: String?,
        token: Long,
        epoch: Long,
    ) {
        if (!isLive(token, epoch)) return
        _state.update { it.copy(busy = "download", error = null) }
        scope.launch {
            try {
                val transfer = withContext(ioDispatcher) {
                    client.startDownload(
                        laneID = lane.id,
                        remotePath = entry.path,
                        taskID = task,
                        relativePath = localPath,
                        overwrite = overwrite,
                        expectedRevision = expectedRevision,
                        owner = owner(epoch),
                    )
                }
                if (!isLive(token, epoch)) {
                    runCatching { withContext(ioDispatcher) { client.cancelTransfer(transfer.id, owner(epoch)) } }
                    return@launch
                }
                _state.update { it.copy(busy = null, transfer = transfer.toUi()) }
                pollTransfer(transfer.id, token, epoch)
            } catch (failure: C05SFTPFailure) {
                if (isLive(token, epoch)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (isLive(token, epoch)) fail(C05SFTPFailure("unknown", detail = error.message), busy = null)
            }
        }
    }

    private fun pollTransfer(transferID: String, token: Long, epoch: Long) {
        transferPoller?.cancel()
        transferPoller = scope.launch {
            while (true) {
                val transfer = try {
                    withContext(ioDispatcher) { client.transferStatus(transferID, owner(epoch)) }
                } catch (failure: C05SFTPFailure) {
                    if (isLive(token, epoch)) fail(failure, busy = null)
                    return@launch
                } catch (_: Throwable) {
                    return@launch
                }
                if (!isLive(token, epoch)) return@launch
                _state.update { current ->
                    current.copy(
                        transfer = transfer.toUi(),
                        busy = if (transfer.state == "running" || transfer.state == "completing") "download" else null,
                        notice = when (transfer.state) {
                            "completed" -> "downloaded"
                            "cancelled" -> "cancelled"
                            else -> current.notice
                        },
                    )
                }
                if (transfer.state != "running" && transfer.state != "completing") {
                    runCatching {
                        withContext(ioDispatcher) { client.releaseTransfer(transferID, owner(epoch)) }
                    }
                    return@launch
                }
                delay(250)
            }
        }
    }

    // MARK: - Helpers

    private fun nextToken(): Long {
        requestGeneration += 1
        return requestGeneration
    }

    private fun isLive(token: Long, epoch: Long): Boolean =
        token == requestGeneration &&
            currentNativeEpoch()?.takeIf { it > 0 } == epoch &&
            taskID != null

    private fun owner(epoch: Long): C05SFTPOwner =
        C05SFTPOwner(token = ownerToken, nativeEpoch = epoch, taskID = taskID, temporary = false)

    private fun fail(
        failure: C05SFTPFailure,
        loading: Boolean? = null,
        busy: String? = null,
    ) {
        log("${failure.code}: ${failure.reason ?: ""}")
        val challenge = failure.challenge
        if (challenge != null) {
            _state.update {
                it.copy(
                    loading = loading ?: it.loading,
                    busy = busy,
                    error = null,
                    challenge = SftpChallengeUi(
                        id = challenge.id,
                        address = challenge.address,
                        port = challenge.port,
                        keyType = challenge.keyType,
                        fingerprint = challenge.fingerprintSHA256,
                        expectedFingerprint = challenge.expectedFingerprintSHA256,
                        changed = challenge.changed,
                    ),
                )
            }
            return
        }
        _state.update {
            it.copy(
                loading = loading ?: it.loading,
                busy = busy,
                error = SftpErrorUi(
                    code = failure.code,
                    detail = failure.detail ?: failure.reason,
                    retryable = failure.retryable,
                    retainedPath = failure.retainedPath,
                ),
            )
        }
    }

    private fun documentInfo(uri: Uri): C05SFTPDocument {
        var name = "upload"
        var size = -1L
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null, null, null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) name = cursor.getString(nameIndex) ?: name
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        }
        if (size <= 0) {
            size = context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
        }
        if (size <= 0) {
            throw C05SFTPFailure("invalidRequest", "uploadSourceSizeUnavailable")
        }
        if (size > C05_SFTP_MAX_UPLOAD) {
            throw C05SFTPFailure("fileTooLarge", "uploadExceedsLimit")
        }
        return C05SFTPDocument(
            displayName = sanitizeName(name),
            bytes = size,
            uri = uri,
        )
    }

    private fun availableRemotePath(
        lane: C05SFTPLane,
        base: String,
        owner: C05SFTPOwner,
    ): String {
        var candidate = base
        var index = 2
        while (true) {
            val exists = try {
                client.stat(lane.id, candidate, owner)
                true
            } catch (failure: C05SFTPFailure) {
                if (failure.code == "pathNotFound") false
                else throw failure
            }
            if (!exists) return candidate
            candidate = conflictCopy(base, index)
            index += 1
            if (index > 50) throw C05SFTPFailure("busy", "uploadConflictLimit")
        }
    }

    private fun defaultLocalPath(entry: SftpEntryUi): String {
        val host = sanitizeName(_state.value.lane?.displayName ?: "host")
        val remote = entry.path.trimStart('/')
        return "SFTP/$host/$remote"
    }

    private fun parentPath(path: String): String {
        val trimmed = path.trimEnd('/')
        if (trimmed.isEmpty() || trimmed == "/") return "/"
        val index = trimmed.lastIndexOf('/')
        return if (index <= 0) "/" else trimmed.substring(0, index)
    }

    private fun joinRemote(parent: String, name: String): String =
        if (parent == "/") "/$name" else "${parent.trimEnd('/')}/$name"

    private fun conflictCopy(path: String, index: Int): String {
        val directory = path.substringBeforeLast('/', "")
        val name = path.substringAfterLast('/')
        val dot = name.lastIndexOf('.')
        val suffix = if (index <= 2) " (SFTP copy)" else " (SFTP copy $index)"
        val candidate = if (dot > 0) {
            name.substring(0, dot) + suffix + name.substring(dot)
        } else name + suffix
        return if (directory.isEmpty()) candidate else "$directory/$candidate"
    }

    private fun sanitizeName(value: String): String {
        val cleaned = value.trim().replace(Regex("[\\u0000-\\u001F/\\\\]"), "_")
        return cleaned.take(120).ifBlank { "upload" }
    }

    private fun uniqueName(value: String): String = sanitizeName(value)

    private fun C05SFTPTransfer.toUi(): SftpTransferUi = SftpTransferUi(
        id = id,
        kind = kind,
        remotePath = remotePath,
        displayName = displayName,
        state = state,
        bytesDone = bytesDone,
        totalBytes = totalBytes,
        sha256 = sha256,
        errorCode = errorCode,
    )

    private companion object {
        const val C05_SFTP_MAX_UPLOAD = 256L * 1024 * 1024
    }
}
