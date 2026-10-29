// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

/**
 * Pure update-discovery semantics shared by the GitHub full-flavor updater:
 * Android release-tag parsing, semantic version ordering, bounded plaintext
 * release summaries, SHA256SUMS parsing and GitHub pagination-link reading.
 *
 * No Android, network or storage types appear here on purpose: the focused
 * full-flavor unit tests exercise every function directly, and Main's one
 * coherent build compiles this file for the full variant only.
 */

/**
 * Semantic version subset used by `android/v<semver>` release tags.
 * Build metadata is irrelevant for ordering and is discarded on parse.
 */
internal data class FloeVersion(
    val major: Int,
    val minor: Int,
    val patch: Int,
    val prerelease: List<String> = emptyList(),
) : Comparable<FloeVersion> {

    override fun compareTo(other: FloeVersion): Int {
        if (major != other.major) return major.compareTo(other.major)
        if (minor != other.minor) return minor.compareTo(other.minor)
        if (patch != other.patch) return patch.compareTo(other.patch)
        // SemVer rule: a normal release outranks every prerelease of the
        // same base version; two normal releases are equal.
        if (prerelease.isEmpty() && other.prerelease.isEmpty()) return 0
        if (prerelease.isEmpty()) return 1
        if (other.prerelease.isEmpty()) return -1
        val limit = minOf(prerelease.size, other.prerelease.size)
        for (index in 0 until limit) {
            val left = prerelease[index]
            val right = other.prerelease[index]
            if (left == right) continue
            val leftNumber = left.toLongOrNull()
            val rightNumber = right.toLongOrNull()
            // Numeric identifiers compare numerically and rank below
            // alphanumeric identifiers (SemVer 2.0.0 item 11).
            if (leftNumber != null && rightNumber != null) return leftNumber.compareTo(rightNumber)
            if (leftNumber != null) return -1
            if (rightNumber != null) return 1
            return left.compareTo(right)
        }
        return prerelease.size.compareTo(other.prerelease.size)
    }

    override fun toString(): String = buildString {
        append(major).append('.').append(minor).append('.').append(patch)
        if (prerelease.isNotEmpty()) append('-').append(prerelease.joinToString("."))
    }

    companion object {
        private val PATTERN = Regex(
            "^(\\d{1,6})\\.(\\d{1,6})\\.(\\d{1,6})(?:-([0-9A-Za-z.-]{1,64}))?(?:\\+[0-9A-Za-z.-]{1,64})?$",
        )

        fun parse(text: String): FloeVersion? {
            val match = PATTERN.matchEntire(text.trim()) ?: return null
            val major = match.groupValues[1].toIntOrNull() ?: return null
            val minor = match.groupValues[2].toIntOrNull() ?: return null
            val patch = match.groupValues[3].toIntOrNull() ?: return null
            val prerelease = match.groupValues[4]
                .takeIf { it.isNotEmpty() }
                ?.split('.')
                ?.filter { it.isNotEmpty() }
                ?: emptyList()
            return FloeVersion(major, minor, patch, prerelease)
        }

        /** Version parsed from an Android release tag; null for any other tag. */
        fun fromAndroidTag(tag: String): FloeVersion? {
            val prefix = "android/v"
            if (!tag.startsWith(prefix)) return null
            return parse(tag.removePrefix(prefix))
        }
    }
}

/**
 * Release-body projection: bounded plaintext, no markup fencing, no HTML and
 * no unbounded body copy into UI state. Everything the dialog shows is a
 * short, human-readable summary from the public release notes.
 */
internal object ReleaseSummary {
    const val MAX_CHARS = 1200

    fun bounded(body: String?): String {
        if (body.isNullOrBlank()) return ""
        val builder = StringBuilder()
        for (raw in body.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            val cleaned = line
                .trimStart('#', '>', '-', '*', '•', '+', ' ')
                .replace("**", "")
                .replace("`", "")
                .trim()
            if (cleaned.isEmpty()) continue
            if (builder.isNotEmpty()) builder.append('\n')
            builder.append(cleaned)
            if (builder.length > MAX_CHARS) break
        }
        val text = builder.toString().trim()
        if (text.length <= MAX_CHARS) return text
        return text.take(MAX_CHARS).trimEnd() + "\u2026"
    }
}

/**
 * SHA256SUMS parsing for the release's own checksum asset. Accepts the GNU
 * coreutils text format (`<64 hex>  <name>`, optional binary `*` marker);
 * absolute paths and path separators are rejected so a checksum file can
 * never redirect the staged filename.
 */
internal object Sha256Sums {
    private val LINE = Regex("^([0-9a-fA-F]{64})[ \\t]+\\*?(.+)$")

    fun parse(text: String): Map<String, String> {
        val entries = LinkedHashMap<String, String>()
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val match = LINE.matchEntire(line) ?: continue
            val hash = match.groupValues[1].lowercase()
            val name = match.groupValues[2].trim()
            if (name.isEmpty() || name.contains('/') || name.contains('\\')) continue
            entries[name] = hash
        }
        return entries
    }
}

/** GitHub `Link` response header: the next page number, bounded. */
internal object GitHubLinkHeader {
    fun nextPage(header: String?, maxPage: Int): Int? {
        if (header.isNullOrBlank()) return null
        for (part in header.split(',')) {
            if (!part.contains("rel=\"next\"")) continue
            val open = part.indexOf('<')
            val close = part.indexOf('>')
            if (open < 0 || close <= open) continue
            val url = part.substring(open + 1, close)
            val match = Regex("[?&]page=(\\d{1,4})").find(url) ?: continue
            val page = match.groupValues[1].toIntOrNull() ?: continue
            if (page in 2..maxPage) return page
        }
        return null
    }
}
