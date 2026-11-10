// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source attribution for platform semantic interaction events
 * (TYPE_VIEW_SCROLLED / TYPE_VIEW_CLICKED).
 *
 * Regression for the Samsung API33 Full code105 case: an automatic unlock
 * succeeded and phone.observe returned the protected Floe navigation-only
 * page, then ~8.4s later a FRESH platform user event fenced the run
 * (OWNED_PHONE_USER_EVENT_FRESH, wake released, RELOCK_RESULT_USER_TAKEN_OVER)
 * with no intervening human input. Floe's own chat streams and autoscrolls
 * while that protected page stays visible, and both programmatic and user
 * dispatches emit these events, so package attribution — never event text —
 * is the only safe discriminator.
 *
 * Policy: an event stamped with Floe's own package is ordinary App UI and
 * must stay non-human; a genuine user touch on Floe's own Activity is
 * delivered by the trusted [com.floe.android.contracts.OwnAppUserPresence]
 * hook instead. External packages keep the conservative takeover path.
 */
class PhoneSemanticAttributionTest {

    private fun origin(
        packageName: String?,
        ownAppPackageName: String = "com.floe.agent.full",
    ): PhoneInteractionOrigin =
        PhoneControlPolicy.semanticInteractionOrigin(packageName, ownAppPackageName)

    @Test
    fun ownAppScrollIsNotHumanTakeoverEvidence() {
        // The actual failure shape: Floe's own window autoscrolls (chat
        // streaming) while a task owns the run after an automatic unlock.
        assertEquals(
            PhoneInteractionOrigin.OWN_APP_SEMANTIC,
            origin("com.floe.agent.full"),
        )
    }

    @Test
    fun actualHostPackageIsOwnAppAcrossBuildVariants() {
        // Compare against the actual trusted service host for each build.
        for (pkg in listOf(
            "com.floe.agent",
            "com.floe.agent.full",
            "com.floe.agent.dev",
            "com.floe.agent.play",
            "com.floe.agent.runtime",
            "com.floe.agent.runtime.full",
            "com.floe.agent.runtime.dev",
        )) {
            assertEquals("package=$pkg", PhoneInteractionOrigin.OWN_APP_SEMANTIC, origin(pkg, pkg))
        }
    }

    @Test
    fun siblingAndNestedPackagesWithoutTheHostHookStayExternal() {
        for (pkg in listOf("com.floe.agent", "com.floe.agent.play",
            "com.floe.agent.runtime.full", "com.floe.agent.full.other")) {
            assertEquals("package=$pkg", PhoneInteractionOrigin.EXTERNAL_SEMANTIC, origin(pkg))
        }
    }

    @Test
    fun missingTrustedHostNeverSuppressesSemanticInput() {
        assertEquals(PhoneInteractionOrigin.EXTERNAL_SEMANTIC, origin("com.floe.agent.full", ""))
    }

    @Test
    fun lookalikePackagesAreExternal() {
        // Separator-aware: a third-party package must keep the conservative
        // user-takeover path, never be swept into the App family.
        for (pkg in listOf("com.floe.agentic", "com.floe.agents", "com.floe.agentx")) {
            assertEquals("package=$pkg", PhoneInteractionOrigin.EXTERNAL_SEMANTIC, origin(pkg))
        }
    }

    @Test
    fun externalSemanticEventsStayHuman() {
        // Real user scroll/click inside an observed external app: unchanged
        // conservative takeover evidence.
        assertEquals(
            PhoneInteractionOrigin.EXTERNAL_SEMANTIC,
            origin("com.example.app"),
        )
        assertEquals(
            PhoneInteractionOrigin.EXTERNAL_SEMANTIC,
            origin("com.android.calculator2"),
        )
    }

    @Test
    fun unattributableSemanticEventsStayConservative() {
        // No package attribution must never silently become "own App": it
        // keeps the existing user-takeover path.
        assertEquals(PhoneInteractionOrigin.EXTERNAL_SEMANTIC, origin(null))
        assertEquals(PhoneInteractionOrigin.EXTERNAL_SEMANTIC, origin(""))
    }

    @Test
    fun ownDispatchedInputEchoChecksStaySeparate() {
        // The existing own-input echo attribution is untouched by the source
        // classifier: an echo inside the bounded window stays task input, a
        // fresh timestamp stays human, and the classifier never consults
        // event text or node contents.
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(10_000L)
        assertTrue(echo.isOwnEcho(10_500L))
        assertFalse(echo.isOwnEcho(12_000L))
    }
}
