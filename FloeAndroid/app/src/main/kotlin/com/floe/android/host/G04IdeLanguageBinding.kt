// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.ide.api.*
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Coalesced native-acknowledged document projections for the original LSP
 * service. Server startup/completion never occupies the editor's edit queue.
 * Root, document and revision checks stay in native Core on every request. */
internal class G04IdeLanguageBinding(
    private val host: RuntimeHost,
    private val client: G04WorkspaceBridgeClient,
    private val current: () -> Boolean,
    private val publishDiagnostics: (TerminalDiagnosticsSnapshot) -> Unit,
    private val publishCompletion: (IdeCompletionSnapshot) -> Unit,
    private val publishFailure: (IdeCommandRequest.RequestCompletion) -> Unit,
) {
    private data class Document(val id: String, val path: String, val language: String, val revision: NativeRevision, val text: String)
    private val closed = AtomicBoolean()
    private val pendingLock = Any()
    private val pending = LinkedHashMap<String, Document?>()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private data class Completion(val command: IdeCommandRequest.RequestCompletion, val document: Document)
    private val completionWake = Channel<Unit>(Channel.CONFLATED)
    private val pendingCompletions = LinkedHashMap<String, Completion>()
    private val sessionLock = Mutex()
    private data class Opened(val id: String, val path: String, val language: String, val revision: NativeRevision)
    private val opened = LinkedHashMap<String, Opened>()
    private val known = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val inFlight = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val readyLanguages = HashSet<String>()
    private val failedLanguages = HashSet<String>()
    private var detachDiagnostics: (() -> Unit)? = null
    private var subscribedController: G04TerminalHostController? = null
    private val pump = host.scope.launch(host.ioDispatcher) {
        for (ignored in wake) {
            while (true) {
                val next = synchronized(pendingLock) {
                    pending.entries.firstOrNull()?.let { row -> (row.key to row.value).also { pending.remove(row.key) } }
                } ?: break
                try {
                    sessionLock.withLock {
                        if (!live()) return@withLock
                        if (next.second == null) closeDocument(next.first) else synchronize(next.second!!, retry = false)
                    }
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) { /* Native service emits its typed availability; editing remains usable. */ }
            }
        }
    }

    private val completionPump = host.scope.launch(host.ioDispatcher) {
        for (ignored in completionWake) while (true) {
            val next = synchronized(pendingLock) {
                pendingCompletions.entries.firstOrNull()?.let { row -> row.value.also { pendingCompletions.remove(row.key) } }
            } ?: break
            completePending(next)
        }
    }

    fun changed(id: String, path: String, revision: NativeRevision, text: String, language: String?) {
        if (!live() || language !in LANGUAGES) return
        val value = Document(id, path, language!!, revision, text)
        synchronized(pendingLock) {
            // The native session admits 32 open documents / 16 MiB total
            // (4 MiB per document) — the queue is keyed per document, so the
            // cap covers every tab the authority can hold. An already-queued
            // document is ALWAYS replaced with its latest ACK (coalescing);
            // only a brand-new document beyond capacity is dropped here,
            // and its next edit/change re-enters (close events for it stay
            // admitted because its row already exists or it was never known).
            if (id !in pending && pending.size >= QUEUED_DOCUMENT_LIMIT) return
            pending[id] = value
        }
        wake.trySend(Unit)
    }

    fun removed(id: String) {
        if (!live()) return
        synchronized(pendingLock) {
            pending.remove(id)
            // A close for a known/in-flight document must never be dropped:
            // the queued-close row REPLACES a newer change row for the same
            // id even when the queue is full (the last-ACK wins rule).
            if ((id in known || id in inFlight) && (id in pending || pending.size < QUEUED_DOCUMENT_LIMIT)) {
                pending[id] = null
            }
        }
        wake.trySend(Unit)
    }

    fun requestCompletion(command: IdeCommandRequest.RequestCompletion, revision: NativeRevision,
                          path: String, text: String, language: String?) {
        if (!live() || language !in LANGUAGES) return
        val document = Document(command.documentKey.documentId, path, language!!, revision, text)
        var overflow = false
        synchronized(pendingLock) {
            if (document.id !in pendingCompletions && pendingCompletions.size >= COMPLETION_QUEUE_LIMIT) {
                overflow = true
            } else {
                pendingCompletions[document.id] = Completion(command, document)
            }
        }
        if (overflow) {
            // Bounded completion queue: an unqueued request is answered with
            // an honest immediate failure, never silently dropped (the
            // per-document latest request still coalesces at capacity).
            publishFailure(command)
            return
        }
        completionWake.trySend(Unit)
    }

    private suspend fun completePending(pending: Completion) {
        val command = pending.command; val document = pending.document
        val text = document.text; val revision = document.revision
        try {
            sessionLock.withLock {
                if (!live()) return@withLock
                if (!synchronize(document, retry = true)) { publishFailure(command); return@withLock }
                val controller = host.workspaceTerminal ?: return@withLock
                val caret = command.selection.endUtf16.coerceIn(0, text.length)
                val position = position(text, caret)
                val result = controller.completion(client.taskID, client.workspaceID, document.language,
                    document.id, revision.opaque, position.first, position.second) ?: return@withLock
                if (!live() || result.documentID != document.id || result.revision != revision.opaque) return@withLock
                publishCompletion(IdeCompletionSnapshot(command.documentKey, command.requestId, revision, command.selection,
                    result.items.map { item -> IdeCompletionItem(item.label, item.insertText, item.detail, when (item.kind) {
                        2 -> IdeCompletionItemKind.METHOD; 3 -> IdeCompletionItemKind.FUNCTION
                        5 -> IdeCompletionItemKind.FIELD; 6 -> IdeCompletionItemKind.VARIABLE
                        7 -> IdeCompletionItemKind.CLASS; 14 -> IdeCompletionItemKind.KEYWORD
                        15 -> IdeCompletionItemKind.SNIPPET; else -> IdeCompletionItemKind.TEXT
                    }) }))
            }
        } catch (error: CancellationException) { throw error }
        catch (_: Exception) { /* No stale/local substitute completion. */ }
    }

    private fun live() = !closed.get() && current()
    private fun controller(): G04TerminalHostController? {
        val controller = host.workspaceTerminal ?: return null
        synchronized(pendingLock) {
            if (!live()) return null
            if (subscribedController !== controller) {
                detachDiagnostics?.invoke()
                detachDiagnostics = controller.addDiagnosticsListener { event ->
                    if (live() && event.conversationID.equals(client.taskID, ignoreCase = true) &&
                        event.workspaceID.equals(client.workspaceID, ignoreCase = true)) publishDiagnostics(event)
                }
                subscribedController = controller
            }
            return controller
        }
    }

    private suspend fun synchronize(document: Document, retry: Boolean): Boolean {
        if (!live()) return false
        val controller = controller() ?: return false
        if (!controller.availability().let { it.bound && it.qualified && it.workspaceAttached }) {
            controller.refreshCapabilities()
            if (!controller.availability().let { it.bound && it.qualified && it.workspaceAttached }) return false
        }
        if (document.language !in readyLanguages) {
            if (!retry && document.language in failedLanguages) return false
            if (controller.ensureLanguageServer(client.taskID, client.workspaceID, document.language) !is TerminalActionReply.Success) {
                failedLanguages.add(document.language); return false
            }
            readyLanguages.add(document.language); failedLanguages.remove(document.language)
        }
        val old = opened[document.id]
        if (old != null && old.revision == document.revision && old.path == document.path) return true
        if (old != null && (old.path != document.path || old.language != document.language)) closeDocument(old.id)
        inFlight.add(document.id)
        try {
            val answer = if (document.id in opened)
                controller.lspChangeDocument(client.taskID, client.workspaceID, document.language,
                    document.id, document.revision.opaque, document.text)
            else controller.lspOpenDocument(client.taskID, client.workspaceID, document.language,
                document.id, document.revision.opaque, document.text)
            if (answer !is TerminalActionReply.Success || !live()) return false
            opened[document.id] = Opened(document.id, document.path, document.language, document.revision)
            known.add(document.id)
            return true
        } finally { inFlight.remove(document.id) }
    }

    private suspend fun closeDocument(id: String) {
        val old = opened.remove(id) ?: return
        known.remove(id)
        host.workspaceTerminal?.lspCloseDocument(client.taskID, client.workspaceID, old.language, old.id)
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        wake.close(); completionWake.close(); pump.cancel(); completionPump.cancel()
        val detach = synchronized(pendingLock) {
            pending.clear(); pendingCompletions.clear()
            detachDiagnostics.also { detachDiagnostics = null; subscribedController = null }
        }
        detach?.invoke()
        host.scope.launch(host.ioDispatcher) {
            sessionLock.withLock {
                // A detached editor must still settle its NATIVE document
                // ownership: task switches and dismissal issue real didClose
                // for every synced document so the center's last-document
                // rule can explicitly release the conversation's servers
                // (no idle orphan holding the shared Linux session budget
                // after the task was visited). The request is only made
                // while the mailbox is still BOUND; a retired generation is
                // settled by the native fence + retireAll, never by a
                // fabricated local close and never claimed as proven stop.
                val controller = host.workspaceTerminal
                if (controller != null && controller.boundNativeEpoch != 0L) {
                    opened.keys.toList().forEach { closeDocument(it) }
                }
                opened.clear(); known.clear(); inFlight.clear(); readyLanguages.clear(); failedLanguages.clear()
            }
        }
    }

    companion object {
        private val LANGUAGES = setOf("shell", "python", "javascript", "typescript", "json", "html", "css", "yaml")
        /** REAL native capacity (G04WorkspaceDocumentSession): 32 open
         * documents / 16 MiB body total / 4 MiB per document. The old "at
         * most eight" note was an incorrect assumption (8 is the Facade
         * workspace-SESSION cap, not a per-workspace document count). */
        private const val QUEUED_DOCUMENT_LIMIT = 32
        /** Bounded completion coalescing cap (latest request per document). */
        private const val COMPLETION_QUEUE_LIMIT = 8
        /** LSP positions count UTF-16; CRLF is one line break. */
        internal fun position(text: String, offset: Int): Pair<Int, Int> {
            var line = 0; var column = 0; var index = 0
            while (index < offset.coerceIn(0, text.length)) {
                when (text[index]) {
                    '\r' -> { line++; column = 0; if (index + 1 < offset && text.getOrNull(index + 1) == '\n') index++ }
                    '\n' -> { line++; column = 0 }
                    else -> column++
                }
                index++
            }
            return line to column
        }
        internal fun offset(text: String, line: Int, column: Int): Int? {
            if (line < 0 || column < 0) return null
            var index = 0; var currentLine = 0
            while (index < text.length && currentLine < line) {
                when (text[index++]) {
                    '\r' -> { if (text.getOrNull(index) == '\n') index++; currentLine++ }
                    '\n' -> currentLine++
                }
            }
            if (currentLine != line) return null
            val start = index
            while (index < text.length && text[index] != '\r' && text[index] != '\n') index++
            return (start + column).takeIf { column <= index - start }
        }
    }
}
