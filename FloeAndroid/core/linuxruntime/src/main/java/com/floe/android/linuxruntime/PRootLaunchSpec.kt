// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime

import java.io.File

/**
 * Trusted, caller-resolved launch inputs. FloeEnvironments owns the selected
 * root, project and write layer; this adapter never resolves a default one.
 * Bind mounts describe path translation, not an access-control boundary.
 */
data class LinuxBind(val host: File, val guest: String) {
    init {
        require(host.isAbsolute && ':' !in host.path && '\u0000' !in host.path)
        require(guest.startsWith("/") && ':' !in guest && '\u0000' !in guest)
    }
}

data class PRootLaunchSpec(
    val nativeLibraryDirectory: File,
    val rootfs: File,
    val scratch: File,
    val guestWorkingDirectory: String,
    val guestHome: String,
    val guestTemporaryDirectory: String,
    val binds: List<LinuxBind>,
    val ownership: RunOwnership,
) {
    init {
        require(listOf(nativeLibraryDirectory, rootfs, scratch).all {
            it.isAbsolute && '\u0000' !in it.path
        })
        require(listOf(guestWorkingDirectory, guestHome, guestTemporaryDirectory).all {
            it.startsWith("/") && '\u0000' !in it
        })
    }

    /** No shell quoting: each command argument remains a separate argv entry. */
    fun command(
        argv: List<String>,
        environment: Map<String, String> = emptyMap(),
        rows: Int = 24,
        cols: Int = 80,
    ): LaunchSpec {
        require(argv.isNotEmpty() && argv[0].startsWith("/")) {
            "Pass an explicit absolute guest executable"
        }
        require(environment.keys.none { it.startsWith("PROOT_") }) {
            "PRoot controls belong to the resolved launch plan"
        }
        require(rootfs.isDirectory && scratch.isDirectory) {
            "The owner must prepare rootfs and scratch before launch"
        }
        val proot = File(nativeLibraryDirectory, "libproot.so").absolutePath
        val loader = File(nativeLibraryDirectory, "libproot_loader.so").absolutePath
        val arguments = mutableListOf(proot, "--kill-on-exit", "-r", rootfs.absolutePath)
        for (bind in binds) arguments += listOf("-b", "${bind.host.absolutePath}:${bind.guest}")
        arguments += listOf("-w", guestWorkingDirectory)
        arguments += argv
        return LaunchSpec(
            executable = proot,
            argv = arguments,
            env = mapOf(
                "PATH" to "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME" to guestHome, "TMPDIR" to guestTemporaryDirectory,
                "TERM" to "xterm-256color",
            ) + environment + mapOf(
                "PROOT_LOADER" to loader,
                "PROOT_TMP_DIR" to scratch.absolutePath,
            ),
            workingDir = rootfs.absolutePath,
            ownership = ownership,
            rows = rows, cols = cols,
        )
    }
}
