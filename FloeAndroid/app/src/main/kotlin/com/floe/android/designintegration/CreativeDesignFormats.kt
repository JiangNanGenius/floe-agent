// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.DesignContentType

/**
 * UI affordance mirror of the shared `DesignContentType.from(format:)` rules.
 *
 * It decides which retained materials look compatible with the user's
 * EXPLICIT requested output kind. It is not an authority: the native design
 * service re-derives the family from the verified bytes/format and refuses a
 * mismatch with zero envelope change. Keeping the mapping here only avoids
 * offering an obviously incompatible row (the user never has to learn a raw
 * format token), and an unrecognized format is treated as incompatible rather
 * than silently accepted.
 */
internal object CreativeDesignFormats {
    fun contentTypeFor(rawFormat: String): DesignContentType? {
        val format = rawFormat.lowercase().trim()
        return when (format) {
            "md", "markdown", "txt" -> DesignContentType.NOTES
            "html", "htm", "svg", "json" -> DesignContentType.WEBPAGE
            "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff" ->
                DesignContentType.IMAGE
            "mp4", "mov", "m4v", "webm" -> DesignContentType.VIDEO
            "pdf" -> DesignContentType.PDF
            "docx", "doc", "xlsx", "xls", "csv", "odt", "ods" ->
                DesignContentType.OFFICE_DOCUMENT
            "pptx", "ppt", "odp", "key" -> DesignContentType.PRESENTATION
            "floecad", "dwg", "dxf", "step", "stp", "stl", "obj", "3mf",
            "glb", "gltf", "usdz", "usd" -> DesignContentType.CAD
            else -> null
        }
    }

    fun matches(kind: DesignContentType, rawFormat: String): Boolean =
        contentTypeFor(rawFormat) == kind
}
