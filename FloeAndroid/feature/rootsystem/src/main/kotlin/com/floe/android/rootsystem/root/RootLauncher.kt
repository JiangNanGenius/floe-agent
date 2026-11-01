// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.root

import com.floe.android.rootsystem.policy.AccessPolicy
import com.topjohnwu.superuser.Shell
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import moe.shizuku.starter.StarterCommand

/**
 * Root backend launcher. Root stays off by default: this class is only reached
 * after the App's explicit user action and it re-checks the actual effective
 * UID through the existing superuser grant. A userdebug/adb UID 0, a debug
 * build or a present `su` binary without a grant is never treated as root.
 */
internal class RootLauncher {

    suspend fun probeEffectiveUid(): Int? = withContext(Dispatchers.IO) {
        try {
            val shell = Shell.getShell()
            if (!shell.isRoot) return@withContext null
            val result = Shell.cmd("id -u").exec()
            if (!result.isSuccess) return@withContext null
            val uid = result.out.firstOrNull { it.trim().isNotEmpty() }?.trim()?.toIntOrNull()
                ?: return@withContext null
            if (uid == AccessPolicy.UID_ROOT) uid else null
        } catch (_: Throwable) {
            null
        }
    }

    suspend fun launch(launch: StarterCommand.Launch): Boolean = withContext(Dispatchers.IO) {
        if (launch.mode != AccessPolicy.MODE_ROOT) return@withContext false
        try {
            // Detach from the su shell so closing the su session does not take
            // the server down; the server itself verifies UID 0 after startup.
            val command = "setsid sh -c " + StarterCommand.quote(launch.command) +
                " >/dev/null 2>&1 &"
            Shell.cmd(command).exec().isSuccess
        } catch (_: Throwable) {
            false
        }
    }
}
