// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import java.io.File

/** Kind view used by the swap engine (no-follow semantics required). */
enum class SwapKind { MISSING, FILE, DIRECTORY, SYMLINK, OTHER, UNREADABLE }

/** Decimal file-mode constants (Kotlin has no octal literals; these are the
 *  documented octal equivalents). */
object WorkspaceFileModes {
    const val DIR_DEFAULT = 493     // 0755
    const val FILE_DEFAULT = 420    // 0644
    const val LINK_NOMINAL = 511    // 0777 (informational for symlinks)
    const val ALL_BITS = 4095       // 07777
    const val SAFE_MASK = 493       // claimed modes clamp to 0755
}

/**
 * Filesystem primitives for the import swap engine. The engine itself is
 * ANDROID-FREE so its transactional behaviour is unit-testable on the JVM
 * with [java.nio] semantics; production passes [DefaultSwapOps] (android
 * Os, O_NOFOLLOW). Implementations MUST NOT follow symlinks.
 */
interface WorkspaceSwapOps {
    fun kind(path: File): SwapKind
    fun size(path: File): Long
    fun rename(from: File, to: File): Boolean
    fun mkdir(path: File): Boolean
    /** True when an existing empty directory was removed. */
    fun rmdir(path: File): Boolean
    /** True when an existing file or symlink was removed. */
    fun unlink(path: File): Boolean
    fun symlink(target: String, path: File): Boolean
    /** Streaming SHA-256 of ACTUAL bytes through a no-follow descriptor. */
    fun streamDigest(path: File): Pair<String, Long>?
    fun freeBytes(path: File): Long
    fun fsyncDirectory(path: File)
}
