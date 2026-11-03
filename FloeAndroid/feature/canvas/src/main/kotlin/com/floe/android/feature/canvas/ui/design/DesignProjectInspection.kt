// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.design

import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignProjectProjection
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * Read-only inspection of the exact shared design-project JSON that native
 * returned in [DesignProjectProjection.rawProject].
 *
 * The frozen Kotlin projection intentionally carries candidates but not the
 * artifact/revision tree. Proposal needs the real artifact ID and export needs
 * the real original payload format, so those values are read from the same
 * preserved project JSON instead of inventing an ID or a format. Nothing here
 * writes, re-encodes or becomes a second design store.
 */
data class DesignRevisionInfo(
    val artifactID: String,
    val revisionID: String,
    val number: Int,
    val format: String?,
    val isCurrent: Boolean,
)

data class DesignArtifactInfo(
    val artifactID: String,
    val contentType: DesignContentType,
    val displayName: String?,
    val currentRevisionID: String?,
    val revisions: List<DesignRevisionInfo>,
) {
    val currentRevision: DesignRevisionInfo?
        get() = revisions.firstOrNull { it.revisionID == currentRevisionID }
            ?: revisions.maxByOrNull { it.number }
}

internal fun DesignProjectProjection.inspectArtifacts(): List<DesignArtifactInfo> {
    val values = rawProject.array("artifacts") ?: return emptyList()
    return values.mapNotNull { element ->
        val artifact = element as? JsonObject ?: return@mapNotNull null
        val artifactID = artifact.string("id")?.takeIf { it.isNotBlank() }
            ?: return@mapNotNull null
        val current = artifact.string("currentRevisionID")
        val resolvedContentType = DesignContentType.entries.firstOrNull {
            it.wire == artifact.string("contentType")
        } ?: contentType
        val name = artifact.objectValue("identity")?.string("name")
        val revisions = artifact.array("revisions")?.mapNotNull { item ->
            val revision = item as? JsonObject ?: return@mapNotNull null
            val revisionID = revision.string("id")?.takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            DesignRevisionInfo(
                artifactID = artifactID,
                revisionID = revisionID,
                number = revision["number"]?.let { (it as? JsonPrimitive)?.intOrNull } ?: 0,
                format = revision.string("payloadFormat")?.takeIf { it.isNotBlank() },
                isCurrent = revisionID == current,
            )
        }.orEmpty()
        DesignArtifactInfo(
            artifactID = artifactID,
            contentType = resolvedContentType,
            displayName = name?.takeIf { it.isNotBlank() },
            currentRevisionID = current,
            revisions = revisions,
        )
    }
}

internal fun DesignProjectProjection.revision(
    revisionID: String,
): DesignRevisionInfo? = inspectArtifacts()
    .flatMap { it.revisions }
    .firstOrNull { it.revisionID == revisionID }

private fun JsonObject.array(key: String): JsonArray? = this[key] as? JsonArray

private fun JsonObject.objectValue(key: String): JsonObject? = this[key] as? JsonObject

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
