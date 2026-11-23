// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import android.content.Context
import com.floe.android.core.devicelink.DeviceHistoryOffer
import com.floe.android.core.devicelink.DeviceHistoryPairingTicket
import com.floe.android.core.devicelink.DeviceHistorySource
import com.floe.android.core.devicelink.DeviceHistorySync
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import com.floe.android.core.devicelink.FloeDeviceLink
import com.floe.android.core.devicelink.FloeDeviceLinkIdentity
import com.floe.android.core.devicelink.FloeDeviceLinkRelay
import com.floe.android.credentials.AndroidKeystoreCredentialStore
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
    suspend fun exportHistory(epoch: Long, taskId: UUID): ByteArray
    suspend fun importHistory(epoch: Long, taskId: UUID, bytes: ByteArray): Int
}

internal enum class DeviceHistoryStatus {
    IDLE, READY, START_FAILED, SETTINGS_FAILED, TRANSFER_FAILED, CONFLICT,
    BUSY_TASK, INCOMPATIBLE, INVALID_RELAY, RELAY_PENDING, IMPORT_UNCONFIRMED, RECEIVED
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
    val importedMessages: Int = 0,
)

/** App-process owner. A view can close without retiring the negotiated listener. */
internal class DeviceHistorySyncHost(
    context: Context,
    private val scope: CoroutineScope,
    private val local: DeviceHistoryLocalStore,
    private val onImport: (Long, UUID) -> Unit,
) {
    private val context = context.applicationContext
    private val settings = DeviceHistoryPreferenceStore(this.context)
    private val keys = AndroidKeystoreCredentialStore(this.context, "device-history")
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
        val shared = previous.peers.firstOrNull { it.id == id }?.sharedConversations.orEmpty()
        replacePeers(previous, previous.peers.filterNot { it.id == id } +
            DeviceHistoryPeer(label, ticket.address, shared))
    }

    fun remove(peerId: String) = run {
        val previous = requirePreferences()
        replacePeers(previous, previous.peers.filterNot { it.id == peerId })
        if (mutable.value.viewedPeer == peerId) {
            mutable.update { it.copy(viewedPeer = null, localOffers = emptyList(), remoteOffers = null) }
        }
    }

    fun showLocalOffers(peerId: String) {
        mutable.update {
            if (it.viewedPeer == peerId) it else it.copy(viewedPeer = peerId, localOffers = emptyList(), remoteOffers = null)
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
        replacePeers(previous, previous.peers.map { if (it.id == peerId) it.copy(sharedConversations = shared) else it })
    }

    fun fetch(peerId: String) = run {
        val current = requireActive()
        val peer = requiredPeer(peerId)
        mutable.update { if (it.viewedPeer == peerId) it.copy(remoteOffers = null) else it }
        val offers = withTimeout(30_000) { current.sync.offers(peer.address) }
        ensureEpoch(current.epoch)
        mutable.update { if (it.viewedPeer == peerId) it.copy(remoteOffers = offers) else it }
    }

    fun receive(peerId: String, taskId: UUID) = run {
        val current = requireActive()
        val peer = requiredPeer(peerId)
        require(mutable.value.viewedPeer == peerId && mutable.value.remoteOffers.orEmpty().any { it.id == taskId })
        val data = withTimeout(60_000) { current.sync.history(taskId, peer.address) }
        try {
            currentCoroutineContext().ensureActive()
            ensureEpoch(current.epoch)
            val added = local.importHistory(current.epoch, taskId, data)
            ensureEpoch(current.epoch)
            onImport(current.epoch, taskId)
            mutable.update { it.copy(importedMessages = added, status = DeviceHistoryStatus.RECEIVED) }
        } finally {
            data.fill(0)
        }
    }

    private fun run(operation: suspend () -> Unit) {
        scope.launch(Dispatchers.IO) {
            if (!serial.tryLock()) return@launch
            val job = currentCoroutineContext()[Job]
            action.set(job)
            mutable.update { it.copy(busy = true, status = if (active == null) DeviceHistoryStatus.IDLE else DeviceHistoryStatus.READY) }
            try {
                operation()
            } catch (_: TimeoutCancellationException) {
                show(DeviceHistoryStatus.TRANSFER_FAILED)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: DeviceHistoryLocalFailure) {
                show(failure.status)
            } catch (failure: DeviceHistorySyncException) {
                show(when (failure.error) {
                    DeviceHistorySyncError.UNSUPPORTED_VERSION -> DeviceHistoryStatus.INCOMPATIBLE
                    DeviceHistorySyncError.CONFLICT -> DeviceHistoryStatus.CONFLICT
                    else -> DeviceHistoryStatus.TRANSFER_FAILED
                })
            } catch (_: LinkageError) {
                show(DeviceHistoryStatus.START_FAILED)
            } catch (_: Exception) {
                show(if (active == null) DeviceHistoryStatus.START_FAILED else DeviceHistoryStatus.TRANSFER_FAILED)
            } finally {
                action.compareAndSet(job, null)
                mutable.update { it.copy(busy = false) }
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
            current.sync.replaceShares(next.shares())
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
        mutable.update { it.copy(fingerprint = null, pairingCode = null, localOffers = emptyList(), remoteOffers = null) }
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
            val source = object : DeviceHistorySource {
                override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> {
                    ensureEpoch(epoch)
                    val offers = local.localOffers(epoch).filter { it.id in allowed }
                    ensureEpoch(epoch)
                    return offers
                }
                override suspend fun export(taskId: UUID): ByteArray {
                    ensureEpoch(epoch)
                    val data = local.exportHistory(epoch, taskId)
                    ensureEpoch(epoch)
                    return data
                }
            }
            val sync = DeviceHistorySync(link, config.shares(), source)
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
}
