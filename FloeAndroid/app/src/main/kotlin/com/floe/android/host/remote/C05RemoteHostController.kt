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

import android.graphics.Bitmap
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
import com.floe.android.feature.remote.RemoteVncEndpointDraft
import com.floe.android.feature.remote.RemoteVncEndpointUi
import com.floe.android.feature.remote.RemoteVncFailureUi
import com.floe.android.feature.remote.RemoteVncHostDraft
import com.floe.android.feature.remote.RemoteVncUi
import com.floe.android.feature.remote.normalizeFingerprint
import com.floe.android.feature.remote.sessionStatusLabel
import com.floe.android.feature.remote.validateRemoteHostDraft
import com.floe.android.feature.remote.validateRemoteVncEndpointDraft
import com.floe.android.feature.remote.validateRemoteVncHostDraft
import com.floe.android.feature.terminal.G04TerminalEngine
import com.floe.android.feature.terminal.TerminalEngineHost
import com.floe.android.feature.terminal.TerminalTransport
import java.nio.ByteBuffer
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
    private val vncClient: C05VNCClient = C05VNCClient(),
    private val vncVideo: C05VNCVideoTransport = C05VNCVideoNative,
    private val localNetwork: C05LocalNetworkGate? = null,
    private val bitmapFactory: (Int, Int) -> Bitmap? = { width, height ->
        runCatching { Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888) }.getOrNull()
    },
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
    private val gate = C05RequestGate(currentNativeEpoch)

    private val rawDetails = mutableMapOf<String, C05HostDetail>()
    private var vncStatusJob: Job? = null
    private var vncFrameJob: Job? = null
    private var vncInputJob: Job? = null
    private var vncLane: C05VNCInputLane? = null
    private var vncEpoch: Long = 0L
    private var vncLastRevision: Long = -1L
    private var vncFrameCount: Int = 0
    private var vncFrameWindowStart: Long = 0L
    @Volatile private var vncVisible: Boolean = true
    private var pendingVncProfileID: String? = null
    private var pendingVncEndpointID: String? = null
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
        val token = gate.beginLoad() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), loading = false)
            return
        }
        scope.launch {
            if (!gate.isLiveLoad(token)) return@launch
            _state.update { it.copy(loading = true, error = null) }
            try {
                val capabilities = withContext(ioDispatcher) { client.capabilities() }
                if (!gate.isLiveLoad(token)) return@launch
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
                // This is the independently fenced profile-list load lane,
                // not an SSH/VNC request token (their sequence counters differ).
                val owner = ownerForEpoch(token.epoch)
                // The screen lists every durable host profile, including
                // VNC-only rows that deliberately have no SSH identity.
                val hosts = withContext(ioDispatcher) {
                    client.profileList(owner)
                }
                if (!gate.isLiveLoad(token)) return@launch
                val details = mutableMapOf<String, C05HostDetail>()
                for (host in hosts) {
                    if (!gate.isLiveLoad(token)) return@launch
                    runCatching {
                        withContext(ioDispatcher) { client.profileGet(host.id, owner) }
                    }.onSuccess { detail -> details[host.id] = detail }
                }
                if (!gate.isLiveLoad(token)) return@launch
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
                if (gate.isLiveLoad(token)) fail(failure, loading = false)
            } catch (error: Throwable) {
                if (gate.isLiveLoad(token)) {
                    fail(C05RemoteFailure("unknown", "loadFailed", detail = error.message), loading = false)
                }
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
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "save", error = null) }
            try {
                validateRemoteHostDraft(draft)?.let { reason ->
                    throw C05RemoteFailure(reason, reason)
                }
                val owner = ownerFor(token) ?: return@launch
                // Never wipe preserved jump/VNC/aux data just because the
                // cached detail was unavailable: re-read the durable profile
                // before building the replacement.
                val existing = draft.id?.let { id ->
                    rawDetails[id] ?: withContext(ioDispatcher) {
                        client.profileGet(id, owner)
                    }
                }
                if (!gate.isLiveSSH(token)) return@launch
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
                if (!gate.isLiveSSH(token)) return@launch
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
                    vncEndpoints = existing?.vncEndpoints
                        ?.map { it.vncNamespaceOnly() }
                        ?: emptyList(),
                    auxiliaryConnections = existing?.auxiliaryConnections ?: emptyList(),
                )
                withContext(ioDispatcher) { client.profileSave(payload, owner) }
                if (!gate.isLiveSSH(token)) return@launch
                _state.update { it.copy(busy = null) }
                load()
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "saveFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun deleteProfile(id: String) {
        if (_state.value.busy != null) return
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "delete", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val vnc = _state.value.vnc
                if (vnc?.profileID == id) {
                    stopVNCWork()
                    runCatching { withContext(ioDispatcher) { vncClient.close(vnc.sessionID, owner) } }
                    _state.update { it.copy(vnc = null) }
                }
                val vncRefs = rawDetails[id]?.vncEndpoints
                    ?.mapNotNull { it.passwordRef }
                    ?.filter { it.keychainAccount.startsWith("floe.vnc.") }
                    ?: emptyList()
                withContext(ioDispatcher) { client.profileDelete(id, owner) }
                if (!gate.isLiveSSH(token)) return@launch
                vncRefs.forEach { ref ->
                    runCatching { withContext(ioDispatcher) { vncClient.credentialDelete(ref, owner) } }
                }
                if (_state.value.session?.profileID == id) {
                    gate.finishSSHSession(_state.value.session?.id ?: "")
                    clearSessionState()
                }
                rawDetails.remove(id)
                _state.update {
                    it.copy(
                        busy = null,
                        profiles = it.profiles.filterNot { host -> host.id == id },
                    )
                }
                load()
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "deleteFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun connect(profileID: String) {
        if (_state.value.busy != null || _state.value.session != null) return
        val summary = _state.value.profiles.firstOrNull { it.id == profileID } ?: run {
            fail(C05RemoteFailure("profileNotFound", "profileNotFound"), busy = null)
            return
        }
        if (!summary.hasSSH) {
            fail(C05RemoteFailure("sshCredentialsRequired", "sshCredentialsRequired"), busy = null)
            return
        }
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        _state.update { it.copy(busy = "connect", error = null, challenge = null) }
        val endpoint = "ssh://${summary.address}:${summary.port}"
        val gateResult = localNetwork?.runExplicitAction(
            ownerID = profileID,
            endpoint = endpoint,
            isCurrent = { gate.isLiveSSH(token) },
            onDenied = { code ->
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure(code, code), busy = null, loading = false)
                }
            },
            dispatch = { startSSHConnect(profileID, token) },
        )
        if (gateResult == null) {
            startSSHConnect(profileID, token)
        } else if (!gateResult && gate.isLiveSSH(token)) {
            _state.update { it.copy(busy = null) }
        }
    }

    private fun startSSHConnect(profileID: String, token: C05RequestGate.Token) {
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "connect", error = null, challenge = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val session = withContext(ioDispatcher) { client.connect(profileID, owner) }
                if (!gate.isLiveSSH(token)) {
                    runCatching { withContext(ioDispatcher) { client.sessionClose(session.id, owner) } }
                    return@launch
                }
                val sessionToken = gate.beginSSHSession(session.id)
                _state.update {
                    it.copy(
                        busy = null,
                        session = mapSession(session),
                        tunnels = emptyList(),
                        exec = null,
                        terminal = null,
                    )
                }
                startSessionPoller(session.id, sessionToken, owner.nativeEpoch)
                openTerminal(session.id, sessionToken, owner.nativeEpoch)
            } catch (failure: C05RemoteFailure) {
                if (!gate.isLiveSSH(token)) return@launch
                if (failure.challenge != null) {
                    _state.update {
                        it.copy(busy = null, challenge = mapChallenge(failure.challenge))
                    }
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "connectFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun approveChallenge(accept: Boolean, replaceChanged: Boolean) {
        val challenge = _state.value.challenge ?: return
        if (_state.value.busy != null) return
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "trust", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                withContext(ioDispatcher) {
                    client.hostKeyApprove(
                        challengeID = challenge.id,
                        accept = accept,
                        replaceChanged = replaceChanged,
                        expectedFingerprint = challenge.expectedFingerprintSHA256,
                        owner = owner,
                    )
                }
                if (!gate.isLiveSSH(token)) return@launch
                _state.update { it.copy(busy = null, challenge = null) }
                if (accept) {
                    val pendingProfile = pendingVncProfileID
                    val pendingEndpoint = pendingVncEndpointID
                    pendingVncProfileID = null
                    pendingVncEndpointID = null
                    if (pendingProfile != null) {
                        connectVNC(pendingProfile, pendingEndpoint)
                    } else {
                        connect(challenge.profileID)
                    }
                } else {
                    pendingVncProfileID = null
                    pendingVncEndpointID = null
                }
            } catch (failure: C05RemoteFailure) {
                if (!gate.isLiveSSH(token)) return@launch
                if (failure.code == "challengeExpired" || failure.code == "challengeNotFound") {
                    _state.update { it.copy(challenge = null) }
                }
                fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "trustFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun closeSession() {
        val session = _state.value.session ?: return
        if (_state.value.busy != null) return
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "close") }
            try {
                val owner = ownerFor(token) ?: return@launch
                val vnc = _state.value.vnc
                if (vnc?.sshSessionID == session.id) {
                    stopVNCWork()
                    runCatching { withContext(ioDispatcher) { vncClient.close(vnc.sessionID, owner) } }
                    _state.update { it.copy(vnc = null) }
                }
                val result = withContext(ioDispatcher) { client.sessionClose(session.id, owner) }
                if (!gate.isLiveSSH(token)) return@launch
                if (result.complete) {
                    gate.finishSSHSession(session.id)
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
                if (!gate.isLiveSSH(token)) return@launch
                if (failure.code == "sessionNotFound") {
                    gate.finishSSHSession(session.id)
                    clearSessionState()
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "closeFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun openTunnel(targetHost: String, targetPort: Int) {
        val session = _state.value.session ?: return
        if (_state.value.busy != null) return
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "tunnel", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val tunnel = withContext(ioDispatcher) {
                    client.tunnelOpen(session.id, targetHost, targetPort, owner)
                }
                if (!gate.isLiveSSH(token) || gate.currentSSHSession() != session.id) return@launch
                _state.update {
                    it.copy(
                        busy = null,
                        tunnels = (it.tunnels + mapTunnel(tunnel)).distinctBy(RemoteTunnelUi::id),
                    )
                }
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "tunnelFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun closeTunnel(tunnelID: String) {
        if (_state.value.busy != null) return
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "tunnel") }
            try {
                val owner = ownerFor(token) ?: return@launch
                val tunnel = withContext(ioDispatcher) { client.tunnelClose(tunnelID, owner) }
                if (!gate.isLiveSSH(token)) return@launch
                _state.update {
                    it.copy(
                        busy = null,
                        tunnels = it.tunnels.map { current ->
                            if (current.id == tunnel.id) mapTunnel(tunnel) else current
                        },
                    )
                }
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "tunnelCloseFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun startExec(command: String) {
        val session = _state.value.session ?: return
        if (_state.value.busy != null) return
        if (_state.value.exec != null) return
        if (command.trim().isEmpty()) return
        val token = gate.beginSSHRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveSSH(token)) return@launch
            _state.update { it.copy(busy = "exec", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val exec = withContext(ioDispatcher) { client.execStart(session.id, command, owner) }
                if (!gate.isLiveSSH(token) || gate.currentSSHSession() != session.id) return@launch
                execCursor = 0L
                _state.update {
                    it.copy(busy = null, exec = mapExec(exec, output = ""))
                }
                startExecPoller(exec.id, session.id, owner.nativeEpoch)
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "execFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun cancelExec() {
        val exec = _state.value.exec ?: return
        val token = gate.beginSSHRequest() ?: return
        scope.launch {
            try {
                val owner = ownerFor(token) ?: return@launch
                val cancelled = withContext(ioDispatcher) { client.execCancel(exec.id, owner) }
                if (!gate.isLiveSSH(token)) return@launch
                if (_state.value.exec?.id != exec.id) return@launch
                _state.update {
                    it.copy(exec = it.exec?.copy(
                        state = cancelled.state,
                        exitCode = cancelled.exitCode,
                        remoteOutcomeUnknown = cancelled.remoteOutcomeUnknown,
                    ))
                }
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "execCancelFailed", detail = error.message))
                }
            }
        }
    }

    fun releaseExec() {
        val exec = _state.value.exec ?: return
        val token = gate.beginSSHRequest() ?: return
        scope.launch {
            try {
                val owner = ownerFor(token) ?: return@launch
                withContext(ioDispatcher) { client.execRelease(exec.id, owner) }
                if (!gate.isLiveSSH(token)) return@launch
                if (_state.value.exec?.id != exec.id) return@launch
                execPoller?.cancel()
                execPoller = null
                _state.update { it.copy(exec = null) }
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveSSH(token)) fail(failure)
            } catch (error: Throwable) {
                if (gate.isLiveSSH(token)) {
                    fail(C05RemoteFailure("unknown", "execReleaseFailed", detail = error.message))
                }
            }
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun onOwnedStoreReady() {
        gate.cancelAll()
        loaded = true
        load()
    }

    fun onRootStopped() {
        gate.cancelAll()
        pendingVncProfileID = null
        pendingVncEndpointID = null
        cancelLocalWork()
        stopVNCWork()
        loaded = false
        _state.value = RemoteHostUiState(loading = false, coreReady = false)
    }

    suspend fun prepareForRootStop(timeoutMillis: Long = 8_000): Boolean {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
            ?: lastKnownEpoch.takeIf { it > 0 }
            ?: return true
        gate.cancelAll()
        pendingVncProfileID = null
        pendingVncEndpointID = null
        cancelLocalWork()
        stopVNCWork()
        _state.update { it.copy(challenge = null, busy = null) }

        val perCallTimeout = maxOf(1_000L, timeoutMillis / 2)
        val sshDrained = try {
            val result = withTimeoutOrNull(perCallTimeout) {
                withContext(ioDispatcher) { client.rootStop(epoch) }
            }
            result?.drained == true
        } catch (failure: C05RemoteFailure) {
            // A core without v9 or an already-retired runtime cannot own a
            // C05 SSH session; there is nothing left to drain.
            failure.code == "needsCoreUpdate" ||
                failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }

        val vncDrained = try {
            val result = withTimeoutOrNull(perCallTimeout) {
                withContext(ioDispatcher) { vncClient.rootStop(epoch) }
            }
            result?.drained == true
        } catch (failure: C05RemoteFailure) {
            failure.code == "needsCoreUpdate" ||
                failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }

        val drained = sshDrained && vncDrained
        if (drained) {
            _state.update {
                it.copy(
                    session = null,
                    terminal = null,
                    tunnels = emptyList(),
                    exec = null,
                    vnc = null,
                    loading = false,
                )
            }
        }
        return drained
    }

    // MARK: - Terminal

    private suspend fun openTerminal(sessionID: String, sessionToken: Long, epoch: Long) {
        try {
            if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return
            val pty = withContext(ioDispatcher) {
                client.ptyOpen(
                    sessionID = sessionID,
                    term = "xterm-256color",
                    columns = 120,
                    rows = 32,
                    owner = ownerForEpoch(epoch),
                )
            }
            if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) {
                runCatching {
                    withContext(ioDispatcher) { client.ptyClose(pty.id, ownerForEpoch(epoch)) }
                }
                return
            }
            val terminal = withContext(mainDispatcher) {
                createTerminal(pty, sessionID, sessionToken, epoch)
            }
            if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return
            _state.update { it.copy(terminal = terminal) }
            ptyCursor = 0L
            startPtyPoller(pty.id, sessionID, sessionToken, epoch)
            startResizePump(pty.id, sessionID, sessionToken, epoch)
        } catch (failure: C05RemoteFailure) {
            if (gate.isLiveSSHSession(sessionID, sessionToken, epoch)) fail(failure)
        } catch (error: Throwable) {
            if (gate.isLiveSSHSession(sessionID, sessionToken, epoch)) {
                fail(C05RemoteFailure("unknown", "ptyOpenFailed", detail = error.message))
            }
        }
    }

    private fun createTerminal(
        pty: C05Pty,
        sessionID: String,
        sessionToken: Long,
        epoch: Long,
    ): RemoteTerminalUi {
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
            sink = { bytes -> writePty(pty.id, bytes, sessionID, sessionToken, epoch) },
            onIssue = { issue ->
                scope.launch(mainDispatcher) {
                    if (gate.isLiveSSHSession(sessionID, sessionToken, epoch)) {
                        _state.update { it.copy(terminal = it.terminal?.copy(inputIssue = issue)) }
                    }
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

    private suspend fun writePty(
        ptyID: String,
        bytes: ByteArray,
        sessionID: String,
        sessionToken: Long,
        epoch: Long,
    ) {
        var offset = 0
        while (offset < bytes.size) {
            if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return
            val end = minOf(bytes.size, offset + C05RemoteClient.MAX_WRITE_BYTES)
            val chunk = bytes.copyOfRange(offset, end)
            withContext(ioDispatcher) {
                client.ptyWrite(ptyID, chunk, ownerForEpoch(epoch))
            }
            offset = end
        }
        if (gate.isLiveSSHSession(sessionID, sessionToken, epoch) &&
            _state.value.terminal?.inputIssue != null
        ) {
            _state.update { it.copy(terminal = it.terminal?.copy(inputIssue = null)) }
        }
    }

    private fun startPtyPoller(
        ptyID: String,
        sessionID: String,
        sessionToken: Long,
        epoch: Long,
    ) {
        ptyPoller?.cancel()
        ptyPoller = scope.launch(ioDispatcher) {
            while (isActive) {
                if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                if (!terminalVisible) {
                    delay(150)
                    continue
                }
                val terminal = _state.value.terminal
                if (terminal == null || terminal.pty.id != ptyID) return@launch
                try {
                    val page = client.ptyRead(ptyID, ptyCursor, 32 * 1024, ownerForEpoch(epoch))
                    if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                    ptyCursor = page.nextCursor
                    if (page.bytes.isNotEmpty()) {
                        withContext(mainDispatcher) {
                            val current = _state.value.terminal
                            if (gate.isLiveSSHSession(sessionID, sessionToken, epoch) &&
                                current?.pty?.id == ptyID
                            ) {
                                current.engine.feed(page.bytes)
                            }
                        }
                    }
                    if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                    val state = page.state
                    _state.update {
                        it.copy(
                            terminal = it.terminal?.copy(
                                pty = requireNotNull(it.terminal).pty.copy(
                                    state = state,
                                    totalBytes = page.totalBytes,
                                    rolledOverBytes = page.rolledOverBytes,
                                ),
                                status = ptyStatus(state, page.lostBytes),
                                inputIssue = if (page.lostBytes > 0L) "outputRolled" else requireNotNull(it.terminal).inputIssue,
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
                    if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
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

    private fun startResizePump(
        ptyID: String,
        sessionID: String,
        sessionToken: Long,
        epoch: Long,
    ) {
        resizeJob?.cancel()
        while (resizeChannel.tryReceive().isSuccess) {
            // Drop any resize queued for a previous PTY.
        }
        resizeJob = scope.launch(ioDispatcher) {
            for ((columns, rows) in resizeChannel) {
                if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                try {
                    val pty = client.ptyResize(ptyID, columns, rows, ownerForEpoch(epoch))
                    if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                    _state.update {
                        it.copy(terminal = it.terminal?.copy(pty = mapPty(pty)))
                    }
                } catch (_: Throwable) {
                    delay(250)
                }
            }
        }
    }

    private fun startSessionPoller(sessionID: String, sessionToken: Long, epoch: Long) {
        sessionPoller?.cancel()
        sessionPoller = scope.launch(ioDispatcher) {
            while (isActive) {
                if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                try {
                    val detail = client.sessionStatus(sessionID, ownerForEpoch(epoch))
                    if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                    _state.update {
                        it.copy(
                            session = mapSession(detail.session),
                            tunnels = detail.tunnels.map(::mapTunnel),
                        )
                    }
                    if (detail.session.state == "closed") {
                        if (_state.value.vnc?.sshSessionID == sessionID) {
                            stopVNCWork()
                            _state.update { it.copy(vnc = null) }
                        }
                        gate.finishSSHSession(sessionID)
                        clearSessionState()
                        return@launch
                    }
                } catch (failure: C05RemoteFailure) {
                    if (!gate.isLiveSSHSession(sessionID, sessionToken, epoch)) return@launch
                    if (failure.code == "sessionNotFound" || failure.code == "staleEpoch") {
                        if (_state.value.vnc?.sshSessionID == sessionID) {
                            stopVNCWork()
                            _state.update { it.copy(vnc = null) }
                        }
                        gate.finishSSHSession(sessionID)
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

    private fun startExecPoller(execID: String, sessionID: String, epoch: Long) {
        execPoller?.cancel()
        execPoller = scope.launch(ioDispatcher) {
            while (isActive) {
                val current = _state.value.exec
                if (current == null || current.id != execID) return@launch
                if (gate.currentSSHSession() != sessionID || currentNativeEpoch() != epoch) {
                    return@launch
                }
                try {
                    val page = client.execRead(execID, execCursor, 32 * 1024, ownerForEpoch(epoch))
                    if (gate.currentSSHSession() != sessionID || currentNativeEpoch() != epoch) return@launch
                    execCursor = page.nextCursor
                    val appended = buildString {
                        page.chunks.forEach { chunk ->
                            if (chunk.channel == "stderr") append("[stderr] ")
                            append(String(chunk.data, StandardCharsets.UTF_8))
                        }
                    }
                    if (gate.currentSSHSession() != sessionID || currentNativeEpoch() != epoch) return@launch
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
        vncEndpoints = detail.vncEndpoints.map { endpoint ->
            RemoteVncEndpointUi(
                id = endpoint.id,
                displayName = endpoint.displayName,
                transport = endpoint.transport,
                host = endpoint.host,
                port = endpoint.port,
                hasPassword = endpoint.passwordRef?.keychainAccount?.startsWith("floe.vnc.") == true,
            )
        },
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
        profileID = session.profileID,
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

    // MARK: - VNC host / endpoint editing

    fun saveVNCOnlyHost(draft: RemoteVncHostDraft) {
        if (_state.value.busy != null) return
        val token = gate.beginVNCRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveVNC(token)) return@launch
            _state.update { it.copy(busy = "vncSave", error = null) }
            val profileID = UUID.randomUUID().toString()
            val endpointID = UUID.randomUUID().toString()
            var savedCredential: C05VncPasswordRef? = null
            try {
                validateRemoteVncHostDraft(draft)?.let { reason ->
                    throw C05RemoteFailure(reason, reason)
                }
                val owner = ownerFor(token) ?: return@launch
                if (draft.password.isNotEmpty()) {
                    savedCredential = saveVncPassword(
                        endpointID = endpointID,
                        value = draft.password,
                        owner = owner,
                    )
                }
                if (!gate.isLiveVNC(token)) return@launch
                val profileDraft = C05VncProfileDraft(
                    id = profileID,
                    displayName = draft.displayName.trim(),
                    deviceKind = "unspecified",
                    endpoints = listOf(
                        C05VncEndpointDraft(
                            id = endpointID,
                            displayName = "VNC",
                            transport = "direct",
                            host = draft.host.trim(),
                            port = draft.port.trim().toIntOrNull() ?: 5900,
                            passwordRef = savedCredential,
                        )
                    ),
                )
                withContext(ioDispatcher) { vncClient.profileSaveVNCOnly(profileDraft, owner) }
                if (!gate.isLiveVNC(token)) return@launch
                _state.update { it.copy(busy = null) }
                load()
            } catch (failure: C05RemoteFailure) {
                savedCredential?.let { credential ->
                    runCatching {
                        val owner = ownerFor(token)
                        if (owner != null) {
                            withContext(ioDispatcher) { vncClient.credentialDelete(credential, owner) }
                        }
                    }
                }
                if (gate.isLiveVNC(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveVNC(token)) {
                    fail(C05RemoteFailure("unknown", "vncSaveFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun saveVncEndpoint(profileID: String, draft: RemoteVncEndpointDraft) {
        if (_state.value.busy != null) return
        val token = gate.beginVNCRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveVNC(token)) return@launch
            _state.update { it.copy(busy = "vncSave", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val detail = rawDetails[profileID] ?: withContext(ioDispatcher) {
                    client.profileGet(profileID, owner)
                }
                if (!gate.isLiveVNC(token)) return@launch
                val allowTunnel = detail.summary.auth.kind != "none"
                validateRemoteVncEndpointDraft(draft, allowTunnel)?.let { reason ->
                    throw C05RemoteFailure(reason, reason)
                }
                val endpointID = draft.id?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
                val existing = detail.vncEndpoints.firstOrNull { it.id == endpointID }
                var passwordRef = existing?.passwordRef
                    ?.takeIf { it.keychainAccount.startsWith("floe.vnc.") }
                if (draft.password.isNotEmpty()) {
                    passwordRef = saveVncPassword(
                        endpointID = endpointID,
                        value = draft.password,
                        owner = owner,
                    )
                } else if (!draft.keepPassword) {
                    existing?.passwordRef
                        ?.takeIf { it.keychainAccount.startsWith("floe.vnc.") }
                        ?.let { ref -> runCatching { withContext(ioDispatcher) {
                            vncClient.credentialDelete(ref, owner)
                        } } }
                    passwordRef = null
                }
                if (!gate.isLiveVNC(token)) return@launch
                val updated = C05VncEndpoint(
                    id = endpointID,
                    displayName = draft.displayName.trim(),
                    transport = draft.transport,
                    host = draft.host.trim(),
                    port = draft.port.trim().toIntOrNull() ?: 5900,
                    passwordRef = passwordRef,
                )
                val endpoints = detail.vncEndpoints
                    .filterNot { it.id == endpointID }
                    .map { it.vncNamespaceOnly() }
                    .plus(updated)
                val saved = if (!allowTunnel) {
                    val profileDraft = C05VncProfileDraft(
                        id = profileID,
                        displayName = detail.summary.displayName,
                        deviceKind = detail.summary.deviceKind,
                        endpoints = endpoints.map { endpoint ->
                            C05VncEndpointDraft(
                                id = endpoint.id,
                                displayName = endpoint.displayName,
                                transport = endpoint.transport,
                                host = endpoint.host,
                                port = endpoint.port,
                                passwordRef = endpoint.passwordRef,
                            )
                        },
                    )
                    withContext(ioDispatcher) { vncClient.profileSaveVNCOnly(profileDraft, owner) }
                } else {
                    val ref = detail.summary.auth.credential
                        ?: throw C05RemoteFailure("credentialMissing", "credentialMissing")
                    withContext(ioDispatcher) { client.profileSave(
                        C05ProfilePayload(
                            id = profileID,
                            displayName = detail.summary.displayName,
                            address = detail.summary.address,
                            port = detail.summary.port,
                            user = detail.summary.user,
                            auth = C05Auth(
                                kind = detail.summary.auth.kind,
                                keyType = detail.summary.auth.keyType,
                                credential = C05CredentialRef(ref.keychainAccount, ref.synchronizable),
                            ),
                            jumpChain = detail.jumpChain,
                            hostKeyPolicy = detail.summary.hostKeyPolicy,
                            pinnedFingerprint = detail.summary.pinnedFingerprint,
                            allowsLegacyAlgorithms = detail.summary.allowsLegacyAlgorithms,
                            deviceKind = detail.summary.deviceKind,
                            isRemoteExecutionEnvironment = true,
                            vncEndpoints = endpoints,
                            auxiliaryConnections = detail.auxiliaryConnections,
                        ),
                        owner,
                    ) }
                }
                if (!gate.isLiveVNC(token)) return@launch
                rawDetails[profileID] = saved
                _state.update {
                    it.copy(
                        busy = null,
                        details = it.details + (profileID to mapDetail(saved)),
                    )
                }
                load()
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveVNC(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveVNC(token)) {
                    fail(C05RemoteFailure("unknown", "vncSaveFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun deleteVncEndpoint(profileID: String, endpointID: String) {
        if (_state.value.busy != null) return
        val token = gate.beginVNCRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        scope.launch {
            if (!gate.isLiveVNC(token)) return@launch
            _state.update { it.copy(busy = "vncSave", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val detail = rawDetails[profileID] ?: withContext(ioDispatcher) {
                    client.profileGet(profileID, owner)
                }
                if (!gate.isLiveVNC(token)) return@launch
                val remaining = detail.vncEndpoints
                    .filterNot { it.id == endpointID }
                    .map { it.vncNamespaceOnly() }
                if (detail.summary.auth.kind == "none" && remaining.isEmpty()) {
                    throw C05RemoteFailure("vncEndpointMissing", "vncEndpointRequired")
                }
                val endpoint = detail.vncEndpoints.firstOrNull { it.id == endpointID }
                val saved = if (detail.summary.auth.kind == "none") {
                    withContext(ioDispatcher) { vncClient.profileSaveVNCOnly(
                        C05VncProfileDraft(
                            id = profileID,
                            displayName = detail.summary.displayName,
                            deviceKind = detail.summary.deviceKind,
                            endpoints = remaining.map { item ->
                                C05VncEndpointDraft(
                                    id = item.id,
                                    displayName = item.displayName,
                                    transport = item.transport,
                                    host = item.host,
                                    port = item.port,
                                    passwordRef = item.passwordRef,
                                )
                            },
                        ),
                        owner,
                    ) }
                } else {
                    val ref = detail.summary.auth.credential
                        ?: throw C05RemoteFailure("credentialMissing", "credentialMissing")
                    withContext(ioDispatcher) { client.profileSave(
                        C05ProfilePayload(
                            id = profileID,
                            displayName = detail.summary.displayName,
                            address = detail.summary.address,
                            port = detail.summary.port,
                            user = detail.summary.user,
                            auth = C05Auth(
                                kind = detail.summary.auth.kind,
                                keyType = detail.summary.auth.keyType,
                                credential = C05CredentialRef(ref.keychainAccount, ref.synchronizable),
                            ),
                            jumpChain = detail.jumpChain,
                            hostKeyPolicy = detail.summary.hostKeyPolicy,
                            pinnedFingerprint = detail.summary.pinnedFingerprint,
                            allowsLegacyAlgorithms = detail.summary.allowsLegacyAlgorithms,
                            deviceKind = detail.summary.deviceKind,
                            isRemoteExecutionEnvironment = true,
                            vncEndpoints = remaining,
                            auxiliaryConnections = detail.auxiliaryConnections,
                        ),
                        owner,
                    ) }
                }
                if (!gate.isLiveVNC(token)) return@launch
                endpoint?.passwordRef
                    ?.takeIf { it.keychainAccount.startsWith("floe.vnc.") }
                    ?.let { ref -> runCatching { withContext(ioDispatcher) {
                        vncClient.credentialDelete(ref, owner)
                    } } }
                rawDetails[profileID] = saved
                _state.update {
                    it.copy(
                        busy = null,
                        details = it.details + (profileID to mapDetail(saved)),
                    )
                }
                load()
            } catch (failure: C05RemoteFailure) {
                if (gate.isLiveVNC(token)) fail(failure, busy = null)
            } catch (error: Throwable) {
                if (gate.isLiveVNC(token)) {
                    fail(C05RemoteFailure("unknown", "vncSaveFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    private fun C05VncEndpoint.vncNamespaceOnly(): C05VncEndpoint =
        if (passwordRef == null ||
            passwordRef.keychainAccount.startsWith("floe.vnc.")
        ) {
            this
        } else {
            // Legacy/reference-shaped data from the SSH package cannot read
            // a provider/SSH secret merely by being named here.
            copy(passwordRef = null)
        }

    private suspend fun saveVncPassword(
        endpointID: String,
        value: String,
        owner: C05RemoteOwner,
    ): C05VncPasswordRef {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        try {
            return withContext(ioDispatcher) {
                vncClient.credentialSave(
                    // Endpoint UUIDs are globally unique; the profile UUID
                    // would push the account past the 80-byte reference
                    // bound enforced by the credential gateway.
                    account = "floe.vnc.${endpointID}.password",
                    synchronizable = false,
                    secret = bytes,
                    owner = owner,
                )
            }
        } finally {
            bytes.fill(0)
        }
    }

    // MARK: - VNC session

    fun connectVNC(profileID: String, endpointID: String? = null) {
        if (_state.value.busy != null || _state.value.vnc != null) return
        val detail = rawDetails[profileID]
        val endpoint = if (endpointID == null) {
            detail?.vncEndpoints?.firstOrNull()
        } else {
            detail?.vncEndpoints?.firstOrNull { it.id == endpointID }
        }
        if (detail == null || endpoint == null) {
            fail(C05RemoteFailure("vncEndpointMissing", "vncEndpointMissing"), busy = null)
            return
        }
        val token = gate.beginVNCRequest() ?: run {
            fail(C05RemoteFailure("staleEpoch", "nativeEpochUnavailable"), busy = null)
            return
        }
        _state.update { it.copy(busy = "vncConnect", error = null, challenge = null) }
        val endpointText = if (endpoint.transport == "direct") {
            "vnc://${endpoint.host}:${endpoint.port}"
        } else {
            "ssh://${detail.summary.address}:${detail.summary.port}"
        }
        val gateResult = localNetwork?.runExplicitAction(
            ownerID = profileID,
            endpoint = endpointText,
            isCurrent = { gate.isLiveVNC(token) },
            onDenied = { code ->
                if (gate.isLiveVNC(token)) {
                    fail(C05RemoteFailure(code, code), busy = null, loading = false)
                }
            },
            dispatch = { startVNCConnect(profileID, endpoint.id, token) },
        )
        if (gateResult == null) {
            startVNCConnect(profileID, endpoint.id, token)
        } else if (!gateResult && gate.isLiveVNC(token)) {
            _state.update { it.copy(busy = null) }
        }
    }

    private fun startVNCConnect(profileID: String, endpointID: String, token: C05RequestGate.Token) {
        scope.launch {
            if (!gate.isLiveVNC(token)) return@launch
            _state.update { it.copy(busy = "vncConnect", error = null) }
            try {
                val owner = ownerFor(token) ?: return@launch
                val vnc = withContext(ioDispatcher) {
                    vncClient.connect(
                        profileID = profileID,
                        endpointID = endpointID,
                        sshSessionID = _state.value.session?.id,
                        owner = owner,
                    )
                }
                if (!gate.isLiveVNC(token)) {
                    runCatching { withContext(ioDispatcher) { vncClient.close(vnc.id, owner) } }
                    return@launch
                }
                pendingVncProfileID = null
                pendingVncEndpointID = null
                vncEpoch = owner.nativeEpoch
                vncLastRevision = -1L
                vncFrameCount = 0
                vncFrameWindowStart = android.os.SystemClock.elapsedRealtime()
                val sessionToken = gate.beginVNCSession(vnc.id)
                _state.update {
                    it.copy(busy = null, vnc = mapVnc(vnc, null, 0.0))
                }
                startVNCStatusPoller(vnc.id, sessionToken, owner.nativeEpoch)
                startVNCInputLane(vnc.id, sessionToken, owner.nativeEpoch)
                startVNCFramePump(vnc.id, sessionToken, owner.nativeEpoch)
            } catch (failure: C05RemoteFailure) {
                if (!gate.isLiveVNC(token)) return@launch
                if (failure.challenge != null) {
                    pendingVncProfileID = profileID
                    pendingVncEndpointID = endpointID
                    _state.update {
                        it.copy(busy = null, challenge = mapChallenge(failure.challenge))
                    }
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                if (gate.isLiveVNC(token)) {
                    fail(C05RemoteFailure("unknown", "vncConnectFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun disconnectVNC() {
        val vnc = _state.value.vnc ?: return
        if (_state.value.busy != null) return
        val token = gate.beginVNCRequest() ?: return
        scope.launch {
            if (!gate.isLiveVNC(token)) return@launch
            _state.update { it.copy(busy = "vncClose") }
            stopVNCWork()
            try {
                val owner = ownerFor(token) ?: return@launch
                val result = withContext(ioDispatcher) { vncClient.close(vnc.sessionID, owner) }
                if (!gate.isLiveVNC(token)) return@launch
                if (result.complete) {
                    gate.finishVNCSession(vnc.sessionID)
                    _state.update { it.copy(vnc = null, busy = null) }
                } else {
                    _state.update {
                        it.copy(busy = null, error = RemoteHostUiError("cleanupIncomplete", null))
                    }
                }
            } catch (failure: C05RemoteFailure) {
                if (!gate.isLiveVNC(token)) return@launch
                if (failure.code == "vncSessionNotFound" || failure.code == "sessionNotFound") {
                    gate.finishVNCSession(vnc.sessionID)
                    _state.update { it.copy(vnc = null, busy = null) }
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                if (gate.isLiveVNC(token)) {
                    fail(C05RemoteFailure("unknown", "vncCloseFailed", detail = error.message), busy = null)
                }
            }
        }
    }

    fun setVncVisible(visible: Boolean) {
        vncVisible = visible
        val vnc = _state.value.vnc ?: return
        if (!visible) {
            vncReleaseAll()
            vncLane?.close()
            vncLane = null
            vncInputJob?.cancel()
            vncInputJob = null
        } else {
            val epoch = vncEpoch.takeIf { it > 0 } ?: return
            val token = gate.currentVNCSessionToken()
            if (token != 0L) {
                startVNCInputLane(vnc.sessionID, token, epoch)
            }
        }
    }

    fun vncPointerMove(x: Int, y: Int) {
        vncLane?.offer(C05VncInput.PointerMove(x, y))?.let(::vncIssue)
    }

    fun vncPointerButton(button: String, down: Boolean, x: Int, y: Int) {
        vncLane?.offer(C05VncInput.PointerButton(button, down, x, y))?.let(::vncIssue)
    }

    fun vncWheel(axis: String, steps: Int, x: Int, y: Int) {
        vncLane?.offer(C05VncInput.Wheel(axis, steps, x, y))?.let(::vncIssue)
    }

    fun vncKey(keysym: Long, down: Boolean) {
        vncLane?.offer(C05VncInput.Key(keysym, down))?.let(::vncIssue)
    }

    fun vncText(text: String) {
        if (text.isEmpty()) return
        // Keep one text event under the bridge's 4 KiB bound; long IME
        // commits are sent in order rather than rejected wholesale.
        var offset = 0
        while (offset < text.length) {
            val end = minOf(text.length, offset + 1_024)
            vncLane?.offer(C05VncInput.Text(text.substring(offset, end)))?.let(::vncIssue)
            offset = end
        }
    }

    fun vncReleaseAll() {
        val vnc = _state.value.vnc ?: return
        val owner = runCatching { ownerForEpoch(vncEpoch) }.getOrNull() ?: return
        vncLane?.close()
        vncLane = null
        vncInputJob?.cancel()
        vncInputJob = null
        scope.launch {
            runCatching { withContext(ioDispatcher) { vncClient.releaseAll(vnc.sessionID, owner) } }
        }
    }

    private fun vncIssue(issue: String) {
        _state.update { it.copy(vnc = it.vnc?.copy(inputIssue = issue)) }
    }

    private fun startVNCInputLane(sessionID: String, sessionToken: Long, epoch: Long) {
        vncLane?.close()
        vncInputJob?.cancel()
        val lane = C05VNCInputLane(
            sink = { events ->
                if (gate.isLiveVNCSession(sessionID, sessionToken, epoch)) {
                    withContext(ioDispatcher) {
                        vncClient.input(sessionID, events, ownerForEpoch(epoch))
                    }
                }
            },
            onIssue = { issue ->
                if (gate.isLiveVNCSession(sessionID, sessionToken, epoch)) {
                    _state.update { it.copy(vnc = it.vnc?.copy(inputIssue = issue)) }
                }
            },
        )
        vncLane = lane
        vncInputJob = scope.launch(ioDispatcher) { lane.run() }
    }

    private fun startVNCStatusPoller(sessionID: String, sessionToken: Long, epoch: Long) {
        vncStatusJob?.cancel()
        vncStatusJob = scope.launch(ioDispatcher) {
            while (isActive) {
                if (!gate.isLiveVNCSession(sessionID, sessionToken, epoch)) return@launch
                try {
                    val session = vncClient.status(sessionID, ownerForEpoch(epoch))
                    if (!gate.isLiveVNCSession(sessionID, sessionToken, epoch)) return@launch
                    _state.update { current ->
                        if (current.vnc?.sessionID != sessionID) {
                            current
                        } else {
                            val mapped = mapVnc(
                                session,
                                current.vnc?.bitmap,
                                current.vnc?.measuredFps ?: 0.0,
                            )
                            current.copy(
                                vnc = mapped.copy(
                                    width = maxOf(mapped.width, current.vnc?.width ?: 0),
                                    height = maxOf(mapped.height, current.vnc?.height ?: 0),
                                    revision = maxOf(mapped.revision, current.vnc?.revision ?: 0L),
                                    byteCount = maxOf(mapped.byteCount, current.vnc?.byteCount ?: 0),
                                )
                            )
                        }
                    }
                    if (session.state == "failed" || session.state == "closed") {
                        vncFrameJob?.cancel(); vncFrameJob = null
                        vncLane?.close(); vncLane = null
                        vncInputJob?.cancel(); vncInputJob = null
                    }
                    if (session.state == "closed") return@launch
                } catch (failure: C05RemoteFailure) {
                    if (failure.code == "sessionNotFound" ||
                        failure.code == "staleEpoch" ||
                        failure.code == "needsCoreUpdate"
                    ) {
                        stopVNCWork()
                        _state.update { it.copy(vnc = null) }
                        return@launch
                    }
                } catch (_: Throwable) {
                    // Keep the last honest projection; the next poll retries.
                }
                delay(1_000)
            }
        }
    }

    private fun startVNCFramePump(sessionID: String, sessionToken: Long, epoch: Long) {
        vncFrameJob?.cancel()
        vncFrameJob = scope.launch(ioDispatcher) {
            var buffer: ByteArray? = null
            var bitmap: Bitmap? = null
            while (isActive) {
                if (!gate.isLiveVNCSession(sessionID, sessionToken, epoch)) return@launch
                if (!vncVisible) {
                    delay(100)
                    continue
                }
                val current = _state.value.vnc
                if (current == null || current.sessionID != sessionID || current.state != "connected") {
                    delay(100)
                    continue
                }
                val meta = vncVideo.acquireFrame(epoch, ownerToken, sessionID)
                if (meta == null) {
                    delay(40)
                    continue
                }
                var leaseReleased = false
                try {
                    if (meta.byteCount > C05_VNC_MAX_FRAME_BYTES) {
                        continue
                    }
                    if (meta.revision == vncLastRevision) {
                        delay(20)
                        continue
                    }
                    val frameBytes = buffer?.takeIf { it.size == meta.byteCount }
                        ?: ByteArray(meta.byteCount).also { buffer = it }
                    var offset = 0
                    while (offset < meta.byteCount) {
                        val length = minOf(C05_VNC_MAX_PAGE_BYTES, meta.byteCount - offset)
                        val copied = vncVideo.read(
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
                            if (!gate.isLiveVNCSession(sessionID, sessionToken, epoch)) return@withContext
                            val target = bitmap?.takeIf {
                                it.width == meta.width && it.height == meta.height && !it.isRecycled
                            } ?: bitmapFactory(meta.width, meta.height) ?: return@withContext
                            bitmap = target
                            target.copyPixelsFromBuffer(ByteBuffer.wrap(frameBytes, 0, meta.byteCount))
                            vncLastRevision = meta.revision
                            vncFrameCount += 1
                            val now = android.os.SystemClock.elapsedRealtime()
                            val elapsed = (now - vncFrameWindowStart).coerceAtLeast(1L)
                            val fps = vncFrameCount * 1_000.0 / elapsed
                            if (elapsed >= 1_000L) {
                                vncFrameWindowStart = now
                                vncFrameCount = 0
                            }
                            _state.update {
                                it.copy(
                                    vnc = it.vnc?.copy(
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
                        // A transient Bitmap/copy failure must not kill the
                        // pump; the next frame is independent.
                        delay(100)
                    }
                } finally {
                    if (!leaseReleased) {
                        vncVideo.release(epoch, meta.leaseID)
                        leaseReleased = true
                    }
                }
                delay(16)
            }
        }
    }

    private fun stopVNCWork() {
        vncStatusJob?.cancel(); vncStatusJob = null
        vncFrameJob?.cancel(); vncFrameJob = null
        vncInputJob?.cancel(); vncInputJob = null
        vncLane?.close(); vncLane = null
        vncLastRevision = -1L
        vncFrameCount = 0
    }

    private fun mapVnc(session: C05VncSession, bitmap: Bitmap?, fps: Double): RemoteVncUi =
        RemoteVncUi(
            sessionID = session.id,
            profileID = session.profileID,
            endpointID = session.endpointID,
            displayName = session.displayName,
            host = session.host,
            port = session.port,
            transport = session.transport,
            state = session.state,
            width = session.width,
            height = session.height,
            revision = session.frameRevision,
            byteCount = session.frameBytes,
            bitmap = bitmap,
            failure = session.failure?.let {
                RemoteVncFailureUi(
                    code = it.code,
                    message = it.message,
                    retryable = it.retryable,
                    category = it.category,
                    stage = it.stage,
                )
            },
            inputIssue = _state.value.vnc?.inputIssue,
            measuredFps = fps,
            sshSessionID = session.sshSessionID,
            tunnelID = session.tunnelID,
        )

    // MARK: - Lifecycle helpers

    private fun ownerFor(token: C05RequestGate.Token): C05RemoteOwner? {
        if (!gate.isLiveSSH(token) && !gate.isLiveVNC(token)) return null
        lastKnownEpoch = token.epoch
        return C05RemoteOwner(token = ownerToken, nativeEpoch = token.epoch)
    }

    private fun ownerForEpoch(epoch: Long): C05RemoteOwner {
        if (epoch <= 0 || currentNativeEpoch() != epoch) {
            throw C05RemoteFailure("staleEpoch", "nativeEpochUnavailable")
        }
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
