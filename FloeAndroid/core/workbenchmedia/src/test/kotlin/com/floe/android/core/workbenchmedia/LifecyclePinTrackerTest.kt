// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.lifecycle.LifecyclePinTracker
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LifecyclePinTrackerTest {
    private val root = Files.createTempDirectory("workbenchmedia-pins").toFile()
    private val context = CreativeProjectContext(
        projectID = "project-1",
        sessionToken = "session-token-1",
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext.standalone(),
    )

    @After
    fun cleanup() {
        root.deleteRecursively()
    }

    @Test
    fun acquiredPinIsRegisteredAndReleasedExactlyOnce() = runBlocking {
        val authority = FakeAuthority()
        val tracker = LifecyclePinTracker(authority, Dispatchers.Unconfined)
        val pin = tracker.acquire(request())
        assertEquals(1, tracker.outstandingCount())
        assertTrue(tracker.release(pin))
        assertEquals(0, tracker.outstandingCount())
        // A terminal/worker finally may retry; the second call must not call
        // native release again.
        assertTrue(tracker.release(pin))
        assertEquals(listOf("pin-1"), authority.releases)
    }

    @Test
    fun unconfirmedReleaseRetainsTheOwnedReferenceAndFailsDrain() = runBlocking {
        val authority = FakeAuthority()
        authority.releaseResult = false
        val tracker = LifecyclePinTracker(authority, Dispatchers.Unconfined)
        val pin = tracker.acquire(request())
        assertFalse(tracker.release(pin))
        assertEquals(1, tracker.outstandingCount())

        val firstDrain = tracker.awaitDrained(100L)
        assertFalse(firstDrain.drained)
        assertEquals(1, firstDrain.outstanding)
        assertTrue(firstDrain.releaseUnknown)

        authority.releaseResult = true
        assertTrue(tracker.release(pin))
        assertEquals(0, tracker.outstandingCount())
        assertTrue(tracker.awaitDrained(100L).drained)
        // One unconfirmed owner release, one documented awaitDrained retry of
        // the still-requested pin, then the confirmed owner release.
        assertEquals(3, authority.releases.size)
    }

    @Test
    fun drainDoesNotReleaseAPinWhoseOwnerNeverRequestedRelease() = runBlocking {
        val authority = FakeAuthority()
        val tracker = LifecyclePinTracker(authority, Dispatchers.Unconfined)
        tracker.acquire(request())
        val report = tracker.awaitDrained(50L)
        assertFalse(report.drained)
        assertEquals(1, report.outstanding)
        // A failed player close must keep the native reference; drain is not
        // allowed to guess that the owner is done.
        assertEquals(emptyList<String>(), authority.releases)
    }

    @Test
    fun duplicateNativePinTokenIsRefusedWithoutReleasingTheFirstOwner() = runBlocking {
        val authority = FakeAuthority()
        authority.forceToken = "same-token"
        val tracker = LifecyclePinTracker(authority, Dispatchers.Unconfined)
        tracker.acquire(request())
        var refused = false
        try {
            tracker.acquire(request())
        } catch (_: MediaRefusal) {
            refused = true
        }
        assertTrue(refused)
        assertEquals(1, tracker.outstandingCount())
        assertEquals(emptyList<String>(), authority.releases)
    }

    @Test
    fun aNativeEchoFromAnotherRootIsRefusedAndReleased() = runBlocking {
        val authority = FakeAuthority()
        authority.wrongRoot = true
        val tracker = LifecyclePinTracker(authority, Dispatchers.Unconfined)
        var refused = false
        try {
            tracker.acquire(request())
        } catch (_: MediaRefusal) {
            refused = true
        }
        assertTrue(refused)
        // Unconfined release runs synchronously; the bad native reference is
        // not silently forgotten and not left for an unrelated owner.
        assertEquals(listOf("pin-1"), authority.releases)
        assertEquals(0, tracker.outstandingCount())
    }

    private fun request(): MediaLifecyclePinRequest = MediaLifecyclePinRequest(
        context = context,
        kind = MediaLifecycleKind.EXPORT,
        epoch = 7L,
        mediaRootPath = root.path,
        attemptID = "attempt-1",
        jobID = "export-1",
    )

    private class FakeAuthority : WorkbenchMediaLifecycleAuthority {
        val releases = mutableListOf<String>()
        var releaseResult = true
        var forceToken: String? = null
        var wrongRoot = false
        private var sequence = 0

        override suspend fun pin(request: MediaLifecyclePinRequest): MediaLifecyclePinDecision {
            sequence += 1
            val pin = MediaLifecyclePin(
                pinToken = forceToken ?: "pin-$sequence",
                epoch = request.epoch,
                mediaRootPath = if (wrongRoot) "/workbenchmedia/not-the-accepted-root" else request.mediaRootPath,
                projectID = request.context.projectID,
                kind = request.kind,
                attemptID = request.attemptID,
            )
            return MediaLifecyclePinDecision.Pinned(pin)
        }

        override suspend fun release(pin: MediaLifecyclePin): Boolean {
            releases += pin.pinToken
            return releaseResult
        }
    }
}
