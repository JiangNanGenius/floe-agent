// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C05 remote-host controller.
//
// Owns the trusted bridge calls, the live PTY poller and the bounded input
// lanes. Swift remains the session/trust/credential authority; the reused
// Termux emulator is presentation only. A session survives Activity
// reconstruction because this controller is app-scoped. It is fenced by the
// current native Root epoch on every request and is closed by RuntimeHost's
// root-stop gate.

package com.floe.android.host.remote

import android.util.Log
import com.floe.android.feature.remote.RemoteAuthUi
import com.floe.android.feature.remote.RemoteExecUi
import com.floe.android.feature.remote.RemoteHostDetailUi
import com.floe.android.feature.remote.RemoteHostDraft
import com.floe.android.feature.remote.RemoteHostKeyChallengeUi
import com.floe.android.feature.remote.RemoteHostSummaryUi
import com.floe.android.feature.remote.RemoteHostUiError
import com.floe.android.feature.remote.RemoteHostUiState
import com.floe.android.feature.remote.RemotePtyUi
import com.floe.android.feature.remote.RemoteSessionUi
import com.floe.android.feature.remote.RemoteTerminalUi
import com.floe.android.feature.remote.RemoteTunnelUi
import com.floe.android.feature.remote.normalizeFingerprint
import com.floe.android.feature.remote.sessionStatusLabel
import com.floe.android.feature.remote.validateRemoteHostDraft
import com.floe.android.feature.terminal.G04TerminalEngine
import com.floe.android.feature.terminal.TerminalEngineHost
import com.floe.android.feature.terminal.TerminalTransport
import java.nio.charset.StandardCharsets
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
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

internal class C05RemoteHostController(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val currentNativeEpoch: () -> Long?,
    private val client: C05RemoteClient = C05RemoteClient(),
    private val engineFactory: (Int, Int, TerminalEngineHost) -> G04TerminalEngine = { columns, rows, host ->
        G04TerminalEngine(columns, rows, host = host)
    },
    private val log: (String, String) -> Unit = { level, message ->
        Log.println(if (level == "error") Log.ERROR else Log.DEBUG, "FloeC05Remote", message)
    },
) {
    private val ownerToken = UUID.randomUUID().toString()
    private val _state = MutableStateFlow(RemoteHostUiState())
    val state: StateFlow<RemoteHostUiState> = _state.asStateFlow()

    private val rawDetails = mutableMapOf<String, C05HostDetail>()
    private var ptyPoller: Job? = null
    private var sessionPoller: Job? = null
    private var execPoller: Job? = null
    private var inputJob: Job? = null
    private var lane: C05RemoteInputLane? = null
    private var activePtyID: String? = null
    private var ptyCursor: Long = 0L
    private var execCursor: Long = 0L
    private var resizeJob: Job? = null
    private val resizeChannel = Channel<Pair<Int, Int>>(Channel.CONFLATED)
    @Volatile private var terminalVisible = true
    @Volatile private var loaded = false
    @Volatile private var lastKnownEpoch: Long = 0L

    fun enter() {
        if (!loaded) {
            loaded = true
            load()
        }
    }

    fun setTerminalVisible(visible: Boolean) {
        terminalVisible = visible
    }

    fun load() {
        scope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                val capabilities = withContext(ioDispatcher) { client.capabilities() }
                if (!capabilities.coreReady) {
                    _state.update {
                        it.copy(
                            loading = false,
                            coreReady = false,
                            credentialGatewayReady = capabilities.credentialGatewayReady,
                        )
                    }
                    return@launch
                }
                val owner = owner()
                // This screen is the C05 SSH surface. VNC/BLE-only profiles
                // are durable host rows owned by the later packages and are
                // deliberately not offered an SSH editor here.
                val hosts = withContext(ioDispatcher) {
                    client.profileList(owner).filter { it.auth.kind != "none" }
                }
                val details = mutableMapOf<String, C05HostDetail>()
                for (host in hosts) {
                    runCatching {
                        withContext(ioDispatcher) { client.profileGet(host.id, owner) }
                    }.onSuccess { detail -> details[host.id] = detail }
                }
                rawDetails.clear()
                rawDetails.putAll(details)
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = true,
                        credentialGatewayReady = capabilities.credentialGatewayReady,
                        profiles = hosts.map(::mapSummary),
                        details = details.mapValues { (_, detail) -> mapDetail(detail) },
                    )
                }
            } catch (failure: C05RemoteFailure) {
                fail(failure, loading = false)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "loadFailed", detail = error.message), loading = false)
            }
        }
    }

    fun refresh() {
        loaded = true
        load()
    }

    fun selectedDetail(id: String?): RemoteHostDetailUi? {
        if (id == null) return null
        val detail = rawDetails[id] ?: return null
        return mapDetail(detail)
    }

    fun saveProfile(draft: RemoteHostDraft, secret: String?) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "save", error = null) }
            try {
                validateRemoteHostDraft(draft)?.let { reason ->
                    throw C05RemoteFailure(reason, reason)
                }
                val owner = owner()
                // Never wipe preserved jump/VNC/aux data just because the
                // cached detail was unavailable: re-read the durable profile
                // before building the replacement.
                val existing = draft.id?.let { id ->
                    rawDetails[id] ?: withContext(ioDispatcher) {
                        client.profileGet(id, owner)
                    }
                }
                val id = draft.id ?: UUID.randomUUID().toString()
                val kind = draft.authKind
                val existingAccount = existing?.summary?.auth?.credential?.keychainAccount
                val sameKind = existing?.summary?.auth?.kind == kind
                val sameKeyType = kind != RemoteHostDraft.AUTH_KEY ||
                    existing?.summary?.auth?.keyType == draft.keyType
                val reusableCredential = sameKind && sameKeyType
                val account = if (reusableCredential && existingAccount != null) {
                    existingAccount
                } else {
                    "floe.ssh.${id}.${if (kind == RemoteHostDraft.AUTH_KEY) "key" else "password"}"
                }
                if (!secret.isNullOrBlank()) {
                    val secretBytes = secret.toByteArray(StandardCharsets.UTF_8)
                    try {
                        withContext(ioDispatcher) {
                            client.credentialSave(
                                account = account,
                                synchronizable = false,
                                secret = secretBytes,
                                owner = owner,
                            )
                        }
                    } finally {
                        secretBytes.fill(0)
                    }
                } else if (!reusableCredential || existingAccount == null) {
                    throw C05RemoteFailure("credentialMissing", "credentialMissing")
                }
                val payload = C05ProfilePayload(
                    id = id,
                    displayName = draft.displayName.trim(),
                    address = draft.address.trim(),
                    port = draft.port.trim().toIntOrNull()
                        ?: throw C05RemoteFailure("portInvalid", "portInvalid"),
                    user = draft.user.trim(),
                    auth = C05Auth(
                        kind = kind,
                        keyType = if (kind == RemoteHostDraft.AUTH_KEY) draft.keyType else null,
                        credential = C05CredentialRef(account, false),
                    ),
                    jumpChain = existing?.jumpChain ?: emptyList(),
                    hostKeyPolicy = draft.hostKeyPolicy,
                    pinnedFingerprint = if (draft.hostKeyPolicy == RemoteHostDraft.POLICY_PINNED) {
                        normalizeFingerprint(draft.pinnedFingerprint)
                    } else {
                        null
                    },
                    allowsLegacyAlgorithms = draft.allowsLegacyAlgorithms,
                    deviceKind = existing?.summary?.deviceKind ?: "unspecified",
                    isRemoteExecutionEnvironment = true,
                    vncEndpoints = existing?.vncEndpoints ?: emptyList(),
                    auxiliaryConnections = existing?.auxiliaryConnections ?: emptyList(),
                )
                withContext(ioDispatcher) { client.profileSave(payload, owner) }
                _state.update { it.copy(busy = null) }
                load()
            } catch (failure: C05RemoteFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "saveFailed", detail = error.message), busy = null)
            }
        }
    }

    fun deleteProfile(id: String) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "delete", error = null) }
            try {
                val owner = owner()
                withContext(ioDispatcher) { client.profileDelete(id, owner) }
                if (_state.value.session?.profileID == id) {
                    clearSessionState()
                }
                rawDetails.remove(id)
                _state.update { it.copy(busy = null, profiles = it.profiles.filterNot { host -> host.id == id }) }
                load()
            } catch (failure: C05RemoteFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "deleteFailed", detail = error.message), busy = null)
            }
        }
    }

    fun connect(profileID: String) {
        if (_state.value.busy != null || _state.value.session != null) return
        scope.launch {
            _state.update { it.copy(busy = "connect", error = null, challenge = null) }
            try {
                val owner = owner()
                val session = withContext(ioDispatcher) { client.connect(profileID, owner) }
                _state.update {
                    it.copy(
                        busy = null,
                        session = mapSession(session),
                        tunnels = emptyList(),
                        exec = null,
                        terminal = null,
                    )
                }
                startSessionPoller(session.id)
                openTerminal(session.id)
            } catch (failure: C05RemoteFailure) {
                if (failure.challenge != null) {
                    _state.update {
                        it.copy(busy = null, challenge = mapChallenge(failure.challenge))
                    }
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "connectFailed", detail = error.message), busy = null)
            }
        }
    }

    fun approveChallenge(accept: Boolean, replaceChanged: Boolean) {
        val challenge = _state.value.challenge ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "trust", error = null) }
            try {
                val owner = owner()
                withContext(ioDispatcher) {
                    client.hostKeyApprove(
                        challengeID = challenge.id,
                        accept = accept,
                        replaceChanged = replaceChanged,
                        expectedFingerprint = challenge.expectedFingerprintSHA256,
                        owner = owner,
                    )
                }
                _state.update { it.copy(busy = null, challenge = null) }
                if (accept) {
                    connect(challenge.profileID)
                }
            } catch (failure: C05RemoteFailure) {
                if (failure.code == "challengeExpired" || failure.code == "challengeNotFound") {
                    _state.update { it.copy(challenge = null) }
                }
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "trustFailed", detail = error.message), busy = null)
            }
        }
    }

    fun closeSession() {
        val session = _state.value.session ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "close") }
            try {
                val owner = owner()
                val result = withContext(ioDispatcher) { client.sessionClose(session.id, owner) }
                if (result.complete) {
                    clearSessionState()
                } else {
                    _state.update {
                        it.copy(
                            busy = null,
                            error = RemoteHostUiError("cleanupIncomplete", null),
                        )
                    }
                }
            } catch (failure: C05RemoteFailure) {
                if (failure.code == "sessionNotFound") {
                    clearSessionState()
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "closeFailed", detail = error.message), busy = null)
            }
        }
    }

    fun openTunnel(targetHost: String, targetPort: Int) {
        val session = _state.value.session ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "tunnel", error = null) }
            try {
                val owner = owner()
                val tunnel = withContext(ioDispatcher) {
                    client.tunnelOpen(session.id, targetHost, targetPort, owner)
                }
                _state.update {
                    it.copy(
                        busy = null,
                        tunnels = (it.tunnels + mapTunnel(tunnel)).distinctBy(RemoteTunnelUi::id),
                    )
                }
            } catch (failure: C05RemoteFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "tunnelFailed", detail = error.message), busy = null)
            }
        }
    }

    fun closeTunnel(tunnelID: String) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "tunnel") }
            try {
                val owner = owner()
                val tunnel = withContext(ioDispatcher) { client.tunnelClose(tunnelID, owner) }
                _state.update {
                    it.copy(
                        busy = null,
                        tunnels = it.tunnels.map { current ->
                            if (current.id == tunnel.id) mapTunnel(tunnel) else current
                        },
                    )
                }
            } catch (failure: C05RemoteFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "tunnelCloseFailed", detail = error.message), busy = null)
            }
        }
    }

    fun startExec(command: String) {
        val session = _state.value.session ?: return
        if (_state.value.busy != null) return
        if (_state.value.exec != null) return
        if (command.trim().isEmpty()) return
        scope.launch {
            _state.update { it.copy(busy = "exec", error = null) }
            try {
                val owner = owner()
                val exec = withContext(ioDispatcher) { client.execStart(session.id, command, owner) }
                execCursor = 0L
                _state.update {
                    it.copy(busy = null, exec = mapExec(exec, output = ""))
                }
                startExecPoller(exec.id)
            } catch (failure: C05RemoteFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "execFailed", detail = error.message), busy = null)
            }
        }
    }

    fun cancelExec() {
        val exec = _state.value.exec ?: return
        scope.launch {
            try {
                val owner = owner()
                val cancelled = withContext(ioDispatcher) { client.execCancel(exec.id, owner) }
                _state.update {
                    it.copy(exec = it.exec?.copy(
                        state = cancelled.state,
                        exitCode = cancelled.exitCode,
                        remoteOutcomeUnknown = cancelled.remoteOutcomeUnknown,
                    ))
                }
            } catch (failure: C05RemoteFailure) {
                fail(failure)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "execCancelFailed", detail = error.message))
            }
        }
    }

    fun releaseExec() {
        val exec = _state.value.exec ?: return
        scope.launch {
            try {
                val owner = owner()
                withContext(ioDispatcher) { client.execRelease(exec.id, owner) }
                execPoller?.cancel()
                execPoller = null
                _state.update { it.copy(exec = null) }
            } catch (failure: C05RemoteFailure) {
                fail(failure)
            } catch (error: Throwable) {
                fail(C05RemoteFailure("unknown", "execReleaseFailed", detail = error.message))
            }
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun onOwnedStoreReady() {
        loaded = true
        load()
    }

    fun onRootStopped() {
        cancelLocalWork()
        loaded = false
        _state.value = RemoteHostUiState(loading = false, coreReady = false)
    }

    suspend fun prepareForRootStop(timeoutMillis: Long = 8_000): Boolean {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
            ?: lastKnownEpoch.takeIf { it > 0 }
            ?: return true
        cancelLocalWork()
        _state.update { it.copy(challenge = null, busy = null) }
        return try {
            val result = withTimeoutOrNull(timeoutMillis) {
                withContext(ioDispatcher) { client.rootStop(epoch) }
            }
            if (result?.drained == true) {
                _state.update {
                    it.copy(
                        session = null,
                        terminal = null,
                        tunnels = emptyList(),
                        exec = null,
                        loading = false,
                    )
                }
            }
            result?.drained ?: false
        } catch (failure: C05RemoteFailure) {
            // A core without v9 or an already-retired runtime cannot own a
            // C05 session; there is nothing left to drain.
            failure.code == "needsCoreUpdate" ||
                failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }
    }

    // MARK: - Terminal

    private suspend fun openTerminal(sessionID: String) {
        try {
            val owner = owner()
            val pty = withContext(ioDispatcher) {
                client.ptyOpen(
                    sessionID = sessionID,
                    term = "xterm-256color",
                    columns = 120,
                    rows = 32,
                    owner = owner,
                )
            }
            val terminal = withContext(mainDispatcher) {
                createTerminal(pty)
            }
            _state.update { it.copy(terminal = terminal) }
            ptyCursor = 0L
            startPtyPoller(pty.id)
            startResizePump(pty.id)
        } catch (failure: C05RemoteFailure) {
            fail(failure)
        } catch (error: Throwable) {
            fail(C05RemoteFailure("unknown", "ptyOpenFailed", detail = error.message))
        }
    }

    private fun createTerminal(pty: C05Pty): RemoteTerminalUi {
        val engineHost = object : TerminalEngineHost {
            override fun writeToPty(bytes: ByteArray) {
                enqueueInput(pty.id, bytes)
            }

            override fun log(level: String, message: String) {
                log(level, "terminal ${pty.id.take(8)}: $message")
            }
        }
        val engine = engineFactory(pty.columns, pty.rows, engineHost)
        val inputLane = C05RemoteInputLane(
            sink = { bytes -> writePty(pty.id, bytes) },
            onIssue = { issue ->
                scope.launch(mainDispatcher) {
                    _state.update { it.copy(terminal = it.terminal?.copy(inputIssue = issue)) }
                }
            },
        )
        lane?.close()
        lane = inputLane
        activePtyID = pty.id
        inputJob?.cancel()
        inputJob = scope.launch(ioDispatcher) { inputLane.run() }
        return RemoteTerminalUi(
            pty = mapPty(pty),
            engine = engine,
            transport = object : TerminalTransport {
                override fun write(bytes: ByteArray) = enqueueInput(pty.id, bytes)
                override fun resize(columns: Int, rows: Int) {
                    resizeChannel.trySend(columns to rows)
                }
            },
            status = sessionStatusLabel("connected", true),
            inputIssue = null,
        )
    }

    private fun enqueueInput(ptyID: String, bytes: ByteArray) {
        if (ptyID != activePtyID) return
        val issue = lane?.offer(bytes)
        if (issue != null) {
            _state.update { it.copy(terminal = it.terminal?.copy(inputIssue = issue)) }
        }
    }

    private suspend fun writePty(ptyID: String, bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(bytes.size, offset + C05RemoteClient.MAX_WRITE_BYTES)
            val chunk = bytes.copyOfRange(offset, end)
            withContext(ioDispatcher) {
                client.ptyWrite(ptyID, chunk, owner())
            }
            offset = end
        }
        if (_state.value.terminal?.inputIssue != null) {
            _state.update { it.copy(terminal = it.terminal?.copy(inputIssue = null)) }
        }
    }

    private fun startPtyPoller(ptyID: String) {
        ptyPoller?.cancel()
        ptyPoller = scope.launch(ioDispatcher) {
            while (isActive) {
                if (!terminalVisible) {
                    delay(150)
                    continue
                }
                val terminal = _state.value.terminal
                if (terminal == null || terminal.pty.id != ptyID) return@launch
                try {
                    val page = client.ptyRead(ptyID, ptyCursor, 32 * 1024, owner())
                    ptyCursor = page.nextCursor
                    if (page.bytes.isNotEmpty()) {
                        withContext(mainDispatcher) {
                            val current = _state.value.terminal
                            if (current?.pty?.id == ptyID) current.engine.feed(page.bytes)
                        }
                    }
                    val state = page.state
                    _state.update {
                        it.copy(
                            terminal = it.terminal?.copy(
                                pty = it.terminal.pty.copy(
                                    state = state,
                                    totalBytes = page.totalBytes,
                                    rolledOverBytes = page.rolledOverBytes,
                                ),
                                status = ptyStatus(state, page.lostBytes),
                                inputIssue = if (page.lostBytes > 0L) "outputRolled" else it.terminal.inputIssue,
                            )
                        )
                    }
                    if (state == "closed") {
                        return@launch
                    } else if (state == "unknown") {
                        delay(250)
                    } else {
                        delay(25)
                    }
                } catch (failure: C05RemoteFailure) {
                    if (failure.code == "ptyNotFound" ||
                        failure.code == "sessionNotFound" ||
                        failure.code == "staleEpoch"
                    ) {
                        _state.update { it.copy(terminal = null) }
                        fail(failure)
                        return@launch
                    }
                    delay(250)
                } catch (_: Throwable) {
                    delay(250)
                }
            }
        }
    }

    private fun ptyStatus(state: String, lostBytes: Long): String = when {
        lostBytes > 0 -> "outputRolled"
        else -> sessionStatusLabel(if (state == "running") "connected" else state, state == "running")
    }

    private fun startResizePump(ptyID: String) {
        resizeJob?.cancel()
        while (resizeChannel.tryReceive().isSuccess) {
            // Drop any resize queued for a previous PTY.
        }
        resizeJob = scope.launch(ioDispatcher) {
            for ((columns, rows) in resizeChannel) {
                try {
                    val pty = client.ptyResize(ptyID, columns, rows, owner())
                    _state.update {
                        it.copy(terminal = it.terminal?.copy(pty = mapPty(pty)))
                    }
                } catch (_: Throwable) {
                    delay(250)
                }
            }
        }
    }

    private fun startSessionPoller(sessionID: String) {
        sessionPoller?.cancel()
        sessionPoller = scope.launch(ioDispatcher) {
            while (isActive) {
                try {
                    val detail = client.sessionStatus(sessionID, owner())
                    _state.update {
                        it.copy(
                            session = mapSession(detail.session),
                            tunnels = detail.tunnels.map(::mapTunnel),
                        )
                    }
                    if (detail.session.state == "closed") {
                        clearSessionState()
                        return@launch
                    }
                } catch (failure: C05RemoteFailure) {
                    if (failure.code == "sessionNotFound" || failure.code == "staleEpoch") {
                        clearSessionState()
                        fail(failure)
                        return@launch
                    }
                } catch (_: Throwable) {
                    // Keep the last honest projection; the next poll retries.
                }
                delay(2_000)
            }
        }
    }

    // MARK: - Exec

    private fun startExecPoller(execID: String) {
        execPoller?.cancel()
        execPoller = scope.launch(ioDispatcher) {
            while (isActive) {
                val current = _state.value.exec
                if (current == null || current.id != execID) return@launch
                try {
                    val page = client.execRead(execID, execCursor, 32 * 1024, owner())
                    execCursor = page.nextCursor
                    val appended = buildString {
                        page.chunks.forEach { chunk ->
                            if (chunk.channel == "stderr") append("[stderr] ")
                            append(String(chunk.data, StandardCharsets.UTF_8))
                        }
                    }
                    _state.update {
                        val previous = it.exec?.output.orEmpty()
                        val combined = (previous + appended).takeLast(MAX_EXEC_OUTPUT)
                        it.copy(
                            exec = mapExec(
                                page.exec,
                                output = combined,
                                truncated = page.lostBytes > 0L || page.exec.rolledOverBytes > 0L,
                            )
                        )
                    }
                    val state = page.exec.state
                    if (state == "exited" || state == "cancelled" || state == "unknown") {
                        delay(250)
                    } else {
                        delay(100)
                    }
                } catch (failure: C05RemoteFailure) {
                    if (failure.code == "execNotFound" || failure.code == "sessionNotFound") {
                        _state.update { it.copy(exec = null) }
                        return@launch
                    }
                    delay(250)
                } catch (_: Throwable) {
                    delay(250)
                }
            }
        }
    }

    // MARK: - Mapping

    private fun mapSummary(host: C05HostSummary): RemoteHostSummaryUi = RemoteHostSummaryUi(
        id = host.id,
        displayName = host.displayName,
        address = host.address,
        port = host.port,
        user = host.user,
        auth = RemoteAuthUi(
            kind = host.auth.kind,
            keyType = host.auth.keyType,
            credentialAccount = host.auth.credential?.keychainAccount,
        ),
        hostKeyPolicy = host.hostKeyPolicy,
        pinnedFingerprint = host.pinnedFingerprint,
        allowsLegacyAlgorithms = host.allowsLegacyAlgorithms,
        jumpHopCount = host.jumpHopCount,
        vncEndpointCount = host.vncEndpointCount,
        auxiliaryConnectionCount = host.auxiliaryConnectionCount,
    )

    private fun mapDetail(detail: C05HostDetail): RemoteHostDetailUi = RemoteHostDetailUi(
        summary = mapSummary(detail.summary),
        jumpHops = detail.jumpChain.map { "${it.user}@${it.address}:${it.port}" },
        vncEndpointCount = detail.vncEndpoints.size,
        auxiliaryConnectionCount = detail.auxiliaryConnections.size,
    )

    private fun mapSession(session: C05Session): RemoteSessionUi = RemoteSessionUi(
        id = session.id,
        displayName = session.displayName,
        address = session.address,
        port = session.port,
        user = session.user,
        state = session.state,
        transportConnected = session.transportConnected,
        ptyCount = session.ptyCount,
        tunnelCount = session.tunnelCount,
    )

    private fun mapPty(pty: C05Pty): RemotePtyUi = RemotePtyUi(
        id = pty.id,
        state = pty.state,
        columns = pty.columns,
        rows = pty.rows,
        totalBytes = pty.totalBytes,
        rolledOverBytes = pty.rolledOverBytes,
    )

    private fun mapTunnel(tunnel: C05Tunnel): RemoteTunnelUi = RemoteTunnelUi(
        id = tunnel.id,
        targetHost = tunnel.targetHost,
        targetPort = tunnel.targetPort,
        localPort = tunnel.localPort,
        state = tunnel.state,
        acceptedConnections = tunnel.acceptedConnections,
        activeConnections = tunnel.activeConnections,
        bytesToRemote = tunnel.bytesToRemote,
        bytesFromRemote = tunnel.bytesFromRemote,
        lastErrorCode = tunnel.lastErrorCode,
    )

    private fun mapExec(exec: C05Exec, output: String, truncated: Boolean = false): RemoteExecUi = RemoteExecUi(
        id = exec.id,
        state = exec.state,
        output = output,
        stdoutBytes = exec.stdoutBytes,
        stderrBytes = exec.stderrBytes,
        exitCode = exec.exitCode,
        remoteOutcomeUnknown = exec.remoteOutcomeUnknown,
        truncated = truncated,
    )

    private fun mapChallenge(challenge: C05HostKeyChallenge): RemoteHostKeyChallengeUi =
        RemoteHostKeyChallengeUi(
            id = challenge.id,
            profileID = challenge.profileID,
            address = challenge.address,
            port = challenge.port,
            keyType = challenge.keyType,
            fingerprintSHA256 = challenge.fingerprintSHA256,
            expectedFingerprintSHA256 = challenge.expectedFingerprintSHA256,
            changed = challenge.changed,
        )

    // MARK: - Lifecycle helpers

    private fun owner(): C05RemoteOwner {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
            ?: throw C05RemoteFailure("staleEpoch", "nativeEpochUnavailable")
        lastKnownEpoch = epoch
        return C05RemoteOwner(token = ownerToken, nativeEpoch = epoch)
    }

    private fun fail(failure: C05RemoteFailure, busy: String? = _state.value.busy, loading: Boolean = _state.value.loading) {
        _state.update {
            it.copy(
                busy = busy,
                loading = loading,
                error = RemoteHostUiError(failure.code, failure.detail),
            )
        }
    }

    private fun clearSessionState() {
        ptyPoller?.cancel(); ptyPoller = null
        sessionPoller?.cancel(); sessionPoller = null
        execPoller?.cancel(); execPoller = null
        inputJob?.cancel(); inputJob = null
        resizeJob?.cancel(); resizeJob = null
        lane?.close(); lane = null
        activePtyID = null
        ptyCursor = 0L
        execCursor = 0L
        _state.update {
            it.copy(
                busy = null,
                session = null,
                terminal = null,
                tunnels = emptyList(),
                exec = null,
            )
        }
    }

    private fun cancelLocalWork() {
        ptyPoller?.cancel(); ptyPoller = null
        sessionPoller?.cancel(); sessionPoller = null
        execPoller?.cancel(); execPoller = null
        inputJob?.cancel(); inputJob = null
        resizeJob?.cancel(); resizeJob = null
        lane?.close(); lane = null
        activePtyID = null
    }

    companion object {
        private const val MAX_EXEC_OUTPUT = 64 * 1024
    }
}
