// SPDX-License-Identifier: MPL-2.0
//
// C07 setup-wizard step-list regressions: actionable optional steps, stable
// persisted keys across channel variation (the Full-only device step), and
// safe normalization of a stored step that is not currently walkable.
//
// Pure JVM: no Android runtime, store, provider or settings owner is touched.
package com.floe.android.host.entryflow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C07SetupWizardTest {
    private val now = 2_000_000L

    @Test
    fun manualReopenResumesASkippedStepAndRestartsAFinishedGuide() {
        val skipped = C07SetupState(step = C07SetupStep.FILES, seen = true, skipped = true)
        assertEquals(C07SetupStep.FILES, C07SetupMachine.reopen(skipped, now).step)
        val finished = C07SetupMachine.finish(skipped.copy(step = C07SetupStep.DONE), now)
        val reopened = C07SetupMachine.reopen(finished, now + 1)
        assertEquals(C07SetupStep.WELCOME, reopened.step)
        assertFalse(reopened.finished)
        assertFalse(C07SetupMachine.offerOnce(reopened, now + 2).second)
    }
    private val fullSteps = C07SetupMachine.visibleSteps(deviceAvailable = true)
    private val playSteps = C07SetupMachine.visibleSteps(deviceAvailable = false)

    @Test
    fun fullChannelWalksAllEightStepsInOrder() {
        assertEquals(
            listOf(
                C07SetupStep.WELCOME,
                C07SetupStep.MODELS,
                C07SetupStep.VOICE,
                C07SetupStep.FILES,
                C07SetupStep.NOTIFICATIONS,
                C07SetupStep.LINUX,
                C07SetupStep.DEVICE,
                C07SetupStep.DONE,
            ),
            fullSteps,
        )
    }

    @Test
    fun unwiredChannelOmitsOnlyTheDeviceStep() {
        // Play / unwired host: no device destination exists, so the step is
        // never offered; every other step stays in place.
        assertEquals(fullSteps - C07SetupStep.DEVICE, playSteps)
        assertFalse(playSteps.contains(C07SetupStep.DEVICE))
        assertTrue(playSteps.contains(C07SetupStep.LINUX))
    }

    @Test
    fun storedStepKeysStayStableAcrossVersions() {
        // Existing installs persist these exact keys; they must keep parsing
        // to the same steps after the wizard grew.
        assertEquals(C07SetupStep.WELCOME, C07SetupStep.fromKey("welcome"))
        assertEquals(C07SetupStep.MODELS, C07SetupStep.fromKey("models"))
        assertEquals(C07SetupStep.VOICE, C07SetupStep.fromKey("voice"))
        assertEquals(C07SetupStep.FILES, C07SetupStep.fromKey("files"))
        assertEquals(C07SetupStep.NOTIFICATIONS, C07SetupStep.fromKey("notifications"))
        assertEquals(C07SetupStep.DONE, C07SetupStep.fromKey("done"))
        assertEquals(C07SetupStep.LINUX, C07SetupStep.fromKey("linux"))
        assertEquals(C07SetupStep.DEVICE, C07SetupStep.fromKey("device"))
        // Unknown/corrupt keys fall back to the start, never a crash.
        assertEquals(C07SetupStep.WELCOME, C07SetupStep.fromKey("bogus"))
        assertEquals(C07SetupStep.WELCOME, C07SetupStep.fromKey(null))
    }

    @Test
    fun hiddenStoredDeviceStepNormalizesToPreviousVisibleStep() {
        // A user who left the guide on the device step, then runs a build
        // where the phone section is not registered, lands on Linux — never
        // on a fabricated destination and never stuck.
        assertEquals(
            C07SetupStep.LINUX,
            C07SetupMachine.normalize(C07SetupStep.DEVICE, playSteps),
        )
        assertEquals(
            C07SetupStep.DEVICE,
            C07SetupMachine.normalize(C07SetupStep.DEVICE, fullSteps),
        )
        // A visible step is never rewritten.
        for (step in fullSteps) {
            assertEquals(step, C07SetupMachine.normalize(step, fullSteps))
        }
    }

    @Test
    fun navigationSkipsHiddenDeviceStepBothDirections() {
        var state = C07SetupState(step = C07SetupStep.NOTIFICATIONS, seen = true)
        state = C07SetupMachine.next(state, playSteps, now)
        assertEquals(C07SetupStep.LINUX, state.step)
        state = C07SetupMachine.next(state, playSteps, now)
        assertEquals(C07SetupStep.DONE, state.step)
        state = C07SetupMachine.previous(state, playSteps, now)
        assertEquals(C07SetupStep.LINUX, state.step)
        state = C07SetupMachine.previous(state, playSteps, now)
        assertEquals(C07SetupStep.NOTIFICATIONS, state.step)
    }

    @Test
    fun navigationFromHiddenStoredStepResumesOnVisibleList() {
        // Stored device step + unwired build: Next continues at Done and Back
        // lands on Linux (the visible step right before it) instead of
        // dead-ending on an invisible page.
        val stored = C07SetupState(step = C07SetupStep.DEVICE, seen = true)
        assertEquals(
            C07SetupStep.DONE,
            C07SetupMachine.next(stored, playSteps, now).step,
        )
        assertEquals(
            C07SetupStep.LINUX,
            C07SetupMachine.previous(stored, playSteps, now).step,
        )
    }

    @Test
    fun boundariesStayPutAndFirstStepCannotGoBack() {
        val first = C07SetupState(step = C07SetupStep.WELCOME, seen = true)
        assertEquals(C07SetupStep.WELCOME, C07SetupMachine.previous(first, fullSteps, now).step)
        val last = C07SetupState(step = C07SetupStep.DONE, seen = true)
        assertEquals(C07SetupStep.DONE, C07SetupMachine.next(last, fullSteps, now).step)
    }

    @Test
    fun navigationNeverClearsSkipOrFinishFlags() {
        val skipped = C07SetupState(
            step = C07SetupStep.FILES,
            seen = true,
            skipped = true,
        )
        val moved = C07SetupMachine.next(skipped, fullSteps, now)
        assertTrue(moved.skipped)
        assertFalse(moved.finished)
        val finished = C07SetupState(
            step = C07SetupStep.DONE,
            seen = true,
            finished = true,
        )
        val back = C07SetupMachine.previous(finished, fullSteps, now)
        assertTrue(back.finished)
        assertFalse(back.skipped)
    }

    @Test
    fun fullWalkthroughReachesDoneAndMarksSeenOnly() {
        var state = C07SetupState()
        repeat(fullSteps.size - 1) {
            state = C07SetupMachine.next(state, fullSteps, now)
        }
        assertEquals(C07SetupStep.DONE, state.step)
        assertTrue(state.seen)
        assertFalse(state.finished)
        assertFalse(state.skipped)
        val done = C07SetupMachine.finish(state, now + 1)
        assertTrue(done.finished)
        // Finishing never rewrites the position or invents configuration.
        assertEquals(C07SetupStep.DONE, done.step)
        val text = done.toString()
        assertFalse(text.contains("provider="))
        assertFalse(text.contains("granted"))
        assertFalse(text.contains("configured"))
    }
}
