// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import android.content.Context
import com.floe.android.core.devicelink.DeviceHistoryAttachmentSource
import com.floe.android.core.devicelink.DeviceHistoryCatalog
import com.floe.android.core.devicelink.DeviceHistoryOffer
import com.floe.android.core.devicelink.DeviceHistoryPage
import com.floe.android.core.devicelink.DeviceHistoryPagedSource
import com.floe.android.core.devicelink.DeviceHistoryPairingTicket
import com.floe.android.core.devicelink.DeviceHistorySync
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import com.floe.android.core.devicelink.DeviceWorkspaceConvergence
import com.floe.android.core.devicelink.DeviceWorkspaceReceipt
import com.floe.android.core.devicelink.FloeDeviceLink
import com.floe.android.core.devicelink.FloeDeviceLinkIdentity
import com.floe.android.core.devicelink.FloeDeviceLinkRelay
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

internal interface DeviceHistoryLocalStore {
    suspend fun localOffers(epoch: Long): List<DeviceHistoryOffer>
    suspend fun exportHistory(epoch: Long, taskId: UUID, version: Int): ByteArray
    suspend fun importHistory(epoch: Long, taskId: UUID, bytes: ByteArray, version: Int): Int
    suspend fun storedCursor(epoch: Long, peerId: String, taskId: UUID): String?
    suspend fun exportPage(epoch: Long, taskId: UUID, after: String?, through: Long?, version: Int): DeviceHistoryPage
    suspend fun importPage(epoch: Long, peerId: String, taskId: UUID, page: DeviceHistoryPage, version: Int): Int
}

internal enum class DeviceHistoryStatus {
    IDLE, READY, START_FAILED, SETTINGS_FAILED, TRANSFER_FAILED, CONFLICT,
    BUSY_TASK, INCOMPATIBLE, INVALID_RELAY, RELAY_PENDING, IMPORT_UNCONFIRMED,
    CURSOR_EXPIRED, NO_LONGER_SHARED, RECEIVED, WORKSPACE_RECEIVED, WORKSPACE_PAUSED,
    WORKSPACE_UNAVAILABLE, WORKSPACE_TOO_LARGE
}

internal class DeviceHistoryLocalFailure(val status: DeviceHistoryStatus) : IllegalStateException()

internal data class DeviceHistorySyncState(
    val preferences: DeviceHistoryPreferences = DeviceHistoryPreferences(),
    val storeReady: Boolean = false,
    val busy: Boolean = false,
    val status: DeviceHistoryStatus = DeviceHistoryStatus.IDLE,
    val fingerprint: String? = null,
    val pairingCode: String? = null,
    val viewedPeer: String? = null,
    val localOffers: List<DeviceHistoryOffer> = emptyList(),
    val remoteOffers: List<DeviceHistoryOffer>? = null,
    val remoteHistoryPages: Boolean = false,
    /** Whether the viewed peer serves verified attachment bytes. */
    val remoteAttachmentTransfer: Boolean = false,
    val importedMessages: Int = 0,
    val importedPages: Int = 0,
    /** Original user attachments verified, stored, and bound in this receive. */
    val restoredAttachments: Int = 0,
    /** Attachments that stayed unrestored; a later receive retries them. */
    val failedAttachments: Int = 0,
    val receivingWorkspace: Boolean = false,
    val workspaceHistoryReceived: Boolean = false,
    val workspaceReceipt: DeviceWorkspaceReceipt? = null,
)

/**
 * One open attachment byte ticket per authenticated serving session and
 * attachment. The wire reads 384 KiB segments; reopening the verified ticket
 * per segment would reload and re-verify up to 32 MiB each time. The ticket
 * instead stays open for the session, is replaced on (epoch, task,
 * attachment) mismatch, and is closed on revocation failures and every
 * terminal path. Lives only inside the per-restart source closure — never in
 * long-lived App state.
 */
internal class AttachmentTicketSession(
    private val store: AndroidNativeDeviceHistoryStore,
    private val epoch: Long,
) {
    private data class Held(val task: UUID, val attachment: UUID, val ticket: Long)

    private val lock = Mutex()
    private var held: Held? = null

    suspend fun read(task: UUID, attachment: UUID, offset: Long, count: Int): ByteArray {
        if (offset < 0 || count <= 0 || count > SEGMENT) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        }
        val ticket = lock.withLock {
            val current = held
            if (current == null || current.task != task || current.attachment != attachment) {
                current?.let { store.attachmentClose(it.ticket) }
                val opened = store.attachmentOpen(epoch, task, attachment)
                Held(task, attachment, opened).also { held = it }.ticket
            } else {
                current.ticket
            }
        }
        return try {
            store.attachmentRead(ticket, offset, count)
        } catch (failure: Exception) {
            // Revocation or I/O failure: drop the cached ticket so the next
            // segment re-opens (and re-authorizes) instead of reusing stale
            // bytes.
            lock.withLock { if (held?.ticket == ticket) held = null }
            store.attachmentClose(ticket)
            throw failure
        }
    }

    suspend fun close() {
        lock.withLock {
            held?.let { store.attachmentClose(it.ticket) }
            held = null
        }
    }

    private companion object {
        const val SEGMENT = 384 * 1024
    }
}

/** App-process owner. A view can close without retiring the negotiated listener. */
internal class DeviceHistorySyncHost(
    context: Context,
    private val scope: CoroutineScope,
    private val local: DeviceHistoryLocalStore,
    private val onImport: (Long, UUID) -> Unit,
) {
    private val context = context.applicationContext
    private val settings = DeviceHistoryPreferenceStore(this.context)
    private val workspaces = AndroidDeviceWorkspaceStore(this.context)
    private val keys = AndroidKeystoreCredentialStore(this.context, "device-history")
    private val bridge = AndroidHostBridgeClient()
    private val requestedEpoch = AtomicLong()
    private val action = AtomicReference<Job?>()
    private val serial = Mutex()
    private val mutable = MutableStateFlow(DeviceHistorySyncState())
    val state = mutable.asStateFlow()

    private data class Active(
        val epoch: Long,
        val link: FloeDeviceLink,
        val sync: DeviceHistorySync,
        val usesRelay: Boolean,
    )
    private var preferences: DeviceHistoryPreferences? = null
    private var active: Active? = null
    /** Closed on every stop; one attachment ticket cache per serving build. */
    private var attachmentSession: AttachmentTicketSession? = null

    fun storeChanged(epoch: Long?) {
        val target = epoch?.takeIf { it > 0 } ?: 0L
        if (requestedEpoch.getAndSet(target) == target) return
        action.get()?.cancel()
        scope.launch(Dispatchers.IO) {
            serial.withLock {
                if (requestedEpoch.get() != target) return@withLock
                mutable.update { it.copy(storeReady = target > 0, busy = true) }
                try {
                    stop()
                    reload()
                    restart()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: DeviceHistoryLocalFailure) {
                    show(failure.status)
                } catch (_: LinkageError) {
                    show(DeviceHistoryStatus.START_FAILED)
                } catch (_: Exception) {
                    show(DeviceHistoryStatus.START_FAILED)
                } finally {
                    mutable.update { it.copy(busy = false) }
                }
            }
        }
    }

    fun setEnabled(enabled: Boolean) = run {
        stop()
        save(requirePreferences().copy(enabled = enabled))
        restart()
    }

    fun setPublicRelay(enabled: Boolean) = run {
        val previous = requirePreferences()
        stop()
        save(previous.copy(publicRelay = enabled, customRelay = if (enabled) null else previous.customRelay))
        restart()
    }

    fun setCustomRelay(text: String) = run {
        val relay = try {
            DeviceHistoryPreferenceStore.validatedRelay(text)
        } catch (_: Exception) {
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.INVALID_RELAY)
        }
        stop()
        save(requirePreferences().copy(publicRelay = false, customRelay = relay))
        restart()
    }

    fun retry() = run {
        stop()
        reload()
        restart()
    }

    fun refreshAddress() = run {
        readAddress(requireActive())
    }

    fun pair(ticket: DeviceHistoryPairingTicket, name: String) = run {
        val current = requireActive()
        val previous = requirePreferences()
        val label = name.trim().take(100)
        val id = ticket.address.endpointId
        require(label.isNotEmpty() && id != current.link.address().endpointId)
        val saved = previous.peers.firstOrNull { it.id == id }
        replacePeers(previous, previous.peers.filterNot { it.id == id } +
            DeviceHistoryPeer(
                label, ticket.address, saved?.sharedConversations.orEmpty(),
                saved?.workspaceShares.orEmpty(), saved?.workspaceSyncVersions.orEmpty(),
            ))
    }

    fun remove(peerId: String) = run {
        val previous = requirePreferences()
        replacePeers(previous, previous.peers.filterNot { it.id == peerId })
        workspaces.forget(peerId)
        if (mutable.value.viewedPeer == peerId) {
            mutable.update {
                it.copy(viewedPeer = null, localOffers = emptyList(), remoteOffers = null, remoteHistoryPages = false)
            }
        }
    }

    fun showLocalOffers(peerId: String) {
        mutable.update {
            if (it.viewedPeer == peerId) it else {
                it.copy(viewedPeer = peerId, localOffers = emptyList(), remoteOffers = null, remoteHistoryPages = false)
            }
        }
        run {
            requiredPeer(peerId)
            val epoch = requestedEpoch.get()
            ensureEpoch(epoch)
            val offers = local.localOffers(epoch)
            ensureEpoch(epoch)
            mutable.update { if (it.viewedPeer == peerId) it.copy(localOffers = offers) else it }
        }
    }

    fun share(peerId: String, taskId: UUID, enabled: Boolean) = run {
        val previous = requirePreferences()
        val peer = requiredPeer(peerId)
        if (enabled) {
            require(mutable.value.viewedPeer == peerId && mutable.value.localOffers.any { it.id == taskId })
        }
        val shared = if (enabled) peer.sharedConversations + taskId else peer.sharedConversations - taskId
        require(shared.size <= DeviceHistoryPreferenceStore.MAX_SHARED_CONVERSATIONS)
        val workspace = if (enabled) peer.workspaceShares else peer.workspaceShares - taskId
        val versions = if (enabled) peer.workspaceSyncVersions else peer.workspaceSyncVersions - taskId
        replacePeers(previous, previous.peers.map {
            if (it.id == peerId) it.copy(sharedConversations = shared, workspaceShares = workspace, workspaceSyncVersions = versions) else it
        })
        if (!enabled && taskId in peer.workspaceShares) workspaces.forget(peerId, taskId)
    }

    /**
     * Shares or stops sharing this conversation's workspace files with the
     * peer. [propagateChanges] explicitly opts the conversation into v2
     * rename/delete convergence (both devices must grant it before either
     * converges). Enabling without propagation clears a prior grant, exactly
     * like the frozen Apple center.
     */
    fun shareWorkspace(peerId: String, taskId: UUID, enabled: Boolean, propagateChanges: Boolean = false) = run {
        val previous = requirePreferences()
        val peer = requiredPeer(peerId)
        val grants: Map<UUID, String>
        val versions: Map<UUID, Int>
        if (enabled) {
            require(taskId in peer.sharedConversations && mutable.value.viewedPeer == peerId &&
                mutable.value.localOffers.any { it.id == taskId })
            val epoch = requestedEpoch.get()
            ensureEpoch(epoch)
            val bound = try {
                workspaces.scope(epoch, taskId)
            } catch (failure: DeviceHistorySyncException) {
                if (failure.error != DeviceHistorySyncError.NOT_SHARED) throw failure
                throw DeviceHistoryLocalFailure(DeviceHistoryStatus.WORKSPACE_UNAVAILABLE)
            }
            ensureEpoch(epoch)
            grants = peer.workspaceShares + (taskId to bound)
            versions = if (propagateChanges) peer.workspaceSyncVersions + (taskId to 2)
                else peer.workspaceSyncVersions - taskId
        } else {
            grants = peer.workspaceShares - taskId
            versions = peer.workspaceSyncVersions - taskId
        }
        replacePeers(previous, previous.peers.map {
            if (it.id == peerId) it.copy(workspaceShares = grants, workspaceSyncVersions = versions) else it
        })
        if (!enabled && taskId in peer.workspaceShares) workspaces.forget(peerId, taskId)
    }

    fun fetch(peerId: String) = run {
        val current = requireActive()
        val peer = requiredPeer(peerId)
        mutable.update {
            if (it.viewedPeer == peerId) {
                it.copy(remoteOffers = null, remoteHistoryPages = false, remoteAttachmentTransfer = false)
            } else it
        }
        val catalog = withTimeout(30_000) { current.sync.catalog(peer.address) }
        ensureEpoch(current.epoch)
        mutable.update {
            if (it.viewedPeer == peerId) it.copy(
                remoteOffers = catalog.offers,
                remoteHistoryPages = catalog.historyPages,
                remoteAttachmentTransfer = catalog.attachmentTransfer,
            ) else it
        }
    }

    /**
     * The local authority record for this build: attachment restore is real
     * only when the installed native library exports the v2 ABI and the
     * store is live. Never advertised otherwise.
     */
    private fun authority(epoch: Long): DeviceSyncAuthority =
        DeviceSyncAuthority(
            attachmentRestore = epoch > 0 && bridge.historyV2Available(),
            workspaceConvergence = true,
        )

    private fun remoteCatalog(state: DeviceHistorySyncState, peerId: String): DeviceHistoryCatalog? {
        if (state.viewedPeer != peerId) return null
        val offers = state.remoteOffers ?: return null
        return DeviceHistoryCatalog(offers, state.remoteHistoryPages, state.remoteAttachmentTransfer)
    }

    fun receive(peerId: String, taskId: UUID, includeWorkspace: Boolean = false) = run {
        val current = requireActive()
        val peer = requiredPeer(peerId)
        val selection = mutable.value
        val offer = selection.remoteOffers.orEmpty().firstOrNull { it.id == taskId }
        require(selection.viewedPeer == peerId && offer != null && (!includeWorkspace || offer.workspaceFiles))
        if (includeWorkspace) mutable.update { it.copy(receivingWorkspace = true) }
        workspaceSyncStep("session") {
            current.sync.receiveFrom(peer.address) { session ->
                val catalog = remoteCatalog(selection, peerId)
                val typedHistory = AndroidHostScopeContract.importsAttachments(
                    authority(current.epoch), includeWorkspace, catalog, taskId,
                )
                val version = if (typedHistory) 2 else 1
                // A prior text-only cursor must not skip old attachment-bearing
                // messages when the user first opts into files.
                val cursorPeer = AndroidHostScopeContract.cursorPeer(peer.id, typedHistory)
                workspaceSyncStep("history") {
                    receiveHistory(current, peer, taskId, selection.remoteHistoryPages, session, version, cursorPeer)
                }
                if (typedHistory) {
                    workspaceSyncStep("attachments") {
                        receiveAttachments(current, taskId, session)
                    }
                }
                if (includeWorkspace) {
                    mutable.update { it.copy(workspaceHistoryReceived = true) }
                    ensureEpoch(current.epoch)
                    val convergence = if (AndroidHostScopeContract.convergesWorkspace(
                            authority(current.epoch), peer, taskId, offer,
                        )
                    ) {
                        DeviceWorkspaceConvergence.V2
                    } else {
                        DeviceWorkspaceConvergence.V1
                    }
                    val receiver = workspaceSyncStep("bind") { workspaces.receiver(current.epoch, peer.id, taskId) }
                    val receipt = receiver.use {
                        workspaceSyncStep("transfer") { session.workspace(taskId, it, convergence) }
                    }
                    ensureEpoch(current.epoch)
                    mutable.update { it.copy(workspaceReceipt = receipt, status = DeviceHistoryStatus.WORKSPACE_RECEIVED) }
                }
            }
            val refreshed = try {
                local.localOffers(current.epoch)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
            ensureEpoch(current.epoch)
            if (refreshed != null) mutable.update {
                if (it.viewedPeer == peerId) it.copy(localOffers = refreshed) else it
            }
        }
    }

    private suspend fun <T> workspaceSyncStep(stage: String, operation: suspend () -> T): T {
        try {
            return operation()
        } catch (timeout: TimeoutCancellationException) {
            android.util.Log.w("FloeWorkspaceSync", "stage=$stage error=timeout")
            throw timeout
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            val classification = (failure as? DeviceHistorySyncException)?.error?.name ?: failure.javaClass.simpleName
            android.util.Log.w("FloeWorkspaceSync", "stage=$stage error=$classification")
            throw failure
        }
    }

    fun cancelWorkspaceTransfer() {
        if (mutable.value.receivingWorkspace) action.get()?.cancel()
    }

    private suspend fun receiveHistory(
        current: Active,
        peer: DeviceHistoryPeer,
        taskId: UUID,
        pages: Boolean,
        session: DeviceHistorySync.ReceiveSession,
        version: Int,
        cursorPeer: String,
    ) {
        if (pages && receivePages(current, taskId, session, version, cursorPeer)) return

        val data = withTimeout(60_000) { session.history(taskId, version) }
        try {
            currentCoroutineContext().ensureActive()
            ensureEpoch(current.epoch)
            val added = local.importHistory(current.epoch, taskId, data, version)
            ensureEpoch(current.epoch)
            onImport(current.epoch, taskId)
            mutable.update { it.copy(importedMessages = added, status = DeviceHistoryStatus.RECEIVED) }
        } finally {
            data.fill(0)
        }
    }

    /**
     * Pulls the original user attachment bytes declared by the imported v2
     * history. Runs only when the peer advertised the capability and the
     * workspace share is active; per-item failures are counted and retried on
     * a later receive, never surfaced as half-links. Authorization that
     * vanishes mid-phase stops the pull; the workspace phase reports the
     * revocation honestly.
     */
    private suspend fun receiveAttachments(
        current: Active,
        taskId: UUID,
        session: DeviceHistorySync.ReceiveSession,
    ) {
        val epoch = current.epoch
        val items = try {
            (local as? AndroidNativeDeviceHistoryStore)?.pendingAttachments(epoch, taskId).orEmpty()
        } catch (_: Exception) {
            return
        }
        val valid = items.filter {
            it.byteCount in 0..MAXIMUM_ITEM_BYTES && it.digest.length == 64 &&
                it.digest.all { char -> char.isDigit() || char in 'a'..'f' }
        }
        var budget = MAXIMUM_TOTAL_BYTES
        var restored = 0
        var failed = 0
        try {
            for (item in valid.take(MAXIMUM_ITEMS)) {
                currentCoroutineContext().ensureActive()
                ensureEpoch(epoch)
                if (item.byteCount.toLong() > budget) break
                val bytes = try {
                    workspaceSyncStep("attachmentBytes") { pullAttachmentBytes(session, taskId, item) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: DeviceHistorySyncException) {
                    if (failure.error == DeviceHistorySyncError.NOT_SHARED ||
                        failure.error == DeviceHistorySyncError.DISCONNECTED
                    ) {
                        return
                    }
                    failed += 1
                    continue
                } catch (_: Exception) {
                    failed += 1
                    continue
                }
                try {
                    ensureEpoch(epoch)
                    val stored = (local as? AndroidNativeDeviceHistoryStore)
                        ?.restoreAttachment(epoch, taskId, item, bytes) == true
                    if (stored) {
                        restored += 1
                        budget -= item.byteCount.toLong()
                    } else {
                        failed += 1
                    }
                } finally {
                    bytes.fill(0)
                }
            }
        } finally {
            if (restored > 0 || failed > 0) {
                mutable.update { it.copy(restoredAttachments = restored, failedAttachments = failed) }
                if (restored > 0) onImport(epoch, taskId)
            }
        }
    }

    private suspend fun pullAttachmentBytes(
        session: DeviceHistorySync.ReceiveSession,
        taskId: UUID,
        item: AndroidHostBridgeClient.PendingAttachment,
    ): ByteArray {
        val assembled = ByteArray(item.byteCount)
        try {
            var offset = 0
            while (offset < item.byteCount) {
                currentCoroutineContext().ensureActive()
                val count = minOf(ATTACHMENT_CHUNK, item.byteCount - offset)
                val bytes = session.attachmentChunk(taskId, item.attachmentID, offset, count)
                try {
                    bytes.copyInto(assembled, destinationOffset = offset)
                    offset += bytes.size
                } finally {
                    bytes.fill(0)
                }
            }
            if (sha256(assembled) != item.digest) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            return assembled
        } catch (failure: Throwable) {
            assembled.fill(0)
            throw failure
        }
    }

    private fun sha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val digits = "0123456789abcdef"
        return buildString(digest.size * 2) {
            digest.forEach { byte ->
                val value = byte.toInt()
                append(digits[(value ushr 4) and 0x0f])
                append(digits[value and 0x0f])
            }
        }
    }

    private suspend fun receivePages(
        current: Active,
        taskId: UUID,
        session: DeviceHistorySync.ReceiveSession,
        version: Int,
        cursorPeer: String,
    ): Boolean {
        val epoch = current.epoch
        val after = local.storedCursor(epoch, cursorPeer, taskId)
        ensureEpoch(epoch)
        var pages = 0
        var added = 0
        suspend fun commit(page: DeviceHistoryPage) {
            try {
                currentCoroutineContext().ensureActive()
                ensureEpoch(epoch)
                added += local.importPage(epoch, cursorPeer, taskId, page, version)
                ensureEpoch(epoch)
                pages += 1
                mutable.update { it.copy(importedPages = pages, importedMessages = added) }
            } finally {
                page.bytes.fill(0)
            }
        }
        try {
            val paged = try {
                session.historyPages(taskId, after, ::commit, version)
            } catch (failure: DeviceHistorySyncException) {
                if (after == null || pages != 0 || !failure.restartableCursor) throw failure
                // The first request refused the old cursor. Replay once
                // from the start and advance only with an actual commit.
                session.historyPages(taskId, null, ::commit, version)
            }
            if (paged) show(DeviceHistoryStatus.RECEIVED)
            return paged
        } finally {
            if (pages > 0 && requestedEpoch.get() == epoch) onImport(epoch, taskId)
        }
    }

    private fun run(operation: suspend () -> Unit) {
        scope.launch(Dispatchers.IO) {
            if (!serial.tryLock()) return@launch
            val job = currentCoroutineContext()[Job]
            action.set(job)
            mutable.update { it.copy(
                busy = true, importedPages = 0, importedMessages = 0, workspaceReceipt = null,
                restoredAttachments = 0, failedAttachments = 0,
                workspaceHistoryReceived = false,
                status = if (active == null) DeviceHistoryStatus.IDLE else DeviceHistoryStatus.READY,
            ) }
            try {
                operation()
            } catch (_: TimeoutCancellationException) {
                show(DeviceHistoryStatus.TRANSFER_FAILED)
            } catch (cancelled: CancellationException) {
                if (mutable.value.receivingWorkspace && active?.epoch == requestedEpoch.get()) {
                    show(DeviceHistoryStatus.WORKSPACE_PAUSED)
                }
                throw cancelled
            } catch (failure: DeviceHistoryLocalFailure) {
                show(failure.status)
            } catch (failure: DeviceHistorySyncException) {
                show(when (failure.error) {
                    DeviceHistorySyncError.UNSUPPORTED_VERSION -> DeviceHistoryStatus.INCOMPATIBLE
                    DeviceHistorySyncError.CONFLICT -> DeviceHistoryStatus.CONFLICT
                    DeviceHistorySyncError.CURSOR_EXPIRED -> DeviceHistoryStatus.CURSOR_EXPIRED
                    DeviceHistorySyncError.NOT_SHARED -> DeviceHistoryStatus.NO_LONGER_SHARED
                    DeviceHistorySyncError.TOO_LARGE -> if (mutable.value.receivingWorkspace) {
                        DeviceHistoryStatus.WORKSPACE_TOO_LARGE
                    } else DeviceHistoryStatus.TRANSFER_FAILED
                    DeviceHistorySyncError.BUSY -> DeviceHistoryStatus.BUSY_TASK
                    else -> DeviceHistoryStatus.TRANSFER_FAILED
                })
            } catch (_: LinkageError) {
                show(DeviceHistoryStatus.START_FAILED)
            } catch (_: Exception) {
                show(if (active == null) DeviceHistoryStatus.START_FAILED else DeviceHistoryStatus.TRANSFER_FAILED)
            } finally {
                action.compareAndSet(job, null)
                mutable.update { it.copy(busy = false, receivingWorkspace = false) }
                serial.unlock()
            }
        }
    }

    private fun requirePreferences() = preferences ?: throw DeviceHistoryLocalFailure(DeviceHistoryStatus.SETTINGS_FAILED)

    private fun reload() {
        preferences = null
        try {
            preferences = settings.read()
            mutable.update { it.copy(preferences = requirePreferences()) }
        } catch (_: Exception) {
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.SETTINGS_FAILED)
        }
    }

    private fun save(value: DeviceHistoryPreferences) {
        try {
            settings.write(value)
        } catch (_: Exception) {
            throw DeviceHistoryLocalFailure(DeviceHistoryStatus.SETTINGS_FAILED)
        }
        preferences = value
        mutable.update { it.copy(preferences = value) }
    }

    private suspend fun replacePeers(previous: DeviceHistoryPreferences, peers: List<DeviceHistoryPeer>) {
        val next = previous.copy(peers = peers)
        save(next)
        val current = active ?: return
        try {
            current.sync.replaceShares(next.shares(), next.workspaceShares(), next.workspaceVersions())
            ensureEpoch(current.epoch)
        } catch (failure: Exception) {
            stop()
            throw failure
        }
    }

    private fun requiredPeer(peerId: String): DeviceHistoryPeer =
        requireNotNull(requirePreferences().peers.firstOrNull { it.id == peerId })

    private fun requireActive(): Active = checkNotNull(active).also { ensureEpoch(it.epoch) }

    private fun ensureEpoch(epoch: Long) {
        check(epoch > 0 && requestedEpoch.get() == epoch)
    }

    private suspend fun stop() {
        val previous = active
        active = null
        attachmentSession?.close()
        attachmentSession = null
        mutable.update { it.copy(
            fingerprint = null, pairingCode = null, localOffers = emptyList(),
            remoteOffers = null, remoteHistoryPages = false, remoteAttachmentTransfer = false,
        ) }
        if (previous != null) withContext(NonCancellable) { previous.sync.stop() }
    }

    private suspend fun restart() {
        stop()
        val config = requirePreferences()
        val epoch = requestedEpoch.get()
        if (!config.enabled || epoch <= 0) {
            show(DeviceHistoryStatus.IDLE)
            return
        }
        val identity = loadIdentity()
        val relay = config.customRelay?.let { FloeDeviceLinkRelay.Custom(it) }
            ?: if (config.publicRelay) FloeDeviceLinkRelay.PUBLIC_IROH else FloeDeviceLinkRelay.DISABLED
        val peers = config.shares().keys
        val link = try {
            FloeDeviceLink.bind(context, identity, peers, relay, bindAddress = config.port?.let { "0.0.0.0:$it" })
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            if (config.port == null) throw failure
            FloeDeviceLink.bind(context, identity, peers, relay)
        }
        try {
            ensureEpoch(epoch)
            val port = link.listeningPort
            if (port != null && port != config.port) save(config.copy(port = port))
            val source = object : DeviceHistoryPagedSource {
                override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> {
                    ensureEpoch(epoch)
                    val offers = local.localOffers(epoch).filter { it.id in allowed }
                    ensureEpoch(epoch)
                    return offers
                }
                override suspend fun export(taskId: UUID, version: Int): ByteArray {
                    ensureEpoch(epoch)
                    val data = local.exportHistory(epoch, taskId, version)
                    ensureEpoch(epoch)
                    return data
                }
                override suspend fun historyPage(
                    taskId: UUID, after: String?, through: Long?, version: Int,
                ): DeviceHistoryPage {
                    ensureEpoch(epoch)
                    val page = local.exportPage(epoch, taskId, after, through, version)
                    ensureEpoch(epoch)
                    return page
                }
            }
            val workspaceSource = workspaces.source(epoch) { peer, task ->
                val current = mutable.value.preferences
                if (requestedEpoch.get() != epoch || !current.enabled) null
                else current.peers.firstOrNull { it.id == peer && task in it.sharedConversations }
                    ?.workspaceShares?.get(task)
            }
            // The serving attachment source is only registered when the local
            // authority is real; the wire keeps the capability omitted
            // otherwise, so a stale library can never advertise bytes it
            // cannot serve. The ticket session dies with this serving build.
            val syncAuthority = authority(epoch)
            val servingStore = local as? AndroidNativeDeviceHistoryStore
            val attachmentSession = if (syncAuthority.attachmentRestore && servingStore != null) {
                AttachmentTicketSession(servingStore, epoch)
            } else {
                null
            }
            this.attachmentSession = attachmentSession
            val attachmentSource = attachmentSession?.let { session ->
                object : DeviceHistoryAttachmentSource {
                    override suspend fun attachment(taskId: UUID, attachmentId: UUID, offset: Long, count: Int): ByteArray =
                        session.read(taskId, attachmentId, offset, count)
                }
            }
            val sync = DeviceHistorySync(
                link,
                config.shares(),
                source,
                workspaceSource,
                attachmentSource,
                config.workspaceShares(),
                config.workspaceVersions(),
                workspaceProtocolVersion = 2,
            )
            sync.start(scope)
            val bound = Active(epoch, link, sync, relay != FloeDeviceLinkRelay.DISABLED)
            active = bound
            show(DeviceHistoryStatus.READY)
            readAddress(bound)
        } catch (failure: Throwable) {
            if (active?.link === link) stop() else link.close()
            throw failure
        }
    }

    private suspend fun loadIdentity(): FloeDeviceLinkIdentity {
        val existing = keys.read("identity-v1")
        if (existing != null) {
            return try { FloeDeviceLinkIdentity(existing) } finally { existing.fill(0) }
        }
        val identity = FloeDeviceLinkIdentity.generate()
        val bytes = identity.privateKeyBytes()
        try {
            keys.write("identity-v1", bytes)
        } finally {
            bytes.fill(0)
        }
        return identity
    }

    private suspend fun readAddress(current: Active) {
        ensureEpoch(current.epoch)
        var address = current.link.address()
        for (attempt in 1..15) {
            val ready = if (current.usesRelay) address.relayUrl != null else address.directAddresses.isNotEmpty()
            if (ready) break
            delay(150)
            ensureEpoch(current.epoch)
            address = current.link.address()
        }
        val available = address.directAddresses.isNotEmpty() || address.relayUrl != null
        mutable.update { it.copy(fingerprint = address.endpointId,
            pairingCode = if (available) DeviceHistoryPairingTicket(address).code() else null,
            status = if (current.usesRelay && address.relayUrl == null) DeviceHistoryStatus.RELAY_PENDING
            else DeviceHistoryStatus.READY) }
    }

    private fun show(status: DeviceHistoryStatus) {
        mutable.update { it.copy(status = status) }
    }

    private companion object {
        /** Per-conversation restore cap for one receive pass (frozen limit). */
        const val MAXIMUM_ITEMS = 512
        /** One attachment never exceeds this many bytes (frozen limit). */
        const val MAXIMUM_ITEM_BYTES = 32 * 1024 * 1024
        /** Total byte budget for one receive pass (frozen limit). */
        const val MAXIMUM_TOTAL_BYTES = 2L shl 30
        /** The wire segment used for attachment reads (384 KiB). */
        const val ATTACHMENT_CHUNK = 384 * 1024
    }
}
