// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.graphics.Bitmap
import android.os.SystemClock
import com.floe.android.feature.remote.RemoteVncUi
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.TerminalActionReply
import com.floe.android.host.remote.*
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.floe.android.host.externaledit.ExternalEditOwner
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class LinuxSoftwarePackage(val application: String, val installed: Boolean, val packageBytes: Long?)

internal data class LinuxDesktopState(val phase: String = "idle", val taskID: String? = null,
    val workspaceID: String? = null, val environmentID: String? = null,
    val desktop: Boolean = false, val vnc: RemoteVncUi? = null, val failure: String? = null,
    val software: List<LinuxSoftwarePackage> = emptyList(), val softwareOperation: String? = null)

/** A graphical session is an owned native PTY plus a real authenticated loopback VNC client.
 * No host interpreter, guessed temporary environment, or view-owned process is used. */
internal class LinuxDesktopHost(private val host: RuntimeHost) {
    private val serial = Mutex()
    private val scope = host.scope
    private val mutable = MutableStateFlow(LinuxDesktopState())
    val state = mutable.asStateFlow()
    private val vncClient = C05VNCClient()
    private val profiles = C05RemoteClient()
    private var task: Job? = null
    private var frames: Job? = null
    private var inputJob: Job? = null
    private var input: C05VNCInputLane? = null
    @Volatile private var stopped = false
    @Volatile private var terminalID: String? = null
    private var vncID: String? = null
    private var profileID: String? = null
    private var credential: C05VncPasswordRef? = null
    private var remoteOwner: C05RemoteOwner? = null
    private var outputClose: (() -> Unit)? = null
    private val editAcks = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private val editWatchers = ConcurrentHashMap<String, Job>()
    private val editReaders = ConcurrentHashMap<String, suspend (java.io.File) -> String>()
    private val fileOpens = ConcurrentHashMap<String, Job>()
    @Volatile private var visible = false
    @Volatile private var epoch = 0L
    @Volatile private var displayNumber: Int? = null
    @Volatile private var inventoryNonce: String? = null
    @Volatile private var softwareNonce: String? = null

    fun start(taskID: String, workspaceID: String, desktop: Boolean, install: Boolean) {
        if (task?.isActive == true) return
        if (state.value.workspaceID == workspaceID && state.value.phase == "running" && state.value.desktop == desktop) {
            visible = true; return
        }
        task = scope.launch(Dispatchers.IO) { serial.withLock {
            stopped = true
            if (!cleanup()) return@withLock
            stopped = false
            epoch = host.nativeRootEpoch() ?: return@withLock
            mutable.value = LinuxDesktopState("starting", taskID, workspaceID, desktop = desktop)
            var stage = "workspace"
            try {
                val binding = G04WorkspaceBridgeClient.bindExisting(host, taskID) { live() }
                check(binding.workspaceID.equals(workspaceID, ignoreCase = true))
                val terminal = checkNotNull(host.workspaceTerminal)
                stage = "terminal"
                var refusal: TerminalActionReply? = null
                val tab = terminal.openTab(taskID, workspaceID, 120, 36) { refusal = it }
                    .also {
                        (refusal as? TerminalActionReply.Refused)?.let { reply ->
                            throw G04WorkspaceBridgeClient.Failure(reply.code)
                        }
                    }
                    ?: error("terminal_unavailable")
                val token = checkNotNull(tab.sessionID)
                terminalID = token
                stage = "terminal_metadata"
                val metadata = withTimeout(15_000) {
                    while (true) {
                        checkLive()
                        val value = terminal.snapshotFor(token)
                        if (value != null && value.environmentID.isNotEmpty() && value.runtimeGeneration.isNotEmpty()) return@withTimeout value
                        delay(100)
                    }
                    error("unreachable")
                }
                check(metadata.workspaceID.equals(workspaceID, ignoreCase = true))
                mutable.value = state.value.copy(environmentID = metadata.environmentID,
                    phase = if (install) "installing" else "starting")
                val owner = C05RemoteOwner(UUID.randomUUID().toString(), epoch, taskID)
                remoteOwner = owner
                val nonce = UUID.randomUUID().toString().replace("-", "")
                val random = SecureRandom()
                val password = ByteArray(8) { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[random.nextInt(32)].code.toByte() }
                try {
                    stage = "vnc_credential"
                    credential = vncClient.credentialSave("floe.local-desktop.$nonce", false, password, owner)
                    val read = CompletableDeferred<Unit>()
                    val ready = CompletableDeferred<Unit>()
                    val received = StringBuilder()
                    outputClose = terminal.addOutputListener(token) { bytes ->
                        synchronized(received) {
                            received.append(String(bytes, Charsets.UTF_8))
                            if (received.length > 65_536) received.delete(0, received.length - 32_768)
                            if (received.contains("FLOE_READ:$nonce")) read.complete(Unit)
                            if (received.contains("FLOE_READY:$nonce")) ready.complete(Unit)
                            editAcks.forEach { (id, ack) ->
                                if (received.contains("FLOE_EDIT_CREATED:$id")) ack.complete(true)
                                else if (received.contains("FLOE_EDIT_REUSED:$id")) ack.complete(false)
                            }
                            inventoryNonce?.let { query ->
                                val rows = Regex("FLOE_SOFTWARE:$query:([a-z0-9]+):(missing|[0-9]+)")
                                    .findAll(received).mapNotNull { match ->
                                        val app = match.groupValues[1]
                                        if (app !in LinuxDesktopCommands.applications) null else LinuxSoftwarePackage(
                                            app, match.groupValues[2] != "missing", match.groupValues[2].toLongOrNull())
                                    }.associateBy { it.application }.values.toList()
                                if (rows.isNotEmpty()) mutable.value = state.value.copy(software = rows)
                            }
                            val completion = when {
                                received.contains("FLOE_INSTALLED:$softwareNonce") -> "installed"
                                received.contains("FLOE_REMOVED:$softwareNonce") -> "removed"
                                received.contains("FLOE_CACHE_CLEANED:$softwareNonce") -> "cache-cleaned"
                                else -> null
                            }
                            if (completion != null && state.value.softwareOperation != null) {
                                mutable.value = state.value.copy(softwareOperation = null)
                            }
                            if (received.contains("FLOE_REMOVE_FAILED:$softwareNonce") || received.contains("FLOE_CACHE_FAILED:$softwareNonce") || received.contains("FLOE_INSTALL_FAILED:$softwareNonce"))
                                mutable.value = state.value.copy(softwareOperation = null, failure = "software_operation_failed")
                            Regex("FLOE_MISSING:([a-z0-9]+)[\r\n]").find(received)?.let { missing ->
                                mutable.value = state.value.copy(failure = "software_unavailable")
                                received.delete(missing.range.first, missing.range.last + 1)
                            }
                        }
                    }
                    val display = random.nextInt(200) + 10
                    displayNumber = display
                    val port = 5900 + display
                    terminal.transportForTab(token).write(LinuxDesktopCommands.launch(nonce, display,
                        if (desktop) 1600 else 960, if (desktop) 1000 else 1280, install, desktop).toByteArray())
                    stage = "guest_components"
                    withTimeout(if (install) 20 * 60_000L else 30_000L) { read.await() }
                    checkLive()
                    terminal.transportForTab(token).write(password + byteArrayOf(10))
                    stage = "guest_display"
                    withTimeout(30_000) { ready.await() }
                    checkLive()
                    // Reuse the existing Android local-network permission broker.
                    val network = CompletableDeferred<Unit>()
                    stage = "local_network"
                    withContext(Dispatchers.Main) {
                        host.integrations.localNetwork.runExplicitAction(
                            ownerID = "linux-desktop-$nonce", endpoint = "vnc://127.0.0.1:$port",
                            isCurrent = { live() }, onDenied = { network.completeExceptionally(IllegalStateException("network_permission")) },
                            dispatch = { network.complete(Unit) })
                    }
                    withTimeout(120_000) { network.await() }
                    checkLive()
                    stage = "vnc_profile"
                    val detail = vncClient.profileSaveVNCOnly(C05VncProfileDraft(null, "Linux", "linux",
                        listOf(C05VncEndpointDraft(null, "Linux", "direct", "127.0.0.1", port, credential))), owner)
                    profileID = detail.summary.id
                    stage = "vnc_connect"
                    val session = vncClient.connect(detail.summary.id, detail.vncEndpoints.firstOrNull()?.id, null, owner)
                    vncID = session.id
                    visible = true
                    val lane = C05VNCInputLane(
                        sink = { events ->
                            try { checkLive(); vncClient.input(session.id, events, owner) }
                            catch (_: Exception) { mutable.value = state.value.copy(failure = "input_failed") }
                            Unit
                        },
                        onIssue = { mutable.value = state.value.copy(failure = "input_failed") })
                    input = lane
                    inputJob = scope.launch(Dispatchers.IO) { lane.run() }
                    mutable.value = state.value.copy(phase = "running", vnc = presentation(session, null), failure = null)
                    frames = scope.launch(Dispatchers.IO) {
                        try { readFrames(session.id, owner) }
                        catch (cancelled: CancellationException) { throw cancelled }
                        catch (_: Exception) { mutable.value = state.value.copy(phase = "failed", failure = "desktop_disconnected") }
                    }
                    refreshSoftware()
                    if (!desktop) application("mousepad", false)
                } finally { password.fill(0) }
            } catch (cancelled: CancellationException) { if (!stopped) cleanup(); throw cancelled }
            catch (failure: Exception) {
                // Codes and the fixed stage are safe diagnostics; exception messages,
                // guest output, paths and credentials must never enter Android logs.
                val code = when (failure) {
                    is G04WorkspaceBridgeClient.Failure -> failure.code
                    is C05RemoteFailure -> failure.code
                    else -> failure.javaClass.simpleName
                }.takeIf { it.matches(Regex("[A-Za-z0-9_]{1,80}")) } ?: "unknown"
                android.util.Log.w("FloeLinuxDesktop", "start_failed stage=$stage code=$code")
                if (!cleanup()) return@withLock
                mutable.value = state.value.copy(phase = "failed", vnc = null, failure = "desktop_start_failed")
            }
        } }
    }

    private fun live() = !stopped && host.nativeRootEpoch() == epoch
    private fun checkLive() { check(live()) }
    /** Read-only facts for the exact environment already resolved by Core.
     * Publishing DISPLAY never grants authority to a different workspace. */
    fun environmentMetadata(environmentID: String): org.json.JSONObject? {
        val current = state.value
        if (!live() || current.phase != "running" ||
            current.environmentID != environmentID) return null
        val session = terminalID?.let { host.workspaceTerminal?.snapshotFor(it) } ?: return null
        if (session.environmentID != environmentID ||
            !session.workspaceID.equals(current.workspaceID, ignoreCase = true)) return null
        val display = displayNumber ?: return null
        return org.json.JSONObject().put("display", ":$display")
            .put("mode", if (current.desktop) "desktop" else "singleApplication")
            .put("width", if (current.desktop) 1600 else 960)
            .put("height", if (current.desktop) 1000 else 1280)
            .put("workspaceID", session.workspaceID)
            .put("runtimeGeneration", session.runtimeGeneration)
    }
    fun setVisible(value: Boolean) { visible = value; if (!value) releaseInput() }
    fun input(event: C05VncInput) { if (live() && state.value.phase == "running") input?.offer(event) }
    fun releaseInput() {
        val id = vncID ?: return
        val owner = remoteOwner ?: return
        scope.launch(Dispatchers.IO) { runCatching { vncClient.releaseAll(id, owner) } }
    }
    fun refreshSoftware() {
        if (!live() || state.value.phase != "running") return
        val token = terminalID ?: return
        val nonce = UUID.randomUUID().toString().replace("-", "")
        inventoryNonce = nonce
        host.workspaceTerminal?.transportForTab(token)?.write("inventory:$nonce\n".toByteArray())
    }
    fun application(name: String, install: Boolean) {
        if (!live() || state.value.phase != "running" || state.value.softwareOperation != null) return
        val token = terminalID ?: return
        val nonce = if (install) UUID.randomUUID().toString().replace("-", "") else null
        mutable.value = state.value.copy(failure = null)
        if (install) {
            softwareNonce = nonce
            mutable.value = state.value.copy(softwareOperation = "install:$name", failure = null)
        }
        host.workspaceTerminal?.transportForTab(token)?.write(LinuxDesktopCommands.application(name, install, nonce))
        if (install) refreshSoftware()
    }
    fun uninstallSoftware(name: String) {
        require(name in LinuxDesktopCommands.applications)
        if (!live() || state.value.phase != "running" || state.value.softwareOperation != null) return
        val token = terminalID ?: return
        val nonce = UUID.randomUUID().toString().replace("-", "")
        softwareNonce = nonce
        mutable.value = state.value.copy(softwareOperation = "remove:$name", failure = null)
        host.workspaceTerminal?.transportForTab(token)?.write("uninstall:$name:$nonce\n".toByteArray())
        refreshSoftware()
    }
    fun cleanSoftwareCache() {
        if (!live() || state.value.phase != "running" || state.value.softwareOperation != null) return
        val token = terminalID ?: return
        val nonce = UUID.randomUUID().toString().replace("-", "")
        softwareNonce = nonce
        mutable.value = state.value.copy(softwareOperation = "clean-cache", failure = null)
        host.workspaceTerminal?.transportForTab(token)?.write("clean-cache:$nonce\n".toByteArray())
        refreshSoftware()
    }
    fun openFile(application: String, logicalPath: String) {
        require(application in LinuxDesktopCommands.applications)
        require(com.floe.android.host.externaledit.ExternalEditPolicy.validPath(logicalPath))
        if (!live() || state.value.phase != "running") return
        check(state.value.softwareOperation == null)
        val token = terminalID ?: return
        val ownerTask = state.value.taskID ?: return
        val workspace = state.value.workspaceID ?: return
        val terminal = host.workspaceTerminal ?: return
        val admittedEpoch = epoch
        val operationID = UUID.randomUUID().toString()
        val opening = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            try {
                val row = host.externalEdits.prepareLinux(ExternalEditOwner(ownerTask, workspace), logicalPath)
                val path = checkNotNull(row.linuxWorkingPath)
                val nonce = UUID.randomUUID().toString().replace("-", "")
                fun encoded(value: String) = java.util.Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8))
                val ack = CompletableDeferred<Boolean>()
                editAcks[nonce] = ack
                val created = try {
                    terminal.transportForTab(token).write("edit:$application:${encoded(logicalPath)}:${encoded(path)}:$nonce\n".toByteArray())
                    withTimeout(15_000) { ack.await() }
                } finally { editAcks.remove(nonce) }
                check(live() && epoch == admittedEpoch && terminalID == token)
                val metadata = checkNotNull(terminal.snapshotFor(token))
                val bridge = LinuxDesktopFileBridge(terminal, ownerTask, token, metadata.runtimeGeneration) {
                    host.nativeRootEpoch() == admittedEpoch && epoch == admittedEpoch && terminalID == token
                }
                var revision: String? = null
                if (created) {
                    // Verify the new guest working copy against the retained original
                    // before accepting its first revision as an editable baseline.
                    check(host.externalEdits.receiveLinuxSnapshot(row.id) { destination ->
                        revision = bridge.copy(path, destination, row.baselineSHA256)
                    })
                }
                check(live() && epoch == admittedEpoch && terminalID == token)
                editReaders[row.id] = { destination -> bridge.copy(path, destination) }
                terminal.transportForTab(token).write("open:$application:${encoded(path)}\n".toByteArray())
                editWatchers.remove(row.id)?.cancelAndJoin()
                editWatchers[row.id] = scope.launch(Dispatchers.IO) {
                    while (isActive && live() && epoch == admittedEpoch && terminalID == token) {
                        try {
                            val next = bridge.probe(path)
                            if (next.fileRevision != revision) {
                                var copied: String? = null
                                val accepted = host.externalEdits.receiveLinuxSnapshot(row.id) { destination ->
                                    copied = bridge.copy(path, destination)
                                }
                                if (accepted) revision = copied
                                else mutable.value = state.value.copy(failure = "save_conflict")
                            }
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (_: Exception) { mutable.value = state.value.copy(failure = "file_return_failed") }
                        delay(2_000)
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { mutable.value = state.value.copy(failure = "file_return_failed") }
            finally { fileOpens.remove(operationID) }
        }
        fileOpens[operationID] = opening
        opening.start()
    }
    fun stop() {
        stopped = true
        task?.cancel()
        scope.launch(Dispatchers.IO) { serial.withLock {
            if (cleanup()) mutable.value = LinuxDesktopState()
        } }
    }
    suspend fun stopAndJoin(): Boolean {
        stopped = true
        task?.cancelAndJoin()
        return serial.withLock {
            val closed = cleanup()
            if (closed) mutable.value = LinuxDesktopState()
            closed
        }
    }

    private suspend fun cleanup(): Boolean = withContext(NonCancellable + Dispatchers.IO) {
        val opening = fileOpens.values.toList()
        fileOpens.clear()
        opening.forEach { it.cancel() }; opening.forEach { it.join() }
        val watching = editWatchers.values.toList()
        editWatchers.clear()
        watching.forEach { it.cancel() }; watching.forEach { it.join() }
        // Persist the latest actually saved editor bytes before closing its PTY.
        // A failed transfer keeps the real session/recovery files instead of
        // claiming success and destroying the only newest copy.
        try {
            withTimeout(120_000) {
                for ((id, reader) in editReaders) {
                    if (!host.externalEdits.hasActiveLinuxEdit(id)) continue
                    check(host.externalEdits.receiveLinuxSnapshot(id) { reader(it) })
                }
            }
        } catch (_: Exception) {
            mutable.value = state.value.copy(phase = "save_pending", failure = "file_return_failed")
            return@withContext false
        }
        editReaders.clear()
        inventoryNonce = null
        softwareNonce = null
        frames?.cancelAndJoin(); frames = null
        editAcks.values.forEach { it.cancel() }; editAcks.clear()
        input?.close(); input = null
        inputJob?.cancelAndJoin(); inputJob = null
        outputClose?.invoke(); outputClose = null
        try {
            val owner = remoteOwner
            if (owner != null) {
                vncID?.let { id ->
                    vncClient.releaseAll(id, owner)
                    check(vncClient.close(id, owner).complete)
                    vncID = null
                }
                profileID?.let { id ->
                    val deleted = runCatching { profiles.profileDelete(id, owner).deleted }.getOrDefault(false)
                    check(deleted || profiles.profileList(owner).none { it.id == id })
                    profileID = null
                }
                credential?.let { vncClient.credentialDelete(it); credential = null }
            }
            remoteOwner = null
            terminalID?.let { token ->
                check(host.workspaceTerminal?.closeTab(token) is TerminalActionReply.Success)
                terminalID = null
            }
            true
        } catch (_: Exception) {
            mutable.value = state.value.copy(phase = "close_pending", failure = "desktop_stop_pending")
            false
        }
    }

    private suspend fun readFrames(sessionID: String, owner: C05RemoteOwner) {
        while (currentCoroutineContext().isActive && live() && vncID == sessionID) {
            if (!visible) { delay(250); continue }
            val session = vncClient.status(sessionID, owner)
            if (session.state in setOf("closed", "failed")) {
                mutable.value = state.value.copy(phase = "failed", failure = "desktop_disconnected")
                return
            }
            val meta = C05VNCVideoNative.acquireFrame(epoch, owner.token, sessionID)
            if (meta == null) { delay(40); continue }
            try {
                if (meta.revision == state.value.vnc?.revision && state.value.vnc?.bitmap != null) { delay(40); continue }
                val bytes = ByteArray(meta.byteCount)
                var offset = 0
                while (offset < bytes.size) {
                    checkLive()
                    val read = C05VNCVideoNative.read(epoch, meta.leaseID, offset.toLong(), bytes, offset,
                        minOf(C05_VNC_MAX_PAGE_BYTES, bytes.size - offset))
                    check(read > 0); offset += read
                }
                withContext(Dispatchers.Main) {
                    if (!live() || vncID != sessionID) return@withContext
                    val bitmap = state.value.vnc?.bitmap?.takeIf {
                        !it.isRecycled && it.width == meta.width && it.height == meta.height
                    } ?: Bitmap.createBitmap(meta.width, meta.height, Bitmap.Config.ARGB_8888)
                    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(bytes))
                    mutable.value = state.value.copy(vnc = presentation(session, bitmap).copy(revision = meta.revision))
                }
            } finally { C05VNCVideoNative.releaseQuietly(epoch, meta.leaseID) }
            delay(40)
        }
    }

    private fun presentation(s: C05VncSession, bitmap: Bitmap?) = RemoteVncUi(s.id, s.profileID, s.endpointID,
        "Linux", s.host, s.port, s.transport, s.state, s.width, s.height, s.frameRevision, s.frameBytes,
        bitmap, null, null, 0.0, s.sshSessionID, s.tunnelID)
}
