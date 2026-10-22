// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.workspacebridge.CoreWorkspaceGrant
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * G03-R3 grant refusal observation — cross-module closed-vocabulary fence.
 * AUTHORED NOT RUN here (Main's grouped JVM batch executes).
 *
 * Every token the grant factory's refusal observer can emit MUST already be
 * an enumerated member of this controller's KNOWN_STAGE_TOKENS set: the
 * stage surface is membership-bound, so an un-enumerated producer token
 * would surface only as the fixed `redacted` token and the branch evidence
 * would be lost. This test pins the producer (workspacebridge constants)
 * and the consumer (app closed vocabulary) against each other.
 */
class WorkspaceGrantRefusalVocabularyTest {

    @Test fun everyGrantRefusalTokenPassesTheClosedStageVocabularyUnchanged() {
        val tokens = CoreWorkspaceGrant.BRANCH_REFUSAL_TOKENS +
            CoreWorkspaceGrant.NATIVE_REFUSAL_CODES
        assertEquals(17, tokens.size)
        for (token in tokens) {
            assertEquals(token, LinuxRuntimeReadinessController.closedStageToken(token))
        }
        // The historical collapsed token and the pre-existing pump grammar
        // stay visible alongside the new finer tokens (fallback when an old
        // caller sees null without an observer, and every lane that never
        // changed).
        assertEquals("workspace_unresolved",
            LinuxRuntimeReadinessController.closedStageToken("workspace_unresolved"))
    }

    @Test fun grantTokensSurviveThePumpBoundedCodeGrammar() {
        // The pump derives the reply reason from the thrown message through
        // boundedCode(): the message must be non-empty, <=32 printable
        // ASCII, or it collapses to `preflight_failed`.
        (CoreWorkspaceGrant.BRANCH_REFUSAL_TOKENS + CoreWorkspaceGrant.NATIVE_REFUSAL_CODES)
            .forEach { token ->
                assertEquals(token, LinuxShellPump.boundedCode(IllegalStateException(token)))
            }
    }
}
