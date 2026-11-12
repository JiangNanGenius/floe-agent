// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `system.access.status`/descriptor guidance must separate potential capture
 * support from the CURRENT live consent of one task/run, and give the existing
 * recovery without enabling anything or implying a permission bypass.
 */
class PhoneControlScreenshotGuidanceTest {
    private fun readiness(
        support: PhoneControlScreenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
        scope: Boolean = true,
        whole: Boolean = false,
        service: Boolean = true,
        armed: Boolean = true,
        targets: Boolean = true,
        stopped: Boolean = false,
        paused: Boolean = false,
        epoch: Boolean = true,
        adbDisplayOnly: Boolean = false,
    ) = PhoneControlScreenshotGuidance.Readiness(
        support = support,
        screenScopeGranted = scope,
        wholeScreenConsent = whole,
        serviceUsable = service,
        taskArmed = armed,
        targetAppsSelected = targets,
        userStopped = stopped,
        taskPaused = paused,
        runtimeEpochReady = epoch,
        adbDisplayOnly = adbDisplayOnly,
    )

    @Test
    fun supportIsPotentialAndDependsOnlyOnThePlatformLevel() {
        assertEquals(PhoneControlScreenshotSupport.NONE,
            PhoneControlScreenshotGuidance.supportForSdk(29))
        assertEquals(PhoneControlScreenshotSupport.DISPLAY,
            PhoneControlScreenshotGuidance.supportForSdk(30))
        assertEquals(PhoneControlScreenshotSupport.DISPLAY,
            PhoneControlScreenshotGuidance.supportForSdk(33))
        assertEquals(PhoneControlScreenshotSupport.WINDOW,
            PhoneControlScreenshotGuidance.supportForSdk(34))
        // The public disclosure helper must never drift from the internal
        // policy gate that actually decides dispatch support.
        for (sdk in 28..40) {
            assertEquals(
                PhoneControlPolicy.screenshotSupport(sdk),
                PhoneControlScreenshotGuidance.supportForSdk(sdk),
            )
        }
    }

    @Test
    fun api33DisplayCaptureNeedsScopeAndWholeScreenButNeverClaimsWindowSupport() {
        val blocked = readiness(support = PhoneControlScreenshotSupport.DISPLAY, whole = false)
        assertFalse(blocked.windowCaptureReady)
        assertFalse(blocked.displayCaptureReady)
        assertTrue(blocked.recovery().contains("whole-screen"))

        val ready = readiness(
            support = PhoneControlScreenshotSupport.DISPLAY,
            whole = true,
        )
        assertTrue(ready.displayCaptureReady)
        assertFalse(ready.windowCaptureReady)
        assertTrue(ready.recovery().contains("without observationId"))
        assertFalse(ready.recovery().contains("window capture, or omit"))
    }

    @Test
    fun adbBackendNeverClaimsWindowCaptureOnApi34() {
        val ready = readiness(
            support = PhoneControlScreenshotSupport.WINDOW,
            whole = true,
            adbDisplayOnly = true,
        )
        assertFalse(ready.windowCaptureReady)
        assertTrue(ready.displayCaptureReady)
        assertTrue(ready.recovery().contains("display only"))
        assertTrue(ready.modeLabel.contains("display_only"))
    }

    @Test
    fun api34WindowCaptureIsReadyWithScopeOnlyAndDisplayStillNeedsWholeScreen() {
        val windowOnly = readiness(
            support = PhoneControlScreenshotSupport.WINDOW,
            whole = false,
        )
        assertTrue(windowOnly.windowCaptureReady)
        assertFalse(windowOnly.displayCaptureReady)
        assertTrue(windowOnly.anyCaptureReady)
        assertTrue(windowOnly.recovery().contains("Window capture is ready"))
        assertTrue(windowOnly.recovery().contains("whole-screen"))

        val both = readiness(support = PhoneControlScreenshotSupport.WINDOW, whole = true)
        assertTrue(both.displayCaptureReady)
        assertTrue(both.windowCaptureReady)
        assertTrue(both.recovery().contains("Ready"))
    }

    @Test
    fun screenScopeOffNamesTheExistingSettingsChoiceAndNoPlayOrCredentialBypass() {
        val off = readiness(scope = false, whole = true)
        assertFalse(off.displayCaptureReady)
        assertFalse(off.windowCaptureReady)
        assertFalse(off.anyCaptureReady)
        val text = off.recovery()
        assertTrue(text.contains("Screen content"))
        assertTrue(text.contains("This task"))
        assertFalse(text.contains("Play permission"))
        assertFalse(text.contains("password bypass"))
        assertTrue(off.consentLine().contains("screenScope=off"))
        // An OFF task scope never hides/reports away an independently saved
        // whole-screen choice (primary keeps that switch visible for revoke).
        assertTrue(off.consentLine().contains("wholeScreenConsent=true"))
    }

    @Test
    fun eachUnmetLiveRequirementGetsItsOwnActionableRecovery() {
        assertTrue(readiness(service = false).recovery().contains("accessibility service"))
        assertTrue(readiness(epoch = false).recovery().contains("runtime is not ready"))
        assertTrue(readiness(stopped = true).recovery().contains("Allow device control"))
        assertTrue(readiness(paused = true).recovery().contains("Resume device control"))
        assertTrue(readiness(targets = false).recovery().contains("Select at least one target app"))
        assertTrue(readiness(armed = false).recovery().contains("Allow device control"))
        assertTrue(
            readiness(support = PhoneControlScreenshotSupport.NONE)
                .recovery().contains("no supported capture"),
        )
    }

    @Test
    fun targetPackageRefusalIsPageScopedAndDoesNotRewriteSelectedApps() {
        val text = PhoneControlScreenshotGuidance.targetPackageRecovery()
        assertTrue(text.contains("selected apps are unchanged"))
        assertTrue(text.contains("already-selected app"))
        assertTrue(text.contains("Applies only to this page"))
        assertFalse(text.contains("revoked"))
    }

    @Test
    fun readinessNeverProjectsSuccessForAnUnarmedOrUnscopedRun() {
        for (support in PhoneControlScreenshotSupport.values()) {
            val unarmed = readiness(support = support, armed = false, scope = true, whole = true)
            assertFalse(unarmed.displayCaptureReady)
            assertFalse(unarmed.windowCaptureReady)
            val unscoped = readiness(support = support, armed = true, scope = false, whole = true)
            assertFalse(unscoped.displayCaptureReady)
            assertFalse(unscoped.windowCaptureReady)
        }
    }
}
