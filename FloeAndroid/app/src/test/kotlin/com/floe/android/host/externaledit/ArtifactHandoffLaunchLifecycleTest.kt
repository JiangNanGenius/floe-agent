// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The handoff launch lifecycle is the difference between a safe retry and a
 * duplicated viewer/importer effect:
 *
 *  - a DEFINITE pre-dispatch refusal keeps the verified copy retryable;
 *  - an UNCONFIRMED OS launch may never be replayed under any call;
 *  - only an accepted platform start is reported launched;
 *  - foreground/background route choice never silently takes the screen from
 *    a different visible task or falls back to a chooser.
 */
class ArtifactHandoffLaunchLifecycleTest {
    private fun record(
        phase: ArtifactHandoffPhase = ArtifactHandoffPhase.STAGED,
        attempt: ArtifactHandoffLaunchAttempt = ArtifactHandoffLaunchAttempt.NONE,
        key: String? = "run:call",
        errorCode: String? = null,
    ): ArtifactHandoffRecord {
        val accepted = attempt == ArtifactHandoffLaunchAttempt.ACCEPTED
        return ArtifactHandoffRecord(
            id = UUID.randomUUID().toString(),
            owner = ExternalEditOwner(UUID.randomUUID().toString(), UUID.randomUUID().toString()),
            source = "workspace",
            logicalPath = "deliverables/clip.mp4",
            runID = null,
            outputID = null,
            displayName = "clip.mp4",
            mimeType = "video/mp4",
            sha256 = "a".repeat(64),
            bytes = 4096,
            targetPackage = "com.sec.android.gallery3d",
            targetComponent = "com.sec.android.gallery3d/View",
            phase = phase,
            launched = accepted,
            toolLaunchKey = key,
            toolLaunchConfirmed = accepted,
            launchAttempt = attempt,
            errorCode = errorCode,
        )
    }

    @Test
    fun definitePreDispatchRefusalRemainsRetryable() {
        val foregroundRequired = record(
            errorCode = "foregroundRequired")
        val phoneRequired = record(phase = ArtifactHandoffPhase.PAUSED,
            attempt = ArtifactHandoffLaunchAttempt.REJECTED,
            errorCode = "phoneArmRequired")
        val rejectedTarget = record(phase = ArtifactHandoffPhase.PAUSED,
            attempt = ArtifactHandoffLaunchAttempt.REJECTED,
            errorCode = "targetNotPermitted")

        for (row in listOf(foregroundRequired, phoneRequired, rejectedTarget)) {
            assertEquals(ArtifactHandoffLaunchDisposition.READY,
                ArtifactHandoffPolicy.launchDisposition(row))
            assertTrue(ArtifactHandoffPolicy.canIssueLaunch(row))
            assertFalse(row.launched)
            assertFalse(row.toolLaunchConfirmed)
        }
    }

    @Test
    fun unconfirmedOsLaunchIsNeverReplayed() {
        val unknown = record(phase = ArtifactHandoffPhase.PAUSED,
            attempt = ArtifactHandoffLaunchAttempt.UNKNOWN,
            errorCode = "launchUnconfirmed")
        assertEquals(ArtifactHandoffLaunchDisposition.OUTCOME_UNKNOWN,
            ArtifactHandoffPolicy.launchDisposition(unknown))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(unknown))
        assertEquals("unknown", ArtifactHandoffPolicy.launchStateName(unknown))
        // The record is still active for status/finish/cancel and root cleanup.
        assertTrue(ArtifactHandoffPolicy.canResume(unknown))
        // A new call for the same source cannot sidestep it by staging anew.
        assertTrue(ArtifactHandoffPolicy.blocksNewLaunch(unknown))
        assertFalse(ArtifactHandoffPolicy.blocksNewLaunch(record(
            phase = ArtifactHandoffPhase.PAUSED,
            attempt = ArtifactHandoffLaunchAttempt.REJECTED,
            errorCode = "phoneArmRequired")))
        assertFalse(ArtifactHandoffPolicy.blocksNewLaunch(record(
            phase = ArtifactHandoffPhase.LAUNCHED,
            attempt = ArtifactHandoffLaunchAttempt.ACCEPTED)))
        assertFalse(ArtifactHandoffPolicy.blocksNewLaunch(record(
            phase = ArtifactHandoffPhase.CANCELLED,
            attempt = ArtifactHandoffLaunchAttempt.UNKNOWN)))
    }

    @Test
    fun acceptedStartReturnsTheExistingRecordAndTerminalIsClosed() {
        val accepted = record(phase = ArtifactHandoffPhase.LAUNCHED,
            attempt = ArtifactHandoffLaunchAttempt.ACCEPTED, errorCode = null)
        assertEquals(ArtifactHandoffLaunchDisposition.ALREADY_LAUNCHED,
            ArtifactHandoffPolicy.launchDisposition(accepted))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(accepted))
        assertTrue(accepted.launched)
        assertTrue(accepted.toolLaunchConfirmed)
        assertEquals("accepted", ArtifactHandoffPolicy.launchStateName(accepted))

        val finished = accepted.copy(phase = ArtifactHandoffPhase.FINISHED)
        assertEquals(ArtifactHandoffLaunchDisposition.ALREADY_LAUNCHED,
            ArtifactHandoffPolicy.launchDisposition(finished))
        val cancelledBeforeLaunch = record(phase = ArtifactHandoffPhase.CANCELLED)
        assertEquals(ArtifactHandoffLaunchDisposition.TERMINAL,
            ArtifactHandoffPolicy.launchDisposition(cancelledBeforeLaunch))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(cancelledBeforeLaunch))
    }

    @Test
    fun foregroundWinsAndBackgroundFailsClosedWithoutThePhoneRoute() {
        assertEquals(ArtifactHandoffLaunchRoute.FOREGROUND,
            ArtifactHandoffPolicy.launchRoute(
                taskVisibleAndSelected = true, floeVisible = true, backgroundAvailable = true))
        assertEquals(ArtifactHandoffLaunchRoute.FOREGROUND_REQUIRED,
            ArtifactHandoffPolicy.launchRoute(
                taskVisibleAndSelected = false, floeVisible = true, backgroundAvailable = true))
        assertEquals(ArtifactHandoffLaunchRoute.BACKGROUND,
            ArtifactHandoffPolicy.launchRoute(
                taskVisibleAndSelected = false, floeVisible = false, backgroundAvailable = true))
        assertEquals(ArtifactHandoffLaunchRoute.UNAVAILABLE,
            ArtifactHandoffPolicy.launchRoute(
                taskVisibleAndSelected = false, floeVisible = false, backgroundAvailable = false))
    }

    @Test
    fun onlyClosedKnownNoDispatchIsRetryable() {
        assertEquals(ArtifactHandoffStartDisposition.NOT_DISPATCHED,
            ArtifactHandoffPolicy.startDisposition(
                startReturned = false, knownNonDispatch = true))
        assertEquals(ArtifactHandoffStartDisposition.UNKNOWN,
            ArtifactHandoffPolicy.startDisposition(
                startReturned = false, knownNonDispatch = false))
        assertTrue(ArtifactHandoffPolicy.canIssueLaunch(record(
            phase = ArtifactHandoffPhase.PAUSED,
            attempt = ArtifactHandoffLaunchAttempt.REJECTED,
            errorCode = "launchRejected")))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(record(
            phase = ArtifactHandoffPhase.PAUSED,
            attempt = ArtifactHandoffLaunchAttempt.UNKNOWN,
            errorCode = "launchUnconfirmed")))
    }

    @Test
    fun postStartFailureKeepsAnAcceptedReceipt() {
        // startActivity returned, then a publication/callback failed: the
        // boundary must be ACCEPTED, never a retryable rejection.
        assertEquals(ArtifactHandoffStartDisposition.ACCEPTED,
            ArtifactHandoffPolicy.startDisposition(
                startReturned = true, knownNonDispatch = false))
        val accepted = record(phase = ArtifactHandoffPhase.LAUNCHED,
            attempt = ArtifactHandoffLaunchAttempt.ACCEPTED)
        assertEquals(ArtifactHandoffLaunchDisposition.ALREADY_LAUNCHED,
            ArtifactHandoffPolicy.launchDisposition(accepted))
        assertFalse(ArtifactHandoffPolicy.canIssueLaunch(accepted))
    }

    @Test
    fun journalRoundTripsEveryLaunchAttempt() {
        val directory = Files.createTempDirectory("artifact-handoff-attempt").toFile()
        try {
            val rows = listOf(
                record(),
                record(phase = ArtifactHandoffPhase.PAUSED,
                    attempt = ArtifactHandoffLaunchAttempt.REJECTED,
                    errorCode = "phoneArmRequired"),
                record(phase = ArtifactHandoffPhase.PAUSED,
                    attempt = ArtifactHandoffLaunchAttempt.UNKNOWN,
                    errorCode = "launchUnconfirmed"),
                record(phase = ArtifactHandoffPhase.LAUNCHED,
                    attempt = ArtifactHandoffLaunchAttempt.ACCEPTED),
            )
            for (row in rows) ArtifactHandoffJournal(directory).save(row)
            val loaded = ArtifactHandoffJournal(directory).load().associateBy { it.id }
            for (row in rows) assertEquals(row, loaded.getValue(row.id))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun legacyJournalRowsDoNotTurnDefiniteFailuresIntoUnknown() {
        val directory = Files.createTempDirectory("artifact-handoff-legacy").toFile()
        try {
            val rejected = record(phase = ArtifactHandoffPhase.PAUSED,
                attempt = ArtifactHandoffLaunchAttempt.REJECTED,
                errorCode = "foregroundRequired")
            val unknown = record(phase = ArtifactHandoffPhase.PAUSED,
                attempt = ArtifactHandoffLaunchAttempt.UNKNOWN,
                errorCode = null)
            val accepted = record(phase = ArtifactHandoffPhase.LAUNCHED,
                attempt = ArtifactHandoffLaunchAttempt.ACCEPTED)
            for (row in listOf(rejected, unknown, accepted)) writeLegacy(directory, row)
            val loaded = ArtifactHandoffJournal(directory).load().associateBy { it.id }

            assertEquals(ArtifactHandoffLaunchAttempt.REJECTED,
                loaded.getValue(rejected.id).launchAttempt)
            assertTrue(ArtifactHandoffPolicy.canIssueLaunch(loaded.getValue(rejected.id)))
            assertEquals(ArtifactHandoffLaunchAttempt.UNKNOWN,
                loaded.getValue(unknown.id).launchAttempt)
            assertFalse(ArtifactHandoffPolicy.canIssueLaunch(loaded.getValue(unknown.id)))
            assertEquals(ArtifactHandoffLaunchAttempt.ACCEPTED,
                loaded.getValue(accepted.id).launchAttempt)
            assertTrue(loaded.getValue(accepted.id).launched)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun aFabricatedLaunchCannotBypassTheAttemptState() {
        assertThrows(IllegalArgumentException::class.java) {
            record().copy(launched = true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            record().copy(toolLaunchConfirmed = true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            record(attempt = ArtifactHandoffLaunchAttempt.ACCEPTED).copy(launched = false)
        }
    }

    /** Remove the fields the retired v1 writer never persisted. */
    private fun writeLegacy(directory: File, row: ArtifactHandoffRecord) {
        val encoded = ArtifactHandoffJournal.encode(row)
        val legacy = JsonObject(
            encoded.filterKeys { it != "launchAttempt" && it != "toolLaunchConfirmed" })
        // The value is only used to prove the JSON shape stays parseable.
        assertTrue(encoded["launchAttempt"]!!.jsonPrimitive.isString)
        File(directory, "${row.id}.json").writeText(legacy.toString())
    }
}
