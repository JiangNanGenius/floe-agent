// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import com.floe.android.bridge.BrowserNative
import com.floe.android.feature.browser.api.BrowserPanelOperation
import com.floe.android.feature.browser.api.BrowserPreviewAuthority
import com.floe.android.feature.browser.api.BrowserProjectionSnapshot
import com.floe.android.feature.browser.api.BrowserServiceCallbacks
import com.floe.android.feature.browser.api.BrowserServicePort
import com.floe.android.feature.browser.api.BrowserTabRow
import com.floe.android.feature.browser.api.LoopbackBindPermissionGate
import com.floe.android.feature.browser.api.PreviewAdjudication
import com.floe.android.feature.browser.api.RendererScreenshot
import com.floe.android.feature.browser.api.RendererTabState
import com.floe.android.feature.browser.internal.BrowserProjectionPresenter
import com.floe.android.feature.browser.render.BrowserServiceHooks
import com.floe.android.feature.browser.render.BrowserWebViewRenderer
import com.floe.android.feature.browser.transport.LoopbackPreviewTransport
import java.util.UUID
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject

/**
 * RuntimeHost-owned controlled-browser host (G04-R1 composition).
 *
 * Authority layout (D4/D7): Swift (`FloeBrowser` over the accepted native
 * generation) owns every browser/preview/download/handoff decision. This
 * class owns only the PLATFORM EXECUTION: the claim pump, the exact
 * task-owned WebView surfaces, the 127.0.0.1 loopback transports and the
 * service-driven projection fan-out. It holds NO browser truth: no local
 * tab list, no control booleans, no receipt state, no permission store.
 * Every UI fact arrives as a Swift `BrowserProjection` (via the mailbox
 * `ui.projection` event) and every projection is fenced by the presenter
 * against this binding's exact task/workspace/epoch triple.
 *
 * Lifetime rules honored here:
 *  * service lifetime is the epoch/binding, NEVER view composition: panel
 *    attach/detach only binds the visible projection; it never destroys a
 *    tab, stops a preview or returns control;
 *  * WebView operations run on the main looper with exactly-once replies;
 *    the claim pump and loopback transports run off-main; adjudication
 *    runs per dedicated connection thread and never needs the pump;
 *  * cancellation is a REQUEST: `shouldStop` interrupts platform work and
 *    the claim STILL settles exactly once; nothing detaches silently;
 *  * preview binds go through the ONE existing Application-owned
 *    LocalNetworkAccessBroker (entry/LAN_PERMISSION_REUSE.json): consulted
 *    exactly once per explicit preview start before the listener binds,
 *    never from page content, loads, timers or background;
 *  * downloads perform NO Kotlin IO: facts go up, signals come down.
 */
internal class BrowserHostController(private val host: RuntimeHost) {
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val json = Json { ignoreUnknownKeys = false }
    private val starts = Mutex()
    private val bindingAdmission = Mutex()
    private val epochState = MutableStateFlow(0L)
    val nativeEpoch: StateFlow<Long> = epochState
    private val bindings = ConcurrentHashMap<String, Binding>()
    private val transports = ConcurrentHashMap<String, TransportHandle>()
    private val stoppedLeases = ConcurrentHashMap<String, Boolean>()
    private val offscreenHosts = ConcurrentHashMap<String, ViewGroup>()
    private val replyRoutes = ConcurrentHashMap<String, Binding>()
    private val platformTasks = MutableStateFlow<Set<String>>(emptySet())
    val hostedTasks: StateFlow<Set<String>> = platformTasks
    private val attention = MutableStateFlow<Map<String, String>>(emptyMap())
    val panelAttention: StateFlow<Map<String, String>> = attention
    private val previewRequests = MutableStateFlow<Map<String, String>>(emptyMap())
    val previewPresentationRequests: StateFlow<Map<String, String>> = previewRequests
    private val previewResults = MutableStateFlow<Map<String, String>>(emptyMap())
    val previewStatus: StateFlow<Map<String, String>> = previewResults
    fun consumePreviewPresentation(taskID: String, requestID: String) {
        val key = taskKey(taskID)
        if (previewRequests.value[key] == requestID) previewRequests.update { it - key }
    }
    private val previewWaiters = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private fun taskKey(value: String): String = runCatching {
        UUID.fromString(value).toString().uppercase(Locale.ROOT)
    }.getOrDefault(value)
    private fun publishHostedTasks() { platformTasks.value = bindings.keys.toSet() }

    private class TransportHandle(val leaseID: String, val transport: LoopbackPreviewTransport)

    private class PumpSession(
        val epoch: Long,
        val stopping: AtomicBoolean = AtomicBoolean(false),
        @Volatile var loop: Job? = null,
        val platformJobs: ConcurrentHashMap<Long, Job> = ConcurrentHashMap(),
    )

    @Volatile
    private var session: PumpSession? = null

    @Volatile
    var boundNativeEpoch: Long = 0L
        private set

    // MARK: - pump lifecycle (Main's epoch mount)

    /** Bind the native pump to the LIVE root epoch and start the claim
     * loop off-main. A refused bind leaves no session (honest false). */
    suspend fun start(epoch: Long): Boolean = starts.withLock {
        if (epoch <= 0 || host.nativeRootEpoch() != epoch) return@withLock false
        session?.let { return@withLock it.epoch == epoch && !it.stopping.get() && it.loop?.isActive == true }
        val bound = runCatching { BrowserNative.bindEpoch(epoch) == 0 }.getOrDefault(false)
        if (!bound) return@withLock false
        val value = PumpSession(epoch)
        session = value
        boundNativeEpoch = epoch
        value.loop = host.scope.launch(
            kotlinx.coroutines.Dispatchers.IO, start = CoroutineStart.ATOMIC,
        ) {
            try {
                while (isActive && !value.stopping.get() && host.nativeRootEpoch() == epoch) {
                    val claim = BrowserNative.next(250)
                    if (claim <= 0) continue
                    // Parent cancellation cannot detach a native claim while
                    // platform IO remains active: settle under NonCancellable.
                    withContext(NonCancellable + kotlinx.coroutines.Dispatchers.IO) {
                        execute(value, claim)
                    }
                }
            } finally {
                withContext(NonCancellable + kotlinx.coroutines.Dispatchers.IO) {
                    value.stopping.set(true)
                    // Retain native claims until permission/start work and
                    // all actual connection IO have retired.
                    value.platformJobs.values.toList().forEach { it.join() }
                    while (!stopAllTransports(joinMillis = 2_000)) delay(20)
                    runCatching { BrowserNative.close(epoch) }
                    if (session === value) epochState.value = 0
                }
            }
        }
        val live = !value.stopping.get() && value.loop?.isActive == true
        epochState.value = if (live) epoch else 0
        live
    }

    /** Epoch-exact stop and join. False means the old generation remains
     * owned; it is never declared stopped just because a wait expired. */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean = starts.withLock {
        val value = session ?: return@withLock true
        if (value.epoch != expectedEpoch) return@withLock false
        value.stopping.set(true)
        stopAllTransports(joinMillis = 2_000)
        val joined = withTimeoutOrNull(waitMillis) { value.loop?.join(); true } ?: false
        if (!joined) return@withLock false
        // Native retirement may have fenced its mailbox before a queued
        // release ticket was claimed. After the pump/IO has really joined,
        // destroy every remaining old-generation WebView on its real looper
        // instead of dropping the only platform reference and assuming it
        // was already released. No view disposal drives this lifecycle.
        withContext(kotlinx.coroutines.Dispatchers.Main.immediate) {
            bindings.values.filter { it.epoch == expectedEpoch }.forEach { binding ->
                binding.retiring.set(true)
                binding.renderer.release()
                binding.detachAll()
                replyRoutes.keys.filter { replyRoutes[it] === binding }.forEach { replyRoutes.remove(it) }
                bindings.remove(binding.taskID, binding)
            }
        }
        publishHostedTasks()
        attention.value = emptyMap()
        previewWaiters.values.forEach { it.complete(false) }; previewWaiters.clear()
        previewRequests.value = emptyMap(); previewResults.value = emptyMap()
        stoppedLeases.clear()
        if (session === value) {
            session = null
            boundNativeEpoch = 0
            epochState.value = 0
        }
        true
    }

    fun boundEpoch(): Long = runCatching { BrowserNative.boundEpoch() }.getOrDefault(-1L)

    /** Typed counters JSON for diagnostics (never a control input). */
    fun mailboxStats(): String = BrowserNative.stats()
        ?.let { String(it, Charsets.UTF_8) } ?: "{}"

    /** Main's run-state observer entry (cold recovery): re-deliver the
     * exact recorded returning receipt for the task/run pair, bound epoch
     * only. Returns false when the generation is not bound — an honest
     * refusal, never a placeholder success. */
    fun recoverHandoff(taskID: String, runID: String): Boolean {
        val epoch = boundNativeEpoch
        if (epoch <= 0) return false
        return runCatching { BrowserNative.recoverHandoff(taskID, runID, epoch) == 0 }
            .getOrDefault(false)
    }

    // MARK: - explicit task disposal (deletion / privacy clear / leave)

    /** The exact lifecycle hook Main calls for task deletion, privacy
     * clearing and root stop (per owner): fence page actions, stop the
     * preview, cancel downloads and release the real renderer — all
     * through the native center's own release path. The binding (platform
     * surfaces) drops only after the call was accepted. */
    fun discardTask(taskID: String, expectedEpoch: Long = boundNativeEpoch) {
        val binding = bindings[taskKey(taskID)]?.takeIf { it.epoch == expectedEpoch } ?: return
        postUICall(binding.taskID, mapOf("op" to "discardTask", "rootEpoch" to binding.epoch.toString()))
        binding.retiring.set(true)
        binding.detachAll()
        attention.update { it - binding.taskID }
        // The binding remains owned until renderer.release physically tears
        // down its WebViews; deletion cannot turn a live surface into absence.
    }

    /** Offscreen host mount (Main wires the Activity container once):
     * background tabs then measure/capture honestly (1024x768 dp). */
    fun attachOffscreenHost(taskID: String, container: ViewGroup) {
        offscreenHosts[taskKey(taskID)] = container
        bindings[taskKey(taskID)]?.renderer?.attachOffscreenHost(container)
    }

    fun detachOffscreenHost(taskID: String) {
        offscreenHosts.remove(taskKey(taskID))
        // Detaching the CONTAINER never destroys tabs or returns control;
        // surfaces simply stop being laid out until re-attached.
        bindings[taskKey(taskID)]?.renderer?.detachOffscreenHost()
    }

    /** Cookie/WebView persistence flush on background transitions (Main
     * calls it; feature/browser never runs a timer). */
    fun flushPersistentState() {
        bindings.values.forEach { it.renderer.flushPersistentState() }
    }

    // MARK: - binding acquisition

    class Failure(val code: String) : IllegalStateException(code)

    /** Acquire (or create) the exact task binding for the pane. Refuses
     * temporary chat, foreign/unbound generations and tasks whose ORIGINAL
     * workspace association is not persisted (no first-project guess). */
    suspend fun acquire(taskID: String): Binding = bindingAdmission.withLock {
        val epoch = host.nativeRootEpoch() ?: throw Failure("ownerUnavailable")
        if (boundNativeEpoch != epoch || boundEpoch() != epoch || session?.stopping?.get() != false ||
            session?.loop?.isActive != true) throw Failure("pumpUnbound")
        val entry = host.conversations.entryFor(taskID)
        if (entry?.isTemporary == true) throw Failure("temporaryChat")
        val parsed = runCatching { UUID.fromString(taskID) }
            .getOrNull() ?: throw Failure("invalidTask")
        if (!parsed.toString().equals(taskID, ignoreCase = true)) throw Failure("invalidTask")
        bindings[taskKey(taskID)]?.takeIf { it.epoch == epoch && it.isCurrent() }?.let { return@withLock it }
        val stale = bindings[taskKey(taskID)]
        if (stale?.retiring?.get() == true) throw Failure("ownerStopping")
        if (stale == null && bindings.size >= 128) throw Failure("surfaceBudget")
        if (stale != null && stale.epoch != epoch) {
            stale.detachAll()
            bindings.remove(taskKey(taskID), stale)
        }
        // The workspace identity comes from the ORIGINAL native projection
        // (conversation.get's persisted association), never a local choice.
        val workspaceID = resolveWorkspaceID(taskID, epoch)
            ?: throw Failure("workspaceUnbound")
        val generation = host.commandClient.generation()
        val canonicalTask = taskKey(parsed.toString())
        val service = TaskService(canonicalTask, workspaceID, epoch, generation)
        val hooks = TaskHooks(canonicalTask, epoch, generation)
        val context = runCatching { host.appContext }.getOrNull()
            ?: throw Failure("ownerUnavailable")
        val presenter = BrowserProjectionPresenter(canonicalTask, workspaceID, epoch)
        val renderer = BrowserWebViewRenderer(context, service, hooks)
        val binding = Binding(canonicalTask, workspaceID, epoch, generation, service, presenter, renderer)
        if (!binding.isCurrent()) throw Failure("ownerChanged")
        bindings[canonicalTask] = binding
        publishHostedTasks()
        offscreenHosts[canonicalTask]?.let { renderer.attachOffscreenHost(it) }
        // Platform creation alone does not select a visible task or lift
        // a native release fence. Only the explicit panel calls bindVisible.
        binding
    }

    /** Called after the original editor save ACK. Permission/browser IO is
     * service-owned and never holds the editor's ordered ACK queue. */
    fun requestWorkspacePreview(taskID: String, workspaceID: String, path: String, current: () -> Boolean) {
        if (!current()) throw Failure("ownerUnavailable")
        val key = taskKey(taskID)
        if (previewResults.value[key] == "pending") throw Failure("workspaceBusy")
        val requestID = UUID.randomUUID().toString()
        previewResults.update { it + (key to "pending") }
        previewRequests.update { it + (key to requestID) }
        host.scope.launch(host.ioDispatcher) {
            var route: Binding? = null
            try {
                val epoch = host.nativeRootEpoch() ?: throw Failure("ownerUnavailable")
                route = acquire(taskID)
                if (!current() || route.epoch != epoch || !route.workspaceID.equals(workspaceID, true))
                    throw Failure("ownerChanged")
                val waiter = CompletableDeferred<Boolean>()
                previewWaiters[requestID] = waiter
                replyRoutes[requestID] = route
                val args = JsonObject(mapOf("root" to JsonPrimitive(path))).toString()
                val admitted = postUICall(route.taskID, mapOf(
                    "op" to "previewFile", "requestID" to requestID, "argsJSON" to args,
                    "workspaceID" to route.workspaceID, "rootEpoch" to epoch.toString()))
                if (!admitted) throw Failure("pumpUnbound")
                val ok = withTimeoutOrNull(100_000) { waiter.await() }
                // A UI observation deadline never proves native work failed
                // or stopped; its actual preview projection remains usable.
                if (current()) previewResults.update { it + (key to when (ok) {
                    true -> "ready"; false -> "failed"; null -> "unknown"
                }) }
            } catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException) throw error
                if (current()) previewResults.update { it + (key to "failed") }
            } finally {
                previewWaiters.remove(requestID)
                if (route != null) replyRoutes.remove(requestID, route)
            }
        }
    }

    /** Read, without consuming, the original per-owner request. Cancelling
     * a navigation waiter therefore cannot lose a background handoff. */
    suspend fun hasPendingPanelRequest(taskID: String): Boolean = withContext(host.ioDispatcher) {
        val epoch = host.nativeRootEpoch() ?: return@withContext false
        if (boundNativeEpoch != epoch) return@withContext false
        val request = JsonObject(mapOf("op" to JsonPrimitive("pendingPanelRequest"),
            "taskID" to JsonPrimitive(taskID), "rootEpoch" to JsonPrimitive(epoch.toString()))).toString()
        val buffer = ByteArray(4096)
        val size = runCatching { BrowserNative.uiQuery(request, buffer, 2_000) }.getOrDefault(-1)
        if (host.nativeRootEpoch() != epoch || size <= 0) return@withContext false
        val fields = BrowserNative.replyText(buffer, size)?.let {
            runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull()
        } ?: return@withContext false
        fields.boolean("present") == true && fields.boolean("show") == true
    }

    private suspend fun resolveWorkspaceID(taskID: String, epoch: Long): String? {
        val result = CompletableDeferred<HostOperationOutcome>()
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(taskID),
                stateful = false,
                correlationID = "browser-bind:${UUID.randomUUID()}",
            ),
            onTerminal = { result.complete(it) },
        )
        if (host.nativeRootEpoch() != epoch) return null
        val reply = when (val outcome = result.await()) {
            is HostOperationOutcome.Completed -> outcome.value as? JsonObject ?: return null
            else -> return null
        }
        if (host.nativeRootEpoch() != epoch) return null
        val conversationID = (reply["conversationID"] as? JsonPrimitive)?.contentOrNullSafe()
            ?: return null
        if (!conversationID.equals(taskID, ignoreCase = true)) return null
        if ((reply["purpose"] as? JsonPrimitive)?.contentOrNullSafe() != "ordinary") return null
        val workspace = reply["workspace"] as? JsonObject ?: return null
        val workspaceID = (workspace["workspaceID"] as? JsonPrimitive)?.contentOrNullSafe()
            ?: return null
        return runCatching { UUID.fromString(workspaceID).toString().uppercase(Locale.ROOT) }.getOrNull()
    }

    private fun bindingFor(taskID: String): Binding? =
        bindings[taskKey(taskID)]?.takeIf { it.epoch == boundNativeEpoch && it.isCurrent() }

    // MARK: - the exact task binding

    inner class Binding internal constructor(
        val taskID: String,
        val workspaceID: String,
        val epoch: Long,
        val generation: Long,
        val service: TaskService,
        val presenter: BrowserProjectionPresenter,
        val renderer: BrowserWebViewRenderer,
    ) {
        val retiring = AtomicBoolean(false)
        @Volatile
        var callbacks: BrowserServiceCallbacks? = null

        val isCurrent: () -> Boolean = {
            !retiring.get() && host.nativeRootEpoch() == epoch &&
                host.commandClient.generation() == generation &&
                boundNativeEpoch == epoch && boundEpoch() == epoch &&
                session?.stopping?.get() == false && session?.loop?.isActive == true &&
                host.conversations.entryFor(taskID)?.isTemporary != true
        }

        fun deliverProjection(projectionJson: String) {
            val snapshot = parseProjection(projectionJson, taskID, workspaceID, epoch)
            main.post {
                if (!isCurrent()) return@post
                presenter.apply(snapshot)
                val state = presenter.currentState()
                val id = state.projection?.presentationId
                if (state.panelRequestsUserAttention && id != null) attention.update { it + (taskID to id) }
            }
        }

        fun deliver(body: (BrowserServiceCallbacks) -> Unit) {
            val sink = callbacks
            if (sink != null) main.post { if (isCurrent()) body(sink) }
        }

        fun detachAll() {
            callbacks = null
        }
    }

    // MARK: - claim execution (pump thread, off main)

    private suspend fun execute(value: PumpSession, claim: Long) {
        val settled = AtomicBoolean(false)
        fun settle(status: Int, payload: ByteArray?) {
            if (!settled.compareAndSet(false, true)) return
            runCatching { BrowserNative.complete(claim, status, payload) }
        }
        fun fail(code: String) = settle(1, codeBytes(code))
        if (BrowserNative.isLive(claim) != 1) {
            fail("revoked")
            return
        }
        val fields = BrowserNative.descriptorText(BrowserNative.describe(claim))?.let { text ->
            runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
        }
        if (fields == null) {
            fail("badTicket")
            return
        }
        if (fields.string("epoch") != value.epoch.toString()) {
            fail("generationFenced")
            return
        }
        val operation = fields.string("operation") ?: ""
        val taskID = fields.string("conversationID") ?: ""
        if (operation.startsWith("ui.")) {
            // One-way delivery event: free the claim FIRST (the native side
            // no longer tracks it), then fan out with the staged payload.
            val payload = BrowserNative.payload(claim)
            settle(0, null)
            deliverEvent(operation, taskID, payload)
            return
        }
        if (BrowserNative.shouldStop(claim) == 1) {
            fail("cancelled")
            return
        }
        when (operation) {
            "transport.start" -> {
                val job = host.scope.launch(kotlinx.coroutines.Dispatchers.IO,
                    start = CoroutineStart.LAZY) {
                    withContext(NonCancellable) {
                        try { startTransport(value, claim, fields, ::settle, ::fail) }
                        finally { value.platformJobs.remove(claim) }
                    }
                }
                value.platformJobs[claim] = job
                job.start()
            }
            "transport.stop" -> {
                val lease = fields.string("leaseID") ?: ""
                val handle = transports[lease]
                if (handle == null) {
                    // The lease may still have an UNRESOLVED start (permission
                    // dialog pending): mark it stopped so the start refuses
                    // itself rather than binding an orphan listener.
                    stoppedLeases[lease] = true
                    trimStoppedLeases()
                } else {
                    // Joined teardown: listener closed AND accept thread retired
                    // before the claim settles.
                    drainTransport(handle)
                }
                settle(0, null)
            }
            else -> runRenderer(value, claim, fields, operation, taskID, ::settle, ::fail)
        }
    }

    private fun trimStoppedLeases() {
        if (stoppedLeases.size > 128) {
            stoppedLeases.keys.take(stoppedLeases.size - 128).forEach { stoppedLeases.remove(it) }
        }
    }

    // MARK: - renderer tickets (main looper, exactly-once replies)

    private suspend fun runRenderer(
        value: PumpSession,
        claim: Long,
        fields: JsonObject,
        operation: String,
        taskID: String,
        settle: (Int, ByteArray?) -> Unit,
        fail: (String) -> Unit,
    ) {
        if (operation == "renderer.release" && bindings[taskKey(taskID)] == null) {
            settle(0, null); return // Proven absence of platform resources.
        }
        val isCreate = operation == "renderer.createTab"
        val binding = if (operation == "renderer.release") {
            bindings[taskKey(taskID)]?.takeIf { it.epoch == value.epoch }
        } else if (isCreate) {
            bindingFor(taskID) ?: acquireOrNone(taskID)
        } else {
            bindingFor(taskID)
        }
        if (binding == null) {
            fail(if (isCreate) "surfaceUnavailable" else "tabGone")
            return
        }
        val renderer = binding.renderer
        val tabId = fields.string("tabID")
        val timeout = fields.string("timeoutMilliseconds")?.toLongOrNull() ?: 15_000L
        when (operation) {
            "renderer.createTab" -> {
                if (tabId == null) { fail("badTicket"); return }
                // The probe install source travels with THIS claim, verbatim
                // (the session built and JSON-escaped it; nobody composes
                // actuator scripts from page data).
                val stagedProbe = BrowserNative.payload(claim)
                    ?.let { String(it, Charsets.UTF_8) } ?: ""
                main.post {
                    renderer.createTab(tabId, stagedProbe)
                    settle(0, null)
                }
            }
            "renderer.destroyTab" -> {
                if (tabId == null) { fail("badTicket"); return }
                main.post { renderer.destroyTab(tabId); settle(0, null) }
            }
            "renderer.navigate" -> {
                val url = fields.string("url")
                if (tabId == null || url.isNullOrEmpty()) { fail("badTicket"); return }
                main.post {
                    runCatching { renderer.navigate(tabId, url) }
                        .onSuccess { settle(0, null) }
                        .onFailure { fail("failed") }
                }
            }
            "renderer.goBack" -> {
                if (tabId == null) { fail("badTicket"); return }
                main.post { renderer.goBack(tabId); settle(0, null) }
            }
            "renderer.goForward" -> {
                if (tabId == null) { fail("badTicket"); return }
                main.post { renderer.goForward(tabId); settle(0, null) }
            }
            "renderer.reload" -> {
                if (tabId == null) { fail("badTicket"); return }
                main.post { renderer.reload(tabId); settle(0, null) }
            }
            "renderer.stopLoading" -> {
                if (tabId == null) { fail("badTicket"); return }
                main.post { renderer.stopLoading(tabId); settle(0, null) }
            }
            "renderer.state" -> {
                if (tabId == null) { fail("badTicket"); return }
                // gateway.state() dispatches to main and joins a bounded
                // latch; safe on this pump/IO thread (never called on main).
                val state = renderer.state(tabId)
                if (state == null) fail("tabGone") else settle(0, encodeState(state).toByteArray(Charsets.UTF_8))
            }
            "renderer.evaluate" -> {
                if (tabId == null) { fail("badTicket"); return }
                val expression = BrowserNative.payload(claim)
                    ?.let { String(it, Charsets.UTF_8) } ?: ""
                if (expression.isEmpty()) { fail("badTicket"); return }
                // The gateway reply fires EXACTLY ONCE (AtomicBoolean inside
                // feature/browser); a null reply is an honest typed failure,
                // never a fabricated probe answer.
                renderer.evaluate(tabId, expression, timeout.toInt()) { result ->
                    if (result == null) fail("evaluateFailed")
                    else settle(0, result.toByteArray(Charsets.UTF_8))
                }
            }
            "renderer.screenshot" -> {
                if (tabId == null) { fail("badTicket"); return }
                renderer.captureScreenshot(tabId) { shot ->
                    if (shot == null) fail("captureFailed")
                    else settle(0, encodeScreenshot(shot).toByteArray(Charsets.UTF_8))
                }
            }
            "renderer.release" -> {
                // All platform surfaces for this owner session. Tab retire
                // decisions are Swift's; this only tears down WebViews the
                // released session will never touch again.
                main.post {
                    renderer.release()
                    binding.retiring.set(true)
                    binding.detachAll()
                    replyRoutes.keys.filter { replyRoutes[it] === binding }.forEach { replyRoutes.remove(it) }
                    bindings.remove(taskKey(taskID), binding)
                    attention.update { it - binding.taskID }
                    publishHostedTasks()
                    settle(0, null)
                }
            }
            else -> fail("badTicket")
        }
    }

    private suspend fun acquireOrNone(taskID: String): Binding? = runCatching {
        acquire(taskID)
    }.getOrNull()

    // MARK: - loopback preview transport (off-main)

    private suspend fun drainTransport(handle: TransportHandle) {
        // The JNI request remains owned until socket IO really stops. A
        // short join deadline is an observation, never a detached success.
        while (!handle.transport.stop(joinMillis = 2_000)) delay(20)
        transports.remove(handle.leaseID, handle)
    }

    private suspend fun startTransport(
        value: PumpSession,
        claim: Long,
        fields: JsonObject,
        settle: (Int, ByteArray?) -> Unit,
        fail: (String) -> Unit,
    ) {
        val leaseID = fields.string("leaseID") ?: run { fail("badTicket"); return }
        fun admitted(): Boolean = !value.stopping.get() && host.nativeRootEpoch() == value.epoch &&
            !stoppedLeases.containsKey(leaseID) && BrowserNative.isLive(claim) == 1 &&
            BrowserNative.shouldStop(claim) != 1
        if (!admitted()) { fail("leaseRetired"); return }
        val permission = CompletableDeferred<LoopbackBindPermissionGate.Outcome>()
        val accepting = AtomicBoolean(true)
        permissionGate.ensureBindAllowed("http://127.0.0.1", { accepting.get() && admitted() }) {
            permission.complete(it) // A late dialog callback never binds IO.
        }
        val deadline = System.nanoTime() + 80_000_000_000L
        var answer: LoopbackBindPermissionGate.Outcome? = null
        while (admitted() && System.nanoTime() < deadline && answer == null) {
            answer = withTimeoutOrNull(250) { permission.await() }
        }
        accepting.set(false)
        if (!admitted()) { fail("leaseRetired"); return }
        if (answer == null) { fail("hostBudget"); return }
        if (answer == LoopbackBindPermissionGate.Outcome.denied) {
            fail("localNetworkPermissionDenied"); return
        }
        val transport = LoopbackPreviewTransport(PreviewAuthority(leaseID), leaseID)
        val handle = TransportHandle(leaseID, transport)
        try {
            val port = transport.start()
            transports[leaseID] = handle
            if (!admitted()) {
                drainTransport(handle)
                fail("leaseRetired")
            } else {
                settle(0, "{\"port\":$port}".toByteArray(Charsets.UTF_8))
            }
        } catch (_: Exception) {
            drainTransport(handle)
            fail("transportBindFailed")
        }
    }

    private val permissionGate = object : LoopbackBindPermissionGate {
        override fun ensureBindAllowed(
            endpointDescription: String,
            isCurrent: () -> Boolean,
            completion: (LoopbackBindPermissionGate.Outcome) -> Unit,
        ) {
            // A caller that already went stale must NOT reach the socket:
            // the broker's own no-answer path on `!isCurrent` would
            // otherwise fall into the unwired branch below.
            if (!isCurrent()) {
                completion(LoopbackBindPermissionGate.Outcome.denied)
                return
            }
            val broker = host.integrations.localNetwork
            val once = AtomicBoolean(false)
            fun resolve(outcome: LoopbackBindPermissionGate.Outcome) {
                if (once.compareAndSet(false, true)) completion(outcome)
            }
            // ONLY the broker's own dispatch/onDenied callbacks decide: the
            // Boolean return of runExplicitAction means "action taken", not
            // "permission granted", so it can never be mapped to allowed.
            // A dialog that the user never answers expires the claim typed
            // (hostBudget) — the preview start then fails honestly and the
            // coordinator restores the prior page, exactly like the module
            // contract.
            val raised = runCatching {
                broker.runExplicitAction(
                    ownerID = "browser-preview:" + endpointDescription,
                    endpoint = endpointDescription,
                    isCurrent = isCurrent,
                    onDenied = { _ -> resolve(LoopbackBindPermissionGate.Outcome.denied) },
                    dispatch = { resolve(LoopbackBindPermissionGate.Outcome.allowed) },
                )
            }.isSuccess
            if (!raised) {
                // No broker reachable (fixture/older host): proceed; the
                // loopback bind succeeds or fails at the socket itself.
                resolve(LoopbackBindPermissionGate.Outcome.unwired)
            }
        }
    }

    /** The Swift-side adjudication entry for one loopback connection thread:
     * every call blocks ONLY that dedicated thread (never the pump, never
     * main) and always resolves within the native budgets. */
    private inner class PreviewAuthority(private val leaseID: String) : BrowserPreviewAuthority {
        // The reply buffer is PER CALL: up to eight owned connection threads
        // hit the same authority concurrently and must never share a region.
        override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
            if (serverId != leaseID || headerBlock.size > 64 * 1024) return adjudication(
                statusLine = "404 Not Found",
                headers = listOf("Content-Length" to "0", "Connection" to "close"),
                bodyLength = 0, bodyStart = 0, chunk = ByteArray(0),
            )
            val replyBuffer = ByteArray(160 * 1024)
            val size = runCatching {
                BrowserNative.previewAdjudicate(serverId, requestId, headerBlock, replyBuffer)
            }.getOrDefault(-1)
            if (size < 0) {
                // A bridge refusal is an honest 404: nothing was named or
                // granted, and the Swift verdict (unreachable) may not be
                // replaced by invented authorization.
                return adjudication(
                    statusLine = "404 Not Found",
                    headers = listOf("Content-Length" to "0", "Connection" to "close"),
                    bodyLength = 0, bodyStart = 0, chunk = ByteArray(0),
                )
            }
            val text = BrowserNative.replyText(replyBuffer, size) ?: return adjudication(
                statusLine = "404 Not Found",
                headers = listOf("Content-Length" to "0", "Connection" to "close"),
                bodyLength = 0, bodyStart = 0, chunk = ByteArray(0),
            )
            val fields = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
                ?: return adjudication(
                    statusLine = "404 Not Found",
                    headers = listOf("Content-Length" to "0", "Connection" to "close"),
                    bodyLength = 0, bodyStart = 0, chunk = ByteArray(0),
                )
            val headers = (fields["headers"] as? JsonArray)?.mapNotNull { element ->
                val pair = element as? JsonObject ?: return@mapNotNull null
                val name = pair.string("name") ?: return@mapNotNull null
                val value = pair.string("value") ?: return@mapNotNull null
                name to value
            } ?: emptyList()
            val chunkBase64 = fields.string("chunk") ?: ""
            val chunk = if (chunkBase64.isEmpty()) ByteArray(0) else runCatching {
                android.util.Base64.decode(chunkBase64, android.util.Base64.NO_WRAP)
            }.getOrDefault(ByteArray(0))
            return adjudication(
                statusLine = fields.string("statusLine") ?: "404 Not Found",
                headers = headers,
                bodyLength = fields.integer("bodyLength") ?: 0,
                bodyStart = fields.integer("bodyStart") ?: 0,
                chunk = chunk,
            )
        }

        override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int): ByteArray {
            if (serverId != leaseID || capacity <= 0) return ByteArray(0)
            val target = ByteArray(capacity.coerceAtMost(64 * 1024))
            val size = runCatching {
                BrowserNative.previewReadChunk(serverId, requestId, offset, target)
            }.getOrDefault(-1)
            if (size <= 0) return ByteArray(0) // done/retired/failed — stop honestly
            return target.copyOf(size)
        }

        private fun adjudication(
            statusLine: String,
            headers: List<Pair<String, String>>,
            bodyLength: Int,
            bodyStart: Int,
            chunk: ByteArray,
        ) = PreviewAdjudication(statusLine, headers, bodyLength, bodyStart, chunk)
    }

    // MARK: - delivery fan-out

    private fun deliverEvent(operation: String, routeID: String, payload: ByteArray?) {
        val text = payload?.let { String(it, Charsets.UTF_8) } ?: return
        when (operation) {
            "ui.projection" -> {
                // Native presentation requests belong to their task even
                // when another task is projected or no platform binding exists.
                val projection = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
                val request = projection?.get("presentationRequest") as? JsonObject
                val owner = request?.string("conversationID")
                val id = request?.string("id")
                if (owner != null && id != null) {
                    if (request.boolean("show") == true) attention.update { it + (taskKey(owner) to id) }
                    else attention.update { it - taskKey(owner) }
                }
                // Fan out to EVERY live binding: each presenter fences by
                // its own owner triple, so another task's projection shows
                // as the honest "another task's browser is projected" state
                // and never repaints this task with foreign truth.
                bindings.values.forEach { binding ->
                    if (binding.isCurrent()) binding.deliverProjection(text)
                }
            }
            "ui.popupDecision" -> {
                val fields = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
                val requestID = fields.string("requestID") ?: return
                val decision = fields.string("decision") ?: return
                val route = replyRoutes.remove(requestID) ?: bindingFor(routeID)
                route?.deliver { it.onPopupDecision(requestID, decision) }
            }
            "ui.downloadSignal" -> {
                val route = bindingFor(routeID)
                route?.deliver { it.onDownloadSignal(text) }
            }
            "ui.toolResult" -> {
                val fields = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
                val requestID = fields.string("requestID") ?: return
                val route = replyRoutes.remove(requestID) ?: return
                val ok = fields.boolean("ok") ?: false
                previewWaiters.remove(requestID)?.complete(ok && route.isCurrent())
                val summary = fields.string("summary") ?: ""
                val requiresUserAction = fields.boolean("requiresUserAction") ?: false
                val errorCode = fields.string("errorCode")
                route.deliver {
                    it.onToolResult(requestID, "", ok, summary, requiresUserAction, errorCode)
                }
            }
            "ui.commandResult" -> {
                val fields = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
                val requestID = fields.string("requestID") ?: return
                val route = replyRoutes.remove(requestID) ?: return
                route.deliver { it.onCommandResult(requestID, fields.string("result") ?: "{}") }
            }
        }
    }

    // MARK: - BrowserServicePort (task-owned, non-blocking)

    inner class TaskService(
        override val taskId: String,
        override val workspaceId: String,
        override val rootEpoch: Long,
        private val generation: Long,
    ) : BrowserServicePort {
        private fun ownedUICall(fields: Map<String, String>): Boolean =
            postUICall(taskId, fields + ("rootEpoch" to rootEpoch.toString()))

        override fun attach(callbacks: BrowserServiceCallbacks) {
            bindingFor(taskId)?.callbacks = callbacks
        }

        override fun submitTool(requestId: String, toolName: String, argsJson: String) {
            val route = bindingFor(taskId)?.takeIf { isBindingCurrent() } ?: return
            replyRoutes[requestId] = route
            ownedUICall( mapOf(
                "op" to "toolSubmit",
                "requestID" to requestId,
                "toolName" to toolName,
                "argsJSON" to argsJson,
                "workspaceID" to workspaceId,
                "rootEpoch" to rootEpoch.toString(),
            ))
        }

        override fun submitCommand(requestId: String, commandJson: String) {
            val route = bindingFor(taskId)?.takeIf { isBindingCurrent() } ?: return
            replyRoutes[requestId] = route
            ownedUICall( mapOf(
                "op" to "commandSubmit",
                "requestID" to requestId,
                "commandJSON" to commandJson,
                "workspaceID" to workspaceId,
                "rootEpoch" to rootEpoch.toString(),
            ))
        }

        override fun ingestLifecycle(eventJson: String) {
            if (!isBindingCurrent()) return
            val event = runCatching { json.parseToJsonElement(eventJson) }.getOrNull() ?: return
            val envelope = JsonObject(mapOf("rootEpoch" to JsonPrimitive(rootEpoch.toString()), "event" to event))
            runCatching { BrowserNative.ingestEvent(envelope.toString()) }
        }

        override fun requestPopupDecision(requestId: String, tabId: String, url: String) {
            val route = bindingFor(taskId)?.takeIf { isBindingCurrent() } ?: return
            replyRoutes[requestId] = route
            val request = buildString {
                append("{\"requestID\":\"").append(escape(requestId))
                .append("\",\"taskID\":\"").append(escape(taskId))
                .append("\",\"rootEpoch\":\"").append(rootEpoch)
                .append("\",\"query\":{\"tabID\":\"").append(escape(tabId))
                .append("\",\"url\":\"").append(escape(url)).append("\"}}")
            }
            runCatching { BrowserNative.popupQuery(request) }
        }

        override fun requestDownload(requestId: String, queryJson: String) {
            val route = bindingFor(taskId)?.takeIf { isBindingCurrent() } ?: return
            // Download progress/commit/refusal arrives as `ui.downloadSignal`
            // events routed by the owning task; no per-request route is kept.
            val fields = runCatching { json.parseToJsonElement(queryJson).jsonObject }.getOrNull()
                ?: return
            val body = StringBuilder("{\"requestID\":\"").append(escape(requestId))
                .append("\",\"taskID\":\"").append(escape(route.taskID))
                .append("\",\"rootEpoch\":\"").append(rootEpoch).append('"')
            fields.forEach { (key, value) ->
                if (value is JsonPrimitive && key in setOf("tabID", "url", "userAgent", "contentDisposition", "mimeType", "contentLength")) {
                    body.append(',').append('"').append(escape(key)).append("\":")
                        .append(if (value.isString) "\"" + escape(value.content) + "\"" else value.content)
                }
            }
            body.append('}')
            runCatching { BrowserNative.downloadRequest(body.toString()) }
        }

        override fun bindVisible() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf(
                "op" to "bind",
                "workspaceID" to workspaceId,
                "rootEpoch" to rootEpoch.toString(),
            ))
        }

        override fun unbindVisible() {
            ownedUICall( mapOf("op" to "unbind"))
        }

        override fun setAddressText(text: String) {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "setAddressText", "text" to text))
        }

        override fun setEditingAddress(editing: Boolean) {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "setEditingAddress", "editing" to editing.toString()))
        }

        override fun navigateFromAddressBar() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "navigateAddressBar"))
        }

        override fun navigateFromAddressBar(draft: String) {
            if (!isBindingCurrent()) return
            // One owned call carries the exact draft; the Swift session
            // applies the draft, clears editing and captures/validates the
            // target before its first suspension, so the newest typed URL
            // is what THIS commit navigates to regardless of in-flight
            // keystroke-echo Tasks.
            ownedUICall( mapOf("op" to "navigateAddressBar", "text" to draft))
        }

        override fun requestReload() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "reload"))
        }

        override fun goBackTab() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "goBack"))
        }

        override fun goForwardTab() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "goForward"))
        }

        override fun performPanelOperation(operation: BrowserPanelOperation) {
            if (!isBindingCurrent()) return
            when (operation) {
                BrowserPanelOperation.CreateTab -> ownedUICall( mapOf("op" to "createTab"))
                is BrowserPanelOperation.Activate ->
                    ownedUICall( mapOf("op" to "activateTab", "tabID" to operation.tabId))
                is BrowserPanelOperation.Close ->
                    ownedUICall( mapOf("op" to "closeTab", "tabID" to operation.tabId))
            }
        }

        override fun takeControl() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "takeControl"))
        }

        override fun returnToAgent(receiptId: String, continueTask: Boolean) {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf(
                "op" to "returnToAgent",
                "receiptID" to receiptId,
                "continueTask" to continueTask.toString(),
            ))
        }

        override fun consumePendingPanelRequest() {
            host.scope.launch(host.ioDispatcher) { consumePanelRequestOffMain() }
        }
        private fun consumePanelRequestOffMain() {
            if (!isBindingCurrent()) return
            val reply = ByteArray(4096)
            val query = buildString {
                append("{\"op\":\"consumePanelRequest\",\"taskID\":\"")
                    .append(escape(taskId)).append("\",\"rootEpoch\":\"").append(rootEpoch).append("\"}")
            }
            val size = runCatching { BrowserNative.uiQuery(query, reply, 2_000) }.getOrDefault(-1)
            if (size <= 0) return
            val text = BrowserNative.replyText(reply, size) ?: return
            val present = runCatching { json.parseToJsonElement(text).jsonObject.boolean("present") }
                .getOrNull() ?: false
            if (present) {
                main.post {
                    attention.update { it - taskKey(taskId) }
                    bindingFor(taskId)?.presenter?.acknowledgeAttention()
                }
                // Fresh projection follows the same transition natively; the
                // route only needs the acknowledgment above.
                val projectionReply = ByteArray(262_144)
                val projectionQuery = buildString {
                    append("{\"op\":\"projection\",\"taskID\":\"").append(escape(taskId)).append("\",\"rootEpoch\":\"").append(rootEpoch).append("\"}")
                }
                val projectionSize = runCatching {
                    BrowserNative.uiQuery(projectionQuery, projectionReply, 2_000)
                }.getOrDefault(-1)
                if (projectionSize > 0) {
                    BrowserNative.replyText(projectionReply, projectionSize)?.let {
                        bindingFor(taskId)?.deliverProjection(it)
                    }
                }
            }
        }

        override fun dismissPanel() {
            if (!isBindingCurrent()) return
            ownedUICall( mapOf("op" to "dismissPanel"))
        }

        private fun isBindingCurrent(): Boolean {
            val current = bindingFor(taskId) ?: return false
            return current.workspaceID == workspaceId && current.epoch == rootEpoch &&
                host.commandClient.generation() == generation
        }
    }

    // MARK: - BrowserServiceHooks (JSON builders; wire shape = Swift Codable)

    private inner class TaskHooks(private val taskId: String, private val epoch: Long, private val generation: Long) : BrowserServiceHooks {
        private fun current(): Boolean = boundNativeEpoch == epoch && host.nativeRootEpoch() == epoch &&
            host.commandClient.generation() == generation && bindingFor(taskId)?.epoch == epoch
        override fun policyAllowsSync(tabId: String, url: String, isMainFrame: Boolean): Boolean {
            if (!current()) return false
            val request = buildString {
                append("{\"url\":\"").append(escape(url)).append("\",\"taskID\":\"")
                    .append(escape(taskId)).append("\",\"rootEpoch\":\"").append(epoch)
                    .append("\",\"isMainFrame\":").append(isMainFrame).append('}')
            }
            return runCatching { BrowserNative.policyAllows(request) }.getOrDefault(0) == 1
        }

        override fun lifecycleEventJson(kind: String, tabId: String): String = when (kind) {
            "loadStarted" -> "{\"loadStarted\":{\"tabID\":\"${escape(tabId)}\"}}"
            else -> "{\"loadCommitted\":{\"tabID\":\"${escape(tabId)}\"}}"
        }

        override fun lifecycleFinishedJson(tabId: String, url: String?, title: String?): String =
            buildString {
                append("{\"loadFinished\":{\"tabID\":\"").append(escape(tabId))
                append("\",\"url\":\"").append(escape(url ?: ""))
                append("\",\"title\":\"").append(escape(title ?: ""))
                append("\"}}")
            }

        override fun lifecycleFailedJson(
            tabId: String, domain: String, code: Int, description: String,
        ): String = buildString {
            append("{\"loadFailed\":{\"tabID\":\"").append(escape(tabId))
            append("\",\"errorDomain\":\"").append(escape(domain))
            append("\",\"errorCode\":").append(code)
            append(",\"errorDescription\":\"").append(escape(description))
            append("\"}}")
        }

        override fun requestPopup(tabId: String, requestId: String, url: String) {
            if (!current()) return
            val binding = bindingFor(taskId) ?: return
            binding.service.requestPopupDecision(requestId, tabId, url)
        }

        override fun downloadQueryJson(
            tabId: String, url: String, userAgent: String, contentDisposition: String,
            mimeType: String, contentLength: Long,
        ): String = buildString {
            append("{\"tabID\":\"").append(escape(tabId))
            append("\",\"url\":\"").append(escape(url))
            append("\",\"userAgent\":\"").append(escape(userAgent))
            append("\",\"contentDisposition\":\"").append(escape(contentDisposition))
            append("\",\"mimeType\":\"").append(escape(mimeType))
            append("\",\"contentLength\":").append(contentLength)
            append('}')
        }
    }

    // MARK: - projection decoding (Swift BrowserProjection JSON)

    private fun parseProjection(
        text: String,
        ownerTask: String,
        ownerWorkspace: String,
        ownerEpoch: Long,
    ): BrowserProjectionSnapshot {
        val fields = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            ?: return emptySnapshot(ownerTask, ownerWorkspace, ownerEpoch)
        val surfaceKind: String
        val surfaceDetail: String?
        when (val surface = fields["surfaceState"]) {
            is JsonPrimitive -> {
                surfaceKind = surface.content
                surfaceDetail = null
            }
            is JsonObject -> {
                val entry = surface.entries.firstOrNull()
                surfaceKind = entry?.key ?: "unbound"
                surfaceDetail = (entry?.value as? JsonPrimitive)?.contentOrNullSafe()
            }
            else -> {
                surfaceKind = "unbound"
                surfaceDetail = null
            }
        }
        val presentation = fields["presentationRequest"] as? JsonObject
        val handoff = fields["handoff"] as? JsonObject
        val tabs = (fields["tabs"] as? JsonArray)?.mapNotNull { element ->
            val row = element as? JsonObject ?: return@mapNotNull null
            val id = row.string("id") ?: return@mapNotNull null
            BrowserTabRow(
                id = id,
                url = row.string("url") ?: "",
                title = row.string("title") ?: "",
                isActive = row.boolean("isActive") ?: false,
            )
        } ?: emptyList()
        val visible = fields.string("visibleTaskID")
        return BrowserProjectionSnapshot(
            ownerTaskId = ownerTask,
            ownerWorkspaceId = ownerWorkspace,
            ownerRootEpoch = ownerEpoch,
            visibleTaskId = visible,
            presentationShow = presentation?.boolean("show"),
            presentationId = if (presentation?.string("conversationID") == ownerTask)
                presentation.string("id") else null,
            handoffReceiptId = handoff?.string("id"),
            handoffReturning = handoff?.boolean("returning") ?: false,
            handoffNeedsContinue = fields.boolean("handoffNeedsContinue") ?: false,
            handoffNotified = fields.boolean("handoffNotified") ?: false,
            handoffError = fields.string("handoffError"),
            returningControl = fields.boolean("returningControl") ?: false,
            surfaceStateKind = surfaceKind,
            surfaceStateDetail = surfaceDetail,
            tabs = tabs,
            activeTabId = fields.string("activeTabID"),
            isUserControlling = fields.boolean("isUserControlling") ?: false,
            addressText = fields.string("addressText") ?: "",
            isEditingAddress = fields.boolean("isEditingAddress") ?: false,
            technicalAddress = fields.string("technicalAddress"),
            isDisplayingLocalPreview = fields.boolean("isDisplayingLocalPreview") ?: false,
        )
    }

    private fun emptySnapshot(task: String, workspace: String, epoch: Long) =
        BrowserProjectionSnapshot(
            ownerTaskId = task,
            ownerWorkspaceId = workspace,
            ownerRootEpoch = epoch,
            visibleTaskId = null,
            presentationShow = null,
            presentationId = null,
            handoffReceiptId = null,
            handoffReturning = false,
            handoffNeedsContinue = false,
            handoffNotified = false,
            handoffError = null,
            returningControl = false,
            surfaceStateKind = "unbound",
            surfaceStateDetail = null,
            tabs = emptyList(),
            activeTabId = null,
            isUserControlling = false,
            addressText = "",
            isEditingAddress = false,
            technicalAddress = null,
            isDisplayingLocalPreview = false,
        )

    // MARK: - small helpers

    private fun postUICall(taskID: String, fields: Map<String, String>): Boolean {
        val builder = StringBuilder("{\"taskID\":\"").append(escape(taskID)).append('"')
        if ("rootEpoch" !in fields) builder.append(",\"rootEpoch\":\"").append(boundNativeEpoch).append('"')
        fields.forEach { (key, value) ->
            builder.append(',').append('"').append(escape(key)).append("\":\"")
                .append(escape(value)).append('"')
        }
        builder.append('}')
        return runCatching { BrowserNative.uiCall(builder.toString()) == 0 }.getOrDefault(false)
    }

    private fun stopAllTransports(joinMillis: Long): Boolean {
        transports.values.toList().forEach { handle ->
            if (handle.transport.stop(joinMillis)) transports.remove(handle.leaseID, handle)
        }
        return transports.isEmpty()
    }

    private fun codeBytes(code: String): ByteArray =
        ("{\"code\":\"" + escape(code) + "\"}").toByteArray(Charsets.UTF_8)

    private fun escape(value: String): String = buildString {
        for (character in value) {
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append("\\u").append(String.format("%04x", character.code))
                } else {
                    append(character)
                }
            }
        }
    }

    private fun encodeState(state: RendererTabState): String = buildString {
        append('{')
        append("\"url\":").append(state.url?.let { "\"${escape(it)}\"" } ?: "null")
        append(",\"title\":").append(state.title?.let { "\"${escape(it)}\"" } ?: "null")
        append(",\"isLoading\":").append(state.isLoading)
        append(",\"viewportWidth\":").append(state.viewportWidth)
        append(",\"viewportHeight\":").append(state.viewportHeight)
        append(",\"scrollX\":").append(state.scrollX)
        append(",\"scrollY\":").append(state.scrollY)
        append('}')
    }

    private fun encodeScreenshot(shot: RendererScreenshot): String = buildString {
        append('{')
        append("\"jpeg\":\"").append(
            android.util.Base64.encodeToString(shot.jpeg, android.util.Base64.NO_WRAP),
        ).append('"')
        append(",\"pixelWidth\":").append(shot.pixelWidth)
        append(",\"pixelHeight\":").append(shot.pixelHeight)
        append(",\"state\":").append(encodeState(shot.state))
        append('}')
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNullSafe()

    private fun JsonObject.boolean(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.integer(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNullSafe()

    private fun JsonPrimitive.contentOrNullSafe(): String? =
        if (isString) content else null

    private fun JsonPrimitive.intOrNullSafe(): Int? =
        if (!isString) content.toIntOrNull() else null
}
