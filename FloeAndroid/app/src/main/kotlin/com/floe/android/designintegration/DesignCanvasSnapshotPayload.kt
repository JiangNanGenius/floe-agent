// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasProject

/**
 * Pure acceptance rules for the REAL `canvasDocument` inside a design
 * `canvas.snapshot` payload.
 *
 * The App only renders the captured canonical scene when the document is
 * present, is schema 7, is the same canvas at the SAME captured revision and
 * still contains the selected node. Anything else is a typed unavailable — the
 * design metadata summary is never substituted for the scene (an older Core
 * without the additive field must not look like a rendered Canvas).
 */
internal object DesignCanvasSnapshotPayload {
    const val FORMAT = "canvas.snapshot"
    const val SCHEMA_VERSION = 7

    fun document(
        project: CanvasProject?,
        canvasID: String,
        documentID: String,
        nodeID: String,
        revision: Long,
    ): CanvasDocument? {
        if (project == null) return null
        if (project.schemaVersion != SCHEMA_VERSION) return null
        if (project.id != canvasID) return null
        // The captured document must be at the same revision as the snapshot;
        // a newer/older revision is never mixed into this preview.
        if (project.revision != revision) return null
        val document = project.documents.firstOrNull { it.id == documentID } ?: return null
        if (document.nodes.none { it.id == nodeID }) return null
        return document
    }
}
