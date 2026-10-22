// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G03-R3 grant refusal observation — pure JVM boundary tests for the closed
 * refusal-token selection of [CoreWorkspaceGrant.create]. AUTHORED NOT RUN
 * here (Main's grouped JVM batch executes). The factory itself needs the
 * Core app Context and the native authority and is exercised by Main's
 * grouped compile + device acceptance; everything asserted below is the
 * pure, module-local grammar that keeps the observation closed-vocabulary.
 */
class CoreWorkspaceGrantRefusalTokenTest {

    @Test fun enumeratedNativeCodeReplacesItsBranchToken() {
        assertEquals("bindingUnavailable", CoreWorkspaceGrant.refusalToken(
            CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "bindingUnavailable"))
        assertEquals("epochNotCurrent", CoreWorkspaceGrant.refusalToken(
            CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "epochNotCurrent"))
        assertEquals("grantNotMinted", CoreWorkspaceGrant.refusalToken(
            CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, "grantNotMinted"))
        assertEquals("bindingMalformed", CoreWorkspaceGrant.refusalToken(
            CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, "bindingMalformed"))
    }

    @Test fun unknownEmptyAndParameterizedCodesFallBackToTheBranchToken() {
        assertEquals(CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED,
            CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, null))
        assertEquals(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED,
            CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, ""))
        // Parameterized engine codes are never passed through: free text
        // (stages, errno values, anything variable) must not ride the
        // observer — the branch token names the lane instead.
        assertEquals(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED,
            CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, "workspaceIO:read:5"))
        assertEquals(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED,
            CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, "workspaceProofRefused:light"))
        // Membership is case- and whitespace-exact; near-misses fall back.
        assertEquals(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED,
            CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, "bindingUnresolved "))
        assertEquals(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED,
            CoreWorkspaceGrant.refusalToken(CoreWorkspaceGrant.REFUSAL_OPEN_REFUSED, "GRANTNOTMINTED"))
    }

    @Test fun branchVocabularyIsExactlyTheCreateNullBranches() {
        assertEquals(
            setOf(
                "grant_arguments_invalid", "grant_peer_refused",
                "grant_binding_unparsable", "grant_binding_refused",
                "grant_identity_mismatch", "grant_open_unparsable",
                "grant_open_refused", "grant_session_key_malformed",
            ),
            CoreWorkspaceGrant.BRANCH_REFUSAL_TOKENS,
        )
        assertEquals(9, CoreWorkspaceGrant.NATIVE_REFUSAL_CODES.size)
    }

    @Test fun everyRefusalTokenSurvivesThePumpBoundedGrammar() {
        val all = CoreWorkspaceGrant.BRANCH_REFUSAL_TOKENS + CoreWorkspaceGrant.NATIVE_REFUSAL_CODES
        assertEquals(17, all.size) // the two sets are disjoint; no token collides
        for (token in all + setOf("workspace_unresolved")) {
            assertTrue(token, token.isNotEmpty() && token.length <= 32)
            assertTrue(token, token.all { it.code in 0x21..0x7e })
        }
    }
}
