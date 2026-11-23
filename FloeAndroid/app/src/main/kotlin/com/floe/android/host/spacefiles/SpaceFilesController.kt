// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.safgateway.MoveMode
import com.floe.android.safgateway.PageRequest
import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PreparedState
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOperation
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafSize
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.SavePolicy
import com.floe.android.safgateway.SaveReceipt
import com.floe.android.safgateway.StagedCopy
import com.floe.android.safgateway.StagedLocalRef
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Space → Files controller: the detached, testable data layer behind
 * `com.floe.android.SpaceFilesDestination`.
 *
 * Ownership boundaries:
 *  - It owns NO task, project, workspace or meeting identity. Rows come from
 *    the exact provider tree the user authorized; there is no fabricated owner.
 *  - Provider IO and grants run through the REAL `SafGatewayService`
 *    (`AndroidSafBackend` in the App). This class never touches a path, never
 *    calls `ContentResolver` and never releases a persisted grant: forgetting a
 *    saved root removes local metadata only, so a grant another feature still
 *    uses is untouched.
 *  - One provider mutation at a time (`busy`). Paging/preview are separate so a
 *    slow folder scan can never interleave a write.
 *  - Browsing/preview jobs are generation-fenced: a late page for a folder the
 *    user already left is discarded (and its held cursor given back), never
 *    appended to the new folder.
 *  - Mutations are launched in the CONTROLLER's scope, not a composition
 *    scope. Recreating or leaving the screen cannot abandon an in-flight
 *    provider write or drop its receipt; operations are awaited to real
 *    settlement (`SafOperation.await`, `NonCancellable`).
 */
internal class SpaceFilesController(
    private val service: SafGatewayService,
    private val backend: SafPlatformBackend,
    private val store: SpaceFilesRootStore,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** App cache root for bounded preview staging and relay-copy scratch. */
    cacheRoot: File,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Stable per-controller-generation picker identity (never user data). */
    val launchNamespace: String = PlatformLaunchOwnership.mintNamespace(),
    /**
     * App-private durable root for native-edit working copies + recovery
     * (filesDir in the App; tests may leave it null to stage under cache).
     * Provider bytes are never written here — only verified working copies.
     */
    editsRoot: File? = null,
) {
    private val _state = MutableStateFlow(SpaceFilesUiState())
    val state: StateFlow<SpaceFilesUiState> = _state

    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val browseGeneration = AtomicLong(0)
    private val transferGeneration = AtomicLong(0)
    private val previewGeneration = AtomicLong(0)
    private val pickIncarnation = AtomicLong(0)
    private val openIncarnation = AtomicLong(0)
    private val editIncarnation = AtomicLong(0)
    private val pageSize = 200

    /** One in-flight "load more" per listing; two overlapping requests would
     *  otherwise append the same provider page twice. */
    private val browseMoreInFlight = AtomicBoolean(false)
    private val transferMoreInFlight = AtomicBoolean(false)

    private val stagingRoot: File = cacheRoot.apply { runCatching { mkdirs() } }
    private val previewDir = File(stagingRoot, "previews")
    private val relayDir = File(stagingRoot, "relay")

    // ------------------------------------------------------------------
    // Native edit sessions (durable working copies + verified save-back)
    // ------------------------------------------------------------------

    private val durableEditsRoot: File = (editsRoot ?: File(stagingRoot, "edits"))
        .apply { runCatching { mkdirs() } }
    private val editWorkingRoot = File(durableEditsRoot, "working")
    private val editRecoveryRoot = File(durableEditsRoot, "recovery")

    /** Crash-safe session rows; also the App-owned commit coordinator that
     *  persists recovery receipts before permitting a destructive write. */
    private val editJournal: SpaceFilesEditJournal? = runCatching {
        SpaceFilesEditJournal(File(durableEditsRoot, "journal")) { sessionId, fileName ->
            File(editWorkingRoot, sessionId).apply { runCatching { mkdirs() } }.let { File(it, fileName) }
        }
    }.getOrNull()

    /** Session registry: one row per provider document, keyed by session id. */
    private val editSessions = LinkedHashMap<String, SpaceFilesEditSession>()
    private val editLock = Mutex()

    /** Working-copy change watchers + debounced reconciles. */
    private val editObservers = ConcurrentHashMap<String, android.os.FileObserver>()
    private val editDebounce = ConcurrentHashMap<String, Job>()

    private val entryOrder: Comparator<SpaceFileEntry> =
        compareBy<SpaceFileEntry>({ !it.isDirectory }, { it.name.lowercase(Locale.ROOT) })

    // ------------------------------------------------------------------
    // Lifecycle (view attach/detach is NOT controller shutdown)
    // ------------------------------------------------------------------

    /** First mount loads the saved roots and reopens the first usable one. */
    fun start() {
        if (closed.get()) return
        launchOwned {
            if (started.compareAndSet(false, true)) {
                refreshCatalogInternal(openFirstUsable = true)
            } else {
                refreshCatalogInternal(openFirstUsable = false)
                reloadBrowseInternal()
            }
            restoreEditSessionsInternal()
        }
    }

    /** Activity resumed: re-probe OS grants before trusting any saved root. */
    fun revalidate() {
        // The first mount's start() already performs this read; avoid a
        // duplicate catalog load when ON_RESUME arrives alongside it.
        if (closed.get() || !started.get()) return
        launchOwned {
            refreshCatalogInternal(openFirstUsable = false)
            reloadBrowseInternal()
            reconcileActiveEditsInternal()
        }
    }

    /** Returning from an editor (or any resume) re-checks every live session:
     *  unchanged copies stay silent, changed ones enter the save-back ladder. */
    private suspend fun reconcileActiveEditsInternal() {
        val active = editLock.withLock {
            editSessions.values.filter { it.phase != SpaceFilesEditPhase.FINISHED }.map { it.id }
        }
        active.forEach { reconcileEditInternal(it) }
    }

    /**
     * The composition is going away. Browsing/preview work is fenced and the
     * held page cursor is given back; an in-flight MUTATION is deliberately
     * left owned by this controller so it can settle and publish its real
     * receipt. Nothing is marked succeeded here.
     */
    fun viewDetached() {
        val browse = _state.value.browse
        releaseHeldCursor(browse?.nextCursorToken)
        clearPreviewFile(_state.value.preview)
        browseGeneration.incrementAndGet()
        transferGeneration.incrementAndGet()
        previewGeneration.incrementAndGet()
        _state.update { current ->
            current.copy(
                pick = null,
                openRequest = null,
                editLaunch = null,
                preview = null,
                previewLoading = false,
                transfer = null,
                browse = current.browse?.copy(
                    nextCursorToken = null,
                    hasMore = false,
                    loading = false,
                    loadingMore = false,
                ),
            )
        }
    }

    /** Process teardown only (the App host keeps one controller for its life). */
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        editObservers.values.forEach { runCatching { it.stopWatching() } }
        editObservers.clear()
        editDebounce.values.forEach { it.cancel() }
        editDebounce.clear()
        scope.cancel()
        runCatching { service.close() }
    }

    // ------------------------------------------------------------------
    // Catalog + root access truth
    // ------------------------------------------------------------------

    fun refreshCatalog() {
        launchOwned { refreshCatalogInternal(openFirstUsable = false) }
    }

    fun openRoot(uri: SafUriRef) {
        launchOwned { openRootByUri(uri) }
    }

    fun loadMore() {
        launchOwned { loadMoreInternal() }
    }

    fun refreshBrowse() {
        launchOwned { reloadBrowseInternal(showLoading = true) }
    }

    fun enterFolder(entry: SpaceFileEntry) {
        launchOwned { enterFolderInternal(entry) }
    }

    fun goUp() {
        launchOwned { goUpInternal() }
    }

    fun removeRoot(uri: SafUriRef) {
        launchOwned { removeRootInternal(uri) }
    }

    fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    internal suspend fun refreshCatalogInternal(openFirstUsable: Boolean) {
        val stored = withContext(ioDispatcher) {
            runCatching { store.read() }.getOrDefault(emptyList())
        }
        // Sweep the gateway's own session notes against the live platform
        // probe. This never releases a grant; it only forgets expired evidence.
        withContext(ioDispatcher) { runCatching { service.grants.revalidate() } }
        val probed = stored.map { probeRoot(it) }
        val currentUri = _state.value.browse?.root?.uri
        _state.update { it.copy(catalogLoaded = true, roots = probed) }
        val current = currentUri?.let { uri -> probed.firstOrNull { it.uri == uri } }
        when {
            currentUri == null -> if (openFirstUsable) {
                probed.firstOrNull { it.usable }?.let { openRootInternal(it) }
            }
            current == null -> markRootUnusable(null)
            !current.usable -> markRootUnusable(current)
            else -> {
                _state.update { s ->
                    s.browse?.takeIf { it.root.uri == current.uri }
                        ?.let { b -> s.copy(browse = b.copy(root = current)) } ?: s
                }
                if (openFirstUsable) reloadBrowseInternal()
            }
        }
    }

    private suspend fun probeRoot(root: SpaceFilesRoot): SpaceRootUi {
        val kindOk = withContext(ioDispatcher) {
            runCatching { backend.classifyUri(root.uri.uriString) }
                .getOrDefault(SafUriKind.UNKNOWN) == SafUriKind.TREE
        }
        if (!kindOk) {
            return SpaceRootUi(root.uri, root.name, root.savedAtMillis, read = false, write = false, persisted = false)
        }
        val evidence = withContext(ioDispatcher) { runCatching { service.grants.currentAccess(root.uri) }.getOrNull() }
        return SpaceRootUi(
            uri = root.uri,
            name = root.name,
            savedAtMillis = root.savedAtMillis,
            read = evidence?.read == true,
            write = evidence?.write == true,
            persisted = evidence?.persisted == true,
        )
    }

    private fun markRootUnusable(root: SpaceRootUi?) {
        _state.update { current ->
            val browse = current.browse ?: return@update current
            if (root == null) {
                current.copy(browse = null, transfer = null)
            } else {
                current.copy(
                    browse = browse.copy(
                        root = root,
                        entries = emptyList(),
                        loading = false,
                        loadingMore = false,
                        error = SpaceFilesFailure(SpaceFilesProblem.GRANT_REVOKED),
                        hasMore = false,
                        nextCursorToken = null,
                        initialised = true,
                    ),
                )
            }
        }
    }

    internal suspend fun openRootByUri(uri: SafUriRef) {
        val known = _state.value.roots.firstOrNull { it.uri == uri }
        if (known != null) {
            openRootInternal(known)
            return
        }
        // A root that is not in the catalog cannot be opened from this page;
        // never fabricate a name or access for it.
        _state.update { it.copy(notice = SpaceFilesNotice.Failed(
            SpaceFilesOperation.LOAD, SpaceFilesFailure(SpaceFilesProblem.GRANT_MISSING))) }
    }

    internal suspend fun openRootInternal(root: SpaceRootUi, knownMeta: RootMeta? = null) {
        if (!root.usable) {
            markRootUnusable(root)
            return
        }
        val generation = browseGeneration.incrementAndGet()
        releaseHeldCursor(_state.value.browse?.nextCursorToken)
        val seedCrumb = SpaceFolderCrumb(null, root.uri, root.name, false)
        _state.update {
            it.copy(
                browse = SpaceRootBrowse(root = root, path = listOf(seedCrumb), loading = true),
                transfer = null,
                preview = null,
            )
        }
        val meta = knownMeta ?: fetchRootMeta(root.uri)
        if (generation != browseGeneration.get()) return
        val effective = if (root.name.isBlank() && !meta?.name.isNullOrBlank()) {
            root.copy(name = meta.name)
        } else {
            root
        }
        val crumb = SpaceFolderCrumb(meta?.documentId, root.uri, effective.name, meta?.canCreate == true)
        if (effective.name != root.name && effective.name.isNotBlank()) {
            _state.update { s ->
                s.copy(roots = s.roots.map { if (it.uri == root.uri) it.copy(name = effective.name) else it })
            }
        }
        _state.update { current ->
            current.browse?.takeIf { it.root.uri == root.uri }
                ?.let { b -> current.copy(browse = b.copy(root = effective, path = listOf(crumb))) }
                ?: current
        }
        loadPageInternal(generation, effective, listOf(crumb), cursor = null, append = false)
    }

    internal suspend fun reloadBrowseInternal(showLoading: Boolean = false) {
        val browse = _state.value.browse ?: return
        if (!browse.root.usable) {
            markRootUnusable(browse.root)
            return
        }
        val generation = browseGeneration.incrementAndGet()
        releaseHeldCursor(browse.nextCursorToken)
        _state.update { current ->
            current.browse?.takeIf { it.root.uri == browse.root.uri }
                ?.let { b -> current.copy(browse = b.copy(
                    loading = showLoading,
                    loadingMore = false,
                    error = null,
                    hasMore = false,
                    nextCursorToken = null,
                )) } ?: current
        }
        loadPageInternal(generation, browse.root, browse.path, cursor = null, append = false)
    }

    internal suspend fun loadMoreInternal() {
        val browse = _state.value.browse ?: return
        val token = browse.nextCursorToken ?: return
        if (browse.loading || browse.loadingMore || !browse.root.usable) return
        if (!browseMoreInFlight.compareAndSet(false, true)) return
        val generation = browseGeneration.get()
        _state.update { current ->
            current.browse?.takeIf { it.root.uri == browse.root.uri }
                ?.let { b -> current.copy(browse = b.copy(loadingMore = true)) } ?: current
        }
        try {
            loadPageInternal(generation, browse.root, browse.path, token, append = true)
        } finally {
            browseMoreInFlight.set(false)
            if (generation == browseGeneration.get() && _state.value.browse?.loadingMore == true) {
                _state.update { s -> s.browse?.let { b -> s.copy(browse = b.copy(loadingMore = false)) } ?: s }
            }
        }
    }

    internal suspend fun enterFolderInternal(entry: SpaceFileEntry) {
        if (!entry.isDirectory) return
        val browse = _state.value.browse ?: return
        if (!browse.root.usable) return
        val generation = browseGeneration.incrementAndGet()
        releaseHeldCursor(browse.nextCursorToken)
        val crumb = SpaceFolderCrumb(
            documentId = entry.documentId,
            uri = entry.uri,
            name = entry.name,
            canCreateChildren = entry.canCreateChildren,
        )
        val path = browse.path + crumb
        _state.update { current ->
            current.browse?.takeIf { it.root.uri == browse.root.uri }
                ?.let { b -> current.copy(browse = b.copy(
                    path = path,
                    entries = emptyList(),
                    loading = true,
                    loadingMore = false,
                    error = null,
                    hasMore = false,
                    nextCursorToken = null,
                    initialised = false,
                )) } ?: current
        }
        loadPageInternal(generation, browse.root, path, cursor = null, append = false)
    }

    internal suspend fun goUpInternal() {
        val browse = _state.value.browse ?: return
        if (browse.path.size <= 1) return
        val generation = browseGeneration.incrementAndGet()
        releaseHeldCursor(browse.nextCursorToken)
        val path = browse.path.dropLast(1)
        _state.update { current ->
            current.browse?.takeIf { it.root.uri == browse.root.uri }
                ?.let { b -> current.copy(browse = b.copy(
                    path = path,
                    entries = emptyList(),
                    loading = true,
                    loadingMore = false,
                    error = null,
                    hasMore = false,
                    nextCursorToken = null,
                    initialised = false,
                )) } ?: current
        }
        loadPageInternal(generation, browse.root, path, cursor = null, append = false)
    }

    internal suspend fun removeRootInternal(uri: SafUriRef) {
        val stored = withContext(ioDispatcher) { runCatching { store.read() }.getOrDefault(emptyList()) }
        val removed = stored.firstOrNull { it.uri == uri } ?: return
        val write = withContext(ioDispatcher) { runCatching { store.write(stored.filterNot { it.uri == uri }) } }
        if (write.isFailure) {
            _state.update { it.copy(notice = SpaceFilesNotice.Failed(
                SpaceFilesOperation.REMOVE_ROOT, SpaceFilesFailure(SpaceFilesProblem.IO))) }
            return
        }
        // Local metadata only. The OS grant is intentionally untouched: another
        // App component may still hold it, and the shared grant broker owns any
        // release decision. This page never releases persisted permissions.
        val browse = _state.value.browse
        if (browse?.root?.uri == uri) {
            releaseHeldCursor(browse.nextCursorToken)
            browseGeneration.incrementAndGet()
        }
        _state.update { current ->
            current.copy(
                roots = current.roots.filterNot { it.uri == uri },
                browse = if (current.browse?.root?.uri == uri) null else current.browse,
                transfer = if (current.transfer?.tree == uri) null else current.transfer,
                notice = SpaceFilesNotice.RootRemoved(removed.name),
            )
        }
    }

    // ------------------------------------------------------------------
    // Bounded listing
    // ------------------------------------------------------------------

    private suspend fun loadPageInternal(
        generation: Long,
        root: SpaceRootUi,
        path: List<SpaceFolderCrumb>,
        cursor: String?,
        append: Boolean,
    ) {
        val folder = path.lastOrNull() ?: return
        val outcome = try {
            awaitProvider { cancel ->
                service.operations.listTreePage(
                    tree = root.uri,
                    parentDocumentId = folder.documentId,
                    request = PageRequest(pageSize, cursor),
                    cancel = cancel,
                )
            }
        } catch (cancelled: CancellationException) {
            if (generation == browseGeneration.get()) {
                _state.update { current ->
                    current.browse?.takeIf { it.root.uri == root.uri }
                        ?.let { b -> current.copy(browse = b.copy(
                            loading = false,
                            loadingMore = false,
                            error = SpaceFilesFailure(SpaceFilesProblem.CANCELLED),
                            hasMore = false,
                            nextCursorToken = null,
                            initialised = true,
                        )) } ?: current
                }
            }
            throw cancelled
        }
        if (generation != browseGeneration.get()) {
            // A newer folder owns the screen: give the just-received cursor back
            // instead of leaving a held provider cursor behind.
            if (outcome is SafOutcome.Success) releaseHeldCursor(outcome.value.nextCursorToken)
            return
        }
        when (outcome) {
            is SafOutcome.Failure -> {
                val failure = outcome.failure.toSpaceFilesFailure(outcome.detail)
                _state.update { current ->
                    current.browse?.takeIf { it.root.uri == root.uri }
                        ?.let { b -> current.copy(browse = b.copy(
                            loading = false,
                            loadingMore = false,
                            error = failure,
                            entries = if (failure.blocking) emptyList() else b.entries,
                            hasMore = false,
                            nextCursorToken = null,
                            initialised = true,
                        )) } ?: current
                }
            }
            is SafOutcome.Success -> {
                val scan = outcome.value
                val restarted = cursor != null && scan.note?.contains("restarted") == true
                val rows = scan.documents.map { it.toSpaceFileEntry() }.sortedWith(entryOrder)
                _state.update { current ->
                    current.browse
                        ?.takeIf {
                            it.root.uri == root.uri &&
                                it.path.lastOrNull()?.documentId == folder.documentId
                        }
                        ?.let { b ->
                            val continueAppend = append && !restarted && b.nextCursorToken == cursor
                            current.copy(
                                browse = b.copy(
                                    loading = false,
                                    loadingMore = false,
                                    error = null,
                                    entries = if (continueAppend) b.entries + rows else rows,
                                    hasMore = scan.nextCursorToken != null,
                                    nextCursorToken = scan.nextCursorToken,
                                    initialised = true,
                                ),
                                notice = if (restarted) {
                                    SpaceFilesNotice.PageReloaded(folder.name)
                                } else {
                                    current.notice
                                },
                            )
                        } ?: current
                }
            }
        }
    }

    /** Give a held provider cursor back on the service's own IO thread. */
    private fun releaseHeldCursor(token: String?) {
        if (token.isNullOrEmpty() || service.isClosed) return
        runCatching {
            service.submit { _ ->
                service.operations.releaseCursor(token)
                SafOutcome.success(true)
            }
        }
    }

    /** Exact tree-root document identity + its own capabilities. */
    internal class RootMeta(val documentId: String?, val name: String, val canCreate: Boolean)

    private suspend fun fetchRootMeta(tree: SafUriRef): RootMeta? {
        val rootRef = awaitProvider { cancel -> service.operations.treeRoot(tree, cancel) }
        if (rootRef !is SafOutcome.Success) return null
        val meta = awaitProvider { cancel -> service.operations.metadata(rootRef.value, cancel) }
        val document = if (meta is SafOutcome.Success) meta.value else null
        return RootMeta(
            documentId = rootRef.value.documentId ?: document?.ref?.documentId,
            name = document?.displayName.orEmpty(),
            canCreate = document?.capabilities?.createChildren == true,
        )
    }

    // ------------------------------------------------------------------
    // Picker lifecycle
    // ------------------------------------------------------------------

    fun requestAddFolder() {
        val current = _state.value
        if (current.busy != null || current.pick != null) return
        val spec = runCatching { service.grants.pickerForTree() }.getOrNull()
        if (spec == null) {
            publishFailure(SpaceFilesOperation.ADD_ROOT, SpaceFilesProblem.FAILED)
            return
        }
        val incarnation = pickIncarnation.incrementAndGet()
        _state.update { it.copy(pick = SpaceRootPick(incarnation, spec), notice = null) }
    }

    fun cancelPicker(incarnation: Long) {
        val pending = _state.value.pick ?: return
        if (pending.incarnation != incarnation) return
        _state.update {
            it.copy(pick = null, notice = SpaceFilesNotice.PickCancelled("user dismissed"))
        }
    }

    /** A ledger-dropped callback owns nothing: no cancel, no state write. */
    fun dropPickerCallback() = Unit

    fun onPickerResult(incarnation: Long, uriString: String?, flags: Int) {
        if (_state.value.pick?.incarnation != incarnation) return
        launchOwned { handlePickerResultInternal(incarnation, uriString, flags) }
    }

    /**
     * Accept ONLY the explicit system result + its ACTUAL returned flags. The
     * gateway decides persistence per offered flag; a cancel never creates a
     * root, and a rejected result never becomes a saved folder.
     */
    internal suspend fun handlePickerResultInternal(incarnation: Long, uriString: String?, flags: Int) {
        val pending = _state.value.pick?.takeIf { it.incarnation == incarnation } ?: return
        _state.update { it.copy(pick = null) }
        if (uriString.isNullOrBlank()) {
            _state.update { it.copy(notice = SpaceFilesNotice.PickCancelled("null-result")) }
            return
        }
        val accepted = withContext(ioDispatcher) {
            service.grants.acceptPickResult(pending.spec, uriString, flags)
        }
        when (accepted) {
            is PickAcceptResult.Cancelled -> {
                _state.update { it.copy(notice = SpaceFilesNotice.PickCancelled(accepted.reason)) }
            }
            is PickAcceptResult.Rejected -> {
                _state.update {
                    it.copy(notice = SpaceFilesNotice.PickRejected(
                        SpaceFilesFailure(
                            SpaceFilesProblem.UNSUPPORTED,
                            "${accepted.reason}: ${accepted.detail}",
                        ),
                    ))
                }
            }
            is PickAcceptResult.Accepted -> adoptPickedTree(accepted)
        }
    }

    private suspend fun adoptPickedTree(accepted: PickAcceptResult.Accepted) {
        val meta = fetchRootMeta(accepted.uri)
        val root = SpaceFilesRoot(
            uri = accepted.uri,
            name = meta?.name.orEmpty(),
            savedAtMillis = clock(),
        )
        val stored = withContext(ioDispatcher) { runCatching { store.read() }.getOrDefault(emptyList()) }
        val updated = (stored.filterNot { it.uri == accepted.uri } + root).sortedBy { it.savedAtMillis }
        val written = withContext(ioDispatcher) { runCatching { store.write(updated) } }
        if (written.isFailure) {
            _state.update {
                it.copy(notice = SpaceFilesNotice.Failed(
                    SpaceFilesOperation.ADD_ROOT, SpaceFilesFailure(SpaceFilesProblem.IO)))
            }
            return
        }
        val probed = probeRoot(root)
        _state.update { current ->
            val roots = (current.roots.filterNot { it.uri == accepted.uri } + probed)
                .sortedBy { it.savedAtMillis }
            current.copy(
                roots = roots,
                notice = SpaceFilesNotice.RootAdded(
                    name = probed.name,
                    sessionOnly = accepted.transientOnly || !probed.persisted,
                ),
            )
        }
        openRootInternal(probed, meta)
    }

    // ------------------------------------------------------------------
    // Mutations (capability-gated, receipt-backed)
    // ------------------------------------------------------------------

    fun createFolder(name: String) {
        launchOwned { createFolderInternal(name) }
    }

    fun createFile(name: String) {
        launchOwned { createFileInternal(name) }
    }

    fun rename(entry: SpaceFileEntry, newName: String) {
        launchOwned { renameInternal(entry, newName) }
    }

    fun delete(entry: SpaceFileEntry) {
        launchOwned { deleteInternal(entry) }
    }

    internal suspend fun createFolderInternal(rawName: String): Boolean {
        val browse = _state.value.browse ?: return false
        val name = rawName.trim()
        if (!SpaceFilesNames.isSafeSegment(name)) {
            publishFailure(SpaceFilesOperation.CREATE_FOLDER, SpaceFilesProblem.INVALID_NAME)
            return false
        }
        val folder = browse.folder ?: return false
        if (folder.canCreateChildren != true) {
            publishFailure(
                SpaceFilesOperation.CREATE_FOLDER,
                SpaceFilesProblem.UNSUPPORTED,
                "parent provider flags do not allow child creation",
            )
            return false
        }
        if (!beginBusy(SpaceFilesOperation.CREATE_FOLDER)) return false
        var created = false
        try {
            val outcome = awaitProvider { cancel ->
                service.operations.createDocument(
                    tree = browse.root.uri,
                    parentDocumentId = folder.documentId,
                    mimeType = SafDocument.MIME_DIR,
                    displayName = name,
                    cancel = cancel,
                )
            }
            when (outcome) {
                is SafOutcome.Success -> {
                    created = true
                    _state.update {
                        it.copy(notice = SpaceFilesNotice.Completed(SpaceFilesOperation.CREATE_FOLDER, name))
                    }
                }
                is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.CREATE_FOLDER, outcome)
            }
        } finally {
            endBusy()
        }
        if (created) reloadBrowseInternal()
        return created
    }

    internal suspend fun createFileInternal(rawName: String): Boolean {
        val browse = _state.value.browse ?: return false
        val name = rawName.trim()
        if (!SpaceFilesNames.isSafeSegment(name)) {
            publishFailure(SpaceFilesOperation.CREATE_FILE, SpaceFilesProblem.INVALID_NAME)
            return false
        }
        val folder = browse.folder ?: return false
        if (folder.canCreateChildren != true) {
            publishFailure(
                SpaceFilesOperation.CREATE_FILE,
                SpaceFilesProblem.UNSUPPORTED,
                "parent provider flags do not allow child creation",
            )
            return false
        }
        if (!beginBusy(SpaceFilesOperation.CREATE_FILE)) return false
        var created = false
        try {
            val outcome = awaitProvider { cancel ->
                service.operations.createDocument(
                    tree = browse.root.uri,
                    parentDocumentId = folder.documentId,
                    mimeType = SpaceFilesNames.mimeForNewTextFile(name),
                    displayName = name,
                    cancel = cancel,
                )
            }
            when (outcome) {
                is SafOutcome.Success -> {
                    // Providers may adjust the name (for example add ".txt").
                    // Report what the provider actually created, not our guess.
                    val meta = awaitProvider { cancel -> service.operations.metadata(outcome.value, cancel) }
                    val actual = if (meta is SafOutcome.Success) meta.value else null
                    created = true
                    _state.update {
                        it.copy(notice = SpaceFilesNotice.Completed(
                            SpaceFilesOperation.CREATE_FILE,
                            actual?.displayName ?: name,
                        ))
                    }
                }
                is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.CREATE_FILE, outcome)
            }
        } finally {
            endBusy()
        }
        if (created) reloadBrowseInternal()
        return created
    }

    internal suspend fun renameInternal(entry: SpaceFileEntry, rawName: String): Boolean {
        val name = rawName.trim()
        if (!SpaceFilesNames.isSafeSegment(name)) {
            publishFailure(SpaceFilesOperation.RENAME, SpaceFilesProblem.INVALID_NAME)
            return false
        }
        if (!entry.canRename) {
            publishFailure(
                SpaceFilesOperation.RENAME,
                SpaceFilesProblem.UNSUPPORTED,
                "provider flags do not support rename",
            )
            return false
        }
        if (!beginBusy(SpaceFilesOperation.RENAME)) return false
        var renamed = false
        try {
            val outcome = awaitProvider { cancel -> service.operations.renameDocument(entry.ref, name, cancel) }
            when (outcome) {
                is SafOutcome.Success -> {
                    renamed = true
                    val notReflectedYet = outcome.note != null
                    _state.update { current ->
                        current.browse?.let { b ->
                            current.copy(
                                browse = b.copy(entries = b.entries.map { row ->
                                    if (row.ref.uri == entry.ref.uri) {
                                        row.copy(
                                            name = if (notReflectedYet) row.name else name,
                                            ref = outcome.value,
                                        )
                                    } else {
                                        row
                                    }
                                }),
                                notice = SpaceFilesNotice.Completed(
                                    SpaceFilesOperation.RENAME,
                                    name,
                                    detail = outcome.note,
                                ),
                            )
                        } ?: current
                    }
                }
                is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.RENAME, outcome)
            }
        } finally {
            endBusy()
        }
        if (renamed) reloadBrowseInternal()
        return renamed
    }

    internal suspend fun deleteInternal(entry: SpaceFileEntry): Boolean {
        if (!entry.canDelete) {
            publishFailure(
                SpaceFilesOperation.DELETE,
                SpaceFilesProblem.UNSUPPORTED,
                "provider flags do not support delete",
            )
            return false
        }
        if (!beginBusy(SpaceFilesOperation.DELETE)) return false
        var deleted = false
        try {
            val outcome = awaitProvider { cancel -> service.operations.deleteDocument(entry.ref, cancel) }
            when (outcome) {
                is SafOutcome.Success -> {
                    deleted = true
                    // Real provider receipt: drop exactly this row, keep every
                    // other file on screen even if the follow-up reload fails.
                    _state.update { current ->
                        current.browse?.let { b ->
                            current.copy(
                                browse = b.copy(entries = b.entries.filterNot { it.ref.uri == entry.ref.uri }),
                                notice = SpaceFilesNotice.Completed(SpaceFilesOperation.DELETE, entry.name),
                            )
                        } ?: current
                    }
                }
                is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.DELETE, outcome)
            }
        } finally {
            endBusy()
        }
        if (deleted) reloadBrowseInternal()
        return deleted
    }

    // ------------------------------------------------------------------
    // Copy / move with destination navigation
    // ------------------------------------------------------------------

    fun beginCopy(entry: SpaceFileEntry) {
        launchOwned { beginTransferInternal(entry, SpaceFilesOperation.COPY) }
    }

    fun beginMove(entry: SpaceFileEntry) {
        launchOwned { beginTransferInternal(entry, SpaceFilesOperation.MOVE) }
    }

    fun transferSelectRoot(uri: SafUriRef) {
        launchOwned { transferSelectRootInternal(uri) }
    }

    fun transferEnter(entry: SpaceFileEntry) {
        launchOwned { transferEnterInternal(entry) }
    }

    fun transferUp() {
        launchOwned { transferUpInternal() }
    }

    fun transferLoadMore() {
        launchOwned { transferLoadMoreInternal() }
    }

    fun transferCancel() {
        val transfer = _state.value.transfer
        if (transfer != null) {
            transferGeneration.incrementAndGet()
            releaseHeldCursor(transfer.nextCursorToken)
        }
        _state.update { it.copy(transfer = null) }
    }

    fun transferConfirm() {
        launchOwned { transferConfirmInternal() }
    }

    internal suspend fun beginTransferInternal(
        entry: SpaceFileEntry,
        operation: SpaceFilesOperation,
    ): Boolean {
        if (operation != SpaceFilesOperation.COPY && operation != SpaceFilesOperation.MOVE) return false
        val browse = _state.value.browse ?: return false
        if (operation == SpaceFilesOperation.COPY) {
            // A directory cannot be byte-verified through the provider stream
            // contract; moving one natively remains supported.
            if (entry.isDirectory) {
                publishFailure(
                    SpaceFilesOperation.COPY,
                    SpaceFilesProblem.UNSUPPORTED,
                    "folder copy is not offered by this page",
                )
                return false
            }
            if (!entry.canCopy) {
                publishFailure(
                    SpaceFilesOperation.COPY,
                    SpaceFilesProblem.UNSUPPORTED,
                    "provider flags do not support copy",
                )
                return false
            }
        }
        if (operation == SpaceFilesOperation.MOVE && !entry.canWrite) {
            publishFailure(SpaceFilesOperation.MOVE, SpaceFilesProblem.READ_ONLY)
            return false
        }
        val root = browse.root
        // The sheet opens immediately with the exact current tree; destination
        // navigation then loads the provider's real directories.
        transferGeneration.incrementAndGet()
        _state.update {
            it.copy(
                transfer = SpaceTransfer(
                    operation = operation,
                    source = entry,
                    tree = root.uri,
                    rootName = root.name,
                    path = listOf(SpaceFolderCrumb(null, root.uri, root.name, false)),
                    loading = true,
                ),
                notice = null,
            )
        }
        val meta = fetchRootMeta(root.uri)
        val pending = _state.value.transfer
            ?.takeIf { it.operation == operation && it.tree == root.uri && it.source == entry }
            ?: return false
        val crumb = SpaceFolderCrumb(meta?.documentId, root.uri, root.name, meta?.canCreate == true)
        val next = pending.copy(path = listOf(crumb), loading = true)
        _state.update { it.copy(transfer = next) }
        loadTransferPageInternal(next, cursor = null)
        return true
    }

    internal suspend fun transferSelectRootInternal(uri: SafUriRef) {
        val transfer = _state.value.transfer ?: return
        val root = _state.value.roots.firstOrNull { it.uri == uri } ?: return
        if (!root.usable) {
            _state.update { it.copy(transfer = transfer.copy(
                tree = uri,
                rootName = root.name,
                path = listOf(SpaceFolderCrumb(null, uri, root.name, false)),
                directories = emptyList(),
                loading = false,
                error = SpaceFilesFailure(SpaceFilesProblem.GRANT_REVOKED),
                hasMore = false,
                nextCursorToken = null,
            )) }
            return
        }
        transferGeneration.incrementAndGet()
        val placeholder = transfer.copy(
            tree = uri,
            rootName = root.name,
            path = listOf(SpaceFolderCrumb(null, uri, root.name, false)),
            directories = emptyList(),
            loading = true,
            error = null,
            hasMore = false,
            nextCursorToken = null,
        )
        _state.update { it.copy(transfer = placeholder) }
        val meta = fetchRootMeta(uri)
        val stillOpen = _state.value.transfer?.takeIf { it.tree == uri } ?: return
        val crumb = SpaceFolderCrumb(meta?.documentId, uri, root.name, meta?.canCreate == true)
        val next = stillOpen.copy(path = listOf(crumb), loading = true)
        _state.update { it.copy(transfer = next) }
        loadTransferPageInternal(next, cursor = null)
    }

    internal suspend fun transferEnterInternal(entry: SpaceFileEntry) {
        if (!entry.isDirectory) return
        val transfer = _state.value.transfer ?: return
        val generation = transferGeneration.incrementAndGet()
        releaseHeldCursor(transfer.nextCursorToken)
        val crumb = SpaceFolderCrumb(entry.documentId, entry.uri, entry.name, entry.canCreateChildren)
        val next = transfer.copy(
            path = transfer.path + crumb,
            directories = emptyList(),
            loading = true,
            error = null,
            hasMore = false,
            nextCursorToken = null,
        )
        _state.update { it.copy(transfer = next) }
        loadTransferPageInternal(next, cursor = null, generation = generation)
    }

    internal suspend fun transferUpInternal() {
        val transfer = _state.value.transfer ?: return
        if (transfer.path.size <= 1) return
        val generation = transferGeneration.incrementAndGet()
        releaseHeldCursor(transfer.nextCursorToken)
        val next = transfer.copy(
            path = transfer.path.dropLast(1),
            directories = emptyList(),
            loading = true,
            error = null,
            hasMore = false,
            nextCursorToken = null,
        )
        _state.update { it.copy(transfer = next) }
        loadTransferPageInternal(next, cursor = null, generation = generation)
    }

    internal suspend fun transferLoadMoreInternal() {
        val transfer = _state.value.transfer ?: return
        val token = transfer.nextCursorToken ?: return
        if (transfer.loading) return
        if (!transferMoreInFlight.compareAndSet(false, true)) return
        _state.update { current ->
            current.transfer?.let { t -> current.copy(transfer = t.copy(loading = true)) } ?: current
        }
        try {
            loadTransferPageInternal(transfer, cursor = token)
        } finally {
            transferMoreInFlight.set(false)
        }
    }

    private suspend fun loadTransferPageInternal(
        transfer: SpaceTransfer,
        cursor: String?,
        generation: Long = transferGeneration.get(),
    ) {
        val folder = transfer.folder ?: return
        val outcome = try {
            awaitProvider { cancel ->
                service.operations.listTreePage(
                    tree = transfer.tree,
                    parentDocumentId = folder.documentId,
                    request = PageRequest(pageSize, cursor),
                    cancel = cancel,
                )
            }
        } catch (cancelled: CancellationException) {
            if (generation == transferGeneration.get()) {
                _state.update { current ->
                    current.transfer?.let { t -> current.copy(transfer = t.copy(
                        loading = false,
                        error = SpaceFilesFailure(SpaceFilesProblem.CANCELLED),
                    )) } ?: current
                }
            }
            throw cancelled
        }
        if (generation != transferGeneration.get()) {
            if (outcome is SafOutcome.Success) releaseHeldCursor(outcome.value.nextCursorToken)
            return
        }
        when (outcome) {
            is SafOutcome.Failure -> {
                val failure = outcome.failure.toSpaceFilesFailure(outcome.detail)
                _state.update { current ->
                    current.transfer
                        ?.takeIf { it.tree == transfer.tree && it.path.lastOrNull()?.documentId == folder.documentId }
                        ?.let { t -> current.copy(transfer = t.copy(
                            loading = false,
                            error = failure,
                            directories = emptyList(),
                            hasMore = false,
                            nextCursorToken = null,
                        )) } ?: current
                }
            }
            is SafOutcome.Success -> {
                val scan = outcome.value
                val restarted = cursor != null && scan.note?.contains("restarted") == true
                val dirs = scan.documents
                    .filter { it.mimeType == SafDocument.MIME_DIR }
                    .map { it.toSpaceFileEntry() }
                    .sortedBy { it.name.lowercase(Locale.ROOT) }
                _state.update { current ->
                    current.transfer
                        ?.takeIf { it.tree == transfer.tree && it.path.lastOrNull()?.documentId == folder.documentId }
                        ?.let { t ->
                            val continueAppend = cursor != null && !restarted && t.nextCursorToken == cursor
                            current.copy(transfer = t.copy(
                                loading = false,
                                error = null,
                                directories = if (continueAppend) t.directories + dirs else dirs,
                                hasMore = scan.nextCursorToken != null,
                                nextCursorToken = scan.nextCursorToken,
                            ))
                        } ?: current
                }
            }
        }
    }

    internal suspend fun transferConfirmInternal(): Boolean {
        val transfer = _state.value.transfer ?: return false
        val dest = transfer.folder ?: return false
        if (transfer.loading) return false
        if (!validDestination(transfer, dest)) {
            publishFailure(
                transfer.operation,
                SpaceFilesProblem.INVALID_DESTINATION,
            )
            return false
        }
        if (!beginBusy(transfer.operation)) return false
        var succeeded = false
        try {
            when (transfer.operation) {
                SpaceFilesOperation.COPY -> {
                    val outcome = awaitProvider { cancel ->
                        service.operations.copyDocumentVerified(
                            source = transfer.source.ref,
                            destTree = transfer.tree,
                            destParentDocumentId = dest.documentId,
                            byteLimit = COPY_VERIFY_BYTE_LIMIT,
                            cancel = cancel,
                        )
                    }
                    when (outcome) {
                        is SafOutcome.Success -> {
                            if (outcome.value.byteIdentical) {
                                succeeded = true
                                _state.update { it.copy(
                                    notice = SpaceFilesNotice.Completed(
                                        SpaceFilesOperation.COPY,
                                        transfer.source.name,
                                    ),
                                    transfer = null,
                                ) }
                            } else {
                                publishFailure(
                                    SpaceFilesOperation.COPY,
                                    SpaceFilesProblem.CONFLICT,
                                    "destination hash differs from the source; the copy was left in place",
                                )
                            }
                        }
                        is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.COPY, outcome)
                    }
                }
                SpaceFilesOperation.MOVE -> {
                    ensureRelayDir()
                    val outcome = awaitProvider { cancel ->
                        service.operations.moveWithVerifiedCopyFallback(
                            ref = transfer.source.ref,
                            destTree = transfer.tree,
                            destParentDocumentId = dest.documentId,
                            relayScratchRoot = relayDir,
                            allowSourceDelete = true,
                            byteLimit = COPY_VERIFY_BYTE_LIMIT,
                            cancel = cancel,
                        )
                    }
                    when (outcome) {
                        is SafOutcome.Success -> {
                            succeeded = true
                            val result = outcome.value
                            _state.update { it.copy(
                                notice = SpaceFilesNotice.Completed(
                                    operation = SpaceFilesOperation.MOVE,
                                    name = transfer.source.name,
                                    detail = result.note,
                                    sourceRetained = result.mode == MoveMode.VERIFIED_COPY_SOURCE_RETAINED,
                                ),
                                transfer = null,
                            ) }
                        }
                        is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.MOVE, outcome)
                    }
                }
                else -> Unit
            }
        } finally {
            endBusy()
        }
        if (succeeded) {
            // The visible folder may be the source or the destination; one real
            // reload reflects whichever provider state actually changed.
            reloadBrowseInternal()
        }
        return succeeded
    }

    private fun validDestination(transfer: SpaceTransfer, dest: SpaceFolderCrumb): Boolean {
        val source = transfer.source
        // Never copy/move a folder into itself or one of its own descendants.
        if (source.documentId != null && transfer.path.any { it.documentId == source.documentId }) return false
        // A copy into the same folder is a legitimate duplicate; a MOVE back
        // into the source folder is a no-op and is refused instead.
        if (transfer.operation == SpaceFilesOperation.MOVE &&
            transfer.tree == source.ref.tree &&
            dest.documentId != null &&
            dest.documentId == source.ref.parentDocumentId
        ) {
            return false
        }
        return true
    }

    // ------------------------------------------------------------------
    // Bounded preview + external open
    // ------------------------------------------------------------------

    fun preview(entry: SpaceFileEntry) {
        launchOwned { previewInternal(entry) }
    }

    fun dismissPreview() {
        previewGeneration.incrementAndGet()
        clearPreviewFile(_state.value.preview)
        _state.update { it.copy(preview = null, previewLoading = false) }
    }

    internal suspend fun previewInternal(entry: SpaceFileEntry) {
        if (entry.isDirectory) return
        val generation = previewGeneration.incrementAndGet()
        clearPreviewFile(_state.value.preview)
        _state.update { it.copy(preview = null, previewLoading = true) }
        val meta = awaitProvider { cancel -> service.operations.metadata(entry.ref, cancel) }
        val document = if (meta is SafOutcome.Success) meta.value else null
        val ref = document?.ref ?: entry.ref
        val name = document?.displayName ?: entry.name
        val mime = document?.mimeType ?: entry.mimeType
        val size = (document?.size as? SafSize.Known)?.bytes ?: entry.sizeBytes
        val virtual = document?.isVirtual ?: entry.isVirtual
        val result: SpaceFilesPreview = try {
            when {
                SpaceFilesNames.allowsTextPreview(mime, name) -> textPreview(ref, name, mime, size, virtual)
                SpaceFilesNames.allowsImagePreview(mime, name) -> imagePreview(ref, name, mime, size, virtual)
                else -> SpaceFilesPreview.Unavailable(
                    name = name,
                    mimeType = mime,
                    bytes = size,
                    ref = ref,
                    isVirtual = virtual,
                    failure = SpaceFilesFailure(SpaceFilesProblem.BINARY),
                )
            }
        } catch (cancelled: CancellationException) {
            if (generation == previewGeneration.get()) {
                _state.update { it.copy(previewLoading = false) }
            }
            throw cancelled
        } catch (error: Exception) {
            SpaceFilesPreview.Unavailable(
                name = name,
                mimeType = mime,
                bytes = size,
                ref = ref,
                isVirtual = virtual,
                failure = SpaceFilesFailure(SpaceFilesProblem.IO, error.javaClass.simpleName),
            )
        }
        if (generation != previewGeneration.get()) {
            if (result is SpaceFilesPreview.Image) deletePreviewFile(result.file)
            return
        }
        _state.update { it.copy(preview = result, previewLoading = false) }
    }

    private suspend fun textPreview(
        ref: SafDocumentRef,
        name: String,
        mime: String,
        size: Long?,
        virtual: Boolean,
    ): SpaceFilesPreview {
        if (size != null && size > TEXT_PREVIEW_LIMIT) {
            return SpaceFilesPreview.Unavailable(
                name = name,
                mimeType = mime,
                bytes = size,
                ref = ref,
                isVirtual = virtual,
                failure = SpaceFilesFailure(SpaceFilesProblem.SIZE_LIMIT),
            )
        }
        val outcome = awaitProvider { cancel ->
            service.operations.readBounded(ref, TEXT_PREVIEW_LIMIT, null, cancel)
        }
        return when (outcome) {
            is SafOutcome.Success -> {
                val text = decodeText(outcome.value)
                if (text == null) {
                    SpaceFilesPreview.Unavailable(
                        name = name,
                        mimeType = mime,
                        bytes = size,
                        ref = ref,
                        isVirtual = virtual,
                        failure = SpaceFilesFailure(SpaceFilesProblem.BINARY),
                    )
                } else {
                    SpaceFilesPreview.Text(
                        name = name,
                        mimeType = mime,
                        bytes = size ?: outcome.value.size.toLong(),
                        ref = ref,
                        isVirtual = virtual,
                        text = text,
                    )
                }
            }
            is SafOutcome.Failure -> SpaceFilesPreview.Unavailable(
                name = name,
                mimeType = mime,
                bytes = size,
                ref = ref,
                isVirtual = virtual,
                failure = outcome.failure.toSpaceFilesFailure(outcome.detail),
            )
        }
    }

    private suspend fun imagePreview(
        ref: SafDocumentRef,
        name: String,
        mime: String,
        size: Long?,
        virtual: Boolean,
    ): SpaceFilesPreview {
        if (size != null && size > IMAGE_PREVIEW_LIMIT) {
            return SpaceFilesPreview.Unavailable(
                name = name,
                mimeType = mime,
                bytes = size,
                ref = ref,
                isVirtual = virtual,
                failure = SpaceFilesFailure(SpaceFilesProblem.SIZE_LIMIT),
            )
        }
        ensurePreviewDir()
        val outcome = awaitProvider { cancel ->
            service.operations.stageToWorkingCopy(ref, previewDir, IMAGE_PREVIEW_LIMIT, cancel)
        }
        return when (outcome) {
            is SafOutcome.Success -> SpaceFilesPreview.Image(
                name = name,
                mimeType = mime,
                bytes = outcome.value.bytes,
                ref = ref,
                isVirtual = virtual,
                file = outcome.value.local.file,
            )
            is SafOutcome.Failure -> SpaceFilesPreview.Unavailable(
                name = name,
                mimeType = mime,
                bytes = size,
                ref = ref,
                isVirtual = virtual,
                failure = outcome.failure.toSpaceFilesFailure(outcome.detail),
            )
        }
    }

    fun requestExternalOpen(entry: SpaceFileEntry) {
        if (entry.isDirectory) return
        launchOwned {
            openExternally(
                ref = entry.ref,
                isVirtual = entry.isVirtual,
                name = entry.name,
                mimeType = entry.mimeType,
            )
        }
    }

    /** External open of the EXACT document the preview was read from. */
    fun openPreviewExternally(preview: SpaceFilesPreview) {
        launchOwned {
            openExternally(
                ref = preview.ref,
                isVirtual = preview.isVirtual,
                name = preview.name,
                mimeType = preview.mimeType,
            )
        }
    }

    /** Resolve a real read grant before the composition starts ACTION_VIEW. */
    internal suspend fun openExternally(
        ref: SafDocumentRef,
        isVirtual: Boolean,
        name: String,
        mimeType: String,
    ) {
        val anchor = ref.tree ?: ref.uri
        val evidence = withContext(ioDispatcher) { runCatching { service.grants.currentAccess(anchor) }.getOrNull() }
        if (evidence?.read != true) {
            publishFailure(SpaceFilesOperation.OPEN, SpaceFilesProblem.GRANT_REVOKED)
            return
        }
        if (isVirtual) {
            publishFailure(
                SpaceFilesOperation.OPEN,
                SpaceFilesProblem.UNSUPPORTED,
                "virtual document has no raw byte representation for an external viewer",
            )
            return
        }
        val request = SpaceFilesOpenRequest(
            id = openIncarnation.incrementAndGet(),
            uri = ref.uri,
            mimeType = mimeType,
            name = name,
        )
        _state.update { it.copy(openRequest = request) }
    }

    /** [result] is what the composition actually observed, never an assumption. */
    fun completeOpenRequest(id: Long, result: SpaceFilesOpenResult) {
        val request = _state.value.openRequest ?: return
        if (request.id != id) return
        _state.update { current ->
            current.copy(
                openRequest = null,
                notice = when (result) {
                    SpaceFilesOpenResult.LAUNCHED -> current.notice
                    SpaceFilesOpenResult.NO_HANDLER -> SpaceFilesNotice.Failed(
                        SpaceFilesOperation.OPEN,
                        SpaceFilesFailure(SpaceFilesProblem.NO_HANDLER),
                    )
                    SpaceFilesOpenResult.FAILED -> SpaceFilesNotice.Failed(
                        SpaceFilesOperation.OPEN,
                        SpaceFilesFailure(SpaceFilesProblem.FAILED),
                    )
                },
            )
        }
    }

    // ------------------------------------------------------------------
    // Native editing: per-document writable working copy + verified save-back
    // ------------------------------------------------------------------

    /** User asked to edit one row natively. Gated by the provider's own
     *  write flag; the tree grant must currently allow read+write so the
     *  verified bytes can land back at the same source. */
    fun requestEdit(entry: SpaceFileEntry) {
        launchOwned { startEditInternal(entry) }
    }

    /** Re-launch the editor for one live session (or resume an existing
     *  session for the exact same provider document). */
    fun requestEditLaunch(sessionId: String) {
        launchOwned {
            val row = editLock.withLock { editSessions[sessionId] } ?: return@launchOwned
            if (row.phase == SpaceFilesEditPhase.FINISHED) return@launchOwned
            runCatching { measuredEdit(row.workingFile) }.onFailure {
                saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.RECOVERABLE_FAILURE,
                    errorCode = "copyUnavailable",
                    updatedAtMillis = clock(),
                ))
            }.onSuccess { publishEditLaunch(row) }
        }
    }

    internal suspend fun startEditInternal(entry: SpaceFileEntry): String? {
        if (entry.isDirectory) return null
        if (!SpaceFilesEditPolicy.supportsEdit(
                isDirectory = entry.isDirectory,
                isVirtual = entry.isVirtual,
                canWrite = entry.canWrite,
                sizeBytes = entry.sizeBytes,
            )) {
            publishFailure(
                SpaceFilesOperation.EDIT,
                when {
                    entry.isVirtual -> SpaceFilesFailure(
                        SpaceFilesProblem.UNSUPPORTED,
                        "virtual document has no raw byte representation for an editor",
                    )
                    !entry.canWrite -> SpaceFilesFailure(SpaceFilesProblem.READ_ONLY)
                    else -> SpaceFilesFailure(SpaceFilesProblem.SIZE_LIMIT)
                },
            )
            return null
        }
        val anchor = entry.ref.tree ?: entry.ref.uri
        val evidence = withContext(ioDispatcher) {
            runCatching { service.grants.currentAccess(anchor) }.getOrNull()
        }
        when {
            evidence?.read != true -> {
                publishFailure(SpaceFilesOperation.EDIT, SpaceFilesProblem.GRANT_REVOKED)
                return null
            }
            evidence.write != true -> {
                publishFailure(SpaceFilesOperation.EDIT, SpaceFilesProblem.READ_ONLY)
                return null
            }
        }
        editLock.withLock {
            editSessions.values.firstOrNull {
                it.target.uri == entry.ref.uri && it.phase != SpaceFilesEditPhase.FINISHED
            }?.let { existing ->
                return existing.id.also { publishEditLaunch(existing) }
            }
            if (editSessions.values.count { it.phase != SpaceFilesEditPhase.FINISHED } >=
                SpaceFilesEditPolicy.MAX_ACTIVE_SESSIONS
            ) {
                publishFailure(
                    SpaceFilesOperation.EDIT,
                    SpaceFilesFailure(SpaceFilesProblem.FAILED, "sessionLimit"),
                )
                return null
            }
        }
        // Live capability re-check: the row flag is only a UI hint; the
        // provider's CURRENT flags decide whether a save-back can ever land.
        val live = awaitProvider { cancel -> service.operations.metadata(entry.ref, cancel) }
        val liveDoc = (live as? SafOutcome.Success)?.value
        if (liveDoc == null) {
            publishFailure(
                SpaceFilesOperation.EDIT,
                (live as? SafOutcome.Failure)?.failure?.toSpaceFilesFailure((live as? SafOutcome.Failure)?.detail)
                    ?: SpaceFilesFailure(SpaceFilesProblem.FAILED),
            )
            return null
        }
        if (!liveDoc.capabilities.write) {
            publishFailure(
                SpaceFilesOperation.EDIT,
                SpaceFilesFailure(SpaceFilesProblem.READ_ONLY, "provider flags do not mark this document writable"),
            )
            return null
        }
        val sessionId = UUID.randomUUID().toString()
        val dir = File(editWorkingRoot, sessionId).apply { runCatching { mkdirs() } }
        if (!dir.isDirectory) {
            publishFailure(SpaceFilesOperation.EDIT, SpaceFilesProblem.FAILED, "workingCopyUnavailable")
            return null
        }
        val outcome = awaitProvider { cancel ->
            service.workingCopy.importDocument(
                entry.ref, dir, SpaceFilesEditPolicy.EDIT_BYTE_LIMIT, cancel,
            )
        }
        val copy = when (outcome) {
            is SafOutcome.Failure -> {
                runCatching { dir.deleteRecursively() }
                publishFailure(SpaceFilesOperation.EDIT, outcome)
                return null
            }
            is SafOutcome.Success -> outcome.value.staged
        }
        val now = clock()
        val row = SpaceFilesEditSession(
            id = sessionId,
            target = entry.ref,
            name = copy.displayName.ifBlank { entry.name },
            mimeType = entry.mimeType,
            baselineSha256 = copy.sha256,
            baselineBytes = copy.bytes,
            workingFile = copy.local.file,
            createdAtMillis = now,
            updatedAtMillis = now,
            phase = SpaceFilesEditPhase.EDITING,
        )
        editLock.withLock { editSessions[sessionId] = row }
        runCatching { editJournal?.save(row) }
        runCatching { watchEdit(row) }
        publishEditSessions()
        publishEditLaunch(row)
        return sessionId
    }

    /** The composition observed the real ACTION_EDIT result. */
    fun completeEditLaunch(id: Long, result: SpaceFilesEditLaunchResult) {
        val launch = _state.value.editLaunch ?: return
        if (launch.id != id) return
        _state.update { it.copy(editLaunch = null) }
        when (result) {
            SpaceFilesEditLaunchResult.LAUNCHED -> Unit
            SpaceFilesEditLaunchResult.NO_HANDLER -> settleEditLaunchFailure(
                launch.sessionId, "noHandler", SpaceFilesProblem.NO_HANDLER,
            )
            SpaceFilesEditLaunchResult.FAILED -> settleEditLaunchFailure(
                launch.sessionId, "launchFailed", SpaceFilesProblem.FAILED,
            )
        }
    }

    private fun settleEditLaunchFailure(sessionId: String, code: String, problem: SpaceFilesProblem) {
        launchOwned {
            val row = editLock.withLock { editSessions[sessionId] } ?: return@launchOwned
            saveEditRow(row.copy(
                phase = SpaceFilesEditPhase.FINISHED,
                errorCode = code,
                updatedAtMillis = clock(),
            ))
            publishFailure(SpaceFilesOperation.EDIT, problem)
        }
    }

    /**
     * The verified save-back ladder for one changed working copy:
     *  1. preserve the CURRENT provider bytes into caller-owned recovery
     *     storage BEFORE any destructive possibility (`prepareSave`);
     *  2. if the observed source hash differs from the import baseline the
     *     result is a CONFLICT — both versions stay recoverable and NOTHING
     *     is written;
     *  3. otherwise `commitSave` writes + read-back-verifies, non-destructive
     *     sibling fallback included; only the provider read-back hash may
     *     report committed bytes.
     * Triggered by the working-copy watcher debounce and by every resume.
     */
    internal suspend fun reconcileEditInternal(sessionId: String) {
        val row = editLock.withLock { editSessions[sessionId] } ?: return
        if (row.phase in setOf(
                SpaceFilesEditPhase.FINISHED,
                SpaceFilesEditPhase.CONFLICT,
                SpaceFilesEditPhase.SAVING,
            )) {
            return
        }
        val measured = runCatching { measuredEdit(row.workingFile) }.getOrElse {
            saveEditRow(row.copy(
                phase = SpaceFilesEditPhase.RECOVERABLE_FAILURE,
                errorCode = "copyUnavailable",
                updatedAtMillis = clock(),
            ), expected = row)
            return
        }
        if (SpaceFilesEditPolicy.workingState(measured.first, row.baselineSha256) ==
            SpaceFilesEditPolicy.WorkingState.UNCHANGED
        ) {
            return
        }
        val saving = row.copy(phase = SpaceFilesEditPhase.SAVING, errorCode = null, updatedAtMillis = clock())
        if (!saveEditRow(saving, expected = row)) return
        val recoveryAvailable = withContext(ioDispatcher) {
            runCatching {
                if (!editRecoveryRoot.isDirectory) editRecoveryRoot.mkdirs()
                editRecoveryRoot.isDirectory && !Files.isSymbolicLink(editRecoveryRoot.toPath())
            }.getOrDefault(false)
        }
        if (!recoveryAvailable) {
            saveEditRow(saving.copy(
                phase = SpaceFilesEditPhase.RECOVERABLE_FAILURE,
                errorCode = "recoveryStoreUnavailable",
                updatedAtMillis = clock(),
            ))
            publishFailure(SpaceFilesOperation.EDIT, SpaceFilesProblem.FAILED, "recoveryStoreUnavailable")
            return
        }
        val preparedOutcome = awaitProvider { cancel ->
            service.workingCopy.prepareSave(
                row.target, row.baselineSha256, editRecoveryRoot,
                SpaceFilesEditPolicy.EDIT_BYTE_LIMIT, cancel,
            )
        }
        val prepared = when (preparedOutcome) {
            is SafOutcome.Failure -> {
                val mapped = preparedOutcome.failure.toSpaceFilesFailure(preparedOutcome.detail)
                saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.RECOVERABLE_FAILURE,
                    errorCode = preparedOutcome.failure.code,
                    updatedAtMillis = clock(),
                ))
                publishFailure(SpaceFilesOperation.EDIT, mapped)
                return
            }
            is SafOutcome.Success -> preparedOutcome.value
        }
        if (prepared.state == PreparedState.SOURCE_CHANGED) {
            // Crash recovery: when the live source already holds exactly the
            // working bytes (the prepareSave receipt proves the observed
            // source hash), a previous save landed before its journal ACK —
            // process death between the provider commit and the journal save
            // — or another writer produced identical bytes. Settle as
            // verified at the same source instead of forcing the user
            // through a false conflict; a genuinely different source still
            // conflicts with BOTH versions kept (never an overwrite).
            val alreadyAtSource = prepared.observedSourceSha256 == measured.first &&
                prepared.receipt.bytes == measured.second
            // Both settlement saves are fenced with `expected = saving`: a
            // session finished/dismissed under the in-flight provider hop can
            // never be re-created here, and its notice is published only when
            // the matching row transition really happened.
            val settled = alreadyAtSource && saveEditRow(row.copy(
                phase = SpaceFilesEditPhase.SAVED,
                errorCode = null,
                savedSiblingName = null,
                baselineSha256 = measured.first,
                baselineBytes = measured.second,
                recoveryReceiptId = prepared.receipt.receiptId,
                updatedAtMillis = clock(),
            ), expected = saving)
            if (settled) {
                _state.update {
                    it.copy(notice = SpaceFilesNotice.Completed(
                        SpaceFilesOperation.EDIT,
                        row.name,
                        detail = null, // null = verified at the same source document
                    ))
                }
                afterEditSaved(row.target)
            } else if (!alreadyAtSource && saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.CONFLICT,
                    errorCode = "sourceChanged",
                    recoveryReceiptId = prepared.receipt.receiptId,
                    updatedAtMillis = clock(),
                ), expected = saving)
            ) {
                publishFailure(
                    SpaceFilesOperation.EDIT,
                    SpaceFilesFailure(
                        SpaceFilesProblem.CONFLICT,
                        "the file changed elsewhere since it was opened; your edits and the current file are both kept",
                    ),
                )
            }
            return
        }
        val commitOutcome = awaitProvider { cancel ->
            service.workingCopy.commitSave(
                prepared,
                StagedLocalRef(row.workingFile, row.workingFile.name),
                measured.first,
                SavePolicy(
                    preferSaveAsWhenReplacementNotProven = false,
                    allowDestructiveOverwrite = true,
                    allowSaveAsSibling = true,
                    recoveryByteLimit = SpaceFilesEditPolicy.EDIT_BYTE_LIMIT,
                    // Human-readable sibling convention, matching the
                    // conflict-export path; the final surfaced name still
                    // comes from the provider read-back below.
                    siblingName = editedSiblingName(row.name),
                ),
                editJournal,
                cancel,
            )
        }
        val receipt = (commitOutcome as? SafOutcome.Success)?.value
        if (receipt == null) {
            saveEditRow(row.copy(
                phase = SpaceFilesEditPhase.RECOVERABLE_FAILURE,
                errorCode = "commitUnavailable",
                recoveryReceiptId = prepared.receipt.receiptId,
                updatedAtMillis = clock(),
            ))
            publishFailure(SpaceFilesOperation.EDIT, SpaceFilesProblem.FAILED, "commit unavailable")
            return
        }
        when (receipt) {
            is SaveReceipt.Committed -> {
                saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.SAVED,
                    errorCode = null,
                    savedSiblingName = null,
                    // The provider now holds these bytes; a later edit round
                    // compares against THIS verified state, not the import one.
                    baselineSha256 = measured.first,
                    baselineBytes = measured.second,
                    recoveryReceiptId = prepared.receipt.receiptId,
                    updatedAtMillis = clock(),
                ))
                _state.update {
                    it.copy(notice = SpaceFilesNotice.Completed(
                        SpaceFilesOperation.EDIT,
                        row.name,
                        detail = null, // null = verified at the same source document
                    ))
                }
                afterEditSaved(row.target)
            }
            is SaveReceipt.SaveAsCreated -> {
                // The created ref carries no display name and a real provider
                // may adjust the requested sibling name on collision: the
                // user-facing label must be the provider's actual name.
                val siblingName = createdDisplayName(receipt.created.created, editedSiblingName(row.name))
                saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.SAVED,
                    errorCode = null,
                    savedSiblingName = siblingName,
                    baselineSha256 = measured.first,
                    baselineBytes = measured.second,
                    recoveryReceiptId = prepared.receipt.receiptId,
                    updatedAtMillis = clock(),
                ))
                _state.update {
                    it.copy(notice = SpaceFilesNotice.Completed(
                        SpaceFilesOperation.EDIT,
                        row.name,
                        detail = siblingName, // non-null = explicit recovery sibling
                    ))
                }
                afterEditSaved(row.target)
            }
            is SaveReceipt.Conflict -> {
                saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.CONFLICT,
                    errorCode = "conflict",
                    recoveryReceiptId = receipt.recovery.receiptId,
                    updatedAtMillis = clock(),
                ))
                publishFailure(
                    SpaceFilesOperation.EDIT,
                    SpaceFilesFailure(
                        SpaceFilesProblem.CONFLICT,
                        "the file changed while saving; your edits and the current file are both kept",
                    ),
                )
            }
            is SaveReceipt.RecoverableFailure -> {
                saveEditRow(row.copy(
                    phase = SpaceFilesEditPhase.RECOVERABLE_FAILURE,
                    errorCode = receipt.code,
                    recoveryReceiptId = prepared.receipt.receiptId,
                    updatedAtMillis = clock(),
                ))
                publishFailure(
                    SpaceFilesOperation.EDIT,
                    SpaceFilesFailure(SpaceFilesProblem.FAILED, receipt.code),
                )
            }
        }
    }

    fun reconcileEdit(sessionId: String) {
        launchOwned { reconcileEditInternal(sessionId) }
    }

    /** CONFLICT resolution: export the edited working bytes as an EXPLICIT new
     *  document next to the original (the original is never overwritten). */
    fun saveConflictCopyAsNew(sessionId: String) {
        launchOwned {
            val row = editLock.withLock {
                editSessions[sessionId]?.takeIf { it.phase == SpaceFilesEditPhase.CONFLICT }
            } ?: return@launchOwned
            val tree = row.target.tree ?: run {
                publishFailure(SpaceFilesOperation.EDIT, SpaceFilesProblem.GRANT_MISSING)
                return@launchOwned
            }
            val measured = runCatching { measuredEdit(row.workingFile) }.getOrElse {
                saveEditRow(row.copy(errorCode = "copyUnavailable", updatedAtMillis = clock()))
                return@launchOwned
            }
            val staged = StagedCopy(
                local = StagedLocalRef(row.workingFile, row.workingFile.name),
                sourceUri = row.target.uri,
                sourceDocumentId = row.target.documentId,
                bytes = measured.second,
                sha256 = measured.first,
                sizeHintBytes = null,
                lastModifiedHintMillis = null,
                displayName = row.name,
            )
            val outcome = awaitProvider { cancel ->
                service.workingCopy.exportStagedCopy(
                    staged, tree, row.target.parentDocumentId,
                    editedSiblingName(row.name), cancel,
                )
            }
            when (outcome) {
                is SafOutcome.Failure -> publishFailure(SpaceFilesOperation.EDIT, outcome)
                is SafOutcome.Success -> {
                    // Same rule as the commit-fallback sibling: surface the
                    // provider's actual display name, not the requested one.
                    val siblingName = createdDisplayName(outcome.value.created, editedSiblingName(row.name))
                    saveEditRow(row.copy(
                        phase = SpaceFilesEditPhase.FINISHED,
                        errorCode = null,
                        savedSiblingName = siblingName,
                        updatedAtMillis = clock(),
                    ))
                    _state.update {
                        it.copy(notice = SpaceFilesNotice.Completed(
                            SpaceFilesOperation.EDIT,
                            row.name,
                            detail = siblingName,
                        ))
                    }
                    reloadBrowseInternal()
                }
            }
        }
    }

    /** CONFLICT resolution: keep the provider version; the edited working copy
     *  and the recovery original stay on disk (a copy is never discarded). */
    fun keepProviderVersion(sessionId: String) {
        launchOwned {
            val row = editLock.withLock {
                editSessions[sessionId]?.takeIf { it.phase == SpaceFilesEditPhase.CONFLICT }
            } ?: return@launchOwned
            saveEditRow(row.copy(
                phase = SpaceFilesEditPhase.FINISHED,
                errorCode = "keptProviderVersion",
                updatedAtMillis = clock(),
            ))
        }
    }

    /** Close one session: stop watching, keep every copy, free the editor's
     *  grant (the composition revokes the URI it minted for this session). */
    fun finishEdit(sessionId: String) {
        launchOwned {
            val row = editLock.withLock { editSessions[sessionId] } ?: return@launchOwned
            if (row.phase == SpaceFilesEditPhase.SAVING) return@launchOwned
            stopWatchingEdit(sessionId)
            saveEditRow(row.copy(phase = SpaceFilesEditPhase.FINISHED, updatedAtMillis = clock()))
        }
    }

    /** Remove one finished session from the surface. Copies ALWAYS stay on
     *  disk (working copy + recovery original); only the metadata row goes. */
    fun dismissEdit(sessionId: String) {
        launchOwned {
            stopWatchingEdit(sessionId)
            editLock.withLock { editSessions.remove(sessionId) }
            runCatching { editJournal?.remove(sessionId) }
            publishEditSessions()
        }
    }

    // ---- edit plumbing -------------------------------------------------

    private fun publishEditLaunch(row: SpaceFilesEditSession) {
        _state.update {
            it.copy(editLaunch = SpaceFilesEditLaunch(
                id = editIncarnation.incrementAndGet(),
                sessionId = row.id,
                file = row.workingFile,
                mimeType = row.mimeType.ifBlank { "*/*" },
                name = row.name,
            ))
        }
    }

    private suspend fun publishEditSessions() {
        val rows = editLock.withLock { editSessions.values.toList() }
        _state.update { it.copy(editSessions = rows.sortedByDescending { row -> row.updatedAtMillis }) }
    }

    private suspend fun saveEditRow(row: SpaceFilesEditSession, expected: SpaceFilesEditSession? = null): Boolean {
        val updated = editLock.withLock {
            if (expected != null && editSessions[row.id] != expected) return@withLock false
            editSessions[row.id] = row
            true
        }
        if (!updated) return false
        runCatching { editJournal?.save(row) }
        publishEditSessions()
        return true
    }

    /** Display name the provider actually gave a just-created sibling. The
     * created ref carries no name and the provider may adjust the requested
     * name (collision), so the label surfaced to the user is read back live;
     * when the read fails the bounded requested name stays the honest
     * fallback (bytes were still verified by the save receipt itself). */
    private suspend fun createdDisplayName(ref: SafDocumentRef, fallback: String): String =
        when (val outcome = awaitProvider { cancel -> service.operations.metadata(ref, cancel) }) {
            is SafOutcome.Success -> outcome.value.displayName.ifBlank { fallback }
            is SafOutcome.Failure -> fallback
        }

    /** Verified size + streamed SHA-256 of one working copy (bounded). */
    private fun measuredEdit(file: File): Pair<String, Long> {
        if (!file.isFile || file.length() !in 0..SpaceFilesEditPolicy.EDIT_BYTE_LIMIT) {
            throw IllegalStateException("copyUnavailable")
        }
        val digest = MessageDigest.getInstance("SHA-256")
        var bytes = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                bytes += count
                if (bytes > SpaceFilesEditPolicy.EDIT_BYTE_LIMIT) throw IllegalStateException("contentTooLarge")
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } to bytes
    }

    @Suppress("DEPRECATION")
    private fun watchEdit(row: SpaceFilesEditSession) {
        if (editObservers.containsKey(row.id)) return
        val dir = row.workingFile.parentFile ?: return
        val observer = object : android.os.FileObserver(
            dir.path, android.os.FileObserver.CLOSE_WRITE or android.os.FileObserver.MOVED_TO,
        ) {
            override fun onEvent(event: Int, path: String?) {
                if (path == row.workingFile.name) {
                    editDebounce.remove(row.id)?.cancel()
                    editDebounce[row.id] = scope.launch(ioDispatcher) {
                        delay(600)
                        reconcileEdit(row.id)
                    }
                }
            }
        }
        // Register only a watcher that actually started: a failed start must
        // not leave a registered observer whose stopWatching() would later
        // throw past the session teardown (finish/dismiss never re-create).
        if (editObservers.putIfAbsent(row.id, observer) == null) {
            runCatching { observer.startWatching() }.onFailure {
                editObservers.remove(row.id, observer)
            }
        }
    }

    private fun stopWatchingEdit(sessionId: String) {
        editDebounce.remove(sessionId)?.cancel()
        // Teardown must never throw past the row removal below: the debounce
        // is already cancelled and a dead observer is inert.
        runCatching { editObservers.remove(sessionId)?.stopWatching() }
    }

    /** After a verified save the provider listing + the open preview (when it
     *  shows the exact saved document) are refreshed from the current bytes. */
    private suspend fun afterEditSaved(target: SafDocumentRef) {
        reloadBrowseInternal()
        val preview = _state.value.preview
        if (preview != null && preview.ref.uri == target.uri) {
            previewInternal(entryFromTarget(target, preview.name, preview.mimeType, preview.isVirtual))
        }
    }

    private fun entryFromTarget(
        target: SafDocumentRef,
        name: String,
        mimeType: String,
        isVirtual: Boolean,
    ): SpaceFileEntry = SpaceFileEntry(
        name = name,
        mimeType = mimeType,
        sizeBytes = null,
        lastModifiedMillis = null,
        isDirectory = false,
        isVirtual = isVirtual,
        ref = target,
        canWrite = true,
        canRename = true,
        canDelete = true,
        canCopy = true,
        canMove = true,
        canCreateChildren = false,
    )

    private fun editedSiblingName(original: String): String {
        val dot = original.lastIndexOf('.')
        val candidate = if (dot > 0) {
            original.substring(0, dot) + " (edited)" + original.substring(dot)
        } else {
            "$original (edited)"
        }
        return if (SpaceFilesNames.isSafeSegment(candidate)) candidate else "$original.edited"
    }

    /** Restore durable sessions after process start; an interrupted SAVING
     *  ladder re-enters from EDITING (prepareSave re-observes the source, so
     *  a crash between write and read-back can only resolve to conflict). */
    private suspend fun restoreEditSessionsInternal() {
        val journal = editJournal ?: return
        val loaded = runCatching { journal.load() }.getOrElse {
            _state.update { current ->
                current.copy(notice = SpaceFilesNotice.Failed(
                    SpaceFilesOperation.EDIT,
                    SpaceFilesFailure(SpaceFilesProblem.FAILED, "editJournalUnavailable"),
                ))
            }
            return
        }
        // Finished sessions never re-surface after a restart; their copies
        // remain on disk and the metadata row is retired.
        loaded.filter { it.phase == SpaceFilesEditPhase.FINISHED }
            .forEach { runCatching { journal.remove(it.id) } }
        val restored = loaded.filterNot { it.phase == SpaceFilesEditPhase.FINISHED }
        if (restored.isEmpty()) return
        editLock.withLock {
            restored.forEach { row ->
                val reconciling = row.phase == SpaceFilesEditPhase.SAVING
                editSessions[row.id] = if (reconciling) {
                    row.copy(phase = SpaceFilesEditPhase.EDITING, errorCode = "reconciling")
                } else {
                    row
                }
            }
        }
        publishEditSessions()
        editLock.withLock { editSessions.values.toList() }
            .filter { it.phase != SpaceFilesEditPhase.FINISHED }
            .forEach { row ->
                runCatching { watchEdit(row) }
                reconcileEditInternal(row.id)
            }
    }

    // ------------------------------------------------------------------
    // Shared plumbing
    // ------------------------------------------------------------------

    private fun launchOwned(block: suspend () -> Unit): Job? {
        if (closed.get()) return null
        return scope.launch(ioDispatcher) {
            try {
                block()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        busy = null,
                        notice = SpaceFilesNotice.Failed(
                            SpaceFilesOperation.LOAD,
                            SpaceFilesFailure(SpaceFilesProblem.FAILED, error.javaClass.simpleName),
                        ),
                    )
                }
            }
        }
    }

    /**
     * Await ACTUAL settlement. Cancellation of the caller only REQUESTS
     * `SafOperation.cancel`; the wait itself runs NonCancellable so a live
     * provider stream and its finalizers are never abandoned mid-call.
     */
    private suspend fun <T> awaitProvider(block: (SafCancelToken) -> SafOutcome<T>): SafOutcome<T> {
        val caller = currentCoroutineContext()
        val operation: SafOperation<T> = try {
            withContext(ioDispatcher) { service.submit(block) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return SafOutcome.failure(SafFailure.Failed(error.message ?: "gateway admission closed"))
        }
        return withContext(NonCancellable + ioDispatcher) {
            val watch = launch(Dispatchers.Default) {
                while (!operation.isDone) {
                    if (!caller.isActive) operation.cancel()
                    delay(20L)
                }
            }
            try {
                operation.await()
            } finally {
                watch.cancel()
            }
        }
    }

    private fun beginBusy(operation: SpaceFilesOperation): Boolean {
        while (true) {
            val current = _state.value
            if (current.busy != null) return false
            if (_state.compareAndSet(current, current.copy(busy = operation, notice = null))) return true
        }
    }

    private fun endBusy() {
        _state.update { it.copy(busy = null) }
    }

    private fun publishFailure(operation: SpaceFilesOperation, problem: SpaceFilesProblem, detail: String? = null) {
        publishFailure(operation, SpaceFilesFailure(problem, detail))
    }

    private fun publishFailure(operation: SpaceFilesOperation, failure: SpaceFilesFailure) {
        _state.update { it.copy(notice = SpaceFilesNotice.Failed(operation, failure)) }
    }

    private fun publishFailure(operation: SpaceFilesOperation, outcome: SafOutcome.Failure<*>) {
        publishFailure(operation, outcome.failure.toSpaceFilesFailure(outcome.detail))
    }

    private fun decodeText(bytes: ByteArray): String? {
        if (bytes.isEmpty()) return ""
        if (bytes.any { it == 0.toByte() }) return null
        return runCatching {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        }.getOrNull()
    }

    private fun ensurePreviewDir() {
        runCatching { if (!previewDir.isDirectory) previewDir.mkdirs() }
    }

    private fun ensureRelayDir() {
        runCatching { if (!relayDir.isDirectory) relayDir.mkdirs() }
    }

    private fun clearPreviewFile(preview: SpaceFilesPreview?) {
        if (preview is SpaceFilesPreview.Image) deletePreviewFile(preview.file)
    }

    /** Only delete a file this controller staged under its own cache dir. */
    private fun deletePreviewFile(file: File) {
        runCatching {
            val root = stagingRoot.canonicalFile
            val candidate = file.canonicalFile
            if (candidate.path.startsWith(root.path + File.separator) && candidate.isFile) {
                candidate.delete()
            }
        }
    }

    companion object {
        /** Text preview cap: a preview is never allowed to buffer a whole file. */
        const val TEXT_PREVIEW_LIMIT = 256L * 1024

        /** Image preview cap before local staging is refused honestly. */
        const val IMAGE_PREVIEW_LIMIT = 64L * 1024 * 1024

        /** Copy/move verification cap (both ends are hash-streamed). */
        const val COPY_VERIFY_BYTE_LIMIT = 512L * 1024 * 1024
    }
}
