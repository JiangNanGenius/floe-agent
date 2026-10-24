// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Host-owned serialized release broker (Main steering 2026-10-24 defect 3).
 * A plain Boolean check is TOCTOU: between "nobody else references it" and
 * the actual platform release, another feature can take/reuse the SAME shared
 * OS grant. The contract is therefore execute-under-exclusive-authority:
 * the broker MUST hold the host's serialized retain/release section across
 * both the decision AND the [release] callback invocation, and must invoke
 * the callback at most once (never after returning Retained).
 */
interface SafReleaseBroker {
    fun executeReleaseUnderExclusiveAuthority(
        uri: SafUriRef,
        flag: SafAccessFlag,
        release: () -> Boolean,
    ): BrokeredRelease
}

sealed class BrokeredRelease {
    /** The broker invoked [release] exactly once inside its exclusive section. */
    data class Executed(val succeeded: Boolean) : BrokeredRelease()

    /** The broker did NOT invoke the callback (other references remain / policy). */
    data class Retained(val reason: String) : BrokeredRelease()
}

/**
 * Grant lifecycle over the OS truth. NOT a permission policy: this class only
 *  (a) builds picker specs,
 *  (b) accepts EXPLICIT system-result URI + actual returned flags,
 *  (c) persists only flags actually granted AND offered persistably — with a
 *      truthful transient fallback when persistence fails,
 *  (d) represents PERSISTED grants and CURRENT-SESSION access separately and
 *      revalidates both at each operation and on resume (a persisted-only
 *      lookup never denies a live session grant; caches/flags confer nothing —
 *      the platform probe and the real descriptor open are the word),
 *  (e) requests release ONLY through the host's serialized exclusive broker, and
 *  (f) reports an expired session grant as one actionable typed re-pick
 *      instead of re-prompting on every operation.
 */
class SafGrantGateway internal constructor(
    private val backend: SafPlatformBackend,
    private val releaseBroker: SafReleaseBroker? = null,
) {
    private val requestSeq = AtomicLong(0)

    /** Flags PERSISTED BY THIS INSTANCE (release *candidates*, never a claim). */
    private val ownedPersisted = ConcurrentHashMap<String, MutableSet<SafAccessFlag>>()

    /** URIs this instance ever persisted (distinguishes Revoked from never-granted). */
    private val everAcquired = ConcurrentHashMap.newKeySet<String>()

    /**
     * Session access evidence from accepted explicit system results. This is a
     * MEMORY NOTE, not an authority: liveness is re-probed through the backend
     * at every operation; entries drop only after the platform says denied.
     */
    private val sessionAccess = ConcurrentHashMap<String, Set<SafAccessFlag>>()

    /**
     * URIs whose session grant the platform confirmed DEAD. They keep answering
     * typed RePickRequired (actionable once in the UI) instead of degrading to
     * a misleading "never granted" — until re-accept or forget clears them.
     */
    private val expiredSession = ConcurrentHashMap.newKeySet<String>()

    /** Rebuildable display hint cache; explicitly not an authority. */
    private val displayCache = ConcurrentHashMap<String, GrantSnapshot>()

    // -----------------------------------------------------------------------
    // Picker specs
    // -----------------------------------------------------------------------

    fun pickerForOpenDocument(mimeTypes: List<String>, initialDirectory: SafUriRef? = null): PickRequestSpec =
        PickRequestSpec(
            requestKey = "open-doc-" + requestSeq.incrementAndGet(),
            kind = PickKind.OPEN_DOCUMENT,
            mimeTypes = mimeTypes.filter { it.isNotBlank() }.distinct(),
            suggestedName = null,
            initialDirectory = initialDirectory,
        )

    fun pickerForTree(initialDirectory: SafUriRef? = null): PickRequestSpec = PickRequestSpec(
        requestKey = "open-tree-" + requestSeq.incrementAndGet(),
        kind = PickKind.OPEN_TREE,
        mimeTypes = emptyList(),
        suggestedName = null,
        initialDirectory = initialDirectory,
    )

    fun pickerForCreateDocument(mimeType: String, suggestedName: String, initialDirectory: SafUriRef? = null): PickRequestSpec {
        require(mimeType.isNotBlank())
        require(!SafStagingNames.isUnsafeDisplayName(suggestedName)) {
            "suggested name must be a single safe display segment"
        }
        return PickRequestSpec(
            requestKey = "create-doc-" + requestSeq.incrementAndGet(),
            kind = PickKind.CREATE_DOCUMENT,
            mimeTypes = listOf(mimeType),
            suggestedName = suggestedName,
            initialDirectory = initialDirectory,
        )
    }

    // -----------------------------------------------------------------------
    // Explicit system-result acceptance
    // -----------------------------------------------------------------------

    /**
     * Accept ONLY the explicit result URI string + actual returned intent
     * flags. A null/blank URI is a cancellation and never invents a grant.
     * Persistence is attempted flag-by-flag and only when the platform
     * offered the persistable bit; the SESSION grant from the system result
     * stays represented separately either way (AttachmentStagingService
     * pickedWithReadGrant precedent: persistence failure falls back to the
     * live session grant, it does not erase access).
     */
    fun acceptPickResult(spec: PickRequestSpec, resultUriString: String?, returnedIntentFlags: Int): PickAcceptResult {
        if (resultUriString.isNullOrBlank()) {
            return PickAcceptResult.Cancelled(if (resultUriString == null) "null-result" else "empty-result")
        }
        if (!resultUriString.startsWith("content://")) {
            return PickAcceptResult.Rejected("non-content-scheme", "gateway never accepts file:// or other schemes")
        }
        val granted = mutableSetOf<SafAccessFlag>()
        if (returnedIntentFlags and SafGrantFlagBits.GRANT_READ != 0) granted += SafAccessFlag.READ
        if (returnedIntentFlags and SafGrantFlagBits.GRANT_WRITE != 0) granted += SafAccessFlag.WRITE
        if (granted.isEmpty()) {
            return PickAcceptResult.Rejected("no-grant-flags", "system result carried no URI permission")
        }
        val uri = SafUriRef(resultUriString)
        val kind = backend.classifyUri(resultUriString)
        when (spec.kind) {
            PickKind.OPEN_TREE -> if (kind != SafUriKind.TREE) {
                return PickAcceptResult.Rejected("kind-mismatch", "expected a tree URI, classified $kind")
            }
            PickKind.OPEN_DOCUMENT, PickKind.CREATE_DOCUMENT -> if (kind != SafUriKind.DOCUMENT) {
                return PickAcceptResult.Rejected("kind-mismatch", "expected a document URI, classified $kind")
            }
        }
        val offeredPersistable = returnedIntentFlags and SafGrantFlagBits.PERSISTABLE != 0
        val persisted = mutableSetOf<SafAccessFlag>()
        val transientNotes = mutableListOf<String>()
        if (offeredPersistable) {
            // WRITE first for coherence with tree grants; per-flag take keeps the
            // ledger exactly aligned with what the platform actually accepted.
            for (flag in listOf(SafAccessFlag.WRITE, SafAccessFlag.READ)) {
                if (flag !in granted) continue
                when (val take = backend.takePersistable(uri, flag)) {
                    TakeOutcome.Persisted -> {
                        persisted += flag
                        ownedPersisted.computeIfAbsent(uri.uriString) { mutableSetOf() } += flag
                        everAcquired += uri.uriString
                    }
                    TakeOutcome.AlreadyHeld -> {
                        // Real persisted access exists, held by someone else in this app:
                        // observable, but NEVER a release candidate for us.
                        persisted += flag
                    }
                    is TakeOutcome.TransientOnly -> transientNotes += "${flag.name}:${take.reason}"
                    is TakeOutcome.Refused -> transientNotes += "${flag.name}:${take.reason}"
                }
            }
        } else {
            transientNotes += "persistable-not-offered"
        }
        // The system result's own session grant stands for ALL granted flags,
        // independent of persistence success.
        sessionAccess[uri.uriString] = granted.toSet()
        expiredSession.remove(uri.uriString) // a fresh explicit pick revives the identity
        val transientOnly = persisted != granted
        displayCache[uri.uriString] = GrantSnapshot(
            uri,
            read = SafAccessFlag.READ in granted,
            write = SafAccessFlag.WRITE in granted,
        )
        return PickAcceptResult.Accepted(
            uri = uri,
            kind = kind,
            granted = granted.toSet(),
            persisted = persisted.toSet(),
            transientOnly = transientOnly,
            // A lost future session grant on a transientOnly pick is re-picked
            // ONLY when the platform probe denies it (typed RePickRequired).
            needsRePickWhenExpired = transientOnly,
            reason = transientNotes.joinToString(","),
        )
    }

    // -----------------------------------------------------------------------
    // Truth queries
    // -----------------------------------------------------------------------

    /**
     * Live evidence per call: persisted OS row + platform probe of the current
     * session permission. No cached model flag is treated as conferring access.
     */
    fun currentAccess(uri: SafUriRef): AccessEvidence {
        val persisted = backend.persistedGrants().firstOrNull { it.uri == uri }
        val probe = backend.probeAccess(uri, needsRead = true, needsWrite = true)
        val read = persisted?.read == true || probe.read == ProbeFlag.GRANTED
        val write = persisted?.write == true || probe.write == ProbeFlag.GRANTED
        val optimistic = probe.read == ProbeFlag.UNKNOWN || probe.write == ProbeFlag.UNKNOWN
        if (persisted != null) displayCache[uri.uriString] = persisted
        // A platform denial also expires our session note (self-cleaning, typed).
        if (sessionAccess[uri.uriString] != null && probe.read == ProbeFlag.DENIED && probe.write == ProbeFlag.DENIED) {
            sessionAccess.remove(uri.uriString)
            expiredSession += uri.uriString
        }
        return AccessEvidence(
            uri = uri,
            read = read,
            write = write,
            persisted = persisted != null,
            probeRead = probe.read,
            probeWrite = probe.write,
            probeIsOptimistic = optimistic,
        )
    }

    /**
     * Revalidate on resume: sweep the persisted ledger AND the session notes
     * against the platform probe. Expired session evidence is dropped here so
     * the next operation produces exactly one actionable re-pick, not a prompt
     * storm.
     */
    fun revalidate(): ResumeSweep {
        val live = backend.persistedGrants()
        val liveByUri = live.associateBy { it.uri.uriString }
        val lost = mutableListOf<SafUriRef>()
        val lostSession = mutableListOf<SafUriRef>()
        ownedPersisted.keys.toList().forEach { uriString ->
            val row = liveByUri[uriString]
            val ownedFlags = ownedPersisted[uriString] ?: return@forEach
            if (row == null) {
                ownedPersisted.remove(uriString)
                lost += SafUriRef(uriString)
            } else {
                val gone = ownedFlags.filter { flag -> if (flag == SafAccessFlag.READ) !row.read else !row.write }
                ownedFlags -= gone
                if (ownedFlags.isEmpty()) ownedPersisted.remove(uriString)
                if (gone.isNotEmpty()) lost += SafUriRef(uriString)
            }
        }
        sessionAccess.keys.toList().forEach { uriString ->
            val uri = SafUriRef(uriString)
            if (liveByUri.containsKey(uriString)) return@forEach
            val probe = backend.probeAccess(uri, needsRead = true, needsWrite = true)
            if (probe.read == ProbeFlag.DENIED && probe.write == ProbeFlag.DENIED) {
                sessionAccess.remove(uriString)
                expiredSession += uriString
                lostSession += uri
            }
        }
        displayCache.keys.toList().forEach { key ->
            if (key !in liveByUri && sessionAccess[key] == null) displayCache.remove(key)
        }
        return ResumeSweep(lost = lost, lostSessionGrants = lostSession, stillGranted = live)
    }

    // -----------------------------------------------------------------------
    // Release — host-guarded only
    // -----------------------------------------------------------------------

    /**
     * Request release of flags we persisted. With NO host broker injected this
     * NEVER calls the platform. Each flag release runs as a single
     * [SafReleaseBroker] call whose callback performs the platform release
     * INSIDE the host's exclusive serialized section — the gateway never
     * releases a second flag unguarded, and never re-checks after the fact
     * (the broker owns the whole retain/release decision atomically).
     */
    fun requestRelease(uri: SafUriRef, flags: Set<SafAccessFlag>): ReleaseResult {
        val owned = ownedPersisted[uri.uriString]
        if (owned == null || owned.isEmpty()) {
            return ReleaseResult.NotOwned(heldElsewhere = currentAccess(uri).let { it.read || it.write || it.probeIsOptimistic })
        }
        val candidates = flags.filter { it in owned }.toSet()
        if (candidates.isEmpty()) return ReleaseResult.NothingOwned(persistedByUs = owned.toSet())
        val broker = releaseBroker
            ?: return ReleaseResult.RefusedNoBroker(candidates, heldElsewhere = currentAccess(uri).read || currentAccess(uri).write)
        val released = mutableSetOf<SafAccessFlag>()
        val retained = mutableSetOf<SafAccessFlag>()
        val failed = mutableSetOf<SafAccessFlag>()
        for (flag in candidates) {
            when (val outcome = broker.executeReleaseUnderExclusiveAuthority(uri, flag) { backend.releasePersistable(uri, flag) }) {
                is BrokeredRelease.Executed -> if (outcome.succeeded) released += flag else failed += flag
                is BrokeredRelease.Retained -> retained += flag
            }
        }
        owned -= released
        if (owned.isEmpty()) ownedPersisted.remove(uri.uriString)
        // Successful release of a flag does not by itself end the session note:
        // probe truth governs (other features may still hold access).
        return when {
            released.isEmpty() && retained.isNotEmpty() -> ReleaseResult.RetainedByBroker(retained)
            failed.isEmpty() && retained.isEmpty() -> ReleaseResult.Released(released)
            else -> ReleaseResult.PartiallyReleased(released, retained, failed)
        }
    }

    /** Forget LOCAL display/session notes only. OS persistence is untouched. */
    fun forget(uri: SafUriRef) {
        displayCache.remove(uri.uriString)
        sessionAccess.remove(uri.uriString)
        expiredSession.remove(uri.uriString)
    }

    fun ownedGrantUris(): Set<String> = ownedPersisted.keys.toSet()

    fun cachedDisplayHints(): Map<String, GrantSnapshot> = displayCache.toMap()

    /**
     * Drop session/display notes on shutdown. Persisted grants STAY (user
     * intent survives restarts; releasing them is host policy, never ours).
     */
    fun shutdown() {
        sessionAccess.clear()
        expiredSession.clear()
        displayCache.clear()
    }

    // -----------------------------------------------------------------------
    // Operation gating
    // -----------------------------------------------------------------------

    /**
     * Gate one operation against LIVE truth. For tree-scoped targets the grant
     * lives on the TREE URI (document URIs derived from it inherit access);
     * checking per-child persisted grants would be false truth. A WRITE
     * requirement NEVER silently takes a missing READ — the picker conversation
     * with the user belongs to the host, and the probe is read-only.
     */
    internal fun gate(ref: SafDocumentRef, needs: Set<SafAccessFlag>): GateVerdict {
        val anchor = ref.tree ?: ref.uri
        val evidence = currentAccess(anchor)
        val unmet = needs.filter { flag ->
            if (flag == SafAccessFlag.READ) !evidence.read else !evidence.write
        }
        if (unmet.isEmpty()) return GateVerdict.Allowed(evidence)
        val anyUnmetUnknown = unmet.any { flag ->
            if (flag == SafAccessFlag.READ) evidence.probeRead == ProbeFlag.UNKNOWN
            else evidence.probeWrite == ProbeFlag.UNKNOWN
        }
        if (anyUnmetUnknown && needs.all { flag ->
                val probeOk = if (flag == SafAccessFlag.READ) evidence.probeRead != ProbeFlag.DENIED
                    else evidence.probeWrite != ProbeFlag.DENIED
                probeOk
            }
        ) {
            // Declarative answer unavailable but NOT denied: proceed optimistically;
            // the actual descriptor open is the final word and will surface a typed
            // Revoked/RePickRequired if the grant really died.
            return GateVerdict.Allowed(evidence)
        }
        // Truly denied by both truth sources:
        val anyLiveAccess = evidence.read || evidence.write || evidence.probeIsOptimistic
        return when {
            // A live grant exists but lacks the required flag: that is a
            // privilege mismatch (read-only), NOT an expired grant.
            anyLiveAccess -> GateVerdict.Denied(SafFailure.ReadOnly)
            everAcquired.contains(anchor.uriString) -> GateVerdict.Denied(SafFailure.Revoked)
            expiredSession.contains(anchor.uriString) || sessionAccess.containsKey(anchor.uriString) -> {
                // Persistent typed re-pick (durable until re-accept/forget): the
                // UI asks the user ONCE, no silent re-take, no prompt storm.
                sessionAccess.remove(anchor.uriString)
                expiredSession += anchor.uriString
                GateVerdict.Denied(SafFailure.RePickRequired("session grant expired for ${anchor.uriString}"))
            }
            else -> GateVerdict.Denied(SafFailure.GrantMissing)
        }
    }
}

enum class PickKind { OPEN_DOCUMENT, OPEN_TREE, CREATE_DOCUMENT }

/**
 * Plain-data picker request. [allowMultiple] is reserved: this lane accepts one
 * explicit result URI at a time; clip-data enumeration is a later host need.
 */
data class PickRequestSpec(
    val requestKey: String,
    val kind: PickKind,
    val mimeTypes: List<String>,
    val suggestedName: String?,
    val initialDirectory: SafUriRef?,
    val allowMultiple: Boolean = false,
)

sealed class PickAcceptResult {
    data class Accepted(
        val uri: SafUriRef,
        val kind: SafUriKind,
        val granted: Set<SafAccessFlag>,
        val persisted: Set<SafAccessFlag>,
        /** True when any granted flag lives only as the current-session grant. */
        val transientOnly: Boolean,
        /** Typed re-pick is required IF AND WHEN the probe denies the session. */
        val needsRePickWhenExpired: Boolean,
        val reason: String,
    ) : PickAcceptResult()

    /** null/cancel result — never fabricates access. */
    data class Cancelled(val reason: String) : PickAcceptResult()

    /** Result shape the gateway refuses (wrong kind, non-content scheme, no flags). */
    data class Rejected(val reason: String, val detail: String) : PickAcceptResult()
}

/** Live access evidence for one URI anchor (persisted row + session probe). */
data class AccessEvidence(
    val uri: SafUriRef,
    val read: Boolean,
    val write: Boolean,
    val persisted: Boolean,
    val probeRead: ProbeFlag,
    val probeWrite: ProbeFlag,
    val probeIsOptimistic: Boolean,
)

data class ResumeSweep(
    val lost: List<SafUriRef>,
    val lostSessionGrants: List<SafUriRef>,
    val stillGranted: List<GrantSnapshot>,
)

sealed class ReleaseResult {
    data class Released(val flags: Set<SafAccessFlag>) : ReleaseResult()
    data class PartiallyReleased(
        val released: Set<SafAccessFlag>,
        val retained: Set<SafAccessFlag>,
        val failed: Set<SafAccessFlag>,
    ) : ReleaseResult()

    /** Host broker serialized section kept other references alive: nothing released. */
    data class RetainedByBroker(val retained: Set<SafAccessFlag>) : ReleaseResult()

    /** No release broker wired: the gateway never releases on its own. */
    data class RefusedNoBroker(val candidates: Set<SafAccessFlag>, val heldElsewhere: Boolean) : ReleaseResult()

    data class NothingOwned(val persistedByUs: Set<SafAccessFlag>) : ReleaseResult()

    /** We never acquired this; `heldElsewhere` says another feature's grant survives. */
    data class NotOwned(val heldElsewhere: Boolean) : ReleaseResult()
}

internal sealed class GateVerdict {
    data class Allowed(val evidence: AccessEvidence) : GateVerdict()
    data class Denied(val failure: SafFailure) : GateVerdict()
}
