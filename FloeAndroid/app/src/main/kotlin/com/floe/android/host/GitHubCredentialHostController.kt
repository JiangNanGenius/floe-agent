// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.credentials.GitHubCredentialStore
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Host-only device credential editor. No token enters a projection or wire.
 * Operations retain their owner through physical settlement and outlive a view.
 * Closing/reopening cannot make an old result close or modify a new editor.
 */
class GitHubCredentialHostController internal constructor(private val host: RuntimeHost) {
    enum class Notice { SAVED, REMOVED, INVALID_TOKEN, UNAVAILABLE }
    data class EditorState(
        val editorId: String? = null,
        val configured: Boolean? = null,
        val busy: Boolean = false,
        val notice: Notice? = null,
    )

    private val mutableState = MutableStateFlow(EditorState())
    val state: StateFlow<EditorState> = mutableState
    private val lock = Any()
    private var activeJob: Job? = null
    private var stopped = false
    private val store by lazy { GitHubCredentialStore.create(host.appContext) }

    internal fun start() = synchronized(lock) { stopped = false }

    fun openEditor(): Boolean = synchronized(lock) {
        if (stopped || activeJob != null) return false
        val id = UUID.randomUUID().toString()
        mutableState.value = EditorState(editorId = id)
        launchOperation(id) { publish(id, configured = store.hasToken()) }
    }

    fun closeEditor(editorId: String) {
        mutableState.update { if (it.editorId == editorId) it.copy(editorId = null, notice = null) else it }
    }

    fun refresh(editorId: String): Boolean = launchOperation(editorId) {
        publish(editorId, configured = store.hasToken())
    }

    fun save(editorId: String, draft: String): Boolean {
        // This local buffer is never retained by StateFlow, saved state or logs.
        val bytes = draft.trim().toByteArray(Charsets.UTF_8)
        if (!GitHubCredentialStore.validToken(bytes)) {
            bytes.fill(0)
            mutableState.update {
                if (it.editorId == editorId && !it.busy) it.copy(notice = Notice.INVALID_TOKEN) else it
            }
            return false
        }
        val accepted = launchOperation(editorId, erase = { bytes.fill(0) }) {
            store.save(bytes)
            publish(editorId, configured = true, notice = Notice.SAVED)
        }
        if (!accepted) bytes.fill(0)
        return accepted
    }

    fun delete(editorId: String): Boolean = launchOperation(editorId) {
        store.delete()
        publish(editorId, configured = false, notice = Notice.REMOVED)
    }

    private fun publish(editorId: String, configured: Boolean, notice: Notice? = null) {
        mutableState.update {
            if (it.editorId == editorId) it.copy(configured = configured, notice = notice) else it
        }
    }

    private fun launchOperation(
        editorId: String,
        erase: () -> Unit = {},
        action: suspend () -> Unit,
    ): Boolean = synchronized(lock) {
        if (stopped || activeJob != null || mutableState.value.editorId != editorId) return false
        mutableState.update { it.copy(busy = true, notice = null) }
        val job = host.scope.launch(host.ioDispatcher, start = CoroutineStart.LAZY) {
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                mutableState.update {
                    if (it.editorId == editorId) it.copy(notice = Notice.UNAVAILABLE) else it
                }
            }
        }
        activeJob = job
        job.invokeOnCompletion {
            erase()
            synchronized(lock) {
                if (activeJob === job) {
                    mutableState.update { it.copy(busy = false) }
                    activeJob = null
                }
            }
        }
        job.start()
        true
    }

    internal suspend fun stop() {
        val job = synchronized(lock) {
            stopped = true
            mutableState.update { it.copy(editorId = null, notice = null) }
            activeJob
        }
        // A physical Keystore write/delete is drained, never reported cancelled
        // while it may still commit. No replacement owner is admitted meanwhile.
        job?.join()
    }
}
