// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.core.officeengine.OfficeCloseProof
import java.io.File
import java.nio.channels.Channels
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.UUID

/** Re-read only a controller-owned staged file after the exact engine died.
 * No path or file authority comes from the receipt. Never follows a link or
 * accepts a prefix, timestamp, partial digest, or bytes from another mount. */
internal object OfficeCloseFileVerification {
    fun matches(file: File, ownedRoots: Set<File>, receipt: OfficeCloseProof.Receipt, processDead: Boolean): Boolean {
        if (!processDead) return false
        return runCatching {
            val parent = file.parentFile ?: return@runCatching false
            val root = parent.parentFile ?: return@runCatching false
            if (root.canonicalFile !in ownedRoots.map { it.canonicalFile } ||
                UUID.fromString(parent.name).toString() != parent.name ||
                listOf(root, parent, file).any { Files.isSymbolicLink(it.toPath()) } ||
                file.absoluteFile != file.canonicalFile || !file.isFile || file.length() != receipt.bytes
            ) return@runCatching false
            val hash = MessageDigest.getInstance("SHA-256")
            var count = 0L
            Files.newByteChannel(file.toPath(), StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
                Channels.newInputStream(channel).use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        count += n
                        if (count > receipt.bytes) return@runCatching false
                        hash.update(buffer, 0, n)
                    }
                }
            }
            OfficeCloseProof.matchesClosedFile(receipt, processDead,
                hash.digest().joinToString("") { "%02x".format(it) }, count)
        }.getOrDefault(false)
    }
}
