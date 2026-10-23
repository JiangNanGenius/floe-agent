// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import com.floe.android.bridge.LinuxReadinessNative
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePeerProof
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * G03-R3 app-owned LIVE readiness controller (trusted host ingress).
 *
 * Binds ONE authenticated [RuntimeConnection] to the ACTUAL accepted native
 * Root epoch and feeds the ORIGINAL seven-fact ingress
 * (`LinuxReadinessNative` / `floe_linux_readiness_*`) with facts this host
 * PROVED itself through existing authorities only:
 *  * `RuntimePeerVerifier` / `RuntimeConnection.currentPeerProof()` — the
 *    runtime-IPC lane's typed peer proof (exact dedicated UID, installed
 *    version token, actual signing-chain SHA-256, connection generation
 *    token). The controller adds NO parallel authentication path and never
 *    relaxes the connection's own admission checks.
 *  * `status` / `install.status` replies measured over the live binder from
 *    the ORIGINAL runtime kernel (protocol, real workload configuration,
 *    process-generation identity `runtimePid`+`runtimeBootToken`, and the
 *    verified published-revision rootfs receipt the runtime only reports
 *    after its own `verifyPublishedRevision` succeeded).
 *  * the mailbox bind performed by [LinuxShellPump.start] (the
 *    `mailboxEpoch` fact carries an empty proof; Core cross-checks the live
 *    bind at ingestion and refuses a closed/mismatched mailbox).
 *
 * The five prerequisite facts (`runtimeUidBoundary` first — it anchors the
 * generation to exactly one verified peer — then `engineConnected`,
 * `mailboxEpoch`, `rootfsInstalled`, `singleWorkloadAcknowledged`) are
 * ingested UP FRONT. `workspaceMappingSynced` and `leaseAuthorityQualified`
 * are NOT prereq-able here: they can only come from a REAL non-executing
 * workspace preflight round trip on a real active run (the pump's
 * `host.workspacePreflight` lane), which calls [ingestMappingAndLease] +
 * [activateAndVerify] with the terminal receipt and lease evidence that
 * round trip produced. There is no allTrue seam, no fabricated digest, and
 * nothing ingests on package-presence alone.
 *
 * Loss semantics (Main contract): transport loss, binder death, peer
 * identity drift (a DIFFERENT runtime process generation under the same
 * epoch is a refusal, never a re-anchor), rootfs receipt change, root stop
 * or an activation failure on the full-set check invalidate ALL seven facts
 * for the generation (`invalidate("*")`); facts NEVER auto-restore — a
 * later qualification is always a fresh full re-ingest after an explicit
 * legitimate resume or on a NEW epoch.
 *
 * Offline / denied-LAN state is irrelevant here by construction: nothing in
 * this controller or in the preflight round trip touches the network, so a
 * real installed rootfs + live binder keeps local command capability
 * qualifiable. Model JSON never reaches any method on this class.
 */
class LinuxRuntimeReadinessController(
    context: Context,
    /** Application-owned scope for lifecycle callbacks/events ONLY (binder
     *  loss re-ingress). Nothing here runs idle polling: every attempt is
     *  triggered by a real verified lifecycle event (install completion /
     *  binder loss) and is bounded + cancellable with the generation. */
    private val watchScope: CoroutineScope? = null,
) {

    private val context = context.applicationContext
    private val state = Mutex()

    /**
     * SHORT publication fence (Main review): guards EVERY native fact
     * write / invalidation / registration together with the current-bound
     * generation check. It is deliberately separate from the long `state`
     * IPC lock so a connect/status/install handshake never blocks stop() or
     * the binder callback path. Enforcement (not an aspirational comment):
     * an ingress round trip whose remote replies already returned still
     * cannot republish facts or re-anchor AFTER stop()/invalidation — its
     * later ingest/activate calls are refused inside this fence — and an
     * old Root callback can never globally invalidate a NEWER generation.
     */
    private val publish = java.util.concurrent.locks.ReentrantLock()

    /** True only while the CURRENT bound generation serves [epoch].
     *  Checked INSIDE [publish] before any native publication. */
    private fun isCurrentGeneration(epoch: Long): Boolean = bound?.epoch == epoch

    private class Bound(val epoch: Long) {
        @Volatile var connection: RuntimeConnection? = null
        @Volatile var anchoredProof: AnchoredPeer? = null
        @Volatile var rootfsReceipt: String? = null
        @Volatile var rootfsVersion: String? = null
    }

    @Volatile private var bound: Bound? = null
    /** Bounded, owned re-ingress attempt set (ONE per invalidation burst);
     *  cancelled on root stop or generation replacement. */
    @Volatile private var reingressJob: Job? = null

    /** What the generation is anchored to; compared against every later
     *  measurement so a rebind to a different peer process can never reuse
     *  facts from the old one. */
    data class AnchoredPeer(
        val peerUid: Int,
        val certificateDigest: String,
        val packageVersion: String,
        /** Runtime PROCESS generation token: "runtime:pid<pid>:gen<32hex>",
         *  measured from the peer's own status reply (never minted here). */
        val processToken: String,
    )

    enum class Activation { READY, REFUSED }
    data class ActivationOutcome(val state: Activation, val code: String)

    val boundEpoch: Long get() = bound?.epoch ?: 0L

    /**
     * Called from Application bootstrap OFF the main thread, right after the
     * pump bound the mailbox to the SAME accepted epoch. Ingresses the five
     * prerequisite facts from live measurements. Any failure leaves the
     * generation unqualified (never partial-truth flags). A later attempt is
     * a fresh full re-ingest ([prerequisitesLive] re-runs it on demand).
     */
    suspend fun start(acceptedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        if (acceptedEpoch <= 0) return@withContext false
        state.withLock {
            val previous = bound
            if (previous != null && previous.epoch != acceptedEpoch) invalidateInternal(previous, "epoch_replace")
            val target = bound?.takeIf { it.epoch == acceptedEpoch }
                ?: Bound(acceptedEpoch).also { bound = it }
            val failureCode = try {
                ingressPrerequisites(target)
                null
            } catch (failure: Exception) {
                refusalOf(failure)
            }
            if (failureCode != null) {
                invalidateInternal(target, failureCode)
                // A fresh launch with peer/rootfs NOT yet present must
                // recover WITHOUT waiting for a relaunch: one bounded,
                // owned, cancellable attempt set re-measures from FRESH
                // proof, and the verified install-completion lifecycle
                // event ([onInstallVerified]) re-arms immediately. No idle
                // poller, no test flag, no revival of a stopped root.
                scheduleFreshIngress(target, failureCode)
                false
            } else {
                true
            }
        }
    }

    /**
     * REAL install-completion event observed by the Application from the
     * EXISTING setup authority ([LocalRuntimeSetupHost] state: its terminal
     * INSTALLED phase is published only after the runtime's own verified
     * install receipt round trip). Re-ingresses the five prerequisite facts
     * for the CURRENT accepted root epoch from FRESH measurements (real peer
     * proof, real status generation, real verified rootfs receipt). Never
     * replays old proof bytes, never re-anchors a replaced generation, never
     * revives a stopped/suspended root (no bound for this exact epoch =>
     * refused). The two workspace facts still require a fresh REAL preflight
     * round trip afterwards; nothing here fabricates qualification.
     */
    suspend fun onInstallVerified(acceptedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        if (acceptedEpoch <= 0) return@withContext false
        state.withLock {
            val target = bound?.takeIf { it.epoch == acceptedEpoch } ?: return@withLock false
            reingressJob?.cancel()
            reingressJob = null
            try {
                ingressPrerequisites(target)
            } catch (failure: Exception) {
                val code = refusalOf(failure)
                invalidateInternal(target, code)
                // G03-R3 retry completion (Main steer 2026-10-23): the
                // install-verified transition is the fresh-install path's
                // ONLY automatic re-arm; one transient failure (e.g. the
                // runtime service still cold-binding) must not leave the
                // generation dead until an accidental app restart. ONE
                // bounded, owned, cancellable attempt set re-measures from
                // FRESH proof — no idle poller, no auto-restore; every
                // attempt still refuses on any real drift.
                scheduleFreshIngress(target, code)
                return@withLock false
            }
            prerequisiteFactsLive(target, acceptedEpoch)
        }
    }

    /** The measured runtime process generation the five-fact ingress is
     *  currently anchored to for [epoch] (null until verified). The pump
     *  stamps claimed preflight dispatches with it so ownership release can
     *  PROVE peer/process retirement against the actual dispatched
     *  generation — never a time budget. Read-only identity observation. */
    fun anchoredProcessToken(epoch: Long): String? {
        val target = bound?.takeIf { it.epoch == epoch } ?: return null
        return target.anchoredProof?.processToken
    }

    private suspend fun ingressPrerequisites(target: Bound) {
        val client = target.connection ?: RuntimeConnection(context).also { fresh ->
            fresh.connect().get(15, TimeUnit.SECONDS)
            // REAL callback: the actual Binder object death / disconnect of
            // the anchored peer falls ALL facts for the generation NOW
            // (dispatch AND discovery fence together) instead of waiting for
            // a preflight call that an already-qualified Core will never
            // make; a later SAME-generation process start then re-ingresses
            // from fresh proof through the bounded owned attempt set.
            fresh.onPeerLost = { handlePeerLoss(target, fresh) }
            target.connection = fresh
        }
        val ownUid = android.os.Process.myUid()
        val proof = client.currentPeerProof() ?: error("peerUnmeasurable")
        if (!proof.wellFormed(ownUid)) error("peerProofMalformed")
        if (proof.peerUid < 0) error("uidNotDistinct")
        val status = result(client.exchange("status"))
        if (status.optInt("protocol") != com.floe.android.runtimeipc.RuntimeWire.VERSION) error("engineProtocolUnsupported")
        val identity = processIdentity(status) ?: error("engineIdentityUnreported")
        val workloadContract = status.optString("workloadContractVersion")
        if (workloadContract != WORKLOAD_CONTRACT) error("workloadNotSingle")
        val install = result(client.exchange("install.status"))
        val receipt = install.optString("rootfsReceiptDigest")
        val version = install.optString("rootfsVersion")
        if (install.optString("phase") != "installed" || !RuntimePeerProof.isHex64(receipt) ||
            !asciiToken(version, 96)
        ) {
            error("rootfsUnverified")
        }
        val anchored = AnchoredPeer(proof.peerUid, proof.certificateDigest, proof.packageVersion, identity)
        // Anchor FIRST; every later fact must match this one verified peer.
        // singleWorkload is only acked while the engine reports itself idle
        // (no active/stopping workload to double-admit behind).
        if (status.optBoolean("active") || status.optBoolean("stopping")) error("workloadNotSingle")
        ingestOrThrow("runtimeUidBoundary", target.epoch, JSONObject()
            .put("runtimeUID", anchored.peerUid)
            .put("certificateDigest", anchored.certificateDigest)
            .put("packageVersion", anchored.packageVersion)
            .put("binderIdentity", anchored.processToken))
        target.anchoredProof = anchored
        target.rootfsReceipt = receipt
        target.rootfsVersion = version
        ingestOrThrow("engineConnected", target.epoch, JSONObject()
            .put("binderIdentity", anchored.processToken)
            .put("engineProtocolVersion", "floe-wire-v${status.getInt("protocol")}"))
        ingestOrThrow("mailboxEpoch", target.epoch, JSONObject())
        ingestOrThrow("rootfsInstalled", target.epoch, JSONObject()
            .put("receiptDigest", receipt).put("rootfsVersion", version))
        ingestOrThrow("singleWorkloadAcknowledged", target.epoch, JSONObject()
            .put("contractVersion", workloadContract))
    }

    /**
     * Fast live re-check the pump runs BEFORE dispatching a preflight claim:
     * the bound connection is still authenticated, the peer process
     * generation is unchanged, the rootfs receipt is unchanged, and the
     * Core-side ingress still reports the five prerequisite fields LIVE for
     * THIS epoch. When the transport is live but the Core facts are missing,
     * at most one bounded FRESH re-ingest is attempted (never a replay of
     * old proof bytes).
     */
    suspend fun prerequisitesLive(epoch: Long): Boolean = withContext(Dispatchers.IO) {
        val target = bound?.takeIf { it.epoch == epoch } ?: return@withContext false
        if (target.anchoredProof == null) return@withContext false
        if (prerequisiteFactsLive(target, epoch)) return@withContext true
        state.withLock {
            val current = bound?.takeIf { it.epoch == epoch } ?: return@withLock false
            try {
                ingressPrerequisites(current)
            } catch (failure: Exception) {
                invalidateInternal(current, refusalOf(failure))
                return@withLock false
            }
            prerequisiteFactsLive(current, epoch)
        }
    }

    private suspend fun prerequisiteFactsLive(target: Bound, epoch: Long): Boolean {
        val proof = target.anchoredProof ?: return false
        return try {
            val client = target.connection ?: return false
            val current = client.currentPeerProof() ?: return false
            if (current.peerUid != proof.peerUid || current.certificateDigest != proof.certificateDigest ||
                current.packageVersion != proof.packageVersion
            ) {
                invalidateInternal(target, "peer_boundary_drift"); return false
            }
            val status = result(client.exchange("status"))
            val identity = processIdentity(status) ?: run {
                invalidateInternal(target, "engine_identity_lost"); return false
            }
            if (identity != proof.processToken) {
                // A DIFFERENT runtime process generation under the same root
                // epoch is an anchor conflict: refuse and fence; never
                // silently re-anchor an existing generation.
                invalidateInternal(target, "peer_generation_drift"); return false
            }
            val install = result(client.exchange("install.status"))
            if (install.optString("phase") != "installed" ||
                install.optString("rootfsReceiptDigest") != target.rootfsReceipt ||
                install.optString("rootfsVersion") != target.rootfsVersion
            ) {
                invalidateInternal(target, "rootfs_drift"); return false
            }
            val ingress = statusObject() ?: return false
            ReadinessSnapshot.prerequisitesLiveAt(ReadinessSnapshot.from(ingress), epoch)
        } catch (_: Exception) {
            invalidateInternal(target, "transport_lost")
            false
        }
    }

    /**
     * After the pump's REAL preflight round trip settled (terminal index
     * digest from the grant's captured EXPORT_FINISH receipt + the runtime's
     * real lease acquire/abandon-with-no-children proof digest), ingest the
     * remaining two facts for the SAME anchored generation. The pump then
     * calls [activateAndVerify] and only replies "ready" on READY.
     */
    suspend fun ingestMappingAndLease(
        epoch: Long,
        workspaceIndexDigest: String,
        leaseProofDigest: String,
        sessionProcessToken: String,
        sessionPeerUid: Int,
        sessionCertificateDigest: String,
        sessionPackageVersion: String,
    ): ActivationOutcome = withContext(Dispatchers.IO) {
        val target = bound?.takeIf { it.epoch == epoch }
            ?: return@withContext ActivationOutcome(Activation.REFUSED, "epoch_unbound")
        val proof = target.anchoredProof
            ?: return@withContext ActivationOutcome(Activation.REFUSED, "peer_unanchored")
        // The round trip must have used the SAME live anchored peer this
        // generation proved; a drifted identity is a refusal (fence), never
        // a silent re-anchor or a "ready" reply.
        if (sessionProcessToken != proof.processToken || sessionPeerUid != proof.peerUid ||
            sessionCertificateDigest != proof.certificateDigest || sessionPackageVersion != proof.packageVersion
        ) {
            invalidateInternal(target, "peer_anchor_mismatch")
            return@withContext ActivationOutcome(Activation.REFUSED, "peer_anchor_mismatch")
        }
        if (!RuntimePeerProof.isHex64(workspaceIndexDigest) || !RuntimePeerProof.isHex64(leaseProofDigest)) {
            return@withContext ActivationOutcome(Activation.REFUSED, "receipt_malformed")
        }
        val mapping = ingest("workspaceMappingSynced", epoch,
            JSONObject().put("receiptDigest", workspaceIndexDigest))
        if (!mapping.first) return@withContext ActivationOutcome(Activation.REFUSED, mapping.second)
        val lease = ingest("leaseAuthorityQualified", epoch,
            JSONObject().put("receiptDigest", leaseProofDigest))
        if (!lease.first) {
            // The mapping fact stays as its own true evidence (Core verified
            // the real read-back); qualification still requires all seven,
            // so activation will honestly refuse. No auto-restore exists.
            return@withContext ActivationOutcome(Activation.REFUSED, lease.second)
        }
        ActivationOutcome(Activation.READY, "ingressed")
    }

    /** activateRegistration + the FINAL truth checks: all seven fields live
     *  at this epoch, registration actually completed, accepted epochs match.
     *  No reply echo can qualify the engine — this reads Core's own status. */
    suspend fun activateAndVerify(epoch: Long): ActivationOutcome = withContext(Dispatchers.IO) {
        // Registration is a native PUBLICATION too: it runs inside the same
        // short fence behind the current-generation check. A stopped or
        // replaced generation can never activate, and the stale round trip
        // never invalidates a NEWER bound generation on the refusal path.
        val reply: ByteArray? = publish.lock().let {
            try {
                if (!isCurrentGeneration(epoch)) null
                else runCatching { LinuxReadinessNative.activateRegistration(epoch) }.getOrNull()
            } finally { publish.unlock() }
        }
        if (reply == null) {
            if (!isCurrentGeneration(epoch)) {
                return@withContext ActivationOutcome(Activation.REFUSED, "generationStopped")
            }
            invalidateForEpoch(epoch, "activation_unreachable")
            return@withContext ActivationOutcome(Activation.REFUSED, "activation_unreachable")
        }
        val activation = parse(reply)
        if (activation == null) {
            // An unreadable activation body proves NOTHING: the same fenced
            // generation check as the unreachable sibling above (a stale
            // Root callback can never invalidate a NEWER bound generation
            // through the global native invalidation), then the typed
            // refusal — never !!, never an empty fake JSON, never an
            // all-true default.
            if (!isCurrentGeneration(epoch)) {
                return@withContext ActivationOutcome(Activation.REFUSED, "generationStopped")
            }
            invalidateForEpoch(epoch, "activation_unparsable")
            return@withContext ActivationOutcome(Activation.REFUSED, "activation_unparsable")
        }
        if (!activation.optBoolean("ok") || !activation.optBoolean("shellRegistered")) {
            return@withContext ActivationOutcome(Activation.REFUSED,
                activation.optString("code").takeIf { it.isNotEmpty() } ?: "activation_refused")
        }
        val status = statusObject()
            ?: return@withContext ActivationOutcome(Activation.REFUSED, "status_unreadable")
        if (!ReadinessSnapshot.allSevenLiveAt(ReadinessSnapshot.from(status), epoch)) {
            return@withContext ActivationOutcome(Activation.REFUSED, "facts_not_all_live")
        }
        ActivationOutcome(Activation.READY, "registered")
    }

    /** Invalidate EVERY fact for the generation and fence the controller.
     *  Requalification requires fresh full re-ingest (and a fresh preflight
     *  receipt once the mapping is affected); cleanup/poll channels are
     *  untouched by this call (they live in the pump/mailbox).
     *  [invalidateForEpoch] is the callback-safe form: a stale pump/reconcile
     *  observer that no longer owns the current generation can NEVER drop a
     *  newer Root's facts through the global native invalidate. */
    /**
     * G03-R3 bounded diagnostic (Main-authorized observability, 2026-10-23;
     * Main reviews r3-workspace-critical-activation-review + closed-token +
     * epoch-tag steers): the LAST typed preflight stage token recorded by
     * the pump's `host.workspacePreflight` lane, TAGGED with the generation
     * it was recorded for. A late callback from an OLD Root can never
     * overwrite or surface under a NEWER generation (write-side epoch match
     * AND read-side filter). CLOSED vocabulary only ([closedStageToken]):
     * known stage/refusal tokens pass through; anything else maps to the
     * fixed `redacted` token — arbitrary text (paths, digests, keys,
     * prompts, commands) is never truncated-and-passed-through.
     * Diagnostic-only: recording a token qualifies nothing and gates
     * nothing; every admission condition is unchanged.
     */
    @Volatile private var lastPreflightStage: Pair<Long, String>? = null

    fun recordPreflightStage(epoch: Long, token: String) {
        // Stale-generation recordings are REFUSED at the write side: only
        // the CURRENT bound generation may own the visible stage token.
        if (epoch <= 0 || bound?.epoch != epoch) return
        closedStageToken(token)?.let { lastPreflightStage = epoch to it }
    }

    /** Read-only diagnostic summary for the Diagnostics & About surface:
     * composed ONLY from the existing readiness status authority (the same
     * `floe_linux_readiness_status` read [activateAndVerify] consults) plus
     * the epoch-tagged recorded preflight stage. `ready` only when all
     * seven facts are live at the exact bound epoch; otherwise an explicit
     * total cause branch, the closed-filtered ingress refusal and the
     * closed-filtered stage — never a raw value, never a throwing path.
     * Must be called OFF the main thread. */
    fun diagnosticSnapshot(): String {
        val epoch = bound?.epoch ?: 0L
        if (epoch <= 0) return "lane:unbound"
        return diagnosticStage(statusObject(), epoch, stageForEpoch(lastPreflightStage, epoch))
    }

    /**
     * Read-only observation of the ACTUAL Core ingress for the CURRENT bound
     * generation (the Settings surface authority). Runs ONE bounded native
     * status read (the SAME `floe_linux_readiness_status` path
     * [activateAndVerify] consults) — it writes nothing, re-ingests nothing,
     * never polls by itself and must be called OFF the main thread. True
     * only when Core's own status authority reports all seven facts live at
     * the exact bound epoch; install status or reply strings NEVER count.
     */
    fun liveTaskExecutionReady(): Boolean {
        val epoch = bound?.epoch ?: return false
        if (epoch <= 0) return false
        val status = statusObject() ?: return false
        return ReadinessSnapshot.allSevenLiveAt(ReadinessSnapshot.from(status), epoch)
    }

    /**
     * Bounded READ-ONLY runtime metadata observation for the Diagnostics &
     * About details popup: ONE metadata-only `status` exchange over the
     * CURRENT bound generation's live authenticated connection — the SAME
     * read [ingressPrerequisites] and [prerequisiteFactsLive] already
     * perform. The kernel answers `status` from in-memory facts only
     * (protocol, foreground permit state, activity, the applied guest
     * resolver snapshot and the process generation): no command, install,
     * DNS or network query and no workload runs for this read.
     *
     * This method WRITES NOTHING: it never ingests, invalidates,
     * re-anchors, retries or registers anything; a drifted or closed
     * generation is only NAMED for the popup. The reply's process identity
     * must match the anchored generation token, and the SAME bound
     * target/connection/anchor must still own the reading AFTER the
     * exchange (read-end fence) or the observation is discarded as
     * belonging to a retired generation. Must be called OFF the main
     * thread.
     */
    suspend fun resolverObservation(): JsonObject = withContext(Dispatchers.IO) {
        val target = bound ?: return@withContext LocalRuntimeProofProjection.unavailable("lane_unbound")
        val client = target.connection ?: return@withContext LocalRuntimeProofProjection.unavailable("connection_closed")
        val anchored = target.anchoredProof
            ?: return@withContext LocalRuntimeProofProjection.unavailable("peer_unanchored")
        val current = runCatching { client.currentPeerProof() }.getOrNull()
            ?: return@withContext LocalRuntimeProofProjection.unavailable("peer_unmeasurable")
        if (current.peerUid != anchored.peerUid || current.certificateDigest != anchored.certificateDigest ||
            current.packageVersion != anchored.packageVersion
        ) {
            return@withContext LocalRuntimeProofProjection.unavailable("peer_drift")
        }
        val envelope = runCatching { client.exchange("status") }.getOrNull()
            ?: return@withContext LocalRuntimeProofProjection.unavailable("transport_unavailable")
        // Read-end fence: only the SAME live generation this read started
        // on may have its reply projected; a stop/rebind across the IPC
        // retires the observation (naming only — never a mutation).
        if (bound !== target || target.connection !== client || target.anchoredProof !== anchored) {
            return@withContext LocalRuntimeProofProjection.unavailable("generation_changed")
        }
        val status = runCatching { result(envelope) }.getOrNull()
            ?: return@withContext LocalRuntimeProofProjection.unavailable("exchange_refused")
        if (status.optInt("protocol") != com.floe.android.runtimeipc.RuntimeWire.VERSION) {
            return@withContext LocalRuntimeProofProjection.unavailable("protocol_mismatch")
        }
        if (processIdentity(status) != anchored.processToken) {
            return@withContext LocalRuntimeProofProjection.unavailable("generation_mismatch")
        }
        val decoded = runCatching { Json.parseToJsonElement(status.toString()) as? JsonObject }.getOrNull()
        LocalRuntimeProofProjection.projectResolver(
            decoded, decoded?.get("resolver") as? JsonObject,
        )
    }

    fun invalidate(reason: String) {
        invalidateInternal(bound, reason)
    }

    /**
     * Callback-safe fenced invalidation for ONE accepted epoch (pump /
     * reconcile observers). G03-R3 retry completion (Main steer 2026-10-23):
     * the Core first-use hook's frozen promise — "the next ordinary run
     * re-issues its own bounded request" — only holds if a preflight-stage
     * fence can recover from LIVE measurements without an accidental app
     * restart: Core's dispatch gate reads the five prerequisite facts, so a
     * fenced generation that never re-ingresses never dispatches again and
     * exec.shell stays honestly unqualified until process death. This
     * schedules the SAME bounded owned attempt set used after binder loss
     * (fresh proof only; no auto-restore; drift still refuses). The global
     * [invalidate] (install actually changed) deliberately stays event-only.
     */
    fun invalidateForEpoch(acceptedEpoch: Long, reason: String) {
        val target = bound?.takeIf { it.epoch == acceptedEpoch } ?: return
        invalidateInternal(target, reason)
        scheduleFreshIngress(target, reason)
    }

    /** Root stop (Application Stopped observation): facts fall, session ends,
     *  owned lifecycle attempts are cancelled. The detach and the native "*"
     *  invalidation happen INSIDE the publication fence, so an in-flight
     *  [ingressPrerequisites] whose status/install IPC already returned can
     *  no longer republish facts or re-anchor afterwards: its remaining
     *  ingest calls are refused by the in-fence generation check. */
    fun stop(expectedEpoch: Long) {
        val target = bound?.takeIf { it.epoch == expectedEpoch } ?: return
        reingressJob?.cancel()
        reingressJob = null
        // ONE fence for the whole detach: invalidate (native "*" only for
        // the current bound target), field clear and generation null-out are
        // atomic against in-fence ingest; the (possibly suspended) handshake
        // on the `state` lock is deliberately NOT held here.
        var stale: RuntimeConnection? = null
        publish.lock()
        try {
            stale = target.connection
            target.connection = null
            invalidateInternal(target, "root_stopped")
            if (bound === target) bound = null
        } finally { publish.unlock() }
        // Peer-loss callbacks hold the connection monitor before taking publish.
        // Keep close outside publish so stop cannot invert those two locks.
        runCatching { stale?.close() }
    }

    private fun handlePeerLoss(target: Bound, client: RuntimeConnection) {
        // Late callbacks cannot touch a replaced or stopped generation: only
        // the CURRENT anchored connection of the CURRENT bound generation is
        // live truth. An intentional local close never reaches here.
        if (bound !== target || target.connection !== client) return
        invalidateInternal(target, "engine_binder_lost")
        scheduleFreshIngress(target, "engine_binder_lost")
    }

    private fun scheduleFreshIngress(target: Bound, reason: String) {
        val scope = watchScope ?: return
        if (reingressJob?.isActive == true) return
        reingressJob = scope.launch(Dispatchers.IO) {
            var attempt = 0
            while (isActive && attempt < REINGRESS_ATTEMPTS) {
                delay(REINGRESS_BACKOFF_MILLIS)
                if (!isActive || bound !== target) break
                val live = state.withLock {
                    if (bound !== target) return@withLock false
                    // A mid-sequence failure must NOT leave partially
                    // ingested facts: fence the whole set before retrying.
                    val ok = try { ingressPrerequisites(target); true }
                    catch (failure: Exception) {
                        invalidateInternal(target, refusalOf(failure))
                        false
                    }
                    ok && prerequisiteFactsLive(target, target.epoch)
                }
                if (live) {
                    reingressJob = null
                    break
                }
                attempt += 1
            }
            // Budget exhausted (or the generation was replaced): the
            // controller stays honestly unqualified. A later REAL lifecycle
            // event (verified install completion / next peer loss) re-arms;
            // there is no idle poller and no partial-truth flag.
        }
    }

    /**
     * Fenced invalidation. The generation check + native "*" write + field
     * clear run atomically against [ingest] and [stop]: an old or already
     * detached target NEVER issues the global native invalidation (so a
     * late current/old-Root callback cannot drop a NEWER generation's
     * facts), while the target's own fields are always cleared. The
     * connection close runs after the native write to keep the fence short.
     */
    private fun invalidateInternal(target: Bound?, reason: String) {
        target ?: return
        publish.lock()
        try {
            if (bound === target) runCatching { LinuxReadinessNative.invalidate(null, reason.take(48)) }
            target.anchoredProof = null
            target.rootfsReceipt = null
            target.rootfsVersion = null
        } finally { publish.unlock() }
        runCatching { target.connection?.close() }
        target.connection = null
    }

    private fun ingestOrThrow(field: String, epoch: Long, proof: JSONObject) {
        val (ok, code) = ingest(field, epoch, proof)
        if (!ok) error(code)
    }

    private fun ingest(field: String, epoch: Long, proof: JSONObject): Pair<Boolean, String> {
        publish.lock()
        try {
            // The generation check and the native write are ATOMIC against
            // stop()/invalidateInternal: a handshake that already returned
            // cannot republish a fact once the generation was fenced, and a
            // stopped/replaced epoch is refused here before any JNI call.
            if (!isCurrentGeneration(epoch)) return false to "generationStopped"
            val bytes = runCatching {
                LinuxReadinessNative.ingest(field, epoch, proof.toString().toByteArray(Charsets.UTF_8))
            }.getOrNull() ?: return false to "nativeUnavailable"
            val reply = parse(bytes) ?: return false to "nativeUnparsable"
            if (reply.optBoolean("ok")) return true to "ok"
            val code = reply.optString("code")
            return false to code.takeIf { it.isNotEmpty() }!!.take(48)
        } finally { publish.unlock() }
    }

    private fun statusObject(): JSONObject? =
        runCatching { LinuxReadinessNative.status() }.getOrNull()?.let { parse(it) }


    internal fun asciiToken(text: String, maximumBytes: Int): Boolean {
        if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > maximumBytes) return false
        return text.all { it.code in 0x21..0x7e }
    }

    private fun result(envelope: JSONObject): JSONObject {
        if (!envelope.optBoolean("ok")) error(envelope.optString("code").ifEmpty { "exchangeFailed" })
        return envelope.getJSONObject("result")
    }

    private fun refusalOf(failure: Exception): String =
        failure.message?.takeIf { it.isNotEmpty() && it.length <= 32 && asciiToken(it, 32) } ?: "ingress_failed"

    enum class LifecycleChange { REINGRESS, INVALIDATE, NONE }

    companion object {
        const val WORKLOAD_CONTRACT = "floe-single-workload-v1"
        /** Owned, BOUNDED re-ingress attempt set per invalidation burst
         *  (individual attempts are already bounded by the connection
         *  handshake; this caps the sequence itself). */
        const val REINGRESS_ATTEMPTS = 12
        const val REINGRESS_BACKOFF_MILLIS = 5_000L
        internal const val INSTALL_PHASE = "installed"

        /** Pure lifecycle-transition decision for the Application's install-
         *  state observer (real events from the EXISTING setup authority,
         *  not a test flag): a transition INTO verified `installed` triggers
         *  ONE fresh full prerequisite re-ingress for the current root; a
         *  transition OUT of it means the rootfs/component actually changed
         *  and ALL facts must fall NOW — even after prior qualification,
         *  which previously only re-checked when a preflight call arrived.
         *  The first observation and unchanged phases never act: no silent
         *  re-anchor of a stale generation, no idle re-ingress loop. */
        internal fun lifecycleChange(previous: String?, current: String): LifecycleChange {
            if (previous == null) return LifecycleChange.NONE
            val was = previous == INSTALL_PHASE
            val now = current == INSTALL_PHASE
            return when {
                !was && now -> LifecycleChange.REINGRESS
                was && !now -> LifecycleChange.INVALIDATE
                else -> LifecycleChange.NONE
            }
        }
        internal fun parse(bytes: ByteArray): JSONObject? = runCatching {
            JSONObject(String(bytes, Charsets.UTF_8))
        }.getOrNull()

        /** The fixed token for anything outside the closed vocabulary. */
        internal const val REDACTED = "redacted"

        /**
         * CLOSED diagnostic vocabulary (Main review 2026-10-23): membership,
         * NOT length, is the bound. Only tokens enumerated from the actual
         * producers may pass through; every other value — including
         * arbitrary exception text, runtime reason strings, paths, hex
         * digests or keys that happen to be printable ASCII — maps to the
         * fixed `redacted` token. Empty stays null (nothing recorded).
         * Sources: LinuxShellPump preflight replies, this controller's
         * ingest/activation codes, the Core `LinuxReadinessIngress` refusal
         * codes and the runtime `RuntimeWorkspacePreflight` reason strings.
         */
        internal val KNOWN_STAGE_TOKENS: Set<String> = setOf(
            // Pump preflight lane (reply/status vocabulary).
            "request_invalid", "run_or_epoch_stopped", "prerequisites_unverified",
            "caller_stopped", "dispatch_unknown", "preflight_cancelled",
            "runtime_busy", "workspace_unresolved", "close_retained",
            "mapping_unsynced", "evidence_incomplete", "preflight_aborted",
            "preflight_failed", "runtime_unavailable", "cancelled", "unavailable",
            // CoreWorkspaceGrant.create closed branch tokens + the flat
            // native reply codes it may surface (G03-R3 grant refusal
            // observation): fixed constants enumerated from the actual producers
            // (CoreWorkspaceGrant.BRANCH_REFUSAL_TOKENS /
            // NATIVE_REFUSAL_CODES); parameterized engine codes stay out
            // and fall back to their branch token at the producer.
            "grant_arguments_invalid", "grant_peer_refused",
            "grant_binding_unparsable", "grant_binding_refused",
            "grant_identity_mismatch", "grant_open_unparsable",
            "grant_open_refused", "grant_session_key_malformed",
            "invalidArguments", "epochNotCurrent", "bindingUnavailable",
            "bindingMalformed", "bindingUnresolved", "jobCallMismatch",
            "grantNotMinted", "sessionOpenFailed", "workspaceNotConfigured",
            // Controller ingest/activation codes.
            "generationStopped", "nativeUnavailable", "nativeUnparsable",
            "epoch_unbound", "peer_unanchored", "peer_anchor_mismatch",
            "receipt_malformed", "activation_unreachable", "activation_unparsable",
            "activation_refused", "status_unreadable", "facts_not_all_live",
            "invalidEpoch", "epochNotBound", "readinessNotIngressed",
            // Controller live-measurement refusals (refusalOf vocabulary).
            "peerUnmeasurable", "peerProofMalformed", "engineProtocolUnsupported",
            "engineIdentityUnreported", "workloadNotSingle", "rootfsUnverified",
            "exchangeFailed", "ingress_failed", "peer_boundary_drift",
            "engine_identity_lost", "peer_generation_drift", "rootfs_drift",
            "transport_lost", "preflight_peer_retired",
            // Core LinuxReadinessIngress refusal codes (lastRefusal values).
            "epochZero", "epochNotLive", "mailboxClosed", "noLiveAuthority",
            "admissionSuspended", "uidNotDistinct", "certificateMalformed",
            "identityTokenMalformed", "peerBoundaryConflict", "peerNotAnchored",
            "peerBinderMismatch", "mailboxEpochMismatch", "rootfsReceiptMalformed",
            "rootfsVersionMalformed", "workspaceAuthorityNotInstalled",
            "workspaceEngineNotInstalled", "mappingReceiptUnreadBack",
            "mappingReceiptEpochMismatch", "mappingReceiptNotSynced",
            "mappingReceiptTreeUnsafe", "mappingReceiptScanTruncated",
            "leaseReceiptMalformed", "leaseWithoutLiveMailbox",
            "contractTokenMalformed", "engineIdentityMalformed", "hostInvalidate",
            // Runtime RuntimeWorkspacePreflight reason strings.
            "aborted", "identityNotCanonical", "leaseRunMismatch", "lease_retained",
            "mapping_conflict", "mirror_empty", "mirror_refused", "preflightBusy",
            "preflightFieldsInvalid", "quiescence_lost", "quiescence_unproven",
            "unexpected",
        )

        /** The `invalidated:<kind>` lastRefusal shape is closed too: only
         * the frozen ABI kind names (or `all`) may follow the prefix. */
        internal val KNOWN_INVALIDATED_KINDS: Set<String> =
            setOf("all") + ReadinessSnapshot.ALL_SEVEN.mapNotNull { ReadinessSnapshot.kindFor(it) }

        internal fun closedStageToken(text: String): String? {
            if (text.isEmpty()) return null
            if (text in KNOWN_STAGE_TOKENS) return text
            if (text.startsWith("invalidated:") &&
                text.removePrefix("invalidated:") in KNOWN_INVALIDATED_KINDS
            ) {
                return text
            }
            return REDACTED
        }

        /** Pure diagnostic composition (Main-authorized bounded stage
         * surface). TOTAL — every branch returns, none throws (Main review
         * 2026-10-23: all-fields-true with an epoch/anchor/suspension or
         * accepted-record mismatch must NOT hit a `first{}` NoSuchElementException):
         * `ready` | `lane:unbound` | `status:unreadable` |
         * `<cause>|refusal:<closed>|stage:<closed>` where cause is one of
         * `epochMismatch`, `peerUnanchored`, `suspended`, `missing:<fact>`,
         * `unaccepted:<kind>` or the defensive `factsNotAllLive`. Nothing
         * here qualifies anything — it only NAMES the honest current stage. */
        /** JSON adapter over the pure core (org.json is not JVM-testable;
         * the decision itself lives in the snapshot overload below). */
        internal fun diagnosticStage(status: JSONObject?, epoch: Long, lastStage: String?): String {
            if (epoch <= 0) return "lane:unbound"
            if (status == null) return "status:unreadable"
            return diagnosticStage(ReadinessSnapshot.from(status),
                status.optString("lastRefusal"), epoch, lastStage)
        }

        /** Pure decision core — TOTAL, never throws (Main review
         * 2026-10-23: all-fields-true with an epoch/anchor/suspension or
         * accepted-record mismatch must NOT hit a `first{}`
         * NoSuchElementException). */
        internal fun diagnosticStage(snapshot: ReadinessSnapshot?, lastRefusal: String?,
                                     epoch: Long, lastStage: String?): String {
            if (epoch <= 0) return "lane:unbound"
            if (snapshot == null) return "status:unreadable"
            if (ReadinessSnapshot.allSevenLiveAt(snapshot, epoch)) return "ready"
            val cause = when {
                snapshot.liveEpoch != epoch -> "epochMismatch"
                !snapshot.peerAnchored -> "peerUnanchored"
                snapshot.suspendedEpoch == epoch -> "suspended"
                else -> {
                    val missingField =
                        ReadinessSnapshot.ALL_SEVEN.firstOrNull { snapshot.fields[it] != true }
                    if (missingField != null) {
                        "missing:$missingField"
                    } else {
                        // Derived fields all true and epoch/anchor/suspension
                        // fine: the live predicate failed on an ACCEPTED-fact
                        // record (absent, not live, or bound to another
                        // epoch). Name that honestly; never throw.
                        val unacceptedKind = ReadinessSnapshot.ALL_SEVEN.firstNotNullOfOrNull { name ->
                            val kind = ReadinessSnapshot.kindFor(name) ?: return@firstNotNullOfOrNull name
                            val boundFact = snapshot.accepted[kind]
                            if (boundFact == null || !boundFact.second || boundFact.first != epoch) kind else null
                        }
                        if (unacceptedKind != null) "unaccepted:$unacceptedKind"
                        else "factsNotAllLive"
                    }
                }
            }
            val refusal = closedStageToken(lastRefusal ?: "") ?: ""
            val stage = closedStageToken(lastStage ?: "") ?: ""
            return "$cause|refusal:$refusal|stage:$stage"
        }

        /** Epoch-tagged stage visibility: a recorded stage is surfaced ONLY
         * under the generation it was captured for — a late old-Root
         * callback can never pollute a newer generation's reading. */
        internal fun stageForEpoch(record: Pair<Long, String>?, epoch: Long): String? =
            record?.takeIf { it.first == epoch }?.second

        /** The live engine PROCESS generation token, measured from the peer's
         *  own authenticated status (or preflight result) reply. Returns null
         *  unless BOTH the pid and a 32-hex boot nonce are present — the
         *  token is always derived, never accepted as a free-form string. */
        internal fun processIdentity(status: JSONObject): String? {
            val pid = status.optInt("runtimePid", -1)
            val boot = status.optString("runtimeBootToken")
            if (pid <= 0 || !boot.matches(Regex("^[0-9a-f]{32}$"))) return null
            return "runtime:pid$pid:gen$boot".take(128)
        }
    }
}

/**
 * Pure typed view of the ingress `status` reply (the frozen Core contract's
 * derivedFields names). The JSONObject adapter (`from`) runs in production;
 * every DECISION below operates only on this immutable snapshot, so the
 * qualification logic is testable with exact boundary fixtures without
 * Android/JNI — and no caller can mistake a status STRING for
 * qualification.
 */
internal data class ReadinessSnapshot(
    val liveEpoch: Long,
    val peerAnchored: Boolean,
    val suspendedEpoch: Long,
    val fields: Map<String, Boolean>,
    /** kind -> (accepted epoch, live flag) for every fact Core has stored. */
    val accepted: Map<String, Pair<Long, Boolean>>,
) {
    companion object {
        val PREREQUISITES = listOf(
            "runtimeUidBoundaryVerified", "engineConnected", "mailboxEpochBound",
            "rootfsQualified", "singleWorkloadContractAcknowledged",
        )
        val ALL_SEVEN = PREREQUISITES + listOf("workspaceMappingSynced", "leaseAuthorityQualified")

        fun from(status: JSONObject): ReadinessSnapshot {
            val fields = status.optJSONObject("fields")
            val fieldMap = PREREQUISITES_PLUS_ALL.map { it to (fields?.optBoolean(it) == true) }.toMap()
            val acceptedObject = status.optJSONObject("accepted")
            val acceptedMap = HashMap<String, Pair<Long, Boolean>>()
            acceptedObject?.let { objectValue ->
                for (kind in objectValue.keys()) {
                    val fact = objectValue.optJSONObject(kind)
                    acceptedMap[kind] = (fact?.optLong("epoch") ?: -1L) to (fact?.optBoolean("live") == true)
                }
            }
            return ReadinessSnapshot(
                liveEpoch = status.optLong("liveEpoch"),
                peerAnchored = status.optJSONObject("peer")?.optBoolean("anchored") == true,
                suspendedEpoch = status.optLong("suspendedEpoch"),
                fields = fieldMap,
                accepted = acceptedMap,
            )
        }

        private val PREREQUISITES_PLUS_ALL = PREREQUISITES +
            listOf("workspaceMappingSynced", "leaseAuthorityQualified")

        /** derivedFields name -> accepted fact kind (frozen ABI names). */
        internal fun kindFor(field: String): String? = FIELD_TO_KIND[field]
        private val FIELD_TO_KIND = mapOf(
            "runtimeUidBoundaryVerified" to "runtimeUidBoundary",
            "engineConnected" to "engineConnected",
            "mailboxEpochBound" to "mailboxEpoch",
            "rootfsQualified" to "rootfsInstalled",
            "singleWorkloadContractAcknowledged" to "singleWorkloadAcknowledged",
            "workspaceMappingSynced" to "workspaceMappingSynced",
            "leaseAuthorityQualified" to "leaseAuthorityQualified",
        )

        fun prerequisitesLiveAt(status: ReadinessSnapshot, epoch: Long): Boolean =
            liveAt(status, epoch, PREREQUISITES)

        fun allSevenLiveAt(status: ReadinessSnapshot, epoch: Long): Boolean =
            liveAt(status, epoch, ALL_SEVEN)

        private fun liveAt(status: ReadinessSnapshot, epoch: Long, names: List<String>): Boolean {
            if (epoch <= 0 || status.liveEpoch != epoch) return false
            if (!status.peerAnchored) return false
            if (status.suspendedEpoch == epoch) return false
            for (name in names) if (status.fields[name] != true) return false
            // Every required derived field must also have an ACCEPTED fact
            // record bound to THIS epoch and live (never a flag without a
            // stored current-generation proof). Entries for other kinds are
            // irrelevant here: `fields` is the single derived authority.
            for (name in names) {
                val kind = FIELD_TO_KIND[name] ?: return false
                val bound = status.accepted[kind] ?: return false
                if (!bound.second || bound.first != epoch) return false
            }
            return true
        }
    }
}
