// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

/** A logical delivery hint, separate from the immutable attempt-owned output path. */
internal fun exportDisplayName(requested: String, extension: String): String {
    val suffix = ".${extension.lowercase(java.util.Locale.ROOT)}"
    var leaf = requested.substringAfterLast('/').substringAfterLast('\\').trim()
    if (leaf.endsWith(suffix, ignoreCase = true)) leaf = leaf.dropLast(suffix.length)
    val stem = leaf.map { if (it.code < 32 || it in "\\/:*?\"<>|") '_' else it }
        .joinToString("").trim(' ', '.').take(64)
        .trimEnd { Character.isHighSurrogate(it) }.ifBlank { "Export" }
    return stem + suffix
}
