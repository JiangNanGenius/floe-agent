// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Grant-flag honesty, persisted-vs-session separation, re-pick semantics,
 * and shared-grant release ownership. (job-2b28c7f9fbaf4da4, G04-R1.)
 */
class SafGrantGatewayTest {

    private fun acceptTree(fake: FakeSafBackend, gateway: SafGrantGateway, flags: Int): PickAcceptResult {
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        val spec = gateway.pickerForTree()
        return gateway.acceptPickResult(spec, tree.uriString, flags)
    }

    @Test
    fun persistsOnlyFlagsActuallyGrantedAndOffered() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val accept = gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or SafGrantFlagBits.PERSISTABLE,
        )
        assertTrue(accept is PickAcceptResult.Accepted)
        val accepted = accept as PickAcceptResult.Accepted
        assertEquals(setOf(SafAccessFlag.READ, SafAccessFlag.WRITE), accepted.granted)
        assertEquals(setOf(SafAccessFlag.READ, SafAccessFlag.WRITE), accepted.persisted)
        assertFalse(accepted.transientOnly)
        // WRITE taken first, then READ; exactly two platform takes.
        assertEquals(
            listOf(tree.uriString to SafAccessFlag.WRITE, tree.uriString to SafAccessFlag.READ),
            fake.takeLog,
        )
        assertTrue(gateway.ownedGrantUris().contains(tree.uriString))
    }

    @Test
    fun readOnlyResultNeverClaimsWrite() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val accept = acceptTree(fake, gateway, SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE)
        val accepted = accept as PickAcceptResult.Accepted
        assertEquals(setOf(SafAccessFlag.READ), accepted.granted)
        assertEquals(setOf(SafAccessFlag.READ), accepted.persisted)
        assertTrue(fake.takeLog.none { it.second == SafAccessFlag.WRITE })
    }

    @Test
    fun persistableFailureFallsBackToTruthfulTransientAcceptance() {
        val fake = FakeSafBackend()
        fake.persistMode = FakeSafBackend.PersistMode.FAILS
        val gateway = SafGrantGateway(fake.backend)
        val accept = acceptTree(fake, gateway, SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE)
        val accepted = accept as PickAcceptResult.Accepted
        assertEquals(emptySet<SafAccessFlag>(), accepted.persisted)
        assertTrue(accepted.transientOnly)
        assertTrue(accepted.needsRePickWhenExpired)
    }

    @Test
    fun nullResultCancelsWithoutInventingGrant() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val accept = gateway.acceptPickResult(gateway.pickerForTree(), null, 0)
        assertTrue(accept is PickAcceptResult.Cancelled)
        assertTrue(fake.takeLog.isEmpty())
        assertTrue(fake.persisted.isEmpty())
    }

    @Test
    fun wrongKindResultIsRejectedNotStored() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val docUri = "content://fake.provider/document/whatever"
        val accept = gateway.acceptPickResult(
            gateway.pickerForTree(),
            docUri,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        assertTrue(accept is PickAcceptResult.Rejected)
        assertTrue(fake.takeLog.isEmpty())
    }

    @Test
    fun liveSessionGrantWorksEvenThoughPersistedTruthIsAbsent() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        val doc = fake.seedDoc(tree, "a.txt", content = "hello".toByteArray())
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        val accept = gateway.acceptPickResult(gateway.pickerForTree(), tree.uriString, SafGrantFlagBits.GRANT_READ)
        val accepted = accept as PickAcceptResult.Accepted
        assertTrue(accepted.transientOnly)
        // persistedUriPermissions is EMPTY here; the session probe still allows reads.
        assertTrue(fake.persisted.isEmpty())
        val ops = SafProviderOperations(fake.backend, gateway, SafLimits.DEFAULT)
        val outcome = ops.readBounded(fake.refOf(tree, doc), 4096, null, SafCancelToken())
        assertTrue("session grant must not be denied by persisted-only lookup", outcome is SafOutcome.Success)
        assertEquals("hello", String((outcome as SafOutcome.Success).value))
    }

    @Test
    fun expiredSessionGrantYieldsOneTypedRePick() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        val doc = fake.seedDoc(tree, "a.txt", content = "x".toByteArray())
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        gateway.acceptPickResult(gateway.pickerForTree(), tree.uriString, SafGrantFlagBits.GRANT_READ)
        val ops = SafProviderOperations(fake.backend, gateway, SafLimits.DEFAULT)
        assertTrue(ops.readBounded(fake.refOf(tree, doc), 4096, null, SafCancelToken()) is SafOutcome.Success)
        fake.session.remove(tree.uriString) // process/session grant actually died
        val failed = ops.readBounded(fake.refOf(tree, doc), 4096, null, SafCancelToken())
        assertTrue(failed is SafOutcome.Failure)
        assertTrue((failed as SafOutcome.Failure).failure is SafFailure.RePickRequired)
        // No silent re-acquisition happened.
        assertTrue(fake.takeLog.isEmpty())
    }

    @Test
    fun revokedPersistedGrantDistinguishesFromNeverGranted() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        fake.session.clear()
        fake.persisted.clear() // user revoked at the system level
        val ops = SafProviderOperations(fake.backend, gateway, SafLimits.DEFAULT)
        val revoked = ops.listTreePage(tree, null, PageRequest(8), SafCancelToken())
        assertTrue((revoked as SafOutcome.Failure).failure is SafFailure.Revoked)

        val other = SafGrantGateway(fake.backend)
        val missing = SafProviderOperations(fake.backend, other, SafLimits.DEFAULT)
            .listTreePage(tree, null, PageRequest(8), SafCancelToken())
        assertTrue((missing as SafOutcome.Failure).failure is SafFailure.GrantMissing)
    }

    @Test
    fun unknownProbeProceedsOptimisticallyWithoutRePickStorm() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.seedDoc(tree, "a.txt", content = "y".toByteArray())
        gateway.acceptPickResult(gateway.pickerForTree(), tree.uriString, SafGrantFlagBits.GRANT_READ)
        fake.probeUnknown = true // declarative answer unavailable on this provider
        val ops = SafProviderOperations(fake.backend, gateway, SafLimits.DEFAULT)
        val outcome = ops.listTreePage(tree, null, PageRequest(8), SafCancelToken())
        assertTrue(outcome is SafOutcome.Success)
        assertFalse(fake.takeLog.isNotEmpty()) // no re-persistence attempts
    }

    @Test
    fun releaseWithoutHostBrokerNeverTouchesPlatform() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        val result = gateway.requestRelease(tree, setOf(SafAccessFlag.READ))
        assertTrue(result is ReleaseResult.RefusedNoBroker)
        assertTrue(fake.releaseLog.isEmpty())
        assertNotNull(fake.persisted[tree.uriString]) // grant untouched
    }

    @Test
    fun grantTakenElsewhereIsNeverAReleaseCandidate() {
        val fake = FakeSafBackend()
        fake.persisted["content://fake.provider/tree/main"] = mutableSetOf(SafAccessFlag.READ) // attachments took it
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        fake.persistMode = FakeSafBackend.PersistMode.ALREADY_HELD
        val accept = gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        val accepted = accept as PickAcceptResult.Accepted
        assertTrue(accepted.persisted.contains(SafAccessFlag.READ)) // observable
        assertFalse(gateway.ownedGrantUris().contains(tree.uriString)) // NOT ours
        val release = gateway.requestRelease(tree, setOf(SafAccessFlag.READ))
        assertTrue(release is ReleaseResult.NotOwned)
        assertTrue(fake.releaseLog.isEmpty())
    }

    /** Broker that invokes the release callback exactly once inside its exclusive section. */
    private class CountingBroker(private val permit: Boolean) : SafReleaseBroker {
        var calls = 0
        var callbackInvocations = 0
        override fun executeReleaseUnderExclusiveAuthority(
            uri: SafUriRef,
            flag: SafAccessFlag,
            release: () -> Boolean,
        ): BrokeredRelease {
            calls++
            if (!permit) return BrokeredRelease.Retained("other references held")
            callbackInvocations++
            return BrokeredRelease.Executed(release())
        }
    }

    @Test
    fun hostBrokerGateControlsActualRelease() {
        val fake = FakeSafBackend()
        val treeA = fake.treeUri("a")
        val treeB = fake.treeUri("b")
        fake.seedRoot(treeA)
        fake.seedRoot(treeB)
        fake.session[treeA.uriString] = setOf(SafAccessFlag.READ)
        fake.session[treeB.uriString] = setOf(SafAccessFlag.READ)

        val denyingBroker = CountingBroker(permit = false)
        val gatewayDeny = SafGrantGateway(fake.backend, denyingBroker)
        gatewayDeny.acceptPickResult(
            gatewayDeny.pickerForTree(),
            treeA.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        val retained = gatewayDeny.requestRelease(treeA, setOf(SafAccessFlag.READ))
        assertTrue(retained is ReleaseResult.RetainedByBroker)
        assertEquals(1, denyingBroker.calls)
        assertEquals("TOCTOU contract: denied broker must never invoke the release callback", 0, denyingBroker.callbackInvocations)
        assertTrue(fake.releaseLog.isEmpty())
        assertNotNull(fake.persisted[treeA.uriString])

        // Distinct URI so the take is genuinely ours (no cross-test grant reuse).
        val allowingBroker = CountingBroker(permit = true)
        val gatewayAllow = SafGrantGateway(fake.backend, allowingBroker)
        gatewayAllow.acceptPickResult(
            gatewayAllow.pickerForTree(),
            treeB.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        val released = gatewayAllow.requestRelease(treeB, setOf(SafAccessFlag.READ))
        assertTrue(released is ReleaseResult.Released)
        assertEquals(1, allowingBroker.callbackInvocations)
        assertEquals(listOf(treeB.uriString to SafAccessFlag.READ), fake.releaseLog)
        assertFalse(fake.persisted[treeB.uriString].orEmpty().contains(SafAccessFlag.READ))

        // Second request for the same flag: nothing owned remains, callback never
        // fires again (no unguarded second release).
        val second = gatewayAllow.requestRelease(treeB, setOf(SafAccessFlag.READ))
        assertTrue(second is ReleaseResult.NotOwned || second is ReleaseResult.NothingOwned)
        assertEquals(1, allowingBroker.callbackInvocations)
    }

    @Test
    fun forgetOnlyDropsLocalDisplayAndSessionNotes() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        assertTrue(gateway.cachedDisplayHints().containsKey(tree.uriString))
        gateway.forget(tree)
        assertNull(gateway.cachedDisplayHints()[tree.uriString])
        // OS truth (persisted) remains — forget cannot revoke and cannot grant.
        assertNotNull(fake.persisted[tree.uriString])
        val sweep = gateway.revalidate()
        assertTrue(sweep.lost.isEmpty())
    }

    @Test
    fun revalidateSweepsBothTruthsAndFlagsLostGrants() {
        val fake = FakeSafBackend()
        val gateway = SafGrantGateway(fake.backend)
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        fake.persisted.clear()
        fake.session.clear()
        val sweep = gateway.revalidate()
        assertEquals(listOf(tree), sweep.lost)
        // The session note died with it too: both sweeps report the same URI.
        assertEquals(listOf(tree), sweep.lostSessionGrants)
        assertTrue(gateway.ownedGrantUris().isEmpty())
    }
}
