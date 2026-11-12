// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.externaledit.ArtifactHandoffBackgroundLaunchResult
import com.floe.android.phonecontrol.PhoneControlActionResult
import com.floe.android.phonecontrol.PhoneControlDenial
import com.floe.android.phonecontrol.PhoneControlDispatch
import com.floe.android.phonecontrol.PhoneControlFailure
import com.floe.android.phonecontrol.PhoneControlResult
import com.floe.android.phonecontrol.PhoneControlUnavailable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The background handoff must keep "definitely not dispatched" separate from
 * "OS outcome unknown". A mistaken retry after the latter duplicates a viewer
 * or importer effect; a refusal of the former must remain safely retryable.
 */
class ArtifactHandoffPhoneLaunchMappingTest {
    private fun result(dispatch: PhoneControlDispatch) =
        PhoneControlResult.Ok(PhoneControlActionResult(
            "documentView", dispatch, null, null, null, null))

    private fun refused(result: ArtifactHandoffBackgroundLaunchResult): String {
        assertTrue(result is ArtifactHandoffBackgroundLaunchResult.Refused)
        return (result as ArtifactHandoffBackgroundLaunchResult.Refused).code
    }

    @Test
    fun acceptedStartIsTheOnlySuccess() {
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Accepted,
            artifactHandoffPhoneLaunchResult(result(PhoneControlDispatch.ACCEPTED)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(result(PhoneControlDispatch.UNKNOWN)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(result(PhoneControlDispatch.PARTIAL)))
        assertEquals("launchRejected",
            refused(artifactHandoffPhoneLaunchResult(result(PhoneControlDispatch.NOT_DISPATCHED))))
        assertEquals("launchRejected",
            refused(artifactHandoffPhoneLaunchResult(result(PhoneControlDispatch.REJECTED))))
    }

    @Test
    fun definiteDispatchesMapToTypedRetryableRefusals() {
        assertEquals("stoppedByUser", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.STOPPED))))
        assertEquals("humanTakeover", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.TAKEN_OVER))))
        assertEquals("humanTakeover", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.USER_TOUCH))))
        assertEquals("deviceLocked", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED))))
        assertEquals("phoneArmRequired", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED))))
        assertEquals("phoneArmRequired", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_STALE))))
        assertEquals("targetNotPermitted", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED))))
        assertEquals("targetNotPermitted", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.PROTECTED_WINDOW))))
        assertEquals("phoneBusy", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))))
        assertEquals("phoneBusy", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT))))
        assertEquals("phoneServiceNotReady", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED))))
        assertEquals("targetNotPermitted", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Unavailable(PhoneControlUnavailable.LAUNCH_TARGET_UNAVAILABLE))))
        assertEquals("launchRejected", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED))))
        assertEquals("cancelled", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Failed(PhoneControlFailure.CANCELLED))))
    }

    @Test
    fun onlyTheClosedStartRejectionIsRetryable() {
        // The phone session emits ACTION_REJECTED ONLY for its closed
        // ActivityNotFoundException/SecurityException boundary. Any other
        // start/post-start exception is INTERNAL_ERROR and therefore unknown.
        assertEquals("launchRejected", refused(artifactHandoffPhoneLaunchResult(
            PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED))))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.OBSERVATION_FAILED)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.GESTURE_TIMEOUT)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.CAPTURE_SECURE_WINDOW)))
    }

    @Test
    fun unobservableFailuresAreUnknownNotRetryable() {
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffPhoneLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.TIMEOUT)))
    }

}
