// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused pure-JVM coverage for the phone20 correction: a task armed while
 * Floe itself is foreground can obtain a real fenced, zero-node metadata
 * observation and use it only for Back/Home or a Launch to an already
 * authorized non-Floe app. Floe trees, text, actions and screenshots stay
 * unavailable.
 */
class PhoneControlNavigationTest {
    private val self = "com.floe.agent.full"
    private val allowed = "com.example.app"
    private val home = "com.android.launcher3"

    private fun metadataObservation(): PhoneControlObservation =
        navigationOnlyCapture(
            owner = testOwner(),
            ticket = PhoneControlFence.Ticket(
                owner = testOwner(),
                fenceGeneration = 5,
                pageGeneration = 9,
            ),
            packageName = self,
            windowId = 42,
            windowType = 1,
            displayId = 0,
            capturedAtElapsedRealtimeMillis = 1_000,
            screenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
        ).observation

    @Test
    fun floeNavigationOnlyObservationRequiresGlobalNavigationAndZeroNodeMode() {
        val effective = setOf(allowed)
        assertNull(
            PhoneControlPolicy.observationDenial(
                self,
                effective,
                home,
                allowGlobalNavigation = true,
                navigationMetadataOnly = true,
            ),
        )
        // No global navigation means no observation at all.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.observationDenial(
                self,
                effective,
                home,
                allowGlobalNavigation = false,
                navigationMetadataOnly = true,
            ),
        )
        // A full Floe tree is never legal, even with global navigation.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.observationDenial(
                self,
                effective,
                home,
                allowGlobalNavigation = true,
                navigationMetadataOnly = false,
            ),
        )
        // The runtime sibling gets exactly the same narrow treatment.
        assertNull(
            PhoneControlPolicy.observationDenial(
                "com.floe.agent.runtime.full",
                effective,
                home,
                allowGlobalNavigation = true,
                navigationMetadataOnly = true,
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.observationDenial(
                "com.floe.agent.runtime.full",
                effective,
                home,
                allowGlobalNavigation = false,
                navigationMetadataOnly = true,
            ),
        )
    }

    @Test
    fun navigationOnlyObservationCannotAuthorizeNodesOrTheFloeApp() {
        val effective = PhoneControlPolicy.effectivePackages(
            testPrincipal(packages = setOf(self, allowed)),
            testGrant(packages = setOf(self, allowed)),
        )
        assertEquals(setOf(allowed), effective)

        // Only the existing global navigation actions and an already-allowed
        // launch may use a navigation-only record.
        assertNull(
            PhoneControlPolicy.navigationOnlyActionDenial(
                true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.Back,
            ),
        )
        assertNull(
            PhoneControlPolicy.navigationOnlyActionDenial(
                true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.Home,
            ),
        )
        assertNull(
            PhoneControlPolicy.navigationOnlyActionDenial(
                true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.Launch(allowed),
            ),
        )
        // A live grant that has since revoked global navigation cannot still
        // use the metadata record for any action.
        assertEquals(
            PhoneControlDenial.AUTHORIZATION_DENIED,
            PhoneControlPolicy.navigationOnlyActionDenial(
                true,
                allowGlobalNavigation = false,
                action = PhoneControlAction.Back,
            ),
        )
        for (action in listOf(
            PhoneControlAction.Click("n0"),
            PhoneControlAction.SetText("n0", "secret"),
            PhoneControlAction.Scroll("n0", PhoneControlScrollDirection.FORWARD),
            PhoneControlAction.Swipe("n0", PhoneControlSwipeDirection.UP),
        )) {
            assertEquals(
                action.wireName,
                PhoneControlDenial.PROTECTED_WINDOW,
                PhoneControlPolicy.navigationOnlyActionDenial(
                    navigationOnly = true,
                    allowGlobalNavigation = true,
                    action = action,
                ),
            )
        }
        // The own App/runtime target is refused by the existing launch gate,
        // and an unselected third-party target is not silently allowed.
        assertNull(PhoneControlPolicy.launchDenial(allowed, effective))
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.launchDenial(self, effective),
        )
        assertEquals(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            PhoneControlPolicy.launchDenial("com.other.app", effective),
        )
        // Ordinary observations keep their existing node action gating.
        assertNull(
            PhoneControlPolicy.navigationOnlyActionDenial(
                navigationOnly = false,
                allowGlobalNavigation = true,
                action = PhoneControlAction.Click("n0"),
            ),
        )
    }

    @Test
    fun navigationOnlyCaptureCarriesOnlyActualFencingMetadata() {
        val owner = testOwner()
        val ticket = PhoneControlFence.Ticket(owner, fenceGeneration = 5, pageGeneration = 9)
        val capture = navigationOnlyCapture(
            owner = owner,
            ticket = ticket,
            packageName = self,
            windowId = 42,
            windowType = 1,
            displayId = 0,
            capturedAtElapsedRealtimeMillis = 1_000,
            screenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
        )
        val observation = capture.observation
        // Real issued identity, real owner/ticket metadata; no invented IDs.
        UUID.fromString(observation.observationId)
        assertEquals(owner, observation.owner)
        assertEquals(5L, observation.fenceGeneration)
        assertEquals(9L, observation.pageGeneration)
        assertEquals(self, observation.packageName)
        assertEquals(42, observation.windowId)
        assertEquals(1, observation.windowType)
        assertEquals(0, observation.displayId)
        assertEquals(
            1_000L + PhoneControlLimits.OBSERVATION_TTL_MS,
            observation.expiresAtElapsedRealtimeMillis,
        )
        // Zero nodes and no private Floe UI fields at all.
        assertTrue(observation.navigationOnly)
        assertTrue(observation.sensitiveWindow)
        assertTrue(observation.nodes.isEmpty())
        assertTrue(capture.records.isEmpty())
        assertTrue(capture.protectedWindow)
        assertFalse(capture.hasSensitiveField)
        assertNull(observation.windowTitle)
        assertNull(observation.rootClassName)
        assertFalse(observation.truncated)
        assertFalse(observation.maxDepthReached)
        // The Agent-facing projection says navigation-only with no nodes.
        val json = JSONObject(PhoneControlJson.observation(observation))
        assertTrue(json.getBoolean("navigationOnly"))
        assertEquals(0, json.getJSONArray("nodes").length())
        assertEquals(0, json.getInt("nodeCount"))
        assertTrue(json.isNull("windowTitle"))
        assertTrue(json.isNull("rootClassName"))
        // A protected navigation-only record never authorizes a screenshot.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.screenshotDenial(
                allowScreenshot = true,
                keyguardLocked = false,
                protectedWindow = capture.protectedWindow,
                hasPassword = capture.hasSensitiveField,
            ),
        )
        // A different actual window identity yields a different fingerprint.
        val other = navigationOnlyCapture(
            owner = owner,
            ticket = ticket,
            packageName = self,
            windowId = 43,
            windowType = 1,
            displayId = 0,
            capturedAtElapsedRealtimeMillis = 1_000,
            screenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
        )
        assertTrue(capture.fingerprint != other.fingerprint)
    }

    @Test
    fun issuedNavigationOnlyRecordCanLeaveFloeForAnAllowedApp() {
        val principal = testPrincipal(packages = setOf(self, allowed))
        val grant = testGrant(packages = setOf(self, allowed), globalNavigation = true)
        assertNull(PhoneControlPolicy.grantDenial(principal, grant))
        val effective = PhoneControlPolicy.effectivePackages(principal, grant)
        val observation = metadataObservation()

        // Observe gate used by PhoneControlSession.observe.
        assertNull(
            PhoneControlPolicy.observationDenial(
                observation.packageName,
                effective,
                home,
                grant.allowGlobalNavigation,
                observation.navigationOnly,
            ),
        )
        // Perform gate used by PhoneControlSession.validateBeforeDispatch for
        // the three actions navigation-only may use.
        for (action in listOf(
            PhoneControlAction.Back,
            PhoneControlAction.Home,
            PhoneControlAction.Launch(allowed),
        )) {
            assertNull(
                PhoneControlPolicy.navigationOnlyActionDenial(
                    navigationOnly = true,
                    allowGlobalNavigation = true,
                    action = action,
                ),
            )
        }
        assertNull(PhoneControlPolicy.launchDenial(allowed, effective))
        // The same record cannot authorize own click/setText/swipe/text actions
        // or relaunching Floe itself.
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.navigationOnlyActionDenial(
                navigationOnly = true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.Click("n0"),
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.navigationOnlyActionDenial(
                navigationOnly = true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.SetText("n0", "secret"),
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.navigationOnlyActionDenial(
                navigationOnly = true,
                allowGlobalNavigation = true,
                action = PhoneControlAction.Swipe("n0", PhoneControlSwipeDirection.LEFT),
            ),
        )
        assertEquals(
            PhoneControlDenial.PROTECTED_WINDOW,
            PhoneControlPolicy.launchDenial(self, effective),
        )
    }
}
