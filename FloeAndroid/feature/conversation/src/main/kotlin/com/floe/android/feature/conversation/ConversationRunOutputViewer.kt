// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

/** Formats with an actual editor route for a separate, verified workspace copy. */
object RunOutputEditPresentation {
    private val office = mapOf(
        "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )
    private val text = mapOf(
        "txt" to setOf("text/plain"),
        "md" to setOf("text/plain", "text/markdown"),
        "markdown" to setOf("text/plain", "text/markdown"),
        "csv" to setOf("text/plain", "text/csv"),
        "json" to setOf("text/plain", "application/json"),
    )
    const val PREPARING_ACTION = "preparing-edit"
    const val FAILED_ACTION = "edit-failed"
    const val MAX_TEXT_BYTES = 4L * 1024 * 1024

    fun editableExtension(mimeType: String, displayName: String, bytes: Long): String? {
        val extension = RunOutputDisplayName.facts(displayName).extension
        val mime = mimeType.substringBefore(';').trim().lowercase()
        val officeMime = office[extension]
        return when {
            bytes <= 0 -> null
            officeMime != null && (mime == officeMime || mime == "application/octet-stream") -> extension
            bytes <= MAX_TEXT_BYTES && mime in text[extension].orEmpty() -> extension
            else -> null
        }
    }

    fun opensExternally(extension: String): Boolean = extension in office
}
