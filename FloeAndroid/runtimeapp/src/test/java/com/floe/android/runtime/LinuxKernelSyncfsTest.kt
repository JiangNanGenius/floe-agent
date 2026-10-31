// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxKernelSyncfsTest {
    @Test fun modernKernelsReportSyncfsWritebackErrors() {
        assertTrue(reportsSyncfsWritebackErrors("5.8.0"))
        assertTrue(reportsSyncfsWritebackErrors("5.10.209-android13-8-g3f4e2a"))
        assertTrue(reportsSyncfsWritebackErrors("6.6.30-android15-8-gabc"))
        // Actual API37 tablet target (device-qa/ACTUAL_KERNELS.json).
        assertTrue(reportsSyncfsWritebackErrors(
            "6.12.81-android16-6-g4f69fc7b210c-ab16167562"))
    }

    @Test fun oldAndUnknownKernelsKeepPerFileFailureSemantics() {
        // syncfs before 5.8 reports only EBADF, so it cannot replace fsync.
        assertFalse(reportsSyncfsWritebackErrors("5.7.19"))
        assertFalse(reportsSyncfsWritebackErrors("5.4.210-android12"))
        assertFalse(reportsSyncfsWritebackErrors("4.14.150+"))
        assertFalse(reportsSyncfsWritebackErrors("4.9.337"))
        // Actual Samsung target (device-qa/ACTUAL_KERNELS.json): per-file path.
        assertFalse(reportsSyncfsWritebackErrors("4.19.113-27095354"))
        // Unknown/absent/unparsable release is conservative fallback.
        assertFalse(reportsSyncfsWritebackErrors(""))
        assertFalse(reportsSyncfsWritebackErrors("unknown"))
        assertFalse(reportsSyncfsWritebackErrors("5"))
        assertFalse(reportsSyncfsWritebackErrors("5.x.0"))
    }
}
