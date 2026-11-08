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

    @Test fun componentPreparationFailuresAreDistinguishedAndActionable() {
        // Every existing component-stage check boundary closes to its own
        // category: storage for staging, component for bundle/identity/session.
        assertEquals("storage", LinuxSetupDiagnostic.fromFields("COMPONENT_STAGING_UNAVAILABLE", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_ASSET_UNAVAILABLE", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_SIZE_EXCEEDED", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_DIGEST_MISMATCH", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_ARCHIVE_UNREADABLE", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_PACKAGE_MISMATCH", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_VERSION_MISMATCH", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_CERTIFICATE_UNAVAILABLE", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_IDENTITY_MISMATCH", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_SESSION_FAILED", "component").category)
        assertEquals("component", LinuxSetupDiagnostic.fromFields("COMPONENT_INSTALL_FAILED", "component").category)
        // Stage and closed codes survive the token gate unchanged.
        val failure = LinuxSetupDiagnostic.fromFields("COMPONENT_DIGEST_MISMATCH", "component", "ComponentPreparation")
        assertEquals("component", failure.stage)
        assertEquals("COMPONENT_DIGEST_MISMATCH", failure.code)
        assertEquals("ComponentPreparation", failure.exceptionType)
    }
}
