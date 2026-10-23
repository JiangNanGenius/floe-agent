// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Bounded read-only proof projection for the Diagnostics & About "Local
 * task execution" details popup.
 *
 * PURE by construction (kotlinx JSON only, no Android/JNI/IPC): it consumes
 * the ACTUAL bytes produced by the ORIGINAL authorities — the runtime
 * kernel `status` reply (whose `resolver` member is the applied guest
 * resolver snapshot), the Core cleanup lane `stats()` aggregate and
 * per-request `status(requestID)` readback (the qualified JNI surface),
 * and the foreground coordinator's owned-operation snapshot — and projects
 * ONLY closed, enumerated fields. Every vocabulary below is enumerated
 * from the actual producers; a value outside its vocabulary becomes the
 * fixed `redacted` token, and a missing or undecodable value becomes
 * `unavailable` — never a defaulted 0, false or "cleared". Nothing here
 * mutates, re-ingresses, retries, installs or qualifies anything: a
 * projection is a READ, never a success source.
 */
internal object LocalRuntimeProofProjection {
    const val UNAVAILABLE = "unavailable"
    const val REDACTED = "redacted"

    /** Target-naming values are opaque identifiers already bounded by the
     *  producers (32-hex ticket, canonical UUID, 64-hex digest); the UI
     *  surfaces them ONLY inside the explicitly opened technical details,
     *  never in the normal row and never as raw paths, hostnames, commands
     *  or keys. */
    private val HEX32 = Regex("^[0-9a-f]{32}$")
    private val HEX64 = Regex("^[0-9a-f]{64}$")
    private val UUID_TOKEN =
        Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
    private val STATE_TRANSITION = Regex("^[a-z_]+->[a-z_]+$")

    // MARK: closed vocabularies (enumerated from the actual producers)

    /** ResolverState names plus the snapshot's own "not_prepared" branch. */
    val RESOLVER_STATES = setOf(
        "bridged", "system_tunnel", "system_direct",
        "unavailable_offline", "unavailable_unsupported", "not_prepared",
    )

    /** PrivateDnsMode names. */
    val RESOLVER_MODES = setOf("off", "opportunistic", "hostname", "unknown")

    /** The snapshot writes the effective fact as a STRING tri-state. */
    val RESOLVER_EFFECTIVE = setOf("true", "false", "unreadable")

    /** TunnelProbe names. */
    val TUNNEL_PROBES = setOf("not_run", "reachable", "unreachable", "refused")

    /** Guest resolver helper install states: every fixed constant the
     *  installer writes. The exception branch composes
     *  "install_<ClassName>" — an OPEN set — so it is bucketed to exactly
     *  one closed token, never passed through. */
    val HELPER_INSTALL_STATES = setOf(
        "staged", "assets_unseen", "assets_absent", "manifest_unparseable",
        "manifest_invalid", "digest_absent", "digest_mismatch", "library_absent",
        "library_oversized", "size_mismatch", "elf_invalid", "sha_mismatch",
        "dir_failed", "install_failed",
    )

    /** GuestDnsBridge.stateName(). */
    val BRIDGE_STATES = setOf("idle", "starting", "listening", "retiring")

    /** GuestDnsBridge fixed lastError markers (the exception-class branch
     *  is an open set → membership-redacted). */
    val BRIDGE_ERRORS = setOf(
        "retirement_pending", "sun_path_too_long", "socket_dir_failed",
        "bind_failed", "peer_creds", "forward_timeout", "resolver_saturated",
    )

    /** GuestDnsBridge also records `resolver_<code>` from the resolver API
     *  error callback. Only the exact fixed prefix plus a bounded SIGNED
     *  INTEGER is accepted: it becomes the closed `resolver_error` marker
     *  plus the actual observed number in its own numeric field. NO enum
     *  name is ever inferred or published (the numeric code space is not
     *  an enumerated vocabulary here); anything outside the exact shape is
     *  redacted — never an arbitrary string, hostname or path passthrough. */
    private val BRIDGE_RESOLVER_ERROR = Regex("^resolver_(-?[0-9]{1,10})$")

    /** The exact observed numeric resolver error, or null when the value
     *  is not the fixed prefix + bounded signed integer. */
    fun bridgeResolverErrorCode(raw: String?): Long? =
        raw?.let { BRIDGE_RESOLVER_ERROR.matchEntire(it) }?.groupValues?.get(1)?.toLongOrNull()

    /** Bridge lastError projection: fixed markers pass; the numeric
     *  `resolver_<int>` becomes the closed `resolver_error` marker (with
     *  the number projected separately); everything else is redacted. */
    fun projectedBridgeError(raw: String?): String = when {
        raw == null -> UNAVAILABLE
        bridgeResolverErrorCode(raw) != null -> "resolver_error"
        raw in BRIDGE_ERRORS -> raw
        else -> REDACTED
    }

    /** LinuxRuntimeCleanup statusJSON state vocabulary plus the honest
     *  "unreadable" for an absent/undecodable/error reply (never queued). */
    val LANE_STATES = setOf("queued", "retrying", "claimed", "settled", "unknown")

    /** The pump's own fixed host-side retention literals. */
    val HOST_RETENTION_TOKENS = setOf(
        "peerUnauthenticated", "peerChanged", "staleBeforeSettle",
        "resultUnverified", "runtimeUnavailable", "retain",
        "uncertain:envelopeIdMismatch", "uncertain:generationChanged",
        "uncertain:statusDeadline",
    )

    /** Runtime-UID cleanup refusal reasons enumerated from the shipped
     *  producers. The wiper's parameterized `unsafe<name>:<kind>` family
     *  is matched by a bounded regex over enumerated components only. */
    val RUNTIME_RETENTION_TOKENS = setOf(
        "scopeInvalid", "ownedWorkActive", "uidNotQuiescent", "rootUnsafe",
        "pathUnsafe", "journalMarkerInvalid", "journalMarkerMismatch",
        "ownershipUnproven", "grantLive", "attributionIncomplete",
        "markerUnlinkFailed", "drainUnproven", "retireMarkerInvalid",
        "retireScopeMismatch", "retireUnmarked", "wipeBudget",
        "unsafeMarker:notRegular", "runtime_not_ready", "invalid_request",
        "operation_failed", "refused", "unknown",
    )
    private val RUNTIME_UNSAFE_ENTRY =
        Regex("^unsafe(?:project|manifest|journal[0-9a-fA-F]{8}):(?:unstatable|symlink|notDirectory)$")

    /** Core complete-ack error/state literals. */
    val ACK_RETENTION_TOKENS = setOf(
        "retrying", "laneUnbound", "scopeMismatch", "identityNotDistinct",
        "receiptCanonicalFailed", "staleClaim", "unknownClaim",
        "receiptMalformed", "internal", "unreadable",
    )

    /** OperationKind names (lowercased). */
    val OPERATION_KINDS = setOf(
        "environment_install", "local_execution", "agent_run", "durable_job",
    )

    // MARK: primitives

    fun unavailable(reason: String): JsonObject = JsonObject(mapOf("availability" to JsonPrimitive(reason)))

    private fun stringOf(element: JsonObject, key: String): String? =
        (element[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun longOf(element: JsonObject, key: String): Long? =
        (element[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

    private fun boolOf(element: JsonObject, key: String): Boolean? =
        (element[key] as? JsonPrimitive)?.takeIf { !it.isString }?.let {
            when (it.content) { "true" -> true; "false" -> false; else -> null }
        }

    private fun objOf(element: JsonObject, key: String): JsonObject? = element[key] as? JsonObject

    /** Membership, NOT length, bounds a token (the closed-vocabulary rule
     *  the readiness stage surface already follows). */
    fun closedToken(raw: String?, allowed: Set<String>): String = when {
        raw == null -> UNAVAILABLE
        raw in allowed -> raw
        else -> REDACTED
    }

    /** Non-negative observable; absent/negative/non-numeric is honestly
     *  unavailable — never a defaulted 0. */
    fun nonNegative(raw: Long?): Long? = raw?.takeIf { it >= 0 }

    /** A receipt digest proves nothing unless it is the full lowercase hex
     *  the producer commits (64 chars); any other shape is "unreadable",
     *  never shown and never cleared. */
    fun strictDigest(raw: String?): String = raw?.takeIf { HEX64.matches(it) } ?: "unreadable"

    // MARK: resolver (runtime kernel `status` → closed projection)

    /**
     * [status] is the decoded result of the ONE metadata-only `status`
     * exchange (never an envelope), already anchored/generation-checked by
     * the readiness authority; [resolver] is its `resolver` member.
     *
     * The free-form `diagnostic` note is deliberately NOT exported: its
     * producers emit prose sentences, not an enumerated vocabulary (exact
     * gap in SOURCE_READY). Bridge `lastError` keeps the causal outcome:
     * fixed markers pass and the numeric `resolver_<int>` becomes the
     * closed `resolver_error` marker with the ACTUAL observed number in
     * `resolverErrorCode` (no enum-name inference anywhere); helper
     * `install_<Exception>` buckets to `install_failed`.
     */
    fun projectResolver(status: JsonObject?, resolver: JsonObject?): JsonObject {
        val rows = LinkedHashMap<String, JsonElement>()
        if (resolver == null) {
            rows["availability"] = JsonPrimitive(if (status == null) "status_unreadable" else "resolver_absent")
            return JsonObject(rows)
        }
        rows["availability"] = JsonPrimitive("observed")
        stringOf(resolver, "state")?.lowercase()?.let {
            rows["state"] = JsonPrimitive(closedToken(it, RESOLVER_STATES))
        } ?: run { rows["state"] = JsonPrimitive(UNAVAILABLE) }
        stringOf(resolver, "configuredMode")?.lowercase()?.let {
            rows["mode"] = JsonPrimitive(closedToken(it, RESOLVER_MODES))
        } ?: run { rows["mode"] = JsonPrimitive(UNAVAILABLE) }
        stringOf(resolver, "effectivePrivateDns")?.let {
            rows["effectivePrivateDns"] = JsonPrimitive(closedToken(it, RESOLVER_EFFECTIVE))
        } ?: run { rows["effectivePrivateDns"] = JsonPrimitive(UNAVAILABLE) }
        nonNegative(longOf(resolver, "serverCount"))?.let { rows["serverCount"] = JsonPrimitive(it) }
            ?: run { rows["serverCount"] = JsonPrimitive(UNAVAILABLE) }
        stringOf(resolver, "probe")?.lowercase()?.let {
            rows["probe"] = JsonPrimitive(closedToken(it, TUNNEL_PROBES))
        } ?: run { rows["probe"] = JsonPrimitive(UNAVAILABLE) }
        nonNegative(longOf(resolver, "generation"))?.let { rows["snapshotGeneration"] = JsonPrimitive(it) }
            ?: run { rows["snapshotGeneration"] = JsonPrimitive(UNAVAILABLE) }
        nonNegative(longOf(resolver, "revalidations"))?.let { rows["revalidations"] = JsonPrimitive(it) }
            ?: run { rows["revalidations"] = JsonPrimitive(UNAVAILABLE) }
        val helper = objOf(resolver, "helper")
        rows["helperInstall"] = JsonPrimitive(
            closedToken(helper?.let { rawInstall ->
                val value = stringOf(rawInstall, "install")
                when {
                    value == null -> null
                    value.startsWith("install_") && value != "install_failed" -> "install_failed"
                    else -> value
                }
            }, HELPER_INSTALL_STATES),
        )
        helper?.let { h ->
            boolOf(h, "present")?.let { rows["helperPresent"] = JsonPrimitive(it) }
                ?: run { rows["helperPresent"] = JsonPrimitive(UNAVAILABLE) }
            boolOf(h, "verified")?.let { rows["helperVerified"] = JsonPrimitive(it) }
                ?: run { rows["helperVerified"] = JsonPrimitive(UNAVAILABLE) }
        } ?: run {
            rows["helperPresent"] = JsonPrimitive(UNAVAILABLE)
            rows["helperVerified"] = JsonPrimitive(UNAVAILABLE)
        }
        stringOf(resolver, "lastTransition")?.let { transition ->
            val shaped = STATE_TRANSITION.matches(transition)
            val sides = transition.split("->")
            val closed = shaped && sides.size == 2 && sides.all { it in RESOLVER_STATES }
            rows["lastTransition"] = JsonPrimitive(if (closed) transition else REDACTED)
        }
        val bridge = objOf(resolver, "bridge")
        if (bridge == null) {
            rows["bridge"] = JsonPrimitive("absent")
        } else {
            val projected = LinkedHashMap<String, JsonElement>()
            projected["state"] = JsonPrimitive(closedToken(stringOf(bridge, "state"), BRIDGE_STATES))
            for (key in listOf(
                "forwarded", "refused", "timedOut", "unauthorized",
                "malformed", "inflight", "resolverRejected",
            )) {
                nonNegative(longOf(bridge, key))?.let { projected[key] = JsonPrimitive(it) }
                    ?: run { projected[key] = JsonPrimitive(UNAVAILABLE) }
            }
            val rawError = stringOf(bridge, "lastError")
            projected["lastError"] = JsonPrimitive(projectedBridgeError(rawError))
            bridgeResolverErrorCode(rawError)?.let { projected["resolverErrorCode"] = JsonPrimitive(it) }
            rows["bridge"] = JsonObject(projected)
        }
        // Engine truth from the SAME bounded status read (closed booleans).
        if (status != null) {
            val engine = LinkedHashMap<String, JsonElement>()
            for (key in listOf("active", "stopping", "localNetworkGranted")) {
                boolOf(status, key)?.let { engine[key] = JsonPrimitive(it) }
                    ?: run { engine[key] = JsonPrimitive(UNAVAILABLE) }
            }
            boolOf(status, "foreground")?.let { engine["foregroundPermit"] = JsonPrimitive(it) }
                ?: run { engine["foregroundPermit"] = JsonPrimitive(UNAVAILABLE) }
            rows["engine"] = JsonObject(engine)
        }
        return JsonObject(rows)
    }

    // MARK: cleanup (lane aggregate + per-target ticket bindings)

    /** One host-observed obligation as retained by the pump's bounded
     *  observation table (scope facts measured from the real claimed
     *  payload — never minted here). [lane] is the decoded lane readback
     *  reply for the ticket ({ok,requestID,targetEpoch,state[,reason]
     *  [,receiptDigest]}); null/undecodable/mismatched replies stay
     *  honestly unknown. */
    fun projectTarget(
        requestID: String,
        conversationID: String,
        targetEpoch: Long,
        lane: JsonObject?,
        hostReason: String?,
    ): JsonObject {
        val row = LinkedHashMap<String, JsonElement>()
        row["ticket"] = JsonPrimitive(if (HEX32.matches(requestID)) requestID else UNAVAILABLE)
        row["conversation"] = JsonPrimitive(if (UUID_TOKEN.matches(conversationID)) conversationID else UNAVAILABLE)
        row["targetEpoch"] = if (targetEpoch > 0) JsonPrimitive(targetEpoch) else JsonPrimitive(UNAVAILABLE)
        // A reply only counts when the lane echoes ok==true AND the exact
        // ticket it was asked about; anything else verifies NOTHING.
        val confirmed = lane?.takeIf { boolOf(it, "ok") == true && stringOf(it, "requestID") == requestID }
        val laneState = confirmed?.let { closedToken(stringOf(it, "state"), LANE_STATES) }
        // The lane must echo the SAME positive target epoch the host proved
        // in the claimed payload; a missing/foreign epoch is never assumed
        // to match.
        val laneEpoch = confirmed?.let { longOf(it, "targetEpoch") }
        val epochMatches = laneEpoch != null && laneEpoch > 0 && laneEpoch == targetEpoch
        when {
            laneState == null -> {
                row["laneState"] = JsonPrimitive("unreadable")
                row["proof"] = JsonPrimitive(if (confirmed != null) "lane_unreadable" else "ticket_unverified")
            }
            !epochMatches -> {
                row["laneState"] = JsonPrimitive(laneState)
                row["proof"] = JsonPrimitive(
                    if (laneEpoch == null || laneEpoch <= 0) "epoch_unverified" else "generation_mismatch",
                )
            }
            laneState == "settled" -> {
                row["laneState"] = JsonPrimitive(laneState)
                val digest = strictDigest(stringOf(confirmed, "receiptDigest"))
                row["proof"] = JsonPrimitive(
                    if (digest == "unreadable") "settled_digest_unreadable" else "cleared_receipt",
                )
                row["receiptDigest"] = JsonPrimitive(digest)
            }
            laneState == "queued" || laneState == "retrying" || laneState == "claimed" -> {
                row["laneState"] = JsonPrimitive(laneState)
                row["proof"] = JsonPrimitive("not_cleared_yet")
                stringOf(confirmed, "reason")?.let { reason ->
                    row["reason"] = JsonPrimitive(closedReasonToken(reason))
                }
            }
            else -> { // "unknown"
                row["laneState"] = JsonPrimitive(laneState)
                row["proof"] = JsonPrimitive("lane_does_not_know_this_ticket")
            }
        }
        // The pump's own last host retention reason (auxiliary narrative;
        // settlement authority remains the lane row above).
        row["hostReason"] = JsonPrimitive(closedReasonToken(hostReason))
        return JsonObject(row)
    }

    /** Reason tokens arrive already bounded by the pump sanitizer but the
     *  sanitized SET is open: pass through only the enumerated producer
     *  literals, keeping the provenance prefix honest. */
    fun closedReasonToken(raw: String?): String {
        if (raw == null) return UNAVAILABLE
        if (raw in HOST_RETENTION_TOKENS) return raw
        if (raw.startsWith("runtime:")) {
            val reason = raw.removePrefix("runtime:")
            return if (reason in RUNTIME_RETENTION_TOKENS || RUNTIME_UNSAFE_ENTRY.matches(reason)) raw
            else "runtime:$REDACTED"
        }
        if (raw.startsWith("ack:")) {
            val code = raw.removePrefix("ack:")
            return if (code in ACK_RETENTION_TOKENS) raw else "ack:$REDACTED"
        }
        if (raw.startsWith("uncertain:")) {
            return if (raw in HOST_RETENTION_TOKENS) raw else "uncertain:$REDACTED"
        }
        return REDACTED
    }

    /** [stats] is the decoded `floe_linux_runtime_cleanup_stats` reply.
     *  Aggregate counts are ALWAYS emitted under `aggregate` together with
     *  the constant `aggregateProvesTargets=false`: counts alone are never
     *  target proof. Obligations the host has not yet claimed have no
     *  host-observable ticket, so they exist ONLY in the aggregate
     *  `queued` count. `fenceTripped` marks a read that crossed a Root
     *  generation change and therefore refuses every target row. */
    fun projectCleanup(
        stats: JsonObject?,
        hostBoundEpoch: Long,
        targets: List<JsonObject>,
        hostSettledCleared: Long,
        hostRetained: Long,
        hostLastReason: String?,
        fenceTripped: Boolean = false,
    ): JsonObject {
        val view = LinkedHashMap<String, JsonElement>()
        val laneBoundEpoch = stats?.let { longOf(it, "boundEpoch") }
        view["availability"] = JsonPrimitive(
            when {
                fenceTripped -> "generation_changed"
                laneBoundEpoch == null || laneBoundEpoch < 0 -> "lane_unreadable"
                hostBoundEpoch > 0 && hostBoundEpoch != laneBoundEpoch -> "generation_mismatch"
                hostBoundEpoch > 0 -> "observed_bound"
                laneBoundEpoch == 0L -> "lane_unbound"
                else -> "lane_bound_without_host"
            },
        )
        val effectiveStats = if (fenceTripped) null else stats
        if (effectiveStats != null) {
            val aggregate = LinkedHashMap<String, JsonElement>()
            for (key in listOf(
                "boundEpoch", "queued", "claimed", "settled", "enqueued", "dedupHits",
                "rejectedSaturated", "rejectedMalformed", "claims", "requeuedAfterGeneration",
                "settledCleared", "runtimeRefusalsRetained", "refusedStaleClaim",
                "refusedUnknown", "refusedScopeMismatch", "refusedIdentity", "refusedUnbound",
            )) {
                nonNegative(longOf(effectiveStats, key))?.let { aggregate[key] = JsonPrimitive(it) }
                    ?: run { aggregate[key] = JsonPrimitive(UNAVAILABLE) }
            }
            view["aggregate"] = JsonObject(aggregate)
        }
        view["aggregateProvesTargets"] = JsonPrimitive(false)
        val host = LinkedHashMap<String, JsonElement>()
        host["settledCleared"] =
            if (hostSettledCleared >= 0) JsonPrimitive(hostSettledCleared) else JsonPrimitive(UNAVAILABLE)
        host["retained"] =
            if (hostRetained >= 0) JsonPrimitive(hostRetained) else JsonPrimitive(UNAVAILABLE)
        host["lastReason"] = JsonPrimitive(closedReasonToken(hostLastReason))
        view["host"] = JsonObject(host)
        view["targets"] = JsonArray(if (fenceTripped) emptyList() else targets.take(MAX_TARGETS))
        return JsonObject(view)
    }

    // MARK: owned foreground operations (closed kinds/count only)

    /** Pure observation of the coordinator's CURRENT owned-operation set:
     *  counts and the CLOSED kind set only — never ids, and counts never
     *  claim IO drain; they name what is still owned. */
    fun projectOwned(
        operationCount: Int?,
        kinds: Set<String>?,
        foregroundConfirmed: Boolean?,
        cpuWakeHeld: Boolean?,
    ): JsonObject {
        val view = LinkedHashMap<String, JsonElement>()
        if (operationCount == null || kinds == null || foregroundConfirmed == null || cpuWakeHeld == null) {
            view["availability"] = JsonPrimitive("coordinator_unavailable")
            return JsonObject(view)
        }
        view["availability"] = JsonPrimitive("observed")
        view["operationCount"] =
            if (operationCount >= 0) JsonPrimitive(operationCount.toLong()) else JsonPrimitive(UNAVAILABLE)
        view["kinds"] = JsonArray(kinds.filter { it in OPERATION_KINDS }.sorted().map { JsonPrimitive(it) })
        view["foregroundConfirmed"] = JsonPrimitive(foregroundConfirmed)
        view["cpuWakeHeld"] = JsonPrimitive(cpuWakeHeld)
        return JsonObject(view)
    }

    private const val MAX_TARGETS = 8

    /** One JsonPrimitive string or null, for defensive callers. */
    fun text(element: JsonElement?): String? = (element as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Raw primitive content (string OR boolean/number): the sheet renders
     *  projected booleans/counts without re-typing them. */
    fun content(element: JsonElement?): String? = (element as? JsonPrimitive)?.content
}
