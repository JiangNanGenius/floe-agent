// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeSigningIdentityTest {
    private val old = "a".repeat(64)
    private val current = "b".repeat(64)
    private val other = "c".repeat(64)

    @Test fun singleSignerUsesCurrentHistoryEntry() {
        assertEquals(setOf(current), RuntimeSigningIdentity.selectCurrent(false, setOf(current), listOf(old, current)))
    }
    @Test fun availableHistoryDoesNotRequireContentsGetter() {
        assertEquals(setOf(current), RuntimeSigningIdentity.selectCurrent(false, emptySet(), listOf(old, current)))
    }
    @Test fun currentContentsRemainAProofWhenHistoryIsMissing() {
        assertEquals(setOf(current), RuntimeSigningIdentity.selectCurrent(false, setOf(current), emptyList()))
    }
    @Test fun pastCertificateDoesNotBecomeCurrentIdentity() {
        assertTrue(RuntimeSigningIdentity.selectCurrent(false, setOf(old), listOf(old, current)).isEmpty())
        assertEquals(setOf(current), RuntimeSigningIdentity.selectCurrent(false, emptySet(), listOf(old, current)))
    }
    @Test fun contradictoryCurrentProofsRefuse() {
        assertTrue(RuntimeSigningIdentity.selectCurrent(false, setOf(other), listOf(old, current)).isEmpty())
    }
    @Test fun multipleSignersRequireTheEntireSet() {
        assertEquals(setOf(current, other), RuntimeSigningIdentity.selectCurrent(true, setOf(current, other), emptyList()))
        assertTrue(RuntimeSigningIdentity.selectCurrent(true, setOf(current), emptyList()).isEmpty())
        assertTrue(RuntimeSigningIdentity.selectCurrent(false, setOf(current, other), emptyList()).isEmpty())
    }
    @Test fun absentProofsRemainUnavailable() {
        assertTrue(RuntimeSigningIdentity.selectCurrent(false, emptySet(), emptyList()).isEmpty())
        assertTrue(RuntimeSigningIdentity.selectCurrent(true, emptySet(), emptyList()).isEmpty())
    }
    @Test fun malformedDigestsDoNotCreateAnIdentity() {
        assertTrue(RuntimeSigningIdentity.selectCurrent(false, setOf("not-a-certificate"), emptyList()).isEmpty())
        assertTrue(RuntimeSigningIdentity.selectCurrent(false, emptySet(), listOf("bad", current)).isEmpty())
    }
}
