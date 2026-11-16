// SPDX-License-Identifier: MPL-2.0
//
// A refusal code cannot prove that an ID was never admitted: IDs may be
// reused and runtime receipt history is bounded. Unknown outcomes retain the
// original ownership until a real release or quiescence is established.
package com.floe.android.host.linux

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxShellStartAdmissionProofTest {

    @Test
    fun noKnownRuntimeRefusalProvesAnIdWasNeverAdmitted() {
        for (code in LinuxShellPump.ADMISSION_REFUSAL_CODES) {
            assertFalse(code, LinuxShellPump.admissionFailureIsPreAdmission(
                LinuxShellPump.AdmissionRefused(code)))
        }
    }

    @Test
    fun theLegacyCatchAllIsNotProofOfNoAdmission() {
        assertFalse(
            "runtime_not_ready was the old binder catch-all and must not terminalize a start",
            LinuxShellPump.admissionFailureIsPreAdmission(
                LinuxShellPump.AdmissionRefused("runtime_not_ready")))
        assertFalse(LinuxShellPump.admissionFailureIsPreAdmission(
            LinuxShellPump.AdmissionRefused("runtime_state_unknown")))
        assertFalse(LinuxShellPump.admissionFailureIsPreAdmission(
            LinuxShellPump.AdmissionRefused("some_future_code")))
    }

    @Test
    fun aTransportFailureIsNeverAStartRefusalProof() {
        assertFalse(LinuxShellPump.admissionFailureIsPreAdmission(
            IllegalStateException("local transport decode failure")))
    }

    @Test
    fun typedRefusalCannotDisproveReusedOrEvictedAdmission() {
        // The wire response carries neither fresh-ID proof nor durable receipt
        // history. These codes must remain ambiguous even when an earlier
        // request with that ID is still live, finished, or evicted.
        for (code in listOf("runtime_foreground_inactive", "runtime_stopping",
                            "runtime_control_busy", "invalid_request")) {
            assertFalse(code, LinuxShellPump.admissionFailureIsPreAdmission(
                LinuxShellPump.AdmissionRefused(code)))
        }
    }

    @Test
    fun diagnosticVocabularyStaysClosedAndBounded() {
        for (code in LinuxShellPump.ADMISSION_REFUSAL_CODES) {
            assertTrue("not a bounded refusal token: $code",
                LinuxShellPump.REFUSAL_TOKEN.matches(code))
        }
        assertTrue("runtime_not_ready" in LinuxShellPump.ADMISSION_REFUSAL_CODES)
    }
}
