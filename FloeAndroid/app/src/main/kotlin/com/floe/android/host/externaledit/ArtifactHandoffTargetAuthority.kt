// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

/**
 * Read-only view of the user's EXISTING Settings > Device target-app ceiling
 * plus the optional Full-platform background document route.
 *
 * This is not a permission store: the FULL platform extension already owns
 * `DeviceAccessHost.settings.allowedPackages`, and wires this interface to
 * read that same set. A missing authority fails closed (`noPermittedTarget`),
 * so a stale/foreign value can never be substituted by the model.
 */
internal interface ArtifactHandoffTargetAuthority {
    fun allowedTargetPackages(): Set<String>

    /**
     * The narrow background viewer/importer route, or null when this channel
     * has no Phone-control capability (fail closed with `backgroundUnavailable`,
     * never a chooser/launcher fallback). The returned implementation still
     * requires its own live armed owner, native epoch, task/run and target
     * checks; returning it grants nothing.
     */
    fun backgroundDocumentLauncher(): ArtifactHandoffBackgroundDocumentLauncher? = null
}
