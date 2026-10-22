// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import com.floe.android.bridge.PrivacyConfirmationNative
import com.floe.android.bridge.ProviderCatalogNative
import com.floe.android.bridge.RuntimeCoreNative
import com.floe.android.bridge.RuntimeNativeException
import com.floe.android.bridge.SecurityCorpusNative
import com.floe.android.bridge.SwiftCore
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Application-owned runtime bootstrap capability. These are SEPARATE typed
 * facts from the gateway's own Loading/Ready/Failed flow (which is
 * preserved):
 *  * [Idle] — not started.
 *  * [WaitingGateway] — the real native runtime may only register after the
 *    actual gateway Ready plus a credential.status readback.
 *  * [Starting] — the trusted host start was accepted; carries the opaque
 *    bootstrap operation receipt.
 *  * [OwnedStoreReady] — the Swift owner committed the original store
 *    bootstrap (effect terminal `accepted` + status readback agree). This
 *    is NOT domain/runtime readiness.
 *  * [Failed] — typed reason codes only (never a path, token or byte).
 *  * [Stopped] — real drain + database close completed.
 */
sealed class RuntimeBootstrapCapability {
    data object Idle : RuntimeBootstrapCapability()
    data object WaitingGateway : RuntimeBootstrapCapability()
    data class Starting(val receipt: String) : RuntimeBootstrapCapability()
    data object OwnedStoreReady : RuntimeBootstrapCapability()
    data class Failed(val reason: String) : RuntimeBootstrapCapability()
    data object Stopped : RuntimeBootstrapCapability()
}

/**
 * Ordinary runtime admission is a typed barrier, not a bool. RB1 can only
 * ever report [Blocked] with the REAL missing bindings until the owning
 * packages (RB2/RB2b/RB3/RB4/RB5/RB6 + transport qualification) are
 * accepted by Main. There is deliberately no `Available` state at this
 * stage: a nil/no-op credential normalizer or placeholder vault must never
 * make the runtime "appear ready".
 */
sealed class RuntimeDomainAdmission {
    data class Blocked(val missingBindings: List<String>) : RuntimeDomainAdmission()
}

internal data class RuntimeBootstrapTimings(
    val effectPollIntervalMillis: Long = 50,
    val bootstrapDeadlineMillis: Long = 30_000,
    val shutdownDeadlineMillis: Long = 15_000,
)

internal interface RuntimeNativeApi {
    fun ensureLoaded()
    fun runtimeOwnerStart(rootPath: String, ownerToken: String, epoch: Long): String
    /** RB1-R5: stop requires the accepted owner epoch + token. */
    fun runtimeOwnerStop(ownerEpoch: Long, ownerToken: String): String
    fun runtimeStatus(): String?
}

internal interface RuntimeBridgeExchange {
    fun exchange(request: String): String
}

/**
 * Privileged privacy-confirmation ingress seam (R2-A). The production
 * implementation calls [PrivacyConfirmationNative.issue] exactly once per
 * explicit user confirmation; component tests substitute a recording double
 * so the owner-proof/epoch gate is testable without JNI. The owner token is
 * passed to this boundary ONLY; it never enters the return value, a log or
 * any stored state.
 */
internal fun interface PrivacyConfirmationIngress {
    fun issue(
        ownerEpoch: Long,
        ownerToken: String,
        operation: String,
        previewDigest: String,
        invocationID: String,
        action: String,
    ): String?
}

private object SystemPrivacyConfirmationIngress : PrivacyConfirmationIngress {
    override fun issue(
        ownerEpoch: Long,
        ownerToken: String,
        operation: String,
        previewDigest: String,
        invocationID: String,
        action: String,
    ): String? = PrivacyConfirmationNative.issue(
        ownerEpoch, ownerToken, operation, previewDigest, invocationID, action)
}

/**
 * Trusted security-corpus handoff (corpus-first repair). The App reads the
 * packaged `security/catastrophic-patterns.json` asset and freezes its bytes
 * into the native Root BEFORE the Root start, so the production
 * RunIngressContext carries the REAL trusted corpus. Returns the native
 * typed status (0 ok / 1 idempotent / negative typed refusal); the bytes and
 * their digest never enter this interface, a log or a command.
 */
internal fun interface RuntimeSecurityCorpusInstaller {
    fun installCorpus(): Int
}

/**
 * Trusted official provider-catalog handoff. The App reads the packaged,
 * reviewed `provider/ProviderCatalog.json` asset (an exact copy of the
 * original iOS trusted resource) and freezes its bytes into the native Root
 * BEFORE the Root start; the ordinary bootstrap install then injects them
 * into the ORIGINAL provider domain (`ModelConfigurationFacade` catalog slot,
 * original `ProviderCatalogIndex` decoder). Returns the native typed status
 * (0 ok / 1 idempotent / negative typed refusal); the document's bytes never
 * enter this interface, a log or a command. A null/refused freeze leaves
 * catalog commands at their honest typed `catalogNotInjected` refusal and
 * never fabricates an official catalog.
 */
internal fun interface RuntimeProviderCatalogFreezer {
    fun freezeCatalog(): Int
}

/**
 * Production adapter. Its initialization does not touch
 * [RuntimeCoreNative]; the object class-init (and therefore
 * System.loadLibrary) runs only on the first off-main method call — the
 * same reviewed pattern as the gateway dispatcher.
 */
private object SystemRuntimeNative : RuntimeNativeApi {
    override fun ensureLoaded() {
        RuntimeCoreNative.hashCode()
    }
    override fun runtimeOwnerStart(rootPath: String, ownerToken: String, epoch: Long) =
        RuntimeCoreNative.runtimeOwnerStart(rootPath, ownerToken, epoch)
    override fun runtimeOwnerStop(ownerEpoch: Long, ownerToken: String) =
        RuntimeCoreNative.runtimeOwnerStop(ownerEpoch, ownerToken)
    override fun runtimeStatus() = RuntimeCoreNative.runtimeStatus()
}

private object SystemBridgeExchange : RuntimeBridgeExchange {
    override fun exchange(request: String) = SwiftCore.exchange(request)
}

/**
 * One Application-process coordinator for the RB-1 native runtime bootstrap.
 *
 * Rules honored here (RB1 handoff + Main wire/lifecycle repair):
 *  * no native load, no disk, no Keystore and no exchange inside property
 *    initialization or Application.onCreate main — [start] only launches
 *    off-main work;
 *  * the real native runtime registers ONLY after the gateway flow is Ready
 *    AND an actual `credential.status` readback confirms registration;
 *  * the trusted root is derived from the host Context (app-private) and
 *    the owner token is process-local random hex — neither is model- or
 *    tool-selectable data and neither enters prompts/logs;
 *  * outcomes are learned through the v3 `effect.poll` channel (the same
 *    bounded mailbox receipts the Swift side owns), never by blocking;
 *  * every bridge/status response is decoded with the pinned structured
 *    JSON library and requires exact schema/version/requestID/correlation/
 *    receipt/generation types — no Regex or string-coercion parsing;
 *  * RB1-R5: a transition token fences late bootstrap results after a stop
 *    request; stop passes the exact accepted epoch + token captured at
 *    start, so a stale coordinator can never stop a newer owner;
 *  * shutdown is a real drain: a typed timeout keeps ownership and remains
 *    retryable; success means the database actually closed.
 */
class RuntimeBootstrapCoordinator internal constructor(
    private val native: RuntimeNativeApi,
    private val exchange: RuntimeBridgeExchange,
    private val gatewayCapability: StateFlow<SecretGatewayCapability>,
    private val rootProvider: suspend () -> String,
    private val ownerTokenProvider: () -> String,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val timings: RuntimeBootstrapTimings = RuntimeBootstrapTimings(),
    private val diagnostics: (String) -> Unit = {},
    /**
     * Trusted bundled-corpus installer. Production always supplies it (the
     * packaged asset read + native freeze); a null installer keeps the
     * coordinator's historical behavior for component tests whose concern is
     * the lifecycle itself (the run gate then refuses corpusAbsent, honestly).
     */
    private val corpusInstaller: RuntimeSecurityCorpusInstaller? = null,
    /**
     * Trusted official-catalog freezer. Production supplies the packaged
     * asset read + native freeze; null keeps component-test behavior (the
     * provider catalog then truthfully answers `catalogNotInjected`).
     */
    private val catalogFreezer: RuntimeProviderCatalogFreezer? = null,
    /**
     * Privileged privacy-confirmation ingress. Production supplies the JNI
     * call; component tests substitute a double. The owner token only ever
     * crosses this boundary.
     */
    private val privacyIngress: PrivacyConfirmationIngress =
        SystemPrivacyConfirmationIngress,
    private val capabilityState: MutableStateFlow<RuntimeBootstrapCapability> =
        MutableStateFlow(RuntimeBootstrapCapability.Idle),
    private val admissionState: MutableStateFlow<RuntimeDomainAdmission> =
        MutableStateFlow(RuntimeDomainAdmission.Blocked(STATIC_MISSING_BINDINGS)),
) {
    val capability: StateFlow<RuntimeBootstrapCapability> = capabilityState
    val domainAdmission: StateFlow<RuntimeDomainAdmission> = admissionState

    /**
     * Mint ONE privileged privacy-clear capability for the LIVE accepted
     * Root generation. Called ONLY from an explicit confirmation tap, OFF the
     * main thread. [expectedNativeEpoch] is the ACTUAL accepted RuntimeBootstrap
     * epoch the App captured with the summary preview (never a UI counter and
     * never a fabricated 0): the accepted epoch + owner token are read
     * ATOMICALLY under [stateLock] and the mint is refused when the expected
     * epoch does not match, a stop was requested or the owner proof is known
     * invalid. The JNI call itself runs outside the lock; the native ingress
     * re-validates the full owner proof and the exact
     * operation/digest/invocation/action binding before minting the opaque
     * `pc:v1:` capability. The owner token is never stored, logged or
     * returned. Null means the App must surface an honest
     * confirmation-unavailable refusal; nothing was authorized and nothing is
     * submitted.
     */
    fun issuePrivacyConfirmation(
        expectedNativeEpoch: Long,
        operation: String,
        previewDigest: String,
        invocationID: String,
        action: String,
    ): String? {
        val epoch: Long
        val token: String
        synchronized(stateLock) {
            if (stopRequested || ownerProofInvalid) return null
            val accepted = acceptedEpoch ?: return null
            if (accepted != expectedNativeEpoch) return null
            epoch = accepted
            token = acceptedToken ?: return null
        }
        return try {
            privacyIngress.issue(
                epoch, token, operation, previewDigest, invocationID, action)
        } catch (t: Throwable) {
            // Typed numeric statuses and defensive nulls collapse to one
            // honest App answer: confirmation unavailable, no capability.
            null
        }
    }

    private val started = AtomicBoolean(false)
    private val epochCounter = AtomicLong(0)
    private val pollCounter = AtomicLong(0)

    /** Fences every publish behind the current start/stop transition. */
    private val transitionToken = AtomicLong(0)
    private val stateLock = Any()
    private val startStopMutex = Mutex()

    @Volatile private var stopRequested = false
    @Volatile private var ownerProofInvalid = false
    /** Proof captured only from a successful trusted start (RB1-R5). */
    @Volatile private var acceptedEpoch: Long? = null
    @Volatile private var acceptedToken: String? = null
    @Volatile private var bootstrapJob: Job? = null
    @Volatile private var bootstrapReceipt: String? = null
    @Volatile private var shutdownReceipt: String? = null

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = false
    }

    /** Called only from the Application owner. Launches off-main work once. */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        bootstrapJob = scope.launch(ioDispatcher) { bootstrap() }
    }

    // MARK: Bootstrap

    internal suspend fun bootstrap() {
        if (stopRequested) return
        val transition = synchronized(stateLock) {
            if (stopRequested) return
            transitionToken.incrementAndGet()
        }
        if (!publish(transition, RuntimeBootstrapCapability.WaitingGateway)) return
        // 1. Wait for the REAL gateway lifecycle (Loading -> Ready/Failed).
        val gateway = gatewayCapability.first {
            it is SecretGatewayCapability.Ready || it is SecretGatewayCapability.Failed
        }
        if (!isCurrent(transition)) return
        if (gateway is SecretGatewayCapability.Failed) {
            publish(transition, RuntimeBootstrapCapability.Failed("gateway_failed"))
            return
        }
        // 2. Actual gateway readback (registry truth inside Swift), typed
        //    structured result only. Ordinary status is NOT bootstrap authority.
        val readbackRaw = try {
            exchange.exchange(
                """{"version":2,"operation":"credential.status","requestID":"rb1-readback"}""")
        } catch (c: CancellationException) {
            return
        } catch (t: Throwable) {
            null
        }
        if (!isCurrent(transition)) return
        when (parseGatewayReadback(readbackRaw, expectedRequestID = "rb1-readback")) {
            GatewayReadback.Registered -> Unit
            GatewayReadback.NotRegistered -> {
                publish(transition, RuntimeBootstrapCapability.Failed("gateway_readback_failed"))
                return
            }
            GatewayReadback.Malformed -> {
                publish(transition, RuntimeBootstrapCapability.Failed("gateway_readback_malformed"))
                return
            }
        }
        // 3. Trusted app-private root + process-local owner token.
        val root = try {
            rootProvider()
        } catch (c: CancellationException) {
            return
        } catch (t: Throwable) {
            publish(transition, RuntimeBootstrapCapability.Failed("root_unavailable"))
            return
        }
        if (!isCurrent(transition)) return
        val token = ownerTokenProvider()
        val epoch = epochCounter.incrementAndGet()
        // 4. Synchronous bounded JNI start under the start/stop mutex. The
        //    accepted proof is recorded before any suspension so a concurrent
        //    shutdown either sees it and stops the owner or never lets the
        //    owner start at all.
        var aborted = false
        val receipt = try {
            startStopMutex.withLock {
                if (stopRequested || !isCurrent(transition)) {
                    aborted = true
                    null
                } else {
                    // Corpus-first: freeze the trusted bundled corpus BEFORE
                    // the Root start so the production RunIngressContext
                    // carries its REAL bytes. This is a trusted host call (no
                    // wire command, no model authority). A refusal is
                    // reported honestly and leaves the corpus absent: the run
                    // gate then keeps its typed `corpusAbsent` refusal before
                    // any model/store effect. Never a fabricated gate.
                    corpusInstaller?.let { installer ->
                        val status = try {
                            installer.installCorpus()
                        } catch (t: Throwable) {
                            null
                        }
                        if (status == null) {
                            diagnostics("security_corpus_unavailable")
                        } else if (status != 0 && status != 1) {
                            diagnostics("security_corpus_freeze_$status")
                        }
                    }
                    // Official provider catalog, same pre-start trusted host
                    // shape: freeze the packaged reviewed document so the
                    // ordinary install injects its EXACT bytes. A refusal is
                    // diagnosed and leaves the catalog absent (the provider
                    // domain keeps its typed catalogNotInjected refusal);
                    // bootstrap itself is never fabricated or aborted here.
                    catalogFreezer?.let { freezer ->
                        val status = try {
                            freezer.freezeCatalog()
                        } catch (t: Throwable) {
                            null
                        }
                        if (status == null) {
                            diagnostics("provider_catalog_unavailable")
                        } else if (status != 0 && status != 1) {
                            diagnostics("provider_catalog_freeze_$status")
                        }
                    }
                    native.ensureLoaded()
                    val value = native.runtimeOwnerStart(root, token, epoch)
                    synchronized(stateLock) {
                        // A successful trusted start created a real owner.
                        // Record its proof even if a concurrent stop fenced
                        // publication: shutdown() must still be able to stop
                        // that owner instead of leaking it.
                        acceptedEpoch = epoch
                        acceptedToken = token
                        if (stopRequested || transitionToken.get() != transition) {
                            aborted = true
                        }
                    }
                    value
                }
            }
        } catch (error: RuntimeNativeException) {
            // Typed numeric status only — never the root or the token.
            publish(transition, RuntimeBootstrapCapability.Failed("owner_start_${error.status}"))
            return
        } catch (c: CancellationException) {
            return
        } catch (t: Throwable) {
            publish(transition, RuntimeBootstrapCapability.Failed("owner_start_unavailable"))
            return
        }
        if (aborted || receipt == null) return
        bootstrapReceipt = receipt
        if (!publish(transition, RuntimeBootstrapCapability.Starting(receipt))) {
            // A stop was requested while the trusted start was in flight.
            // Do not poll or publish; shutdown() holds the accepted proof and
            // is responsible for the real stop.
            return
        }
        // 5. Learn the committed outcome through the bounded effect channel.
        when (val terminal = awaitTerminal(receipt, timings.bootstrapDeadlineMillis,
            transition, stopFences = true)) {
            is PollTerminal.Accepted -> {
                if (!isCurrent(transition)) return
                val statusRaw = try { native.runtimeStatus() } catch (t: Throwable) { null }
                if (!isCurrent(transition)) return
                val status = parseStatus(statusRaw, expectedEpoch = epoch)
                if (status == null) {
                    diagnostics("status_unreadable")
                    publish(transition, RuntimeBootstrapCapability.Failed("store_readback_unreadable"))
                    return
                }
                if (status.domainRuntimeReady) {
                    // Never promote ordinary readiness from a JSON flag.
                    diagnostics("ignoring_domain_ready_claim")
                }
                val admitted = publishAdmission(transition, status.missingBindings)
                if (!admitted) return
                when {
                    status.retiring || status.phase != "starting" ->
                        publish(transition, RuntimeBootstrapCapability.Failed("store_readback_mismatch"))
                    !status.ownedStoreReady || status.ownedStorePhase != "ready" ->
                        publish(transition, RuntimeBootstrapCapability.Failed("store_readback_mismatch"))
                    status.version != STATUS_VERSION ||
                        status.generation != epoch ->
                        publish(transition, RuntimeBootstrapCapability.Failed("store_readback_mismatch"))
                    else -> publish(transition, RuntimeBootstrapCapability.OwnedStoreReady)
                }
            }
            is PollTerminal.Failed -> publish(
                transition,
                RuntimeBootstrapCapability.Failed(
                    "bootstrap_" + terminal.kind + terminal.code?.let { "_$it" }.orEmpty()))
            PollTerminal.Timeout -> {
                if (!isCurrent(transition)) return
                // Honest: the receipt may still settle later; the App
                // instance did not observe the terminal in the window.
                diagnostics("bootstrap_effect_timeout receipt live")
                publish(transition, RuntimeBootstrapCapability.Failed("bootstrap_effect_timeout"))
            }
            is PollTerminal.Unavailable -> {
                if (!isCurrent(transition)) return
                publish(transition,
                    RuntimeBootstrapCapability.Failed("bootstrap_" + terminal.reason))
            }
        }
    }

    /**
     * Real shutdown: fence, drain, database close. A typed timeout KEEPS
     * ownership (the Swift side refuses time-disposal) and the call is
     * retryable; success means [RuntimeBootstrapCapability.Stopped].
     *
     * RB1-R5: the stop call carries the EXACT accepted epoch + owner token.
     * Without accepted-start proof this coordinator never calls native stop,
     * so it cannot stop another instance's owner.
     */
    /** Application transport cleanup; false retains the accepted native owner. */
    @Volatile var localRuntimeDrain: (suspend () -> Boolean)? = null

    suspend fun shutdown(): Boolean {
        if (ownerProofInvalid) return false
        // Fence every late bootstrap publication first; then wait for any
        // in-flight native start to publish its accepted proof.
        synchronized(stateLock) {
            stopRequested = true
            transitionToken.incrementAndGet()
        }
        bootstrapJob?.cancel()
        startStopMutex.withLock { /* barrier only */ }
        if (ownerProofInvalid) return false
        val epoch = acceptedEpoch
        val token = acceptedToken
        if (epoch == null || token == null) {
            publishStopped()
            return true
        }
        if (localRuntimeDrain?.invoke() == false) {
            // A requested stop is not remote-process quiescence. Keep the
            // original root/database owner open so a later drain can finish.
            return false
        }
        val stopReceipt = try {
            native.runtimeOwnerStop(epoch, token)
        } catch (error: RuntimeNativeException) {
            diagnostics("owner_stop_${error.status}")
            when (error.status) {
                -207 -> {
                    clearAcceptedProof()
                    publishStopped()
                    return true
                }
                -203, -204, -205, -210 -> {
                    // The owner changed or is no longer ours. Never claim a
                    // foreign owner was stopped; never retry against it.
                    clearAcceptedProof()
                    ownerProofInvalid = true
                    synchronized(stateLock) {
                        capabilityState.value =
                            RuntimeBootstrapCapability.Failed("owner_stop_stale")
                    }
                    return false
                }
                else -> return false
            }
        } catch (t: Throwable) {
            diagnostics("owner_stop_unavailable")
            return false
        }
        shutdownReceipt = stopReceipt
        return when (val terminal = awaitTerminal(
            stopReceipt, timings.shutdownDeadlineMillis, transitionToken.get(),
            stopFences = false)) {
            is PollTerminal.Accepted -> {
                clearAcceptedProof()
                publishStopped()
                true
            }
            else -> {
                diagnostics("shutdown_${terminal.label}")
                synchronized(stateLock) {
                    capabilityState.value = RuntimeBootstrapCapability.Failed(
                        "shutdown_" + terminal.label)
                }
                false
            }
        }
    }

    // MARK: Transition fencing

    private fun isCurrent(transition: Long, stopFences: Boolean = true): Boolean =
        transitionToken.get() == transition && (!stopFences || !stopRequested)

    private fun publish(transition: Long, value: RuntimeBootstrapCapability): Boolean =
        synchronized(stateLock) {
            if (stopRequested || transitionToken.get() != transition) return false
            capabilityState.value = value
            true
        }

    private fun publishAdmission(transition: Long, missing: List<String>): Boolean =
        synchronized(stateLock) {
            if (stopRequested || transitionToken.get() != transition) return false
            if (missing.isEmpty()) return false
            admissionState.value = RuntimeDomainAdmission.Blocked(missing)
            true
        }

    private fun publishStopped() {
        synchronized(stateLock) {
            admissionState.value =
                RuntimeDomainAdmission.Blocked(STATIC_MISSING_BINDINGS)
            capabilityState.value = RuntimeBootstrapCapability.Stopped
        }
    }

    private fun clearAcceptedProof() {
        synchronized(stateLock) {
            acceptedEpoch = null
            acceptedToken = null
        }
    }

    // MARK: Effect polling (bounded, prompt-returning, typed JSON)

    internal sealed class PollTerminal {
        data class Accepted(val value: JsonElement? = null) : PollTerminal()
        data class Failed(val kind: String, val code: String?) : PollTerminal()
        data object Timeout : PollTerminal()
        data class Unavailable(val reason: String) : PollTerminal()

        val label: String
            get() = when (this) {
                is Accepted -> "accepted"
                is Failed -> kind + (code?.let { "_$it" } ?: "")
                is Timeout -> "effect_timeout"
                is Unavailable -> reason
            }
    }

    private sealed interface GatewayReadback {
        data object Registered : GatewayReadback
        data object NotRegistered : GatewayReadback
        data object Malformed : GatewayReadback
    }

    internal data class EffectItem(
        val sequence: Long,
        val kind: String,
        val code: String?,
        /** Optional typed completed value/result object (final consumer schema). */
        val value: JsonElement? = null,
        /** Optional typed page object (backward-compatible carrier). */
        val page: JsonElement? = null,
    )

    internal sealed interface EffectPageResult {
        data class Page(
            val effects: List<EffectItem>,
            val nextSequence: Long,
            val hasMore: Boolean,
            val resyncRequired: Boolean,
        ) : EffectPageResult
        data class Failure(val reason: String) : EffectPageResult
        data object ProtocolMismatch : EffectPageResult
    }

    private data class StatusSnapshot(
        val version: Int,
        val phase: String,
        val generation: Long,
        val ownedStoreReady: Boolean,
        val ownedStorePhase: String,
        val domainRuntimeReady: Boolean,
        val retiring: Boolean,
        val ordinaryAdmission: String,
        val missingBindings: List<String>,
    )

    private suspend fun awaitTerminal(receipt: String, deadlineMillis: Long,
                                      transition: Long,
                                      stopFences: Boolean): PollTerminal {
        if (!isOpaqueReceipt(receipt)) {
            return PollTerminal.Unavailable("effect_receipt_malformed")
        }
        val deadline = System.nanoTime() + deadlineMillis * 1_000_000L
        var sequence = 0L
        var resyncStreak = 0
        while (System.nanoTime() < deadline) {
            if (!isCurrent(transition, stopFences)) {
                return PollTerminal.Unavailable("superseded")
            }
            val correlation = "rb1-effect-${pollCounter.incrementAndGet()}"
            val request = effectPollEnvelope(correlation, receipt, sequence)
            if (utf8Bytes(request) > MAX_BRIDGE_BYTES) {
                return PollTerminal.Unavailable("effect_request_too_large")
            }
            val response = try {
                exchange.exchange(request)
            } catch (c: CancellationException) {
                return PollTerminal.Unavailable("superseded")
            } catch (t: Throwable) {
                return PollTerminal.Unavailable("exchange_unavailable")
            }
            if (!isCurrent(transition, stopFences)) {
                return PollTerminal.Unavailable("superseded")
            }
            if (response.length > MAX_BRIDGE_BYTES || utf8Bytes(response) > MAX_BRIDGE_BYTES) {
                return PollTerminal.Unavailable("effect_response_too_large")
            }
            when (val parsed = parseEffectPage(response, expectedRequestID = correlation,
                expectedReceipt = receipt, afterSequence = sequence)) {
                is EffectPageResult.Failure -> {
                    return when (parsed.reason) {
                        "effectReceiptNotFound", "effectReceiptExpired" ->
                            PollTerminal.Unavailable(parsed.reason)
                        else -> PollTerminal.Unavailable(
                            "effect_" + sanitizeReason(parsed.reason))
                    }
                }
                EffectPageResult.ProtocolMismatch ->
                    return PollTerminal.Unavailable("effect_protocol_mismatch")
                is EffectPageResult.Page -> {
                    val terminal = parsed.effects.lastOrNull { it.kind in TERMINAL_KINDS }
                    if (terminal != null) {
                        return if (terminal.kind == "accepted") {
                            PollTerminal.Accepted(terminal.value)
                        } else PollTerminal.Failed(terminal.kind, terminal.code)
                    }
                    if (parsed.nextSequence < sequence) {
                        return PollTerminal.Unavailable("effect_cursor_regression")
                    }
                    sequence = parsed.nextSequence
                    if (parsed.resyncRequired) {
                        resyncStreak += 1
                        if (resyncStreak > 3) {
                            return PollTerminal.Unavailable("effect_resync")
                        }
                    } else {
                        resyncStreak = 0
                    }
                    if (!parsed.hasMore || parsed.effects.isEmpty()) {
                        delay(timings.effectPollIntervalMillis)
                    }
                }
            }
        }
        return PollTerminal.Timeout
    }

    /**
     * Builds the EXACT v3 `floe.effect-cursor/3` envelope accepted by the
     * frozen BridgeEnvelopeV3 validator: applicationConfiguration scope,
     * closed `system` configuration label, command effect.poll,
     * stateful=false, opaque receipt + nonnegative sequence, correlationID
     * equal to the requestID.
     */
    private fun effectPollEnvelope(correlation: String, receipt: String,
                                   sequence: Long): String {
        // Escape both opaque values through the structured library; a receipt
        // is never concatenated raw into JSON.
        val correlationJSON = JsonPrimitive(correlation).toString()
        val receiptJSON = JsonPrimitive(receipt).toString()
        return """{"version":3,"operation":"effect.poll","requestID":$correlationJSON,""" +
            """"envelope":{"schema":"floe.effect-cursor/3","scope":"applicationConfiguration",""" +
            """"configurationScope":"system","command":"effect.poll","stateful":false,""" +
            """"correlationID":$correlationJSON,""" +
            """"effect":{"operationReceiptID":$receiptJSON,"sequence":$sequence}}}"""
    }

    // MARK: Structured JSON decoding (pinned kotlinx-serialization-json)

    private fun parseGatewayReadback(raw: String?, expectedRequestID: String): GatewayReadback {
        if (raw == null || raw.length > MAX_BRIDGE_BYTES ||
            utf8Bytes(raw) > MAX_BRIDGE_BYTES) return GatewayReadback.Malformed
        val root = parseObject(raw) ?: return GatewayReadback.Malformed
        if (root.longStrict("version") != 2L) return GatewayReadback.Malformed
        if (root.stringStrict("requestID") != expectedRequestID) return GatewayReadback.Malformed
        if (root.boolStrict("ok") != true) return GatewayReadback.Malformed
        val backend = root.obj("secretBackend") ?: return GatewayReadback.Malformed
        val registered = backend.boolStrict("registered") ?: return GatewayReadback.Malformed
        if (backend.boolStrict("memoryFallback") != false) return GatewayReadback.Malformed
        val availability = backend.stringStrict("availability")
            ?: return GatewayReadback.Malformed
        return if (registered) {
            if (availability != "AVAILABLE") GatewayReadback.Malformed
            else GatewayReadback.Registered
        } else {
            if (availability != "NEEDS_CONFIGURATION") GatewayReadback.Malformed
            else GatewayReadback.NotRegistered
        }
    }

    /**
     * Direct v1 status snapshot (NEVER the v2 credential wrapper and NEVER a
     * v3 handler response). Required types are strict: a JSON string "true"
     * is not a boolean, a string sequence is not a number, and a nested
     * fake-ready flag is never consulted.
     */
    private fun parseStatus(raw: String?, expectedEpoch: Long): StatusSnapshot? {
        if (raw == null || raw.length > MAX_BRIDGE_BYTES ||
            utf8Bytes(raw) > MAX_BRIDGE_BYTES) return null
        val root = parseObject(raw) ?: return null
        val version = root.longStrict("version")?.toInt() ?: return null
        if (version != STATUS_VERSION) return null
        val phase = root.stringStrict("phase") ?: return null
        if (phase !in STATUS_PHASES) return null
        val generation = root.longStrict("generation") ?: return null
        if (generation != expectedEpoch) return null
        val ownedStoreReady = root.boolStrict("ownedStoreReady") ?: return null
        val domainReady = root.boolStrict("domainRuntimeReady") ?: return null
        val retiring = root.boolStrict("retiring") ?: return null
        val ownedStorePhase = root.stringStrict("ownedStorePhase") ?: return null
        val ordinaryAdmission = root.stringStrict("ordinaryRuntimeAdmission") ?: return null
        if (ordinaryAdmission != "blocked") return null
        val missing = root.array("missingBindings") ?: return null
        if (missing.isEmpty()) return null
        val bindings = ArrayList<String>(missing.size)
        for (item in missing) {
            val value = item.stringValue() ?: return null
            if (value !in STATIC_MISSING_BINDINGS) return null
            bindings.add(value)
        }
        // A future status can add fields, but a non-empty capability claim
        // without real bindings is inconsistent with the RB1 barrier.
        val business = root.array("businessCapabilities")
        if (business != null && business.isNotEmpty()) return null
        return StatusSnapshot(
            version = version,
            phase = phase,
            generation = generation,
            ownedStoreReady = ownedStoreReady,
            ownedStorePhase = ownedStorePhase,
            domainRuntimeReady = domainReady,
            retiring = retiring,
            ordinaryAdmission = ordinaryAdmission,
            missingBindings = bindings,
        )
    }

    /**
     * Strict `floe.effect-cursor/3` v3 response. The top-level object is the
     * AndroidBridge response wrapper (`version`, `requestID`) around the
     * handler-returned object (`ok`, `schema`, `correlationID`, `cursor`,
     * `effects`, `hasMore`, `resyncRequired`). Shape mismatches never mark
     * Ready/Stopped and never advance the cursor.
     */
    internal fun parseEffectPage(raw: String, expectedRequestID: String,
                                 expectedReceipt: String,
                                 afterSequence: Long): EffectPageResult {
        val root = parseObject(raw) ?: return EffectPageResult.ProtocolMismatch
        if (root.longStrict("version") != 3L) return EffectPageResult.ProtocolMismatch
        if (root.stringStrict("requestID") != expectedRequestID) {
            return EffectPageResult.ProtocolMismatch
        }
        if (root.boolStrict("ok") == false) {
            val error = root.stringStrict("error") ?: return EffectPageResult.ProtocolMismatch
            // The coordinator always builds a structurally valid envelope;
            // an invalidEnvelope reply is a protocol break, never a retryable
            // domain condition.
            if (error == "invalidEnvelope") return EffectPageResult.ProtocolMismatch
            if (error != "runtimeUnavailable") return EffectPageResult.ProtocolMismatch
            val reason = root.stringStrict("reason")
                ?: return EffectPageResult.ProtocolMismatch
            return EffectPageResult.Failure(reason)
        }
        if (root.boolStrict("ok") != true) return EffectPageResult.ProtocolMismatch
        if (root.stringStrict("schema") != EFFECT_SCHEMA) {
            return EffectPageResult.ProtocolMismatch
        }
        if (root.stringStrict("correlationID") != expectedRequestID) {
            return EffectPageResult.ProtocolMismatch
        }
        val cursor = root.obj("cursor") ?: return EffectPageResult.ProtocolMismatch
        if (cursor.stringStrict("operationReceiptID") != expectedReceipt) {
            return EffectPageResult.ProtocolMismatch
        }
        val nextSequence = cursor.longStrict("sequence")
            ?: return EffectPageResult.ProtocolMismatch
        if (nextSequence < afterSequence) return EffectPageResult.ProtocolMismatch
        val hasMore = root.boolStrict("hasMore") ?: return EffectPageResult.ProtocolMismatch
        val resync = root.boolStrict("resyncRequired")
            ?: return EffectPageResult.ProtocolMismatch
        val effects = root.array("effects") ?: return EffectPageResult.ProtocolMismatch
        val parsed = ArrayList<EffectItem>(effects.size)
        var previous = afterSequence
        var retainedBytes = 0
        for (element in effects) {
            val objectValue = element as? JsonObject ?: return EffectPageResult.ProtocolMismatch
            val sequence = objectValue.longStrict("sequence")
                ?: return EffectPageResult.ProtocolMismatch
            if (sequence <= previous) return EffectPageResult.ProtocolMismatch
            val kind = objectValue.stringStrict("kind")
                ?: return EffectPageResult.ProtocolMismatch
            if (kind !in EFFECT_KINDS) return EffectPageResult.ProtocolMismatch
            val code = if (objectValue.containsKey("code")) {
                objectValue.stringStrict("code") ?: return EffectPageResult.ProtocolMismatch
            } else null
            if (objectValue.containsKey("detail")) {
                val detail = objectValue.array("detail")
                    ?: return EffectPageResult.ProtocolMismatch
                for (entry in detail) {
                    val detailObject = entry as? JsonObject
                        ?: return EffectPageResult.ProtocolMismatch
                    detailObject.stringStrict("key")
                        ?: return EffectPageResult.ProtocolMismatch
                    detailObject.stringStrict("value")
                        ?: return EffectPageResult.ProtocolMismatch
                }
            }
            // Typed carrier (final consumer schema):
            //  * `value`/`page` must be JSON OBJECT documents;
            //  * a declared `valueBytes`/`pageBytes` must equal the ACTUAL
            //    canonical encoded size (kotlinx JsonObject.toString(), the
            //    same lexeme rules the producer derives);
            //  * declared bytes without the document are a protocol break.
            val pageCarrier = decodeCarrierDocument(objectValue, "page", "pageBytes")
                ?: return EffectPageResult.ProtocolMismatch
            val valueCarrier = decodeCarrierDocument(objectValue, "value", "valueBytes")
                ?: return EffectPageResult.ProtocolMismatch
            retainedBytes += utf8Bytes(element.toString())
            previous = sequence
            parsed.add(EffectItem(sequence, kind, code,
                valueCarrier.first, pageCarrier.first))
        }
        if (retainedBytes > EFFECT_PAGE_BUDGET_BYTES) {
            return EffectPageResult.ProtocolMismatch
        }
        if (parsed.any { it.kind != "resyncRequired" && it.sequence > nextSequence }) {
            return EffectPageResult.ProtocolMismatch
        }
        return EffectPageResult.Page(parsed, nextSequence, hasMore, resync)
    }

    /** Returns Pair(document, declaredBytes) or null on a protocol break. */
    private fun decodeCarrierDocument(
        item: JsonObject,
        documentKey: String,
        bytesKey: String,
    ): Pair<JsonElement?, Long?>? {
        if (!item.containsKey(documentKey)) {
            if (item.containsKey(bytesKey)) return null // bytes without document
            return Pair(null, null)
        }
        val element = item[documentKey] as? JsonObject ?: return null
        val actual = element.toString().toByteArray(Charsets.UTF_8).size.toLong()
        if (item.containsKey(bytesKey)) {
            val declared = item.longStrict(bytesKey) ?: return null
            if (declared < 0L || declared != actual) return null
        }
        return Pair(element, actual)
    }

    private fun parseObject(raw: String): JsonObject? = try {
        json.parseToJsonElement(raw) as? JsonObject
    } catch (t: Throwable) {
        null
    }

    private fun JsonObject.stringStrict(key: String): String? {
        val value = this[key] as? JsonPrimitive ?: return null
        if (!value.isString) return null
        return value.contentOrNull
    }

    private fun JsonObject.boolStrict(key: String): Boolean? {
        val value = this[key] as? JsonPrimitive ?: return null
        if (value.isString) return null   // never coerce "true" -> true
        return value.booleanOrNull
    }

    private fun JsonObject.longStrict(key: String): Long? {
        val value = this[key] as? JsonPrimitive ?: return null
        if (value.isString) return null   // never coerce "3" -> 3
        if (value is JsonNull) return null
        return value.longOrNull
    }

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

    private fun JsonObject.array(key: String): JsonArray? = this[key] as? JsonArray

    private fun JsonElement.stringValue(): String? {
        val value = this as? JsonPrimitive ?: return null
        if (!value.isString) return null
        return value.contentOrNull
    }

    private fun sanitizeReason(value: String): String {
        val builder = StringBuilder(minOf(value.length, 48))
        for (char in value) {
            if (builder.length >= 48) break
            if (char.isLetterOrDigit() || char == '_') builder.append(char)
        }
        return if (builder.isEmpty()) "unknown" else builder.toString()
    }

    private fun isOpaqueReceipt(value: String): Boolean =
        value.isNotBlank() && value.length <= 256 &&
            value.none { it.isISOControl() }

    private fun utf8Bytes(value: String): Int = value.toByteArray(Charsets.UTF_8).size

    companion object {
        /** The closed RB1 truth list (mirrors
         * `AndroidRuntimeBootstrap.MissingBinding`). Kept here so a status
         * that is momentarily unreadable still advertises the honest
         * barrier instead of nothing. */
        val STATIC_MISSING_BINDINGS = listOf(
            "providerConfigurationDomain",
            "credentialVaultAdapter",
            "credentialArgumentNormalizer",
            "conversationDomain",
            "runDomain",
            "temporaryDomain",
            "skillsMcpDiscovery",
            "hostAttachmentStaging",
            "transportDeviceQualification",
        )

        internal const val STATUS_VERSION = 1
        internal const val EFFECT_SCHEMA = "floe.effect-cursor/3"
        /** Frozen bridge request/response bound (BridgeV3.maximumBytes). */
        internal const val MAX_BRIDGE_BYTES = 65_536
        /** Server page budget: a normal effect page stays inside 48 KiB. */
        internal const val EFFECT_PAGE_BUDGET_BYTES = 49_152
        internal val STATUS_PHASES = setOf(
            "stopped", "starting", "draining", "failedDrainPending", "failed")
        internal val EFFECT_KINDS = setOf(
            "accepted", "rejected", "failed", "cancelled", "replaced",
            "closed", "resyncRequired", "prepared", "started")
        internal val TERMINAL_KINDS = setOf(
            "accepted", "rejected", "failed", "cancelled", "replaced", "closed")

        /** Production factory. Touches no native/IO here — only captures. */
        fun create(
            context: Context,
            gatewayCapability: StateFlow<SecretGatewayCapability>,
            capabilityState: MutableStateFlow<RuntimeBootstrapCapability> =
                MutableStateFlow(RuntimeBootstrapCapability.Idle),
        ): RuntimeBootstrapCoordinator {
            val appContext = context.applicationContext ?: context
            val random = SecureRandom()
            return RuntimeBootstrapCoordinator(
                native = SystemRuntimeNative,
                exchange = SystemBridgeExchange,
                gatewayCapability = gatewayCapability,
                rootProvider = {
                    withContext(Dispatchers.IO) {
                        val directory = java.io.File(appContext.filesDir, "floe-runtime")
                        if (!directory.isDirectory && !directory.mkdirs()) {
                            throw java.io.IOException("runtime_root_unavailable")
                        }
                        directory.absolutePath
                    }
                },
                ownerTokenProvider = {
                    val bytes = ByteArray(16)
                    random.nextBytes(bytes)
                    bytes.joinToString("") { "%02x".format(it) }
                },
                scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                diagnostics = { code -> android.util.Log.e("FloeRuntimeBootstrap", code) },
                corpusInstaller = RuntimeSecurityCorpusInstaller {
                    installBundledSecurityCorpus(appContext)
                },
                catalogFreezer = RuntimeProviderCatalogFreezer {
                    installBundledProviderCatalog(appContext)
                },
                capabilityState = capabilityState,
            )
        }

        /** Packaged trusted corpus asset (merged from :core:swiftbridge). */
        private const val SECURITY_CORPUS_ASSET =
            "security/catastrophic-patterns.json"

        /**
         * Packaged trusted OFFICIAL provider catalog (merged from
         * :core:swiftbridge; an exact byte copy of the original iOS trusted
         * resource FloeAgent/FloeApp/Resources/ProviderCatalog.json, whose
         * embedded `source` block records the models.dev document digest,
         * fetchedAt, MIT license and URL).
         */
        private const val PROVIDER_CATALOG_ASSET =
            "provider/ProviderCatalog.json"

        /** Mirrors the original loader bound; oversize is refused here too. */
        private const val MAX_CORPUS_BYTES = 1_048_576
        private const val CORPUS_OVERSIZED = -422

        /**
         * Read the trusted asset with a hard byte bound and freeze it through
         * the native original-loader validation. No path, digest or byte is
         * logged or returned beyond the typed status.
         */
        private fun installBundledSecurityCorpus(context: Context): Int {
            val bytes = context.assets.open(SECURITY_CORPUS_ASSET).use { stream ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = stream.read(chunk)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_CORPUS_BYTES) return CORPUS_OVERSIZED
                    buffer.write(chunk, 0, read)
                }
                buffer.toByteArray()
            }
            return SecurityCorpusNative.securityCorpusFreeze(bytes)
        }

        /** Mirrors ProviderCatalogIndex.maximumDocumentBytes (2 MiB). */
        private const val MAX_CATALOG_BYTES = 2 * 1024 * 1024
        private const val CATALOG_OVERSIZED = -432

        /**
         * Read the trusted official catalog asset with the ORIGINAL document
         * byte bound and freeze it through the native original-decoder
         * validation. No path, digest or document content is logged or
         * returned beyond the typed status.
         */
        private fun installBundledProviderCatalog(context: Context): Int {
            val bytes = context.assets.open(PROVIDER_CATALOG_ASSET).use { stream ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = stream.read(chunk)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_CATALOG_BYTES) return CATALOG_OVERSIZED
                    buffer.write(chunk, 0, read)
                }
                buffer.toByteArray()
            }
            return ProviderCatalogNative.providerCatalogFreeze(bytes)
        }
    }
}
