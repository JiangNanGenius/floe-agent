// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafBackendFault
import com.floe.android.safgateway.SafBackendFaultException
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCancelledException
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafLimits
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafSharedGrantBroker
import com.floe.android.safgateway.SafUriRef
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.URI
import java.security.MessageDigest
import java.util.UUID

/** Where one Save Copy operation is between prepare() and its settled outcome. */
enum class OfficeSaveCopyStage { AWAITING_TARGET, TRANSFERRING, VERIFYING }

/**
 * What this service can HONESTLY say about the caller-staged source bytes at
 * settlement time. The service never observes the caller's independent
 * recovery owner, so no variant here claims the bytes "were recovered"; the
 * retention OBLIGATION always stays with the caller either way (Main review
 * finding 6, 2026-10-26).
 */
enum class OfficeSaveCopySourceRetention {
    /**
     * Nothing was established: the source stream did not fully observe
     * verified bytes on this path (opener threw, the pass was cut before EOF,
     * or the operation settled before any source IO). The controller did not
     * and will not delete the caller's staged data, but the UI must NOT
     * report the bytes as recovered — verifying/preserving them is the
     * caller's retention obligation.
     */
    UNPROVEN_CALLER_OBLIGATION,

    /**
     * On this attempt the controller read the source stream to EOF and hashed
     * the complete byte sequence into durable scratch (the staged content —
     * even where it then MISMATCHED the declared length/hash). The service
     * proved the observation, not the caller's ongoing retention; the scratch
     * copy was deleted only after every stream, grant reference and settle had
     * drained.
     */
    FULLY_OBSERVED_THIS_ATTEMPT,
}

/**
 * Typed terminal outcome of one Save Copy operation. NOTHING here is a UI
 * string and nothing implies provider CAS: [CopiedVerified] requires exact
 * byte count + source SHA while streaming + destination read-back size+SHA
 * equality; every other state reports the exact stage/target the App can act
 * on plus an honest [OfficeSaveCopySourceRetention]. In-flight state is
 * RAM-only — no process-death durability is claimed anywhere in this class.
 */
sealed class OfficeSaveCopyOutcome {
    abstract val identity: OfficeSaveCopyIdentity
    /** Honest source-retention state — never an unproven recovery claim. */
    abstract val sourceRetention: OfficeSaveCopySourceRetention

    /** Distinct destination written and verified byte-identical to the source. */
    data class CopiedVerified(
        override val identity: OfficeSaveCopyIdentity,
        val destination: SafDocumentRef,
        val bytes: Long,
        val sourceSha256: String,
        val destinationSha256: String,
        /** Flags the system actually persisted at pick-accept time. */
        val grantPersisted: Set<SafAccessFlag>,
        /** True when some granted flag lives only as the current-session grant. */
        val grantTransientOnly: Boolean,
        override val sourceRetention: OfficeSaveCopySourceRetention =
            OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
    ) : OfficeSaveCopyOutcome()

    /** User cancelled / no target, or the App requested cancel/retire and IO drained. */
    data class Cancelled(
        override val identity: OfficeSaveCopyIdentity,
        val stage: OfficeSaveCopyStage,
        val reason: String,
        val targetUri: SafUriRef? = null,
        val partialWritePossible: Boolean = false,
        override val sourceRetention: OfficeSaveCopySourceRetention =
            OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION,
    ) : OfficeSaveCopyOutcome()

    /**
     * The copy did not complete verifiably. [ownedTargetUri] preserves the
     * exact destination for actionable recovery when a target exists; an
     * uncertain partial destination is NEVER deleted here and never relabeled
     * success. Unknown provider atomicity stays honestly unclaimed.
     */
    data class Failed(
        override val identity: OfficeSaveCopyIdentity,
        val code: String,
        val stage: OfficeSaveCopyStage,
        val detail: String? = null,
        val ownedTargetUri: SafUriRef? = null,
        val partialWritePossible: Boolean = false,
        override val sourceRetention: OfficeSaveCopySourceRetention =
            OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION,
    ) : OfficeSaveCopyOutcome()

    /** A late/replayed call that cannot bind this operation — never success. */
    data class Stale(
        override val identity: OfficeSaveCopyIdentity,
        val reason: String,
        override val sourceRetention: OfficeSaveCopySourceRetention =
            OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION,
    ) : OfficeSaveCopyOutcome()
}

sealed class OfficeSaveCopyPrepareResult {
    data class Prepared(val spec: PickRequestSpec, val identity: OfficeSaveCopyIdentity) : OfficeSaveCopyPrepareResult()
    /** One current save per controller: finish or cancel the active one first. */
    data class Busy(val activeIdentity: OfficeSaveCopyIdentity) : OfficeSaveCopyPrepareResult()
    data class Stale(val identity: OfficeSaveCopyIdentity, val reason: String) : OfficeSaveCopyPrepareResult()
    data class Invalid(val reason: String) : OfficeSaveCopyPrepareResult()
}

sealed class OfficeSaveCopyDelivery {
    data class TargetAccepted(
        val identity: OfficeSaveCopyIdentity,
        val uri: SafUriRef,
        val granted: Set<SafAccessFlag>,
        val persisted: Set<SafAccessFlag>,
        val transientOnly: Boolean,
    ) : OfficeSaveCopyDelivery()

    /** null/empty system result or a retired-mid-acceptance — the operation is terminal Cancelled. */
    data class NoTarget(val identity: OfficeSaveCopyIdentity, val reason: String) : OfficeSaveCopyDelivery()

    /** Shape the gateway refuses (non-content, kind mismatch, missing flags,
     *  result aliasing the source original, live access denied). Terminal. */
    data class Refused(val identity: OfficeSaveCopyIdentity, val code: String, val detail: String) :
        OfficeSaveCopyDelivery()

    /** Not the exact current claimed operation — never settles, never publishes. */
    data class Stale(val identity: OfficeSaveCopyIdentity, val reason: String) : OfficeSaveCopyDelivery()
}

/** Result of a bounded [OfficeSaveCopyController.retire] request. */
sealed class OfficeSaveCopyRetirement {
    /** Nothing was in flight: settled Cancelled, and only the controller's own
     *  source borrow (its lease close) was released. */
    data class Retired(val identity: OfficeSaveCopyIdentity) : OfficeSaveCopyRetirement()

    /** An acceptance or IO pass is in flight for this exact operation: it is
     *  NEVER cleared or lease-released here. The running owner settles and
     *  releases at quiescence. */
    data class Deferred(val identity: OfficeSaveCopyIdentity) : OfficeSaveCopyRetirement()

    /** Not the exact current operation — the request changed nothing. */
    data class Stale(val identity: OfficeSaveCopyIdentity, val reason: String) : OfficeSaveCopyRetirement()
}

sealed class OfficeSaveCopyState {
    data class Idle(val settled: OfficeSaveCopyOutcome?) : OfficeSaveCopyState()
    data class Active(
        val identity: OfficeSaveCopyIdentity,
        val stage: OfficeSaveCopyStage,
        val targetUri: SafUriRef?,
    ) : OfficeSaveCopyState()
}

/**
 * App-owned Office Save Copy controller over the existing SAF gateway, bound to
 * EXACTLY ONE Office session ([sessionToken]). A new Office session uses a new
 * controller instance; a foreign session's identities can never prepare,
 * deliver or transfer on this one, and this controller can never be
 * re-prepared into another session (Main review finding 3, 2026-10-26).
 *
 * Settled first slice (Main 2026-10-26): explicit Edit Copy -> native private
 * OUTPUT_READY -> system CREATE_DOCUMENT -> actual stream + destination
 * read-back -> App COPY_SAVED. The controller:
 *  - PREPARES the gateway CREATE_DOCUMENT spec ([com.floe.android.safgateway.SafGrantGateway.pickerForCreateDocument])
 *    and consumes the REAL system result through [com.floe.android.safgateway.SafGrantGateway.acceptPickResult]
 *    — actual returned flags only, WRITE and READ both required, a result
 *    aliasing the source original (exact URI, or same-authority known document
 *    id) refused BEFORE the acceptance can persist any rights;
 *  - requires the EXACT current operation identity on every [deliverPickResult]
 *    and [transfer] call — there is no permissive null/default that transfers
 *    "whichever operation exists";
 *  - atomically CLAIMS the single acceptance slot under the lock before any
 *    gateway call, so duplicate/late picker callbacks are Stale and only the
 *    exactly-claimed operation can publish a target or a terminal settlement;
 *    a retired-mid-acceptance operation never publishes its target;
 *  - NEVER starts an Activity: the foreground OfficeActivity launches the
 *    Main-prepared Intent from [OfficeSaveCopyPrepareResult.Prepared.spec] and
 *    forwards resultCode/URI/flags via a session-bound Main capability;
 *  - writes ONLY the distinct document that CREATE_DOCUMENT returned, in 64 KiB
 *    chunks under the 256 MiB Office cap, hashing the source while streaming,
 *    staging to controller scratch verified BEFORE the provider is touched,
 *    then requires destination read-back size+SHA equality before reporting
 *    [OfficeSaveCopyOutcome.CopiedVerified];
 *  - treats cancel as a REQUEST: the token is honored between chunks, streams
 *    are closed, and grant references, scratch and the caller's source borrow
 *    (lease) are released exactly once — after the settle publishes, never
 *    mid-IO — on every real exit: delivery terminals, retire, grant-retention
 *    failure and all IO paths. A caller-view detach never drops IO — Main runs
 *    [transfer] on the gateway/service IO context (e.g. [SafGatewayService.submit])
 *    and owns the [com.floe.android.safgateway.SafOperation] token.
 *
 * Long IO is owned by the application/service lifetime, not a view: construct
 * one controller per Office session surface, run [transfer] off the UI thread,
 * and consult [state]/[settledOutcome] for progress.
 */
class OfficeSaveCopyController(
    private val service: SafGatewayService,
    private val backend: SafPlatformBackend,
    /** Exact Office session token this controller instance is bound for life. */
    private val sessionToken: String,
    /** Caller-owned existing directory for the controller's scratch staging. */
    stagingRoot: File,
    private val limits: SafLimits = SafLimits.DEFAULT,
    /**
     * Grant retention seam: default shares the app-wide broker; tests inject a recorder.
     * A seam that throws AFTER taking some references must release its own partials
     * first (the default does); the controller treats a throwing seam as a
     * pre-IO grant-retention failure and settles that operation Failed.
     */
    private val retainGrants: (SafUriRef, Set<SafAccessFlag>) -> List<SafSharedGrantBroker.Lease> = { uri, flags ->
        val taken = ArrayList<SafSharedGrantBroker.Lease>(flags.size)
        try {
            for (flag in flags) taken += SharedUriGrantAuthority.broker.retain(uri, flag)
            taken
        } catch (failure: RuntimeException) {
            taken.asReversed().forEach { runCatching { it.release() } }
            throw failure
        }
    },
) {

    init {
        require(sessionToken.isNotBlank()) { "sessionToken must be the exact non-blank Office session binding" }
    }

    private val scratchRoot: File = run {
        val root = runCatching { stagingRoot.canonicalFile }.getOrNull()
            ?: throw IllegalArgumentException("staging root not resolvable")
        require(root.isDirectory) { "staging root must be a caller-created directory" }
        root
    }

    private val lock = Any()
    private var current: Active? = null
    private var lastIdentity: OfficeSaveCopyIdentity? = null
    private var terminal: OfficeSaveCopyOutcome? = null

    private class Active(
        val source: OfficeSaveCopySource,
        val spec: PickRequestSpec,
    ) {
        var stage: OfficeSaveCopyStage = OfficeSaveCopyStage.AWAITING_TARGET
        var target: SafDocumentRef? = null
        var persisted: Set<SafAccessFlag> = emptySet()
        var transientOnly: Boolean = true
        /** True once this operation's SINGLE acceptance slot is claimed (under lock). */
        var acceptanceClaimed: Boolean = false
        /** A retire arrived while acceptance/IO was in flight; owners honor it at quiescence. */
        var retireRequested: Boolean = false
        /** Exactly-once source-lease release flag for this operation. */
        var leaseReleased: Boolean = false
    }

    // -----------------------------------------------------------------------
    // 1. Prepare the CREATE_DOCUMENT picker spec (Main launches the Intent)
    // -----------------------------------------------------------------------

    fun prepare(source: OfficeSaveCopySource): OfficeSaveCopyPrepareResult = synchronized(lock) {
        if (source.identity.sessionToken != sessionToken) {
            return OfficeSaveCopyPrepareResult.Stale(
                source.identity, "controller is bound to Office session $sessionToken, not ${source.identity.sessionToken}",
            )
        }
        val active = current
        if (active != null) return OfficeSaveCopyPrepareResult.Busy(active.source.identity)
        val last = lastIdentity
        if (last != null) {
            if (last == source.identity) {
                return OfficeSaveCopyPrepareResult.Stale(
                    source.identity, "operation already settled; prepare a new generation",
                )
            }
            // All identities in this controller share one session token, so the
            // generation is a strictly increasing PER-SAVE ordinal (never a
            // native document generation).
            if (source.identity.generation <= last.generation) {
                return OfficeSaveCopyPrepareResult.Stale(
                    source.identity,
                    "generation ${source.identity.generation} is not newer than settled ${last.generation}",
                )
            }
        }
        val spec = try {
            service.grants.pickerForCreateDocument(source.mimeType, source.suggestedName)
        } catch (illegal: IllegalArgumentException) {
            return OfficeSaveCopyPrepareResult.Invalid(illegal.message ?: "picker spec refused")
        }
        terminal = null
        current = Active(source, spec)
        OfficeSaveCopyPrepareResult.Prepared(spec, source.identity)
    }

    // -----------------------------------------------------------------------
    // 2. Consume the REAL system picker result (forwarded by the foreground UI)
    // -----------------------------------------------------------------------

    /**
     * Deliver the actual picker result for the EXACT operation [identity]. The
     * single acceptance slot is claimed atomically before leaving the lock: a
     * duplicate, late or foreign callback is Stale and never reaches the
     * gateway acceptance (which could otherwise persist rights for a stale
     * result). Only the claimed operation can publish a target or settle.
     */
    fun deliverPickResult(
        resultUriString: String?,
        returnedIntentFlags: Int,
        identity: OfficeSaveCopyIdentity,
    ): OfficeSaveCopyDelivery {
        val active = synchronized(lock) {
            val a = current
                ?: return OfficeSaveCopyDelivery.Stale(
                    identity, "no active save-copy operation for this identity (settled, retired or never prepared)",
                )
            if (a.source.identity != identity) {
                return OfficeSaveCopyDelivery.Stale(
                    identity, "exact current operation identity required; result belongs to a different operation",
                )
            }
            if (a.stage != OfficeSaveCopyStage.AWAITING_TARGET || a.target != null || a.acceptanceClaimed) {
                return OfficeSaveCopyDelivery.Stale(
                    identity, "this operation's single acceptance slot is already claimed or fulfilled",
                )
            }
            a.acceptanceClaimed = true
            a
        }
        val source = active.source

        // Identity/ownership decisions are ordered BEFORE gateway acceptance,
        // because acceptance may persist rights (Main review finding 4): a
        // result aliasing the known original must never become a grant.
        if (!resultUriString.isNullOrEmpty() && knownResultIsOriginal(source, resultUriString)) {
            return refuseDelivery(
                active, "result-is-original",
                "CREATE_DOCUMENT result is the source original by exact URI or same-authority document id; refusing to overwrite it",
            )
        }

        // Settled service repair (Main review 2026-10-26): AndroidSafBackend.classifyUri
        // and persistedGrants are guarded and may throw SafBackendFaultException; an
        // unexpected RuntimeException must strand NOTHING. Once the acceptance slot is
        // claimed, a backend fault that unwinds the gateway call has already quiesced
        // that acceptance (no callback IO remains in flight), so the EXACT claimed
        // Active settles here and its borrow releases exactly once. Anything the
        // gateway itself may already have persisted or noted stays under the
        // gateway/host-broker ownership — this controller never deletes, releases or
        // relabels an uncertain destination or grant.
        val accepted = try {
            service.grants.acceptPickResult(active.spec, resultUriString, returnedIntentFlags)
        } catch (fault: SafBackendFaultException) {
            return refuseDelivery(
                active, "acceptance-backend-fault",
                "backend ${fault.fault.name.lowercase()} threw during pick acceptance: ${fault.message?.take(120) ?: "no detail"}",
            )
        } catch (runtime: RuntimeException) {
            return refuseDelivery(
                active, "acceptance-runtime-fault",
                "unexpected ${runtime.javaClass.simpleName} during pick acceptance: ${runtime.message?.take(120) ?: "no detail"}",
            )
        }
        return when (accepted) {
            is PickAcceptResult.Cancelled -> {
                val outcome = OfficeSaveCopyOutcome.Cancelled(
                    source.identity, OfficeSaveCopyStage.AWAITING_TARGET, reason = accepted.reason,
                )
                if (settleDelivery(active, outcome)) {
                    OfficeSaveCopyDelivery.NoTarget(source.identity, accepted.reason)
                } else {
                    OfficeSaveCopyDelivery.Stale(source.identity, "operation was already settled during acceptance")
                }
            }
            is PickAcceptResult.Rejected -> {
                val outcome = OfficeSaveCopyOutcome.Failed(
                    source.identity, code = "pick-${accepted.reason}", stage = OfficeSaveCopyStage.AWAITING_TARGET,
                    detail = accepted.detail,
                )
                if (settleDelivery(active, outcome)) {
                    OfficeSaveCopyDelivery.Refused(source.identity, accepted.reason, accepted.detail)
                } else {
                    OfficeSaveCopyDelivery.Stale(source.identity, "operation was already settled during refusal")
                }
            }
            is PickAcceptResult.Accepted -> acceptLiveTarget(active, accepted)
        }
    }

    /**
     * Known-original alias refusal: exact URI string, or — only when the
     * original carries a known document id — the backend-resolved document id
     * equal on the SAME provider authority. No cross-provider alias certainty
     * and no provider CAS is claimed; a null/unresolvable returned id falls
     * back to the exact-URI rule only.
     */
    private fun knownResultIsOriginal(source: OfficeSaveCopySource, resultUriString: String): Boolean {
        val original = source.original ?: return false
        if (original.uri.uriString == resultUriString) return true
        val knownId = original.documentId ?: return false
        val returnedId = runCatching { backend.documentIdOf(SafUriRef(resultUriString)) }.getOrNull() ?: return false
        if (returnedId != knownId) return false
        val returnedAuthority = uriAuthority(resultUriString)
        val originalAuthority = uriAuthority(original.uri.uriString)
        return returnedAuthority != null && originalAuthority != null && returnedAuthority == originalAuthority
    }

    private fun uriAuthority(uriString: String): String? =
        runCatching { URI(uriString).authority }.getOrNull()?.takeIf { it.isNotBlank() }
            ?: uriString.takeIf { it.startsWith("content://") }
                ?.substringAfter("content://")?.substringBefore('/')?.takeIf { it.isNotBlank() }

    private fun acceptLiveTarget(
        active: Active,
        accepted: PickAcceptResult.Accepted,
    ): OfficeSaveCopyDelivery {
        val source = active.source
        if (SafAccessFlag.WRITE !in accepted.granted) {
            return refuseDelivery(active, "missing-write-flag", "system result carried no WRITE grant")
        }
        if (SafAccessFlag.READ !in accepted.granted) {
            return refuseDelivery(active, "missing-read-flag", "read-back requires the READ grant actually returned")
        }
        // Mirror saveAsAccepted: only an explicit platform denial fails here;
        // UNKNOWN stays optimistic and the real descriptor open is the word.
        // Settled service repair: the probe path (persistedGrants + platform probe)
        // may throw a guarded backend fault or an unexpected RuntimeException; the
        // exact claimed Active settles and releases its borrow, and no target is
        // ever published from a faulted probe.
        val evidence = try {
            service.grants.currentAccess(accepted.uri)
        } catch (fault: SafBackendFaultException) {
            return refuseDelivery(
                active, "live-access-backend-fault",
                "backend ${fault.fault.name.lowercase()} threw during live-access probe: ${fault.message?.take(120) ?: "no detail"}",
            )
        } catch (runtime: RuntimeException) {
            return refuseDelivery(
                active, "live-access-runtime-fault",
                "unexpected ${runtime.javaClass.simpleName} during live-access probe: ${runtime.message?.take(120) ?: "no detail"}",
            )
        }
        val readLive = evidence.read || evidence.probeRead != ProbeFlag.DENIED
        val writeLive = evidence.write || evidence.probeWrite != ProbeFlag.DENIED
        if (!readLive || !writeLive) {
            return refuseDelivery(active, "access-not-live", "platform probe denies the returned grant")
        }
        // Publish ONLY if the exact claimed Active is still current and not
        // retired: the lock was dropped for the gateway acceptance + probe, and
        // a retired-mid-acceptance operation must never publish a target.
        val published = synchronized(lock) {
            if (
                current === active && active.acceptanceClaimed && active.target == null &&
                active.stage == OfficeSaveCopyStage.AWAITING_TARGET && !active.retireRequested
            ) {
                active.target = SafDocumentRef(tree = null, documentId = null, parentDocumentId = null, uri = accepted.uri)
                active.persisted = accepted.persisted
                active.transientOnly = accepted.transientOnly
                true
            } else {
                false
            }
        }
        if (!published) {
            val retired = synchronized(lock) { active.retireRequested }
            if (retired) {
                val reason = "retired during acceptance; no target published"
                val outcome = OfficeSaveCopyOutcome.Cancelled(source.identity, OfficeSaveCopyStage.AWAITING_TARGET, reason)
                return if (settleDelivery(active, outcome)) {
                    OfficeSaveCopyDelivery.NoTarget(source.identity, reason)
                } else {
                    OfficeSaveCopyDelivery.Stale(source.identity, "operation was already settled during acceptance")
                }
            }
            return OfficeSaveCopyDelivery.Stale(
                source.identity, "operation is no longer current during acceptance; no target published",
            )
        }
        return OfficeSaveCopyDelivery.TargetAccepted(
            source.identity, accepted.uri, accepted.granted, accepted.persisted, accepted.transientOnly,
        )
    }

    /** Settle the claimed delivery as Failed and report honestly. */
    private fun refuseDelivery(active: Active, code: String, detail: String): OfficeSaveCopyDelivery {
        val source = active.source
        val outcome = OfficeSaveCopyOutcome.Failed(
            source.identity, code = code, stage = OfficeSaveCopyStage.AWAITING_TARGET, detail = detail,
        )
        return if (settleDelivery(active, outcome)) {
            OfficeSaveCopyDelivery.Refused(source.identity, code, detail)
        } else {
            OfficeSaveCopyDelivery.Stale(source.identity, "operation was already settled during refusal")
        }
    }

    /**
     * Publish a delivery-stage terminal ONLY for the exact still-current
     * claimed operation, then release only this operation's source borrow
     * (exactly once — no IO is in flight on any delivery-terminal path).
     */
    private fun settleDelivery(active: Active, outcome: OfficeSaveCopyOutcome): Boolean {
        val settled = synchronized(lock) {
            if (current !== active || active.source.identity != outcome.identity) {
                false
            } else {
                current = null
                lastIdentity = outcome.identity
                terminal = outcome
                true
            }
        }
        if (settled) releaseSourceLeaseOnce(active)
        return settled
    }

    // -----------------------------------------------------------------------
    // 3. Bounded retire (exact identity only; quiescence-deferred)
    // -----------------------------------------------------------------------

    /**
     * Retire the exact current operation. If an acceptance or IO pass is in
     * flight, this NEVER clears it or releases its lease ([OfficeSaveCopyRetirement.Deferred]):
     * the running owner settles and releases at quiescence. Only a waiting
     * operation (picker not answered, or target accepted but transfer not
     * started) settles immediately here, Cancelled, with the source borrow
     * released exactly once.
     */
    fun retire(identity: OfficeSaveCopyIdentity): OfficeSaveCopyRetirement {
        val result: Pair<OfficeSaveCopyRetirement, Active?> = synchronized(lock) {
            val a = current
            if (a == null) {
                val reason = if (lastIdentity == identity) {
                    "operation already settled"
                } else {
                    "no active save-copy operation for this identity"
                }
                OfficeSaveCopyRetirement.Stale(identity, reason) to null
            } else if (a.source.identity != identity) {
                OfficeSaveCopyRetirement.Stale(identity, "retire requires the exact current operation identity") to null
            } else if ((a.acceptanceClaimed && a.target == null) || a.stage != OfficeSaveCopyStage.AWAITING_TARGET ||
                a.retireRequested
            ) {
                a.retireRequested = true
                OfficeSaveCopyRetirement.Deferred(identity) to null
            } else {
                val cancelled = OfficeSaveCopyOutcome.Cancelled(
                    identity, OfficeSaveCopyStage.AWAITING_TARGET,
                    reason = "retired by App before transfer",
                    targetUri = a.target?.uri,
                )
                current = null
                lastIdentity = identity
                terminal = cancelled
                OfficeSaveCopyRetirement.Retired(identity) to a
            }
        }
        val (retirement, released) = result
        released?.let { releaseSourceLeaseOnce(it) }
        return retirement
    }

    // -----------------------------------------------------------------------
    // 4. Transfer: bounded staged verify -> provider write -> read-back verify.
    //    Run on the gateway/service IO context (Main: service.submit { ... }).
    // -----------------------------------------------------------------------

    /**
     * Run the transfer for the EXACT operation [identity]. A foreign or
     * already-settled identity gets a Stale outcome and can neither touch the
     * current operation nor its resources; once the operation is settled, its
     * own terminal outcome is returned idempotently.
     */
    fun transfer(identity: OfficeSaveCopyIdentity, cancel: SafCancelToken): OfficeSaveCopyOutcome {
        val active = synchronized(lock) {
            val a = current
            if (a == null) {
                val settled = terminal
                return if (settled != null && settled.identity == identity) {
                    settled
                } else {
                    OfficeSaveCopyOutcome.Stale(identity, "no active save-copy operation for this identity")
                }
            }
            if (a.source.identity != identity) {
                return OfficeSaveCopyOutcome.Stale(identity, "transfer requires the exact current operation identity")
            }
            if (a.target == null) {
                return OfficeSaveCopyOutcome.Stale(identity, "no accepted target; deliver the picker result first")
            }
            if (a.stage != OfficeSaveCopyStage.AWAITING_TARGET) {
                return OfficeSaveCopyOutcome.Stale(identity, "transfer already running or settled")
            }
            a.stage = OfficeSaveCopyStage.TRANSFERRING
            a
        }
        val source = active.source
        val target = active.target!!
        // Grant references and scratch ownership live strictly inside the
        // owned IO region; the finally block below is the single drain point.
        var references: List<SafSharedGrantBroker.Lease> = emptyList()
        var scratch: File? = null
        var outcome: OfficeSaveCopyOutcome? = null
        try {
            references = try {
                retainGrants(target.uri, setOf(SafAccessFlag.READ, SafAccessFlag.WRITE))
            } catch (retention: RuntimeException) {
                // The seam released (or never took) its partials; zero IO started.
                val failure = OfficeSaveCopyOutcome.Failed(
                    source.identity, code = "grant-retention-failed",
                    stage = OfficeSaveCopyStage.TRANSFERRING,
                    detail = "grant retention failed before any IO: ${retention.message}",
                    ownedTargetUri = target.uri, partialWritePossible = false,
                )
                outcome = failure
                return failure
            }
            val result: OfficeSaveCopyOutcome = try {
                transferLocked(source, target, active, cancel) { staged -> scratch = staged }
            } catch (unexpected: RuntimeException) {
                OfficeSaveCopyOutcome.Failed(
                    source.identity, code = "unexpected-${unexpected.javaClass.simpleName}",
                    stage = activeStage(active), detail = unexpected.message,
                    ownedTargetUri = target.uri, partialWritePossible = true,
                )
            }
            outcome = result
            return result
        } finally {
            // IO quiescence reached. Publish this operation's settle ONLY if it
            // is still the controller's current (never overwrite another
            // Active's state), then drain exactly this operation's own
            // references, scratch copy and source borrow — never mid-IO, and
            // never another feature's grant references (broker per-lease release).
            synchronized(lock) {
                if (current === active) {
                    current = null
                    lastIdentity = source.identity
                    if (outcome != null) terminal = outcome
                }
            }
            references.asReversed().forEach { runCatching { it.release() } }
            scratch?.let { runCatching { it.delete() } }
            releaseSourceLeaseOnce(active)
        }
    }

    private fun activeStage(active: Active): OfficeSaveCopyStage = synchronized(lock) { active.stage }

    private inline fun transferLocked(
        source: OfficeSaveCopySource,
        target: SafDocumentRef,
        active: Active,
        cancel: SafCancelToken,
        onStaged: (File) -> Unit,
    ): OfficeSaveCopyOutcome {
        // Phase 1: stage the trusted source bytes into controller scratch,
        // bounded and hashed. The provider destination is NOT touched until
        // the staged bytes prove to be exactly the verified output.
        val staged = stageSource(source, cancel)
        val stagedFile: File
        val stagedSha: String
        when (staged) {
            is SafOutcome.Failure -> return cancelledOrFailed(
                source, staged.failure, staged.detail, target, OfficeSaveCopyStage.TRANSFERRING,
                partial = false, retention = OfficeSaveCopySourceRetention.UNPROVEN_CALLER_OBLIGATION,
            )
            is SafOutcome.Success -> {
                stagedFile = staged.value.first
                stagedSha = staged.value.second
            }
        }
        // The controller now OWNS the staged scratch file: the caller's transfer
        // finally block deletes it after all IO settles.
        onStaged(stagedFile)
        if (stagedFile.length() != source.lengthBytes) {
            return OfficeSaveCopyOutcome.Failed(
                source.identity, code = "source-length-mismatch", stage = OfficeSaveCopyStage.TRANSFERRING,
                detail = "streamed ${stagedFile.length()} bytes, expected ${source.lengthBytes}",
                partialWritePossible = false,
                sourceRetention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
        }
        if (stagedSha != source.expectedSha256) {
            return OfficeSaveCopyOutcome.Failed(
                source.identity, code = "source-hash-mismatch", stage = OfficeSaveCopyStage.TRANSFERRING,
                detail = "staged bytes differ from the verified native output; nothing was written",
                partialWritePossible = false,
                sourceRetention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
        }

        // Phase 2: write the staged bytes into the DISTINCT picked document.
        val writeFailure = writeToDestination(stagedFile, source, target, cancel)
        if (writeFailure != null) return writeFailure

        // Phase 3: read the destination back; size+SHA equality is the ONLY
        // path to CopiedVerified.
        synchronized(lock) { active.stage = OfficeSaveCopyStage.VERIFYING }
        val readback = service.operations.streamRead(target, OfficeSaveCopySource.MAX_BYTES, null, cancel) { _, _ -> }
        return when (readback) {
            is SafOutcome.Failure -> cancelledOrFailed(
                source, readback.failure, readback.detail, target, OfficeSaveCopyStage.VERIFYING,
                partial = true, retention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
            is SafOutcome.Success -> {
                val summary = readback.value
                if (!summary.completed || summary.bytes != source.lengthBytes || summary.sha256 != source.expectedSha256) {
                    OfficeSaveCopyOutcome.Failed(
                        source.identity, code = "verify-mismatch", stage = OfficeSaveCopyStage.VERIFYING,
                        detail = "read-back ${summary.bytes} bytes sha ${summary.sha256}; " +
                            "expected ${source.lengthBytes} bytes sha ${source.expectedSha256}",
                        ownedTargetUri = target.uri, partialWritePossible = true,
                        sourceRetention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
                    )
                } else {
                    OfficeSaveCopyOutcome.CopiedVerified(
                        identity = source.identity,
                        destination = target,
                        bytes = summary.bytes,
                        sourceSha256 = source.expectedSha256,
                        destinationSha256 = summary.sha256,
                        grantPersisted = active.persisted,
                        grantTransientOnly = active.transientOnly,
                    )
                }
            }
        }
    }

    /** Returns the failure outcome, or null when the write settled cleanly. */
    private fun writeToDestination(
        stagedFile: File,
        source: OfficeSaveCopySource,
        target: SafDocumentRef,
        cancel: SafCancelToken,
    ): OfficeSaveCopyOutcome? {
        val open = try {
            backend.openWriteTruncate(target, cancel)
        } catch (fault: SafBackendFaultException) {
            return cancelledOrFailed(
                source, fault.fault.toFailure(), fault.message, target, OfficeSaveCopyStage.TRANSFERRING,
                partial = false, retention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
        } catch (io: IOException) {
            return cancelledOrFailed(
                source, SafFailure.Io(io.message ?: "write open io"), null, target, OfficeSaveCopyStage.TRANSFERRING,
                partial = false, retention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
        }
        return when (open) {
            is com.floe.android.safgateway.WriteOpen.UnsupportedMode -> OfficeSaveCopyOutcome.Failed(
                source.identity, code = "write-unsupported", stage = OfficeSaveCopyStage.TRANSFERRING,
                detail = "provider rejects truncate-write on the picked document",
                ownedTargetUri = target.uri, partialWritePossible = false,
                sourceRetention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
            is com.floe.android.safgateway.WriteOpen.NotFound -> OfficeSaveCopyOutcome.Failed(
                source.identity, code = "not-found", stage = OfficeSaveCopyStage.TRANSFERRING,
                detail = "the picked document is gone before the write",
                partialWritePossible = false,
                sourceRetention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
            )
            is com.floe.android.safgateway.WriteOpen.Opened -> {
                val buffer = ByteArray(limits.chunkBytes)
                var failure: SafFailure? = null
                try {
                    stagedFile.inputStream().use { input ->
                        open.output.use { output ->
                            while (true) {
                                cancel.ensureActive()
                                val n = input.read(buffer)
                                if (n < 0) break
                                output.write(buffer, 0, n)
                            }
                            output.flush()
                        }
                    }
                } catch (cancelled: SafCancelledException) {
                    failure = SafFailure.Cancelled
                } catch (io: IOException) {
                    failure = SafFailure.Io(io.message ?: "write io")
                } catch (fault: SafBackendFaultException) {
                    failure = fault.fault.toFailure()
                }
                val f = failure
                if (f != null) {
                    cancelledOrFailed(
                        source, f, "provider write did not settle cleanly", target, OfficeSaveCopyStage.TRANSFERRING,
                        partial = true, retention = OfficeSaveCopySourceRetention.FULLY_OBSERVED_THIS_ATTEMPT,
                    )
                } else {
                    null
                }
            }
        }
    }

    /** Map a terminal SafFailure to Cancelled (cancel only) or Failed. */
    private fun cancelledOrFailed(
        source: OfficeSaveCopySource,
        failure: SafFailure,
        detail: String?,
        target: SafDocumentRef,
        stage: OfficeSaveCopyStage,
        partial: Boolean,
        retention: OfficeSaveCopySourceRetention,
    ): OfficeSaveCopyOutcome = if (failure == SafFailure.Cancelled) {
        OfficeSaveCopyOutcome.Cancelled(
            source.identity, stage, reason = detail ?: "cancelled",
            targetUri = target.uri, partialWritePossible = partial,
            sourceRetention = retention,
        )
    } else {
        OfficeSaveCopyOutcome.Failed(
            source.identity, code = failure.code, stage = stage, detail = detail,
            ownedTargetUri = target.uri, partialWritePossible = partial,
            sourceRetention = retention,
        )
    }

    // -----------------------------------------------------------------------
    // Observation
    // -----------------------------------------------------------------------

    /** The settled outcome of the last operation (null once a new one prepares). */
    fun settledOutcome(): OfficeSaveCopyOutcome? = synchronized(lock) { terminal }

    fun state(): OfficeSaveCopyState = synchronized(lock) {
        val a = current
        when {
            a == null -> OfficeSaveCopyState.Idle(terminal)
            else -> OfficeSaveCopyState.Active(a.source.identity, a.stage, a.target?.uri)
        }
    }

    // -----------------------------------------------------------------------
    // Internal bounded staging + hashing
    // -----------------------------------------------------------------------

    /** Stage the trusted source stream into caller scratch; bounded 256 MiB, hashed. */
    private fun stageSource(source: OfficeSaveCopySource, cancel: SafCancelToken): SafOutcome<Pair<File, String>> {
        val part = File(scratchRoot, "office-save-copy-${UUID.randomUUID()}.part")
        if (!isWithin(scratchRoot, part)) return SafOutcome.failure(SafFailure.Failed("scratch escaped caller root"))
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(limits.chunkBytes)
        var total = 0L
        try {
            source.openBytes(cancel).use { input ->
                FileOutputStream(part).use { out ->
                    while (true) {
                        cancel.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        if (total + n > OfficeSaveCopySource.MAX_BYTES) {
                            runCatching { part.delete() }
                            return SafOutcome.failure(SafFailure.SizeLimitExceeded(OfficeSaveCopySource.MAX_BYTES))
                        }
                        out.write(buffer, 0, n)
                        digest.update(buffer, 0, n)
                        total += n
                    }
                    // Durability BEFORE verification: a failed flush/sync means
                    // the staged bytes cannot be trusted as the verified output,
                    // so the real IOException propagates to the caller below —
                    // it is never silently swallowed (Main review finding 1).
                    out.flush()
                    out.fd.sync()
                }
            }
        } catch (cancelled: SafCancelledException) {
            runCatching { part.delete() }
            return SafOutcome.failure(SafFailure.Cancelled)
        } catch (io: IOException) {
            runCatching { part.delete() }
            return SafOutcome.failure(SafFailure.Io(io.message ?: "source staging io"))
        } catch (unexpected: RuntimeException) {
            // Settled service repair (Main review 2026-10-26): an unexpected
            // failure (a throwing opener, a stream that raises a non-IOException, ...)
            // must still remove the OWNED .part before onStaged ever runs — the outer
            // transfer handler keeps scratch=null and could not clean it. Deleting
            // only this owned part, the original failure is rethrown unchanged
            // (never swallowed, never relabeled), and the caller's output or an
            // uncertain provider destination is never touched here.
            runCatching { part.delete() }
            throw unexpected
        }
        val hex = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        return SafOutcome.success(part to hex)
    }

    /** Release this operation's source borrow exactly once (never mid-IO). */
    private fun releaseSourceLeaseOnce(active: Active) {
        val lease = active.source.lease ?: return
        val shouldClose = synchronized(lock) {
            if (active.leaseReleased) false else {
                active.leaseReleased = true
                true
            }
        }
        if (shouldClose) runCatching { lease.close() }
    }

    private fun isWithin(root: File, candidate: File): Boolean {
        val r = runCatching { root.canonicalFile }.getOrNull() ?: return false
        val c = runCatching { candidate.canonicalFile }.getOrNull() ?: return false
        return c.path != r.path && c.path.startsWith(r.path + File.separator)
    }

    private fun SafBackendFault.toFailure(): SafFailure = when (this) {
        SafBackendFault.REVOKED -> SafFailure.Revoked
        SafBackendFault.GRANT_MISSING -> SafFailure.GrantMissing
        SafBackendFault.OFFLINE -> SafFailure.ProviderOffline
        SafBackendFault.UNSUPPORTED -> SafFailure.Unsupported("the document provider rejected this operation")
        SafBackendFault.NOT_FOUND -> SafFailure.NotFound
        SafBackendFault.CANCELLED -> SafFailure.Cancelled
        SafBackendFault.IO -> SafFailure.Io("provider io error")
        SafBackendFault.FAILED -> SafFailure.Failed("provider failure")
    }
}
