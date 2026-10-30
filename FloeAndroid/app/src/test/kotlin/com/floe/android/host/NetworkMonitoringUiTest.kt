// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.MonitorConfigPolicy
import com.floe.android.MonitorConfigProblem
import com.floe.android.MonitorExportFormat
import com.floe.android.MonitorExportValidation
import com.floe.android.MonitorFormValues
import com.floe.android.MonitorNotificationGate
import com.floe.android.formatMonitorElapsed
import com.floe.android.monitorElapsedSeconds
import com.floe.android.monitorNotificationGate
import com.floe.android.validateMonitorExport
import com.floe.android.core.networkmonitor.NetworkMonitorLimits
import com.floe.android.core.networkmonitor.NetworkMonitorPhase
import com.floe.android.core.networkmonitor.NetworkMonitorProbeKind
import com.floe.android.core.networkmonitor.NetworkMonitorSessionState
import java.io.File
import java.io.RandomAccessFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Source-level policy coverage for the G07.2 monitoring/report surface.
 *
 * These tests exercise the pure admission/validation helpers the rendered UI
 * uses. They do not start a service, request a permission, write a real SAF
 * document or claim device behaviour; Main owns the real SDK/JVM/device batch.
 */
class NetworkMonitoringUiTest {

    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun defaultFormIsABoundedStatusOnlySession() {
        val parsed = MonitorConfigPolicy.parse(MonitorFormValues())
        assertTrue(parsed.problems.isEmpty())
        val config = requireNotNull(parsed.config)
        assertEquals(600_000L, config.durationMillis)
        assertEquals(30_000L, config.intervalMillis)
        assertEquals(1, config.probes.size)
        assertEquals(NetworkMonitorProbeKind.STATUS, config.probes.single().kind)
    }

    @Test
    fun allThreeChecksUseTheValidatedHostAndPort() {
        val parsed = MonitorConfigPolicy.parse(
            MonitorFormValues(
                durationMinutes = "60",
                intervalSeconds = "300",
                statusEnabled = true,
                pingEnabled = true,
                pingHost = "  example.com  ",
                tcpEnabled = true,
                tcpHost = "2001:db8::1",
                tcpPort = "443",
            ),
        )
        assertTrue(parsed.problems.toString(), parsed.problems.isEmpty())
        val config = requireNotNull(parsed.config)
        assertEquals(3_600_000L, config.durationMillis)
        assertEquals(300_000L, config.intervalMillis)
        assertEquals(3, config.probes.size)
        assertEquals("example.com", config.probes.first { it.kind == NetworkMonitorProbeKind.PING }.host)
        assertEquals("2001:db8::1", config.probes.first { it.kind == NetworkMonitorProbeKind.TCP }.host)
        assertEquals(443, config.probes.first { it.kind == NetworkMonitorProbeKind.TCP }.port)
    }

    @Test
    fun durationAndIntervalOutsideCoreBoundsAreRejected() {
        assertEquals(
            setOf(MonitorConfigProblem.DURATION),
            MonitorConfigPolicy.parse(MonitorFormValues(durationMinutes = "0")).problems.toSet(),
        )
        assertEquals(
            setOf(MonitorConfigProblem.DURATION),
            MonitorConfigPolicy.parse(MonitorFormValues(durationMinutes = "61")).problems.toSet(),
        )
        assertEquals(
            setOf(MonitorConfigProblem.INTERVAL),
            MonitorConfigPolicy.parse(MonitorFormValues(intervalSeconds = "4")).problems.toSet(),
        )
        assertEquals(
            setOf(MonitorConfigProblem.INTERVAL),
            MonitorConfigPolicy.parse(MonitorFormValues(intervalSeconds = "301")).problems.toSet(),
        )
        assertNull(MonitorConfigPolicy.parse(MonitorFormValues(durationMinutes = "x")).config)
        assertNull(MonitorConfigPolicy.parse(MonitorFormValues(intervalSeconds = "")).config)
    }

    @Test
    fun anEmptyProbeSelectionCannotCreateASession() {
        val parsed = MonitorConfigPolicy.parse(
            MonitorFormValues(statusEnabled = false, pingEnabled = false, tcpEnabled = false),
        )
        assertNull(parsed.config)
        assertTrue(MonitorConfigProblem.NO_PROBE in parsed.problems)
    }

    @Test
    fun pingHostValidationMatchesTheCoreContract() {
        val invalidHosts = listOf(
            "",
            "   ",
            "https://example.com",
            "user@example.com",
            "host name",
            "host/path",
            "host?query",
            "host#fragment",
            "a".repeat(254),
        )
        invalidHosts.forEach { host ->
            assertNull("expected rejection for '$host'", MonitorConfigPolicy.normalizeMonitorHost(host))
        }
        assertEquals("example.com", MonitorConfigPolicy.normalizeMonitorHost("  example.com  "))
        assertEquals("2001:db8::1", MonitorConfigPolicy.normalizeMonitorHost("2001:db8::1"))

        val parsed = MonitorConfigPolicy.parse(
            MonitorFormValues(pingEnabled = true, pingHost = "https://example.com"),
        )
        assertNull(parsed.config)
        assertTrue(MonitorConfigProblem.HOST in parsed.problems)
    }

    @Test
    fun tcpPortMustBeInTheCoreRange() {
        val parsed = MonitorConfigPolicy.parse(
            MonitorFormValues(tcpEnabled = true, tcpHost = "example.com", tcpPort = "0"),
        )
        assertNull(parsed.config)
        assertTrue(MonitorConfigProblem.PORT in parsed.problems)

        val tooHigh = MonitorConfigPolicy.parse(
            MonitorFormValues(tcpEnabled = true, tcpHost = "example.com", tcpPort = "65536"),
        )
        assertNull(tooHigh.config)
        assertTrue(MonitorConfigProblem.PORT in tooHigh.problems)

        val valid = MonitorConfigPolicy.parse(
            MonitorFormValues(tcpEnabled = true, tcpHost = "example.com", tcpPort = "65535"),
        )
        assertNotNull(valid.config)
        assertEquals(2, requireNotNull(valid.config).probes.size)
    }

    @Test
    fun notificationGateReusesAGrantButNeverRequestsOnItsOwn() {
        assertEquals(
            MonitorNotificationGate.ALLOWED,
            monitorNotificationGate(32, permissionGranted = true, notificationsEnabled = true, canAskAgain = true, requestedBefore = false),
        )
        assertEquals(
            MonitorNotificationGate.OPEN_SETTINGS,
            monitorNotificationGate(32, permissionGranted = true, notificationsEnabled = false, canAskAgain = true, requestedBefore = false),
        )
        assertEquals(
            MonitorNotificationGate.ALLOWED,
            monitorNotificationGate(33, permissionGranted = true, notificationsEnabled = true, canAskAgain = true, requestedBefore = true),
        )
        assertEquals(
            MonitorNotificationGate.OPEN_SETTINGS,
            monitorNotificationGate(33, permissionGranted = true, notificationsEnabled = false, canAskAgain = false, requestedBefore = true),
        )
        assertEquals(
            MonitorNotificationGate.REQUEST_PERMISSION,
            monitorNotificationGate(33, permissionGranted = false, notificationsEnabled = false, canAskAgain = false, requestedBefore = false),
        )
        assertEquals(
            MonitorNotificationGate.REQUEST_PERMISSION,
            monitorNotificationGate(33, permissionGranted = false, notificationsEnabled = false, canAskAgain = true, requestedBefore = true),
        )
        assertEquals(
            MonitorNotificationGate.OPEN_SETTINGS,
            monitorNotificationGate(33, permissionGranted = false, notificationsEnabled = false, canAskAgain = false, requestedBefore = true),
        )
    }

    @Test
    fun exportAcceptsOnlyTheExactBoundedReportFile() {
        val valid = folder.newFile("report.json").apply { writeText("{}") }
        assertEquals(MonitorExportValidation.VALID, validateMonitorExport(valid, MonitorExportFormat.JSON))

        val wrongName = folder.newFile("other.json").apply { writeText("{}") }
        assertEquals(MonitorExportValidation.WRONG_NAME, validateMonitorExport(wrongName, MonitorExportFormat.JSON))

        val empty = folder.newFile("report.md")
        assertEquals(MonitorExportValidation.EMPTY, validateMonitorExport(empty, MonitorExportFormat.MARKDOWN))

        assertEquals(
            MonitorExportValidation.MISSING,
            validateMonitorExport(null, MonitorExportFormat.JSON),
        )
        assertEquals(
            MonitorExportValidation.MISSING,
            validateMonitorExport(File(folder.root, "missing.json"), MonitorExportFormat.JSON),
        )
        assertEquals(
            MonitorExportValidation.NOT_A_FILE,
            validateMonitorExport(folder.newFolder("report-directory"), MonitorExportFormat.JSON),
        )
    }

    @Test
    fun oversizedReportIsRejectedBeforeAnyPickerOrWrite() {
        val oversized = folder.newFile("report.json")
        RandomAccessFile(oversized, "rw").use { file ->
            file.setLength(NetworkMonitorLimits.MAX_REPORT_JSON_BYTES.toLong() + 1L)
        }
        assertEquals(
            MonitorExportValidation.TOO_LARGE,
            validateMonitorExport(oversized, MonitorExportFormat.JSON),
        )
        val markdown = folder.newFile("report.md")
        RandomAccessFile(markdown, "rw").use { file ->
            file.setLength(NetworkMonitorLimits.MAX_REPORT_MARKDOWN_BYTES.toLong() + 1L)
        }
        assertEquals(
            MonitorExportValidation.TOO_LARGE,
            validateMonitorExport(markdown, MonitorExportFormat.MARKDOWN),
        )
    }

    @Test
    fun elapsedTimeIsMonotonicForTheActiveAndCompletedSession() {
        val running = NetworkMonitorSessionState(
            phase = NetworkMonitorPhase.RUNNING,
            sessionId = "active",
            startedAtElapsedNanos = 1_000_000_000L,
        )
        assertEquals(65L, monitorElapsedSeconds(running, 66_000_000_000L))

        // Terminal sessions use the last completed check's monotonic timestamp
        // rather than inventing an end time; no observation means no elapsed
        // measurement is claimed.
        assertEquals(
            30L,
            monitorElapsedSeconds(
                startedAtElapsedNanos = 1_000_000_000L,
                isActive = false,
                lastObservationFinishedAtElapsedNanos = 31_000_000_000L,
                nowElapsedNanos = 999_000_000_000L,
            ),
        )
        assertEquals(
            0L,
            monitorElapsedSeconds(
                startedAtElapsedNanos = 1_000_000_000L,
                isActive = false,
                lastObservationFinishedAtElapsedNanos = null,
                nowElapsedNanos = 999_000_000_000L,
            ),
        )
        assertEquals("0:00", formatMonitorElapsed(0L))
        assertEquals("1:05", formatMonitorElapsed(65L))
        assertEquals("1:01:01", formatMonitorElapsed(3_661L))
    }
}
