// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * G03-R3 local-task-execution diagnostics regressions (workspace-entry
 * batch 2026-10-23, job-d54a914f83a54585).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs the focused JVM filter named in SOURCE_READY.json.
 *
 * Pins Main's two review corrections plus the epoch-tag rule:
 *  1. [LinuxRuntimeReadinessController.Companion.diagnosticStage] is TOTAL:
 *     all-fields-true with an epoch mismatch, a lost anchor, a suspension
 *     or an absent/foreign accepted-fact record must produce an explicit
 *     cause token — never a `first{}` NoSuchElementException crash on the
 *     Diagnostics page.
 *  2. The stage/refusal vocabulary is CLOSED by membership, not by length:
 *     known producer tokens pass through; ANY unknown value — including
 *     printable-ASCII paths, hex digests or free-form exception text —
 *     maps to the fixed `redacted` token. Nothing is truncated-and-passed-
 *     through.
 *  3. A recorded preflight stage is visible ONLY under the generation it
 *     was captured for: a late old-Root callback never pollutes a newer
 *     generation's diagnostic reading.
 *
 * The pure decision core operates on [ReadinessSnapshot] directly (org.json
 * is not available to plain JVM unit tests — the same constraint the
 * existing [LinuxRuntimeReadinessControllerTest] documents).
 */
class LinuxTaskExecutionDiagnosticsTest {

    private val epoch = 7L

    private val five = setOf(
        "runtimeUidBoundaryVerified", "engineConnected", "mailboxEpochBound",
        "rootfsQualified", "singleWorkloadContractAcknowledged",
    )
    private val seven = five + setOf("workspaceMappingSynced", "leaseAuthorityQualified")

    private fun snapshot(
        liveEpoch: Long = epoch,
        anchored: Boolean = true,
        suspended: Long = 0,
        fields: Set<String>,
        accepted: Map<String, Pair<Long, Boolean>>? = null,
    ) = ReadinessSnapshot(
        liveEpoch = liveEpoch, peerAnchored = anchored, suspendedEpoch = suspended,
        fields = ReadinessSnapshot.ALL_SEVEN.associateWith { it in fields },
        accepted = accepted ?: ReadinessSnapshot.ALL_SEVEN
            .mapNotNull { ReadinessSnapshot.kindFor(it) }
            .associateWith { epoch to true },
    )

    private fun stage(
        snap: ReadinessSnapshot?,
        lastRefusal: String? = null,
        lastStage: String? = null,
    ) = LinuxRuntimeReadinessController.diagnosticStage(snap, lastRefusal, epoch, lastStage)

    // MARK: - total decision core (never throws)

    @Test fun allSevenLiveIsReady() {
        assertEquals("ready", stage(snapshot(fields = seven)))
    }

    /** Main review negative case 1: every derived field true but the live
     * epoch differs — an explicit cause token, NOT a crash. */
    @Test fun allFieldsTrueWithEpochMismatchNamesTheCauseWithoutThrowing() {
        val result = stage(snapshot(liveEpoch = epoch + 1, fields = seven))
        assertEquals("epochMismatch|refusal:|stage:", result)
    }

    /** All fields true but the peer anchor is gone: explicit cause. */
    @Test fun allFieldsTrueWithoutAnchorNamesTheCause() {
        assertEquals("peerUnanchored|refusal:|stage:",
            stage(snapshot(anchored = false, fields = seven)))
    }

    /** All fields true but THIS epoch is admission-suspended: explicit
     * cause (suspension blocks positive readiness by contract). */
    @Test fun allFieldsTrueWhileSuspendedNamesTheCause() {
        assertEquals("suspended|refusal:|stage:",
            stage(snapshot(suspended = epoch, fields = seven)))
    }

    /** All fields true, epoch/anchor/suspension fine, but one accepted-fact
     * record is ABSENT: the honest `unaccepted:<kind>` cause — the branch
     * the pre-fix `first{}` would have crashed on. */
    @Test fun acceptedRecordAbsentNamesTheKind() {
        val accepted = ReadinessSnapshot.ALL_SEVEN
            .mapNotNull { ReadinessSnapshot.kindFor(it) }
            .filter { it != "workspaceMappingSynced" }
            .associateWith { epoch to true }
        assertEquals("unaccepted:workspaceMappingSynced|refusal:|stage:",
            stage(snapshot(fields = seven, accepted = accepted)))
    }

    /** Accepted record present but bound to a FOREIGN epoch or not live:
     * same honest `unaccepted:<kind>` cause. */
    @Test fun acceptedRecordForeignEpochNamesTheKind() {
        val accepted = ReadinessSnapshot.ALL_SEVEN
            .mapNotNull { ReadinessSnapshot.kindFor(it) }
            .associateWith { kind ->
                if (kind == "leaseAuthorityQualified") (epoch - 1) to true else epoch to true
            }
        assertEquals("unaccepted:leaseAuthorityQualified|refusal:|stage:",
            stage(snapshot(fields = seven, accepted = accepted)))
        val notLive = ReadinessSnapshot.ALL_SEVEN
            .mapNotNull { ReadinessSnapshot.kindFor(it) }
            .associateWith { kind ->
                if (kind == "engineConnected") epoch to false else epoch to true
            }
        assertEquals("unaccepted:engineConnected|refusal:|stage:",
            stage(snapshot(fields = seven, accepted = notLive)))
    }

    /** A genuinely missing derived field is named (first in the frozen
     * ALL_SEVEN order), with the closed refusal/stage tokens appended. */
    @Test fun missingFieldIsNamed() {
        assertEquals(
            "missing:workspaceMappingSynced|refusal:invalidated:all|stage:mapping_unsynced",
            stage(snapshot(fields = five), lastRefusal = "invalidated:all",
                lastStage = "mapping_unsynced"))
    }

    @Test fun degenerateInputsAreTotal() {
        assertEquals("status:unreadable", stage(null))
        assertEquals("lane:unbound",
            LinuxRuntimeReadinessController.diagnosticStage(
                snapshot(fields = seven), null, 0, null))
    }

    // MARK: - closed token vocabulary (Main review correction 2)

    @Test fun knownTokensPassThroughUnchanged() {
        for (token in listOf("mapping_unsynced", "prerequisites_unverified",
            "workspace_unresolved", "quiescence_unproven", "mailboxClosed",
            "activation_refused", "preflightBusy")) {
            assertEquals(token, LinuxRuntimeReadinessController.closedStageToken(token))
        }
        assertEquals("invalidated:all",
            LinuxRuntimeReadinessController.closedStageToken("invalidated:all"))
        assertEquals("invalidated:workspaceMappingSynced",
            LinuxRuntimeReadinessController.closedStageToken("invalidated:workspaceMappingSynced"))
    }

    /** Printable-ASCII values that are NOT in the closed set — a raw path,
     * a pure-hex digest/key shape, free-form exception text, an
     * `invalidated:` prefix with a foreign suffix — all map to the fixed
     * `redacted` token. Length/printability alone never passes. */
    @Test fun unknownValuesAreRedactedNeverPassedThrough() {
        val hostile = listOf(
            "/data/user/0/com.floe.android/files/workspace",
            "a".repeat(64),
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
            "failed to connect to /dev/socket/xyz",
            "invalidated:/data/user/0/x",
            "invalidated:workspaceMapping",
            "MISSING:workspaceMappingSynced",
            "x".repeat(200),
        )
        for (value in hostile) {
            assertEquals("redacted", LinuxRuntimeReadinessController.closedStageToken(value))
        }
        // A hostile recorded stage/refusal reaches the composed line only as
        // the fixed token — the raw value never appears.
        val line = stage(snapshot(fields = five),
            lastRefusal = "/data/user/0/secret", lastStage = "b".repeat(64))
        assertEquals("missing:workspaceMappingSynced|refusal:redacted|stage:redacted", line)
    }

    @Test fun emptyTokenRecordsNothing() {
        assertNull(LinuxRuntimeReadinessController.closedStageToken(""))
        // An empty lastRefusal/lastStage stays an empty segment (no token).
        assertEquals("missing:workspaceMappingSynced|refusal:|stage:",
            stage(snapshot(fields = five), lastRefusal = "", lastStage = ""))
    }

    // MARK: - epoch-tagged stage visibility (Main steer 2026-10-23)

    @Test fun stageIsVisibleOnlyUnderItsCapturedEpoch() {
        val recorded = 7L to "mapping_unsynced"
        assertEquals("mapping_unsynced",
            LinuxRuntimeReadinessController.stageForEpoch(recorded, 7))
        // A newer generation never surfaces the old Root's late recording.
        assertNull(LinuxRuntimeReadinessController.stageForEpoch(recorded, 8))
        assertNull(LinuxRuntimeReadinessController.stageForEpoch(null, 7))
    }
}
