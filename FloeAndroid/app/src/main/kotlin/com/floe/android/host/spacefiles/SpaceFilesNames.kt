// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import java.util.Locale

/**
 * Pure name/MIME policy for Space → Files.
 *
 * `displayName` is untrusted display text, never a path: these helpers decide
 * whether it can be sent to a provider as ONE display segment, and how a
 * bounded preview should read a file. They never build provider URIs and never
 * treat an extension as document identity.
 */
internal object SpaceFilesNames {

    /** Same single-segment rule the gateway enforces for create/rename. */
    const val MAX_NAME_BYTES = 255

    fun isSafeSegment(raw: String): Boolean {
        val name = raw.trim()
        if (name.isEmpty() || name.length != raw.length) return false
        if (name == "." || name == "..") return false
        if (name.contains('/') || name.contains('\\')) return false
        if (name.any { it.code < 0x20 || it.code == 0x7f }) return false
        return name.toByteArray(Charsets.UTF_8).size <= MAX_NAME_BYTES
    }

    private val textMimeTypes = setOf(
        "application/json",
        "application/xml",
        "application/x-yaml",
        "application/yaml",
        "application/javascript",
        "application/x-sh",
        "application/sql",
        "application/toml",
        "application/x-httpd-php",
    )

    private val textExtensions = setOf(
        "txt", "text", "md", "markdown", "json", "xml", "csv", "tsv", "yaml", "yml",
        "log", "ini", "toml", "conf", "cfg", "properties", "gradle", "kts",
        "kt", "java", "swift", "py", "js", "jsx", "ts", "tsx", "sh", "zsh", "bash",
        "html", "htm", "css", "scss", "sql", "go", "rs", "c", "h", "cc", "cpp", "hpp",
        "svg", "gitignore", "pl", "lua", "rb", "php", "dockerfile", "makefile",
    )

    private val extensionMimeTypes = mapOf(
        "md" to "text/markdown",
        "markdown" to "text/markdown",
        "json" to "application/json",
        "csv" to "text/csv",
        "tsv" to "text/tab-separated-values",
        "html" to "text/html",
        "htm" to "text/html",
        "xml" to "application/xml",
        "svg" to "image/svg+xml",
        "yaml" to "application/yaml",
        "yml" to "application/yaml",
        "toml" to "application/toml",
        "sh" to "application/x-sh",
        "sql" to "application/sql",
    )

    fun extensionOf(name: String): String {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return ""
        return name.substring(dot + 1).lowercase(Locale.ROOT)
    }

    /** MIME for a newly created text document, derived from the typed name. */
    fun mimeForNewTextFile(name: String): String =
        extensionMimeTypes[extensionOf(name)] ?: "text/plain"

    /** Bounded text preview is meaningful for declared text and known text names. */
    fun allowsTextPreview(mimeType: String, name: String): Boolean {
        val mime = mimeType.lowercase(Locale.ROOT)
        if (mime.startsWith("text/")) return true
        if (mime in textMimeTypes) return true
        return extensionOf(name) in textExtensions
    }

    /**
     * BitmapFactory can decode raster images only; SVG is text and is handled
     * by the text path (never claimed as a decodable image).
     */
    fun allowsImagePreview(mimeType: String, name: String): Boolean {
        val mime = mimeType.lowercase(Locale.ROOT)
        if (mime == "image/svg+xml" || extensionOf(name) == "svg") return false
        if (mime.startsWith("image/")) return true
        return extensionOf(name) in setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif", "avif")
    }

    /** Human byte size; unknown is the caller's separate string, never "0 B". */
    fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = listOf("KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = ""
        for (candidate in units) {
            value /= 1024.0
            unit = candidate
            if (value < 1024.0) break
        }
        return if (value >= 100) {
            String.format(Locale.ROOT, "%.0f %s", value, unit)
        } else {
            String.format(Locale.ROOT, "%.1f %s", value, unit)
        }
    }
}
