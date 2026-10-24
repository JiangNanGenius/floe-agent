// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.NetworkWorkspaceNative
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * G04-R1 trusted NETWORK WORKSPACE host lane (App side) for WebDAV + SMB.
 *
 * The controller the reusable WorkspaceNetworkPanel drives. It owns NOTHING
 * authoritative: Swift owns the mount configuration, the retained qualified
 * sessions, the credential lease, the streaming/commit/save journal ladder
 * and every digest (`floe_g04_net_*`, see G04NetworkWorkspaceHostAPI.swift +
 * G04NetworkWorkspace). This lane owns exactly four things, each fenced by
 * the FULL captured identity (taskID + workspaceID + nativeEpoch +
 * hostGeneration + ownerFence):
 *
 *  1. the LAN permission boundary — every endpoint-touching user action runs
 *     through the SAME existing LocalNetworkAccessBroker (entry/
 *     LAN_PERMISSION_REUSE.json): the user-entered endpoint is captured,
 *     denial is typed and keeps local work, and NOTHING here grants or
 *     assumes permission (public endpoints dispatch directly);
 *  2. staged-credential hand-off — a password is converted to bytes, staged
 *     into the native one-shot RAM ticket, and the local arrays are cleared
 *     immediately; the ticket/secret is never stored, logged or placed in
 *     any state;
 *  3. operation tickets + bounded status polling — cancel is only a REQUEST;
 *     a live operation stays visible until native reports its physical
 *     terminal state, and a dismissed entry never fakes settlement; and
 *  4. lifecycle settlement — a rebind/new owner takes the lane over, a root
 *     stop (new epoch) fences late polls and late callbacks, journaled
 *     ladder receipts stay honestly pending for reconcile, and the panel
 *     renders only ACTUAL state.
 *
 * There is deliberately no model-facing entry: the callers are the App's own
 * Files inspector UI (WorkspaceNetworkPanel) and the Application-owned
 * lifecycle hooks.
 */
internal class NetworkWorkspaceHostController(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val localNetwork: () -> LocalNetworkAccessBroker?,
    private val channel: NetworkWorkspaceChannel = NativeNetworkWorkspaceChannel,
    /** Trusted fixture seam (JVM tests only): scriptable replacement for the
     * broker call. Production always leaves this null and uses the REAL
     * broker from [localNetwork]. */
    private val gateOverride: NetworkWorkspaceGate? = null,
) {
    /** Shared with the bound lanes: 0 keeps the stored credential, -1 asks
     * the native mount to clear it. */
    companion object {
        const val CLEAR_CREDENTIAL = -1L
    }

    private val lanes = ConcurrentHashMap<String, Lane>()

    /** Bootstrap for one accepted root epoch. The network owner restores its
     * durable config lazily per workspace (metadata-only JSON on the native
     * side); there is nothing to pump here, so this stays a lifecycle marker
     * symmetric with the source host and triggers a refresh of live lanes. */
    fun beginEpoch(epoch: Long) {
        lanes.values.filter { it.nativeEpoch == epoch }.forEach { lane ->
            scope.launch(ioDispatcher) { lane.refresh() }
        }
    }

    /** Root stop / rebind: fence every lane of THIS generation. Operations
     * are only requested to cancel; their native settlement is untouched. */
    fun retireEpoch(epoch: Long) {
        val doomed = lanes.entries.filter { it.value.nativeEpoch == epoch }
        for (entry in doomed) {
            entry.value.stop()
            lanes.remove(entry.key, entry.value)
        }
    }

    /** Binds (or rebinds) the lane for ONE durable workspace identity under
     * the exact captured owner. A newer pane generation of the same identity
     * takes ownership; an owner trying to reuse a retiring lane fails
     * closed. */
    fun laneFor(taskID: String, workspaceID: String, nativeEpoch: Long, hostGeneration: Long,
                isCurrentOwner: () -> Boolean): Lane? {
        if (nativeEpoch <= 0 || currentNativeEpoch() != nativeEpoch) return null
        val task = try { UUID.fromString(taskID) } catch (_: IllegalArgumentException) { return null }
        val workspace = try { UUID.fromString(workspaceID) } catch (_: IllegalArgumentException) { return null }
        if (!task.toString().equals(taskID, true) || !workspace.toString().equals(workspaceID, true)) return null
        val key = "${task.toString().uppercase(Locale.ROOT)}|${workspace.toString().uppercase(Locale.ROOT)}|$nativeEpoch"
        var created = false
        val lane = lanes.computeIfAbsent(key) {
            created = true
            Lane(taskID = task.toString(), workspaceID = workspace.toString(),
                 nativeEpoch = nativeEpoch, initialGeneration = hostGeneration,
                 initialOwner = isCurrentOwner)
        }
        if (!created && !lane.rebind(hostGeneration, isCurrentOwner)) return null
        return lane
    }

    fun stats(): String? {
        val reply = NetworkHostReply.call { buffer ->
            runCatching { channel.hostStats(buffer) }.getOrDefault(-699)
        }
        return if (reply.protocolOk) reply.body?.toString() else null
    }

    // -----------------------------------------------------------------------
    // One bound network lane. Identity is captured AT BIND and rides every
    // request; nothing here re-reads "the current task/workspace" late.
    // -----------------------------------------------------------------------

    inner class Lane internal constructor(
        val taskID: String,
        val workspaceID: String,
        val nativeEpoch: Long,
        initialGeneration: Long,
        initialOwner: () -> Boolean,
    ) {
        private val incarnation = AtomicLong(0)
        private val stopped = AtomicBoolean(false)
        private val busy = AtomicBoolean(false)
        @Volatile private var ownerGeneration: Long = initialGeneration
        @Volatile private var ownerFence: () -> Boolean = initialOwner
        private val pollers = ConcurrentHashMap<Long, Boolean>()

        private val ui = MutableStateFlow(NetworkLaneState())
        val state: StateFlow<NetworkLaneState> = ui

        internal fun rebind(generation: Long, isCurrentOwner: () -> Boolean): Boolean {
            if (stopped.get()) return false
            synchronized(this) {
                if (stopped.get()) return false
                if (generation < ownerGeneration) return false
                ownerGeneration = generation
                ownerFence = isCurrentOwner
            }
            return true
        }

        fun stop() {
            if (!stopped.compareAndSet(false, true)) return
            // Cancel REQUEST only for tracked live ops (their native IO
            // settles on its own; this lane never detaches anything).
            val tracked = pollers.keys.toList()
            tracked.forEach { pollers.remove(it) }
            scope.launch(ioDispatcher) {
                tracked.forEach { runCatching { channel.opCancel(it) } }
            }
            busy.set(false)
            mutate { it.copy(busy = false, runtimeAvailable = false) }
        }

        // ---- admission ----

        private fun admitted(): Boolean =
            !stopped.get() && currentNativeEpoch() == nativeEpoch && ownerFence()

        private fun mutate(transform: (NetworkLaneState) -> NetworkLaneState) {
            ui.value = transform(ui.value)
        }

        private inline fun <R> whenIdle(body: () -> R): R? =
            if (!stopped.get() && busy.compareAndSet(false, true)) body() else null

        private fun endIdle() {
            busy.set(false)
            mutate { it.copy(busy = false) }
        }

        private fun noteBusyRefused() {
            mutate { it.copy(messageToken = "busy") }
        }

        /** Runs [body] only through the SAME broker the providers/browser
         * use: the captured user-entered endpoint decides; onDenied is a
         * typed UI message; when no broker is reachable the native hop still
         * answers honestly (never a permission assumption here). */
        private fun gated(endpoint: String, body: () -> Unit) {
            val gate: NetworkWorkspaceGate = gateOverride ?: { ownerID, captured, isCurrent, onDenied, dispatch ->
                val broker = localNetwork()
                if (broker == null) {
                    // No broker wired (fixture / older host): dispatch only
                    // for the captured current owner; never a permission grant.
                    if (isCurrent()) { dispatch(); true } else false
                } else {
                    broker.runExplicitAction(ownerID, captured, isCurrent, onDenied, dispatch)
                }
            }
            val ownerID = "network-mount:${taskID.uppercase()}:${workspaceID.uppercase()}:${
                incarnation.incrementAndGet() }"
            val once = AtomicBoolean(false)
            val raised = runCatching {
                gate(ownerID, endpoint, ::admitted,
                    { code ->
                        if (once.compareAndSet(false, true)) {
                            endIdle()
                            mutate { it.copy(messageToken = code) }
                        }
                    },
                    {
                        if (once.compareAndSet(false, true)) body()
                    })
            }.getOrDefault(false)
            if (!raised && once.compareAndSet(false, true)) {
                // No broker wired (fixture / older host): proceed; native and
                // the provider decide. This is not a permission grant.
                body()
            } else if (!raised && !once.get()) {
                // The gate declined WITHOUT dispatch or denial (the caller
                // already went stale): release busy honestly, run nothing.
                endIdle()
            }
        }

        // ---- mount configuration ----

        fun refresh() {
            if (!admitted()) return
            scope.launch(ioDispatcher) {
                val reply = NetworkHostReply.call { buffer ->
                    runCatching { channel.mountPage(nativeEpoch, taskID, workspaceID, buffer) }
                        .getOrDefault(-699)
                }
                val sources = NetworkHostReply.call { buffer ->
                    runCatching { channel.sourcePage(nativeEpoch, workspaceID, "", 32, buffer) }
                        .getOrDefault(-699)
                }
                if (!admitted()) return@launch
                if (reply.protocolOk) {
                    val mounts = reply.rows("rows").map { it.toMountUi() }
                    val sourceRows = if (sources.protocolOk) sources.rows("rows").map { it.toSourceUi() }
                    else ui.value.sources
                    // A successful reload never erases the last ACTIONABLE
                    // refusal (an ok:0 errorCode surfaced by finishReply): a
                    // typed failure stays visible until the NEXT action
                    // replaces it (success clears it, protocol failure
                    // replaces it below). Actions own messageToken; the
                    // metadata reload owns only rows + runtime availability.
                    mutate {
                        it.copy(mounts = mounts, sources = sourceRows,
                                runtimeAvailable = reply.status >= 0)
                    }
                } else {
                    mutate { it.copy(runtimeAvailable = false, messageToken = reply.protocolToken) }
                }
            }
        }

        fun addMount(draft: NetworkMountDraft) = startAction(draft.endpointForGate) {
            scope.launch(ioDispatcher) {
                val ticket = stageCredential(draft)
                if (ticket == CREDENTIAL_FAILED) { endIdle(); return@launch }
                val reply = NetworkHostReply.call { buffer ->
                    runCatching {
                        if (draft.mountID == null) {
                            channel.mountAdd(nativeEpoch, taskID, workspaceID, draft.name,
                                draft.transport, draft.endpoint, draft.rootPath, draft.username,
                                draft.readOnly, ticket, buffer)
                        } else {
                            channel.mountUpdate(nativeEpoch, taskID, workspaceID, draft.mountID,
                                draft.name, draft.transport, draft.endpoint, draft.rootPath,
                                draft.username, draft.readOnly, ticket, buffer)
                        }
                    }.getOrDefault(-699)
                }
                if (!admitted()) { abortTicketIfNeeded(ticket); endIdle(); return@launch }
                finishReply(reply, token = null) {
                    mutate { it.copy(messageToken = reply.actionableToken) }
                }
                refreshSync()
            }
        }

        fun probeMount(mountID: String, endpointForGate: String) = startAction(endpointForGate) {
            scope.launch(ioDispatcher) {
                val reply = simpleCall { channel.mountProbe(nativeEpoch, taskID, workspaceID, mountID, it) }
                finishReply(reply) { mutate { it.copy(messageToken = reply.actionableToken) } }
                refreshSync()
            }
        }

        fun disconnectMount(mountID: String, endpointForGate: String) = startAction(endpointForGate) {
            scope.launch(ioDispatcher) {
                val reply = simpleCall { channel.mountDisconnect(nativeEpoch, taskID, workspaceID, mountID, it) }
                finishReply(reply) { mutate { it.copy(messageToken = reply.actionableToken) } }
                refreshSync()
            }
        }

        fun removeMount(mountID: String, endpointForGate: String, forgetCredential: Boolean) =
            startAction(endpointForGate) {
                scope.launch(ioDispatcher) {
                    val reply = simpleCall {
                        channel.mountRemove(nativeEpoch, taskID, workspaceID, mountID, forgetCredential, it)
                    }
                    finishReply(reply) { mutate { it.copy(messageToken = reply.actionableToken) } }
                    refreshSync()
                }
            }

        // ---- browse ----

        fun browse(mountID: String, path: String, endpointForGate: String) =
            startAction(endpointForGate) {
                scope.launch(ioDispatcher) {
                    val reply = simpleCall { channel.browse(nativeEpoch, taskID, workspaceID, mountID, path, it) }
                    if (!admitted()) { endIdle(); return@launch }
                    if (reply.ok) {
                        val entries = reply.rows("entries").map { it.toEntryUi() }
                        mutate {
                            it.copy(browse = NetworkBrowseUi(mountID, path, entries,
                                reply.number("truncated")?.toIntOrNull() == 1 ||
                                    reply.body?.boolean("truncated") == true))
                        }
                        endIdle()
                    } else {
                        finishReply(reply) { mutate { it.copy(messageToken = reply.actionableToken) } }
                    }
                }
            }

        // ---- operations ----

        fun startImport(mountID: String, remotePath: String, logicalPath: String,
                        recursive: Boolean, conflictCopy: Boolean, endpointForGate: String) =
            startAction(endpointForGate) {
                scope.launch(ioDispatcher) {
                    launchOperation(
                        channel.opImport(nativeEpoch, taskID, workspaceID, mountID, remotePath,
                            logicalPath, recursive, if (conflictCopy) "copy" else "refuse"),
                        displayName = remotePath,
                    )
                }
            }

        fun startExport(mountID: String, logicalPath: String, remotePath: String,
                        conflictCopy: Boolean, endpointForGate: String) =
            startAction(endpointForGate) {
                scope.launch(ioDispatcher) {
                    launchOperation(
                        channel.opExport(nativeEpoch, taskID, workspaceID, mountID, logicalPath,
                            remotePath, if (conflictCopy) "conflictCopy" else "refuse"),
                        displayName = logicalPath,
                    )
                }
            }

        fun startSave(sourceID: String, endpointForGate: String) =
            startAction(endpointForGate) {
                scope.launch(ioDispatcher) {
                    launchOperation(
                        channel.opSave(nativeEpoch, taskID, workspaceID, sourceID),
                        displayName = sourceID,
                    )
                }
            }

        fun startReconcile(recoveryID: String, endpointForGate: String) =
            startAction(endpointForGate) {
                scope.launch(ioDispatcher) {
                    launchOperation(
                        channel.opReconcile(nativeEpoch, taskID, workspaceID, recoveryID),
                        displayName = recoveryID,
                    )
                }
            }

        private fun launchOperation(code: Long, displayName: String) {
            if (!admitted()) { endIdle(); return }
            if (code < 0) {
                mutate { it.copy(messageToken = NetworkHostReply.tokenForStatus(code.toInt())) }
                endIdle()
                return
            }
            endIdle()
            pollOperation(code, displayName)
        }

        private fun pollOperation(ticket: Long, displayName: String) {
            if (pollers.putIfAbsent(ticket, true) != null) return
            scope.launch(ioDispatcher) {
                var settled = false
                while (!stopped.get() && admitted() && !settled) {
                    val reply = NetworkHostReply.call { buffer ->
                        runCatching { channel.opStatus(ticket, buffer) }.getOrDefault(-699)
                    }
                    if (!admitted()) break
                    if (reply.protocolOk) {
                        val view = reply.body!!.toOperationUi(displayName)
                        settled = !view.isLive
                        mutate { state ->
                            val rest = state.operations.filterNot { it.id == view.id }
                            state.copy(operations = (rest + view).sortedBy { it.id })
                        }
                    } else if (reply.status == -603 || reply.status == -602) {
                        break   // ticket gone/fenced: honest disappearance, no fake terminal
                    }
                    if (!settled) delay(400)
                }
                pollers.remove(ticket)
                if (settled) refreshSync()
            }
        }

        /** Cancel is a REQUEST. The op entry stays visible (cancelRequested)
         * until native proves the physical terminal state. */
        fun cancelOperation(ticket: Long) {
            scope.launch(ioDispatcher) {
                val status = runCatching { channel.opCancel(ticket) }.getOrDefault(-699)
                if (status == 0) {
                    mutate { state ->
                        state.copy(operations = state.operations.map {
                            if (it.id == ticket && it.isLive) it.copy(state = "cancelRequested") else it
                        })
                    }
                }
            }
        }

        /** Only a proven-terminal operation may be dismissed; a negative
         * native status keeps the entry (never a fake cleanup). */
        fun dismissOperation(ticket: Long) {
            scope.launch(ioDispatcher) {
                val status = runCatching { channel.opClose(ticket) }.getOrDefault(-699)
                if (status == 0) {
                    mutate { state ->
                        state.copy(operations = state.operations.filterNot { it.id == ticket })
                    }
                } else {
                    mutate { it.copy(messageToken = NetworkHostReply.tokenForStatus(status)) }
                }
            }
        }

        // ---- shared internals ----

        // noinline: the captured action is handed to the non-inline gate.
        private inline fun startAction(endpoint: String, noinline body: () -> Unit) {
            if (!admitted()) {
                mutate { it.copy(messageToken = "runtimeUnavailable", runtimeAvailable = false) }
                return
            }
            if (busy.get()) { noteBusyRefused(); return }
            if (whenIdle(body = {}) == null) { noteBusyRefused(); return }
            // Mirror the acquired one-shot latch into the UI state so the
            // panel shows busy — and refuses a second action honestly — while
            // a LAN permission chain is still pending. endIdle clears it on
            // every settle path (dispatch, denial, decline or native reply).
            mutate { it.copy(busy = true) }
            gated(endpoint, body)
        }

        private fun simpleCall(execute: (ByteArray) -> Int): NetworkHostReply =
            NetworkHostReply.call { buffer -> runCatching { execute(buffer) }.getOrDefault(-699) }

        private fun finishReply(reply: NetworkHostReply,
                               token: String? = null,
                               onActionable: () -> Unit) {
            if (!admitted()) { endIdle(); return }
            // Release the one-shot busy latch BEFORE publishing the outcome,
            // so no observer ever sees a settled action still latched busy
            // (endIdle's own mutate would otherwise trail the token write).
            endIdle()
            if (reply.ok) {
                mutate { it.copy(messageToken = token) }
            } else if (reply.protocolOk) {
                onActionable()          // ok:0 body — actionable errorCode
            } else {
                mutate { it.copy(messageToken = reply.protocolToken) }
            }
        }

        private fun refreshSync() {
            // refresh() launches again; admitted() is re-checked there.
            refresh()
        }

        private val CREDENTIAL_FAILED = Long.MIN_VALUE

        /** Converts + stages the draft's password, clearing every local
         * buffer immediately. Returns 0 (none), a positive ticket, or
         * CREDENTIAL_FAILED with the message already recorded. */
        private fun stageCredential(draft: NetworkMountDraft): Long {
            val password = draft.password
            if (password == null) {
                return when (draft.credentialAction) {
                    CLEAR_CREDENTIAL -> CLEAR_CREDENTIAL
                    else -> 0L
                }
            }
            if (password.isEmpty()) {
                mutate { it.copy(messageToken = "emptyCredential") }
                return CREDENTIAL_FAILED
            }
            val encoded = Charsets.UTF_8.encode(java.nio.CharBuffer.wrap(password))
            val bytes = ByteArray(encoded.remaining())
            encoded.get(bytes)
            java.util.Arrays.fill(password, '\u0000')
            val ticket = try {
                channel.credStage(nativeEpoch, bytes, 0, bytes.size)
            } catch (_: LinkageError) {
                bytes.fill(0)
                mutate { it.copy(messageToken = "runtimeUnavailable") }
                return CREDENTIAL_FAILED
            }
            bytes.fill(0)
            if (ticket <= 0) {
                mutate { it.copy(messageToken = NetworkHostReply.tokenForStatus(ticket.toInt())) }
                return CREDENTIAL_FAILED
            }
            return ticket
        }

        private fun abortTicketIfNeeded(ticket: Long) {
            if (ticket > 0) runCatching { channel.credAbort(ticket) }
        }
    }

    // ------------------------------------------------------------------
    // Public value types (consumed by WorkspaceNetworkPanel + Main mount)
    // ------------------------------------------------------------------

    internal data class NetworkMountDraft(
        val mountID: String? = null,
        val name: String,
        val transport: String,               // "webdav" | "smb"
        val endpoint: String,
        val rootPath: String,
        val username: String,
        val readOnly: Boolean,
        /** Consumed + zeroed at submit; never stored in any state. */
        val password: CharArray? = null,
        /** Used when password == null: 0 keep, -1 clear. */
        val credentialAction: Long = 0L,
    ) {
        /** The SAME user-entered endpoint that will be handed to the native
         * mount AND to the broker classification — never a re-derived
         * value after the tap. */
        val endpointForGate: String get() = endpoint
    }

    internal data class NetworkMountUi(
        val id: String, val name: String, val transport: String,
        val endpoint: String, val rootPath: String, val username: String,
        val readOnly: Boolean, val status: String,
    )

    internal data class NetworkEntryUi(
        val name: String, val path: String, val isDirectory: Boolean,
        val bytes: Long, val modifiedAt: Long?, val entityTag: String?,
    )

    internal data class NetworkOperationUi(
        val id: Long, val kind: String, val displayName: String,
        val mountID: String,
        val state: String, val phase: String,
        val bytesDone: Long, val totalBytes: Long,
        val entriesDone: Int, val entriesFailed: Int,
        val failures: List<Pair<String, String>>,
        val errorCode: String, val retryable: Boolean,
        val result: Map<String, String>,
    ) {
        val isLive: Boolean get() = state == "running" || state == "cancelRequested"
        val recoverableRecoveryID: String?
            get() = if (state == "failed" && result["reconcileRequired"] == "yes")
                result["recoveryID"] else null
    }

    internal data class NetworkSourceUi(
        val id: String, val path: String, val kind: String, val reference: String,
        val documentID: String, val sha256: String, val entityTag: String,
        val revision: String,
    )

    internal data class NetworkBrowseUi(
        val mountID: String, val path: String,
        val entries: List<NetworkEntryUi>, val truncated: Boolean,
    )

    internal data class NetworkLaneState(
        val busy: Boolean = false,
        val runtimeAvailable: Boolean = true,
        val mounts: List<NetworkMountUi> = emptyList(),
        val sources: List<NetworkSourceUi> = emptyList(),
        val browse: NetworkBrowseUi? = null,
        val operations: List<NetworkOperationUi> = emptyList(),
        /** Closed actionable token (mapped to localized copy by the panel);
         * never message text with paths, endpoints or secrets. */
        val messageToken: String? = null,
    )
}

/// Scriptable shape of the LAN broker call (production forwards to the ONE
/// existing LocalNetworkAccessBroker; JVM tests inject behaviour).
internal typealias NetworkWorkspaceGate = (
    ownerID: String,
    endpoint: String,
    isCurrent: () -> Boolean,
    onDenied: (String) -> Unit,
    dispatch: () -> Unit,
) -> Boolean

// ---------------------------------------------------------------------------
// Channel seam + native impl + reply plumbing
// ---------------------------------------------------------------------------

internal interface NetworkWorkspaceChannel {
    fun credStage(epoch: Long, data: ByteArray, offset: Int, length: Int): Long
    fun credAbort(ticket: Long): Int
    fun mountPage(epoch: Long, taskID: String, workspaceID: String, reply: ByteArray): Int
    fun mountAdd(epoch: Long, taskID: String, workspaceID: String, name: String,
                 transport: String, endpoint: String, rootPath: String, username: String,
                 readOnly: Boolean, credentialTicket: Long, reply: ByteArray): Int
    fun mountUpdate(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                    name: String, transport: String, endpoint: String, rootPath: String,
                    username: String, readOnly: Boolean, credentialTicket: Long,
                    reply: ByteArray): Int
    fun mountProbe(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                   reply: ByteArray): Int
    fun mountDisconnect(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                        reply: ByteArray): Int
    fun mountRemove(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                    forgetCredential: Boolean, reply: ByteArray): Int
    fun browse(epoch: Long, taskID: String, workspaceID: String, mountID: String, path: String,
               reply: ByteArray): Int
    fun stat(epoch: Long, taskID: String, workspaceID: String, mountID: String, path: String,
             reply: ByteArray): Int
    fun opImport(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                 remotePath: String, logicalPath: String, recursive: Boolean,
                 conflict: String): Long
    fun opExport(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                 logicalPath: String, remotePath: String, policy: String): Long
    fun opSave(epoch: Long, taskID: String, workspaceID: String, sourceID: String): Long
    fun opReconcile(epoch: Long, taskID: String, workspaceID: String, recoveryID: String): Long
    fun opStatus(ticket: Long, reply: ByteArray): Int
    fun opCancel(ticket: Long): Int
    fun opClose(ticket: Long): Int
    fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int,
                   reply: ByteArray): Int
    fun hostStats(reply: ByteArray): Int
}

private object NativeNetworkWorkspaceChannel : NetworkWorkspaceChannel {
    override fun credStage(epoch: Long, data: ByteArray, offset: Int, length: Int): Long =
        NetworkWorkspaceNative.credStage(epoch, data, offset, length)
    override fun credAbort(ticket: Long): Int = NetworkWorkspaceNative.credAbort(ticket)
    override fun mountPage(epoch: Long, taskID: String, workspaceID: String, reply: ByteArray): Int =
        NetworkWorkspaceNative.mountPage(epoch, taskID, workspaceID, reply)
    override fun mountAdd(epoch: Long, taskID: String, workspaceID: String, name: String,
                          transport: String, endpoint: String, rootPath: String,
                          username: String, readOnly: Boolean, credentialTicket: Long,
                          reply: ByteArray): Int =
        NetworkWorkspaceNative.mountAdd(epoch, taskID, workspaceID, name, transport, endpoint,
            rootPath, username, readOnly, credentialTicket, reply)
    override fun mountUpdate(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                              name: String, transport: String, endpoint: String,
                              rootPath: String, username: String, readOnly: Boolean,
                              credentialTicket: Long, reply: ByteArray): Int =
        NetworkWorkspaceNative.mountUpdate(epoch, taskID, workspaceID, mountID, name, transport,
            endpoint, rootPath, username, readOnly, credentialTicket, reply)
    override fun mountProbe(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                            reply: ByteArray): Int =
        NetworkWorkspaceNative.mountProbe(epoch, taskID, workspaceID, mountID, reply)
    override fun mountDisconnect(epoch: Long, taskID: String, workspaceID: String,
                                 mountID: String, reply: ByteArray): Int =
        NetworkWorkspaceNative.mountDisconnect(epoch, taskID, workspaceID, mountID, reply)
    override fun mountRemove(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                             forgetCredential: Boolean, reply: ByteArray): Int =
        NetworkWorkspaceNative.mountRemove(epoch, taskID, workspaceID, mountID, forgetCredential, reply)
    override fun browse(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                        path: String, reply: ByteArray): Int =
        NetworkWorkspaceNative.browse(epoch, taskID, workspaceID, mountID, path, reply)
    override fun stat(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                      path: String, reply: ByteArray): Int =
        NetworkWorkspaceNative.stat(epoch, taskID, workspaceID, mountID, path, reply)
    override fun opImport(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                          remotePath: String, logicalPath: String, recursive: Boolean,
                          conflict: String): Long =
        NetworkWorkspaceNative.opImport(epoch, taskID, workspaceID, mountID, remotePath,
            logicalPath, recursive, conflict)
    override fun opExport(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                          logicalPath: String, remotePath: String, policy: String): Long =
        NetworkWorkspaceNative.opExport(epoch, taskID, workspaceID, mountID, logicalPath,
            remotePath, policy)
    override fun opSave(epoch: Long, taskID: String, workspaceID: String, sourceID: String): Long =
        NetworkWorkspaceNative.opSave(epoch, taskID, workspaceID, sourceID)
    override fun opReconcile(epoch: Long, taskID: String, workspaceID: String,
                             recoveryID: String): Long =
        NetworkWorkspaceNative.opReconcile(epoch, taskID, workspaceID, recoveryID)
    override fun opStatus(ticket: Long, reply: ByteArray): Int =
        NetworkWorkspaceNative.opStatus(ticket, reply)
    override fun opCancel(ticket: Long): Int = NetworkWorkspaceNative.opCancel(ticket)
    override fun opClose(ticket: Long): Int = NetworkWorkspaceNative.opClose(ticket)
    override fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int,
                            reply: ByteArray): Int =
        NetworkWorkspaceNative.sourcePage(epoch, workspaceID, afterID, limit, reply)
    override fun hostStats(reply: ByteArray): Int = NetworkWorkspaceNative.hostStats(reply)
}

/** One status + bounded JSON reply, mirroring the accepted SourceHostReply
 * shape with the network -6xx space. A negative protocol status means the
 * call never produced a body; a body with ok:0 carries the actionable
 * errorCode token. */
internal class NetworkHostReply private constructor(
    val status: Int,
    val body: JsonObject?,
) {
    val protocolOk: Boolean get() = status >= 0 && body != null
    val ok: Boolean get() = status >= 0 && body?.boolean("ok") == true
    val actionableToken: String get() = body?.text("errorCode")?.takeIf { it.isNotEmpty() } ?: "providerFailed"
    val protocolToken: String get() = tokenForStatus(status)

    fun text(key: String): String = body?.text(key) ?: ""
    fun number(key: String): String? = (body?.get(key) as? JsonPrimitive)?.content
    fun rows(key: String): List<JsonObject> = body?.rows(key) ?: emptyList()

    companion object {
        const val REPLY_BYTES = 32 * 1024

        /** Closed token for a negative native status (never raw ints to UI). */
        fun tokenForStatus(status: Int): String = when (status) {
            -105 -> "invalidArguments"
            -106 -> "bufferLimit"
            -601, -602 -> "epochMismatch"
            -603 -> "operationUnknown"
            -604 -> "conflict"
            -605 -> "ownerChanged"
            -606 -> "mountUnknown"
            -607 -> "pathInvalid"
            -608 -> "providerFailed"
            -609 -> "credentialRejected"
            -610 -> "busy"
            -611 -> "hopTimeout"
            -612 -> "storageFull"
            -613 -> "sizeExceeded"
            -614 -> "journalRefused"
            else -> "internalError"
        }

        fun call(execute: (ByteArray) -> Int): NetworkHostReply {
            val buffer = ByteArray(REPLY_BYTES)
            val status = try { execute(buffer) } catch (_: LinkageError) { return NetworkHostReply(-601, null) }
            if (status < 0) return NetworkHostReply(status, null)
            val body = runCatching {
                val decoded = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(buffer, 0, status)).toString()
                Json.parseToJsonElement(decoded).jsonObject
            }.getOrNull()
            return if (body == null) NetworkHostReply(-699, null) else NetworkHostReply(status, body)
        }
    }
}

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.content
private fun JsonObject.boolean(key: String): Boolean? =
    when ((this[key] as? JsonPrimitive)?.content) {
        "true", "1" -> true
        "false", "0" -> false
        else -> null
    }
private fun JsonObject.long(key: String): Long =
    (this[key] as? JsonPrimitive)?.content?.toLongOrNull() ?: 0L
private fun JsonObject.int(key: String): Int =
    (this[key] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0
private fun JsonObject.rows(key: String): List<JsonObject> =
    ((this[key] as? JsonArray)?.mapNotNull { element -> element as? JsonObject }) ?: emptyList()

private fun JsonObject.toMountUi() = NetworkWorkspaceHostController.NetworkMountUi(
    id = text("id") ?: "", name = text("name") ?: "", transport = text("transport") ?: "",
    endpoint = text("endpoint") ?: "", rootPath = text("rootPath") ?: "",
    username = text("username") ?: "", readOnly = boolean("readOnly") == true,
    status = text("status") ?: "disconnected")

private fun JsonObject.toEntryUi() = NetworkWorkspaceHostController.NetworkEntryUi(
    name = text("name") ?: "", path = text("path") ?: "",
    isDirectory = boolean("isDirectory") == true, bytes = long("bytes"),
    modifiedAt = (this["modifiedAt"] as? JsonPrimitive)?.content?.toDoubleOrNull()?.toLong(),
    entityTag = text("entityTag").takeIf { !it.isNullOrEmpty() })

private fun JsonObject.toSourceUi() = NetworkWorkspaceHostController.NetworkSourceUi(
    id = text("id") ?: "", path = text("path") ?: "", kind = text("kind") ?: "",
    reference = text("reference") ?: "", documentID = text("documentID") ?: "",
    sha256 = text("sha256") ?: "", entityTag = text("entityTag") ?: "",
    revision = text("revision") ?: "")

private fun JsonObject.toOperationUi(displayName: String): NetworkWorkspaceHostController.NetworkOperationUi {
    val failures = rows("failures").map { row ->
        (row.text("path") ?: "") to (row.text("code") ?: "")
    }
    val result = (this["result"] as? JsonObject)?.mapValues { (_, value) ->
        (value as? JsonPrimitive)?.content ?: value.toString()
    } ?: emptyMap()
    return NetworkWorkspaceHostController.NetworkOperationUi(
        id = long("id"), kind = text("kind") ?: "", displayName = displayName,
        mountID = text("mountID") ?: "",
        state = text("state") ?: "running", phase = text("phase") ?: "",
        bytesDone = long("bytesDone"), totalBytes = long("totalBytes"),
        entriesDone = int("entriesDone"), entriesFailed = int("entriesFailed"),
        failures = failures, errorCode = text("errorCode") ?: "",
        retryable = boolean("retryable") == true, result = result)
}
