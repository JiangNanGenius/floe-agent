// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

/**
 * The Application-owned G02 host binding.
 *
 * Exactly one [RuntimeHost] exists per process. It is created by
 * [com.floe.android.FloeApplication] after the RB-1 owned store bootstrap
 * reaches [RuntimeBootstrapCapability.OwnedStoreReady], it reuses the SAME
 * gateway + owner generation the Application already owns (no second
 * runtime/DB/token copy), and it outlives every Activity/Composition.
 * Navigation, rotation, background/lock and recomposition never restart or
 * dispose it; only the Application owner stops it (real drain before the
 * database closes).
 *
 * The host owns the typed domain controllers that map every existing G02
 * feature callback onto canonical native operations and project the async
 * effect/event channels back into the immutable UI states the feature
 * components consume:
 *
 *  * [ProviderHostController] — providers/models/catalogue/preferences;
 *  * [ConversationHostController] — conversation/history/run/temporary;
 *  * [IntegrationsHostController] — Skills/MCP/backend tool discovery;
 *  * [SettingsHostController] — defaults/memory/personalization/usage/privacy;
 *  * [WebSearchHostController] — web-search provider metadata + secure editor;
 *  * [AttachmentImportController] — picker/SAF/staging handoff ownership.
 *
 * Nothing in this package executes business logic natively in Kotlin: the
 * Swift runtime remains the single structural authority; the host only
 * correlates, decodes, budgets, fences and projects.
 */
class RuntimeHost internal constructor(
    val commandClient: RuntimeHostCommandClient,
    internal val gatewayCapability: StateFlow<SecretGatewayCapability>,
    internal val bootstrapCapability: StateFlow<RuntimeBootstrapCapability>,
    internal val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default),
    internal val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val readinessState = MutableStateFlow(RuntimeHostReadiness())
    val readiness: StateFlow<RuntimeHostReadiness> = readinessState

    /** Controllers are created eagerly; they bind as readiness admits. */
    val providers = ProviderHostController(this)
    val conversations = ConversationHostController(this)
    val integrations = IntegrationsHostController(this)
    val gitCredentials = GitHubCredentialHostController(this)
    val settings = SettingsHostController(this)
    val webSearch = WebSearchHostController(this)
    val attachments = AttachmentImportController(this)
    val home = HomeLaunchpadHost(this)

    private var observationJob: Job? = null
    private val started = java.util.concurrent.atomic.AtomicBoolean(false)
    private val configProjectionRefreshed = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * G02 minimal readiness adapter (additive delta): polls the narrow
     * trusted-host native readbacks and republishes the REAL per-domain
     * state through the existing [onDomainAvailability] seam. Null/invalid
     * native answers never manufacture readiness.
     */
    private val g02ReadinessAdapter = G02DomainReadinessAdapter(
        host = this,
        readReadiness = {
            runCatching { com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness() }
                .getOrNull()
        },
        readRootEpoch = {
            runCatching {
                com.floe.android.bridge.RuntimeCoreNative.g02NativeRootEpoch()?.toLongOrNull()
            }.getOrNull() ?: -1L
        },
    )

    /**
     * ACTUAL accepted native Root epoch, or null when no generation is live.
     * Shared trusted-host readback used by the secure-route admission; it
     * NEVER fabricates a 0 and never echoes the UI command generation.
     */
    internal var nativeRootEpochReader: () -> Long? = {
        runCatching {
            com.floe.android.bridge.RuntimeCoreNative.g02NativeRootEpoch()?.toLongOrNull()
        }.getOrNull()?.takeIf { it > 0 }
    }

    fun nativeRootEpoch(): Long? = nativeRootEpochReader()

    /**
     * Privileged privacy-clear confirmation issuer injected by the
     * Application owner. The implementation resolves the live coordinator's
     * ACCEPTED epoch + owner token and the native ingress; the owner token
     * never enters this class's state, a log or the wire. [expectedNativeEpoch]
     * is the exact accepted Root epoch the App bound to the immutable user
     * preview — a stale/foreign epoch is refused by the owner, never minted.
     * Must be invoked off the main thread.
     */
    internal var privacyConfirmationIssuer:
        ((expectedNativeEpoch: Long, operation: String, previewDigest: String,
          invocationID: String, action: String) -> String?)? = null

    fun issuePrivacyConfirmation(
        expectedNativeEpoch: Long,
        operation: String,
        previewDigest: String,
        invocationID: String,
        action: String,
    ): String? = privacyConfirmationIssuer?.invoke(
        expectedNativeEpoch, operation, previewDigest, invocationID, action)

    /** Called once by the Application owner, off-main. */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        observationJob = scope.launch(ioDispatcher) { observeCapabilities() }
        providers.start()
        conversations.start()
        integrations.start()
        gitCredentials.start()
        attachments.start()
        settings.start()
        webSearch.start()
        home.start()
    }

    /**
     * Real shutdown: controllers drain their pumps first (generation bump
     * disposes matching collectors only), then the caller proceeds with the
     * RB-1 owner stop. The host never cancels another owner's work.
     */
    suspend fun stop() {
        commandClient.bumpGeneration()
        providers.stop()
        conversations.stop()
        integrations.stop()
        gitCredentials.stop()
        attachments.stop()
        settings.stop()
        webSearch.stop()
        home.stop()
        observationJob?.cancel()
    }

    private suspend fun observeCapabilities() {
        // Gateway fact.
        gatewayCapability.collect { capability ->
            val gateway = when (capability) {
                is SecretGatewayCapability.Loading ->
                    RuntimeHostReadiness.GatewayReadiness.Loading
                is SecretGatewayCapability.Ready ->
                    RuntimeHostReadiness.GatewayReadiness.Ready
                is SecretGatewayCapability.Failed ->
                    RuntimeHostReadiness.GatewayReadiness.Failed(capability.reason)
            }
            update { it.copy(gateway = gateway) }
        }
    }

    /** The bootstrap capability drives store + domain readiness truth. */
    internal fun onBootstrapCapability(value: RuntimeBootstrapCapability) {
        when (value) {
            is RuntimeBootstrapCapability.Idle ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.Idle) }
            is RuntimeBootstrapCapability.WaitingGateway ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.WaitingGateway) }
            is RuntimeBootstrapCapability.Starting ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.Starting(value.receipt)) }
            is RuntimeBootstrapCapability.OwnedStoreReady -> {
                update {
                    it.copy(
                        store = RuntimeHostReadiness.StoreReadiness.OwnedStoreReady,
                        // Configuration surfaces become usable at store
                        // readiness; never gated on a synthetic "AI ready".
                        domains = it.domains + ("providerConfigurationDomain" to available()),
                    )
                }.also { refreshConfigurationProjections() }
                // G02: republish the REAL native domain readiness (handler
                // registry + composition constructors), not source optimism.
                g02ReadinessAdapter.pollAndPublish()
            }
            is RuntimeBootstrapCapability.Failed ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.Failed(value.reason)) }
            is RuntimeBootstrapCapability.Stopped -> {
                update {
                    it.copy(
                        store = RuntimeHostReadiness.StoreReadiness.Stopped,
                        domains = it.domains.mapValues { blocked(listOf("storeStopped")) },
                    )
                }
                g02ReadinessAdapter.reset()
            }
        }
    }

    /**
     * Domain availability is reported by the REAL native handler registry
     * (status readback), never assumed. The bootstrap coordinator's typed
     * admission carries the authoritative missing-bindings list; as the
     * owning packages land, the Swift side flips domains to registered and
     * the App host records truthful availability for the CURRENT generation.
     */
    internal fun onDomainAvailability(domain: String, available: Boolean, missing: List<String>) {
        update {
            it.copy(
                domains = it.domains + (
                    domain to if (available) {
                        RuntimeHostReadiness.DomainReadiness.Available(commandClient.generation())
                    } else {
                        RuntimeHostReadiness.DomainReadiness.Blocked(missing)
                    }
                    ),
            )
        }
        // Settings summaries are owned by their OWN settings domain, not by
        // provider-configuration readiness. A domain that only becomes
        // available AFTER the one-shot settings.start() must still load its
        // surface; this transition is the late-admission owner. The adapter
        // publishes CHANGED states only, so this is not a poll loop.
        if (available) settings.onSettingsDomainAvailable(domain)
        refreshConfigurationProjections()
    }

    /**
     * One-shot re-read of the narrow native domain-readiness snapshot.
     *
     * Used by a user-visible Settings page open to recover when the initial
     * `OwnedStoreReady` snapshot could not be published (JNI/readback race):
     * the adapter's normal trigger is the bootstrap capability transition, so
     * a first poll that returned null/unknown would otherwise leave every
     * settings surface unadmitted for the rest of the process. This performs
     * exactly one bounded readback and publishes real transitions only; it is
     * never a timer/poll loop. Must run off the main thread.
     */
    internal suspend fun refreshDomainReadiness() {
        g02ReadinessAdapter.pollAndPublish()
    }

    /**
     * The controllers' start() ran before the store was ready and gated out;
     * when configuration admission first becomes true the REAL projections
     * must be read once or the composer/launchpad never sees a model (F1
     * cold-start gap). Exactly-once per admission epoch — the reads are
     * idempotent, and repeating them on every domain flip would only add
     * noise to unrelated surfaces.
     */
    private fun refreshConfigurationProjections() {
        if (!readiness.value.providerConfigurationAdmitted) return
        if (!configProjectionRefreshed.compareAndSet(false, true)) return
        providers.refreshProviders()
        settings.refreshPreferences()
        conversations.refreshModels()
    }

    private fun available() = RuntimeHostReadiness.DomainReadiness.Available(
        commandClient.generation())

    private fun blocked(missing: List<String>) =
        RuntimeHostReadiness.DomainReadiness.Blocked(missing)

    private inline fun update(transform: (RuntimeHostReadiness) -> RuntimeHostReadiness) {
        readinessState.value = transform(readinessState.value)
    }

    // ---------------------------------------------------- host affordances

    /** Application context, set once by the owner at creation. */
    lateinit var appContext: android.content.Context
        internal set

    /** Share text through the platform share sheet (off the UI thread). */
    internal fun shareText(text: String, mimeType: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(android.content.Intent.EXTRA_TEXT, text)
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /** Open a public-web URL in the browser (temporary-ceiling-safe). */
    internal fun openWebUrl(url: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val intent = android.content.Intent(
                android.content.Intent.ACTION_VIEW,
                android.net.Uri.parse(url),
            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /** Copy text to the clipboard. */
    internal fun copyToClipboard(text: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val manager = appContext.getSystemService(
                android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            manager.setPrimaryClip(
                android.content.ClipData.newPlainText("floe", text))
            true
        } catch (t: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------ operations

    /** One independently owned reader per logical page request. Provider,
     * role and conversation reads must never supersede one another. */
    internal fun readModelPage(
        providerID: String?,
        cursor: String?,
        correlationTag: String = "mlist",
        isCurrent: () -> Boolean = { true },
        onOutcome: (HostOperationOutcome) -> Unit,
    ) {
        ModelPageReadController(this).readPage(
            providerID, cursor, correlationTag, isCurrent, onOutcome)
    }


    /**
     * Submit + track one canonical operation to its terminal. [onTerminal]
     * is invoked exactly once with the typed outcome; the correlation is
     * closed on every path. Failures are typed — never secrets, raw paths
     * or exception text.
     *
     * [onAccepted] (optional, default null = no behavior change for existing
     * callers) fires exactly once with the REAL mailbox-issued
     * `operationReceiptID` the moment the queue admits the envelope — before
     * the effect stream opens. Long-running cancellable operations
     * (personalization generate, memory organize) retain this receipt so an
     * explicit user cancel can address the actual active operation by
     * reusing the original correlation; a UI dismissal or request id is
     * never presented as a domain receipt. Terminal-once delivery and
     * effect ownership are unchanged.
     */
    internal fun trackOperation(
        request: HostCommandRequest,
        onFrame: (HostEffectFrame) -> Unit = { },
        onAccepted: ((String) -> Unit)? = null,
        onTerminal: (HostOperationOutcome) -> Unit,
    ) {
        scope.launch(ioDispatcher) {
            when (val submitted = commandClient.submit(request)) {
                is HostSubmitResult.Accepted -> {
                    onAccepted?.invoke(submitted.operationReceiptID)
                    commandClient.openEffectStream(
                        operationReceiptID = submitted.operationReceiptID,
                        configurationScope = request.configurationScope ?: "system",
                        onFrame = onFrame,
                        onTerminal = { terminal ->
                            logRunFailureMetadata(request, terminal)
                            commandClient.closeCorrelation(request.correlationID)
                            onTerminal(terminal.toOperationOutcome())
                        },
                        onFailure = { failure ->
                            logRunPumpFailureMetadata(request, failure)
                            commandClient.closeCorrelation(request.correlationID)
                            onTerminal(failure.toOperationOutcome())
                        },
                    )
                }
                is HostSubmitResult.Rejected -> {
                    logRunSubmitRefusal(request, submitted.reason)
                    onTerminal(HostOperationOutcome.Rejected(submitted.reason, submitted.reason))
                }
                HostSubmitResult.Superseded -> onTerminal(HostOperationOutcome.Superseded)
            }
        }
    }

    // ---------------------------------------------------- run.start diagnostics

    /**
     * DEBUG-only redacted refusal metadata for `run.start`. The generic UI
     * only shows the outer typed code; the REAL root-cause lives in the
     * effect detail (wire/code/reason/binding/phase/expected/actual) which
     * [HostEffectTerminal.toOperationOutcome] intentionally does not carry
     * into ordinary UI. This fixed-tag line is the safe diagnostic channel:
     * whitelisted structural keys only, credential-pattern redaction, bounded
     * strings, never the request/payload/headers/key. No-op in release.
     */
    private fun logRunFailureMetadata(request: HostCommandRequest, terminal: HostEffectTerminal) {
        if (request.command != "run.start" && request.command != "run.startTask") return
        if (!com.floe.android.BuildConfig.DEBUG) return
        val code: String
        val reason: String
        val detail: Map<String, String>
        when (terminal) {
            is HostEffectTerminal.Rejected -> {
                code = terminal.code
                reason = terminal.reason
                detail = terminal.detail
            }
            is HostEffectTerminal.Failed -> {
                code = terminal.code
                reason = terminal.reason
                detail = terminal.detail
            }
            else -> return
        }
        emitRunFailureLine(code, reason, detail)
    }

    private fun logRunPumpFailureMetadata(request: HostCommandRequest, failure: HostPumpFailure) {
        if (request.command != "run.start" && request.command != "run.startTask") return
        if (!com.floe.android.BuildConfig.DEBUG) return
        when (failure) {
            is HostPumpFailure.Recoverable ->
                emitRunFailureLine(failure.code, failure.reason, emptyMap())
            HostPumpFailure.Superseded ->
                emitRunFailureLine("superseded", "superseded", emptyMap())
        }
    }

    private fun logRunSubmitRefusal(request: HostCommandRequest, reason: String) {
        if (request.command != "run.start" && request.command != "run.startTask") return
        if (!com.floe.android.BuildConfig.DEBUG) return
        emitRunFailureLine(reason, reason, emptyMap())
    }

    private fun emitRunFailureLine(
        code: String,
        reason: String,
        detail: Map<String, String>,
    ) {
        runCatching {
            android.util.Log.e("FloeRunFailure", buildString {
                append("op=run.start")
                append(" code=").append(boundedDiagnostic(code))
                append(" reason=").append(boundedDiagnostic(reason))
                for (key in RUN_FAILURE_DETAIL_KEYS) {
                    val raw = detail[key] ?: continue
                    append(' ').append(key).append('=')
                        .append(redactDiagnosticValue(raw))
                }
            })
        }
    }

    /** Bounded, credential-redacted diagnostic value (never user payload). */
    private fun redactDiagnosticValue(raw: String): String {
        val bounded = boundedDiagnostic(raw)
        return CREDENTIAL_PATTERN.replace(bounded, "[redacted]")
    }

    private fun boundedDiagnostic(raw: String): String =
        if (raw.length <= 128) raw else raw.take(128) + "…"

    companion object {
        /** Structural refusal metadata only — never echo the goal/payload. */
        private val RUN_FAILURE_DETAIL_KEYS = listOf(
            "wire", "code", "reason", "binding", "phase",
            "expected", "actual", "expectedState", "runState",
            "storePrimary", "storeExtended",
        )

        private val CREDENTIAL_PATTERN = Regex(
            "(?i)(api[_-]?key|secret|token|authorization|bearer|sk-[a-z0-9]{6,})",
        )

        /** Production factory; performs no native or disk work. */
        fun create(
            context: android.content.Context,
            gatewayCapability: StateFlow<SecretGatewayCapability>,
            bootstrapCapability: StateFlow<RuntimeBootstrapCapability>,
        ): RuntimeHost = RuntimeHost(
            commandClient = RuntimeHostCommandClient.system(),
            gatewayCapability = gatewayCapability,
            bootstrapCapability = bootstrapCapability,
        ).also { it.appContext = context.applicationContext ?: context }
    }
}

sealed interface HostOperationOutcome {
    /**
     * A settled completion. [value] is the typed value/page document; [detail]
     * stays the bounded identifier/reason map the native terminal carried
     * (e.g. a queue acceptance's real `inputID`/`position`). Identifier-only
     * commands legitimately have `value == null` and a populated detail.
     */
    data class Completed(
        val value: JsonElement?,
        val detail: Map<String, String> = emptyMap(),
    ) : HostOperationOutcome
    data class Rejected(val code: String, val reason: String) : HostOperationOutcome
    data class Failed(
        val code: String,
        val reason: String,
        /**
         * Bounded structural detail the native terminal carried (e.g. the
         * domain `wire` code). Diagnostic-only; ordinary UI keeps showing
         * the settlement class and uses this solely to map a typed,
         * user-actionable privacy-clear failure.
         */
        val detail: Map<String, String> = emptyMap(),
    ) : HostOperationOutcome
    data object Cancelled : HostOperationOutcome
    data object Superseded : HostOperationOutcome
}

private fun HostEffectTerminal.toOperationOutcome(): HostOperationOutcome = when (this) {
    is HostEffectTerminal.Completed -> HostOperationOutcome.Completed(value, detail)
    is HostEffectTerminal.Rejected -> HostOperationOutcome.Rejected(code, reason)
    is HostEffectTerminal.Failed -> HostOperationOutcome.Failed(code, reason, detail)
    is HostEffectTerminal.Cancelled -> HostOperationOutcome.Cancelled
    is HostEffectTerminal.Closed -> HostOperationOutcome.Completed(null, detail)
    is HostEffectTerminal.Replaced -> HostOperationOutcome.Superseded
}

private fun HostPumpFailure.toOperationOutcome(): HostOperationOutcome = when (this) {
    is HostPumpFailure.Recoverable -> HostOperationOutcome.Failed(code, reason)
    HostPumpFailure.Superseded -> HostOperationOutcome.Superseded
}
