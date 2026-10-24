// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.io.File
import java.security.MessageDigest

/**
 * displayName is UNTRUSTED display text, never a path. These helpers guarantee
 * local staging names carry no separators, traversal, absolute prefixes or
 * control characters, and embed a stable digest of the exact document identity
 * so collisions across distinct documents are impossible.
 */
internal object SafStagingNames {

    /** Deterministic lowercase hex SHA-256 of a string's UTF-8 bytes. */
    fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    /** Reject a provider-supplied display name before any local staging use. */
    fun isUnsafeDisplayName(name: String): Boolean =
        name.isBlank() || name.contains('/') || name.contains('\\') ||
            name == "." || name == ".." || name.any { it.code < 0x20 || it.code == 0x7f }

    /**
     * Map an untrusted displayName + exact identity to one safe staging segment:
     * separators flattened, control characters stripped, trailing dots trimmed,
     * UTF-8 length capped on a character boundary, identity digest suffix added.
     */
    fun forStaging(displayName: String, identity: String, limits: SafLimits): String {
        val flattened = displayName
            .replace('\\', '_')
            .replace('/', '_')
            .filter { it.code >= 0x20 && it.code != 0x7f }
            .trim()
            .trimEnd('.')
        val base = if (flattened.isBlank() || flattened.all { it == '.' }) "document" else flattened
        val suffix = "~" + sha256Hex(identity).substring(0, 12)
        // Reserve room for the suffix on the byte cap; truncate on char boundaries.
        val budget = limits.maxStagedNameBytes - suffix.toByteArray(Charsets.UTF_8).size
        var kept = StringBuilder()
        var used = 0
        for (ch in base) {
            val size = ch.toString().toByteArray(Charsets.UTF_8).size
            if (used + size > budget) break
            kept.append(ch)
            used += size
        }
        var trimmed = kept.toString().trimEnd('.', ' ')
        if (trimmed.isEmpty()) trimmed = "document"
        return trimmed + suffix
    }

    /** True when [candidate] stays strictly under [root] after canonicalization. */
    fun isWithin(root: File, candidate: File): Boolean {
        val r = runCatching { root.canonicalFile }.getOrNull() ?: return false
        val c = runCatching { candidate.canonicalFile }.getOrNull() ?: return false
        return c.path != r.path && c.path.startsWith(r.path + File.separator)
    }
}

/** Streaming hash helper shared by read/stage/verify passes. */
internal class SafStreamHasher(private val chunkBytes: Int) {
    private val digest = MessageDigest.getInstance("SHA-256")
    var bytes: Long = 0L
        private set
    private var completed = false

    fun consume(buffer: ByteArray, count: Int) {
        check(!completed) { "hasher already finished" }
        digest.update(buffer, 0, count)
        bytes += count.toLong()
    }

    fun finishHex(): String {
        if (!completed) {
            completed = true
            hex = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }
        return hex
    }

    private var hex: String = ""
}
