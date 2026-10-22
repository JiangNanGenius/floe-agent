// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

/** Build/channel identities, never selected by a model or an IPC payload. */
data class RuntimePackages private constructor(val core: String, val runtime: String) {
    val permission: String get() = "$core.permission.LINUX_RUNTIME"

    companion object {
        const val ACCESS = "com.floe.android.runtime.RuntimeAccessActivity"
        const val SERVICE = "com.floe.android.runtime.LinuxRuntimeService"
        private val channels = listOf(
            RuntimePackages("com.floe.agent", "com.floe.agent.runtime"),
            RuntimePackages("com.floe.agent.dev", "com.floe.agent.runtime.dev"),
            RuntimePackages("com.floe.agent.full", "com.floe.agent.runtime.full"),
            RuntimePackages("com.floe.agent.full.dev", "com.floe.agent.runtime.full.dev"),
        )

        fun forCore(packageName: String): RuntimePackages =
            channels.singleOrNull { it.core == packageName }
                ?: throw SecurityException("Unrecognized core application")

        fun forRuntime(packageName: String): RuntimePackages =
            channels.singleOrNull { it.runtime == packageName }
                ?: throw SecurityException("Unrecognized runtime application")
    }
}
