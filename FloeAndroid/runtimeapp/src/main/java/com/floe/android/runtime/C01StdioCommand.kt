// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import java.io.File

/**
 * Pure, testable command -> guest argv resolution for the C01 separated-stdio
 * launch. This is NOT a shell: every argument stays one argv entry and no
 * metacharacter expansion exists anywhere.
 *
 * * absolute guest path: used verbatim (still component-validated);
 * * relative path containing '/': resolved against the already-validated
 *   workspace-relative cwd, never outside `/workspace`;
 * * bare name: searched in the SELECTED environment's own writable root using
 *   the fixed guest PATH order. A host PATH lookup or an interpreter fallback
 *   does not exist.
 *
 * Every empty/`.`/`..` component is refused. Absence is a typed failure the
 * caller reports; nothing is guessed.
 */
internal object C01StdioCommand {
    private val guestSearchPath = listOf(
        "usr/local/sbin", "usr/local/bin", "usr/sbin", "usr/bin", "sbin", "bin",
    )

    fun resolve(command: String, arguments: List<String>, cwd: String,
                writableRoot: File): List<String> {
        require(arguments.size <= 64)
        require(command.isNotBlank() && command.toByteArray(Charsets.UTF_8).size <= 512 &&
            '\u0000' !in command && '\n' !in command && '\r' !in command)
        val cwdParts = cwd.split('/').filter { it.isNotEmpty() }
        require(cwdParts.none { it == "." || it == ".." })
        val guestExecutable: String = when {
            command.startsWith("/") -> command
            '/' in command -> {
                val commandParts = command.split('/').filter { it.isNotEmpty() }
                require(commandParts.none { it == "." || it == ".." } && commandParts.isNotEmpty())
                "/workspace/" + (cwdParts + commandParts).joinToString("/")
            }
            else -> {
                require(command != "." && command != "..")
                val found = guestSearchPath.firstOrNull { relative ->
                    File(File(writableRoot, relative), command).isFile
                } ?: throw IllegalArgumentException("stdioCommandNotFound")
                "/$found/$command"
            }
        }
        val components = guestExecutable.split('/').drop(1)
        require(components.isNotEmpty() &&
            components.none { it.isEmpty() || it == "." || it == ".." }) {
            "stdioCommandInvalid"
        }
        return listOf(guestExecutable) + arguments
    }
}
