// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlPolicyTest {
    private val owner = testOwner()

    /** Every App/runtime applicationId currently shipped by the project. */
    private val floeFamily = listOf(
        "com.floe.agent",
        "com.floe.agent.dev",
        "com.floe.agent.full",
        "com.floe.agent.full.dev",
        "com.floe.agent.runtime",
        "com.floe.agent.runtime.dev",
        "com.floe.agent.runtime.full",
        "com.floe.agent.runtime.full.dev",
    )

    private fun nodeRecord(
        password: Boolean = false,
        redacted: Boolean = false,
    ) = PhoneControlNodeRecord(
        ref = "n0",
        path = listOf(0),
        className = "android.widget.EditText",
        packageName = "com.example.app",
        viewId = "com.example.app:id/field",
        bounds = PhoneControlBounds(0, 0, 100, 50),
        password = password,
        redacted = redacted,
        clickable = false,
        editable = true,
        scrollable = false,
    )

    @Test
    fun ownerEpochAndGenerationMustMatchTheLiveGrant() {
        val principal = testPrincipal()
        assertNull(PhoneControlPolicy.grantDenial(principal, testGrant()))
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_STALE,
            PhoneControlPolicy.grantDenial(
                principal,
                testGrant(owner = testOwner(run = "77777777-7777-7777-7777-777777777777")),
            ),
        )
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_STALE,
            PhoneControlPolicy.grantDenial(principal, testGrant(epoch = 8)),
        )
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_STALE,
            PhoneControlPolicy.grantDenial(principal, testGrant(generation = 4)),
        )
    }

    @Test
    fun approvalGrantIdentityMustNotBeCachedFromADifferentGrant() {
        val grantID = UUID.fromString("88888888-8888-8888-8888-888888888888")
        val other = UUID.fromString("99999999-9999-9999-9999-999999999999")
        val principal = testPrincipal(grantID = grantID)
        assertNull(PhoneControlPolicy.grantDenial(principal, testGrant(grantID = grantID)))
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_STALE,
            PhoneControlPolicy.grantDenial(principal, testGrant(grantID = other)),
        )
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_STALE,
            PhoneControlPolicy.grantDenial(principal, testGrant(grantID = null)),
        )
    }

    @Test
    fun liveGrantCanOnlyNarrowTheRequestedScope() {
        val principal = testPrincipal(packages = setOf("com.example.app", "com.example.other"))
        val grant = testGrant(packages = setOf("com.example.app", "com.example.forbidden"))
        assertEquals(
            setOf("com.example.app"),
            PhoneControlPolicy.effectivePackages(principal, grant),
        )
    }

    @Test
    fun targetPackageOutsideTheEffectiveScopeIsDenied() {
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            PhoneControlPolicy.nodeTargetDenial(
                nodePackage = "com.evil.app",
                observationPackage = "com.example.app",
                effectivePackages = setOf("com.example.app"),
            ),
        )
        assertNull(
            PhoneControlPolicy.nodeTargetDenial(
                nodePackage = null,
                observationPackage = "com.example.app",
                effectivePackages = setOf("com.example.app"),
            ),
        )
    }

    @Test
    fun observationAllowsTheLauncherOnlyWithGlobalNavigationGrant() {
        val effective = setOf("com.example.app")
        assertNull(
            PhoneControlPolicy.observationDenial(
                "com.example.app", effective, "com.android.launcher3", true,
            ),
        )
        assertNull(
            PhoneControlPolicy.observationDenial(
                "com.android.launcher3", effective, "com.android.launcher3", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            PhoneControlPolicy.observationDenial(
                "com.android.launcher3", effective, "com.android.launcher3", false,
            ),
        )
        assertNull(
            PhoneControlPolicy.observationDenial(
                "com.android.systemui", effective, "com.android.launcher3", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            PhoneControlPolicy.observationDenial(
                "com.other.app", effective, "com.android.launcher3", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            PhoneControlPolicy.observationDenial(null, effective, null, true),
        )
    }

    @Test
    fun launchRequiresAnAuthorizedNonProtectedPackage() {
        assertNull(
            PhoneControlPolicy.launchDenial("com.example.app", setOf("com.example.app")),
        )
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            PhoneControlPolicy.launchDenial("com.example.other", setOf("com.example.app")),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.launchDenial(
                "com.android.systemui",
                setOf("com.android.systemui"),
            ),
        )
        assertEquals(
            PhoneControlDenial.INVALID_ARGUMENT,
            PhoneControlPolicy.launchDenial("bad package", setOf("bad package")),
        )
    }

    @Test
    fun everyShippedFloeAppAndRuntimeIdIsLaunchAndWindowProtected() {
        for (packageName in floeFamily) {
            assertTrue(packageName, PhoneControlPolicy.isFloePackage(packageName))
            assertTrue(packageName, PhoneControlPolicy.isProtectedPackage(packageName))
            assertTrue(
                packageName,
                PhoneControlPolicy.isProtectedWindow(
                    packageName,
                    "com.floe.agent.MainActivity",
                    1,
                    false,
                    false,
                ),
            )
            assertEquals(
                packageName,
                PhoneControlDenial.PROTECTED_WINDOW,
                PhoneControlPolicy.nodeActionDenial(
                    packageName,
                    "com.floe.agent.MainActivity",
                    1,
                    false,
                    false,
                ),
            )
            assertEquals(
                packageName,
                PhoneControlDenial.PROTECTED_WINDOW,
                PhoneControlPolicy.launchDenial(packageName, setOf(packageName)),
            )
        }
        // Separator-aware: an unrelated package sharing the text prefix is not
        // swept into the Floe ceiling.
        assertFalse(PhoneControlPolicy.isFloePackage("com.floe.agentic.app"))
        assertFalse(PhoneControlPolicy.isProtectedPackage("com.floe.agentic.app"))
        assertNull(
            PhoneControlPolicy.launchDenial(
                "com.floe.agentic.app",
                setOf("com.floe.agentic.app"),
            ),
        )
    }

    @Test
    fun floeStaysDeniedEvenWhenAHostGrantMistakenlyListsIt() {
        val self = "com.floe.agent.full.dev"
        val unrelated = "com.example.app"
        val erroneousScope = setOf(self, unrelated)
        // Phone20 correction: the privacy invariant is "no Floe content",
        // not "no safe navigation". A full tree stays denied even when global
        // navigation is granted; exactly the zero-node metadata observation is
        // the one narrow exception, and only with global navigation.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.observationDenial(
                self,
                erroneousScope,
                "com.android.launcher3",
                true,
            ),
        )
        assertNull(
            PhoneControlPolicy.observationDenial(
                self,
                erroneousScope,
                "com.android.launcher3",
                true,
                navigationMetadataOnly = true,
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.observationDenial(
                self,
                erroneousScope,
                "com.android.launcher3",
                false,
                navigationMetadataOnly = true,
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.nodeTargetDenial(self, self, erroneousScope),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.launchDenial(self, erroneousScope),
        )
        assertTrue(
            PhoneControlPolicy.isProtectedWindow(
                self,
                "com.floe.agent.MainActivity",
                1,
                true,
                false,
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.screenshotDenial(
                allowScreenshot = true,
                keyguardLocked = false,
                protectedWindow = PhoneControlPolicy.isProtectedWindow(
                    self,
                    "com.floe.agent.MainActivity",
                    1,
                    false,
                    false,
                ),
                hasPassword = false,
            ),
        )
        // Only the forbidden self target is pruned from the live scope; the
        // unrelated user selection and every other setting remain usable.
        assertEquals(
            setOf(unrelated),
            PhoneControlPolicy.effectivePackages(
                testPrincipal(packages = erroneousScope),
                testGrant(packages = erroneousScope),
            ),
        )
        assertNull(
            PhoneControlPolicy.observationDenial(
                unrelated,
                erroneousScope,
                "com.android.launcher3",
                true,
            ),
        )
        assertNull(PhoneControlPolicy.nodeTargetDenial(unrelated, unrelated, erroneousScope))
        assertNull(PhoneControlPolicy.launchDenial(unrelated, erroneousScope))
        assertFalse(
            PhoneControlPolicy.isProtectedWindow(
                unrelated,
                "com.example.Main",
                1,
                false,
                false,
            ),
        )
        assertNull(PhoneControlPolicy.screenshotDenial(true, false, false, false))
    }

    @Test
    fun wholeDisplayCaptureNeverIncludesFloeWindows() {
        val display = PhoneControlBounds(0, 0, 1080, 2400)
        val unrelatedWindow = PhoneControlDisplayWindow(
            windowId = 10,
            packageName = "com.example.app",
            windowType = 1,
            bounds = PhoneControlBounds(0, 80, 1080, 2320),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            displayCaptureDenial(
                windows = listOf(
                    PhoneControlDisplayWindow(
                        windowId = 11,
                        packageName = "com.floe.agent.runtime.full",
                        windowType = 1,
                        bounds = PhoneControlBounds(0, 80, 1080, 2320),
                    ),
                ),
                observedWindowId = 11,
                observedPackage = "com.floe.agent.runtime.full",
                homePackage = "com.android.launcher3",
                displayBounds = display,
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            displayCaptureDenial(
                windows = listOf(
                    unrelatedWindow,
                    PhoneControlDisplayWindow(
                        windowId = 12,
                        packageName = "com.floe.agent.full",
                        windowType = 1,
                        bounds = PhoneControlBounds(0, 80, 540, 2320),
                    ),
                ),
                observedWindowId = 10,
                observedPackage = "com.example.app",
                homePackage = "com.android.launcher3",
                displayBounds = display,
            ),
        )
        assertNull(
            displayCaptureDenial(
                windows = listOf(unrelatedWindow),
                observedWindowId = 10,
                observedPackage = "com.example.app",
                homePackage = "com.android.launcher3",
                displayBounds = display,
            ),
        )
    }

    @Test
    fun passwordAndRedactedFieldsRefuseSetText() {
        assertEquals(
            PhoneControlDenial.SENSITIVE_FIELD,
            PhoneControlPolicy.fieldActionDenial(nodeRecord(password = true)),
        )
        assertEquals(
            PhoneControlDenial.SENSITIVE_FIELD,
            PhoneControlPolicy.fieldActionDenial(nodeRecord(redacted = true)),
        )
        assertNull(PhoneControlPolicy.fieldActionDenial(nodeRecord()))
    }

    @Test
    fun protectedWindowsCoverSystemUiLockAndCredentialScreens() {
        assertTrue(
            PhoneControlPolicy.isProtectedWindow(
                "com.example.app", "com.example.Main", 1, false, keyguardLocked = true,
            ),
        )
        assertTrue(
            PhoneControlPolicy.isProtectedWindow(
                "com.android.systemui", "com.android.systemui.SomeWindow", 3, false, false,
            ),
        )
        assertTrue(
            PhoneControlPolicy.isProtectedWindow(
                "com.android.permissioncontroller",
                "com.android.permissioncontroller.permission.ui.GrantPermissionsActivity",
                1,
                false,
                false,
            ),
        )
        assertTrue(
            PhoneControlPolicy.isProtectedWindow(
                "com.android.settings",
                "com.android.settings.ConfirmLockPassword",
                1,
                false,
                false,
            ),
        )
        assertTrue(
            PhoneControlPolicy.isProtectedWindow(
                "android", "android.app.AlertDialog", 3, true, false,
            ),
        )
        assertFalse(
            PhoneControlPolicy.isProtectedWindow(
                "com.example.bank", "com.example.bank.LoginActivity", 1, true, false,
            ),
        )
        assertFalse(
            PhoneControlPolicy.isProtectedWindow(
                "com.example.app", "com.example.Main", 1, false, false,
            ),
        )
    }

    @Test
    fun screenshotGateHonoursGrantLockPrivacyAndApiGuards() {
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_DENIED,
            PhoneControlPolicy.screenshotDenial(false, false, false, false),
        )
        assertEquals(
            PhoneControlDenial.DEVICE_LOCKED,
            PhoneControlPolicy.screenshotDenial(true, true, false, false),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.screenshotDenial(true, false, true, false),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.screenshotDenial(true, false, false, true),
        )
        assertNull(PhoneControlPolicy.screenshotDenial(true, false, false, false))
        assertEquals(
            PhoneControlScreenshotSupport.NONE,
            PhoneControlPolicy.screenshotSupport(29),
        )
        assertEquals(
            PhoneControlScreenshotSupport.DISPLAY,
            PhoneControlPolicy.screenshotSupport(30),
        )
        assertEquals(
            PhoneControlScreenshotSupport.DISPLAY,
            PhoneControlPolicy.screenshotSupport(33),
        )
        assertEquals(
            PhoneControlScreenshotSupport.WINDOW,
            PhoneControlPolicy.screenshotSupport(34),
        )
    }

    @Test
    fun lockAndForegroundChecksAreExplicit() {
        assertTrue(PhoneControlPolicy.isDeviceLocked(interactive = false, keyguardLocked = false))
        assertTrue(PhoneControlPolicy.isDeviceLocked(interactive = true, keyguardLocked = true))
        assertFalse(PhoneControlPolicy.isDeviceLocked(interactive = true, keyguardLocked = false))
        assertTrue(
            PhoneControlPolicy.screenChanged(
                1L, "com.example.app", 1, 2L, "com.example.app", 1,
            ),
        )
        assertTrue(
            PhoneControlPolicy.screenChanged(
                1L, "com.example.app", 1, 1L, "com.example.other", 1,
            ),
        )
        assertFalse(
            PhoneControlPolicy.screenChanged(
                1L, "com.example.app", 1, 1L, "com.example.app", 1,
            ),
        )
    }

    @Test
    fun principalValidationRejectsControlCharactersAndOversizedIds() {
        assertEquals(
            PhoneControlDenial.INVALID_ARGUMENT,
            PhoneControlPolicy.principalDenial(
                testPrincipal(packages = setOf("com.example.app\n")),
            ),
        )
        assertEquals(
            PhoneControlDenial.INVALID_ARGUMENT,
            PhoneControlPolicy.principalDenial(
                testPrincipal(callID = "x".repeat(201)),
            ),
        )
        assertNull(PhoneControlPolicy.principalDenial(testPrincipal(callID = "call-1")))
    }


    @Test
    fun wholeDisplayCaptureAllowsOnlyTheObservedAppHomeAndSystemBars() {
        val display = PhoneControlBounds(0, 0, 1080, 2400)
        fun window(
            id: Int,
            packageName: String?,
            type: Int,
            bounds: PhoneControlBounds,
        ) = PhoneControlDisplayWindow(id, packageName, type, bounds)

        val safe = listOf(
            window(10, "com.example.app", 1, PhoneControlBounds(0, 80, 1080, 2320)),
            window(2, "com.android.systemui", 3, PhoneControlBounds(0, 0, 1080, 80)),
            window(3, "com.android.systemui", 3, PhoneControlBounds(0, 2320, 1080, 2400)),
            window(11, "com.example.app", 1, PhoneControlBounds(200, 800, 880, 1600)),
            window(12, "com.android.launcher3", 1, PhoneControlBounds(0, 80, 1080, 2320)),
            // Landscape side navigation bar.
            window(13, "com.android.systemui", 3, PhoneControlBounds(1032, 0, 1080, 2400)),
        )
        assertNull(
            displayCaptureDenial(
                safe, 10, "com.example.app", "com.android.launcher3", display,
            ),
        )

        val denied = listOf(
            // IME over the lower half.
            window(4, "com.google.android.inputmethod.latin", 2, PhoneControlBounds(0, 1400, 1080, 2400)),
            // Notification shade / full system overlay.
            window(5, "com.android.systemui", 3, PhoneControlBounds(0, 0, 1080, 2400)),
            // Foreign split-screen app.
            window(6, "com.other.app", 1, PhoneControlBounds(0, 80, 540, 2320)),
            // Heads-up notification/toast larger than the status bar.
            window(7, "com.android.systemui", 3, PhoneControlBounds(0, 0, 1080, 200)),
            // Unknown overlay package.
            window(8, null, 3, PhoneControlBounds(0, 0, 1080, 80)),
        )
        for (windowInfo in denied) {
            assertEquals(
                "window ${windowInfo.windowId} must make the display capture unscoped",
                PhoneControlDenial.PROTECTED_WINDOW,
                displayCaptureDenial(
                    listOf(
                        window(10, "com.example.app", 1, PhoneControlBounds(0, 80, 1080, 2320)),
                        windowInfo,
                    ),
                    10,
                    "com.example.app",
                    "com.android.launcher3",
                    display,
                ),
            )
        }
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            displayCaptureDenial(
                emptyList(), 10, "com.example.app", "com.android.launcher3",
                PhoneControlBounds(0, 0, 0, 0),
            ),
        )
    }

    @Test
    fun captureCompletionRejectsAChangedPageWindowOrPackage() {
        val stamp = PhoneControlCaptureStamp(
            fenceGeneration = 3,
            pageGeneration = 5,
            windowId = 10,
            packageName = "com.example.app",
        )
        assertNull(
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Open, 3, 5, 10, "com.example.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.WINDOW_CHANGED,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Open, 3, 5, 11, "com.example.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.FOREGROUND_CHANGED,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Open, 3, 5, 10, "com.other.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Open, 3, 5, 10, "com.example.app", false,
            ),
        )
        assertEquals(
            PhoneControlDenial.STOPPED,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Blocked(PhoneControlBlocker.STOPPED),
                3, 5, 10, "com.example.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.STALE_OBSERVATION,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.StalePage, 3, 5, 10, "com.example.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.FOREIGN_RUN,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.ForeignRun, 3, 5, 10, "com.example.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.STALE_OBSERVATION,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Open, 3, 6, 10, "com.example.app", true,
            ),
        )
        assertEquals(
            PhoneControlDenial.STALE_OBSERVATION,
            captureCompletionDenial(
                stamp, PhoneControlFence.Verdict.Open, 4, 5, 10, "com.example.app", true,
            ),
        )
    }

    @Test
    fun blockerMappingKeepsStopAndTakeoverDistinct() {
        assertEquals(
            PhoneControlDenial.STOPPED,
            PhoneControlPolicy.denialForBlocker(PhoneControlBlocker.STOPPED),
        )
        assertEquals(
            PhoneControlDenial.TAKEN_OVER,
            PhoneControlPolicy.denialForBlocker(PhoneControlBlocker.TAKEN_OVER),
        )
        assertEquals(
            PhoneControlDenial.DEVICE_LOCKED,
            PhoneControlPolicy.denialForBlocker(PhoneControlBlocker.LOCKED),
        )
    }
}
