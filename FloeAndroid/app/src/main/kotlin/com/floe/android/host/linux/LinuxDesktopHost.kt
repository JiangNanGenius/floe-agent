// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.graphics.Bitmap
import android.os.SystemClock
import com.floe.android.feature.remote.RemoteVncUi
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.remote.*
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class LinuxDesktopState(val phase: String = "idle", val taskID: String? = null,
    val workspaceID: String? = null, val environmentID: String? = null,
    val desktop: Boolean = false, val vnc: RemoteVncUi? = null, val failure: String? = null)

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
    @Volatile private var visible = false
    private var epoch = 0L

    fun start(taskID: String, workspaceID: String, desktop: Boolean, install: Boolean) {
        if (task?.isActive == true) return
        if (state.value.workspaceID == workspaceID && state.value.phase == "running" && state.value.desktop == desktop) {
            visible = true; return
        }
        task = scope.launch(Dispatchers.IO) { serial.withLock {
            cleanup()
            stopped = false
            epoch = host.nativeRootEpoch() ?: return@withLock
            mutable.value = LinuxDesktopState("starting", taskID, workspaceID, desktop = desktop)
            try {
                val binding = G04WorkspaceBridgeClient.bindExisting(host, taskID) { live() }
                check(binding.workspaceID.equals(workspaceID, ignoreCase = true))
                val terminal = checkNotNull(host.workspaceTerminal)
                val tab = terminal.openTab(taskID, workspaceID, 120, 36)
                    ?: error("terminal_unavailable")
                val token = checkNotNull(tab.sessionID)
                terminalID = token
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
                            if (received.contains("FLOE_MISSING:") || received.contains("FLOE_INSTALL_FAILED:"))
                                mutable.value = state.value.copy(failure = "software_unavailable")
                        }
                    }
                    val display = random.nextInt(200) + 10
                    val port = 5900 + display
                    terminal.transportForTab(token).write(LinuxDesktopCommands.launch(nonce, display,
                        if (desktop) 1600 else 960, if (desktop) 1000 else 1280, install, desktop).toByteArray())
                    withTimeout(if (install) 20 * 60_000L else 30_000L) { read.await() }
                    checkLive()
                    terminal.transportForTab(token).write(password + byteArrayOf(10))
                    withTimeout(30_000) { ready.await() }
                    checkLive()
                    // Reuse the existing Android local-network permission broker.
                    val network = CompletableDeferred<Unit>()
                    withContext(Dispatchers.Main) {
                        host.integrations.localNetwork.runExplicitAction(
                            ownerID = "linux-desktop-$nonce", endpoint = "vnc://127.0.0.1:$port",
                            isCurrent = { live() }, onDenied = { network.completeExceptionally(IllegalStateException("network_permission")) },
                            dispatch = { network.complete(Unit) })
                    }
                    withTimeout(120_000) { network.await() }
                    checkLive()
                    val detail = vncClient.profileSaveVNCOnly(C05VncProfileDraft(null, "Linux", "linux",
                        listOf(C05VncEndpointDraft(null, "Linux", "direct", "127.0.0.1", port, credential))), owner)
                    profileID = detail.summary.id
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
                    if (!desktop) application("mousepad", false)
                } finally { password.fill(0) }
            } catch (cancelled: CancellationException) { cleanup(); throw cancelled }
            catch (_: Exception) {
                cleanup()
                mutable.value = state.value.copy(phase = "failed", vnc = null, failure = "desktop_start_failed")
            }
        } }
    }

    private fun live() = !stopped && host.nativeRootEpoch() == epoch
    private fun checkLive() { check(live()) }
    fun setVisible(value: Boolean) { visible = value; if (!value) releaseInput() }
    fun input(event: C05VncInput) { if (live() && state.value.phase == "running") input?.offer(event) }
    fun releaseInput() {
        val id = vncID ?: return
        val owner = remoteOwner ?: return
        scope.launch(Dispatchers.IO) { runCatching { vncClient.releaseAll(id, owner) } }
    }
    fun application(name: String, install: Boolean) {
        if (!live() || state.value.phase != "running") return
        val token = terminalID ?: return
        host.workspaceTerminal?.transportForTab(token)?.write(LinuxDesktopCommands.application(name, install))
    }
    fun openFile(application: String, logicalPath: String) {
        require(application in LinuxDesktopCommands.applications)
        require(com.floe.android.host.externaledit.ExternalEditPolicy.validPath(logicalPath))
        if (!live() || state.value.phase != "running") return
        val token = terminalID ?: return
        val encoded = java.util.Base64.getEncoder().encodeToString(logicalPath.toByteArray(Charsets.UTF_8))
        host.workspaceTerminal?.transportForTab(token)?.write("open:$application:$encoded\n".toByteArray())
    }
    fun stop() {
        stopped = true
        task?.cancel()
        scope.launch(Dispatchers.IO) { serial.withLock { cleanup(); mutable.value = LinuxDesktopState() } }
    }
    suspend fun stopAndJoin() {
        stopped = true
        task?.cancelAndJoin()
        serial.withLock { cleanup(); mutable.value = LinuxDesktopState() }
    }

    private suspend fun cleanup() = withContext(NonCancellable + Dispatchers.IO) {
        frames?.cancelAndJoin(); frames = null
        input?.close(); input = null
        inputJob?.cancelAndJoin(); inputJob = null
        outputClose?.invoke(); outputClose = null
        val owner = remoteOwner
        if (owner != null) {
            vncID?.let { runCatching { vncClient.releaseAll(it, owner); vncClient.close(it, owner) } }
            profileID?.let { runCatching { profiles.profileDelete(it, owner) } }
            credential?.let { runCatching { vncClient.credentialDelete(it) } }
        }
        vncID = null; profileID = null; credential = null; remoteOwner = null
        terminalID?.let { runCatching { host.workspaceTerminal?.closeTab(it) } }
        terminalID = null
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
