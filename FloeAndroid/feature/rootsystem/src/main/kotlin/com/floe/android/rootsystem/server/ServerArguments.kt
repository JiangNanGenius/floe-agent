// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.policy.AccessPolicy

/**
 * Strict argument parser for the app_process entry point. Only the fixed
 * launcher grammar is accepted; unknown or duplicate keys are ignored, values
 * are re-validated, and the token is never written to a log.
 */
internal data class ServerArguments(
    val mode: String,
    val token: String,
    val packageName: String,
    val callerUid: Int,
    val signingSha256: String,
    val appVersionCode: Long,
    val apkPath: String,
) {
    companion object {
        private val PACKAGE = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
        private val HEX_64 = Regex("^[0-9a-f]{64}$")
        private val HEX_32_64 = Regex("^[0-9a-f]{32,64}$")

        fun parse(args: Array<String>): ServerArguments? {
            val map = HashMap<String, String>()
            for (arg in args) {
                if (!arg.startsWith("--")) continue
                val equals = arg.indexOf('=')
                if (equals <= 2) continue
                val key = arg.substring(2, equals)
                val value = arg.substring(equals + 1)
                if (key.isEmpty() || value.isEmpty()) continue
                map.putIfAbsent(key, value)
            }
            val mode = map["mode"] ?: return null
            if (mode != AccessPolicy.MODE_ADB && mode != AccessPolicy.MODE_ROOT) return null
            val token = map["token"] ?: return null
            if (!HEX_32_64.matches(token)) return null
            if (mode == AccessPolicy.MODE_ADB && token.length != 64) return null
            val packageName = map["package"] ?: return null
            if (!PACKAGE.matches(packageName) || packageName.length > 127) return null
            val callerUid = map["caller-uid"]?.toIntOrNull() ?: return null
            if (callerUid <= 0) return null
            val signing = map["signing-sha256"] ?: return null
            if (!HEX_64.matches(signing)) return null
            val version = map["app-version"]?.toLongOrNull() ?: return null
            if (version <= 0) return null
            val apk = map["apk"] ?: return null
            if (!apk.startsWith("/") || apk.length > 4096 || apk.any { it == '\u0000' || it == '\n' }) {
                return null
            }
            return ServerArguments(mode, token, packageName, callerUid, signing, version, apk)
        }
    }
}

internal object ServerExit {
    const val ARGUMENTS = 2
    const val UID = 3
    const val IDENTITY = 4
    const val CONTEXT = 5
    const val BINDER = 6
    const val STOPPED = 0
}
