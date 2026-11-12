// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactHandoffPolicyTest {
    private val own = "com.floe.agent.full"
    private val calendar = "com.samsung.android.calendar"

    private fun handler(
        packageName: String,
        className: String = "ImportActivity",
        label: String = packageName,
        priority: Int = 0,
        mime: String = "text/calendar",
    ) = ArtifactHandoffHandler(packageName, className, label, priority, mime)

    @Test
    fun closedMimeMapCoversDemoMediaAndCalendarImport() {
        assertEquals(listOf("video/mp4"), ArtifactHandoffPolicy.mimeFor("预告.MP4")!!.all)
        assertEquals(listOf("image/jpeg"), ArtifactHandoffPolicy.mimeFor("poster.jpeg")!!.all)
        assertTrue(ArtifactHandoffPolicy.mimeFor("event.ics")!!.all.contains("text/calendar"))
        assertTrue(ArtifactHandoffPolicy.mimeFor("event.ics")!!.all.contains("text/x-vcalendar"))
        assertNull(ArtifactHandoffPolicy.mimeFor("archive.zip"))
        assertNull(ArtifactHandoffPolicy.mimeFor("no-extension"))
    }

    @Test
    fun sealedOutputMimeMustAgreeWithTheSealedName() {
        assertTrue(ArtifactHandoffPolicy.mimeMatchesExtension("clip.mp4", "video/mp4"))
        assertTrue(ArtifactHandoffPolicy.mimeMatchesExtension("event.ics", "text/calendar"))
        assertFalse(ArtifactHandoffPolicy.mimeMatchesExtension("clip.mp4", "application/octet-stream"))
        assertFalse(ArtifactHandoffPolicy.mimeMatchesExtension("image.png", "image/jpeg"))
        // The fallback handler family still agrees with the same .ics name.
        assertTrue(ArtifactHandoffPolicy.mimeMatchesExtension("event.ics", "text/x-vcalendar"))
    }

    @Test
    fun displayNamesAreInertSingleComponents() {
        assertEquals("海报.png", ArtifactHandoffPolicy.displayNameFor("deliverables/海报.png"))
        assertNull(ArtifactHandoffPolicy.displayNameFor("deliverables/.hidden"))
        assertNull(ArtifactHandoffPolicy.displayNameFor("bad\\name.png"))
        assertNull(ArtifactHandoffPolicy.displayNameFor("tab\tname.png"))
        assertNull(ArtifactHandoffPolicy.displayNameFor("dir/"))
        assertNull(ArtifactHandoffPolicy.displayNameFor("x".repeat(161)))
    }

    @Test
    fun pathAndSourceValidationMatchTheWireContract() {
        assertTrue(ArtifactHandoffPolicy.validSource("workspace", "a/b.mp4", null))
        assertFalse(ArtifactHandoffPolicy.validSource("workspace", "../b.mp4", null))
        assertFalse(ArtifactHandoffPolicy.validSource("workspace", "/abs/b.mp4", null))
        assertFalse(ArtifactHandoffPolicy.validSource("workspace", "b.mp4",
            "a".repeat(64)))
        assertTrue(ArtifactHandoffPolicy.validSource("output", null, "a".repeat(64)))
        assertFalse(ArtifactHandoffPolicy.validSource("output", "b.mp4", "a".repeat(64)))
        assertFalse(ArtifactHandoffPolicy.validSource("output", null, "A".repeat(64)))
        assertFalse(ArtifactHandoffPolicy.validSource("other", null, null))
    }

    @Test
    fun targetPackageAndComponentCannotDisagree() {
        assertTrue(ArtifactHandoffPolicy.validTargetFields(calendar, "$calendar/ImportActivity"))
        assertTrue(ArtifactHandoffPolicy.validTargetFields(null, "$calendar/ImportActivity"))
        assertFalse(ArtifactHandoffPolicy.validTargetFields("com.other", "$calendar/ImportActivity"))
        assertFalse(ArtifactHandoffPolicy.validTargetFields("bad/package", null))
        assertFalse(ArtifactHandoffPolicy.validTargetFields(calendar, "packageOnly"))
        assertFalse(ArtifactHandoffPolicy.validTargetFields(calendar, "$calendar/"))
    }

    @Test
    fun onlyUserSelectedNonResolverHandlersArePermitted() {
        val candidates = listOf(
            handler(calendar, "Import", priority = 20),
            handler(calendar, "Import", priority = 10), // duplicate component
            handler("com.sec.android.gallery3d", "View", mime = "video/mp4"),
            handler("android", "ResolverActivity"),
            handler("com.android.internal.app", "ChooserActivity"),
            handler(own, "Internal"),
            handler("com.unselected.viewer", "View"),
        )
        val permitted = ArtifactHandoffPolicy.permittedHandlers(
            candidates,
            allowedPackages = setOf(calendar, "com.sec.android.gallery3d", "android",
                "com.android.internal.app", own),
            ownPackage = own,
        )
        assertEquals(listOf(calendar, "com.sec.android.gallery3d"),
            permitted.map { it.packageName })
        assertEquals(1, permitted.count { it.packageName == calendar })
        // Priority ordering is deterministic inside the permitted set.
        assertEquals(20, permitted.first().priority)
    }

    @Test
    fun exactTargetSelectionDoesNotFallBackToAnotherPackage() {
        val permitted = listOf(
            handler(calendar, "ImportActivity", priority = 20),
            handler("com.google.android.calendar", "ImportActivity", priority = 10),
        )
        val exact = ArtifactHandoffPolicy.selectTarget(permitted, calendar,
            "$calendar/ImportActivity")
        assertTrue(exact is ArtifactHandoffTargetChoice.Selected)
        assertEquals(calendar, (exact as ArtifactHandoffTargetChoice.Selected).handler.packageName)

        val wrong = ArtifactHandoffPolicy.selectTarget(permitted, calendar,
            "$calendar/OtherActivity")
        assertTrue(wrong is ArtifactHandoffTargetChoice.Refused)
        assertEquals("targetNotPermitted", (wrong as ArtifactHandoffTargetChoice.Refused).code)
    }

    @Test
    fun ambiguousPackageOrHandlerListRequiresAnExplicitChoice() {
        val permitted = listOf(
            handler(calendar, "ImportActivity", priority = 20),
            handler(calendar, "SecondActivity", priority = 10),
        )
        val byPackage = ArtifactHandoffPolicy.selectTarget(permitted, calendar, null)
        assertTrue(byPackage is ArtifactHandoffTargetChoice.Ambiguous)
        assertEquals(2, (byPackage as ArtifactHandoffTargetChoice.Ambiguous).handlers.size)

        val automatic = ArtifactHandoffPolicy.selectTarget(permitted, null, null)
        assertTrue(automatic is ArtifactHandoffTargetChoice.Ambiguous)
        assertTrue(ArtifactHandoffPolicy.selectTarget(emptyList(), null, null)
            is ArtifactHandoffTargetChoice.None)
    }

    @Test
    fun onePermittedHandlerCanLaunchWithoutAnOperatorChooser() {
        val only = handler(calendar)
        val selected = ArtifactHandoffPolicy.selectTarget(listOf(only), null, null)
        assertTrue(selected is ArtifactHandoffTargetChoice.Selected)
        assertEquals(only, (selected as ArtifactHandoffTargetChoice.Selected).handler)
    }

    @Test
    fun launchIsReadOnlyAndHasNoWriteBit() {
        val launch = ArtifactHandoffPolicy.launchFor(handler(calendar), "event.ics")
        assertEquals("android.intent.action.VIEW", launch.action)
        assertEquals(calendar, launch.packageName)
        assertTrue(launch.readPermission)
        assertFalse(launch.writePermission)
        assertEquals(ArtifactHandoffPolicy.FLAG_GRANT_READ_URI_PERMISSION,
            ArtifactHandoffPolicy.grantFlags(launch))
        assertTrue(ArtifactHandoffPolicy.grantFlags(launch) and
            ArtifactHandoffPolicy.FLAG_GRANT_WRITE_URI_PERMISSION == 0)
    }

    @Test
    fun launchIdentityIsBoundToTheDurableRecord() {
        val id = UUID.randomUUID().toString()
        val owner = ExternalEditOwner(UUID.randomUUID().toString(), UUID.randomUUID().toString())
        val record = ArtifactHandoffRecord(
            id = id, owner = owner, source = "workspace", logicalPath = "deliverables/clip.mp4",
            runID = null, outputID = null, displayName = "clip.mp4", mimeType = "video/mp4",
            sha256 = "1".repeat(64), bytes = 10, targetPackage = "com.sec.android.gallery3d",
            targetComponent = "com.sec.android.gallery3d/View", phase = ArtifactHandoffPhase.STAGED,
            launched = false, toolLaunchKey = "run:call", toolLaunchConfirmed = false,
        )
        assertTrue(ArtifactHandoffPolicy.sourceMatches(record, "workspace",
            "deliverables/clip.mp4", null))
        assertFalse(ArtifactHandoffPolicy.sourceMatches(record, "workspace",
            "deliverables/other.mp4", null))
        assertFalse(ArtifactHandoffPolicy.sourceMatches(record, "output", null,
            "2".repeat(64)))
        // A prepared-but-never-attempted record is retryable; an unconfirmed
        // OS launch is not; an accepted launch returns its existing session.
        assertTrue(ArtifactHandoffPolicy.canIssueLaunch(record))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(record.copy(
            phase = ArtifactHandoffPhase.PAUSED,
            launchAttempt = ArtifactHandoffLaunchAttempt.UNKNOWN,
            errorCode = "launchUnconfirmed")))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(record.copy(
            phase = ArtifactHandoffPhase.LAUNCHED, launched = true,
            toolLaunchConfirmed = true,
            launchAttempt = ArtifactHandoffLaunchAttempt.ACCEPTED)))
        assertTrue(ArtifactHandoffPolicy.canIssueLaunch(record.copy(
            phase = ArtifactHandoffPhase.PAUSED,
            launchAttempt = ArtifactHandoffLaunchAttempt.REJECTED,
            errorCode = "deviceArmRequired")))
        assertTrue(ArtifactHandoffPolicy.canResume(record))
        assertFalse(ArtifactHandoffPolicy.canResume(
            record.copy(phase = ArtifactHandoffPhase.FINISHED)))
    }
}
