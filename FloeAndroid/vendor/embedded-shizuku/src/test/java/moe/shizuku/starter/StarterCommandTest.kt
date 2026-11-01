// SPDX-License-Identifier: Apache-2.0
package moe.shizuku.starter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StarterCommandTest {

    private val token = "a".repeat(64)
    private val signing = "b".repeat(64)
    private val packageName = "com.floe.agent.full"

    @Test
    fun adbLaunchIsValidatedAndShellQuoted() {
        val launch = StarterCommand.adbLaunch(
            nativeLibraryDir = "/data/app/com.floe.agent.full-1/lib/arm64",
            apkPath = "/data/app/com.floe.agent.full-1/base.apk",
            packageName = packageName,
            token = token,
            callerUid = 10123,
            signingSha256 = signing,
            appVersionCode = 24,
            serverClass = "com.floe.android.rootsystem.server.FloeSystemServer",
        )
        assertEquals("floe_adb_server", launch.processName)
        assertEquals("adb", launch.mode)
        assertTrue(launch.command.contains("--token='$token'"))
        assertTrue(launch.command.contains("--mode=adb"))
        assertTrue(launch.command.startsWith("'"))
        assertTrue(StarterCommand.usbBootstrapCommand(launch).startsWith("adb shell '"))
        val script = StarterCommand.usbBootstrapScript(launch)
        assertTrue(script.startsWith("#!/bin/sh"))
        assertTrue(script.contains("exec adb shell "))
    }

    @Test
    fun rootLaunchContainsNoShellInterpolationHole() {
        val launch = StarterCommand.rootLaunch(
            apkPath = "/data/app/com.floe.agent.full-1/base.apk",
            packageName = packageName,
            token = token,
            callerUid = 10123,
            signingSha256 = signing,
            appVersionCode = 24,
            serverClass = "com.floe.android.rootsystem.server.FloeSystemServer",
        )
        assertEquals("floe_root_server", launch.processName)
        assertEquals("root", launch.mode)
        assertTrue(launch.command.contains("--mode=root"))
        assertTrue(launch.command.contains("--nice-name=floe_root_server"))
        assertTrue(launch.command.contains("CLASSPATH="))
    }

    @Test
    fun adbLaunchCarriesExactIdentityArguments() {
        val launch = StarterCommand.adbLaunch(
            nativeLibraryDir = "/data/app/com.floe.agent.full-1/lib/arm64",
            apkPath = "/data/app/com.floe.agent.full-1/base.apk",
            packageName = packageName,
            token = token,
            callerUid = 10123,
            signingSha256 = signing,
            appVersionCode = 24,
            serverClass = "com.floe.android.rootsystem.server.FloeSystemServer",
        )
        // app_process erases its argv block at --nice-name, so these identity
        // arguments are not available from /proc. The App instead verifies the
        // published binder through describe(); the launcher still carries the
        // same package/caller UID/class/mode for the server's own startup check.
        assertTrue(launch.command.contains("--apk='/data/app/com.floe.agent.full-1/base.apk'"))
        assertTrue(launch.command.contains("--package='com.floe.agent.full'"))
        assertTrue(launch.command.contains("--caller-uid=10123"))
        assertTrue(launch.command.contains("--mode=adb"))
        assertTrue(
            launch.command.contains(
                "--server-class='com.floe.android.rootsystem.server.FloeSystemServer'",
            ),
        )
        assertTrue(launch.command.contains("--process-name='floe_adb_server'"))
        assertTrue(launch.command.contains("--signing-sha256='$signing'"))
        assertTrue(launch.command.contains("--app-version=24"))
        // No replacement PID is sent unless the App has verified an old binder.
        assertTrue(!launch.command.contains("--replace-pid="))
    }

    @Test
    fun replacePidIsOnlyEmittedForAVerifiedPid() {
        val launch = StarterCommand.adbLaunch(
            nativeLibraryDir = "/data/app/com.floe.agent.full-1/lib/arm64",
            apkPath = "/data/app/com.floe.agent.full-1/base.apk",
            packageName = packageName,
            token = token,
            callerUid = 10123,
            signingSha256 = signing,
            appVersionCode = 24,
            serverClass = "com.floe.android.rootsystem.server.FloeSystemServer",
            replacePid = 4321,
        )
        assertTrue(launch.command.endsWith(" --replace-pid=4321"))
        assertNotNull(
            runCatching {
                StarterCommand.adbLaunch(
                    "/data/app/p/lib", "/data/app/p/base.apk", packageName, token, 10123,
                    signing, 24, "a.B", replacePid = 0,
                )
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching {
                StarterCommand.adbLaunch(
                    "/data/app/p/lib", "/data/app/p/base.apk", packageName, token, 10123,
                    signing, 24, "a.B", replacePid = 1,
                )
            }.exceptionOrNull(),
        )
    }

    @Test
    fun invalidValuesAreRejectedBeforeReachingAShell() {
        assertNotNull(
            runCatching {
                StarterCommand.adbLaunch(
                    "/data/app/p/lib", "/data/app/p/base.apk", "bad package", token, 1, signing, 1,
                    "a.B",
                )
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching {
                StarterCommand.adbLaunch(
                    "relative", "/data/app/p/base.apk", packageName, token, 1, signing, 1, "a.B",
                )
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching {
                StarterCommand.adbLaunch(
                    "/data/app/p/lib", "/data/app/p/base.apk", packageName, "zz", 1, signing, 1, "a.B",
                )
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching {
                StarterCommand.adbLaunch(
                    "/data/app/p/lib", "/data/app/p/base.apk", packageName, token, 0, signing, 1, "a.B",
                )
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching {
                StarterCommand.rootLaunch(
                    "/data/app/p/base.apk", packageName, token, -1, signing, 1, "a.B",
                )
            }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching { StarterCommand.packagePathQuery("a;rm -rf /") }.exceptionOrNull(),
        )
    }

    @Test
    fun quotesAreEscaped() {
        assertEquals("'a'\\''b'", StarterCommand.quote("a'b"))
    }
}
