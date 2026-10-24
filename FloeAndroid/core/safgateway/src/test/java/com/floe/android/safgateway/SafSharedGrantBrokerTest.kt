// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class SafSharedGrantBrokerTest {
    private val uri = SafUriRef("content://provider/document/one")
    private class Platform(var held: Boolean = false) {
        var takes = 0; var releases = 0
        fun acquire(broker: SafSharedGrantBroker, uri: SafUriRef) = broker.acquire(uri, SafAccessFlag.READ,
            isPersisted = { held }, take = { takes++; held = true }, release = { releases++; held = false; true })
    }

    @Test fun preexistingPermissionIsHeldButNeverClaimedOrReleased() {
        val b = SafSharedGrantBroker(); val p = Platform(true)
        val lease = p.acquire(b, uri)
        assertTrue(lease.persistedAtAcquisition)
        assertEquals(0, p.takes)
        assertEquals(SafSharedGrantBroker.Release.PREEXISTING_PRESERVED, lease.release())
        assertTrue(p.held); assertEquals(0, p.releases)
    }

    @Test fun newlyTakenGrantTransfersReleaseUntilLastFeatureStopsUsingIt() {
        val b = SafSharedGrantBroker(); val p = Platform()
        val attachment = p.acquire(b, uri); val workspace = p.acquire(b, uri)
        assertEquals(1, p.takes)
        assertEquals(SafSharedGrantBroker.Release.RETAINED, attachment.release())
        assertTrue(p.held); assertEquals(0, p.releases)
        assertEquals(SafSharedGrantBroker.Release.RELEASED, workspace.release())
        assertFalse(p.held); assertEquals(1, p.releases)
        assertEquals(SafSharedGrantBroker.Release.ALREADY_CLOSED, workspace.release())
        assertEquals(1, p.releases)
    }

    @Test fun readReferencesDoNotBlockUnrelatedWriteRelease() {
        val b = SafSharedGrantBroker(); val lease = b.retain(uri, SafAccessFlag.READ)
        var calls = 0
        val released = b.executeReleaseUnderExclusiveAuthority(uri, SafAccessFlag.WRITE) { calls++; true }
        assertEquals(BrokeredRelease.Executed(true), released); assertEquals(1, calls)
        assertTrue(b.executeReleaseUnderExclusiveAuthority(uri, SafAccessFlag.READ) { fail(); true } is BrokeredRelease.Retained)
        lease.close()
    }

    @Test fun externalGatewayReleaseCannotRaceAnActiveSourceReference() {
        val b = SafSharedGrantBroker(); val lease = b.retain(uri, SafAccessFlag.READ)
        var calls = 0
        assertTrue(b.executeReleaseUnderExclusiveAuthority(uri, SafAccessFlag.READ) { calls++; true } is BrokeredRelease.Retained)
        assertEquals(0, calls)
        lease.close()
        assertEquals(BrokeredRelease.Executed(true), b.executeReleaseUnderExclusiveAuthority(uri, SafAccessFlag.READ) { calls++; true })
        assertEquals(1, calls)
    }

    @Test fun failedPersistenceRemainsSessionOnlyAndDoesNotReleaseSomeoneElsesGrant() {
        val b = SafSharedGrantBroker(); var releases = 0
        val lease = b.acquire(uri, SafAccessFlag.READ, { false }, { throw SecurityException() }, { releases++; true })
        assertFalse(lease.persistedAtAcquisition)
        assertEquals(SafSharedGrantBroker.Release.PREEXISTING_PRESERVED, lease.release())
        assertEquals(0, releases)
    }

    @Test fun revokedPermissionIsNotResurrectedByExistingReferenceCache() {
        val b = SafSharedGrantBroker(); val p = Platform()
        val old = p.acquire(b, uri); p.held = false
        val current = b.acquire(uri, SafAccessFlag.READ, { p.held }, { throw SecurityException() }, { fail(); true })
        assertFalse(current.persistedAtAcquisition)
        old.close(); current.close()
        assertEquals(0, p.releases)
    }

    @Test fun failedReleaseIsReportedAndNotRetriedAgainstNewAuthorization() {
        val b = SafSharedGrantBroker(); var held = false; var releases = 0
        val lease = b.acquire(uri, SafAccessFlag.READ, { held }, { held = true }, { releases++; false })
        assertEquals(SafSharedGrantBroker.Release.FAILED, lease.release())
        val later = b.acquire(uri, SafAccessFlag.READ, { held }, { fail() }, { releases++; true })
        assertEquals(SafSharedGrantBroker.Release.PREEXISTING_PRESERVED, later.release())
        assertEquals(1, releases)
    }

    @Test fun referenceLimitRejectsBeforeAnyAdditionalPlatformSideEffect() {
        val b = SafSharedGrantBroker(1); val first = b.retain(uri, SafAccessFlag.READ)
        var calls = 0
        try {
            b.acquire(uri, SafAccessFlag.READ, { calls++; false }, { calls++ }, { calls++; true })
            fail()
        } catch (_: IllegalStateException) { }
        assertEquals(0, calls)
        first.close()
        b.retain(uri, SafAccessFlag.READ).close()
    }

    @Test fun failedReadbackRollsBackOnlyTheGrantJustTaken() {
        val b = SafSharedGrantBroker(); var probes = 0; var releases = 0
        try {
            b.acquire(uri, SafAccessFlag.READ, { if (++probes == 1) false else throw IllegalStateException() }, {}, { releases++; true })
            fail()
        } catch (_: IllegalStateException) { }
        assertEquals(1, releases)
        b.retain(uri, SafAccessFlag.READ).close()
    }

    @Test fun platformReleaseCannotReenterAndAdmitUseOfTheSameGrant() {
        val b = SafSharedGrantBroker(); var rejected = false
        assertEquals(BrokeredRelease.Executed(true), b.executeReleaseUnderExclusiveAuthority(uri, SafAccessFlag.READ) {
            try { b.retain(uri, SafAccessFlag.READ) } catch (_: IllegalStateException) { rejected = true }
            true
        })
        assertTrue(rejected)
    }

    @Test(timeout = 5000) fun concurrentRetainWaitsUntilActualReleaseCallbackSettles() {
        val b = SafSharedGrantBroker()
        val inside = CountDownLatch(1); val contender = CountDownLatch(1)
        val allowRelease = CountDownLatch(1); val admitted = AtomicBoolean(false)
        val threadFailure = AtomicReference<Throwable>()
        val releaser = Thread {
            try { b.executeReleaseUnderExclusiveAuthority(uri, SafAccessFlag.READ) {
                inside.countDown()
                assertTrue(contender.await(2, TimeUnit.SECONDS))
                assertFalse(admitted.get())
                assertTrue(allowRelease.await(2, TimeUnit.SECONDS))
                true
            } } catch (error: Throwable) { threadFailure.set(error) }
        }
        releaser.start(); assertTrue(inside.await(2, TimeUnit.SECONDS))
        val reader = Thread {
            try {
                contender.countDown()
                val lease = b.retain(uri, SafAccessFlag.READ)
                admitted.set(true); lease.close()
            } catch (error: Throwable) { threadFailure.set(error) }
        }
        reader.start(); assertTrue(contender.await(2, TimeUnit.SECONDS))
        assertFalse(admitted.get()); allowRelease.countDown()
        releaser.join(); reader.join(); assertNull(threadFailure.get()); assertTrue(admitted.get())
    }
}
