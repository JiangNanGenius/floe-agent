// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.workspacebridge.RuntimeWorkspaceSession
import com.floe.android.workspacebridge.WorkspaceExportOutcome
import com.floe.android.workspacebridge.WorkspaceMirrorEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail
import org.junit.Test

/**
 * G03-R3 authored-not-run regressions for the FIRST-USE PREFLIGHT executor's
 * pure decision core. Covers Main's required cases: the faithful non-empty
 * baseline round-trip versus the forbidden EMPTY-export deletion plan, a
 * zero-entry export honest ONLY for a truly empty baseline, the canonical
 * lease evidence being real-event bound (never a hash of "true"), and the
 * bounded export verdict mapping. The harness/native paths (authority,
 * census, session IO) are exercised by Main's grouped compile + device
 * lane; runtimeapp adds a JVM test source set + junit testImplementation
 * when this batch merges (build wiring is Main-owned).
 */
class RuntimeWorkspacePreflightGuardTest {

    @Test fun faithfulMirrorOfNonEmptyBaselinePasses() {
        // 3 mirrored entries, staged back as created+replaced+directories,
        // zero deletions, zero refusals: the accepted round trip.
        assertNull(RuntimeWorkspacePreflight.mirrorHonestyViolation(
            mirrored = 3, created = 1, replaced = 1, directories = 1, deleted = 0, links = 0,
            stagedRefusals = 0))
    }

    @Test fun nonEmptyBaselineExportingNothingIsADeletionPlanAndRefuses() {
        // The headline forbidden case: the mirror would apply an EMPTY
        // export against a NON-EMPTY baseline.
        assertNotNull(RuntimeWorkspacePreflight.mirrorHonestyViolation(
            mirrored = 3, created = 0, replaced = 0, directories = 0, deleted = 0, links = 0,
            stagedRefusals = 0))
        // Any explicit deletion is refused even when the rest looks fine.
        assertNotNull(RuntimeWorkspacePreflight.mirrorHonestyViolation(
            mirrored = 3, created = 1, replaced = 1, directories = 0, deleted = 2, links = 0,
            stagedRefusals = 0))
        // Partial staging refusals mean the mirror is NOT complete.
        assertNotNull(RuntimeWorkspacePreflight.mirrorHonestyViolation(
            mirrored = 3, created = 1, replaced = 1, directories = 0, deleted = 0, links = 0,
            stagedRefusals = 1))
    }

    @Test fun zeroEntryExportIsHonestOnlyForATrulyEmptyBaseline() {
        assertNull(RuntimeWorkspacePreflight.mirrorHonestyViolation(
            mirrored = 0, created = 0, replaced = 0, directories = 0, deleted = 0, links = 0,
            stagedRefusals = 0))
    }

    @Test fun leaseEvidenceDigestIsCanonicalAndEventBound() {
        val a = RuntimeWorkspacePreflight.canonicalEvidence(
            "lease-1", "env-1", "550e8400-e29b-41d4-a716-446655440000",
            "6ba7b810-9dad-11d1-80b4-00c04fd430c8", 3, 1, 1, 1, 0, 512)
        val b = RuntimeWorkspacePreflight.canonicalEvidence(
            "lease-2", "env-1", "550e8400-e29b-41d4-a716-446655440000",
            "6ba7b810-9dad-11d1-80b4-00c04fd430c8", 3, 1, 1, 1, 0, 512)
        // Deterministic over the ACTUAL event record; any changed identity,
        // count or census makes a different proof.
        assertEquals(RuntimeWorkspacePreflight.sha256Hex(a), RuntimeWorkspacePreflight.sha256Hex(a))
        assertNotEquals(RuntimeWorkspacePreflight.sha256Hex(a), RuntimeWorkspacePreflight.sha256Hex(b))
        assertEquals(64, RuntimeWorkspacePreflight.sha256Hex(a).length)
        // Known SHA-256 discipline vector (empty string).
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            RuntimeWorkspacePreflight.sha256Hex(""))
        // The record names the REAL release path; it is not a boolean flag.
        assertTrueRecordContains(a)
    }

    private fun assertTrueRecordContains(evidence: String) {
        org.junit.Assert.assertTrue(evidence.contains("\"release\":\"abandonUnstarted\""))
        org.junit.Assert.assertTrue(evidence.contains("\"quiescence\":\"proven-no-children\""))
    }

    @Test fun exportVerdictsMapToBoundedCodesAndNeverSuccessStrings() {
        // RecoverableFailure codes are the runtime's own bounded evidence.
        val failure = WorkspaceExportOutcome.RecoverableFailure("cancelled", true, "a".repeat(32))
        val synced = WorkspaceExportOutcome.Synced("k", 1, 1, 0, 0, 0, 0, "digest")
        val conflict = WorkspaceExportOutcome.Conflict("k", "aborted", 0, 0, 0, 0, 0,
            emptyList(), false, 0, 0, "digest")
        val conflictStatus = WorkspaceExportOutcome.Conflict("k", "conflict", 0, 0, 0, 0, 0,
            emptyList(), false, 0, 0, "digest")
        assertEquals("cancelled", exportCodeOf(failure))
        assertEquals("cancelled", exportCodeOf(conflict))
        assertEquals("mapping_conflict", exportCodeOf(conflictStatus))
        assertEquals("unexpected", exportCodeOf(synced))
    }

    /** The executor's verdict mapping is private; mirror it through the
     *  public execute surface is impossible without Android, so this test
     *  pins the SAME mapping via a tiny re-exposed helper in production. */
    private fun exportCodeOf(outcome: WorkspaceExportOutcome): String =
        RuntimeWorkspacePreflight.exportCodeForTest(outcome)

    /**
     * The executor validates the SAME uppercase grammar as the pump and
     * returns the ORIGINAL bytes untouched (grant equality stays exact).
     * A digit-only fixture cannot tell the two grammars apart — meaningful
     * fixtures must contain A-F.
     */
    @Test fun executorIdentityGrammarMatchesCoreUppercaseBytes() {
        val core = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        assertEquals(core, RuntimeWorkspacePreflight.canonicalUUID(core))
        assertEquals("ABCDEF12-3456-7890-ABCD-EF1234567890",
            RuntimeWorkspacePreflight.canonicalUUID("ABCDEF12-3456-7890-ABCD-EF1234567890"))
        for (refused in listOf(core.lowercase(), "3F2504E0-4F89-11d3-9A0C-0305E82C3301",
            "$core ", "GG2504E0-4F89-11D3-9A0C-0305E82C3301", "run-42", "")) {
            try {
                RuntimeWorkspacePreflight.canonicalUUID(refused)
                fail("refused identity: $refused")
            } catch (_: IllegalArgumentException) { /* identityNotCanonical */ }
        }
    }

    /**
     * PRECOMMIT faithful-mirror guard (the v1 defect: the honesty check only
     * ran AFTER the ORIGINAL session had already invoked EXPORT_FINISH and
     * APPLIED the transaction). A missing/changed baseline entry must be
     * decided here so the preflight pipeline refuses BEFORE any commit; the
     * ordinary shell export path (guard off) still permits deletions.
     */
    @Test fun precommitGuardRefusesUnfaithfulMirrorBeforeCommit() {
        val baseline = mapOf(
            "docs/a.md" to WorkspaceMirrorEntry("file", 42L, null),
            "pics" to WorkspaceMirrorEntry("directory", 0L, null),
            "link" to WorkspaceMirrorEntry("symlink", 0L, "docs/a.md"),
        )
        // Missing baseline entry = the forbidden deletion plan (headline).
        assertEquals("deletion_plan", RuntimeWorkspaceSession.faithfulMirrorViolation(
            baseline, mapOf("pics" to baseline.getValue("pics"),
                           "link" to baseline.getValue("link"))))
        // A non-empty baseline mirrored as NOTHING (the empty-plan case).
        assertEquals("deletion_plan",
            RuntimeWorkspaceSession.faithfulMirrorViolation(baseline, emptyMap()))
        // Changed representation (kind / byte size / contained target).
        assertEquals("mirror_unfaithful", RuntimeWorkspaceSession.faithfulMirrorViolation(
            baseline, mapOf("docs/a.md" to WorkspaceMirrorEntry("directory", 0L, null),
                            "pics" to baseline.getValue("pics"),
                            "link" to baseline.getValue("link"))))
        assertEquals("mirror_unfaithful", RuntimeWorkspaceSession.faithfulMirrorViolation(
            baseline, mapOf("docs/a.md" to WorkspaceMirrorEntry("file", 41L, null),
                            "pics" to baseline.getValue("pics"),
                            "link" to baseline.getValue("link"))))
        assertEquals("mirror_unfaithful", RuntimeWorkspaceSession.faithfulMirrorViolation(
            baseline, mapOf("docs/a.md" to baseline.getValue("docs/a.md"),
                            "pics" to baseline.getValue("pics"),
                            "link" to WorkspaceMirrorEntry("symlink", 0L, "elsewhere"))))
        // Faithful mirror + independent ADDITIONS (never imported baseline
        // entries) stays allowed, exactly like the unchanged shell pipeline.
        assertNull(RuntimeWorkspaceSession.faithfulMirrorViolation(
            baseline, baseline + mapOf("out/new.log" to WorkspaceMirrorEntry("file", 7L, null))))
        // Zero-entry export is honest ONLY for a truly empty baseline.
        assertNull(RuntimeWorkspaceSession.faithfulMirrorViolation(emptyMap(), emptyMap()))
        assertNull(RuntimeWorkspaceSession.faithfulMirrorViolation(baseline, baseline))
    }

    @Test fun commandLikeFieldsCanNeverEnterThePreflightGrammar() {
        // The closed control field set: nothing command/cwd/env/stdin-like
        // can be expressed at all. This asserts the GRAMMAR list itself.
        val allowed = RuntimeWorkspacePreflight.ALLOWED_FIELDS_FOR_TEST
        org.junit.Assert.assertTrue(allowed == setOf("projectID", "runID", "conversationID", "environmentID"))
        for (forbidden in listOf("command", "cwd", "env", "rows", "columns", "stdin", "stdinDelivery",
            "timeoutSeconds")) {
            org.junit.Assert.assertFalse(forbidden, forbidden in allowed)
        }
    }
    @Test fun sameSizeChangedFileBytesCannotPassThePrecommitMirrorGuard() {
        val original = WorkspaceMirrorEntry("file", 4L, null, "a".repeat(64))
        val changed = WorkspaceMirrorEntry("file", 4L, null, "b".repeat(64))
        assertEquals("mirror_unfaithful", RuntimeWorkspaceSession.faithfulMirrorViolation(
            mapOf("same-size.txt" to original), mapOf("same-size.txt" to changed)))
        assertNull(RuntimeWorkspaceSession.faithfulMirrorViolation(
            mapOf("same-size.txt" to original), mapOf("same-size.txt" to original)))
    }

}
