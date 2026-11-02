// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C05 RDP controller. Swift/FloeRDP/FreeRDP remain the
// session, certificate and credential authority; this controller only owns
// the trusted `floe.rdp/17` client, the real binary frame pump, bounded input
// ordering and the App-scoped lifetime. It is fenced by the current native
// Root epoch and drained by RuntimeHost before Root retirement.

package com.floe.android.host.rdp

import android.graphics.Bitmap
import android.util.Log
import com.floe.android.feature.rdp.RdpCapabilitiesUi
import com.floe.android.feature.rdp.RdpCertificatePromptUi
import com.floe.android.feature.rdp.RdpEndpointDraftUi
import com.floe.android.feature.rdp.RdpEndpointUi
import com.floe.android.feature.rdp.RdpFailureUi
import com.floe.android.feature.rdp.RdpHostDetailUi
import com.floe.android.feature.rdp.RdpProfileDraftUi
import com.floe.android.feature.rdp.RdpSessionUi
import com.floe.android.feature.rdp.RdpUiState
import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteOwner
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal class C05RDPHostController(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val currentNativeEpoch: () -> Long?,
    private val client: C05RDPClient = C05RDPClient(),
    private val video: C05RDPVideoTransport = C05RDPVideoNative,
    private val bitmapFactory: (Int, Int) -> Bitmap? = { width, height ->
        runCatching { Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888) }.getOrNull()
    },
    private val log: (String, String) -> Unit = { level, message ->
        Log.println(if (level == "error") Log.ERROR else Log.DEBUG, "FloeC05RDP", message)
    },
) {
    private val ownerToken = UUID.randomUUID().toString()
    private val _state = MutableStateFlow(RdpUiState())
    val state: StateFlow<RdpUiState> = _state.asStateFlow()

    private val gate = Gate()
    private var details: MutableMap<String, C05RdpHostDetail> = mutableMapOf()
    private var statusJob: Job? = null
    private var frameJob: Job? = null
    private var inputJob: Job? = null
    private var lane: C05RDPInputLane? = null
    private var sessionEpoch: Long = 0L
    private var lastRevision: Long = -1L
    private var frameCount: Int = 0
    private var frameWindowStart: Long = 0L
    @Volatile private var visible: Boolean = true
    @Volatile private var loaded: Boolean = false
    @Volatile private var lastKnownEpoch: Long = 0L

    private class Gate {
        private var requestGeneration = 0L
        private var requestEpoch = 0L
        private var sessionToken = 0L
        private var sessionID: String? = null
        private var sessionEpoch = 0L

        @Synchronized
        fun beginRequest(epoch: Long?): Long? {
            val live = epoch?.takeIf { it > 0 } ?: return null
            requestGeneration += 1
            requestEpoch = live
            return requestGeneration
        }

        @Synchronized
        fun liveRequest(generation: Long, epoch: Long?): Boolean =
            generation == requestGeneration && epoch != null && epoch == requestEpoch

        @Synchronized
        fun beginSession(id: String, epoch: Long): Long {
            sessionToken += 1
            sessionID = id
            sessionEpoch = epoch
            return sessionToken
        }

        @Synchronized
        fun liveSession(id: String, token: Long, epoch: Long?): Boolean =
            sessionID == id && token == sessionToken && epoch != null && epoch == sessionEpoch

        @Synchronized
        fun clearSession() {
            sessionID = null
            sessionToken += 1
        }

        @Synchronized
        fun cancelAll() {
            requestGeneration += 1
            sessionToken += 1
            sessionID = null
        }
    }

    fun enter() {
        if (!loaded) {
            loaded = true
            load()
        }
    }

    fun onOwnedStoreReady() {
        gate.cancelAll()
        loaded = true
        load()
    }

    fun onRootStopped() {
        gate.cancelAll()
        stopWork()
        loaded = false
        _state.value = RdpUiState(loading = false, coreReady = false)
    }

    fun refresh() = load()

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun setVisible(value: Boolean) {
        visible = value
        if (!value) {
            releaseAll()
        }
    }

    // MARK: - Profiles

    private fun load() {
        if (_state.value.loading) return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            _state.update {
                it.copy(loading = false, coreReady = false, error = RdpFailureUi(
                    code = "runtimeNotReady",
                    message = "The local runtime is not ready",
                    retryable = true,
                    category = "coreUnavailable",
                    stage = "runtime",
                ))
            }
            return
        }
        lastKnownEpoch = epoch
        _state.update { it.copy(loading = true, error = null) }
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                val capabilities = withContext(ioDispatcher) { client.capabilities() }
                val hosts = withContext(ioDispatcher) { client.listProfiles(owner) }
                details = hosts.associateBy { it.summary.id }.toMutableMap()
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = capabilities.coreReady,
                        capabilities = RdpCapabilitiesUi(
                            coreReady = capabilities.coreReady,
                            runtimeVersion = capabilities.runtimeVersion,
                            supportsCertificateTrust = capabilities.supportsCertificateTrust,
                            modelTools = capabilities.modelTools,
                        ),
                        hosts = hosts.map { it.toUi() },
                        error = null,
                    )
                }
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(loading = false, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(loading = false, error = failure.toUi()) }
            } catch (error: Throwable) {
                _state.update {
                    it.copy(loading = false, error = RdpFailureUi(
                        code = "unknown",
                        message = "Could not load RDP hosts",
                        retryable = true,
                        category = "internalFailure",
                        stage = "profile",
                    ))
                }
            }
        }
    }

    fun saveProfile(draft: RdpProfileDraftUi) {
        if (_state.value.busy != null) return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            _state.update { it.copy(error = runtimeNotReady()) }
            return
        }
        _state.update { it.copy(busy = "save") }
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                val endpoints = mutableListOf<C05RdpEndpointDraft>()
                for (endpoint in draft.endpoints) {
                    val endpointID = endpoint.id ?: UUID.randomUUID().toString()
                    val existing = details[draft.id]?.endpoints?.firstOrNull { it.id == endpointID }
                    val port = endpoint.port.toIntOrNull()?.takeIf { it in 1..65535 }
                        ?: throw C05RDPException("invalidRequest", "invalidPort")
                    val secret = endpoint.password.takeIf { it.isNotEmpty() }
                    val reference = if (secret != null) {
                        val account = "floe.rdp.$endpointID.password"
                        val bytes = secret.toByteArray(Charsets.UTF_8)
                        try {
                            withContext(ioDispatcher) {
                                client.credentialSave(account, false, bytes, owner)
                            }
                        } finally {
                            bytes.fill(0)
                        }
                    } else {
                        existing?.passwordRef
                    }
                    endpoints += C05RdpEndpointDraft(
                        id = endpointID,
                        displayName = endpoint.displayName,
                        host = endpoint.host,
                        port = port,
                        username = endpoint.username,
                        domain = endpoint.domain,
                        passwordRef = reference,
                    )
                }
                val saved = withContext(ioDispatcher) {
                    client.profileSave(
                        C05RdpProfileDraft(
                            id = draft.id,
                            displayName = draft.displayName,
                            deviceKind = draft.deviceKind,
                            endpoints = endpoints,
                        ),
                        owner,
                    )
                }
                details[saved.summary.id] = saved
                _state.update {
                    it.copy(
                        busy = null,
                        error = null,
                        savedMessage = "Saved",
                        hosts = details.values.sortedBy { host -> host.summary.displayName }.map { it.toUi() },
                    )
                }
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (error: Throwable) {
                _state.update {
                    it.copy(
                        busy = null,
                        error = RdpFailureUi(
                            "unknown", "Could not save the RDP profile", true,
                            "internalFailure", "profile",
                        ),
                    )
                }
            }
        }
    }

    fun deleteEndpoint(profileID: String, endpointID: String) {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        _state.update { it.copy(busy = "delete") }
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                val detail = withContext(ioDispatcher) {
                    client.endpointDelete(profileID, endpointID, owner)
                }
                details[profileID] = detail
                _state.update {
                    it.copy(
                        busy = null,
                        savedMessage = "Deleted",
                        hosts = details.values.sortedBy { host -> host.summary.displayName }.map { it.toUi() },
                    )
                }
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (_: Throwable) {
                _state.update {
                    it.copy(
                        busy = null,
                        error = RdpFailureUi(
                            "unknown", "Could not delete the RDP endpoint", true,
                            "internalFailure", "profile",
                        ),
                    )
                }
            }
        }
    }

    fun deleteProfile(profileID: String, deleteHost: Boolean) {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        _state.update { it.copy(busy = "delete") }
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                withContext(ioDispatcher) { client.profileDelete(profileID, deleteHost, owner) }
                details.remove(profileID)
                _state.update {
                    it.copy(
                        busy = null,
                        savedMessage = "Deleted",
                        hosts = details.values.sortedBy { host -> host.summary.displayName }.map { it.toUi() },
                    )
                }
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (_: Throwable) {
                _state.update {
                    it.copy(
                        busy = null,
                        error = RdpFailureUi(
                            "unknown", "Could not delete the RDP host", true,
                            "internalFailure", "profile",
                        ),
                    )
                }
            }
        }
    }

    // MARK: - Session

    fun connect(profileID: String, endpointID: String? = null) {
        if (_state.value.busy != null || _state.value.session != null) return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            _state.update { it.copy(error = runtimeNotReady()) }
            return
        }
        val generation = gate.beginRequest(epoch) ?: return
        _state.update { it.copy(busy = "connect", error = null) }
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                val session = withContext(ioDispatcher) {
                    client.connect(profileID, endpointID, owner)
                }
                if (!gate.liveRequest(generation, currentNativeEpoch())) {
                    runCatching { withContext(ioDispatcher) { client.close(session.id, owner) } }
                    return@launch
                }
                sessionEpoch = epoch
                lastRevision = -1L
                frameCount = 0
                frameWindowStart = android.os.SystemClock.elapsedRealtime()
                val token = gate.beginSession(session.id, epoch)
                _state.update {
                    it.copy(
                        busy = null,
                        prompt = null,
                        session = session.toUi(null, 0.0),
                    )
                }
                startStatusPoller(session.id, token, epoch)
                startInputLane(session.id, token, epoch)
                startFramePump(session.id, token, epoch)
            } catch (failure: C05RDPException) {
                if (failure.challenge != null) {
                    _state.update {
                        it.copy(busy = null, prompt = failure.challenge.toUi())
                    }
                } else {
                    _state.update { it.copy(busy = null, error = failure.toUi()) }
                }
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (error: Throwable) {
                _state.update {
                    it.copy(
                        busy = null,
                        error = RdpFailureUi(
                            "unknown", "Could not connect the RDP session", true,
                            "transportFailed", "transport",
                        ),
                    )
                }
            }
        }
    }

    fun trust() {
        val prompt = _state.value.prompt ?: return
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        _state.update { it.copy(busy = "trust") }
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                withContext(ioDispatcher) {
                    client.trust(
                        prompt.profileID,
                        prompt.endpointID,
                        prompt.fingerprintSHA256,
                        owner,
                    )
                }
                _state.update { it.copy(busy = null, prompt = null) }
                connect(prompt.profileID, prompt.endpointID)
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            }
        }
    }

    fun rejectTrust() {
        _state.update { it.copy(prompt = null) }
    }

    fun disconnect() {
        val session = _state.value.session ?: return
        val epoch = sessionEpoch.takeIf { it > 0 } ?: return
        if (_state.value.busy != null) return
        _state.update { it.copy(busy = "close") }
        stopWork()
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                val result = withContext(ioDispatcher) { client.close(session.sessionID, owner) }
                if (result.complete) {
                    gate.clearSession()
                    _state.update { it.copy(session = null, busy = null) }
                } else {
                    _state.update {
                        it.copy(
                            busy = null,
                            error = RdpFailureUi(
                                "cleanupIncomplete", "The session did not prove closure", true,
                                "cleanupIncomplete", "transport",
                            ),
                        )
                    }
                }
            } catch (failure: C05RemoteFailure) {
                if (failure.code == "rdpSessionNotFound" || failure.code == "sessionNotFound") {
                    gate.clearSession()
                    _state.update { it.copy(session = null, busy = null) }
                } else {
                    _state.update { it.copy(busy = null, error = failure.toUi()) }
                }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            }
        }
    }

    fun reconnect() {
        val session = _state.value.session ?: return
        val epoch = sessionEpoch.takeIf { it > 0 } ?: return
        if (_state.value.busy != null) return
        _state.update { it.copy(busy = "reconnect") }
        stopWork()
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                runCatching { withContext(ioDispatcher) { client.close(session.sessionID, owner) } }
                gate.clearSession()
                _state.update { it.copy(session = null, busy = null, prompt = null, error = null) }
                connect(session.profileID, session.endpointID)
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            }
        }
    }

    fun reset() {
        val session = _state.value.session ?: return
        val epoch = sessionEpoch.takeIf { it > 0 } ?: return
        if (_state.value.busy != null) return
        _state.update { it.copy(busy = "reset") }
        stopWork()
        scope.launch {
            try {
                val owner = ownerFor(epoch)
                val result = withContext(ioDispatcher) { client.reset(session.sessionID, owner) }
                if (result.complete) {
                    gate.clearSession()
                    _state.update {
                        it.copy(session = null, busy = null, prompt = null, error = null)
                    }
                } else {
                    _state.update {
                        it.copy(
                            busy = null,
                            prompt = null,
                            error = RdpFailureUi(
                                "cleanupIncomplete",
                                "The session did not prove closure",
                                true,
                                "cleanupIncomplete",
                                "transport",
                            ),
                        )
                    }
                }
            } catch (failure: C05RemoteFailure) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            } catch (failure: C05RDPException) {
                _state.update { it.copy(busy = null, error = failure.toUi()) }
            }
        }
    }

    suspend fun prepareForRootStop(timeoutMillis: Long = 8_000): Boolean {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
            ?: lastKnownEpoch.takeIf { it > 0 }
            ?: return true
        gate.cancelAll()
        stopWork()
        _state.update { it.copy(session = null, prompt = null, busy = null) }
        return try {
            val result = withTimeoutOrNull(maxOf(1_000L, timeoutMillis)) {
                withContext(ioDispatcher) { client.rootStop(epoch) }
            }
            result != null
        } catch (failure: C05RemoteFailure) {
            failure.code == "needsCoreUpdate" ||
                failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }
    }

    // MARK: - Input

    fun pointerMove(x: Int, y: Int) {
        lane?.offer(C05RdpInput.PointerMove(x, y))?.let(::issue)
    }

    fun pointerButton(button: String, down: Boolean, x: Int, y: Int) {
        lane?.offer(C05RdpInput.PointerButton(button, down, x, y))?.let(::issue)
    }

    fun wheel(up: Boolean, steps: Int, x: Int, y: Int) {
        lane?.offer(C05RdpInput.Wheel(up, steps.coerceIn(1, 20), x, y))?.let(::issue)
    }

    fun key(scancode: Int, extended: Boolean, down: Boolean) {
        lane?.offer(C05RdpInput.Key(scancode, extended, down))?.let(::issue)
    }

    fun namedKey(key: String) {
        lane?.offer(C05RdpInput.NamedKey(key))?.let(::issue)
    }

    fun modifier(modifier: String, down: Boolean) {
        lane?.offer(C05RdpInput.Modifier(modifier, down))?.let(::issue)
    }

    fun text(text: String) {
        if (text.isEmpty()) return
        var offset = 0
        while (offset < text.length) {
            val end = minOf(text.length, offset + 1_024)
            lane?.offer(C05RdpInput.Text(text.substring(offset, end), false))?.let(::issue)
            offset = end
        }
    }

    fun submit() {
        lane?.offer(C05RdpInput.NamedKey("Return"))?.let(::issue)
    }

    fun releaseAll() {
        val session = _state.value.session ?: return
        val epoch = sessionEpoch.takeIf { it > 0 } ?: return
        lane?.close()
        lane = null
        inputJob?.cancel()
        inputJob = null
        scope.launch {
            runCatching {
                withContext(ioDispatcher) { client.releaseAll(session.sessionID, ownerFor(epoch)) }
            }
        }
    }

    private fun issue(value: String) {
        _state.update { it.copy(session = it.session?.copy(inputIssue = value)) }
    }

    private fun startInputLane(sessionID: String, token: Long, epoch: Long) {
        lane?.close()
        inputJob?.cancel()
        val created = C05RDPInputLane(
            sink = { events ->
                if (gate.liveSession(sessionID, token, currentNativeEpoch())) {
                    withContext(ioDispatcher) {
                        client.input(sessionID, events, ownerFor(epoch))
                    }
                }
            },
            onIssue = { value ->
                if (gate.liveSession(sessionID, token, currentNativeEpoch())) {
                    _state.update { it.copy(session = it.session?.copy(inputIssue = value)) }
                }
            },
        )
        lane = created
        inputJob = scope.launch(ioDispatcher) { created.run() }
    }

    private fun startStatusPoller(sessionID: String, token: Long, epoch: Long) {
        statusJob?.cancel()
        statusJob = scope.launch(ioDispatcher) {
            while (isActive) {
                if (!gate.liveSession(sessionID, token, currentNativeEpoch())) return@launch
                try {
                    val session = client.status(sessionID, ownerFor(epoch))
                    if (!gate.liveSession(sessionID, token, currentNativeEpoch())) return@launch
                    _state.update { current ->
                        if (current.session?.sessionID != sessionID) {
                            current
                        } else {
                            val mapped = session.toUi(
                                current.session?.bitmap,
                                current.session?.measuredFps ?: 0.0,
                            )
                            current.copy(
                                session = mapped.copy(
                                    width = maxOf(mapped.width, current.session?.width ?: 0),
                                    height = maxOf(mapped.height, current.session?.height ?: 0),
                                    revision = maxOf(mapped.revision, current.session?.revision ?: 0L),
                                    byteCount = maxOf(mapped.byteCount, current.session?.byteCount ?: 0),
                                )
                            )
                        }
                    }
                    if (session.state == "failed" || session.state == "closed") {
                        stopWork()
                    }
                    if (session.state == "closed") return@launch
                } catch (failure: C05RemoteFailure) {
                    if (failure.code == "sessionNotFound" || failure.code == "staleEpoch") {
                        stopWork()
                        _state.update { it.copy(session = null) }
                        return@launch
                    }
                } catch (failure: C05RDPException) {
                    if (failure.code == "sessionNotFound" || failure.code == "staleEpoch") {
                        stopWork()
                        _state.update { it.copy(session = null) }
                        return@launch
                    }
                } catch (_: Throwable) {
                    // Keep the last honest projection; the next poll retries.
                }
                delay(1_000)
            }
        }
    }

    private fun startFramePump(sessionID: String, token: Long, epoch: Long) {
        frameJob?.cancel()
        frameJob = scope.launch(ioDispatcher) {
            var buffer: ByteArray? = null
            var bitmap: Bitmap? = null
            while (isActive) {
                if (!gate.liveSession(sessionID, token, currentNativeEpoch())) return@launch
                if (!visible) {
                    delay(100)
                    continue
                }
                val current = _state.value.session
                if (current == null || current.sessionID != sessionID || current.state != "connected") {
                    delay(100)
                    continue
                }
                val meta = video.acquireFrame(epoch, ownerToken, sessionID)
                if (meta == null) {
                    delay(40)
                    continue
                }
                try {
                    if (meta.byteCount > C05_RDP_MAX_FRAME_BYTES) continue
                    if (meta.revision == lastRevision) {
                        delay(20)
                        continue
                    }
                    val frameBytes = buffer?.takeIf { it.size == meta.byteCount }
                        ?: ByteArray(meta.byteCount).also { buffer = it }
                    var offset = 0
                    while (offset < meta.byteCount) {
                        val length = minOf(C05_RDP_MAX_PAGE_BYTES, meta.byteCount - offset)
                        val copied = video.read(
                            epoch = epoch,
                            leaseID = meta.leaseID,
                            offset = offset.toLong(),
                            target = frameBytes,
                            targetOffset = offset,
                            length = length,
                        )
                        if (copied <= 0) break
                        offset += copied
                    }
                    if (offset != meta.byteCount) {
                        delay(40)
                        continue
                    }
                    try {
                        withContext(mainDispatcher) {
                            if (!gate.liveSession(sessionID, token, currentNativeEpoch())) return@withContext
                            val target = bitmap?.takeIf {
                                it.width == meta.width && it.height == meta.height && !it.isRecycled
                            } ?: bitmapFactory(meta.width, meta.height) ?: return@withContext
                            bitmap = target
                            target.copyPixelsFromBuffer(ByteBuffer.wrap(frameBytes, 0, meta.byteCount))
                            lastRevision = meta.revision
                            frameCount += 1
                            val now = android.os.SystemClock.elapsedRealtime()
                            val elapsed = (now - frameWindowStart).coerceAtLeast(1L)
                            val fps = frameCount * 1_000.0 / elapsed
                            if (elapsed >= 1_000L) {
                                frameWindowStart = now
                                frameCount = 0
                            }
                            _state.update {
                                it.copy(
                                    session = it.session?.copy(
                                        width = meta.width,
                                        height = meta.height,
                                        revision = meta.revision,
                                        byteCount = meta.byteCount,
                                        bitmap = target,
                                        measuredFps = fps,
                                        inputIssue = null,
                                    )
                                )
                            }
                        }
                    } catch (_: Throwable) {
                        delay(100)
                    }
                } finally {
                    video.releaseQuietly(epoch, meta.leaseID)
                }
                delay(16)
            }
        }
    }

    private fun stopWork() {
        statusJob?.cancel(); statusJob = null
        frameJob?.cancel(); frameJob = null
        inputJob?.cancel(); inputJob = null
        lane?.close(); lane = null
        lastRevision = -1L
        frameCount = 0
    }

    private fun ownerFor(epoch: Long): C05RemoteOwner =
        C05RemoteOwner(token = ownerToken, nativeEpoch = epoch, taskID = null, temporary = false)

    private fun runtimeNotReady(): RdpFailureUi = RdpFailureUi(
        code = "runtimeNotReady",
        message = "The local runtime is not ready",
        retryable = true,
        category = "coreUnavailable",
        stage = "runtime",
    )

    private fun C05RdpHostDetail.toUi(): RdpHostDetailUi = RdpHostDetailUi(
        id = summary.id,
        displayName = summary.displayName,
        deviceKind = summary.deviceKind,
        isRemoteExecutionEnvironment = summary.isRemoteExecutionEnvironment,
        endpoints = endpoints.map { endpoint ->
            RdpEndpointUi(endpoint.id, endpoint.displayName, endpoint.host, endpoint.port,
                endpoint.username, endpoint.domain, endpoint.hasPassword,
                endpoint.approvedFingerprintSHA256, endpoint.passwordRef?.keychainAccount)
        },
    )

    private fun C05RdpSession.toUi(bitmap: Bitmap?, fps: Double): RdpSessionUi =
        RdpSessionUi(
            sessionID = id,
            profileID = profileID,
            endpointID = endpointID,
            displayName = displayName,
            host = host,
            port = port,
            username = username,
            domain = domain,
            state = state,
            width = width,
            height = height,
            revision = frameRevision,
            byteCount = frameBytes,
            bitmap = bitmap,
            failure = failure?.let {
                RdpFailureUi(
                    code = it.code,
                    message = it.message,
                    retryable = it.retryable,
                    category = it.category,
                    stage = it.stage,
                )
            },
            inputIssue = null,
            measuredFps = fps,
        )

    private fun C05RdpCertificatePrompt.toUi(): RdpCertificatePromptUi =
        RdpCertificatePromptUi(
            profileID = profileID,
            endpointID = endpointID,
            host = host,
            port = port,
            fingerprintSHA256 = fingerprintSHA256,
            subject = subject,
            kind = kind,
            reason = reason,
            notBefore = notBefore,
            notAfter = notAfter,
            expiresAt = expiresAt,
        )

    private fun C05RemoteFailure.toUi(): RdpFailureUi =
        RdpFailureUi(
            code = code,
            message = reason ?: detail ?: "The RDP operation failed",
            retryable = retryable,
            category = challenge?.let { "certificateTrust" } ?: "remoteDesktop",
            stage = "bridge",
        )

    private fun C05RDPException.toUi(): RdpFailureUi =
        RdpFailureUi(
            code = code,
            message = reason ?: detail ?: "The RDP operation failed",
            retryable = retryable,
            category = challenge?.let { "certificateTrust" } ?: "remoteDesktop",
            stage = "bridge",
        )
}
