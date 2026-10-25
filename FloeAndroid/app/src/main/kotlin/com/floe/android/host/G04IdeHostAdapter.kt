// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.ide.api.*
import java.util.Locale
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Presentation adapter only: native workspace sessions own text, history,
 * revisions, files and recovery. This FIFO orders one owner's UI requests;
 * view attachment never creates a Run, workspace or editor database.
 */
internal class G04IdeHostAdapter(
    private val runtimeHost: RuntimeHost,
    private val client: G04WorkspaceBridgeClient,
    override val bindingGeneration: Long,
    private val isCurrentOwner: () -> Boolean,
    private val errorText: (String) -> String,
    private val extras: Extras = Extras(),
) : IdeHost {
    override val taskId: String get() = client.taskID
    override val workspaceId: String get() = client.workspaceID
    private val owner = IdeOwnerScope(taskId, workspaceId, bindingGeneration)
    private val closed = AtomicBoolean(false)
    private val receivers = CopyOnWriteArraySet<IdeReceiver>()
    private val queue = Channel<Pending>(64)
    private val pendingOperations = java.util.concurrent.atomic.AtomicInteger()
    fun isIdle(): Boolean = pendingOperations.get() == 0
    private val documents = LinkedHashMap<String, Loaded>()
    private val tabHeaders = LinkedHashMap<String, Header>()
    private val closedPaths = LinkedHashMap<String, String>()
    private val reviewedSourceSHA = HashMap<String, String>()
    private var activeID: String? = null
    private var sequence = 0L

    private val languages = G04IdeLanguageBinding(runtimeHost, client, ::live,
        publishDiagnostics = { event -> enqueue(null, null) {
            val value = documents[event.documentID] ?: return@enqueue
            if (event.revision != value.header.revision.opaque || event.relativePath != value.header.path) return@enqueue
            val diagnostics = event.items.mapIndexedNotNull { index, item ->
                val start = G04IdeLanguageBinding.offset(value.text, item.startLine, item.startCharacter) ?: return@mapIndexedNotNull null
                val end = G04IdeLanguageBinding.offset(value.text, item.endLine, item.endCharacter) ?: return@mapIndexedNotNull null
                if (end < start) return@mapIndexedNotNull null
                IdeDiagnostic(index.toLong(), IdeUtf16Range(start, end), when (item.severity) {
                    1 -> IdeDiagnosticSeverity.ERROR; 2 -> IdeDiagnosticSeverity.WARNING
                    4 -> IdeDiagnosticSeverity.HINT; else -> IdeDiagnosticSeverity.INFO
                }, item.message, item.source)
            }
            receivers.forEach { it.onDiagnostics(IdeDiagnosticSnapshot(key(value.header.id), value.header.revision, diagnostics)) }
        } },
        publishCompletion = { answer -> enqueue(null, answer.documentKey) {
            if (documents[answer.documentKey.documentId]?.header?.revision == answer.revision)
                receivers.forEach { it.onCompletion(answer) }
        } },
        publishFailure = { command -> enqueue(null, command.documentKey) {
            reply(command.requestId, command.documentKey, IdeReplyOutcome.Failed(IdeErrorCode.UNSUPPORTED, errorText("languageServerUnavailable")))
        } })

    data class Extras(
        val run: (suspend (String, String) -> Unit)? = null,
        val preview: (suspend (String, String) -> Unit)? = null,
        val completion: (suspend (IdeCommandRequest.RequestCompletion, NativeRevision) -> IdeCompletionSnapshot?)? = null,
        val terminalAvailable: Boolean = false,
    )
    private data class Pending(
        val id: String?, val key: IdeDocumentKey?, val body: suspend () -> Unit,
    )
    private data class Header(
        val id: String, val path: String, val revision: NativeRevision, val bytes: Int,
        val selection: IdeTextSelection, val dirty: Boolean, val undo: Boolean, val redo: Boolean,
    )
    private data class Loaded(val header: Header, val text: String, val generation: Long)

    private val pump = runtimeHost.scope.launch(runtimeHost.ioDispatcher) {
        for (pending in queue) {
            try { if (live()) pending.body() }
            catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException) throw error
                val code = (error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError"
                if (code == "staleRevision" && pending.key != null && live()) {
                    val fresh = try { reload(pending.key.documentId) }
                        catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
                        catch (_: Exception) { null }
                    if (fresh != null) {
                        reply(pending.id, pending.key, IdeReplyOutcome.StaleRevision(snapshot(fresh)))
                        continue
                    }
                }
                reply(pending.id, pending.key, IdeReplyOutcome.Failed(errorCode(code), errorText(code)))
            } finally { pendingOperations.decrementAndGet() }
        }
    }

    private fun live() = !closed.get() && isCurrentOwner()
    private fun owns(scope: IdeOwnerScope) = scope == owner
    private fun owns(key: IdeDocumentKey) = key.taskId == taskId && key.workspaceId == workspaceId
    private fun key(id: String) = IdeDocumentKey(taskId, workspaceId, id)
    private fun enqueue(id: String?, key: IdeDocumentKey?, action: suspend () -> Unit) {
        if (!live() || key?.let { !owns(it) } == true) return
        pendingOperations.incrementAndGet()
        if (queue.trySend(Pending(id, key, action)).isFailure) {
            pendingOperations.decrementAndGet()
            reply(id, key, IdeReplyOutcome.Failed(IdeErrorCode.HOST_UNAVAILABLE, errorText("bufferLimit")))
        }
    }
    private fun reply(id: String?, key: IdeDocumentKey?, outcome: IdeReplyOutcome) {
        if (!live()) return
        val value = IdeCommandReply(id, owner, key, outcome)
        receivers.forEach { it.onCommandReply(value) }
    }
    private fun executed(command: IdeCommandRequest, payload: IdeCommandPayload) =
        reply(command.requestId, command.documentKey, IdeReplyOutcome.Executed(payload))

    override fun attach(receiver: IdeReceiver): () -> Unit {
        if (!live()) return { }
        receivers.add(receiver)
        enqueue(null, null) {
            refreshTabs()
            activeID?.let { id ->
                val value = reload(id)
                if (live()) receiver.onDocumentSnapshot(snapshot(value))
            }
        }
        return { receivers.remove(receiver) }
    }

    override fun submitEdit(transaction: IdeEditTransaction) {
        if (!owns(transaction.owner) || !owns(transaction.documentKey)) return
        enqueue(transaction.transactionId, transaction.documentKey) {
            val previous = loaded(transaction.documentKey.documentId)
            if (previous.header.revision != transaction.expectedRevision || previous.generation != transaction.generation) {
                reply(transaction.transactionId, transaction.documentKey,
                    IdeReplyOutcome.StaleRevision(snapshot(reload(previous.header.id))))
                return@enqueue
            }
            val start = transaction.range.startUtf16
            val end = transaction.range.endUtf16
            if (start < 0 || end < start || end > previous.text.length) throw G04WorkspaceBridgeClient.Failure("invalidRange")
            val header = if (transaction.replacement.toByteArray(Charsets.UTF_8).size > 8 * 1024) {
                decodeHeader(client.uploadEdit(previous.header.id, previous.header.revision.opaque,
                    start, end - start, transaction.replacement))
            } else {
                decodeHeader(client.request("edit", buildJsonObject {
                    put("documentID", previous.header.id); put("revision", transaction.expectedRevision.opaque)
                    put("location", start); put("length", end - start); put("replacement", transaction.replacement)
                }))
            }
            // Projection of the EXACT acknowledged edit, never speculative
            // durable truth. Unexpected length forces authoritative reload.
            val text = previous.text.replaceRange(start, end, transaction.replacement)
            if (text.toByteArray(Charsets.UTF_8).size != header.bytes) {
                reply(transaction.transactionId, transaction.documentKey,
                    IdeReplyOutcome.StaleRevision(snapshot(reload(header.id))))
                return@enqueue
            }
            val acknowledged = Loaded(header, text, previous.generation)
            cache(acknowledged)
            reply(transaction.transactionId, transaction.documentKey,
                IdeReplyOutcome.Acknowledged(header.revision, snapshot(acknowledged).capabilities))
            publishTabs()
        }
    }

    /** Refresh after a user file operation through the same native workspace. */
    fun refreshWorkspace() = enqueue(null, null) {
        refreshTabs()
        activeID?.let { id ->
            val fresh = reload(id)
            if (live()) receivers.forEach { it.onDocumentSnapshot(snapshot(fresh)) }
        }
    }

    override fun sendCommand(command: IdeCommandRequest) {
        if (!owns(command.owner) || command.documentKey?.let { !owns(it) } == true) return
        enqueue(command.requestId, command.documentKey) { process(command) }
    }

    private suspend fun process(command: IdeCommandRequest) {
        when (command) {
            is IdeCommandRequest.OpenFile -> {
                val value = open(command.relativePath); activeID = value.header.id
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SNAPSHOT, snapshot = snapshot(value)))
                refreshTabs()
            }
            is IdeCommandRequest.ReopenDocument -> {
                val path = closedPaths[command.documentId] ?: throw G04WorkspaceBridgeClient.Failure("missingDocument")
                val value = open(path); activeID = value.header.id
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SNAPSHOT, snapshot = snapshot(value)))
                refreshTabs()
            }
            is IdeCommandRequest.Save -> {
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SAVE,
                    save = save(command.documentKey.documentId)))
                publishTabs()
            }
            is IdeCommandRequest.Undo -> mutateSnapshot(command, "undo")
            is IdeCommandRequest.Redo -> mutateSnapshot(command, "redo")
            is IdeCommandRequest.UpdateSelection -> {
                val value = loaded(command.documentKey.documentId)
                val selection = command.selection
                val h = decodeHeader(client.request("selection", withDocument(value.header) {
                    put("location", selection.startUtf16); put("length", selection.endUtf16 - selection.startUtf16)
                }))
                cache(value.copy(header = h))
                reply(command.requestId, command.documentKey, IdeReplyOutcome.Acknowledged(h.revision))
            }
            is IdeCommandRequest.Find -> {
                var value = loaded(command.documentKey.documentId)
                command.fromUtf16?.let { from ->
                    val h = decodeHeader(client.request("selection", withDocument(value.header) {
                        put("location", from); put("length", 0)
                    }))
                    value = value.copy(header = h); cache(value)
                }
                val result = client.request("find", withDocument(value.header) {
                    put("query", command.query); put("caseSensitive", command.caseSensitive)
                    put("wholeWord", command.wholeWord); put("backwards", command.backwards)
                })
                val hits = result.array("ranges").map { decodeRange(it as? JsonObject ?: malformed()) }
                (result["selection"] as? JsonObject)?.let { selected ->
                    val range = decodeRange(selected)
                    val h = decodeHeader(client.request("selection", withDocument(value.header) {
                        put("location", range.startUtf16); put("length", range.endUtf16 - range.startUtf16)
                    }))
                    cache(value.copy(header = h))
                }
                val found = IdeFindResult(command.documentKey, NativeRevision(result.string("revision")),
                    command.query, command.caseSensitive, command.wholeWord, hits)
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.FIND, find = found))
            }
            is IdeCommandRequest.Replace -> {
                val value = loaded(command.documentKey.documentId)
                if (value.header.revision != command.expectedRevision) throw G04WorkspaceBridgeClient.Failure("staleRevision")
                val result = client.request("replace", withDocument(value.header) {
                    put("query", command.query); put("replacement", command.replacement)
                    put("caseSensitive", command.caseSensitive); put("wholeWord", command.wholeWord)
                    put("all", command.scope == IdeReplaceScope.ALL)
                })
                val updated = load(decodeHeader(result.objectValue("header")))
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.REPLACE,
                    replace = IdeReplaceOutcome(result.integer("replacements"), snapshot(updated))))
                publishTabs()
            }
            is IdeCommandRequest.CloseDocument -> {
                if (command.decision == IdeCloseDecision.CANCEL) {
                    executed(command, IdeCommandPayload.none()); return
                }
                if (command.decision == IdeCloseDecision.SAVE) {
                    val saved = save(command.documentId)
                    if (saved.conflict != null) {
                        executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SAVE, save = saved)); return
                    }
                }
                closeDocument(command.documentId, discard = command.decision == IdeCloseDecision.DISCARD)
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.CLOSED, closedDocumentId = command.documentId))
                refreshTabs()
            }
            is IdeCommandRequest.ResolveConflict -> resolve(command)
            is IdeCommandRequest.ExpandTree -> {
                val rows = ArrayList<IdeFileRow>()
                var cursor: String? = null
                val seen = HashSet<String>()
                do {
                    val page = client.request("list", buildJsonObject {
                        put("path", command.parentRelativePath ?: ".")
                        cursor?.let { put("pageToken", it) }
                    })
                    for (element in page.array("entries")) {
                        val row = element as? JsonObject ?: malformed()
                        rows += IdeFileRow(row.string("relativePath"), row.string("name"), row.flag("isDirectory"), row.long("size"))
                    }
                    if (rows.size > 20_000) throw G04WorkspaceBridgeClient.Failure("bufferLimit")
                    cursor = page.optionalString("nextPageToken")
                    if (cursor != null && !seen.add(cursor!!)) throw G04WorkspaceBridgeClient.Failure("invalidQueryReply")
                } while (cursor != null)
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.TREE_CHILDREN,
                    treeChildren = IdeTreeChildrenEvent(owner, command.parentRelativePath, command.requestGeneration, rows)))
            }
            is IdeCommandRequest.RequestWorkspaceSearch -> {
                val result = client.request("search", buildJsonObject { put("query", command.query); put("path", ".") })
                val hits = result.array("hits").map { element ->
                    val hit = element as? JsonObject ?: malformed()
                    IdeSearchHit(hit.string("relativePath"), lineNumber = hit.integer("lineNumber"), context = hit.string("context"))
                }
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.WORKSPACE_SEARCH,
                    search = IdeWorkspaceSearchResult(owner, command.query, command.queryGeneration, hits)))
            }
            is IdeCommandRequest.LoadDiff -> {
                val value = loaded(command.documentKey.documentId)
                val text = client.readContent(value.header.id, value.header.revision.opaque, "diff")
                executed(command, IdeCommandPayload(IdeCommandPayload.Kind.DIFF,
                    diff = IdeDocumentDiffPayload(command.documentKey, value.header.revision, text)))
            }
            is IdeCommandRequest.Run -> {
                val value = loaded(command.documentKey.documentId)
                val saved = save(value.header.id)
                if (saved.conflict != null) {
                    executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SAVE, save = saved)); return
                }
                val run = extras.run
                if (run != null) run(value.header.id, value.header.path) else {
                    val controller = runtimeHost.workspaceTerminal ?: throw G04WorkspaceBridgeClient.Failure("backendUnavailable")
                    val type = language(value.header.path) ?: throw G04WorkspaceBridgeClient.Failure("unsupportedContent")
                    when (val answer = controller.runDraft(taskId, workspaceId, value.header.path, type)) {
                        is TerminalActionReply.Success -> Unit
                        is TerminalActionReply.Refused -> throw G04WorkspaceBridgeClient.Failure(
                            // The occupied single engine slot is its own
                            // honest condition (typed pre-dispatch refusal):
                            // say "runtime busy", never a generic
                            // "backend unavailable" that hides the remedy.
                            if (answer.code == "notStarted" && answer.reason == "engineSlotBusy") "runtimeBusy"
                            else "backendUnavailable")
                        TerminalActionReply.TimedOut -> throw G04WorkspaceBridgeClient.Failure("operationPending")
                    }
                }
                executed(command, IdeCommandPayload.none())
            }
            is IdeCommandRequest.OpenPreview -> {
                val preview = extras.preview ?: throw G04WorkspaceBridgeClient.Failure("backendUnavailable")
                val value = loaded(command.documentKey.documentId)
                val saved = save(value.header.id)
                if (saved.conflict != null) {
                    executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SAVE, save = saved)); return
                }
                preview(value.header.id, value.header.path); executed(command, IdeCommandPayload.none())
            }
            is IdeCommandRequest.RequestCompletion -> {
                val value = loaded(command.documentKey.documentId)
                val complete = extras.completion
                if (complete != null) {
                    val answer = complete(command, value.header.revision)
                    if (answer != null && live() && answer.requestId == command.requestId && answer.documentKey == command.documentKey &&
                        documents[value.header.id]?.header?.revision == answer.revision) receivers.forEach { it.onCompletion(answer) }
                } else languages.requestCompletion(command, value.header.revision, value.header.path, value.text, language(value.header.path))
                executed(command, IdeCommandPayload.none())
            }
            is IdeCommandRequest.RequestContentFragment -> throw G04WorkspaceBridgeClient.Failure("invalidTransfer")
        }
    }

    private suspend fun mutateSnapshot(command: IdeCommandRequest, operation: String) {
        val value = loaded(command.documentKey?.documentId ?: throw G04WorkspaceBridgeClient.Failure("missingDocument"))
        val result = load(decodeHeader(client.request(operation, withDocument(value.header))))
        executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SNAPSHOT, snapshot = snapshot(result)))
        publishTabs()
    }
    private suspend fun save(id: String): IdeSaveOutcome {
        val previous = loaded(id)
        val result = client.request("save", withDocument(previous.header))
        val h = decodeHeader(result.objectValue("header"))
        cache(previous.copy(header = h))
        return when (result.string("state")) {
            "saved" -> { reviewedSourceSHA.remove(id); IdeSaveOutcome(h.revision) }
            "conflict" -> {
                val c = result.objectValue("conflict")
                reviewedSourceSHA[id] = c.string("currentSHA256")
                val base = if (c.flag("basePresent")) client.readContent(id, h.revision.opaque, "conflictBase") else null
                val draft = client.readContent(id, h.revision.opaque)
                val remote = client.readContent(id, h.revision.opaque, "conflictCurrent")
                cache(previous.copy(header = h, text = draft))
                IdeSaveOutcome(h.revision, IdeConflictPayload(key(id), base, draft, remote,
                    NativeRevision(c.string("currentSHA256"))))
            }
            else -> malformed()
        }
    }
    private suspend fun resolve(command: IdeCommandRequest.ResolveConflict) {
        var value = loaded(command.documentKey.documentId)
        if (command.choice == IdeConflictChoice.USE_REMOTE) {
            val path = value.header.path
            closeDocument(value.header.id, discard = true)
            val fresh = open(path); activeID = fresh.header.id
            executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SNAPSHOT, snapshot = snapshot(fresh)))
            refreshTabs(); return
        }
        if (command.chosenText != value.text) {
            val h = decodeHeader(client.uploadEdit(value.header.id, value.header.revision.opaque,
                0, value.text.length, command.chosenText))
            value = Loaded(h, command.chosenText, value.generation); cache(value)
        }
        if (command.choice == IdeConflictChoice.KEEP_BOTH) {
            val result = client.forkDraft(value.header.id, value.header.revision.opaque, discardAfterCopy = false)
            val copy = result.objectValue("copy")
            val copiedHeader = result["copyHeader"] as? JsonObject
            val copied = if (copiedHeader != null) load(decodeHeader(copiedHeader)) else open(copy.string("relativePath"))
            // Verified native copy AND complete body read precede old-tab
            // disposal. Failure leaves the draft and both disk copies safe.
            closeDocument(value.header.id, discard = true)
            activeID = copied.header.id
            executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SNAPSHOT, snapshot = snapshot(copied)))
        } else {
            val reviewed = reviewedSourceSHA[value.header.id] ?: throw G04WorkspaceBridgeClient.Failure("staleRevision")
            val h = decodeHeader(client.request("resolveConflictUsingDraft", withDocument(value.header) {
                put("reviewedSHA256", reviewed)
            }))
            val result = load(h); reviewedSourceSHA.remove(h.id)
            executed(command, IdeCommandPayload(IdeCommandPayload.Kind.SNAPSHOT, snapshot = snapshot(result)))
        }
        refreshTabs()
    }

    private suspend fun open(path: String): Loaded = load(decodeHeader(
        client.request("open", buildJsonObject { put("path", path) })))
    private suspend fun load(header: Header): Loaded {
        val text = client.readContent(header.id, header.revision.opaque)
        if (text.toByteArray(Charsets.UTF_8).size != header.bytes) throw G04WorkspaceBridgeClient.Failure("contentDigestMismatch")
        val existing = documents[header.id]
        val generation = existing?.takeIf { it.header.revision == header.revision }?.generation ?: ++sequence
        val value = Loaded(header, text, generation)
        cache(value)
        return value
    }
    private fun cache(value: Loaded) {
        documents[value.header.id] = value
        tabHeaders[value.header.id] = value.header
        languages.changed(value.header.id, value.header.path, value.header.revision, value.text, language(value.header.path))
    }
    private suspend fun loaded(id: String): Loaded {
        val value = documents[id]
        val latest = tabHeaders[id]
        return if (value != null && (latest == null || latest.revision == value.header.revision)) value else reload(id)
    }
    private suspend fun reload(id: String): Loaded {
        val result = client.request("tabs")
        val header = result.array("documents").map { decodeHeader(it as? JsonObject ?: malformed()) }.firstOrNull { it.id == id }
            ?: throw G04WorkspaceBridgeClient.Failure("missingDocument")
        return load(header)
    }
    private suspend fun closeDocument(id: String, discard: Boolean) {
        val value = loaded(id)
        val result = client.request("close", withDocument(value.header) { put("discardDraft", discard) })
        if (!result.flag("closed") || result.string("documentID") != id) malformed()
        documents.remove(id); tabHeaders.remove(id); reviewedSourceSHA.remove(id); closedPaths[id] = value.header.path
        languages.removed(id)
        while (closedPaths.size > 32) closedPaths.remove(closedPaths.keys.first())
        if (activeID == id) activeID = tabHeaders.keys.firstOrNull()
    }
    private suspend fun refreshTabs() {
        val result = client.request("tabs")
        val headers = result.array("documents").map { decodeHeader(it as? JsonObject ?: malformed()) }
        val alive = headers.map { it.id }.toSet()
        documents.keys.filter { it !in alive }.forEach { languages.removed(it) }
        documents.keys.retainAll(alive)
        tabHeaders.clear()
        for (h in headers) {
            tabHeaders[h.id] = h
            val existing = documents[h.id]
            // A newer native revision does not describe the old cached body.
            // Keep that body under its old revision until the complete content
            // is read. The next request reloads it before using its ranges.
            if (existing != null && existing.header.revision == h.revision) {
                documents[h.id] = existing.copy(header = h)
            }
        }
        if (activeID !in alive) activeID = headers.firstOrNull()?.id
        val descriptors = headers.map { descriptor(it) }
        if (live()) receivers.forEach { it.onTabs(IdeTabsSnapshot(owner, activeID, descriptors, ++sequence)) }
    }
    private fun publishTabs() {
        if (!live()) return
        val tabs = tabHeaders.values.map { descriptor(it) }
        receivers.forEach { it.onTabs(IdeTabsSnapshot(owner, activeID, tabs, ++sequence)) }
    }
    private fun descriptor(h: Header) = IdeTabDescriptor(h.id, h.path, h.path.substringAfterLast('/'),
        languageId = language(h.path), dirty = h.dirty)
    private fun snapshot(value: Loaded): IdeDocumentSnapshot {
        val h = value.header
        val localReady = runtimeHost.workspaceTerminal?.availability()?.let { it.bound && it.qualified && it.workspaceAttached } == true
        val type = language(h.path)
        // Actual completion availability is DYNAMIC over the real controller:
        // a KNOWN-disabled language (persisted user choice mirrored from the
        // durable native answer) advertises no completion. Unknown durable
        // state never blocks — native remains the admission authority.
        val lspReady = type != null && type in LSP_LANGUAGES &&
            runtimeHost.workspaceTerminal?.isLanguageEnabled(type) != false
        return IdeDocumentSnapshot(key(h.id), h.revision, value.generation, value.text,
            h.path.substringAfterLast('/'), h.path, language(h.path), h.bytes.toLong(),
            capabilities = IdeDocumentCapabilities(undo = h.undo, redo = h.redo, save = true,
                find = true, replace = true, diff = true, run = extras.run != null || (localReady && type in RUN_LANGUAGES),
                openPreview = extras.preview != null, terminal = extras.terminalAvailable || localReady,
                completion = extras.completion != null || (localReady && lspReady)),
            selection = h.selection, caretUtf16 = h.selection.endUtf16)
    }
    private fun withDocument(h: Header, block: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {}) = buildJsonObject {
        put("documentID", h.id); put("revision", h.revision.opaque); block()
    }
    private fun decodeHeader(value: JsonObject): Header {
        val selection = value.objectValue("selection")
        val start = selection.integer("location"); val length = selection.integer("length")
        if (start < 0 || length < 0 || start > G04WorkspaceBridgeClient.MAX_DOCUMENT_BYTES - length) malformed()
        val bytes = value.integer("utf8Bytes")
        if (bytes !in 0..G04WorkspaceBridgeClient.MAX_DOCUMENT_BYTES) malformed()
        return Header(value.string("documentID"), value.string("relativePath"), NativeRevision(value.string("revision")),
            bytes, IdeTextSelection(start, start + length), value.flag("dirty"), value.flag("canUndo"), value.flag("canRedo"))
    }
    private fun decodeRange(value: JsonObject): IdeUtf16Range {
        val start = value.integer("location"); val length = value.integer("length")
        if (start < 0 || length < 0 || start > G04WorkspaceBridgeClient.MAX_DOCUMENT_BYTES - length) malformed()
        return IdeUtf16Range(start, start + length)
    }
    private fun language(path: String): String? = when (path.substringAfterLast('.', "").lowercase(Locale.ROOT)) {
        "kt", "kts" -> "kotlin"; "java" -> "java"; "swift" -> "swift"; "py" -> "python"
        "js", "jsx" -> "javascript"; "ts", "tsx" -> "typescript"; "html", "htm" -> "html"
        "css" -> "css"; "json" -> "json"; "xml", "svg" -> "xml"; "sh", "bash" -> "shell"
        "md" -> "markdown"; "c", "h" -> "c"; "cpp", "hpp", "cc" -> "cpp"
        "yaml", "yml" -> "yaml"; "toml" -> "toml"; else -> null
    }
    private fun errorCode(code: String): IdeErrorCode = when (code) {
        "staleRevision" -> IdeErrorCode.STALE_REVISION
        "conflict", "dirtyDocument" -> IdeErrorCode.CONFLICT
        "missingDocument", "notFound" -> IdeErrorCode.NOT_FOUND
        "secretFile", "escapesRoot", "notAdmitted", "purposeNotOrdinary" -> IdeErrorCode.POLICY
        "backendUnavailable", "unsupportedContent" -> IdeErrorCode.UNSUPPORTED
        "retired", "ownerChanged", "epochMismatch", "ownerUnavailable", "workspaceUnbound" -> IdeErrorCode.HOST_UNAVAILABLE
        else -> IdeErrorCode.IO
    }
    private fun malformed(): Nothing = throw G04WorkspaceBridgeClient.Failure("invalidReply")
    private fun JsonObject.objectValue(name: String): JsonObject = this[name] as? JsonObject ?: malformed()
    private fun JsonObject.array(name: String): JsonArray = this[name] as? JsonArray ?: malformed()
    private fun JsonObject.string(name: String): String = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: malformed()
    private fun JsonObject.optionalString(name: String): String? = when (this[name]) {
        null, JsonNull -> null
        else -> string(name)
    }
    private fun JsonObject.integer(name: String): Int = (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: malformed()
    private fun JsonObject.long(name: String): Long = (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: malformed()
    private fun JsonObject.flag(name: String): Boolean = (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: malformed()

    private val RUN_LANGUAGES = setOf("python", "javascript", "typescript", "shell", "c", "cpp")
    private val LSP_LANGUAGES = setOf("shell", "python", "javascript", "typescript", "json", "html", "css", "yaml")

    /** Release presentation waiters only; native drafts remain Root-owned. */
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        languages.close()
        receivers.clear(); queue.close(); pump.cancel()
    }
}
