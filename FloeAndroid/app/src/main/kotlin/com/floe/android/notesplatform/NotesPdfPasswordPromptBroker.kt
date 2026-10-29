// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

internal data class NotesPdfPasswordPrompt(val id: String, val fileName: String)

/** One App-owned password request; neither state nor saved preferences contains the secret. */
internal class NotesPdfPasswordPromptBroker(
    private val admitsPrompt: () -> Boolean,
) : NotesPdfPasswordProvider {
    private class Pending(val prompt: NotesPdfPasswordPrompt) {
        val signal = CompletableDeferred<Unit>()
        var answer: CharArray? = null
    }

    private val lock = Any()
    private var pending: Pending? = null
    private val promptState = MutableStateFlow<NotesPdfPasswordPrompt?>(null)
    val prompt: StateFlow<NotesPdfPasswordPrompt?> = promptState

    override suspend fun requestPassword(fileName: String): CharArray? {
        val request = synchronized(lock) {
            if (!admitsPrompt()) return null
            if (pending != null) throw NotesPlatformErrors.busy("passwordPromptInFlight")
            Pending(NotesPdfPasswordPrompt(UUID.randomUUID().toString(), fileName.take(160))).also {
                pending = it
                promptState.value = it.prompt
            }
        }
        try {
            request.signal.await()
            currentCoroutineContext().ensureActive()
            return synchronized(lock) {
                request.answer.also { request.answer = null }
            }
        } finally {
            synchronized(lock) {
                request.answer?.fill('\u0000')
                request.answer = null
                if (pending === request) {
                    pending = null
                    promptState.value = null
                }
            }
        }
    }

    /** Takes ownership of the input buffer, including when rejecting a late answer. */
    fun answer(id: String, characters: CharArray?): Boolean {
        try {
            return synchronized(lock) {
                val current = pending ?: return false
                if (current.prompt.id != id || current.signal.isCompleted) return false
                if (characters != null && (characters.isEmpty() || characters.size > 512)) return false
                current.answer = characters?.copyOf()
                current.signal.complete(Unit)
            }
        } finally {
            characters?.fill('\u0000')
        }
    }

    fun cancelPending(id: String? = null) {
        synchronized(lock) {
            val current = pending ?: return
            if (id != null && current.prompt.id != id) return
            current.answer?.fill('\u0000')
            current.answer = null
            current.signal.complete(Unit)
            pending = null
            promptState.value = null
        }
    }
}
