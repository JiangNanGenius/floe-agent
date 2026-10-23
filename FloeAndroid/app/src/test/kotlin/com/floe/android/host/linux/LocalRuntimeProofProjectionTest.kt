// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Read-only proof projection regressions (Diagnostics & About details
 * popup).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs the focused JVM filter named in SOURCE_READY.json alongside the
 * existing LinuxRuntimeCleanupPumpTest / LinuxTaskExecutionDiagnosticsTest.
 *
 * The projection is PURE (kotlinx JSON in, kotlinx JSON out), so these
 * fixtures pin the honest-absence rules without Android/JNI/IPC:
 *  1. CLOSED membership, not length: an enumerated token passes, anything
 *     else is `redacted`, and NOTHING is truncated-and-passed-through.
 *     The bridge `resolver_<defined code>` keeps its causal outcome as a
 *     closed `resolver_<name>` token; undefined codes/strings are redacted.
 *  2. A missing/unreadable value is `unavailable` — never a defaulted 0,
 *     false or "cleared".
 *  3. A target row proves a specific wipe ONLY when the lane echoes
 *     ok+ticket+epoch and the settled state carries a FULL 64-hex receipt
 *     digest; foreign tickets, epoch mismatch and short digests never
 *     claim cleared.
 *  4. Aggregate counts are never target proof: with `settled` counts and
 *     zero processed tickets the projection shows an EMPTY targets list
 *     plus the constant `aggregateProvesTargets=false`.
 *  5. Generation fences: a host lane epoch != stats boundEpoch is
 *     `generation_mismatch`, and a reading whose epoch changed across the
 *     native reads is `generation_changed` with every target row refused.
 */
class LocalRuntimeProofProjectionTest {

    private val ticket = "a".repeat(32)
    private val digest = "d".repeat(64)
    private val conversation = "0F66A2F0-6CFA-4B6E-9E5F-3E9D2B5C7A11"

    private fun json(text: String): JsonObject = Json.parseToJsonElement(text) as JsonObject

    // MARK: - resolver projection

    private val fullStatus = json(
        """{"protocol":1,"foreground":true,"active":false,"stopping":false,
           "localNetworkGranted":true,
           "resolver":{"state":"BRIDGED","configuredMode":"hostname",
             "effectivePrivateDns":"false","serverCount":2,"probe":"not_run",
             "generation":4,"revalidations":1,
             "helper":{"install":"staged","present":true,"verified":true},
             "bridge":{"state":"listening","forwarded":12,"refused":0,"timedOut":1,
               "unauthorized":0,"malformed":0,"inflight":0,"resolverRejected":2,
               "lastError":"forward_timeout"}}}""",
    )

    @Test fun resolverHappyPathPassesClosedTokensOnly() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            fullStatus, objOf(fullStatus, "resolver"),
        )
        assertEquals("observed", text(projected, "availability"))
        // Producers emit lowercase names; the projection lowercases too.
        assertEquals("bridged", text(projected, "state"))
        assertEquals("hostname", text(projected, "mode"))
        assertEquals("false", text(projected, "effectivePrivateDns"))
        assertEquals("2", content(projected, "serverCount"))
        assertEquals("not_run", text(projected, "probe"))
        assertEquals("staged", text(projected, "helperInstall"))
        assertEquals("true", content(projected, "helperPresent"))
        val bridge = projected["bridge"] as JsonObject
        assertEquals("listening", text(bridge, "state"))
        assertEquals("12", content(bridge, "forwarded"))
        assertEquals("forward_timeout", text(bridge, "lastError"))
        val engine = projected["engine"] as JsonObject
        assertEquals("false", content(engine, "active"))
        assertEquals("true", content(engine, "foregroundPermit"))
    }

    @Test fun resolverUnknownTokensAreRedactedNeverTruncated() {
        val resolver = json(
            """{"state":"/data/user/10/x/files/secret","configuredMode":"hostname",
               "probe":"refused_extra","generation":3,"revalidations":0,"serverCount":1,
               "effectivePrivateDns":"maybe","helper":{"install":"weird_state"}}""",
        )
        val projected = LocalRuntimeProofProjection.projectResolver(json("{}"), resolver)
        assertEquals("redacted", text(projected, "state"))
        assertEquals("redacted", text(projected, "probe"))
        assertEquals("redacted", text(projected, "effectivePrivateDns"))
        assertEquals("redacted", text(projected, "helperInstall"))
        assertEquals("hostname", text(projected, "mode"))
    }

    @Test fun resolverMissingFieldsAreUnavailableNeverZero() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            null, json("""{"state":"bridged"}"""),
        )
        assertEquals("observed", text(projected, "availability"))
        assertEquals("unavailable", text(projected, "serverCount"))
        assertEquals("unavailable", text(projected, "snapshotGeneration"))
        assertEquals("unavailable", text(projected, "revalidations"))
        assertEquals("unavailable", text(projected, "mode"))
        assertEquals("absent", text(projected, "bridge"))
        assertNull(projected["engine"])
    }

    @Test fun resolverNegativeCountersAreUnavailable() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            json("{}"), json("""{"state":"bridged","serverCount":-7,"generation":-1}"""),
        )
        assertEquals("unavailable", text(projected, "serverCount"))
        assertEquals("unavailable", text(projected, "snapshotGeneration"))
    }

    @Test fun helperExceptionBranchBucketsToInstallFailed() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            json("{}"),
            json("""{"state":"bridged","helper":{"install":"install_kotlin.illegalstateexception","present":false,"verified":false}}"""),
        )
        assertEquals("install_failed", text(projected, "helperInstall"))
    }

    @Test fun bridgeExceptionClassErrorIsRedacted() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            json("{}"),
            json("""{"state":"bridged","bridge":{"state":"listening","forwarded":0,"refused":0,
               "timedOut":0,"unauthorized":0,"malformed":0,"inflight":0,"resolverRejected":0,
               "lastError":"InterruptedIOException"}}"""),
        )
        assertEquals("redacted", text((projected["bridge"] as JsonObject), "lastError"))
    }

    @Test fun lastTransitionOnlyClosedStatePairsPass() {
        val ok = LocalRuntimeProofProjection.projectResolver(
            json("{}"), json("""{"state":"system_direct","lastTransition":"bridged->system_direct"}"""),
        )
        assertEquals("bridged->system_direct", text(ok, "lastTransition"))
        val bad = LocalRuntimeProofProjection.projectResolver(
            json("{}"), json("""{"state":"system_direct","lastTransition":"bridged->/etc/passwd"}"""),
        )
        assertEquals("redacted", text(bad, "lastTransition"))
    }

    @Test fun resolverAbsentStatusIsHonest() {
        val noStatus = LocalRuntimeProofProjection.projectResolver(null, null)
        assertEquals("status_unreadable", text(noStatus, "availability"))
        val noResolver = LocalRuntimeProofProjection.projectResolver(json("""{"protocol":1}"""), null)
        assertEquals("resolver_absent", text(noResolver, "availability"))
    }

    // MARK: - per-target proof binding

    @Test fun settledFullDigestProvesClearedReceipt() {
        val lane = json("""{"ok":true,"requestID":"$ticket","targetEpoch":5,"state":"settled","receiptDigest":"$digest"}""")
        val row = LocalRuntimeProofProjection.projectTarget(ticket, conversation, 5, lane, null)
        assertEquals(ticket, text(row, "ticket"))
        assertEquals("settled", text(row, "laneState"))
        assertEquals("cleared_receipt", text(row, "proof"))
        assertEquals(digest, text(row, "receiptDigest"))
        assertEquals("unavailable", text(row, "hostReason"))
    }

    @Test fun settledTruncatedDigestIsNeverCleared() {
        val lane = json("""{"ok":true,"requestID":"$ticket","targetEpoch":5,"state":"settled","receiptDigest":"${digest.take(40)}"}""")
        val row = LocalRuntimeProofProjection.projectTarget(ticket, conversation, 5, lane, null)
        assertEquals("settled_digest_unreadable", text(row, "proof"))
        assertEquals("unreadable", text(row, "receiptDigest"))
    }

    @Test fun foreignTicketEchoVerifiesNothing() {
        val lane = json("""{"ok":true,"requestID":"${"b".repeat(32)}","targetEpoch":5,"state":"settled","receiptDigest":"$digest"}""")
        val row = LocalRuntimeProofProjection.projectTarget(ticket, conversation, 5, lane, null)
        assertEquals("unreadable", text(row, "laneState"))
        assertEquals("ticket_unverified", text(row, "proof"))
    }

    @Test fun laneEpochMismatchIsGenerationMismatchNotCleared() {
        val lane = json("""{"ok":true,"requestID":"$ticket","targetEpoch":6,"state":"settled","receiptDigest":"$digest"}""")
        val row = LocalRuntimeProofProjection.projectTarget(ticket, conversation, 5, lane, null)
        assertEquals("generation_mismatch", text(row, "proof"))
    }

    @Test fun missingLaneEpochIsEpochUnverified() {
        val lane = json("""{"ok":true,"requestID":"$ticket","state":"queued"}""")
        val row = LocalRuntimeProofProjection.projectTarget(ticket, conversation, 5, lane, null)
        assertEquals("epoch_unverified", text(row, "proof"))
    }

    @Test fun retryingKnownReasonPassesUnknownRedacts() {
        val known = LocalRuntimeProofProjection.projectTarget(
            ticket, conversation, 5,
            json("""{"ok":true,"requestID":"$ticket","targetEpoch":5,"state":"retrying","reason":"runtime:ownedWorkActive"}"""),
            "runtime:ownedWorkActive",
        )
        assertEquals("retrying", text(known, "laneState"))
        assertEquals("not_cleared_yet", text(known, "proof"))
        assertEquals("runtime:ownedWorkActive", text(known, "reason"))
        val unknown = LocalRuntimeProofProjection.projectTarget(
            ticket, conversation, 5,
            json("""{"ok":true,"requestID":"$ticket","targetEpoch":5,"state":"retrying","reason":"runtime:/private/path"}"""),
            null,
        )
        assertEquals("runtime:redacted", text(unknown, "reason"))
    }

    @Test fun unknownAndUnreadableLaneRepliesStayHonest() {
        val unknown = LocalRuntimeProofProjection.projectTarget(
            ticket, conversation, 5,
            json("""{"ok":true,"requestID":"$ticket","targetEpoch":5,"state":"unknown"}"""), null,
        )
        assertEquals("lane_does_not_know_this_ticket", text(unknown, "proof"))
        val missing = LocalRuntimeProofProjection.projectTarget(ticket, conversation, 5, null, null)
        assertEquals("unreadable", text(missing, "laneState"))
        assertEquals("ticket_unverified", text(missing, "proof"))
        val notOk = LocalRuntimeProofProjection.projectTarget(
            ticket, conversation, 5, json("""{"ok":false,"state":"unknown"}"""), null,
        )
        assertEquals("ticket_unverified", text(notOk, "proof"))
    }

    @Test fun malformedTicketOrConversationAreUnavailable() {
        val row = LocalRuntimeProofProjection.projectTarget(
            "NOT-HEX", "not-a-uuid", -3,
            json("""{"ok":true,"requestID":"NOT-HEX","targetEpoch":-3,"state":"claimed"}"""), null,
        )
        assertEquals("unavailable", text(row, "ticket"))
        assertEquals("unavailable", text(row, "conversation"))
        assertEquals("unavailable", text(row, "targetEpoch"))
    }

    // MARK: - bridge resolver error (exact observed NUMBER only; no name inference)

    @Test fun bridgeResolverNumericCodeProjectsExactObservedNumber() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            json("{}"),
            json("""{"state":"bridged","bridge":{"state":"listening","forwarded":3,"refused":0,
               "timedOut":0,"unauthorized":0,"malformed":0,"inflight":0,"resolverRejected":0,
               "lastError":"resolver_11"}}"""),
        )
        val bridge = projected["bridge"] as JsonObject
        assertEquals("resolver_error", text(bridge, "lastError"))
        assertEquals("11", content(bridge, "resolverErrorCode"))
    }

    /** The ONLY accepted shape is the exact fixed prefix + bounded signed
     *  integer: the number is projected as observed (no enum-range claim,
     *  no name mapping — Main review correction). Anything else is
     *  redacted with no numeric field. */
    @Test fun bridgeResolverErrorNumericShapeIsBounded() {
        assertEquals(11L, LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_11"))
        assertEquals(0L, LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_0"))
        assertEquals(-3L, LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_-3"))
        assertEquals(13L, LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_13"))
        assertNull(LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_12345678901"))
        assertNull(LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_"))
        assertNull(LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_1.5"))
        assertNull(LocalRuntimeProofProjection.bridgeResolverErrorCode("Resolver_11"))
        assertNull(LocalRuntimeProofProjection.bridgeResolverErrorCode("resolver_./etc/passwd"))
        assertNull(LocalRuntimeProofProjection.bridgeResolverErrorCode(null))
        assertEquals("resolver_error", LocalRuntimeProofProjection.projectedBridgeError("resolver_11"))
        assertEquals("redacted", LocalRuntimeProofProjection.projectedBridgeError("resolver_x"))
        assertEquals("forward_timeout", LocalRuntimeProofProjection.projectedBridgeError("forward_timeout"))
        assertEquals("unavailable", LocalRuntimeProofProjection.projectedBridgeError(null))
    }

    @Test fun bridgeNumericErrorOmitsCodeFieldWhenNotNumeric() {
        val projected = LocalRuntimeProofProjection.projectResolver(
            json("{}"),
            json("""{"state":"bridged","bridge":{"state":"listening","forwarded":0,"refused":0,
               "timedOut":0,"unauthorized":0,"malformed":0,"inflight":0,"resolverRejected":0,
               "lastError":"InterruptedIOException"}}"""),
        )
        val bridge = projected["bridge"] as JsonObject
        assertEquals("redacted", text(bridge, "lastError"))
        assertFalse(bridge.containsKey("resolverErrorCode"))
    }

    // MARK: - aggregate honesty (counts are NEVER target proof)

    @Test fun aggregatesWithNoProcessedTicketsShowNoTargetProof() {
        val view = LocalRuntimeProofProjection.projectCleanup(
            stats = json("""{"boundEpoch":9,"queued":0,"claimed":0,"settled":3,"enqueued":3,
                "dedupHits":0,"rejectedSaturated":0,"rejectedMalformed":0,"claims":3,
                "requeuedAfterGeneration":0,"settledCleared":3,"runtimeRefusalsRetained":0,
                "refusedStaleClaim":0,"refusedUnknown":0,"refusedScopeMismatch":0,
                "refusedIdentity":0,"refusedUnbound":0}"""),
            hostBoundEpoch = 9,
            targets = emptyList(),
            hostSettledCleared = 3, hostRetained = 0, hostLastReason = null,
        )
        assertEquals("observed_bound", text(view, "availability"))
        assertEquals(false, (view["aggregateProvesTargets"] as kotlinx.serialization.json.JsonPrimitive).content.toBoolean())
        val targets = view["targets"] as JsonArray
        assertTrue(targets.isEmpty())
        assertEquals("3", content((view["aggregate"] as JsonObject), "settled"))
    }

    @Test fun hostAndLaneGenerationMismatchIsNamedNotMerged() {
        val view = LocalRuntimeProofProjection.projectCleanup(
            stats = json("""{"boundEpoch":9,"queued":1,"claimed":0,"settled":0}"""),
            hostBoundEpoch = 10, targets = emptyList(),
            hostSettledCleared = 0, hostRetained = 0, hostLastReason = null,
        )
        assertEquals("generation_mismatch", text(view, "availability"))
    }

    /** The pump's read-end fence: a bound-epoch change anywhere across the
     *  native reads retires the WHOLE reading — no aggregate snapshot, no
     *  target rows, never a partial mix of generations. */
    @Test fun fenceTrippedReadingRefusesEveryTarget() {
        val settledRow = LocalRuntimeProofProjection.projectTarget(
            ticket, conversation, 5,
            json("""{"ok":true,"requestID":"$ticket","targetEpoch":5,"state":"settled","receiptDigest":"$digest"}"""),
            null,
        )
        val view = LocalRuntimeProofProjection.projectCleanup(
            stats = json("""{"boundEpoch":9,"queued":0,"claimed":0,"settled":1}"""),
            hostBoundEpoch = 9, targets = listOf(settledRow),
            hostSettledCleared = 0, hostRetained = 0, hostLastReason = null,
            fenceTripped = true,
        )
        assertEquals("generation_changed", text(view, "availability"))
        assertFalse(view.containsKey("aggregate"))
        assertEquals(0, (view["targets"] as JsonArray).size)
    }

    @Test fun unboundAndUnreadableLanesAreHonest() {
        val unbound = LocalRuntimeProofProjection.projectCleanup(
            stats = json("""{"boundEpoch":0,"queued":0,"claimed":0,"settled":0}"""),
            hostBoundEpoch = 0, targets = emptyList(),
            hostSettledCleared = 0, hostRetained = 0, hostLastReason = null,
        )
        assertEquals("lane_unbound", text(unbound, "availability"))
        val unreadable = LocalRuntimeProofProjection.projectCleanup(
            stats = null, hostBoundEpoch = 3, targets = emptyList(),
            hostSettledCleared = 0, hostRetained = 0, hostLastReason = null,
        )
        assertEquals("lane_unreadable", text(unreadable, "availability"))
        assertNull(unreadable["aggregate"])
    }

    @Test fun negativeAggregateCountersAreUnavailableNeverZero() {
        val view = LocalRuntimeProofProjection.projectCleanup(
            stats = json("""{"boundEpoch":2,"queued":-4,"claimed":0,"settled":0}"""),
            hostBoundEpoch = 2, targets = emptyList(),
            hostSettledCleared = -1, hostRetained = 0, hostLastReason = null,
        )
        assertEquals("unavailable", text((view["aggregate"] as JsonObject), "queued"))
        assertEquals("unavailable", text((view["host"] as JsonObject), "settledCleared"))
    }

    // MARK: - reason vocabulary

    @Test fun reasonTokenFamiliesStayClosedPerProvenance() {
        assertEquals("peerUnauthenticated", LocalRuntimeProofProjection.closedReasonToken("peerUnauthenticated"))
        assertEquals("uncertain:statusDeadline", LocalRuntimeProofProjection.closedReasonToken("uncertain:statusDeadline"))
        assertEquals("uncertain:redacted", LocalRuntimeProofProjection.closedReasonToken("uncertain:someNewInternalThing"))
        assertEquals("ack:scopeMismatch", LocalRuntimeProofProjection.closedReasonToken("ack:scopeMismatch"))
        assertEquals("ack:redacted", LocalRuntimeProofProjection.closedReasonToken("ack:whatever"))
        assertEquals("runtime:unsafeproject:symlink",
            LocalRuntimeProofProjection.closedReasonToken("runtime:unsafeproject:symlink"))
        assertEquals("runtime:unsafeMarker:notRegular",
            LocalRuntimeProofProjection.closedReasonToken("runtime:unsafeMarker:notRegular"))
        assertEquals("runtime:redacted", LocalRuntimeProofProjection.closedReasonToken("runtime:customFutureCode"))
        assertEquals("redacted", LocalRuntimeProofProjection.closedReasonToken("totally free form text here"))
        assertEquals("unavailable", LocalRuntimeProofProjection.closedReasonToken(null))
    }

    // MARK: - owned operations (closed kinds/count; never drain)

    @Test fun ownedSnapshotIsClosedCountsAndKinds() {
        val view = LocalRuntimeProofProjection.projectOwned(
            operationCount = 2,
            kinds = setOf("local_execution", "durable_job", "invented_kind"),
            foregroundConfirmed = true,
            cpuWakeHeld = false,
        )
        assertEquals("observed", text(view, "availability"))
        assertEquals("2", content(view, "operationCount"))
        val kinds = view["kinds"] as JsonArray
        assertEquals(2, kinds.size)
        assertFalse(kinds.any { (it as kotlinx.serialization.json.JsonPrimitive).content == "invented_kind" })
        assertEquals("true", content(view, "foregroundConfirmed"))
        assertEquals("false", content(view, "cpuWakeHeld"))
    }

    @Test fun missingCoordinatorSnapshotsAreUnavailable() {
        val view = LocalRuntimeProofProjection.projectOwned(null, null, null, null)
        assertEquals("coordinator_unavailable", text(view, "availability"))
        assertFalse(view.containsKey("operationCount"))
    }

    // MARK: - helpers

    private fun text(view: JsonObject, key: String): String? =
        LocalRuntimeProofProjection.text(view[key])

    private fun content(view: JsonObject, key: String): String? =
        LocalRuntimeProofProjection.content(view[key])

    private fun objOf(parent: JsonObject, key: String): JsonObject = parent[key] as JsonObject
}
