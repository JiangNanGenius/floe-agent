package com.floe.android.host.linux

import org.junit.Assert.*
import org.junit.Test

class LinuxSetupDiagnosticTest {
    @Test fun wrappedNetworkErrorNamesCauseWithoutLeakingMessage() {
        val secret = "https://user:secret@example.invalid/private?token=hidden"
        val failure = LinuxSetupDiagnostic.fromThrowable(java.util.concurrent.ExecutionException(
            java.net.UnknownHostException(secret)), "connect")
        assertEquals("dns", failure.category)
        assertEquals("connect", failure.stage)
        assertFalse(failure.toString().contains("secret"))
    }
    @Test fun unknownWireTextCannotBecomeDiagnosticContent() {
        val value = LinuxSetupDiagnostic.fromFields("private/path?key=secret", "password=secret", "bad\nline")
        assertEquals(LinuxSetupDiagnostic("OPERATION_FAILED", "unknown", ""), value)
    }
    @Test fun actualInstallerFailuresHaveDifferentRecoveries() {
        assertEquals("storage", LinuxSetupDiagnostic.fromFields("DISK_BUDGET", "extract").category)
        assertEquals("archive", LinuxSetupDiagnostic.fromFields("DIGEST_MISMATCH", "verify_archive").category)
        assertEquals("permission", LinuxSetupDiagnostic.fromFields("COMPONENT_BLOCKED", "component").category)
        assertEquals("unknown", LinuxSetupDiagnostic.fromFields("UNEXPECTED_IO", "publish").category)
    }
}
