// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.ide.IdePresenter
import com.floe.android.feature.ide.api.IdeRecoveryProjection
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Application-owned projections over the one native document authority.
 * A view disappearing does not detach ACK delivery or discard unsent typing.
 * Every request still revalidates its native epoch, task and workspace in Core.
 * This holds RAM projections only: no Kotlin document/revision store is added.
 */
internal class G04WorkspaceEditorController(private val host: RuntimeHost) {
    internal data class Binding(
        val client: G04WorkspaceBridgeClient,
        val ide: G04IdeHostAdapter,
        val presenter: IdePresenter,
        val isCurrent: () -> Boolean,
        // View lifetime flags are not document ownership. They only protect
        // a visible clean projection from opportunistic RAM-cache eviction.
        val viewOwners: MutableSet<AtomicBoolean> = ConcurrentHashMap.newKeySet(),
    )
    private data class Key(val taskID: String, val epoch: Long, val generation: Long)
    private val lock = Mutex()
    private val sequence = AtomicLong()
    private val bindings = LinkedHashMap<Key, Binding>()
    private var drainingEpoch: Long? = null
    private val recovering = HashSet<G04IdeHostAdapter>()
    internal data class RecoveryRow(val binding: Binding, val projection: IdeRecoveryProjection)

    suspend fun recoveryRows(): List<RecoveryRow> = lock.withLock {
        bindings.values.flatMap { binding -> binding.presenter.recoveryProjections().map { RecoveryRow(binding, it) } }
    }

    /** The Application owns every upload step; dismissing its sheet only
     * cancels a UI waiter. It never clears unconfirmed text before proof. */
    suspend fun copyRecovery(row: RecoveryRow, target: G04WorkspaceBridgeClient): String =
        host.scope.async(host.ioDispatcher) { performRecovery(row, target) }.await()

    private suspend fun performRecovery(row: RecoveryRow, target: G04WorkspaceBridgeClient): String {
        val source = row.binding
        lock.withLock {
            if (bindings.values.none { it === source } || !recovering.add(source.ide))
                throw G04WorkspaceBridgeClient.Failure("workspaceBusy")
            source.presenter.setInputAdmission(false)
            if (!source.ide.isIdle() || row.projection.composing) {
                recovering.remove(source.ide)
                if (source.isCurrent() && drainingEpoch != host.nativeRootEpoch()) source.presenter.setInputAdmission(true)
                throw G04WorkspaceBridgeClient.Failure("workspaceBusy")
            }
        }
        try {
            val path = target.preserveProjection(row.projection.recoveryId, row.projection.relativePath, row.projection.text)
            lock.withLock {
                if (!source.ide.isIdle() || !source.presenter.acknowledgeRecoveredProjection(row.projection))
                    throw G04WorkspaceBridgeClient.Failure("recoveryProjectionChanged")
                // A genuinely newer native Root proves its predecessor's
                // accepted drafts passed the native preservation gate. Only
                // the now-settled stale RAM projection is released here.
                val old = bindings.entries.firstOrNull { it.value === source }
                if (old != null && old.key.epoch != host.nativeRootEpoch() && !source.presenter.hasUnsettledEdits()) {
                    bindings.remove(old.key); source.presenter.release(); source.ide.close()
                }
            }
            return path
        } finally {
            withContext(NonCancellable) { lock.withLock {
                recovering.remove(source.ide)
                if (source.isCurrent() && drainingEpoch != host.nativeRootEpoch()) source.presenter.setInputAdmission(true)
            } }
        }
    }

    /** Called only after the user confirms discarding this exact snapshot. */
    suspend fun discardRecovery(row: RecoveryRow): Boolean = lock.withLock {
        if (bindings.values.none { it === row.binding } || row.binding.ide in recovering || !row.binding.ide.isIdle()) return@withLock false
        row.binding.presenter.discardRecoveryProjection(row.projection)
    }

    suspend fun acquire(taskID: String, errorText: (String) -> String, viewLifetime: AtomicBoolean): Binding = lock.withLock {
        val epoch = host.nativeRootEpoch() ?: throw G04WorkspaceBridgeClient.Failure("ownerUnavailable")
        if (drainingEpoch == epoch) throw G04WorkspaceBridgeClient.Failure("ownerStopping")
        // A genuinely new native Root can admit its own binding. Old dirty
        // projections stay fenced and retained until recovered or explicitly
        // discarded after a proven deletion; no automatic cross-epoch replay.
        if (drainingEpoch != null && drainingEpoch != epoch) drainingEpoch = null
        val generation = host.commandClient.generation()
        val key = Key(taskID, epoch, generation)
        bindings[key]?.takeIf { it.isCurrent() }?.let {
            it.viewOwners.removeIf { owner -> !owner.get() }
            it.viewOwners.add(viewLifetime)
            return@withLock it
        }
        // A settled clean projection no longer shown by any view may be
        // released even within the same Root. Otherwise visiting eight tasks
        // would permanently prevent opening a ninth. Dirty or rejected edits
        // remain service-owned regardless of view lifetime or Root changes.
        val removable = bindings.filterValues { binding ->
            binding.viewOwners.none { it.get() } && binding.ide.isIdle() &&
                !binding.presenter.hasUnsettledEdits() &&
                binding.presenter.state.value.tabs.none { it.descriptor.dirty }
        }.keys.toList()
        for (old in removable) bindings.remove(old)?.let { binding ->
            binding.presenter.release()
            binding.ide.close()
        }
        if (bindings.size >= 8) throw G04WorkspaceBridgeClient.Failure("editorSessionsSaturated")
        val current = {
            host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation &&
                host.conversations.entryFor(taskID)?.isTemporary == false
        }
        if (!current()) throw G04WorkspaceBridgeClient.Failure("ownerUnavailable")
        val client = G04WorkspaceBridgeClient.bind(host, taskID, current)
        if (!current()) throw G04WorkspaceBridgeClient.Failure("ownerChanged")
        val adapter = G04IdeHostAdapter(host, client, sequence.incrementAndGet(), current, errorText,
            extras = G04IdeHostAdapter.Extras(preview = { _, path ->
                host.browser.requestWorkspacePreview(taskID, client.workspaceID, path, current)
            }))
        val presenter = IdePresenter(adapter).also { it.start() }
        Binding(client, adapter, presenter, current).also {
            it.viewOwners.add(viewLifetime)
            bindings[key] = it
        }
    }

    /** UI Git mutations fence unsent JVM typing before the native document
     * barrier is acquired. This owns no filesystem or Git authority. */
    suspend fun <T> withExternalMutation(taskID: String, operation: suspend () -> T): T {
        val owned = lock.withLock {
            val epoch = host.nativeRootEpoch() ?: throw G04WorkspaceBridgeClient.Failure("ownerUnavailable")
            if (drainingEpoch == epoch) throw G04WorkspaceBridgeClient.Failure("ownerStopping")
            val rows = bindings.filterKeys { it.taskID == taskID && it.epoch == epoch }.values.toList()
            rows.forEach { it.presenter.setInputAdmission(false) }
            if (rows.any { !it.ide.isIdle() || it.presenter.hasUnsettledEdits() || it.presenter.state.value.tabs.any { tab -> tab.descriptor.dirty } }) {
                rows.filter { it.isCurrent() }.forEach { it.presenter.setInputAdmission(true) }
                throw G04WorkspaceBridgeClient.Failure("dirtyDocument")
            }
            rows
        }
        try { return operation() }
        finally {
            // Partial Git failures can still have changed disk files. The
            // native barrier rereads those before returning; refresh this
            // projection on either outcome under the same original owner.
            withContext(NonCancellable) {
                lock.withLock {
                    owned.filter { it.isCurrent() }.forEach { binding ->
                        binding.ide.refreshWorkspace()
                        if (drainingEpoch != host.nativeRootEpoch()) binding.presenter.setInputAdmission(true)
                    }
                }
            }
        }
    }

    /** Runs BEFORE native Root stop and before host generation invalidation.
     * A deadline returns false with all ownership/data retained. The native
     * pre-drain gate then preserves the actually accepted native drafts. */
    suspend fun prepareForRootStop(timeoutMillis: Long = 5_000): Boolean {
        val epoch = host.nativeRootEpoch() ?: return false
        val owned = lock.withLock {
            drainingEpoch = epoch
            bindings.values.toList().also { rows -> rows.forEach { it.presenter.setInputAdmission(false) } }
        }
        var settled = false
        try {
            val idle = withTimeoutOrNull(timeoutMillis) {
                while (owned.any { !it.ide.isIdle() } || lock.withLock { recovering.isNotEmpty() }) delay(10)
                true
            } == true
            if (!idle) return false
            // Recovery is bounded by bytes/count, not the old 5-second edit
            // wait budget: a complete large document can need many pages.
            // Any cancellation/failure retains its original projection.
            val generation = host.commandClient.generation()
            val targets = HashMap<String, G04WorkspaceBridgeClient>()
            for (binding in owned) {
                for (projection in binding.presenter.recoveryProjections()) {
                    if (projection.composing) return false
                    val target = targets.getOrPut(binding.client.taskID) {
                        G04WorkspaceBridgeClient.bindExisting(host, binding.client.taskID) {
                            host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation
                        }
                    }
                    if (!target.workspaceID.equals(binding.client.workspaceID, ignoreCase = true)) return false
                    copyRecovery(RecoveryRow(binding, projection), target)
                }
            }
            settled = withTimeoutOrNull(timeoutMillis) {
                while (owned.any { !it.ide.isIdle() || it.presenter.hasUnsettledEdits() }) delay(10)
                true
            } == true
            return settled && host.nativeRootEpoch() == epoch
        } catch (error: kotlinx.coroutines.CancellationException) { throw error }
        catch (_: Exception) { return false }
        finally {
            if (!settled) withContext(NonCancellable) {
                lock.withLock {
                    if (drainingEpoch == epoch) {
                        drainingEpoch = null
                        owned.filter { it.isCurrent() }.forEach { it.presenter.setInputAdmission(true) }
                    }
                }
            }
        }
    }

    /** Only called after the ORIGINAL native deletion has committed/drained.
     * Epoch-exact: a late delete result cannot erase another Root's editor. */
    suspend fun discardDeletedTask(taskID: String, epoch: Long) = lock.withLock {
        host.browser.discardTask(taskID, epoch)
        val removed = bindings.keys.filter { it.taskID == taskID && it.epoch == epoch }
        for (key in removed) bindings.remove(key)?.let { binding ->
            binding.presenter.setInputAdmission(false)
            binding.presenter.release()
            binding.ide.close()
        }
    }

    /** History clear may be partial. Re-read each of the at-most-eight held
     * tasks from Core and discard ONLY its exact typed notFound result;
     * absence from a paged UI history list is never deletion proof. */
    suspend fun reconcileAfterHistoryClear(epoch: Long) {
        val tasks = lock.withLock {
            (bindings.keys.filter { it.epoch == epoch }.map { it.taskID } + host.browser.hostedTasks.value).distinct()
        }
        for (taskID in tasks) {
            if (host.nativeRootEpoch() != epoch) return
            val result = CompletableDeferred<HostOperationOutcome>()
            host.trackOperation(HostCommandRequest(command = "conversation.get",
                scope = HostScope.ConversationLifecycle(taskID), stateful = false,
                correlationID = "editor-deletion-readback:${java.util.UUID.randomUUID()}"),
                onTerminal = { result.complete(it) })
            val outcome = result.await()
            if (host.nativeRootEpoch() != epoch) return
            val missing = when (outcome) {
                is HostOperationOutcome.Rejected -> outcome.code == "notFound"
                is HostOperationOutcome.Failed -> (outcome.detail["wire"] ?: outcome.code) == "notFound"
                else -> false
            }
            if (missing) discardDeletedTask(taskID, epoch)
        }
    }

}
